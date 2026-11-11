# Wave 2 — Broader Diagnostic (Post PR 22 Merge)

**Date**: 2026-07-23
**Method**: Local grep of `dbt-fes-ae` for every `var("data_interval_*") / var("ds_nodash")` reference (30 hits, 6 usage patterns), then Snowflake `MAX(<affected column>)` per prod target via `dbt show --inline` at `--target dev`.

**Verdict**: Wave 2 is **NOT the same incident as fanflow**. Most models are running normally. Three distinct problems surfaced initially — a **fourth was discovered after user noticed `xtremepush_tier_change_events.py` docstring didn't match its code**. See "Problem 4" below.

---

## Full model inventory by pattern

Pattern classifications from the grep, with prod FQN + which column carries the "affected value":

| Pattern | Description | Models | Prod target | Affected column |
|---|---|---|---|---|
| **A** | Snapshot column: `var("data_interval_start")::TIMESTAMP AS snapshot_ts` | 13: cde_loyalty_analytics_ledger_metrics, cde_loyalty_balance_metrics, cde_loyalty_state_metrics, cde_loyalty_earn_burn_mapper_metrics, cde_tier_points_ledger_metrics, cde_tier_points_overrides_metrics, fancash_balance_collectibles_metrics, fbg_loyalty_{analytics_ledger,balance,state,earn_burn_mapper}_metrics, tier_points_{ledger,overrides}_fbg_metrics | CDE.CDE_COMMERCE_LOYALTY.* / FDE_COLLECTIBLES.FDE_COLLECTIBLES_INFO.* / FDE_FBG.FDE_FBG_INFO_SOURCE.* / LOYALTY.LOYALTY_INFO.* | `snapshot_ts` |
| **B** | Date-window filter: `WHERE _insert_ts >= var - INTERVAL ...` | 6: commerce/stage/fan_id_register_dtl, growthloop/gl_new_to_x_registration_events, loyalty/fancash/{ledger_upstream/loyalty_redeem, redeem_matching/new_ledger_txn, redeem_matching/unconnected_earn, redeem_matching/redeem_matches} | COMMERCE.STAGE / GROWTHLOOP.FLYWHEEL_SYSTEM / LOYALTY.LOYALTY_CORE / LOYALTY.SOURCE | `_insert_ts` (or `creation_time` for LOYALTY.SOURCE.*) |
| **C** | PK / snapshot_date column: `generate_pk(['user_id', var("data_interval_end")])` + `snapshot_date` | 6: xtremepush/{xp_user_attributes_snapshot, xp_user_attributes_delta, xp_push_last_opened_snapshot, xp_push_last_opened_delta, xp_optin_preferences_snapshot, xp_optin_preferences_delta} | XP.STAGE.* / XP.XP.* | `snapshot_date` (snapshots) / `insert_ts` (deltas) |
| **D** | Post-hook row-count tagging: `loyalty_insert_row_count(..., var('data_interval_end'))` | 4 post_hook entries in loyalty/fancash/ledger/ledger.yaml | LOYALTY.FANCASH_LEDGER (attached to ledger models) | n/a — instrumentation only |
| **E** | `update_ts` stamp: `var("data_interval_end")::timestamp_ntz AS update_ts` | 2: loyalty/fanatics_one/{tier_changes_all, tier_points_marketing_triggers} | LOYALTY.LOYALTY_INFO.* | `update_ts` |
| **F** | Threshold-test macro: `snapshot_ts_col = var("data_interval_start")::TIMESTAMP` | 1: macros/tests/metric_threshold_check.sql | n/a — used by Pattern A `tests:` blocks | n/a |

---

## Diagnostic query results (prod, 2026-07-23)

### Pattern A — 13 loyalty metric models (ALL frozen identically)

```
cde_loyalty_analytics_ledger_metrics  89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
cde_loyalty_balance_metrics           89 rows  MIN 2026-04-24 12:00  MAX 2026-07-21 12:00
cde_loyalty_state_metrics             89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
cde_loyalty_earn_burn_mapper_metrics  89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
cde_tier_points_ledger_metrics        89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
cde_tier_points_overrides_metrics     89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
fancash_balance_collectibles_metrics  89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
fbg_loyalty_analytics_ledger_metrics  89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
fbg_loyalty_balance_metrics           89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
fbg_loyalty_state_metrics             89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
fbg_loyalty_earn_burn_mapper_metrics  89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
tier_points_ledger_fbg_metrics        89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
tier_points_overrides_fbg_metrics     89 rows  MIN 2026-04-24 14:00  MAX 2026-07-21 14:00
```

- All 13 share tag `loyalty_metrics` (per `dbt Cloud jobs list — dbt_loyalty_metrics job execute_steps = "dbt build --select tag:loyalty_metrics"`).
- Snapshots ran successfully daily from 2026-04-24 (cutover) through 2026-07-21 14:00, then **stopped**.
- Nothing pinned to 2023 → placeholder default is NOT the cause. Real `data_interval_start` values were being passed successfully until 2026-07-21 14:00.
- Not a code issue in the models — this is orchestration ceasing to fire.

### Pattern C — 6 xtremepush models (2 subgroups)

```
xp_user_attributes_snapshot     125,373,187 rows  MAX(snapshot_date) 2026-07-22
xp_user_attributes_delta         21,684,152,536   MAX(insert_ts)    2026-07-22 12:01:55
xp_push_last_opened_snapshot        1,333,931     MAX(snapshot_date) 2026-06-09   ← 6+ weeks stale
xp_push_last_opened_delta             785,850     MAX(insert_ts)    2026-06-09 14:30
xp_optin_preferences_snapshot       5,004,362     MAX(snapshot_date) 2026-06-09   ← 6+ weeks stale
xp_optin_preferences_delta         17,536,278     MAX(insert_ts)    2026-06-09 14:30
```

- `xp_user_attributes*` running fine — daily cadence, ran yesterday.
- **`xp_push_last_opened*` and `xp_optin_preferences*` are BOTH frozen at 2026-06-09**. Consistent freeze timestamp (14:30) suggests one shared orchestrator stopped there.
- The `optin_preferences` freeze at 2026-06-09 predates the `dbt_optin_preferences` job even having runs (queried API — job has 0 runs since being created). The Airflow DAG `sfmc_optin_preferences_import.py` uses `steps_override` with `--vars` — but the DAG hasn't fired since well before cutover.

### Pattern E — 2 Fanatics One models

```
tier_changes_all                98,318 rows  MAX(update_ts) 2026-07-22 15:00
tier_points_marketing_triggers 2,342,830     MAX(update_ts) 2026-07-22 15:00
```

Both fresh (yesterday, identical time — same DAG/job). No issue.

### Pattern B — 5 loyalty date-filter models

```
fan_id_register_dtl    14,286,794      MAX(_insert_ts)    2026-07-22 19:43:45
loyalty_redeem      5,693,898,045      MAX(_insert_ts)    2026-07-22 14:19:19
new_ledger_txn            161,929      MAX(creation_time) 2026-07-22 13:58:38
unconnected_earn      158,298,076      MAX(creation_time) 2026-07-22 13:58:38
redeem_matches        316,990,423      MAX(creation_time) 2026-07-22 13:58:38
```

All fresh — daily cadence, ran yesterday. No issue.

### Pattern B — the model that doesn't exist

`GROWTHLOOP.FLYWHEEL_SYSTEM.GL_NEW_TO_X_REGISTRATION_EVENTS` — table not found. Model was added to the repo but has never been materialized in prod. Third distinct problem.

### Patterns D + F

Not directly queryable — D is post-hook instrumentation on the ledger models; F is a test macro used by Pattern A models. Both will resolve when their host models are resolved.

---

## Three separate problems identified

### Problem 1 — xp_push_last_opened + xp_optin_preferences frozen 6+ weeks (highest impact)

- **4 tables frozen at 2026-06-09 14:30**.
- Impact: every FanApp / XtremePush push-open signal and every FanApp/XP opt-in preference update since 2026-06-09 has been silently dropped from `XP.XP.XP_*_DELTA`, which feeds downstream marketing sync + retention analytics.
- Not caused by fanflow / migration timeline — predates by ~6 weeks.
- **Not a code bug in the models** — the `xp_user_attributes` sibling uses identical code and runs fine.
- Cause is orchestration: the DAG/job that runs these two tag groups has been paused, erroring, or dropped from the schedule since June 9.

### Problem 2 — 13 loyalty metric models frozen 2 days (moderate impact)

- **All 13 stopped writing snapshots at 2026-07-21 14:00**.
- Historical rows are healthy (2026-04-24 → 2026-07-21 with real dates, not placeholder-pinned).
- Cause is orchestration: whatever fires `tag:loyalty_metrics` stopped 2 days ago. Probably coincides with a migration or DAG cutover event.
- Not urgent-urgent (these are dashboards / monitoring, not customer-facing), but the FANATICS ONE monitoring blind-spot is worth closing.

### Problem 3 — gl_new_to_x_registration_events never materialized

- Table doesn't exist in prod.
- Model was added to the repo but never had a successful first run.
- Impact: any downstream that reads it doesn't exist yet, so no active breakage — but the model isn't doing what it was written for.

### Problem 4 — Fanatics One tier change events → XtremePush pipeline is BROKEN (data loss)

**Discovered after user flagged that `xtremepush_tier_change_events.py` docstring
describes an ExternalTaskSensor + dbt trigger that don't exist in the code.**

**End-to-end trace**:

1. `dags/xtremepush/xtremepush_tier_change_events.py` — the Airflow DAG:
   - Docstring says: wait for dbt `tier_points_marketing_triggers`, then send to XP.
   - Actual code (lines 162–179): one PythonOperator, **no ExternalTaskSensor, no
     dbt Cloud trigger**. Passes `data_interval_end` into a Snowflake SQL template.
   - Schedule: every 30 min in prod.

2. `dags/xtremepush/sql/select_tier_change_events.sql` line 27:
   ```sql
   WHERE mt.update_ts = '{{ params.data_interval_end }}'
   ```
   Filters `LOYALTY.LOYALTY_INFO.tier_changes_all` by exact-match on Airflow's
   `data_interval_end` timestamp.

3. `dbt_fanatics_one` dbt Cloud scheduled job (env 974, cron `*/30 * * * *`):
   - Executes: `dbt build --select tag:fanaticsone`.
   - **No `--vars` passed**.
   - Rebuilds `tier_changes_all` and `tier_points_marketing_triggers` with
     `'{{ var("data_interval_end") }}'::timestamp_ntz AS update_ts` — which
     resolves to `'2023-01-02T00:00:00'` (the placeholder default in
     dbt_project.yml).
   - Both models use anti-join incremental strategy (`WHERE existing.transaction_id
     IS NULL`), so old rows keep their real `update_ts`, new rows get stamped
     `2023-01-02`.

**Consequence**:
- Every 30 min dbt writes new tier-change rows with `update_ts = 2023-01-02`.
- Every 30 min the XP DAG queries `WHERE update_ts = '2026-07-23T05:00:00'` → **0 rows**.
- **Real tier changes are silently NOT being sent to XtremePush.**

**Confirmed corruption in prod tables** (queried 2026-07-23):

```
tier_points_marketing_triggers:  2,342,830 rows total   79,210 stamped '2023-01-02'
tier_changes_all:                   98,318 rows total       359 stamped '2023-01-02'
```

Every subsequent `dbt_fanatics_one` run adds more.

**When did it break?**
- Last legit real-var stamp: `MAX(update_ts) = 2026-07-22 15:00:00`. Every row past
  that point got the placeholder.

**Fix options**:

1. **Restore Airflow-triggered dbt with `steps_override`**. Change `dbt_fanatics_one`
   to be Airflow-driven with `--vars '{data_interval_end: "{{ data_interval_end | ts }}"}'`,
   and add an ExternalTaskSensor in `xtremepush_tier_change_events` waiting on the
   dbt build to complete. Preserves the original "coordinated data_interval_end"
   design that the docstring implies was intended.

2. **Decouple the timing**. Change `tier_changes_all.update_ts` /
   `tier_points_marketing_triggers.update_ts` to use `run_started_at` (dbt-native),
   and change the XP DAG's filter to a target-table high-water on some send-log
   (e.g., `WHERE update_ts > MAX(sent_update_ts) FROM xp_send_log`). Eliminates the
   need for coordinated timing.

3. **Stop-gap**: change the XP DAG's WHERE filter to a range instead of exact match,
   e.g., `WHERE update_ts >= DATEADD('hour', -1, CURRENT_TIMESTAMP)`. Buys time.

**Cleanup work required**:
- Delete or repair the 79,210 (+ 359) placeholder-stamped rows in the two prod
  tables. Options: DELETE + `--full-refresh` (both models have no
  `full_refresh_prevention`), or targeted UPDATE to reset `update_ts` from the
  transaction_timestamp / original event ts.
- Backfill the tier-change events that WERE lost from XtremePush since 2026-07-22
  15:00 (need to identify the affected `martech_id`s and re-send).

---

## What this diagnostic tells us about "should we fix Wave 2 code?"

**Almost no**. The models that are broken (Problems 1 + 2) are broken because their **orchestrator stopped firing**, not because their `var()` references fell back to placeholders. Their historical rows have real dates. Removing the `var()` dependency won't fix the freeze.

Only Problem 3 (gl_new_to_x) might benefit from code work, and only if we determine the first-run has been failing due to the var pattern (needs investigation).

So Wave 2 is 90% ops, 10% code — the opposite of the fanflow fix.

---

## Recommended next steps

1. **Problem 1 (xp_push_last_opened + xp_optin_preferences)**: find the owning DAG in `fes-airflow` (probably `xtremepush_tier_change_events.py` or a sibling). Check whether it's paused, erroring, or the models aren't included in any active tag selector. This is highest impact.
2. **Problem 2 (loyalty metrics)**: find what fires `tag:loyalty_metrics`. Check whether it's the `dbt_loyalty_metrics` dbt Cloud scheduled job (cron?) or an Airflow-triggered one. Confirm why it stopped at 2026-07-21 14:00.
3. **Problem 3 (gl_new_to_x)**: manually trigger the model's first run; if it fails, check if the failure is related to the var pattern (the model uses `data_interval_end` in a filter — first run would use the placeholder default, which might produce 0 rows and prevent the initial create).

## Query used

```sql
-- Pattern A
SELECT '<name>' AS m, COUNT(*), MIN(snapshot_ts), MAX(snapshot_ts)
  FROM <prod fqn>
UNION ALL ...

-- Pattern C snapshots
SELECT '<name>', COUNT(*), MAX(snapshot_date) FROM XP.STAGE.<...>
-- Pattern C deltas
SELECT '<name>', COUNT(*), MAX(insert_ts) FROM XP.XP.<...>

-- Pattern E
SELECT '<name>', COUNT(*), MAX(update_ts) FROM LOYALTY.LOYALTY_INFO.<...>

-- Pattern B
SELECT '<name>', COUNT(*), MAX(_insert_ts) FROM <target>   -- most
SELECT '<name>', COUNT(*), MAX(creation_time) FROM LOYALTY.SOURCE.<...>  -- LOYALTY.SOURCE
```

Ran via `dbt show --inline --target dev --limit 30` with FES_DATA_DEVELOPER role. See `/tmp/diag_final.sql` in local session for the composed UNION ALL.
