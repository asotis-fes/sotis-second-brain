# Prod incident — `load_bucket` OOM (2026-08-10)

DAG `loyalty_postgres_to_s3_ingest` (prod). `load_bucket` task failing; user paged with a
"zombie job" error. Confusing because it coincided with the tier-points prod push but is NOT a
schema issue.

## Verdict: OOM (SIGKILL -9), NOT a hang/lock/schema problem

Task log (run `scheduled__2026-08-10T15:05:00`, attempt **4 of 4**):
```
Starting attempt 4 of 4
Started process 340223 to run task
[14:15:50 -> 14:16:30 EDT]  Task exited with return code -9   # SIGKILL, ~40s in, no traceback
[14:16:36 EDT] Detected zombie job ...                        # consequence, logged AFTER the kill
```
- `-9` = SIGKILL by the kernel (OOM killer). Zombie message is downstream of the kill, not the cause.
- Deterministic across all 4 attempts (~40s each) => data-driven memory blowout, not a flaky worker
  or a transient PG lock (a lock would be a ~5-min heartbeat-timeout zombie, not a 40s SIGKILL).
- `load_transaction` (same PG conn, same `SqlToS3Operator`, same run) succeeded in ~2s => PG healthy
  broadly; failure is specific to the `bucket` query/table.

## Mechanism
- `SqlToS3Operator` loads the ENTIRE query result into a pandas DataFrame in worker memory before
  writing parquet. `max_rows_per_file=1_000_000` only splits the OUTPUT files, not the in-memory frame.
- `bucket` config: `incremental_col = updated_at`, so hourly query is
  `SELECT * FROM bucket WHERE updated_at >= interval_start-30s AND updated_at < interval_end ORDER BY updated_at`.
- Normal `bucket` volume = 1-12 rows/hr (verified in Snowflake). A bulk `UPDATE` on prod `bucket`
  stamps `updated_at = now()` on every touched row -> all land in ONE hourly window -> query returns a
  massive result -> pandas OOM -> SIGKILL.

## Corroborating Snowflake facts (LOYALTY.SOURCE, prod, read-only)
- `bucket` 11,835 rows; `account_balance` 19,903; `transaction` 8,186. All tiny.
- All three share max ts `2026-08-10 14:58:38 UTC` = clean ingest cutoff (poisoned 15:05 window never landed).
- `bucket.updated_at` hourly volume last 24h = 1-12 rows/hr.
- `transaction`/`account_balance` `program_id = 2` (tier) rows = 0 => tier data not in prod yet;
  this is NOT a tier schema/mismatch issue.
- `transaction` uses `created_at` (append-only) => a bulk update doesn't move its window => it stayed green.

## Why it's self-limiting
Bulk UPDATE => all touched rows get `updated_at ~= 15:0x` => confined to ~one hourly window. That run
OOMs forever if retried (always pulls the whole window). LATER scheduled runs pull small windows and
recover on their own. Grid showed ~2 trailing red columns => poisoned window may straddle the :05
boundary (30s re-read overlap) or two bulk ops.

## Immediate mitigation (does NOT self-heal the gap)
- Do NOT just "Clear/Retry" the failed run — it will OOM again.
- Confirm newest scheduled run is green again (later windows small) => active bleeding already stopped.
- To clear the red/alert + fill the gap: backfill the poisoned window's `bucket` rows in CHUNKS
  (sub-hour windows or keyed pagination) so no single pull materializes the whole set. Then the
  compare_row_counts (1% tolerance on bucket) will pass.
- Leaving `load_bucket` failed but NOT backfilling => `bucket` SF short by the bulk-updated rows =>
  future `compare_row_counts` mismatch once diff exceeds 1%.

## Open confirmations needed
1. Is the newest scheduled run green on `load_bucket`? (expect yes)
2. Did loyalty run a bulk update/migration on prod `bucket` ~14:50-16:10 UTC 2026-08-10?
   PG check: `SELECT count(*) FROM bucket WHERE updated_at >= '2026-08-10 15:04:30' AND updated_at < '2026-08-10 16:05:00';`
3. Worker memory limit for this MWAA env (to size the chunk count).

## CONFIRMED (2026-08-10, loyalty team + SF program table)
- Loyalty team ran the window count on prod PG `bucket`: **5,744,469 rows** in [15:04:30, 16:05:00).
  Normal = 1-12/hr. `SqlToS3Operator` full-frame load of 5.7M rows => OOM. Definitive.
- `program` mapping (LOYALTY.SOURCE.program): **1=FANCASH, 2=TIERPOINTS, 3=CREDITS (OneCredits)**.
- Currently-ingested `bucket` = 100% program_id=3 (OneCredits), 11,835 rows. The 5.7M flood is
  program_id=2 (TierPoints) backfill — NOT yet in SF (load_bucket OOMs before landing it).
- `bucket` IS shared (has `program_id`). `load_bucket` has NO program filter => tier backfill floods it.
  This directly refutes "tier backfill shouldn't affect OneCredits" — the ingest doesn't separate programs.
- Feature branch `tp/ingest-wiring`: dormant in prod (`TP_INGEST_LIVE=prod=False`), purely additive
  (new tier-specific tables only; +lifetime on account_balance_ext). Does NOT touch bucket, adds no
  program filter, reuses the same full-frame SqlToS3Operator. Merging it fixes nothing here AND will
  hit the same wall at tier/FanCash scale. No incremental-col or existing-schema change needs prod now.
- Design note: shared tables (bucket/account_balance/transaction) are SUPPOSED to carry all programs
  (TP configs deliberately exclude them; AE reads shared ext-tables for tier). So a permanent
  program_id=3 filter would starve tier — filtering is only a stopgap for the backfill flood.

## Priority-1 options (stop the failure)
1. PAUSE the DAG now — fastest/safest/reversible; stops pages + OOM retries. Cost: all loyalty
   ingest+dbt (incl. OneCredits ledgers) go stale until resumed. Handle catchup on resume.
2. SURGICAL program filter — add optional per-table `extra_filter` (e.g. `program_id = 3`) to
   bucket (and account_balance if it also floods) so OC stays small/fresh; excludes the tier flood.
   Small code change + prod deploy. Tier shared-table data then needs a controlled chunked backfill.
3. Ask loyalty to throttle/pause the tier backfill while we deploy a durable fix.
Recommended sequence: (1) pause now to stop bleeding -> (2) deploy filter to restore OC freshness ->
unpause (catchup safe with filter) -> (3) durable chunked ingest before FanCash.

## RESOLUTION PATH (2026-08-10)
Two branches, both off main:
- `fix/loyalty-oc-program-filter` — STOPGAP for prod NOW. Restricts the shared bucket-model
  program-scoped tables (bucket, account_balance, transaction) to program_id=3 (OneCredits) on BOTH
  the load query (via a new optional `program_filter` template param) AND compare_row_counts (both
  sides). Lets the live OneCredits pipeline keep running while tier's program_id=2 flood is excluded.
  Behavior-preserving for the bonus DAG (shares the template; no program_filter key => no clause;
  verified by rendering all cases). Residual risk: allocation_remaining/void_remaining are updated_at
  + have NO program_id column, so they can't be program-filtered — acceptable since tier (status
  points) is not expected to write FEFO allocation rows and only `bucket` was observed flooding.
  Remove this stopgap once chunking ships.
- `fix/loyalty-ingest-chunked` — the real fix (chunked ingest + backfill dag). Test in dev, then it
  supersedes the stopgap (revert the program filter when it deploys).

## Durable fix (priority 2 candidate)
`SqlToS3Operator` full-frame load is the latent risk for ANY `updated_at`-keyed table under a bulk
update (bucket, account_balance, program_account_balance, bonus.* updated_at tables). Options:
chunked/windowed export, server-side cursor, or a guardrail that caps/splits when a window row-count
exceeds a threshold. Revisit after the tier cutover.
