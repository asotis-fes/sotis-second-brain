# Progress log

## Open action items
- **[OPEN] Partition the `_uni_ext` external tables.** Add `PARTITION BY (upload_date)` (already
  derived from the `dt=<run_date>/` path) so the dbt incremental's `upload_ts >= MAX-2h` predicate
  prunes to recent run-date partitions instead of full-scanning ~237 GB every hour. **Must stay CSV**
  (the Aurora `COPY … TO STDOUT` → S3 produces CSV; Parquet would break the bounded-memory streaming
  writer). A `created_month` (data-date) partition would need files physically re-laid-out by
  `created_at` — deferred; route ad-hoc analytics to the native `_uni` tables instead. DDL-only change
  + matching dbt predicate tweak.
- **[OPEN] Missing-burn freshness gap (2026-10-05, Zoe EBM parity).** 296 burns absent from the new
  source, ALL `burn_second` in 2026-10-01→10-05 (last 5 days, concentrated 10-03/10-04), `NEW_AMT=0`
  for all ($730.28 old-side), 296 distinct accounts (~1 each), `NEW_MIGRATION_SLICES=0` (organic, not
  migration). This is a RECENT/tail gap — distinct from the two 2026-09-10 pre-migration UUIDs. Two
  candidate causes to split: (a) dual-write (`FcDualWriter`) failing to persist these burns to PG
  → upstream service bug (cf. the `tenantId()=null` capture failures, site_id=515621); (b) our
  incremental not capturing recent burns (reader-lag/window — PR fes-airflow#2387 lookback helps, but
  a 5-day-persistent miss argues against pure lag). TEST: check a sample of these order_ids in PG; if
  present in PG but not `transaction_uni_ext` → ours; if absent from PG → upstream dual-write.

## 2026-08-21 — Session 1 (scaffold)
- Created `projects/fancash_migration/` workspace from the framing prompt.
- Oriented on sibling migrations: OneCredits (`loyalty_ingest_migration`, prod-live),
  Tier Points (`loyalty_tier_points_migration` + `..._s3_parallel_processing_data_dump`).
- Fetched ENTDATA-2021 → captured the full Scylla → PG `transaction` column & status mapping
  in `backfill_mapping.md` (load-bearing for Task 2).
- Established: FanCash = `program_id = 1`; scope = **ingestion only** (dbt ledger owned by
  another AE); Task 1 (dev ingest to learn data shape) is the first step.
- **Next:** Task 1 — inspect dev PG FanCash tables and the current `configs.py` wiring.

## 2026-08-21 — Session 1 (cont.) — FanCash ingest DAG built
- Confirmed **program_id=1 is ingested by nothing**: OC DAG STOPGAP pins transaction/bucket/
  account_balance to program_id=3; tier DAG pulls program_id=2 only. (`findings.md`)
- Read the DAG fleet: OC main (`loyalty_postgres_to_s3_ingest`), tier
  (`loyalty_postgres_tier_to_s3_ingest`), backfill, schema-discovery, bonus, partnerships.
- Captured the full dev-PG schema dump (93 tables) + the analytics-ledger source set in `findings.md`.
- **Created `fes-airflow/dags/loyalty/loyalty_postgres_fancash_to_s3_ingest.py`** (cloned from tier
  DAG), ingesting transaction/bucket/account_balance/account_metadata @ program_id=1. Imports clean
  under the tox env. Decision + rationale in `decisions.md` D-1. Branch: `tiger/capi-firebase-export`
  (⚠ not a fancash branch — see below).
- **Next:** trigger the DAG in dev, land program_id=1 parquet, compare vs legacy ledger (OQ-9);
  confirm table set with ledger AE (OQ-7); resolve loyalty_id source from Slack (OQ-8).

## 2026-08-25/26 — Sessions 2-3 — Pivoted to streaming COPY-from-reader; working in dev

**Big pivot (see decisions D-2..D-4):** dropped the chunked parquet DAG for FanCash. FanCash
volume is too big for `SqlToS3Operator` (pandas DataFrame per chunk → O(N) memory; benchmark in
`memory_benchmark.md` = ~15 GB at 5M rows). Went to **streaming `COPY (SELECT … program_id=1)
TO STDOUT` from the Aurora READER → S3 multipart** — flat/bounded memory (~180-380 MB at any size).
Ruled out `aws_s3.query_export_to_s3` (writer-only; we require no-writer-load) and RDS cluster/snapshot
export (full-table, no filter). Reader is grant-free: COPY-to-STDOUT needs only SELECT.

**Architecture now (all in PR #2338, branch `fancash/postgres-ingest`):**
- `dags/loyalty/loyalty_fancash_copy_to_s3.py` — the loader. Manual, streams the 4 program-scoped
  tables (transaction/bucket/account_balance/account_metadata) @ program_id=1 → **CSV** under
  `s3://fes-integrations-<env>/loyalty_fancash/<table>/dt=<ds>/<table>_<ts>.csv`. Default part 64 MB
  (→ ~1.15B rows/object under S3's 10k-part cap). Logs host/current_user/reader flag + per-table rows.
- **Isolated from the shared pipeline (D-4):** new `fancash_<table>_ext` **CSV** external tables
  (`dags/create_tables/sql/loyalty/create_fancash_*_ext.sql`) read `loyalty_fancash/`; the shared
  `<table>_ext` stay **parquet** and OC/Tier stay on their current ingest. Non-destructive — no dev
  S3 wipe, no prod impact. Convert OC/Tier to COPY later when convenient.
- Diagnostics (also in PR): `loyalty_postgres_endpoint_check` + `loyalty_postgres_schema_discovery`
  both take a `{"conn_id": ...}` override and log host/port/dbname/login/current_user/reader flag
  (no secret). Removed: chunked FanCash DAG + writer-only `query_export_to_s3` DAG.

**Env / connection facts (nailed down this session):**
- `loyalty_postgres_test` = the **QC/test** env (loyalty engineer confirmed). DB `fes_loyalty`, on the
  Aurora **reader** via a VPC-Lattice RO endpoint (host `snra-…rcfg-041a5a38b3a8d568d…vpc-lattice-rsc
  .us-east-1.on.aws`; reader IP 10.58.104.110). `loyalty_postgres_dev` is also a reader.
- Perm fight: the conn authenticated as `data_ro_user` (no grants) → `permission denied`. Loyalty
  repointed it; it now logs in as **`loyalty_engineer_rw`** (RW user, works; writes blocked anyway on
  reader). Airflow conn secret = SSM SecureString **`/airflow/connections/loyalty_postgres_test`**
  (acct 010526250084, us-east-1), set via `fanapp-cluster-scripts` → `script_custom_ssm_set.yaml`.
- Alex has only ReadOnly SSO on 010526250084 (can't self-serve MWAA/SSM writes) — [[reference_aws_dev_compute_access]].

**✅ First successful dev run (2026-08-26):** loader pulled QC → transaction **1,891**, bucket 13,
account_balance 10, **account_metadata 0** rows; PEAK_RSS 180 MB. End-to-end path proven:
reader → COPY → CSV → S3, bounded memory, no shared-table disruption.

**Next (do NOT start until after /compact):**
1. Run `create_tables` (dev) → the 4 `create_fancash_*_ext` tasks; then the validation SELECTs
   (metadata_parsed/ts_parsed ≈ 1891 confirms CSV→VARIANT/timestamp casts work).
2. **Formalize the ingest** (Task 3 rewrite): schedule + incremental window (created_at/updated_at
   with lookback) + dedup — either downstream QUALIFY on `upload_ts`, or AE builds native
   incremental-merge SOURCE tables (like the tier native tables in this engineer's other work).
3. Decide **satellite tables** (capture_event, allocation, void_auth_event) — ledger needs them,
   they have no program_id (pull unfiltered into loyalty_fancash/ + fancash ext tables?). (OQ-7)
4. AE points the FanCash ledger at `fancash_*_ext`. account_metadata=0 — confirm if needed.
5. Prod cutover later: confirm prod `loyalty_postgres` is a reader; deploy loader + fancash ext
   tables to prod (they build in prod already — not `create_test_` prefixed).

## 2026-08-26 — Session 4 — PIVOT to UNIFY all loyalty ingestion (Scope B, decision D-7)

**Big scope change (see D-7):** FanCash-only work is subsumed into a **single unified COPY-stream DAG
for ALL programs** (OC=3, Tier=2, FanCash=1). Tier needs to switch ASAP; COPY handles FanCash volume.
**Scope B chosen:** Airflow OWNS the native Snowflake tables + MERGE (retires the dbt loyalty source
layer, repoints both ledger stacks). Cutover = parallel-run then flip, **Tier first**. Self-seeding
incremental: window keyed off native `MAX(incr_col)` − lookback (empty native ⇒ full seed; no backfill job).

**Discovery (Explore agent, this session):** current OC DAG `loyalty_postgres_to_s3_ingest` (SqlToS3,
parquet, `loyalty_postgres/` prefix, STOPGAP program_id=3), Tier `loyalty_postgres_tier_to_s3_ingest`
(chunked 250k, program_id=2). Shared parquet `*_ext` tables. **dbt already owns the dedup/native layer
for ~20 tables** (incremental + QUALIFY on upload_ts): `loyalty_transaction`/`bucket`/`account_balance`/
all legacy/`tier_*` — not just Tier's 5. OC DAG triggers dbt Cloud job + row-count-compares PG vs
`{DB}.SOURCE.{table}`. Bonus/Partnerships DAGs hit DIFFERENT source DBs → out of scope. Full column
choices/casts in `dags/loyalty/configs.py`; types in `create_transaction_ext.sql`
(uuid→VARCHAR, bigint/int→NUMBER, numeric→NUMBER(18,6), ts→TIMESTAMP_NTZ, jsonb→VARIANT).

**Built this session (branch `loyalty/unified-postgres-ingest`, off origin/main; NOT committed/deployed):**
- `dags/loyalty/loyalty_unified_config.py` — single registry `UNIFIED_LOYALTY_TABLES` (7 core tables so
  far: transaction, bucket, account_balance, account_metadata, allocation, capture_event, void_auth_event)
  + generators: `copy_select_cols`, `ext_column_defs`, `native_column_defs`, `create_native_sql`,
  `watermark_sql`, `merge_sql`. Parallel-run naming: S3 `loyalty_source/`, ext `<t>_uni_ext`, native
  `<t>_uni` in SOURCE schema. `UNIFIED_TODO_TABLES` lists the remaining 17 (mechanical adds).
- `dags/loyalty/loyalty_postgres_unified_to_s3.py` — unified DAG. Dynamic-mapped per table:
  extract (watermark→COPY reader→S3 CSV, bounded mem, self-seeding) → merge (refresh ext + MERGE dedup)
  → dbt Cloud ledger job. Prod `20 * * * *`, dev None. Both files parse; MERGE codegen verified.

**FanCash-only work parked:** branch `fancash/postgres-ingest` (PR #2338) + this session's uncommitted
allocation/capture/void additions are in `git stash@{0}` on that branch (recoverable). Superseded by unified.

**Session 4 (cont.) — fan-out COMPLETE.** Registry now covers **all 24** loyalty-PG tables (OC bucket-model
12 + tier 6 + legacy dims 6; entry/journal/idempotency_keys excluded — dropped at 000011). Validated: all 24
generate COPY/ext/native/MERGE; PK ⊆ cols and incr_col ∈ cols for every table; col counts match the schema
dump. **24 `create_<t>_uni_ext.sql`** files generated into `dags/create_tables/sql/loyalty/` (auto-registered
by the folder scan) — CSV positional, types match `create_transaction_ext.sql`, jsonb→VARIANT. Codegen script
in scratchpad (`gen_unified_ext_ddl.py`) regenerates from the registry.
- Refresh handling reviewed + fixed: `merge` task does a **targeted** `ALTER EXTERNAL TABLE <t>_uni_ext
  REFRESH '<dt=ds/>'` (owner = snowflake_service_user) before MERGE — O(1) as files accumulate.
- PK caveat: `allocation_remaining` / `void_remaining` PKs are inferred composites `(transaction_id, bucket_id)`
  — VERIFY vs DB / dbt unique_key before flip (flagged inline in the registry).

**Branch `loyalty/unified-postgres-ingest` (off origin/main): 26 new files, NOT committed/deployed.**

**Side task (2026-08-26, background agent): FanCash branch expanded to ALL 24 QC tables.**
Before returning to unified, the user wanted `fancash/postgres-ingest` (PR #2338) complete on its own.
A worktree-isolated agent expanded `loyalty_fancash_copy_to_s3.py` (DEFAULT_TABLES/COPY_COLS/INCR_COL to
24; PROGRAM_SCOPED_TABLES = the 7 program tables → program_id=1; other 17 unfiltered) and generated all
24 `create_fancash_<t>_ext.sql` CSV ext tables, reusing the validated unified specs (so both branches
agree). Fixed: WHERE gating now respects PROGRAM_SCOPED_TABLES; `account_balance` gained `lifetime`
(now 8 cols). Committed **b272c8b1** on `fancash/postgres-ingest` (verified on branch, cast types correct,
worktree cleaned up). NOT pushed, NOT deployed. Unified branch untouched.
**VALIDATED in dev 2026-08-26:** create_tables built all 24 `fancash_*_ext`; loader ran clean off QC reader
(program_id=1 on the 7 program tables, satellites/dims unfiltered; loyalty_account 808,500 rows streamed at
PEAK_RSS 284 MB flat). After a clean-slate `REMOVE @…/loyalty_fancash/ PATTERN='.*\.csv'` + rerun + REFRESH,
all 24 ext row counts == source COPY counts exactly (transaction 1891, bucket 13, account_balance 10,
allocation 1023, capture_event 653, tier_account_override 1412, loyalty_account 808500, etc.; account_metadata
& opco_program_account = 0, no program_id=1 rows in QC). NOTE for AE: ext tables accumulate a dated file per
run → ledger must dedup via `QUALIFY ROW_NUMBER() OVER (PARTITION BY <pk> ORDER BY upload_ts DESC)=1`.

## 2026-09-03 — Unified pipeline → MERGE TO PROD TODAY as isolated parallel-run (D-8)

**Goal:** merge PR #2342 within ~2h; run `loyalty_postgres_unified_to_s3` isolated in prod for a few days,
then flip. Merge = deploy (CI create_tables builds 24 `_uni_ext` dev+prod; DAG runs `20 * * * *` prod).
Isolated: new `loyalty_source/` prefix + `_uni`/`_uni_ext`; live pipeline + dbt `SOURCE.<t>` untouched.

**Made the DAG merge-safe (commit dc8079ad, pushed):** bounded first seed (7d, not all history → no S3
part-cap blowup; full seed = separate min/max backfill), explicit min/max backfill path, **removed the dbt
Cloud trigger** (isolated; ledger repoint is a later PR), retries=2, max_active_tasks=8. Parses clean.

**Merge checklist (owner = Alex):** (1) un-draft PR #2342 + get approval/CI green → merge; (2) after CI deploy,
watch the first prod run's `pg_is_in_recovery()` log to confirm READER (pause+repoint if writer); (3) watch
`compare_counts` parity over the parallel-run days. NOTE: git commit signing needs 1Password unlocked (it
locked mid-session; retry the commit after approving the 1Password prompt).

**Branch state:** `loyalty/unified-postgres-ingest` @ dc8079ad, in sync w/ origin. Also NOTE the working tree
had been switched to `loyalty/bonus-postgres-copy-to-s3` (other session) — switched back; both branches clean.

**Deferred (NOT parallel-run blockers; pre-full-cutover):** native GRANTs (downstream read at flip), full
historical seed via min/max slices, all-programs PK re-check on native, other-AE sign-off to retire dbt source.

**PK QA PASSED (2026-08-27):** ran the uniqueness check against all 24 QC `fancash_*_ext` tables (latest
`upload_ts` snapshot). Every CHOSEN key `dupes=0` — all unique keys validated, NO registry changes. Notably
`transaction.transaction_id` unique (1891/1891) despite partitioned parent; `allocation.allocation_id` unique;
`allocation_remaining`/`void_remaining` composite confirmed (txn_id alone also unique — kept composite as safer
superset). Cleared the D-7 "VERIFY PKs" caveat. incr_col mutable/immutable split confirmed correct for all 24.
Remaining pre-dev-test code item: harden `compare_counts` (cutoff + tolerance + per-table try/except; review #1/#2).

**Unified PR opened (draft): https://github.com/fanatics-gaming/fes-airflow/pull/2342** on
`loyalty/unified-postgres-ingest` (commit 26e89aa5, 26 files). Parity check `compare_counts` baked into the
DAG (PG distinct-PK vs native COUNT, never fails). Cutover runbook: `unified_cutover_runbook.md`. PR body
lists the 4 merge-blockers (AE sign-off, dev-run validation, verify allocation_remaining/void_remaining PKs,
confirm prod reader).

**Next (Session 5):** Task #4 — (1) **dev run**: deploy (needs compute-dev write — not Alex's SSO) or PR so
create_tables builds the `_uni_ext` tables, then trigger `loyalty_postgres_unified_to_s3` in dev; validate
self-seed + MERGE dedup on QC data. (2) Parity: adapt the row-count/dedup compare (PG vs `SOURCE.<t>_uni`).
(3) **Tier-first parallel-run/flip runbook** + the coordinated dbt PR repointing `tier_points_ledger_core`
(then OC ledger) off the retired dbt source layer onto `SOURCE.<t>_uni`. (4) **Other-AE sign-off** (hard dep).

## 2026-09-04 — Session 6 — SCOPE REDUCED to extraction-only (Scope A, D-9)

**Decision (D-9):** cut the Airflow-owned native tables + MERGE from unified PR #2342. The DAG now does ONLY
(1) streaming COPY → CSV → isolated `loyalty_source/`, and (2) refresh the `SOURCE.<t>_uni_ext` external
tables. **dbt keeps the dedup** (incremental + QUALIFY on `upload_ts`), unchanged from how OC/Tier and the
merged bonus DAG (**#2347**) work in prod. Eliminates the whole "MERGE pattern / compact the native registry"
debate; makes the ingest change small, reversible, and same-shape as a DAG already proven in prod.

**Read the proven template** — `git show origin/main:dags/loyalty/loyalty_bonus_postgres_to_s3_ingest.py`
(#2347): pure PG→S3 COPY, `_resolve_window` (conf min/max > backfill > scheduled `[start−30s, end)`),
`compare_row_counts` warns-not-fails, dbt does the refresh+dedup. Our reduced DAG mirrors it.

**Diffs to remove from PR #2342 (confirmed by reading both files):**
- DAG `loyalty_postgres_unified_to_s3.py`: delete the `merge` task (MERGE + native COUNT); in `extract`
  delete the `create_native_sql`/`watermark_sql` calls + the native-watermark & bounded-seed branches,
  replace with `_resolve_window`; repoint `compare_counts` from native → `_uni_ext` (distinct-PK both sides);
  drop `DEFAULT_SEED_LOOKBACK_DAYS`. Extract ends up with ZERO Snowflake calls.
- Config `loyalty_unified_config.py`: delete `native_column_defs`, `create_native_sql`, `watermark_sql`,
  `merge_sql`, `native_fqn`, `business_col_names`, `NATIVE_SUFFIX`; trim the module docstring. KEEP the
  registry, `copy_select_cols`, `ext_column_defs`, `ext_fqn`/`EXT_SUFFIX`/`S3_PREFIX`, `pk`/`pk_distinct_count_expr`.
- KEEP all 24 `create_*_uni_ext.sql` (the external tables ARE the deliverable) — no change.

**One open judgment call:** whether to keep the `refresh_ext` task in the DAG (recommended — keeps the
isolated ext tables auto-queryable during the parallel-run; drop at cutover once dbt pre_hook refreshes) or
go fully minimal (no Snowflake in the DAG at all; refresh + check manually).

**Not changed:** parallel-run isolation (`loyalty_source/` + `_uni_ext`), reader-only COPY, prod `20 * * * *`.

**DONE this session:** implemented the removals (DAG + config), trimmed AI-slop comments, background subagent
review (2 findings fixed: stale MERGE/native headers scrubbed across all 24 DDLs; parity PG cast `::timestamptz`
→`::timestamp` to match the NTZ cutoff). Validated: black==23.12.1 + flake8 (max-complexity 10) clean, import
test passed. **Rebased onto a fresh branch `loyalty/unified-ingest-extract-only` off latest `main` → single
commit → new PR (label: enhancement). **Old PR #2342 CLOSED** (superseded). Commit signing via 1Password worked.

**CI coverage fix + final PR:** first fresh PR #2357 failed the repo-wide 60% coverage gate (59.03% — the two
new files added 140 uncovered stmts). Added `tests/dags/test_loyalty_unified.py` (registry/generator contract,
`_resolve_window` 3 branches, `_S3MultipartWriter` single/multipart/abort) → full suite **156 passed, 60.30%**.
Amended into the single commit. Force-push is blocked by the team deny list, so per user: pushed the amended
commit to a NEW branch `loyalty/unified-ingest-extract` → **PR fanatics-gaming/fes-airflow#2358**; **closed #2357**
and deleted its stale branch. #2358 = the live PR (27 files, one commit).
**Next:** confirm #2358 CI green; reviewer approval → merge (deploys isolated parallel-run to prod).

## 2026-09-08 — Session 7 — MERGED TO PROD + config simplified to configs.py shape

**Shipped:** PR **fanatics-gaming/fes-airflow#2358** merged 2026-09-08 18:52Z → unified ingest LIVE in prod as
the isolated parallel-run (`loyalty_source/` + `_uni_ext`; live pipeline untouched).

**DAG shape settled this session:**
- Fused COPY + ext-refresh into ONE task per table (`ingest_table`) — the DAG owns the refresh permanently
  (user decision); dropped the separate `refresh_ext` mapped task and the mapped-over-mapped fragility.
- `resolve_tables` feeds `ingest_table.expand` so a subset run maps only the requested tables (no
  AirflowSkipException skips); `map_index_template="{{ mapped_table }}"` labels each instance by table name.
- **Removed `compare_counts`** (hourly full-table distinct-count parity was out of scope / heavy) + its dead
  `pk_distinct_count_expr`/`PARITY_TOLERANCE_PCT`.
- **`retries=0`** (fused task → a retry would re-COPY just to redo the cheap refresh).
- **`max_active_tasks` env-aware: dev=1, prod=3** — dev MWAA workers were OOM/zombie-ing under 8 concurrent
  full-table COPYs during backfills.

**Config simplification (big cleanup, user drove):** went thin-config + generated manifest +
`information_schema` generator → judged overkill → **collapsed to ONE file** `loyalty_unified_config.py` =
`{table: {incr_col, cols}}`, same shape as `dags/loyalty/configs.py`. `cols` is the COPY column list (jsonb
`::text` inline); Snowflake types live only in the `create_*_uni_ext.sql` DDLs. Deleted
`loyalty_unified_columns.py` + `scripts/generate_loyalty_uni_ext.py`. Trimmed all AI-slop comments/docstrings.
Kept `test_cols_match_ext_ddls` (asserts `cols` order/jsonb == each DDL's `value:cN` — the one thing that
silently corrupts). Full suite **157 passed, 60.78%**.

**Prod schema verified (schema_discovery dumps, prod + dev):** programmatically confirmed every `cols` column
AND every `incr_col` exists in all 24 prod tables → **no COPY failure**. Column-order diffs are irrelevant
(COPY selects by name). transaction/allocation are partitioned in prod (`_YYYY_MM`/`_default`) — `FROM <parent>`
reads all. Correctly excludes `entry`/`journal`/`idempotency_keys`/`job_queue`/`program_account_override`/
`reason_config`/`schema_migrations`.

**Dev-vs-prod diff → D-10 follow-ups:** dev has `auth_bucket_hold.updated_at` and `transfer_restriction.created_at`
that **prod lacks** (loyalty adding `updated_at` to mutable tables; prod "soon"). We key `auth_bucket_hold` on
`created_at` and `transfer_restriction` on `starts_at`, so **no failure**. Policy (D-10): use `updated_at`
wherever it exists; switch both `incr_col`s once prod has the columns (auth_bucket_hold only if truly mutable —
confirm with loyalty). No table currently has prod `updated_at` that we ignore.

**Next (Session 8):** (1) watch prod parallel-run — run the 24-table ext summary query (rows/files/latest_upload)
over a few days. (2) Coordinated dbt PR repointing source models parquet `SOURCE.<t>_ext` → `_uni_ext`,
**Tier → OC → FanCash** (`unified_cutover_runbook.md`); needs other-AE sign-off. (3) Execute D-10 `incr_col`
switches when loyalty updates prod schema.

## Session 8 — 2026-09-30 — AE / Data Eng Integrations — dbt-fes-ae PR #260 (dual-write native ledger)

Work moved DOWNSTREAM to **dbt-fes-ae**, Sean McClure's PR **#260** "Sm/migrated loyalty ledger"
(branch `sm/migrated-loyalty-ledger`), which rebuilds the FanCash ledger on the unified `_uni_ext`
CSV landing. I contributed the native-source layer + dual-write isolation + CI fix + comment cleanup.
All commits pushed; latest **`6bcbcf7`**. PR: https://github.com/fanatics-gaming/dbt-fes-ae/pull/260

**Scylla ledger source trace** (answered "where's the full fancash data from Scylla"): historical
(pre-fanflow) ledger = `ref('loyalty_transaction_raw')` → native `LOYALTY.LOYALTY_CORE.LOYALTY_TRANSACTION_RAW`,
fed by external `LOYALTY.LOYALTY_STAGE.LOYALTY_TRANSACTION_RAW` over S3 `…/fdsloyalty/scylla_replication/pub…`
(parquet). STILL LIVE + current (6.77B rows, 2021→today, 6h refresh). Ledger UNIONs it only on full-refresh
(capped 2021-12-31..2025-12-31); incremental uses fanflow (`loyalty_transaction_successful__account`, ≥2026-01-01).
See findings 2026-09-30.

**Native `_uni` source models** (CSV-ext slowness fix): added 4 models
`{transaction,allocation,capture_event,void_auth_event}_uni` in `models/loyalty/source/dual_write/` — 1:1 over
each `_uni_ext`, incremental MERGE on PK, `upload_ts` watermark, QUALIFY dedup, `add_incremental_timestamps()`.
Repointed Sean's ledger_core stage to `ref('<t>_uni')` instead of full-scanning the ~237GB CSV. Source models
keep `_uni` suffix but NO `dual_write_` prefix (suffix already separates from live). PKs: transaction=id,
allocation=(earn_transaction_id,consume_transaction_id), capture/void=transaction_id.

**Dual-write restructure (D-11):** `_core` chain moved under `models/loyalty/fancash/dual_write/<folder>`,
native sources under `models/loyalty/source/dual_write/`. Ledger `_core` model FILES renamed `dual_write_<name>.sql`
→ materialize to `dual_write_*` tables (never overwrite live). Tags `['daily','fancash_dual_write']` + a
`fancash_dual_write_enabled` (default true) gate, set FOLDER-LEVEL in `dbt_project.yml`. Runs daily; ad-hoc via
`dbt run -s tag:fancash_dual_write`; read-prod-write-dev via team's `--vars '{loyalty_source_prod: true}'`
(source db flip in loyalty.yml). Cutover = drop `dual_write_` prefix + move out of `dual_write/`. (Rejected an
alias-macro approach as over-engineered — files renamed instead so temp models are obvious on disk.)

**CI fix:** CI runs dbt `--full-refresh`; `full_refresh_prevention()` hard-raises under that flag → new modified
stage models failed CI. Prod-gated all 4 guards: `{% if target.name == 'prod' %}{{ full_refresh_prevention() }}{% endif %}`
(protects prod, lets ci/dev rebuild). Reproduced + verified fixed by a dev `--full-refresh` build.

**AI-slop cleanup:** stripped 733 narrative comment lines across the dual_write tree (Sean's + mine),
COMMENTS ONLY — proved no code change by compiling every model before/after and confirming comment-stripped
compiled SQL byte-identical (20/20); no functional directives (depends_on/noqa/hooks) touched.

**Verified:** dbt parse clean; `tag:fancash_dual_write` selects 15 models; 4 source models build + all tests
pass in dev; ledger compiles to read `LOYALTY.SOURCE.transaction_uni` etc.

**NEXT (Session 9):** (1) confirm CI green on #260 → MERGE. (2) full dual-write chain build+test in dev (only
source layer + stage_core built so far; Sean flagged a possible `not_empty` on refund_agg). (3) optional: strip
PR-added narrative in `models/sources/loyalty.yml` `_uni_ext` source block. (4) airflow-side still pending:
watch prod parallel-run parity; D-10 incr_col switches when loyalty adds prod `updated_at`. (5) prod full-refresh
of 24 `_uni_ext` when needed (runbook in findings 2026-09-30).
