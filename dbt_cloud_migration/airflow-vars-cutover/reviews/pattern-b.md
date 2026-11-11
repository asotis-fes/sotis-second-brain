# Pattern B Adversarial Review

## Summary verdict

**DO NOT MERGE AS-IS.** One file (`martech_private_fan_id_map.sql`) has a critical regression that produces a permanent no-op filter, and a second (`loyalty_private_fan_id_map.sql`) is likely miscalibrated. The redeem-matching trio and `loyalty_redeem` change semantics from "as-of the Airflow slot" to "as-of NOW," which is defensible for a scheduled-hourly job but has a subtle drift risk called out below. The rest is safe.

---

## Findings

### CRITICAL

**C1. `martech_private_fan_id_map.sql` — filter now matches zero rows.**
- **What**: Before: `AND created >= '{{ var("data_interval_start") }}'::TIMESTAMP_NTZ`. After: `AND created >= CURRENT_TIMESTAMP()`.
- **Evidence**: The source column `created` is a real-world creation timestamp — no row will ever have `created > NOW()`. This makes the incremental branch a permanent no-op. On every incremental run the model will `MERGE` **zero source rows** against an incremental target. New martech mappings will never land. (Note: this model has `unique_key: martech_id` with `unique` test — silent 0-row runs will pass tests but stop refreshing the map.)
- **Under placeholder**: `created >= '2023-01-01'` — matched essentially every row on every incremental run. Wasteful but functional; the MERGE upserted whatever the source had.
- **Under Airflow**: `created >= data_interval_start` — narrow window since last DAG slot. Correct.
- **Under this PR**: `created >= CURRENT_TIMESTAMP()` — matches nothing. **Silent regression.**
- **Recommendation**: Change to `AND created >= CURRENT_TIMESTAMP() - INTERVAL '1 DAY'` (or whatever lookback matches the intended job cadence). Since this model's `--full-refresh` path may not be gated, verify a lookback matches upstream ingestion cadence, then confirm the map keeps refreshing after cutover. Do not merge this file without fixing.

---

### HIGH

**H1. `loyalty_private_fan_id_map.sql` — lookback likely too narrow.**
- **What**: Before: `AND created >= '{{ var("data_interval_start") }}'::TIMESTAMP_NTZ - INTERVAL '1 DAY'`. After: `AND created >= CURRENT_TIMESTAMP() - INTERVAL '1 DAY'`.
- **Evidence**: Ext source loaded by `upload_date` daily partition. `unique_key: ['loyalty_account_id', 'private_fan_id']`. When the DAG ran (say daily), `data_interval_start` was midnight of the current day, so the effective window was `created >= (today - 1 day)` — about 24-48h. Under this PR, the window is `NOW - 1 day` — a strict 24h. If the dbt Cloud job runs less frequently than daily, or drifts (job start jitter), rows created between (prev_run - 24h) and (this_run - 24h) will be missed. **Not zero-row, but leaky.**
- **Recommendation**: Confirm the scheduled cadence in dbt Cloud. If hourly → fine (huge overlap). If daily → widen to `INTERVAL '2 DAY'` for safety. This is the same pattern the rest of the repo uses for `loyalty_incremental_lookback_days: 2`.

**H2. `redeem_matches` / `unconnected_earn` / `new_ledger_txn` / `loyalty_redeem` — clock drift between the trio and downstream.**
- **What**: All four now use `CURRENT_TIMESTAMP()` independently, evaluated at each model's compile time (or runtime for the UDTF arg).
- **Evidence**: `new_ledger_txn` runs first (materialized: table). Then `redeem_matches` (table, feeds UDTF `connect_loyalty_transactions` with `CURRENT_TIMESTAMP()` as the "expiration-check" now). Then `unconnected_earn` (table) filters `loyalty_expiration >= CURRENT_TIMESTAMP()`. Then `loyalty_redeem` (incremental, merge) filters `creation_time >= NOW - redeem_lookback_days`.
- Before, all four saw the same `data_interval_end`. After, each sees its own wall-clock `NOW`. If the DAG takes 5-30 minutes to run end-to-end (plausible — `redeem_matches` is on `FDE_SNOWPARK_WH` doing a UDTF partition-by), an earn whose `loyalty_expiration` is between `redeem_matches`'s NOW and `unconnected_earn`'s NOW will be considered expired by the former (excluded from EARN_UPDATED output) yet included by the latter. Also `new_ledger_txn`'s upper bound (`creation_time <= NOW`) is a different NOW than `loyalty_redeem`'s window base, so a redeem row created between the two runs could be excluded from `new_ledger_txn` (didn't exist yet) but included by `loyalty_redeem` (after the fact, via `redeem_matches` output that also didn't see it). **In practice these windows are minutes wide and the data probably won't fall in them**, but the invariant "the whole redeem_matching family sees the same instant" is broken.
- **Recommendation**: Snapshot `NOW` once at the start of the job via a project-level var or a small anchor table (`SELECT CURRENT_TIMESTAMP() AS run_ts` seeded into a temp), and reference it consistently. If that's too heavy, at minimum document that the trio must run on a single warehouse in a single job invocation, and understand that expiration/lookback edges will have minute-scale jitter. A simple mitigation: use `DATE_TRUNC('minute', CURRENT_TIMESTAMP())` or snap to the hour so runs within the same hour see the same anchor.

**H3. `new_ledger_txn` upper bound `creation_time <= CURRENT_TIMESTAMP()` — future-dated rows.**
- **What**: The upper bound in `WHERE creation_time <= CURRENT_TIMESTAMP()` is now NOW rather than Airflow's `data_interval_end`.
- **Evidence**: Under Airflow, `data_interval_end` is the scheduled slot boundary — usually behind wall-clock time. If any row in `loyalty_transaction_successful__account` has `creation_time` slightly ahead of wall clock (clock skew across ingest → Fanflow → Snowflake pipeline), those rows were previously **excluded** and now are **included**. Given the prod diagnostic (MAX creation_time = 2026-07-22 13:58 vs runs at various times), skew of seconds-to-minutes is plausible. If the downstream `redeem_ledger_processed` guard is strict on `(loyalty_account_id, loyalty_txn_id, txn_status)` composite dedupe, this is probably harmless (already-processed rows get filtered by `NOT EXISTS`). But it's a widened behavior that should be acknowledged.
- **Recommendation**: Low-effort mitigation — keep `creation_time <= CURRENT_TIMESTAMP()` (documents intent) or remove it entirely since `NOT EXISTS` handles dedupe. Verify empirically that future-dated `creation_time` values don't exist by checking `SELECT COUNT(*) FROM loyalty_transaction_successful__account WHERE creation_time > CURRENT_TIMESTAMP();`.

---

### MEDIUM

**M1. `fan_id_register_dtl.sql` — 6 filters, all fine, but the JOIN filters have a subtle semantic shift.**
- **What**: All 6 uses look correct and consistent. Two of them (`email_otp` and `sms_otp` LEFT JOIN conditions) sit inside `ON` clauses rather than `WHERE`. That was already the case before; the change is just the anchor. Fine.
- **Sanity**: `unique_key: stream_id` with `merge`, and the driving CTE `register_acc` uses a 1-day lookback. All downstream joins use 30-day lookback. The imbalance is intentional: `stream_id` is the register event, so drive-set is 1 day; enrichment lookups are 30 days back because those events can arrive late. Under `CURRENT_TIMESTAMP()`, both windows shift together, so the offset is preserved. **Safe.** Prod verification: MAX(_insert_ts) is fresh (2026-07-22 19:43), 14.3M rows, so this model is landing rows currently — the Airflow behavior with the placeholder date probably matched everything, and the daily tag has been keeping it going that way. Post-cutover it will land only truly recent rows — this is the *intended* behavior once vars are stripped.

**M2. `gl_new_to_x_registration_events` — never materialized in prod; first-run will silently produce a partial table.**
- **What**: On first run, `is_incremental()` is false, so the model uses `event_ts >= '2023-01-01'` for the anchor CTE. That's fine and will produce a full historical backfill. But: the AppsFlyer join (`amplitude_attribution`) has NO `else` branch for `--full-refresh` — the `WHERE` clause is only inside `{% if is_incremental() %}`. On first run, Amplitude is unbounded, which the docstring warns: "consider a larger warehouse for the initial backfill" but the model is configured for `FDE_MWAA_SM_WH` on prod. **Small warehouse + full Amplitude scan = probable failure or extreme runtime on first run.**
- **Recommendation**: Before first materialization, either (a) run once with `--full-refresh` on a larger warehouse, or (b) add an else branch to bound Amplitude to `>= '2024-03-01'` per the docstring's note about `appsflyer_inapps` history. Independent of the PR — but worth flagging because the model is in the cutover set.

**M3. `loyalty_redeem` uses `merge` + `merge_exclude_columns: ['_insert_ts']` + `unique_key: pk` — safe, but the source `redeem_matches` upstream is a `table`.**
- **What**: `loyalty_redeem` filters `redeem_matches` output by `out_type = 'REDEEM' AND creation_time >= NOW - 2 days`. Since `redeem_matches` is a full rebuild each run, the "redeem" universe is fresh; the incremental filter is a downstream cost-control lookback into that fresh universe. Post-PR the lookback is `NOW - 2 days` vs previously `data_interval_end - 2 days`. Semantically identical for a job that runs on time. Adds risk only under job delays or reruns of an old scheduled slot. **Safe for scheduled hourly/daily runs.**

---

### LOW

**L1. `redeem_matches` UDTF arg for expiration-check now floats.**
- Under Airflow, the UDTF received a specific instant (`data_interval_end`) so backfills were deterministic. Under `CURRENT_TIMESTAMP()` they are not. If someone re-runs `redeem_matches` at a different time, EARN_UPDATED rows for earns that expired between the two run times will differ. Not a correctness bug for forward-only production runs, but worth being aware of.

**L2. `unconnected_earn.loyalty_expiration >= CURRENT_TIMESTAMP()` behavior boundary is soft.**
- Same theme: an earn with `loyalty_expiration` equal to the second the model runs will flip in/out. Millisecond-level, harmless.

**L3. Placeholder default `data_interval_start = '2023-01-01T00:00:00'` doesn't exist in this repo's `dbt_project.yml`.**
- I searched for a fallback default in `dbt_project.yml` — none is set. Under dbt Cloud without `--vars`, `var("data_interval_start")` would have raised a compile error unless a default was set per-model or overridden in the profile. That's actually a *good* thing: the affected models would have failed loudly rather than run with placeholders. Suggests the framing "produced rolling windows anchored on Jan 2023" was only true for models that pass a default (`var("data_interval_start", "2023-01-01T00:00:00")`). None of the Pattern B files pass a default — worth verifying whether these were compiling at all in dbt Cloud before this PR. If they were failing to compile, the impact is "PR unblocks them" rather than "PR fixes bad data." Either way, the C1 finding stands after the fix.

---

## Confirmed non-issues

- **Timezone**: `CURRENT_TIMESTAMP()` in Snowflake returns `TIMESTAMP_LTZ` by default, coerced to `TIMESTAMP_NTZ` in the compare context. The source columns (`event_ts`, `creation_time`, `_insert_ts`) are already `TIMESTAMP_NTZ` in FES silver events. Snowflake handles the coercion; timezone drift is not a real risk here. Prior code cast `data_interval_start`::TIMESTAMP_NTZ explicitly; the CURRENT_TIMESTAMP() replacement gets implicit cast via the comparison operator. Fine.
- **`fan_id_register_dtl` incremental strategy**: `merge` on `stream_id`; a narrower filter under wall-clock time doesn't cause data loss — the model only produces or updates rows for events falling in the window, and everything else is untouched from the prior run. Safe.
- **`full_refresh_prevention` on `loyalty_redeem` and `redeem_matches`**: pre-hook prevents `--full-refresh` accidentally wiping history for `loyalty_redeem`; `redeem_matches` also has it (verified) — protects the intermediate table from being wiped mid-flight. Both fine post-PR.

---

## Unresolved questions

1. **Cadence of the dbt Cloud jobs that run these models.** The correctness of every lookback change assumes the job runs at least as often as the lookback window. H1 in particular can't be graded without knowing whether `loyalty_private_fan_id_map` runs hourly, daily, or something else. (Airflow tag `identity` on those two models isn't visible in job schedules from this repo.) **Someone should confirm the dbt Cloud job schedule before merge and widen H1's window if the cadence is daily.**
2. **Whether `martech_private_fan_id_map` and `loyalty_private_fan_id_map` were actually compiling under the placeholder or failing.** If failing, C1's fix restores them from broken to broken-differently — no worse. If compiling with placeholder, C1's fix restores them from over-broad to zero-rows — a real regression. Either way, C1 must be fixed.
3. **Whether `connect_loyalty_transactions` UDTF's "now" argument is used for `loyalty_expiration` comparison only or also for other purposes.** Impacts the severity of H2. I could not inspect the UDTF body from this repo.
4. **Whether `gl_new_to_x_registration_events` is intended to materialize as part of this cutover.** If yes, M2 needs a plan; if no, why is it in the PR at all?
