# Design — memory-safe loyalty PG→S3 ingest (tier now, FanCash soon)

Context: `load_bucket` OOMs (SIGKILL -9) because the tier backfill floods the shared `bucket` table
(program_id=2) via `updated_at = now()` — 5,744,469 rows in one hourly window — and `SqlToS3Operator`
buffers the ENTIRE result in a pandas DataFrame. See `../analysis/prod_load_bucket_oom_20260810.md`.
User decision: NO pause, NO temporary program filter — make the pipeline actually ingest the full table.

## Two distinct volume problems => two chunk keys (KEY INSIGHT)
- **Burst on `updated_at`** (bucket, account_balance): a backfill stamps `updated_at = now()`, so millions
  of rows share ~one timestamp. TIME-chunking (month/week/day/hour) puts them all in ONE chunk => useless.
  Must chunk by ROW COUNT: server-side-cursor streaming OR keyset pagination on the PK (`bucket_id`).
- **Spread on `created_at`** (transaction): historical rows spread across months. TIME-chunking works.
  The existing prototype `loyalty_test_transaction_backfill.py` is CORRECT for this case.
  NOTE: backdated `created_at` means historical tier transactions land in OLD hourly windows, so the
  live incremental `load_transaction` never picks them up -> tier transaction history needs a
  created_at-range backfill (the prototype) for AE's tier ledger. That's a completeness gap, not the OOM.

## Downstream safety (VERIFIED in dbt-fes-ae, 2026-08-10)
- OC ledgers filter `program_id = 3` (CREDITS): `one_credits_loyalty_analytics_ledger.sql`,
  `loyalty_one_credits_balance_daily_snapshot.sql`. => ingesting program_id=2 into shared source is safe.
- `models/loyalty/source/bucket.sql`: no program filter, incremental `WHERE updated_at >= MAX(updated_at)`,
  dedup `QUALIFY ROW_NUMBER() OVER (PARTITION BY bucket_id ORDER BY upload_ts DESC)=1`. Absorbs tier rows.
- Transforms run via dbt Cloud job (DBT_CLOUD_FESLOYALTY_JOB_ID), models in dbt-fes-ae, NOT fes-airflow.

## Why the "backfill DAG + leave normal DAG alone" plan is incomplete
The tier backfill is LIVE and ongoing, stamping updated_at=now(), so it lands in the CURRENT hourly
windows. A backfill DAG only helps for a bounded historical range; it does NOT keep the live hourly
`load_bucket` green while the flood is happening. To go green with no pause/filter, the INCREMENTAL
load itself must be memory-safe. (This is also why 3+ consecutive runs failed: each hour the backfill
runs, that hour's window has millions — not one poisoned window, a rolling flood until backfill ends.)

## Memory-safe export primitive — options
- **(A) Server-side cursor streaming** [recommended]: custom `@task` opens a named psycopg2 cursor,
  `fetchmany(batch_size)`, streams batches to parquet (pyarrow ParquetWriter / N files). Memory = batch,
  independent of total rows AND time distribution. One task, no planning query. Scales to FanCash.
- **(B) Keyset-chunk dynamic task mapping**: `plan_chunks` computes `bucket_id` ranges (row-count balanced),
  `.expand()` a load task per range (`WHERE bucket_id > lo AND <= hi`). Reuses the prototype's mapping
  pattern; parallelizable; needs a stable PK + a planning query. Good for the standalone backfill DAG.

## Proposed architecture
1. Shared memory-safe export helper (A) in `dags/loyalty/` (or utils).
2. **Incremental DAG**: swap `SqlToS3Operator` -> streaming helper for the shared high-volume tables
   (`bucket`, `account_balance`; consider `transaction`). Keeps the incremental window filter; just
   streams it. THIS is what makes prod green during the flood — no pause, no program filter.
3. **Generalized backfill DAG**: config `{table, start, end, key: created_at|keyset, granularity/batch}`.
   Reuses the helper. For one-off historical loads + gap-fills (tier now, FanCash cutover later).
   Writes same S3 prefix; `ALTER EXTERNAL TABLE ... REFRESH;` after; dedup handled by staging QUALIFY.
   Generalize the existing `loyalty_test_transaction_backfill.py` (currently dev-only, test_transaction,
   created_at/month only) into this.

## Sequencing out of the current prod failure (no pause/filter)
1. Build + test streaming helper in DEV on `test_bucket` (loyalty_postgres_dev). Verify parquet matches
   bucket_ext, memory stays bounded on a big pull.
2. Deploy to prod (PR to main). Once `load_bucket` streams, the 5.7M windows succeed -> dbt unblocks -> green.
3. Windows that already failed pre-deploy = a bucket gap for those hours. Fill via the backfill DAG over
   that `updated_at` range (keyset). compare_row_counts (1% tol on bucket) then reconciles.
4. Watch `load_account_balance` — currently green, but it's also shared+updated_at; if tier writes many
   AB rows it will OOM too. Apply the helper preemptively.

## Open items / to confirm
- Approach A vs B; scope of tables to convert now.
- Whether to fix the incremental path now (go green during backfill) vs. accept failures + backfill after.
- Loyalty backfill total volume + ETA (bounds the gap-fill and dbt run size).
- dbt Cloud job runtime once bucket staging ingests millions in one incremental batch — monitor.
- Prod deploy path: standard PR to main vs. dev-first via fes-airflow-dev-deploy skill.

## UPDATE 2026-08-12 — Tier ingest = SEPARATE scheduled DAG (PR #2327), + prod backfill validated
Decision (user, agreed): during parallel processing keep OneCredits and Tier on SEPARATE scheduled
DAGs; fold into one once tier is stable. Isolation = a tier flood/failure/schema-churn can't stall the
live OC pipeline, tier pausable independently, and it proves chunked_ingest in a scheduled context on
the lower-stakes stream first.

PR #2327 `feat/loyalty-tier-ingest` (off origin/main b90e0807) — CI green (black/flake8/DagBag/SQL):
- NEW `loyalty_postgres_tier_to_s3_ingest`: extract-only, chunked, schedule prod `35 * * * *` (offset
  from OC `:05` so they don't co-trigger the shared dbt Cloud job), dev None, max_active_tasks=2.
  Ingests shared `transaction` filtered program_id=2 + the 5 tier tables (tier-only, no filter). No dbt
  trigger (shared loyalty dbt run rebuilds tier staging). No bucket/account_balance.
- `TP_POSTGRES_TABLE_CONFIGS` (tier, tier_override_configuration, tier_account_override [+rollover_tierpoints,
  5% tol], tier_account_override_trial, tier_invite_approval) in configs.py.
- 5 `create_tier*_ext.sql` (auto-registered by create_tables glob).
- Backfill DAG TABLE_CONFIGS now includes TP configs -> 5 tier tables backfillable.

KEY source-dependency finding (dbt-fes-ae PR #29, Hajime `tier_points_migration`): tier ledger reads
`loyalty__source`: transaction_ext + tier_ext, tier_override_configuration_ext, tier_account_override_ext,
tier_account_override_trial_ext, tier_invite_approval_ext. Does NOT read bucket/account_balance. (Also reads
Salesforce sources for legacy journal/member attrs — separate ingestion.) So earlier "backfill bucket +
account_balance for tier" was WRONG — corrected.

Prod backfill validated: `transaction` program_id=2 loaded Apr 2026 -> today via
`{table:transaction, column:created_at, program_id:2, min:2026-04-01, max:...}`. Tier `transaction` is
BACKDATED (rows dated 2025-06+), and full-history = ~328M rows -> 1300 chunks > Airflow's 1024 map cap,
so MUST bound by date range (quarter/month) per run. plan_backfill logs chunk count.

### Remaining steps (post-merge #2327)
1. Merge #2327 (auto-deploys prod). 2. Run `create_tables` in prod -> 5 tier ext tables.
3. Backfill 5 tier tables (small, one chunk each): `{table:tier}`, `{table:tier_override_configuration}`,
   `{table:tier_account_override}`, `{table:tier_account_override_trial}`, `{table:tier_invite_approval}`.
4. Backfill remaining tier `transaction` history pre-Apr-2026 in date-bounded runs if AE needs full history.
5. Confirm tier ext-table refresh (AUTO_REFRESH / dbt pre_hook — ownership caveat) with dbt owner.
6. Unpause/verify the scheduled tier DAG picks up live (current-dated) tier transactions.

## UPDATE 2026-08-11c — DEV-VALIDATED settings + PR #2325 (backfill landing)
- Branch `feat/loyalty-postgres-backfill` (off origin/main) = additive only: chunked_ingest.py,
  loyalty_postgres_backfill.py, loyalty_postgres_schema_discovery.py. PR #2325 — all CI green
  (black/flake8/DagBag/coverage); mergeable but BLOCKED on review approval. Merge-safe (does NOT touch
  the running incremental DAG; merge→main auto-deploys prod).
- IMPORTANT git context: origin/main was 3 commits ahead of local; the STOPGAP (program filter, #2322)
  is merged and in prod. The incremental chunked DAG stays on `fix/loyalty-ingest-chunked` (one clean
  commit, stale base) for a SEPARATE later PR — must rebase onto origin/main (reconcile with stopgap).
- Dev validation of the backfill DAG:
  - schema_discovery: works bare (no conf) — lists all tables.
  - backfill full `bucket`: 1 chunk, success.
  - backfill `transaction` [2026-01..07): FAILED first at CHUNK_ROWS=1M (one <1M chunk, -9 OOM — wide
    rows), then at 250k with max_active_tasks=4 (2 of 3 chunks OOM — CO-LOCATION). SUCCEEDED at
    CHUNK_ROWS=250k + max_active_tasks=1 (serial).
  - KEY LESSON: peak worker mem ~= CHUNK_ROWS * avg_row_bytes * pandas_overhead * concurrency. Row count
    alone is a bad proxy (transaction ~939B/row + metadata JSON vs bucket ~475B). Bound BOTH size and
    concurrency. Settled: CHUNK_ROWS=250_000; backfill DAG max_active_tasks=1 (serial; backfills aren't
    time-sensitive).
  - Backfill tier shared-table history via conf {table, column:created_at, min, max, program_id:2}.
- TODO for the incremental-DAG PR: it also had max_active_tasks=4 — apply the same low-concurrency so a
  prod flood window doesn't co-locate chunks and OOM. Normal hourly windows are 1 tiny chunk (moot).

## UPDATE 2026-08-11b — chunk on TIMESTAMP, not PK hash (supersedes the hash design below)
Decision (user): chunk by subdividing a timestamp column into ~1M-row slices; do NOT hash a
PK/id. Rationale: id-hash re-scans the window n times and "chunking on id" is unintuitive; timestamp
slicing needs one ordered pass for boundaries, then indexed range scans per slice.
- `build_chunk_specs(chunk_ts_col, range_start, range_end, program_id)`: finds the timestamp at each
  CHUNK_ROWS-th row via `ROW_NUMBER() OVER (ORDER BY chunk_ts_col)` (row-balanced boundaries), emits one
  timestamp sub-range per slice. Optional `program_id` adds an equality filter. `chunk_key` removed;
  `configs.py` reverted to main (no chunk_key).
- Incremental DAG: chunks the hourly window on `incremental_col` (−30s overlap baked into range_start);
  `program_id=None` (all programs — the point of dropping the stopgap filter), hook available to restrict.
- Backfill DAG conf: `{table, column(=ts, default incremental_col), min, max(exclusive), program_id?}`.
  Load tier shared-table history: `{table:transaction, column:created_at, min:.., max:.., program_id:2}`.
- Caveat: a timestamp column can't split rows sharing one exact value beyond CHUNK_ROWS — non-issue for
  microsecond timestamps unless a single instant has >1M rows. Chunk/filter cols should be indexed.
- All 5 DAG files py_compile; SQL generation sanity-checked for small/flood/backfill/full-table.

## UPDATE 2026-08-11 (final shape, branch `fix/loyalty-ingest-chunked`)
- CHUNK_ROWS 500k -> **1_000_000** (validated in dev). Peak worker mem ~= CHUNK_ROWS * max_active_tasks
  (=4) — confirm concurrent-chunk memory in dev or dial max_active_tasks down.
- Shard expr hardened: `MOD(ABS(HASHTEXT((key)::TEXT)::BIGINT), n)` — the `::BIGINT` before ABS avoids
  int4 overflow when HASHTEXT returns INT_MIN (~0.1% chance per multi-M window otherwise -> chunk error).
- `build_chunk_specs` generalized: takes a ready-made `filter_pred` (WHERE body) instead of a
  timestamp-only window. Incremental DAG passes its timestamp window; backfill DAG passes a column range.
- `chunk_key` now optional -> full-row hash `HASHTEXT(<table>::TEXT)` fallback when no PK (needs no PK,
  only clumps on exact-duplicate rows). All current tables still pass an explicit PK.
- Backfill DAG signature is now `{table, column, min, max}` (inclusive range on ANY column; omit column
  for full table). Backfill tier shared-table history via `{table:bucket, column:program_id, min:2, max:2}`
  (chunked by PK), likewise transaction/account_balance. Values are quoted literals; PG casts to col type.
- `loyalty_postgres_schema_discovery.py` brought onto this branch (from tp/ingest-wiring) to ship to prod
  — read-only, manual, prod-capable, optional `{"table_filter": "..."}`.
- Missing-timestamp/PK challenges: none for current tables (all have an indexed incremental_col + PK).
  Watch-outs: filter/shard cols should be indexed (else COUNT + n chunk scans are full scans); MOD sharding
  re-scans the window per chunk (~n x window DB work) — fine now, revisit at FanCash scale.

## IMPLEMENTED (2026-08-10, branch `fix/loyalty-ingest-chunked` off main)
Approach chosen: dynamic-chunk task mapping in the MAIN dag for every load task + a
generalized manual backfill dag. Chunk = row-count based: `n = ceil(count/CHUNK_ROWS)`,
shard by `MOD(ABS(HASHTEXT((chunk_key)::TEXT)), n) = i` on the table's single-column PK.
CHUNK_ROWS=500_000. MOD predicate only emitted when n>1 (tiny tables never chunk).

Files:
- `dags/loyalty/chunked_ingest.py` (NEW) — `CHUNK_ROWS`, `build_chunk_specs(...)`. Pure helper:
  COUNT the window, compute n, emit one `{query, s3_key}` per shard. Window optional (None=full
  table/backfill). Uses `MOD()/HASHTEXT()` (NOT `%`) to avoid psycopg2 paramstyle clashes.
- `dags/loyalty/loyalty_postgres_to_s3_ingest.py` (MODIFIED) — replaced the two single-`SqlToS3Operator`
  loops with, per table: a `plan_chunks` task -> `SqlToS3Operator.partial(...).expand_kwargs(chunks)`.
  `max_active_tasks` 1 -> 4 (peak mem ~= 4 * one 500k chunk; tunable). Backfill flag still drops the
  window (now chunked too). compare_row_counts + loyalty_dbt gating unchanged.
- `dags/loyalty/loyalty_postgres_backfill.py` (NEW) — manual, `schedule=None`. conf
  `{table, start?, end?, window_col?}`; looks up cols/chunk_key/incremental_col from configs; reuses
  `build_chunk_specs`; writes same S3 prefix; logs the `ALTER EXTERNAL TABLE ... REFRESH` to run after.
  Works in dev AND prod (conn resolves by env). This is the sanctioned replacement for the dev-only
  `loyalty_test_transaction_backfill.py` prototype.
- `dags/loyalty/configs.py` (MODIFIED) — added `chunk_key` (single-col PK) to every entry in
  POSTGRES_TABLE_CONFIGS + OC_POSTGRES_TABLE_CONFIGS. Verified each PK against SCHEMA_DATA_main.md.

PK verification (SCHEMA_DATA_main.md): bucket=bucket_id, account_balance=id, transaction=id (PK is
(id,created_at); id is unique UUIDv7), allocation=allocation_id, allocation_remaining/void_remaining/
auth_hold/capture_event/void_auth_event=transaction_id (PK), loyalty_account=loyalty_id,
opco_program_account/program_account_balance=account_id. Low-card keys (program_id, opco_id) only on
1-3 row dimension tables that never chunk. Dropped legacy (entry/journal/idempotency_keys) not loaded
in either env (OC_INGEST_LIVE True both) so their keys are moot.

All 4 files `py_compile` clean. `loyalty_postgres_incremental.sql` left in place (still used by the
separate bonus DAG). NOT applied to `loyalty_bonus_postgres_to_s3_ingest.py` (same latent risk; helper
is reusable there later — bonus configs would need chunk_key added).

### Still TODO before prod
- Dev validation: deploy to dev MWAA, trigger `loyalty_postgres_to_s3_ingest` with
  `{"loyalty_postgres_backfill": true}` on test_ tables; confirm chunked parquet matches ext tables,
  worker memory bounded per chunk, dbt + compare_row_counts pass. Measure mem to finalize CHUNK_ROWS.
- Dev-test the backfill dag: `{"table": "bucket"}` full pull, verify chunk count + REFRESH.
- Confirm SqlToS3Operator behavior on a 0-row chunk (existing DAG already tolerates 0-row windows).
- Confirm `[mapped, mapped] >> loyalty_dbt` gating renders (mapped-task -> TaskGroup dep).
- Then PR to main. Prod recovers once deployed (load_bucket chunks the 5.7M window). Gap-fill any
  pre-deploy failed windows with the backfill dag over that updated_at range.

## Assets already on `tp/ingest-wiring`
- `loyalty_postgres_schema_discovery.py` — prod-capable read-only schema lister (manual; `{table_filter}`).
- `loyalty_test_transaction_backfill.py` — chunked-backfill prototype (dev-only, created_at/month). Basis
  for the generalized backfill DAG; correct for transaction, NOT for bucket (needs keyset).
