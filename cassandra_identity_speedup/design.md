# Build Design — CDC Materialization

Grounded in: the confirmed prod CDC stage (findings.md probe), the reusable `debezium_cdc` dbt
pattern (data-transformations), and the current `tag:identity` contract (dbt-fes-ae). See
[cdc_investigation.md](cdc_investigation.md) for source docs + Anna's SQL.

## The contract to preserve (from dbt-fes-ae)

Sources: `dbt-fes-ae/models/sources/identity.yml` (schema `IDENTITY.SOURCE`, external tables `*_ext`
over `cassandra/{ks}/{table}/`). Consumers in `dbt-fes-ae/models/identity/`, all **current-state,
one-row-per-entity** (they read `MAX(upload_date)` partition today):

| Cassandra tbl | ext table (today) | PK / grain | consuming model |
|---|---|---|---|
| id.loyalty | loyalty_private_fan_id_map_ext | loyalty_id | loyalty_private_fan_id_map |
| id.marketing | martech_private_fan_id_map_ext | martech_id | martech_private_fan_id_map |
| profile.core | core_ext | profile_id | unified_profile_core |
| profile.preferences | preferences_ext | profile_id | unified_profile_preferences |
| profile.favorites | favorites_ext | (profile_id, entity_id) | unified_profile_favorites |

**Goal:** produce a CDC-derived object per table with the **same columns + current-state grain**, and
**repoint the source** so the `unified_*` / `*_map` models are unchanged (or nearly).

## Target layers (reuse the 3-layer SHAPE, Cassandra-specific internals)

```
S3 (identity-cdc-fes-prod)                          [platform-owned, confirmed flowing]
 └─ Snowpipe/COPY  ──► IDENTITY.CDC_RAW.<table>     land raw Debezium JSON, beat 7-day TTL, 1 read of 256k files
     └─ dbt: <table>_cdc_parsed (incremental)       parse envelope + derive node_id; append-only
         └─ dbt: <table>_cdc_current (view/table)    dedup RF3×re-read → latest per PK, drop op='d'
             └─ dbt: <table> (source repoint)         UNION seed (pre-CDC) + cdc_current  ► existing model
```

Why NOT reuse the Postgres `CDC_SCD`/`parsed_materialized_view` macros directly: they key on
`payload:source:lsn`/`sequence` and read a `before` image. **Cassandra Debezium has neither** — no
`before`, ordering is commit-log `source:file`+`source:pos`, columns are `{value,set}` Avro unions,
and `(file,pos)` is not a global dedup key (RF=3). We keep their **layer structure** but write a new
**`cassandra_cdc_*` macro** implementing Anna's logic.

## The reusable Cassandra CDC macro (from Anna's BARDSPLAT-31 SQL)

Inputs: stage/raw table, `logical_key` (list), optional `order_cols`. Produces current-state rows.
1. Parse: `$1:after:<col>:value` per column; `$1:op`, `$1:source:{table,file,pos,ts_ms}`, `$1:ts_ms`.
   Use `IS_NULL_VALUE()` (not `IS NULL`) on VARIANT inner nulls.
2. `node_id` = dense-run index over `segment_id` (`REGEXP_SUBSTR(source:file,'CommitLog-7-(\d+)\.log')`),
   computed in **two CTE levels** (`LAG` can't nest in `SUM() OVER`).
3. Dedup: `GROUP BY logical_key` collapsing the 5–8× copies; `is_current` via
   `ROW_NUMBER() OVER (PARTITION BY <pk> ORDER BY source:ts_ms DESC, <tiebreak> DESC)=1`; drop `op='d'`.

## Seed + union (CDC has no backfill)

CDC only carries changes since enablement (per table). Rows unchanged since then never appear.
```
final_current =
    SELECT <cols> FROM <table>_cdc_current                       -- authoritative latest for changed rows
  UNION ALL
    SELECT <cols> FROM seed_snapshot s                           -- pre-CDC baseline
    WHERE s.<pk> NOT IN (SELECT <pk> FROM <table>_cdc_current)    -- only rows CDC hasn't superseded
```
- **Seed** = one batch snapshot (the existing `cassandra_extract` output, run once ≥ enablement date).
  Keep the batch DAG for this + dev; do NOT delete it.
- Deletes: `op='d'` rows are excluded from `_cdc_current`, so a post-enablement delete correctly
  drops the row from `final_current` even if present in seed.
- Reconciliation (deferred): a change missing from all 3 nodes is undetectable from CDC alone
  (Anna) → optionally re-seed periodically to self-heal.

## Landing mechanism

**Snowpipe auto-ingest** preferred (the SNS topic from TF PR #3270 exists) → `IDENTITY.CDC_RAW.<table>`,
so consumers never scan the 256k-file stage. Fallback: scheduled `COPY INTO` in the identity DAG.
Either way, land once; model incrementally off the table.

## Freshness / alerting

Latency is bimodal (p50 2.7s, 0.94% > 1h, max 2.3h). **Alert on pipeline lag** (max source:ts_ms vs
now), NOT row counts — counts look normal during a stall. Wire to the identity DAG's existing P2 callback.

## Pilot (M3, first PR)

**`id.loyalty` end-to-end** (well-understood; Anna already validated its key):
1. Land `IDENTITY.CDC_RAW.LOYALTY` (Snowpipe or COPY).
2. `loyalty_cdc_parsed` + `loyalty_cdc_current` (macro) in dbt-fes-ae, logical key
   `(loyalty_id, private_fanid, created)`, tiebreak `source:ts_ms`.
3. Parity vs. a fresh `loyalty` batch snapshot (row count + spot PKs).
4. Repoint `loyalty_private_fan_id_map` source → CDC current (+ seed union).
Then replicate per table (core, preferences, marketing, favorites, tenant_fanid, …).

## Repos / PRs
- **dbt models + macro + source repoint:** `dbt-fes-ae` (labeled PR; tag:identity so the existing
  dbt Cloud job picks them up).
- **Snowpipe / stage / CDC_RAW + storage integration grants:** `fanapp-terraform`
  (`root/fes-data/snowflake-v2/…`, extends `integrations-fes_instaclustr.tf`).
- **DAG changes** (retire daily full-extract → keep as seed/dev; add lag alert / Snowpipe trigger):
  `fes-airflow` `dags/identity/`.

## Open design confirmations (for user)
1. **Current-state only** (match today's contract) vs. also keep a HISTORY/SCD grain? (Default: current-only now, history later.)
2. **Snowpipe** (auto, preferred) vs. **scheduled COPY** in the DAG for landing?
3. Seed: strictly one-time vs. periodic reconciliation re-seed?
