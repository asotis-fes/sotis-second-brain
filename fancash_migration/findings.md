# Findings

## 2026-08-21 — Ingestion architecture (fes-airflow `dags/loyalty/`)

The new-backend PG→S3→Snowflake ingest is a **fleet of extract-only DAGs**, one per
program while each migrates in parallel, all writing parquet to the **same S3 prefix**
`loyalty_postgres/<table>/dt=.../` that the Snowflake external tables read. The shared
loyalty **dbt Cloud** job (triggered by the OneCredits DAG) rebuilds staging over the
unioned rows. De-dup is downstream via `QUALIFY ROW_NUMBER() … ORDER BY upload_ts DESC`.

- **`loyalty_postgres_to_s3_ingest.py`** (OneCredits, `program_id=3`) — the main DAG.
  Runs `:05`, catchup, triggers dbt Cloud + `compare_row_counts`. Ingests
  `POSTGRES_TABLE_CONFIGS_ACTIVE` (legacy) + `OC_POSTGRES_TABLE_CONFIGS` (bucket model).
  **STOPGAP filter**: `PROGRAM_FILTERED_TABLES = {bucket, account_balance, transaction}`
  restricted to `ONE_CREDITS_PROGRAM_ID = 3`. Non-program tables ingested in full.
- **`loyalty_postgres_tier_to_s3_ingest.py`** (Tier Points, `program_id=2`) — runs `:35`,
  extract-only (no dbt trigger), chunked via `build_chunk_specs`. Pulls shared
  `transaction` + `account_metadata` (program-scoped) + 5 tier satellite tables.
- **`loyalty_bonus_postgres_to_s3_ingest.py`** / **`partnerships_postgres_to_s3_ingest.py`**
  — separate bonus-engine / partnerships PG sources.
- **`loyalty_postgres_backfill.py`** — manual, chunked, general-purpose. Already supports
  FanCash: `{"table":"transaction","program_id":1,"column":"created_at","min":..,"max":..}`.
  Use for historical/backdated rows outside the hourly window. REFRESH the ext table after.
- **`loyalty_postgres_schema_discovery.py`** — read-only `information_schema` dump.

### Why FanCash (program_id=1) is ingested by NOTHING today
The OC STOPGAP pins `transaction`/`bucket`/`account_balance` to `program_id=3`; the tier
DAG only pulls `program_id=2`. So program_id=1 rows for those shared tables land nowhere.
`account_metadata` is pulled only by the tier DAG (program_id=2). → **new DAG needed.**

### What the analytics ledger actually reads (program-scoped)
OC ledger v2 draft (`../loyalty_new_service/ledger_v2_draft.sql`) builds off **`transaction`**
(`WHERE program_id = 3`) + `capture_event`. `capture_event` (and the other bucket-model
satellites: allocation, auth_hold, void_auth_event, void_remaining, allocation_remaining,
auth_bucket_hold, bucket_type, transfer_restriction) have **no program_id** and are already
ingested in FULL by the OC DAG — so FanCash rows are already present for those. FanCash only
needs the **program-scoped** shared tables pulled for `program_id=1`.

## Dev PG schema (conn `loyalty_postgres_dev`, 93 tables) — key shapes
Full dump saved from `loyalty_postgres_schema_discovery` (2026-08-21). Highlights:
- Dev PG has BOTH the un-prefixed prod-shape tables (`transaction` + monthly partitions
  `transaction_YYYY_MM`, `bucket`, `account_balance`, `account_metadata`, `allocation`…)
  AND the older `test_`-prefixed sandbox tables. The **un-prefixed** tables are the live shape.
- `transaction` (22 cols): `id, transaction_id, program_id, loyalty_id, type, amount,
  bucket_id, entry_type, campaign_code, expires_at, available_at, external_id, actor, reason,
  site_id, tenant_id, ref_id, ref_id_type, metadata(jsonb), jurisdiction,
  reversed_transaction_id, created_at`. Range-partitioned by `created_at`. `reason` is `text`
  (in the shared `transaction`; note `test_transaction.reason` is a USER-DEFINED enum).
- `account_balance` (8): id, loyalty_id, program_id, available, pending, maturing, updated_at, lifetime.
- `account_metadata` (6): id, loyalty_id, program_id, metadata(jsonb), created_at, updated_at.
- `bucket` (11): bucket_id, bucket_type_id, loyalty_id, program_id, expires_at, available_at,
  is_matured, available_balance, pending_balance, created_at, updated_at.
- `tp_migration_account` / `tp_migration_batch` present = tier-points migration scaffolding.

## DAG created
`fes-airflow/dags/loyalty/loyalty_postgres_fancash_to_s3_ingest.py` — see `decisions.md` D-1.
Imports clean (`FES_ENVIRONMENT=dev PYTHONPATH=dags`), dag_id `loyalty_postgres_fancash_to_s3_ingest`,
tasks: `get_backfill_flag` + `plan_/load_` × {transaction, bucket, account_balance, account_metadata}.

## Aurora reader/writer — endpoint check (2026-08-25, CORRECTED)
Ran `loyalty_postgres_endpoint_check` in dev → **`loyalty_postgres_dev` lands on the READER
replica**: `pg_is_in_recovery=True`, `transaction_read_only=on`, server_addr `10.58.40.142`,
Aurora PG 17.7. (An earlier note in this file said "writer" — that was a misread; the log is
unambiguous: `-> READER replica`.)
**Implication:** the existing Airflow connection already reads off the reader — **no `_ro`
connection needed**, nothing to set up. The streaming-COPY approach (D-3) runs off the reader on
`loyalty_postgres_dev` today with **zero writer load and zero new config**. The perf-test DAG
`loyalty_copy_to_s3_perf_test` defaults to this conn, so it's already reader-based.
TODO: confirm prod `loyalty_postgres` is likewise a reader before prod cutover (run the check in prod).

## 2026-08-28 — FanCash ledger data sources: Scylla vs fanflow vs Postgres (dbt-fes-ae)
Traced `models/loyalty/fancash/`. See memory `reference_fancash_scylla_vs_fanflow_sources`.
- **Core ledger** `ledger/loyalty_analytics_ledger_stage.sql`: daily incremental reads **fanflow**
  `fanflow__account_events.loyalty_transaction_successful__account` (line 34). Scylla refs
  (`loyalty_transaction_raw` line 80; `duplicate_bfc_add_events` lines 108/147) are all inside
  `{% if not is_incremental() %}` → **full-refresh history only** (pre-2025-12-31); steady state = fanflow.
- **Redeem matching / earn_burn_mapper**: fanflow (`new_ledger_txn`) + intermediate state in
  `LOYALTY.SOURCE` (unconnected_earn/burn, redeem_ledger_processed). **Zero Scylla.**
- **Bonus FanCash (Scylla) = the ONLY live Scylla source**, `ledger_upstream/bonus_fancash.sql`
  ← `loyalty__loyalty_stage.BONUS_FANCASH_INCREMENTAL`. **BUT it does NOT feed the analytics ledger** —
  it feeds the **BALANCE / 360 / expiry** layer only (`loyalty_balance_stage.sql:93`,
  `loyalty_balance_monthly_snapshot.sql:16`, `fbg_bonus_fancash_expired*`, `loyalty_360_pfi`,
  `fancash_360_upstream`, `pfi_fanatics_one_attributes`). Bonus *activity* reaches the ledger only via
  fanflow (bonus ADD events are normal loyalty txns, tagged `loyalty_txn_add_type`).

**CORRECTION 2026-09-01 (user): "bonus fancash" ≠ "bonus engine".** Bonus engine = `fes-loyalty-bonus`
(promotional bonuses; separate PG/DAG, now COPY→CSV, live in prod). **Bonus FanCash is being DEPRECATED,
not repointed** — "FanCash with expiry" is served natively by the loyalty Postgres bucket model
(`transaction`/`bucket` `expires_at`), i.e. the tables THIS unified pipeline ingests.

**Retiring Scylla for FanCash — two tracks, both tied to THIS migration:**
1. **Ledger** → the **ENTDATA-2021 historical backfill** (Scylla→PG `transaction`) so the full-refresh
   history branch is no longer Scylla-backed. This is Task 2.
2. **Balance layer** (live bonus-fancash Scylla dep) → retires when balance/ledger models repoint off
   `BONUS_FANCASH_INCREMENTAL` onto the new `bucket`/`transaction` (expires_at) data from THIS pipeline.
   No bonus-engine involvement.
=> This unified pipeline is the enabler for killing the bonus-fancash Scylla leg (via the new bucket
model); the ENTDATA-2021 backfill covers the ledger-history leg.

## 2026-08-27/28 — Unified PR review outcomes (branch `loyalty/unified-postgres-ingest`)
- **PK QA PASSED**: all 24 chosen unique keys verified `dupes=0` in QC (incl. partitioned
  `transaction.transaction_id`, `allocation.allocation_id`). No registry changes. incr_col
  mutable/immutable split confirmed correct for all 24 (mirrors prod `configs.py`).
- **Parity task hardened** (`compare_counts`): bounds both sides to native `MAX(incr_col)` (no post-COPY
  false-alarms), 1% tolerance, per-table try/except, empty-native skip. **Uncommitted** on the branch —
  draft PR #2342 still shows pre-review version.
- **Still-deferred (not dev-test blockers, pre-prod/cutover):** native-table GRANTs (downstream read),
  prod seed time-slicing (S3 10k-part cap on huge full seeds), retries, concurrency pool, in-repo runbook,
  import test. Hard-delete propagation is a documented non-goal (parity with current dbt incremental).

## 2026-09-08 — Prod schema readiness for the unified ingest (verified)

Ran `loyalty_postgres_schema_discovery` on **prod + dev** and diffed against `loyalty_unified_config.py`.

**Result: prod is ready — no COPY failure.** Programmatically confirmed every `cols` column AND every
`incr_col` exists in all 24 prod tables. Notes:
- Column-order differences between our `cols` and prod are irrelevant — COPY selects by name.
- `transaction`/`allocation` are range-partitioned in prod (`_2025_05 … _2027_03`, `_default`); `FROM <parent>`
  reads all partitions.
- Prod correctly lacks the excluded tables' relevance: `entry`, `journal`, `idempotency_keys`, `job_queue`,
  `program_account_override`, `reason_config`, `schema_migrations` are present in PG but not in our 24.
- Prod uses the un-prefixed tables (`transaction`, …). The `test_*` tables exist only in dev — we never touch them.

**Dev-ahead-of-prod diff (loyalty's in-progress mutable-table work):** dev has columns prod does NOT yet:
- `auth_bucket_hold.updated_at` (dev) vs prod `created_at` only.
- `transfer_restriction.created_at` (dev) vs prod `starts_at, ends_at` only.
We key those on `created_at` / `starts_at` respectively, so no failure now. When prod catches up, switch their
`incr_col` per **D-10** (auth_bucket_hold → updated_at only if mutable; transfer_restriction → created_at).
Verified there is NO table where prod already has `updated_at` but we still key on `created_at`.

## 2026-09-30 — Where the full FanCash ledger data from Scylla lives

- **Historical (pre-fanflow) ledger source = `loyalty_transaction_raw`** (dbt model in
  `models/loyalty/fancash/ledger_upstream/`) → native `LOYALTY.LOYALTY_CORE.LOYALTY_TRANSACTION_RAW`, fed by
  external `LOYALTY.LOYALTY_STAGE.LOYALTY_TRANSACTION_RAW` over S3
  `@FANATICS_PROD_INTERNAL_REGULATED/fdsloyalty/scylla_replication/pub…` (parquet, partitioned by creation_date).
  Materialized (NOT S3-only), tag `loyalty_6hours`, `ALTER EXTERNAL TABLE … REFRESH` pre_hook.
- **Still live + current:** 6,765,866,168 rows, creation_time 2021-01-08 → today; refreshed every ~6h. Scylla
  replication kept running in parallel even after the fanflow cutover.
- **Ledger usage:** `loyalty_analytics_ledger_stage.sql` UNIONs it ONLY on full-refresh
  (`{% if not is_incremental() %}`, WHERE creation_time BETWEEN 2021-12-31 AND 2025-12-31). Incremental runs read
  fanflow (`ref('loyalty_transaction_successful__account')`, creation_time ≥ 2026-01-01).
- **bonus_fancash** (`BONUS_FANCASH_INCREMENTAL`, LOYALTY_STAGE) is the other live Scylla leg (balance layer).
- It is ALL loyalty transactions (all programs), not fancash-only — filter by program/txn attrs. Memory:
  `reference_fancash_scylla_vs_fanflow_sources`.

## Loyalty Aurora + loyalty-owned S3 facts (salvaged from the retired aurora_export_plan.md, confirmed 2026-08-25)

Kept for the **ENTDATA-2021 backfill (Task 2)**, which delivers Scylla history to the loyalty-owned
bucket for the Loyalty team. The D-2 Aurora-native `query_export_to_s3` design these came from is dead
(ruled out by D-3 — writer-only; the live unified pipeline instead writes to our own
`fes-integrations-<env>` bucket). Confirmed from **fanapp-terraform**:
- **Loyalty DB** = Aurora **PostgreSQL 17.7** (`modules/rds-aurora-postgres`, prod `db.r6g.12xlarge`).
- **Loyalty-owned bucket** = `fes-loyalty-<env_name>` (`root/fes/loyalty/s3.tf`), region **us-east-1**.
  `env_name`: dev=`fanapp-dev-1`, perf=`fanapp-perf-1`, prod=`fanapp-prod-1` → dev bucket
  `fes-loyalty-fanapp-dev-1`, prod `fes-loyalty-fanapp-prod-1`. Already used for the Tier Points
  migration under the `tp_migration/` prefix.
- **Snowflake** reads that bucket via role `fes-loyalty-snowflake-s3-<env>-migration` (external-id
  storage integration), scoped to `tp_migration/*` today — would need widening for any new prefix.
- **Gap (why Aurora-native export was a non-starter):** the cluster has **no `s3Export` role
  association** and `aws_s3` extension isn't confirmed enabled; `query_export_to_s3` is also
  writer-only. Hence the streaming `COPY … TO STDOUT` off the reader (D-3), which needs none of that.

## 2026-09-30 — `_uni_ext` CSV externals are slow to query (by design) + prod full-refresh runbook

Querying `LOYALTY.SOURCE.<t>_uni_ext` is very slow: CSV = row-oriented, UNCOMPRESSED, no min/max stats → every
query full-scans + parses all files (transaction ≈237GB / 390M rows, landed as 5 date-window files from a
chunked backfill). Parquet `_ext` was fast (columnar + row-group stats + pruning). Fix: don't query the CSV
landing interactively — dbt materializes native deduped tables (the `_uni` models, D-11); query those.

**Full-refresh of the 24 prod `_uni_ext` (Snowflake REMOVE route):**
1. `LIST @fes_integrations.stage.fes_integrations_prod_stage/loyalty_source/;` (preview)
2. `REMOVE @fes_integrations.stage.fes_integrations_prod_stage/loyalty_source/<table>/;` per table (or whole prefix)
3. Trigger `loyalty_postgres_unified_to_s3` with conf `{"loyalty_postgres_unified_backfill": true}`
4. `ALTER EXTERNAL TABLE LOYALTY.SOURCE.<table>_uni_ext REFRESH;` (whole-table, to drop removed-file metadata)
The `loyalty_source/` prefix is EXCLUSIVE to the unified pipeline (live parquet = `loyalty_postgres/`, bonus =
`loyalty_bonus_postgres/`, partnerships = `partnerships_postgres/`) — REMOVE won't touch them. `transaction` is
390M rows / 16 months (append-only, incr_col=created_at); if a single COPY is too slow, chunk by `created_at`
windows via conf `min`/`max` (max_active_runs=1 → chunks run sequentially, restartable).
