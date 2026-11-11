# Decisions & Open Questions

## Decisions (with why)

### D-1 (2026-08-21) — New FanCash ingest DAG, cloned from the Tier DAG
Created `fes-airflow/dags/loyalty/loyalty_postgres_fancash_to_s3_ingest.py`, modeled on
`loyalty_postgres_tier_to_s3_ingest.py`. Extract-only, chunked (`build_chunk_specs`,
CHUNK_ROWS=250k), writes to the shared `loyalty_postgres/` S3 prefix, dev schedule `None` /
prod `50 * * * *` (offset from OC `:05` and tier `:35`). p2 callbacks, tags `[loyalty, fancash]`.

- **Why a separate DAG (not editing the OC DAG):** matches the established per-program pattern
  and keeps FanCash volatility from stalling the OneCredits pipeline while it migrates in parallel.
- **Which tables:** the shared program-scoped tables filtered to `program_id=1` —
  `transaction`, `bucket`, `account_balance`, `account_metadata`. These are exactly the shared
  tables that carry `program_id` and are NOT otherwise ingested for program_id=1 (OC pins the
  first three to program_id=3; account_metadata is tier-only). Column configs are **reused** from
  `OC_POSTGRES_TABLE_CONFIGS`/`TP_POSTGRES_TABLE_CONFIGS` (one source of truth for jsonb→TEXT casts,
  pk chunk keys). Non-program satellites (allocation, capture_event, …) are already fully ingested
  by the OC DAG — deliberately NOT duplicated here.
- **Verified:** imports clean under the repo tox env; 4 plan_/load_ pairs wired, all program_id=1.

### D-2 (2026-08-25) — Switch FanCash to Aurora-native `aws_s3.query_export_to_s3`
FanCash volume is too large for the chunked `SqlToS3Operator` (buffers whole result in
worker memory → OOM). New DAG `loyalty_fancash_aurora_export_to_s3.py` runs the export
server-side on Aurora (no rows through the worker, auto-split at ~6 GB). CSV output (no
parquet from this function), new prefix `fancash_export/` on the same-account loyalty
bucket, new CSV external tables. FanCash-only for now; deprecate chunked ingests for
OC/Tier later. Supersedes the chunked FanCash DAG (PR #2338) once infra lands.
Full design + cross-team asks in `aurora_export_plan.md`. Aurora PG 17.7 confirmed in
fanapp-terraform; the `s3Export` cluster role association is the main missing infra piece.

### D-3 (2026-08-25) — Chosen extraction: streaming `COPY … TO STDOUT` from the READER
`aws_s3.query_export_to_s3` is **writer-only** (AWS docs; errors on a reader) — ruled out by the
"no writer load" constraint. Chosen approach: a streaming `COPY (SELECT … WHERE program_id=1 AND
<incr_col> in [window]) TO STDOUT` run against the Aurora **reader** endpoint, piped into an S3
multipart upload. Why it wins:
- **Reader-capable & grant-free:** COPY TO STDOUT needs only SELECT (no rds_superuser, no aws_s3
  extension, no cluster `s3Export` IAM role). S3 write is done by the worker's existing `aws_storage`
  role into our own same-account `fes-integrations-<env>` bucket → **no platform/loyalty grants**.
- **Memory:** benchmarked on real Postgres 16 (`memory_benchmark.md`) — peak RSS is **flat** (117→302→
  369 MB for 250k→1M→5M rows, tracks the S3 part buffer, not N) vs the current pandas-DataFrame chunking
  which is O(N) (1 GB at 250k, ~15 GB at 5M). ~40× less memory at 5M, and faster. No chunk-planning, no OOM ceiling.
- **Tradeoffs:** bytes stream *through* the worker (bounded, no OOM — not zero-touch; that would need ECS/DMS).
  Output is CSV (COPY-native) → CSV external tables, consistent with D-2. Parquet would need a streaming
  pyarrow writer (still bounded).
Supersedes the writer-based `query_export_to_s3` DAG (D-2) and the chunked DAG (D-1) for FanCash.
**Reader confirmed (2026-08-25):** the EXISTING `loyalty_postgres_dev` connection already lands on
the READER replica (`pg_is_in_recovery=True`) — so NO `_ro` connection is needed; COPY runs off the
reader on the current conn with zero writer load and zero new setup. (Earlier "writer" note was a
misread.) Perf-test DAG `loyalty_copy_to_s3_perf_test` built + reader-based; validate on Tier Points
(`program_id=2`) volume next. TODO: confirm prod `loyalty_postgres` is also a reader before cutover.

### D-4 (2026-08-25) — Isolate FanCash to its own path + tables (not shared)
Rather than overwrite the shared parquet `transaction`/`bucket`/`account_balance`/
`account_metadata` ext tables, FanCash gets full isolation:
- COPY loader (`loyalty_fancash_copy_to_s3`) writes CSV to **`loyalty_fancash/<table>/`** (own prefix).
- New **`fancash_<table>_ext`** CSV external tables (create_tables) read that prefix — CSV in dev AND prod.
- Shared `*_ext` tables + create_tables `file_format` param **reverted to parquet** — One Credits / Tier
  Points stay on their current parquet ingest, converted to COPY later when convenient.
Benefits: non-destructive (no dev S3 to clear), prod-safe, reversible, clean prod cutover (deploy the
fancash DAG + fancash ext tables; other programs untouched). PR #2338 @ 2cf04b5a.
**Open:** (a) satellite tables — the fancash ledger also needs `capture_event` (+ maybe allocation/
void_auth_event), which have NO program_id and are EMPTY in dev (OC/tier don't ingest in dev); decide
whether to pull them (unfiltered) into `loyalty_fancash/` + fancash ext tables. (b) AE must point the
FanCash ledger at `fancash_*_ext`. (c) `loyalty_postgres_test` (QC) reachable from dev MWAA?

### D-5 (2026-08-26) — POC loader works; current behavior = manual full-table pull
`loyalty_fancash_copy_to_s3` as it stands: **manual** (`schedule_interval=None`), pulls the **whole
`program_id=1` slice** per run (no time window unless `min`/`max` conf passed), one COPY per table →
one CSV object per table (parts only kick in past 64 MB). Validated in dev against QC 2026-08-26.
This is a proof-of-concept, NOT the production shape. **Formalization (Task 3, next session):**
- Add a **schedule** + **incremental window** (created_at for transaction, updated_at for the mutable
  tables, with a lookback) — mirrors the OC/Tier hourly pattern.
- **Dedup**: incremental appends new dated CSV files to `loyalty_fancash/<table>/`; the ext table's
  PATTERN reads them all → duplicates for updated rows. Resolve via downstream
  `QUALIFY ROW_NUMBER() OVER (PARTITION BY <pk> ORDER BY upload_ts DESC)` (ext table already has
  `upload_ts`), or AE native incremental-merge SOURCE tables.
- Initial historical / big backfill: **time-slice** via `min`/`max` (restartable; each slice its own file).
Env note: QC conn (`loyalty_postgres_test`) currently authenticates as `loyalty_engineer_rw` (works;
reader blocks writes). account_metadata has 0 program_id=1 rows in QC.

### D-6 (2026-08-26) — Airflow owns ext + native Snowflake table per table; MERGE dedupes. Add `allocation`.
**Supersedes the D-5 "dedup lives downstream in the AE ledger" direction.** New target architecture,
confirmed by the engineer: for **each** ingested table, fes-airflow maintains BOTH
- the `fancash_<table>_ext` **external** table (reads the accumulating dated CSVs), and
- a corresponding **native** Snowflake table (one native per ext),

and runs a **`MERGE`** (ext → native, keyed on the table PK, dedupe on `upload_ts`) so the native
table is the deduped, self-healing source of truth. Dedup/incremental-merge therefore lives in the
**ingest pipeline (fes-airflow)**, NOT in the AE `loyalty_analytics_ledger`. (This mirrors the
self-healing intent of the Tier Points native SOURCE tables, but ownership sits with ingestion here.)
- **Schedule (chosen):** hourly, prod cron **`20 * * * *`** (offset from OC `:05` / Tier `:35`);
  dev stays `schedule_interval=None` (manual), like the other loyalty DAGs.
- **Sequencing (engineer directive):** **FIRST** add the `allocation` table to the pull; THEN build
  the incremental window + native-table/MERGE layer. Don't start incremental until allocation lands.

**`allocation` added to the loader (2026-08-26):**
- Cols (COPY order): `allocation_id, earn_transaction_id, consume_transaction_id, amount, loyalty_id, created_at`.
  No jsonb. PK = `allocation_id`. Incremental col = `created_at` (append-only, no `updated_at`).
- **No `program_id`** → ingested **unfiltered** (all programs). Loader now has `PROGRAM_SCOPED_TABLES`
  = {transaction, bucket, account_balance, account_metadata}; the `program_id=1` filter is applied
  ONLY to those. `allocation` (and any future satellite) is pulled whole.
- `allocation` is a **partitioned** parent (`allocation_YYYY_MM` + `allocation_default`); COPYing the
  parent reads all partitions — no per-partition logic needed. (Same is true of `transaction`.)
- New ext table `create_fancash_allocation_ext.sql` (CSV, `loyalty_fancash/allocation/`). `DEFAULT_TABLES`
  now 5 tables. DAG parses clean. **Not deployed/committed yet.**

**Still open (satellites):** `capture_event` and `void_auth_event` (both no program_id, both jsonb
`metadata`, PK `transaction_id`) — the ledger may also need these. Confirm with the engineer whether to
add them alongside `allocation`. `auth_hold`/`auth_bucket_hold`/`void_remaining`/`allocation_remaining`
also exist but are likely balance-mechanics, not ledger inputs.

### D-7 (2026-08-26) — Unify ALL loyalty-Postgres ingestion into one COPY-stream DAG; Airflow owns native+MERGE (Scope B)
Engineer decision: replace the per-program extraction DAGs (OneCredits `loyalty_postgres_to_s3_ingest`,
Tier Points `loyalty_postgres_tier_to_s3_ingest`, and the FanCash `loyalty_fancash_copy_to_s3`) with a
**single unified COPY-stream DAG** over the loyalty Aurora reader, for **all three programs at once**.
Tier Points needs to switch ASAP; the COPY stream handles FanCash's eventual volume with flat memory.

**Scope = B (full ownership move):** Airflow owns, per source table, the **CSV external table AND a
deduped native Snowflake table maintained by MERGE**. This RETIRES the dbt loyalty **source layer**
(~20 incremental+QUALIFY models: `loyalty_transaction`, `bucket`, `account_balance`, all legacy, `tier_*`)
and repoints both ledger stacks (`one_credits_loyalty_analytics_ledger` @ program_id=3,
`tier_points_ledger_core` @ program_id=2, and the future FanCash ledger @ program_id=1) at the
Airflow-owned native tables. **Chosen over Scope A** (extraction-only, keep dbt dedup) despite being the
larger migration — the engineer wants the complete "everything in Airflow" end-state.

**Design (registry-driven):**
- One `LOYALTY_TABLES` registry (built from the 2026-08-26 QC schema-discovery dump) holds per table:
  column list + order, PK, incremental col, jsonb→text cols, and `program_scoped` flag. The DAG GENERATES
  the COPY SQL, the CSV `_ext` DDL (positional value:cN), the native-table DDL, and the MERGE from it.
- **Full unfiltered pulls** (no per-program WHERE): COPY streaming is memory-bounded, so the OOM constraint
  that forced the OC STOPGAP (program_id=3 pin) and Tier's 250k chunking **goes away**. Programs separate
  downstream by `program_id` (already a column). Satellites (allocation/capture_event/void_auth_event/…)
  have no program_id and come in whole — same code path.
- **Self-seeding incremental (engineer insight):** the incremental window is keyed off the **native table's
  own MAX(watermark) − lookback**; an empty native table ⇒ unbounded window ⇒ full seed on first run, then
  incremental. No separate backfill job — the DAG's normal operation converges the native table. Same
  self-healing shape as the Tier dbt models' `MAX(upload_ts)−lookback`.
- **Dev/prod per-program is automatic:** a full pull ingests whatever's present. QC/dev already has FanCash
  (program_id=1); prod has OC+Tier now and FanCash rows simply appear when the loyalty service starts
  writing program_id=1 to prod PG. Same DAG, no go-live code change.

**Cutover = parallel-run then flip, Tier first (safe):** unified DAG writes to a NEW prefix + NEW native
tables alongside the current parquet pipeline. Validate row/dedup parity, then a coordinated dbt PR
repoints downstream (Tier first, OC right after) and retires the old chunked DAGs + parquet `_ext` tables.

**Hard dependency:** the other AE must sign off on retiring the dbt source layer / superseding the in-flight
Tier native-SOURCE models before the flip.

**Out of scope:** Bonus-Engine (`fes-loyalty-bonus`) and Partnerships (`fes-partnerships`) DAGs — they pull
from DIFFERENT source databases, not the loyalty Postgres.

**Supersedes** the FanCash-only D-4/D-5/D-6 direction (FanCash is now just program_id=1 inside the unified
DAG). The `loyalty_fancash_copy_to_s3` loader + `fancash_*_ext` tables become the prototype the unified DAG
generalizes. New work goes on a fresh fes-airflow branch off main.

### D-8 (2026-09-03) — Merge to prod TODAY as an isolated parallel-run (bounded seed, no dbt trigger)
Goal: get `loyalty_postgres_unified_to_s3` into prod today, running **isolated in parallel** with the live
pipeline for a few days, then flip. Merging PR #2342 to main IS the deploy (CI `sync_files` builds the 24
`_uni_ext` via create_tables in dev+prod; the DAG runs `20 * * * *` in prod). Isolation makes this low-risk:
writes only to the NEW `loyalty_source/` prefix + `_uni`/`_uni_ext` objects; the current parquet pipeline and
dbt-owned `SOURCE.<t>` are untouched.

Safety changes made for the immediate prod run (commit dc8079ad):
- **Bounded first seed** — empty native pulls only `DEFAULT_SEED_LOOKBACK_DAYS` (7d), NOT all history, so the
  automated first run can't hit S3's 10k-part-per-object cap on huge prod tables (transaction/loyalty_account).
  The parity check self-adjusts (bounds both sides to native MAX). **Full historical seed is a SEPARATE,
  deliberate op**: trigger with explicit `{"min","max"}` slices per big table (added that path).
- **No dbt trigger** — removed `create_dbt_cloud_task_group`; nothing downstream reads `SOURCE.<t>_uni` yet, so
  the pipeline is fully self-contained (extract → merge → compare_counts). dbt repoint is a separate PR at cutover.
- **retries=2 + max_active_tasks=8** (cap concurrent COPYs off the reader).

**First-run watch items (rollback = pause the DAG; nothing to clean up since isolated):**
- Confirm prod `loyalty_postgres` is a **reader** — the DAG logs `pg_is_in_recovery()` on first run. If it's the
  writer, pause + repoint to a reader conn. (COPY is read-only, so even the writer is only read load — low risk.)
- Watch `compare_counts` parity (WITHIN_TOL/MATCH) over the parallel-run days.

### D-9 (2026-09-04) — REDUCE SCOPE to extraction-only (Scope A): COPY→CSV→`_uni_ext`; dbt keeps the dedup
**Supersedes the native-table + MERGE half of D-6 / D-7 / D-8.** The unified PR (#2342) did two things:
(1) switch extraction to streaming COPY + new CSV external tables, and (2) move dedup into Airflow via
native `SOURCE.<t>_uni` tables + MERGE. **We are cutting (2).** The DAG now ONLY dumps CSVs to the isolated
`loyalty_source/` prefix and refreshes the `SOURCE.<t>_uni_ext` external tables on top; **the existing dbt
loyalty source layer keeps doing the dedup** (incremental + `QUALIFY ROW_NUMBER() OVER (PARTITION BY pk
ORDER BY upload_ts DESC)`), exactly as it does today for OC/Tier and as the merged bonus-engine DAG
(**#2347**, `loyalty_bonus_postgres_to_s3_ingest`) does in prod.

**Why:** eliminates the entire "which MERGE pattern / how to make the native registry compact" question;
keeps the ingest change small, reversible, and identical in shape to a DAG already proven in prod; and
leaves the dbt-owned dedup contract unchanged so the eventual flip is a same-shape **source repoint**
(parquet `SOURCE.<t>_ext` → CSV `SOURCE.<t>_uni_ext`), not an ownership move.

**Reduced DAG shape** (mirrors `loyalty_bonus_postgres_to_s3_ingest` @ origin/main):
`get_backfill_flag >> copy_table.expand → refresh_ext.expand → compare_counts`.
- **Window** (replaces the native watermark): conf `min`/`max` > backfill flag (full) > scheduled interval
  `[data_interval_start − 30s, data_interval_end)`. Extract makes **zero** Snowflake calls.
- **refresh_ext**: targeted `ALTER EXTERNAL TABLE <t>_uni_ext REFRESH '<dt=ds/>'` so the isolated ext tables
  are queryable during the parallel-run (nothing reads `_uni_ext` yet). At cutover dbt's pre_hook refreshes
  and this task can be dropped.
- **compare_counts**: PG distinct-PK vs `_uni_ext` distinct-PK, both bounded to the ext table's own
  MAX(incr_col) (ext accumulates a dated file per run → dupes, so DISTINCT on both sides). Warns, never fails.

**Removed from the PR** — DAG: the `merge` task (MERGE + native COUNT), the `create_native_sql`/`watermark_sql`
calls and native-watermark + bounded-seed branches in `extract`, the native seed constants. Config:
`native_column_defs`, `create_native_sql`, `watermark_sql`, `merge_sql`, `native_fqn`, `business_col_names`,
`NATIVE_SUFFIX`. **Kept:** the 24 `create_*_uni_ext.sql` external tables (the deliverable), the COPY loader,
the registry (column order/types drive COPY + ext DDL), `pk`/`pk_distinct_count_expr` (parity only).

**Parallel-run intent unchanged:** dump to the isolated `loyalty_source/` prefix + `_uni_ext` tables, eyeball
output for a few days, THEN a coordinated dbt PR repoints the source models onto `_uni_ext`. Flip order
Tier → OC → FanCash as before.

### D-10 (2026-09-08) — incr_col policy: prefer `updated_at` where it exists; two switches pending prod schema
**Policy:** the incremental column should be `updated_at` whenever the table has one (mutable-safe — an
in-place update bumps `updated_at`, so the row re-pulls and dbt keeps the latest by `upload_ts`); append-only
tables use `created_at`. The config already satisfies this for prod's schema **today** — verified there is no
table where prod has `updated_at` but we still key on `created_at`.

**Two follow-ups, gated on loyalty catching prod up to the lower envs** (dev has these columns, prod does not
yet — confirmed via the 2026-09-08 schema_discovery dumps). No failure risk now; both are correctness fixes:
- **`auth_bucket_hold`** — currently `incr_col=created_at`. When prod adds `updated_at`, switch to `updated_at`
  (add it to `cols` + regen `create_auth_bucket_hold_uni_ext.sql`). Needed **iff the table is mutable** (rows
  updated in place); if append-only, `created_at` is fine. **Confirm mutability with loyalty.**
- **`transfer_restriction`** — currently `incr_col=starts_at` (its only timestamp today; `starts_at` is a
  business date, not a write-time watermark). When prod adds `created_at`, switch to `created_at`.

Guard: `test_cols_match_ext_ddls` keeps `cols` ⇄ ext-DDL aligned, so any such switch is a config + DDL change
made together.

## Open Questions
- **OQ-1 — `transaction_id` transform (backfill):** ticket marks the `loyalty_txn_id → transaction_id`
  rule TBD. What transformation is required?
- **OQ-2 — Final reason-code list:** map scylla `loyalty_txn_reason_desc` → new reasons
  (Confluence 2771091472). Owners: Will Mack / Christine Nichols.
- **OQ-3 — S3 format for ~2B rows:** ticket says format TBD; how do the Loyalty engineers want
  ~2B transactions delivered for the PG backfill?
- **OQ-4 — `loyalty_id` resolution:** "pre-resolved in the export" — what step resolves
  `loyalty_account_id → loyalty_id`? Does FanCash need the same de-collide identity map Tier Points used?
- **OQ-5 — Dev FanCash coverage:** which/how many FanCash rows exist in dev PG, and are they
  representative enough to validate the mapping?
- **OQ-6 — dbt ledger coordination:** which AE owns the FanCash `loyalty_analytics_ledger` rewrite,
  and what ingestion contract do they need from us?
- **OQ-7 — FanCash table set (confirm D-1 superset):** DAG pulls `transaction` + `bucket` +
  `account_balance` + `account_metadata` @ program_id=1. The OC ledger draft only reads
  `transaction` (+ non-program `capture_event`). Confirm with the ledger AE whether bucket/
  account_balance/account_metadata are actually consumed for FanCash, or trim to just `transaction`.
- **OQ-8 — loyalty_id source (Slack C0BPV01HBKL, p1787172654234739):** thread on where to find the
  `loyalty_id`. Relevant to the backfill's `loyalty_account_id → loyalty_id` resolution (OQ-4) and
  to keying the dev-vs-legacy comparison. Read/attach the thread next session.
- **OQ-9 — dev validation:** dev PG has both un-prefixed and `test_`-prefixed tables; trigger the
  new DAG in dev (schedule is None) and compare ingested program_id=1 rows vs legacy Salesforce ledger.

### D-11 (2026-09-30) — Downstream dbt: native `_uni` source tables + dual-write parallel run (dbt-fes-ae PR #260)

The dbt cutover that D-9 deferred to "a coordinated PR" landed on Sean McClure's **PR #260**
(`sm/migrated-loyalty-ledger`), which rebuilds the FanCash ledger on the `_uni_ext` landing. My contributions:

- **Native source layer:** query the CSV `_uni_ext` externals ONCE via native dbt tables
  `{transaction,allocation,capture_event,void_auth_event}_uni` (incremental MERGE on PK, `upload_ts` watermark,
  QUALIFY dedup), NOT repeatedly — CSV externals are slow (no stats/pruning; transaction ≈237GB / 390M rows).
  The ledger reads `ref('<t>_uni')`. Source tables keep the `_uni` suffix, NO `dual_write_` prefix (suffix
  already separates them from the live `_ext`/native tables).
- **Dual-write:** the `_core` ledger models build to `dual_write_<name>` tables under `dual_write/` folders,
  tagged `daily` + `fancash_dual_write`, so they run in parallel and NEVER overwrite live models. Naming done by
  FILE RENAME (not an alias macro — that was judged over-engineered; renamed files make the temp models obvious).
  tags/enabled set FOLDER-LEVEL in `dbt_project.yml` via `fancash_dual_write_enabled` (default true). Cutover =
  drop the `dual_write_` prefix + move files out of `dual_write/`.
- **`full_refresh_prevention` prod-gated:** CI runs `--full-refresh` and the guard hard-raises under it, so it
  must be `{% if target.name == 'prod' %}`-gated or CI fails on any fresh build of these new models.

**Why:** decouples the slow CSV landing from the ledger (native tables are fast), lets the new ledger run daily
for parity against live with zero risk, and makes the temporary models obvious on disk. Supersedes nothing in
D-9/D-10 (airflow-side extraction is unchanged); this is the consuming dbt layer.
