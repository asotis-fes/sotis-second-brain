# Pattern F Adversarial Review (metric_threshold_check test macro)

## Summary verdict

**SAFE TO MERGE** — the change replaces a silently-broken WHERE (matching the frozen `'2023-01-01'` placeholder → 0 rows → trivial pass under dbt Cloud) with correct latest-snapshot semantics that align with Pattern A's new `CURRENT_TIMESTAMP()` snapshot_ts. Net: PR-24 restores a set of tests that had been silently degraded to no-ops, at the price of a small semantic shift (see MEDIUM-1) that is almost certainly desired.

Scope confirmed: **79 test invocations across 13 Pattern A models** — every one now uses `MAX(snapshot_ts)` selection. All confirmed compiled tests use fully-qualified `{{ model }}` (no subquery wrap; no `where:` filter anywhere in the three yamls), so the substitution is textually safe.

---

## Findings

### MEDIUM — 1. Empty-target trivial pass is preserved, not fixed

**What:** If `MAX(snapshot_ts)` is NULL (empty table), `snapshot_ts = NULL` never matches → test returns 0 rows → **PASSES silently**. Same failure mode as the old `'2023-01-01'` placeholder, so this PR does not *introduce* the risk — but it does not fix it either.

**Evidence:**
```sql
WHERE snapshot_ts = (SELECT MAX(snapshot_ts) FROM ...)  -- MAX = NULL if empty
```
Snowflake: `x = NULL` is UNKNOWN → row filtered → 0 rows → test passes.

**Where it bites:** on a first-time build failure that produces zero rows (e.g., model INSERT fails or all upstream refs are empty in a new environment), the very tests designed to warn about "pipeline data loss" will report green. The lower_bound thresholds (e.g., `num_fbg_txn >= 100e6`) are meant to catch exactly this class of failure — but only if there IS a row.

**Recommendation (non-blocking for this PR):** Follow-up PR to add a companion `dbt_utils.expression_is_true` or `not_null` test on `snapshot_ts` itself for each of the 13 models. Or wrap `metric_threshold_check` to raise when `MAX(snapshot_ts) IS NULL`. Do not block this PR on it — it is a pre-existing gap.

### MEDIUM — 2. `unique_key: snapshot_ts` + `CURRENT_TIMESTAMP()` sub-second collision risk

**What:** All 13 models use `incremental_strategy: merge` with `unique_key: snapshot_ts`, and Pattern A's SELECT sets `snapshot_ts = CURRENT_TIMESTAMP()::TIMESTAMP`. If a dbt Cloud job is retried or manually re-triggered within the same second (Snowflake `TIMESTAMP_NTZ` millisecond precision), the merge would UPSERT over the previous row instead of appending — losing the earlier snapshot entirely.

Interaction with this test: the test itself is fine (it just reads the winning row). But the *threshold values* were calibrated assuming a discrete series of snapshots. If merges silently collapse two runs, cadence-dependent thresholds (the `_pct_change` tests bounded at ±10) will misbehave because `prev_snapshot` may pick up a version that is nearly identical to `current_snapshot`.

**Evidence:**
- `models/loyalty/fanatics_one/metrics/tier_points_ledger_fbg_metrics.sql:53` — `CURRENT_TIMESTAMP()::TIMESTAMP AS snapshot_ts`
- `models/loyalty/fanatics_one/metrics/metrics.yaml:13` — `unique_key: snapshot_ts`
- Snowflake `CURRENT_TIMESTAMP()` returns millisecond-ish resolution but statement-scoped; two concurrent dbt jobs against the same target could tie.

**Where it bites:** manual re-runs after a transient failure; parallel dbt Cloud CI jobs; job retry logic. Not a Pattern F bug per se — but Pattern F's semantic ("test the latest snapshot") makes it more important than before to guarantee snapshot_ts uniqueness.

**Recommendation:** Consider using `TIMESTAMP_LTZ` with `ROW_NUMBER`/UUID tiebreaker, or use `run_started_at` (which is invocation-scoped, stable within a run) as the composite key. Not blocking, but worth a follow-up.

### LOW — 3. Semantic shift from "specific slot" to "latest available"

**What:**
- Under Airflow: test the row where `snapshot_ts = data_interval_start` — i.e., the row this DAG run just wrote.
- Under dbt Cloud pre-PR-24: `data_interval_start` was the frozen placeholder → 0 rows selected → tests were passing trivially. **The tests were broken.**
- Under dbt Cloud post-PR-24: latest row in the table.

For the standard case (`dbt build` writes a row, then the test reads it a moment later, and this is now the latest row), these are semantically equivalent. The gap opens if the model INSERT fails but the test still runs — in the old Airflow world, the test would find 0 rows for that slot and pass; under `MAX()`, it will find yesterday's row and test **stale data** against today's thresholds.

**Evidence:** `dbt build` fails-fast per node: if the model errors, downstream tests are skipped, not run. So this failure mode requires the model to *succeed but insert 0 rows* (edge case) — in which case testing yesterday's row is arguably the right behavior anyway.

**Recommendation:** Document the semantic in a comment on the macro itself so the next engineer doesn't wonder why `MAX(snapshot_ts)` and not `run_started_at`. One-line comment sufficient.

### LOW — 4. Post-hook deletes 90-day-old snapshots — interacts with empty-target risk

**What:** Every Pattern A model has:
```sql
post_hook = ["DELETE FROM {{ this }} WHERE snapshot_ts < CURRENT_TIMESTAMP - INTERVAL '90 DAY'"]
```
If the model is orphaned (no new inserts) for >90 days AND then a run finally happens but errors before insert, the table could genuinely go empty. Combined with Finding #1 (empty target passes trivially), a stalled pipeline that eventually gets a broken run could produce a silently-passing test even after the DELETE truncates history.

**Recommendation:** Non-blocking. Tied to Finding #1.

### LOW — 5. `cde_loyalty_balance_metrics` has `tags: ['daily']` while siblings have `['loyalty_metrics']`

**What:** In `models/cde/loyalty/metrics/metrics.yaml:81`, this one Pattern A model is tagged `daily` instead of `loyalty_metrics`. If dbt Cloud jobs are selecting `tag:loyalty_metrics`, this model may execute on a different schedule than the tests attached to it — meaning the test could read a *very* stale MAX(snapshot_ts).

**Evidence:** grep confirmed `daily` is used elsewhere in the repo for daily-cadence scheduling. If `daily` and `loyalty_metrics` jobs run at different frequencies, MAX(snapshot_ts) could be from a different cadence than expected.

**Recommendation:** Verify with the FES team that the `daily` tag on this one model is intentional and that its dbt Cloud job runs (a) at least as often as the tests that depend on it, and (b) the model + tests are always co-scheduled. Not a Pattern F regression — pre-existing.

### NIT — 6. `snapshot_ts_col` is column-name-only, but embedded twice

The macro references `{{ snapshot_ts_col }}` at three positions (SELECT list, WHERE LHS, subquery). No caller in any of the 79 invocations overrides the default `'snapshot_ts'`, so this is fine — but a caller who did pass a quoted-identifier or aliased column (e.g., `snapshot_ts_col='snap.snapshot_ts'`) would emit invalid SQL in the `SELECT MAX(...)` subquery (there is no alias inside the subquery). Preserves prior behavior; noting for future callers.

### NIT — 7. Compiled SQL has stray whitespace / Jinja indent

Sample compiled output shows extra blank lines and hanging indentation (see `target/compiled/.../metric_threshold_check_tier_po_*.sql`). Cosmetic only; Snowflake parses fine.

---

## Confirmed non-issues

- **`get_where_subquery` interaction (adv Q5):** No `where:` filter on any of the 79 test invocations (grep confirmed). Compiled SQL shows `FROM LOYALTY_DEV.LOYALTY_INFO.tier_points_ledger_fbg_metrics` — plain relation, not a subquery. The `(SELECT MAX(snapshot_ts) FROM {{ model }})` substitution is textually identical outer + inner, no aliasing conflict. Safe.
- **Two rows share MAX(snapshot_ts) (adv Q2):** `unique_key: snapshot_ts` + merge strategy means there is at most ONE row per snapshot_ts value in the target. The subquery returns a single value → WHERE matches at most one row. (The collision risk in Finding #2 is a different concern — collapsing two writes into one, not two winning rows.)
- **Idempotency (adv Q10):** The subquery reads the same target as the outer FROM within one query — Snowflake serializes this snapshot-consistent. Repeated invocations within the same session are stable.
- **Query plan efficiency (adv Q4):** Snowflake reads MIN/MAX from metadata for uncomplicated columns without table scan. All 13 tables are tiny (≤365 rows given 90-day retention + daily cadence). Zero performance concern.
- **Test-macro pattern F changes and Pattern E `run_started_at` change:** Pattern E affects `models/loyalty/fanatics_one/tier_changes_all.sql`, not Pattern A metric models. No cross-pattern interaction with this test.
- **Threshold calibration (adv Q8):** Since the *cadence* of Pattern A snapshots was already effectively broken pre-PR-24 (all writes stamped `2023-01-01`), the current threshold values were calibrated during the Airflow era. Post-PR-24, cadence normalizes to "once per dbt Cloud run of this tag." As long as that runs daily (matching the historical Airflow cadence), thresholds are still valid. Verify job schedules.
- **Store failures / audit conflict (adv Q9):** No `store_failures: true` on any of the 79 invocations. Nothing to conflict.

---

## Unresolved questions

1. **What is the dbt Cloud job schedule for `tag:loyalty_metrics`?** The correctness of the `_pct_change` thresholds (bounded ±10 between consecutive snapshots) depends on the cadence being roughly-daily. If a manual trigger runs 3× in one day, `prev_snapshot` will be an hour old and pct_change will show noise-level values — still likely passing, but semantically different.

2. **Does `cde_loyalty_balance_metrics` (`tags: ['daily']`) get executed on the same job as its siblings?** If the model runs on a `daily` job but its tests are selected by `tag:loyalty_metrics` (tag is inherited to tests), timing could split — worth confirming with a `dbt list --resource-type test --select tag:loyalty_metrics` to see whether this model's tests are included.

3. **Is there a monitoring path if a metric_threshold_check test fails?** dbt Cloud job failure alert → Slack? PagerDuty? If not, silent-pass regressions from Finding #1 will never be noticed. This is a general observability question, not specific to Pattern F, but Pattern F puts these tests back into service after months of silence — so alerting hygiene is worth revisiting.

4. **Was the pre-PR-24 silent-pass behavior noticed at all?** If these 79 tests have been passing trivially since dbt Cloud cutover, there may be undetected data-quality drift that the newly-functional thresholds will surface. First run of PR-24 in prod could produce a flurry of failures. Consider running `dbt test --select tag:loyalty_metrics` in dev against prod data (or a snapshot copy) before merging to size the blast radius.
