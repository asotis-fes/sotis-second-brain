# Findings

## Current-state code facts (`dags/identity/cassandra_extract.py` @ main)

### DAG `cassandra_extract`
- `schedule_interval`: prod `0 6 * * *` (6am EST), dev `None`. `catchup=False`, `max_active_runs=1`.
- Callbacks: `dag_failure_callback_p2` / `dag_success_callback_p2` (P2 paging).
- Task graph: `discover_tables` → `extract_table.expand(table_info=tables)` →
  `summarize_results` → `identity_dbt` (dbt Cloud task group, job
  `70437463793544` prod / `70437463793536` dev, `dbt build --select tag:identity`).

### `discover_tables()` task
- `store_ssl_certificates()` writes cassandra certs from Airflow Variable `SSH_PRIVATE_KEY_FILES` to `/usr/local/airflow/tmp/ssh_keys`.
- Reads `SELECT keyspace_name, table_name FROM system_schema.tables`, filters to
  `TARGET_KEYSPACES = ["profile", "id"]`, excludes `SKIP_TABLES = {"credit_card"}`.
- Returns `[{keyspace, table}, ...]` for dynamic mapping.
- **Note:** no per-table partition-key info returned yet — token-range work will need the PK column(s).

### `extract_table(table_info)` task — the bottleneck
- `execution_timeout=1h`, **`max_active_tis_per_dagrun=1`** → tables extracted strictly sequentially.
- Query: `SELECT * FROM {ks}.{table}` via `SimpleStatement`, `fetch_size=5000` (`FETCH_SIZE`),
  `consistency_level=LOCAL_ONE`, `timeout=QUERY_TIMEOUT=300s`.
- Single coordinator drives the whole paged scan → no token-ring parallelism.
- Buffers rows into `current_batch`; every 5000 rows → `_save_batch_to_s3` → **one Parquet file per 5000 rows** (many small files).
- `hook.shutdown_cluster()` in `finally`.

### `_save_batch_to_s3(...)`
- Builds a PyArrow table column-by-column via `_convert_value`, writes snappy Parquet to a `BytesIO`, uploads to
  `cassandra/{keyspace}/{table}/{upload_date}/batch_{batch_num:04d}.parquet`. `upload_date` = `data_interval_end` (YYYY-MM-DD).

### `_convert_value(val)`
- Primitives/list pass through; UUID/datetime/date/time → `str`; set/frozenset → list;
  map-like (`.items()`) → `json.dumps(dict(...))`; catch-all → JSON or `str`.
- Downstream Snowflake external tables use `PARSE_JSON()` on the map columns.
- **Constraint for token-range work:** output column names + types must stay identical, else downstream ext tables break.

### `cassandra_schema_discovery.py`
- Ad-hoc, `schedule_interval=None`. Lists `table_name, column_name, type` from
  `system_schema.columns` per keyspace. **No row counts, no PK ordering info surfaced** (has `type` but not `kind`).
- To get PK columns for token-range queries we'll likely need `system_schema.columns.kind = 'partition_key'`
  (position via `position` column) — not currently queried.

## Sizing evidence — GROUND TRUTH from last prod run

**Source:** prod run `scheduled__2026-09-22T10:00:00+00:00` (executed 2026-09-23 06:00 EDT),
`extract_table` Mapped Tasks view. **33 tables** discovered. Airflow dynamic task mapping
preserves `discover_tables` list order, so `map_index` ↔ table is deterministic (verified against
the discover_tables return-value log).

### Per-table durations (idx = map_index)

| idx | table | duration | sec |
|----|-------|---------|-----|
| 17 | **profile.core** | 38:42 | 2322 |
| 28 | **profile.preferences** | 34:44 | 2084 |
| 1  | **id.auth_id_lkp** | 30:59 | 1859 |
| 0  | **id.auth_id** | 29:05 | 1745 |
| 2  | **id.loyalty** | 28:46 | 1726 |
| 4  | **id.marketing** | 28:46 | 1726 |
| 3  | **id.loyalty_lkp** | 26:51 | 1611 |
| 5  | id.marketing_lkp | 07:22 | 442 |
| 25 | profile.favorites | 06:20 | 380 |
| all other 24 tables | trivial | ~1–3s | ~50 total |

- **Wall clock (extract phase):** map 0 start 06:00:09 → map 32 end 09:54:25 = **~3h 54m**.
  (Framing's "~5h" likely includes `discover_tables` + the identity dbt Cloud group after.)
- Sum of task durations ≈ **13,900s ≈ 3.86h** — matches wall clock, **confirming the tasks run
  strictly sequentially** (`max_active_tis_per_dagrun=1`).

### VERDICT — NOT one giant table. It's ~7 medium tables + a long trivial tail.

- **7 tables in the 27–39 min band** (core, preferences, auth_id_lkp, auth_id, loyalty, marketing,
  loyalty_lkp) + 2 more at 6–7 min (marketing_lkp, favorites) = **~99% of the runtime**.
- The single largest table (profile.core, 38.7 min) is only **~17%** of the extract — there is no
  single hog to blame.
- Remaining 24 tables are effectively empty/tiny (1–3s each).

### Implications for the fix (drives decisions.md D-3)
1. **Table-level concurrency (lever 1) is the DOMINANT win here.** Running tables in parallel
   instead of sequentially collapses wall-clock from Σ (~3.9h) toward max(single table) ≈ 39 min —
   a ~6× ceiling from concurrency alone. Rough estimate with a concurrency cap of 4: ~2 waves of
   the big tables ≈ **~65–70 min** (~3.4×); cap of 8: one wave ≈ **~39 min** (~6×).
2. **Token-range (lever 2) then attacks the ~39-min floor** — it's most valuable on the top
   ~7 tables to break the longest-pole once tables run concurrently. Not worth it on the trivial tail.
3. So the ordering is **concurrency first (biggest ROI), token-range second (lowers the pole)** —
   both ship together, but this reframes token-range from "the primary fix" to "the second lever."

## PROD CDC probe — read-only, 2026-09-28 (DIRECTORY metadata, no file scan)

Ran on `FAN_DATA_EXCHANGE_PROD` / `FES_DATA_DEVELOPER` / `FDE_DEVELOPER_WH` against
`@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD`:

- **256,315 files, ~78.8 GB**, earliest `2026-09-11 08:14 UTC`, latest `2026-09-28 15:25 UTC`
  (i.e. writing continuously, current to the minute). **19 tables.**
- Access confirmed: `FES_DATA_DEVELOPER` can read the FDE stage directory. ✅
- **Per-table file counts (freshness all ~now unless noted):** id.tenant_fanid 55,524 · id.tenant_fanid_lkp
  52,345 · profile.preferences 19,271 · id.loyalty 16,510 · profile.core 12,903 · id.auth_id 12,333 ·
  id.marketing 12,314 · id.loyalty_lkp 12,221 · id.auth_id_lkp 12,200 · id.marketing_lkp 12,181 ·
  profile.favorites 11,498 · id.profile_id 9,950 · id.profile_id_lkp 6,375 · id.private_fanid 6,210 ·
  id.partnership_intent 1,236 · id.partnerships_lkp 1,128 · id.partnerships 1,121 ·
  id.partnership_intent_lkp 966 · profile.streak 29.

**Consequences:**
- **`tenant_fanid` is now CDC-covered** (contradicts the Aug Slack note) → it does NOT need to stay
  batch-only. Removes a major caveat.
- CDC coverage ≈ all non-trivial `id`+`profile` tables → CDC can carry the whole daily workload
  (except dev, which has no CDC by design).
- **7-day TTL is not currently pruning** (17 days of files present) — good for seeding; confirm
  whether that's intentional before relying on it.
- **File explosion is worse in prod**: 256k files. Scanning the raw stage repeatedly is a non-starter
  → **land via Snowpipe/COPY into a table** (D-8 design). (~315 KB avg/file, bigger than test's 3.5 KB.)

## PROD envelope + dedup VALIDATED (read-only, 2026-09-28) — de-risks the macro

**File format:** `FDE.FDE_STAGE.JSON_FF` (JSON). The stage's *default* FF is CSV-like — must name
JSON_FF explicitly or the JSON splits on the first comma. **Stage path:**
`@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD/topics/identity_cdc.<ks>.<table>/dt=YYYY-MM-DD/hour=HH/…json.gz`
(Hive-partitioned; filename `identity_cdc.<ks>.<table>+<kafkaPartition>+<offset>.json.gz`).

**Real prod envelope (id.loyalty), confirms Anna's structure:**
```json
{ "op":"i", "ts_ms":<emit_ms>,
  "after": { "loyalty_id":{"value":"<uuid>","set":true,"deletion_ts":null},
             "private_fanid":{"value":"<uuid>","set":true}, "created":{"value":<epoch_ms>},
             "_range_start":null, "_range_end":null },
  "source": { "connector":"cassandra","cluster":"fanapp-prod-1-prod-fes-identity-cassandra",
              "keyspace":"id","table":"loyalty","file":"CommitLog-7-1787764124419.log",
              "pos":5194327,"ts_ms":<src_ms>,"sequence":null,"snapshot":"false","version":"2.0.1.Final" } }
```
- `after.<col>.value` (+ `set`, and a new per-cell `deletion_ts` in Debezium 2.0.1). Parse `:value`.
- `source.sequence` is **null** → no LSN; order by `source.ts_ms` + node_id/segment dedup (confirmed).
- `source.file` matches `CommitLog-7-(\d+)\.log` → Anna's node-clustering regex works as-is.

**Dedup validated on a 1-hour loyalty slice (`dt=2026-09-28/hour=15`):**
| raw_events | commitlog_files | distinct_ids | distinct_logical | dup_factor | op_i/u/d |
|---|---|---|---|---|---|
| 4,403 | 11 | 861 | 861 | **5.11×** | 4403 / 0 / 0 |
- Logical key `(loyalty_id, src_ts_ms, private_fanid, created_ms)` collapses the 5.11× cleanly;
  `distinct_ids == distinct_logical` in-window. PK = `loyalty_id`. All inserts (upserts). ✅
- **Conclusion:** Anna's parse+dedup pattern reproduces on prod. Macro build is de-risked.

## CDC-vs-DAG table coverage (2026-09-28) — before decommissioning the batch DAG

DAG `cassandra_extract` discovers **33 tables** (keyspaces id+profile, skip credit_card); CDC stage
has **19**. **CDC ⊆ DAG** (every CDC table is also extracted by the DAG; none CDC-only).

- **CDC-covered (19):** id.{auth_id,auth_id_lkp,loyalty,loyalty_lkp,marketing,marketing_lkp,
  partnership_intent,partnership_intent_lkp,partnerships,partnerships_lkp,private_fanid,profile_id,
  profile_id_lkp,tenant_fanid,tenant_fanid_lkp} (15) + profile.{core,favorites,preferences,streak} (4).
  ⚠️ `profile.streak` looks STALE (29 files, last 06:05 UTC vs ~now for the rest) — CDC may have stopped.
- **DAG-only, NOT in CDC (14):** id.schema_migrations; profile.{address, core_history,
  credit_card_customer_lkp, dbversion, display_name_lookup, **email, email_lkp, phone, phone_lkp**,
  entity_tags, profile_tagged_entities, schema_migrations, tag_catalog}.

**Consumption check (grep of dbt-fes-ae + fes-airflow/dags/dbt + data-transformations):**
Only **6** Cassandra tables have BOTH an external table (in `fes-airflow/dags/create_tables/sql/identity`)
AND a dbt consumer — and all 6 are CDC-covered:
- the identity 5 (loyalty_private_fan_id_map, martech_private_fan_id_map, core, preferences, favorites);
- **auth_id** — a 6th, in a DIFFERENT group: `fde__source.auth_id_ext` (DB `FDE.SOURCE`) →
  `dbt-fes-ae/models/fde/auth_id.sql`. Same CDC migration pattern applies; out of scope for THIS PR
  (identity source) but an easy follow-up.

The **14 DAG-only tables have ZERO references** anywhere in the three FES dbt repos (no ext table, no
consumer) — the batch DAG extracts them but nothing reads them (email/phone/address/etc.).

**Retire-readiness:** every consumed Cassandra table is CDC-covered, so post-migration the batch DAG
extracts 33 tables of which only 6 are consumed and all 6 have CDC. The DAG can be **fully retired**
(kept only as one-time seed + dev) once: (a) auth_id is migrated too, and (b) we confirm no consumers
OUTSIDE these 3 repos (other Mesh projects, Streamlit, ad-hoc) for the 14 + the 6. Within the FES dbt
repos, the 14 are dead extraction.

## Still-open questions
- Partition key column(s) for the top ~7 tables — needed for `token(pk)` predicates.
  (Extend discovery to read `system_schema.columns.kind='partition_key'` + `position`.)
- `system.size_estimates` cross-check (optional now — durations already answer the sizing question;
  size_estimates still useful to pick N ranges per table & estimate row/byte volume).
- Cassandra topology: hosts seen in log = DC `fanapp-prod-1-prod-cassandra-dc` (10.58.x) +
  `...-reader-dc` (10.68.x). **A reader DC exists** → extract should target it (LOCAL_ONE +
  DCAwareRoundRobin/TokenAware pinned to the reader DC) to avoid loading the write path. Confirm
  the conn's contact points / load-balancing DC.
- Worker/pool slot capacity in MWAA — caps the achievable table-level concurrency.
