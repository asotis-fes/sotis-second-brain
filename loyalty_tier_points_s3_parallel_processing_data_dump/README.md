# Loyalty Tier Points — Snowflake → S3 Migration Data Dump

**Owner:** Alex Sotis · **Team:** Data Engineering Integrations · **Created:** 2026-07-29
**Prod cutover:** TBD (was 8/3; slipped through query redesigns + format validation)

## Goal
One-time export of tier-points **migration** datasets from Snowflake **prod** into the Loyalty
team's S3 buckets via `COPY INTO`, so the Loyalty service can load them into its new tier-points
service. Run against the same prod tables, only the destination stage differs: **perf**
(`fes-loyalty-fanapp-perf-1`, dry-run) then **prod** (`fes-loyalty-fanapp-prod-1`, real cutover).

## ▶ Resume-after-/compact (current state, 2026-08-07)
- **Scripts are at v4** — rebuilt to Suneel's **DE-COLLIDE** model from his repo
  [`fes-loyalty-tp-migration-ws/snowflake`](https://github.com/fanatics-gaming/fes-loyalty-tp-migration-ws/tree/main/snowflake).
  Builders in [export_tp_migration.py](export_tp_migration.py) (source of truth), driven by
  [gen.py](gen.py) / [gen_sample.py](gen_sample.py).
- **What changed vs v3.1:** 3-tier identity map (not the single legacy tenant map); per-**fan-id**
  keying via de-collide (was per-loyalty-id); FMTI is 39 cols (+`source_loyalty_id`/`is_primary`/
  `dup_group`). See "The de-collide model" below.
- **Validated read-only (2026-08-07):** all 8 map source tables readable; the full map chain, every
  FMTI/override/ledger column, and the de-collide projection all compile (`EXPLAIN`).
- **NEXT: 1000-account sample export to perf first** (Suneel's ask), then the full export a few days
  later — procedure below.
- **Two open items Suneel flagged for us** (see "Open confirmations"): the tier-2 `_dev` map source,
  and re-confirming the timestamp format for the new loader.

## The de-collide model (what makes v4 different)
Many `PRIVATE_FAN_ID`s can resolve to one `LOYALTY_ACCOUNT_ID`. We do **not** merge them — **every
fan-id migrates as its own account**:
- **Identity map is 3-tier**, unioned by priority: tier-1 `identity.orchestration.loyalty_private_fan_id_map`
  → tier-2 a prod email-chain (`scylla → auth_id → account_internal → user_service → hashed_email →
  cde.loyalty_account`) → tier-3 the legacy `LOYALTY_ACCOUNT_ID_FAN_ID_TENANT_MAP`.
- **De-collide:** within a colliding loyalty-id the highest-active-balance fan-id (`is_primary`)
  **keeps the original id**; every other fan-id gets a **new deterministic v1-shaped UUID**
  (`UUID_STRING(fixed-ns, pfid:source_loyalty_id)` with the version nibble flipped 5→1, because the
  Cassandra `loyaltyAccountId` is a `timeuuid` and rejects v5). Deterministic → all datasets
  recompute the same id, no shared table.
- **Key flips to one-row-per-fan-id.** `effective_loyalty_id` is 1:1 with fan-id, so chunking by it
  still puts an account's whole history in exactly one chunk. FMTI carries `source_loyalty_id` /
  `is_primary` / `dup_group` so the loader writes an `account_metadata(program_id=2)` row for both
  sides of every dup group.

## Run procedure (perf sample → perf full → prod)
Run from this folder via `snow sql -f`. `gen.py` emits phased SQL from the vetted builders. Setup/
verify/count run as your default role (owns the transient snapshots); the export COPY runs as
ACCOUNTADMIN (owns the integration/stage) — hence the one-time schema `GRANT SELECT`.

```bash
export TP_ENV=perf                              # prod: TP_ENV=prod
export TP_CUT="$(date '+%Y-%m-%d %H:%M:%S')"    # perf/sample: now; prod: the real freeze T

# 0. integration must point at the env's role (perf 354089337614 / prod 851474972090):
#    ALTER STORAGE INTEGRATION loyalty_migration_s3_int SET STORAGE_AWS_ROLE_ARN=
#      'arn:aws:iam::354089337614:role/fes-loyalty-snowflake-s3-fanapp-perf-1-migration';
snow sql -q "REMOVE @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/;"     # clear old run
python3 gen.py setup      > 1.sql && snow sql -f 1.sql   # 3-tier map + de-collide + ledger (map runs ONCE)
snow sql -q "GRANT SELECT ON ALL TABLES IN SCHEMA FES_USERS.ALEX_SOTIS TO ROLE ACCOUNTADMIN;"

# ── A) 1000-account SAMPLE first (Suneel) ────────────────────────────────────────────
python3 gen_sample.py 1000 > s.sql && snow sql -f s.sql  # restrict snaps to 1000 accts w/ ledger history
python3 gen.py verify     > v.sql && snow sql -f v.sql   # GATE (on the sample): see gate rules below
python3 gen.py count      > c.sql && snow sql -f c.sql   # -> 1 (1000 accts all in chunk 0)
python3 gen.py export 1   > 2.sql && snow sql -f 2.sql   # fmti/ + override_cdc/ + ledger/chunk_00000/
snow sql -q "LIST @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/;"

# ── B) FULL run (a few days later; re-run setup to un-restrict the snapshots) ─────────
python3 gen.py setup      > 1.sql && snow sql -f 1.sql   # rebuild FULL-scope snapshots
snow sql -q "GRANT SELECT ON ALL TABLES IN SCHEMA FES_USERS.ALEX_SOTIS TO ROLE ACCOUNTADMIN;"
python3 gen.py verify     > v.sql && snow sql -f v.sql   # GATE
python3 gen.py count      > c.sql && snow sql -f c.sql   # -> N
python3 gen.py export <N> > 2.sql && snow sql -f 2.sql   # fmti + overrides + N ledger chunks
snow sql -q "LIST @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/;"
python3 gen.py cleanup    > 4.sql && snow sql -f 4.sql   # drop transient snaps (keeps UNRESOLVED)
```
- **Verify gate rules:** `ledger_missing_account` and `overrides_missing_account` **must be 0**
  (cohort integrity, §P2). `unresolved_active_fanids` / `unresolved_points_at_stake` (§P1) is the
  data-loss surface — fan-ids with points-bearing ledger activity that resolve in **none** of the 3
  tiers; if points are material, hand the `TP_MIGRATION_UNRESOLVED` list to the data team before prod.
- **Speed:** each chunk is one file (`SINGLE=TRUE`) run sequentially. The map runs once in setup, so
  the full export is chunk-count bound. Ask for a parallel-chunk runner if the prod window is tight.

## Confirmed facts
- **Deleted accounts are MIGRATED** (they become stale in the new ledger). No deleted filter. Only
  fan-ids the 3-tier map can't resolve are dropped (surfaced by §P1).
- **Per-fan-id keying via de-collide.** `effective_loyalty_id` is 1:1 with fan-id; primary keeps the
  original loyalty id, secondaries get a deterministic v1-shaped UUID. FMTI is one row per fan-id.
- **FMTI covers every exported override + ledger account by construction** — the de-collide snapshot
  is built from FMTI, so every `effective_loyalty_id` has an FMTI row; `verify` proves §P2 = 0.
- **Cutover applies to the LEDGER only.** FMTI + overrides are current-state snapshots.
- **Format:** timestamps → UTC `YYYY-MM-DD HH24:MI:SS.FF3 Z`; NULLs → bare empty (`NULL_IF=()`);
  booleans (incl. `is_primary`/`dup_group`) → lowercase `true/false`; every chunk file has a HEADER.
- **Member-alignment holds:** single-snapshot pinning → each account's full history is in one chunk.

## Open confirmations — both RESOLVED
1. ~~Tier-2 map entry point is a `_dev` schema.~~ **RESOLVED 2026-08-07 (Suneel):**
   `commerce_dev.source.scylla_tenant_fanid_ext` is intentional — a loyalty-team table for
   paid→loyalty-id mapping, used only as the **tier-2 fallback** (when tier-1 identity misses). Mohit
   backfilled the tier-1 identity table on 2026-08-06, so tier-1 now covers more and tier-2's share
   shrinks. We rebuild the map snapshot fresh at `gen.py setup`, so the backfill is picked up
   automatically. Sanity-check `unresolved_active_fanids` (§P1) in `verify` post-backfill.
2. ~~Timestamp format for the new loader.~~ **RESOLVED 2026-08-10 (Suneel):** he confirmed our last
   full perf export looked good, which validates the UTC `… Z` format (`TS_SUFFIX=' Z'`). No change needed.

## Files
- [export_tp_migration.py](export_tp_migration.py) — **SQL builders = source of truth** (v4).
  `python3 export_tp_migration.py <setup|effective|fmti|overrides|chunk|count|verify|cleanup>` prints SQL.
- [gen.py](gen.py) — phased runner (setup/count/export/verify/cleanup); env `TP_ENV`, `TP_CUT`.
- [gen_sample.py](gen_sample.py) — restrict pinned snaps to N accounts (run AFTER `gen.py setup`).
- [reference.md](reference.md) — map/de-collide, buckets/accounts/roles, dataset model, gates.
- [export-sql.md](export-sql.md) — concise dataset summary (defers to the code for exact SQL).
- [snowflake-stage-setup.md](snowflake-stage-setup.md) — integration/stage setup (done) + AssumeRole troubleshooting.

## Key decisions
- Integration + stages built **manually in the Snowflake UI as ACCOUNTADMIN** (short-lived; drop
  after prod). Roles are Loyalty-owned, **per-env accounts** (perf `354089337614`, prod
  `851474972090`) — NOT the CI accounts.
- Export runs via `export_tp_migration.py`/`gen.py` (**not** MWAA/the DAG), as ACCOUNTADMIN.
- **Single-snapshot pinning** — `gen.py setup` materializes `TP_MAP_SNAPSHOT` (raw 3-tier union),
  `TP_EFFECTIVE_SNAPSHOT` (de-collide), `TP_LEDGER_SNAPSHOT` (chunk-assigned) in `FES_USERS.ALEX_SOTIS`.
  The expensive 6-DB map runs **once**; all datasets join the pinned de-collide → no drift.
- **One file per chunk** (`chunk_NNNNN/chunk_NNNNN.csv.gz`, `SINGLE=TRUE`), chunked by `effective_loyalty_id`.

## Source material
- **Suneel's repo (2026-08-07)** = `fanatics-gaming/fes-loyalty-tp-migration-ws`, `snowflake/`
  (`fmti.sql`, `overrides.sql`, `ledger.sql`, `preflight.sql`, `split_ledger.py`). This is the query
  source of truth; his earlier DM queries / `info.txt` are superseded.
- Slack thread (buckets/layout): channel `C08NEJYM69L`, thread ts `1784221033.492019`.
- Confluence: Tier Points Migration (`3278143602`), Migration Plan Notes (`3012788698`).

## Related projects
`../loyalty_tier_points_migration/` · `../loyalty_ingest_migration/` · `../loyalty_new_service/`
