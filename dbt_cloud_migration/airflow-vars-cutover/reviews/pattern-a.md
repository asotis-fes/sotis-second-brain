# Pattern A Adversarial Review

## Summary verdict

**MERGE WITH CAVEATS.** All 13 files compile and produce correct semantics for the "one snapshot per scheduled run" use case. Row-generation, prev-snapshot lookup, retention post-hook, and the Pattern F test macro all trace clean. The change *does* alter two invariants that were previously guaranteed by Airflow (idempotent PK on retry, and exact-hour timestamp alignment), and there is one silent semantic where the fbg-loyalty-balance metric's `alias` breaks with the CDE peer's cadence. These are documentation / operational concerns, not correctness bugs. Details below.

---

## Findings

### CRITICAL

*(None found.)*

---

### HIGH

**H1. `unique_key: snapshot_ts` is now effectively insert-only — retries or manual re-runs on the same day create duplicate snapshots.**
- **What**: Under the old code, every run in a scheduled slot got the same `data_interval_start` timestamp, so MERGE on `unique_key: snapshot_ts` was idempotent — a retry (transient Snowflake error, dbt Cloud manual "run job", operator kicks the job UI twice) would UPDATE the same row, not INSERT a second one. Under the new code, every run's `CURRENT_TIMESTAMP()` differs by at least milliseconds, so MERGE never matches → INSERT every time.
- **Evidence**: All 13 yaml configs declare `materialized: incremental`, `incremental_strategy: merge`, `unique_key: snapshot_ts`. In the compiled SQL (see `target/compiled/fes_data/models/loyalty/fanatics_one/metrics/tier_points_ledger_fbg_metrics.sql`), `CURRENT_TIMESTAMP()::TIMESTAMP` is the only place `snapshot_ts` is generated. Two runs 5 minutes apart → two rows.
- **Blast radius**:
  - `metric_threshold_check` (Pattern F) evaluates `MAX(snapshot_ts)` and tests only the newest row — so **the test still functions** even when duplicates exist.
  - The `prev_snapshot` lookup in the join-based files (`WHERE snapshot_ts < CURRENT_TIMESTAMP()::TIMESTAMP ORDER BY snapshot_ts DESC LIMIT 1`) picks the most-recent prior row — so a same-day retry would compare the retry against the first run of the same day, producing near-zero `*_pct_change` deltas and effectively silencing week-over-week test alerts for that day.
  - The 90-day retention post-hook doesn't care about duplicates.
  - If ops kicks a manual run to verify a schema change, the duplicate snapshot pollutes the change-detection tests for the *next* run too (that next run's "previous snapshot" is now the manual kick, not yesterday's real snapshot).
- **Recommendation**: Two options — either (a) document that ops must not manually re-kick the `dbt_loyalty_metrics` job within the same day, and configure dbt Cloud to disable auto-retry on this job; or (b) truncate the timestamp to the day/hour so retries are idempotent: `DATE_TRUNC('DAY', CURRENT_TIMESTAMP())::TIMESTAMP AS snapshot_ts` (or `DATE_TRUNC('HOUR', ...)` if you ever want sub-daily granularity). Option (b) restores the merge idempotency and is a one-character-per-file change. Given the intended semantic is "one row per scheduled slot", option (b) is the safer default.

**H2. `cde_loyalty_balance_metrics` is tagged `daily`, not `loyalty_metrics` — it does NOT run under the daily `dbt_loyalty_metrics` job cited in the review prompt.**
- **What**: All other Pattern A models in `cde/loyalty/metrics/metrics.yaml` are tagged `loyalty_metrics`. `cde_loyalty_balance_metrics` is tagged `daily` (line 81 of `metrics.yaml`).
- **Evidence**: `grep -n "tags:" models/cde/loyalty/metrics/metrics.yaml` → line 81 shows `tags: ['daily']`. This means the "`dbt build --select tag:loyalty_metrics`" job the prompt describes will NOT pick up `cde_loyalty_balance_metrics` — it flows through whatever `tag:daily` job dbt Cloud has scheduled. If the `daily` job's schedule differs from the `loyalty_metrics` job's schedule, this one model's cadence, retention behavior, and change-detection semantics differ from its 12 siblings even though the pattern-A change is identical. This is pre-existing and not introduced by this PR, but the assumption in the review prompt ("one snapshot per day at 14:00 UTC") does not necessarily hold for this file.
- **Recommendation**: Confirm what dbt Cloud job runs `tag:daily` and its cron. If it runs at a different time or multiple times per day, redo the "89 daily snapshots" verification for this specific table. (Non-blocking for the code review.)

**H3. `fbg_loyalty_balance_metrics` shares alias `loyalty_balance_metrics` with the CDE peer's target-name — but the two live in different databases, so no collision. Verify.**
- **What**: `fde_fbg/metrics/metrics.yaml` line 74 sets `alias: loyalty_balance_metrics` (dropping the `fbg_` prefix). `cde_loyalty_balance_metrics` has no alias, so it lands as-is.
- **Evidence**: The two tables land in different Snowflake schemas (`FDE_FBG.FDE_FBG_INFO_SOURCE.loyalty_balance_metrics` vs `CDE.CDE_COMMERCE_LOYALTY.cde_loyalty_balance_metrics`). No collision. Called out only because someone unfamiliar with the alias could grep for `loyalty_balance_metrics` in prod and be confused about which table they're looking at.
- **Recommendation**: No action. Flagging for reviewer awareness.

---

### MEDIUM

**M1. `CURRENT_TIMESTAMP()::TIMESTAMP` — subtle timezone / precision behavior.**
- **What**: Snowflake's `CURRENT_TIMESTAMP()` returns `TIMESTAMP_LTZ`. Cast to bare `::TIMESTAMP` becomes `TIMESTAMP_NTZ` (per Snowflake's default `TIMESTAMP_TYPE_MAPPING = TIMESTAMP_NTZ`), stripping the timezone. The resulting wall-clock value is whatever the session timezone is.
- **Evidence**: dbt Cloud jobs run with the account/user default timezone. If the account is `UTC` (typical for engineering accounts, and consistent with historical rows stamped at `14:00` matching the `0 14 * * *` UTC cron), the NTZ value equals UTC wall-clock — no drift. If the account is `America/Los_Angeles` (Snowflake default), the NTZ value is 7-8 hours behind UTC, and MIN/MAX snapshot_ts values will jump backwards by that offset once this PR merges.
- **Blast radius**: If timezone changes:
  - Downstream dashboards ordering by snapshot_ts still order correctly (monotonic).
  - The 90-day retention post-hook uses `CURRENT_TIMESTAMP - INTERVAL '90 DAY'` against `snapshot_ts`. Both sides are the same "kind of NOW", so retention still works correctly — but Snowflake implicitly converts LTZ→NTZ (or vice versa) for the comparison, and the 90-day window swallows any offset.
  - Historical rows produced under Airflow used ISO strings like `'2026-07-21T14:00:00'::TIMESTAMP` → NTZ literal at UTC. New rows will be NTZ at whatever the session TZ maps to. If session TZ ≠ UTC, MAX(snapshot_ts) will discontinuously shift on the first post-cutover run and downstream dashboards that display raw snapshot_ts will show a confusing time jump. **This is the ONE observable break** for existing consumers.
- **Recommendation**: Verify session timezone: `SHOW PARAMETERS LIKE 'TIMEZONE' IN ACCOUNT;` and `SHOW PARAMETERS LIKE 'TIMEZONE' IN USER <dbt_cloud_service_user>;`. If not UTC, either (a) explicitly stamp UTC: `CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP AS snapshot_ts` (safest — always UTC regardless of session), or (b) confirm nobody consumes raw snapshot_ts values and accept the offset. Option (a) is a small, clean improvement that eliminates any ambiguity.

**M2. Removes the ability to backfill a historical `snapshot_ts` via `--vars`.**
- **What**: Old code accepted `dbt run -s cde_loyalty_analytics_ledger_metrics --vars '{data_interval_start: "2026-06-15T14:00:00"}'` to stamp a specific historical snapshot. New code always uses NOW.
- **Evidence**: The models no longer reference `var("data_interval_start")` for `snapshot_ts`. Even if a user passes `--vars`, the value is ignored.
- **Blast radius**: Monitoring snapshots aren't typically backfilled (they're a rolling 90-day window of point-in-time observations), so this is likely never used. But if someone was compensating for a missed job by re-running with `--vars`, that pattern breaks silently — the "backfilled" row will be stamped with wall-clock NOW, not the intended historical moment.
- **Recommendation**: Search history for anyone running these models with `--vars` (fes-airflow DAG history, dbt Cloud job run overrides, Slack #fes-data-analytics-support archives). If nobody does, no action. If somebody does, document that they now need to use `dbt run --vars '{data_interval_start: ...}'` with the *old* semantics only if the vars are consumed elsewhere — for these 13 models, backfill via var is now unsupported.

**M3. `CURRENT_TIMESTAMP()::TIMESTAMP` evaluated identically in both `current_snapshot` and `prev_snapshot` CTEs — behavior is correct, but worth stating explicitly.**
- **What**: In 8 of the 13 models the pattern is:
  ```
  current_snapshot AS (SELECT ..., CURRENT_TIMESTAMP()::TIMESTAMP AS snapshot_ts, ...)
  prev_snapshot   AS ({% if is_incremental() %} SELECT ... FROM {{ this }} WHERE snapshot_ts < CURRENT_TIMESTAMP()::TIMESTAMP ORDER BY snapshot_ts DESC LIMIT 1 {% else %} ... {% endif %})
  ```
- **Evidence**: Snowflake evaluates `CURRENT_TIMESTAMP()` **once per statement**, so both CTEs see the same value. Result: `WHERE snapshot_ts < X` correctly excludes the row currently being inserted (which is being stamped with exactly X, and `X < X` is false), and returns the most-recent *pre-existing* row. This is the correct behavior. Verified via reading the compiled `tier_points_ledger_fbg_metrics.sql` — the pattern renders as one flat SQL statement.
- **Recommendation**: No action. Confirming this is safe.

---

### LOW / NIT

**L1. `metric_threshold_check` change-detection tests now compare against yesterday's snapshot instead of the previous scheduled slot.**
- **What**: The `*_pct_change` metrics (e.g. `acct_pct_change`, `earn_pct_change`) are computed in-model as `current.cde_acct_pct - prev.cde_acct_pct`. Since the previous-row lookup uses `MAX(snapshot_ts) < NOW LIMIT 1`, the previous snapshot for a daily-cadence job is ~24h old. That's identical to the old daily behavior. But if the job's cadence were ever changed (e.g. re-enabled at 6-hour cadence like the old Airflow DAG), the "previous snapshot" would be 6 hours old — which would tighten the `lower/upper_bound: [-10, +10]` change-detection thresholds substantially. The thresholds are calibrated for daily deltas.
- **Recommendation**: If the job's schedule is ever changed from daily, revisit the `_pct_change` bounds in `metrics.yaml`.

**L2. `fbg_loyalty_earn_burn_mapper_metrics` still has `unique_key: snapshot_ts` but no `prev_snapshot` CTE.**
- **What**: `models/fde_fbg/metrics/fbg_loyalty_earn_burn_mapper_metrics.sql` and its CDE peer DO have the join-based `prev_snapshot` CTE (`fbg_acct_pct`, `fbg_txn_amount_pct`). Actually verified — both have it. This finding is retracted; I was concerned but confirmed the pattern is present. **Ignore.**

**L3. `cde_tier_points_ledger_metrics`, `cde_tier_points_overrides_metrics`, `fancash_balance_collectibles_metrics`, `tier_points_ledger_fbg_metrics`, `tier_points_overrides_fbg_metrics` — no `prev_snapshot` join, so no week-over-week `_pct_change` column in output.**
- **What**: 5 of the 13 files are simple `SELECT ..., CURRENT_TIMESTAMP()::TIMESTAMP AS snapshot_ts, * FROM totals`. They do have `today` vs `last_week` comparisons *inside the CTE tree* for the 3 tier-points files (which compute `_week_pct_change` using absolute wall-clock day-30-hour lookback, unaffected by this PR), but they don't compute `snapshot-over-snapshot` deltas.
- **Evidence**: Reading the 5 files, only the join-pattern files have `prev_snapshot`.
- **Recommendation**: No action. Consistent with pre-PR behavior.

**L4. NIT: post_hook uses `CURRENT_TIMESTAMP` (no parens) — mixes LTZ and NTZ.**
- **What**: `DELETE FROM {{ this }} WHERE snapshot_ts < CURRENT_TIMESTAMP - INTERVAL '90 DAY'`. Left side is NTZ (`snapshot_ts` column), right side is LTZ (`CURRENT_TIMESTAMP` returns LTZ). Snowflake implicitly converts, but the comparison is timezone-sensitive if the session TZ ≠ UTC.
- **Evidence**: 90-day window is much larger than any TZ offset, so no rows are incorrectly retained/deleted. Cosmetic only.
- **Recommendation**: If M1's `CONVERT_TIMEZONE('UTC', ...)` recommendation is adopted, also update post_hook to match.

---

## Confirmed non-issues

1. **PK collision / merge behavior on the daily cadence**: One run per day → one snapshot_ts per day → no MERGE-driven overwrite. Correct.
2. **`CURRENT_TIMESTAMP()` timing consistency within a statement**: Snowflake evaluates once per statement; the same value flows through `current_snapshot` and `prev_snapshot`. `WHERE snapshot_ts < X` correctly excludes the current row and returns the most-recent prior row.
3. **90-day retention post-hook**: Still functions correctly. Comparing NTZ snapshot_ts against LTZ CURRENT_TIMESTAMP with an implicit cast — the 90-day window swallows any TZ offset.
4. **No downstream `ref()` on these 13 tables inside this repo**: `grep -rn "cde_loyalty_analytics_ledger_metrics\|fbg_loyalty_balance_metrics\|..." models/` returned only the definitions themselves and the yaml configs. No cross-model dependencies would break.
5. **Pattern F test macro**: `WHERE {{ snapshot_ts_col }} = (SELECT MAX({{ snapshot_ts_col }}) FROM {{ model }})` works correctly against the new snapshot_ts values. It tests the latest snapshot regardless of what that snapshot's timestamp is. Thresholds themselves (`lower_bound: 7.5e9` for `num_cde_txn` etc.) are calibrated against absolute business metrics, not against the snapshot_ts, so they're unaffected.
6. **`is_incremental()` first-run behavior**: If the table already exists in prod (it does — 89 rows), `is_incremental()` is true; the `prev_snapshot` CTE queries `{{ this }}` and finds the last real snapshot. If someone `--full-refresh`es, `is_incremental()` is false and `prev_snapshot` returns a NULL row with `WHERE FALSE`, so `_pct_change` columns COALESCE to 0. Safe.
7. **fes-airflow `dbt_loyalty_6hours` DAG**: This DAG uses tag `loyalty_6hours`, NOT `loyalty_metrics`. It does not pick up any of these 13 Pattern A models. The metrics job is separate. (Verified in `/Users/alex.sotis/repos/fes-airflow/dags/loyalty/dbt_loyalty_6hours.py`.)

---

## Unresolved questions

1. **Snowflake session timezone**: Need to run `SHOW PARAMETERS LIKE 'TIMEZONE' IN USER <dbt_cloud_service_user>;` in prod to confirm UTC. The single biggest observable-behavior concern (M1) hinges on this.
2. **`dbt_loyalty_metrics` dbt Cloud job schedule and retry policy**: The prompt states `0 14 * * *` daily. Confirm in dbt Cloud UI. Also confirm retry-on-failure is off (or that H1's duplicate-row risk is acceptable).
3. **`tag:daily` dbt Cloud job schedule**: See H2. This job picks up `cde_loyalty_balance_metrics`. Verify its cadence matches the assumed "one per day" pattern.
4. **Why did the tables freeze at 2026-07-21 14:00 (2 days ago)?**: Prod diagnostic showed MAX snapshot_ts stuck at that value. If Airflow was previously injecting `data_interval_start` via steps_override into the dbt Cloud job, and that injection broke 2 days ago, this PR is the correct fix — the models now don't depend on Airflow at all. If the freeze has a different root cause (dbt Cloud job disabled, deploy issue), the fix here still helps but doesn't unfreeze the pipeline. Worth confirming the dbt Cloud job history shows failed/skipped runs on 07-22 and 07-23 rather than "successful runs writing the wrong data."
5. **Prod diagnostic delta**: The prompt says "89 rows spanning April-July" but if pre-PR runs without vars would fall back to the `2023-01-01` placeholder, how did prod accumulate 89 distinct daily rows? Two hypotheses: (a) the dbt Cloud job had `--vars` in steps_override until 07-21, then that config broke; or (b) something in dbt Cloud (job env vars, project-level overrides) was already providing a dynamic timestamp. Either way, this PR makes the model self-sufficient — but worth understanding for the write-up on why the freeze happened, so it doesn't recur through a different vector.
