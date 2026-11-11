# Pattern C Adversarial Review

## Summary verdict

**MERGE WITH CAVEATS** — the model SQL changes themselves are correct, but the PR **leaves one stale `var("data_interval_end")` reference in the same file** (a `post_hook` in `schema.yml`) that silently breaks retention pruning on `xp_user_attributes_snapshot` and will cause the table to grow unbounded at ~125M rows/day once the change ships. Fix the post_hook (or ship a hotfix immediately after) before merging.

---

## Findings

### CRITICAL — post_hook on `xp_user_attributes_snapshot` still references `var("data_interval_end")`, retention pruning silently no-ops

**File:** `models/xtremepush/schema.yml:33`

```yaml
post_hook: "DELETE FROM {{ this }} WHERE snapshot_date < '{{ var(\"data_interval_end\") }}'::DATE - 2"
```

- The PR changes `snapshot_date` in `xp_user_attributes_snapshot.sql` from `'{{ var("data_interval_end") }}'::DATE` (which under placeholder = `2023-01-02`) to `CURRENT_DATE`. Post-PR, rows are written with `snapshot_date = <today>`.
- **But the post_hook was NOT updated in this PR.** It still resolves to `DELETE FROM ... WHERE snapshot_date < '2023-01-02'::DATE - 2` (i.e., `< 2022-12-31`). No live row will ever satisfy this predicate → **pruning silently does nothing**.
- Pre-PR behavior: `snapshot_date` was also `'2023-01-02'` for every row, so the MERGE on `pk = HASH(user_id | '2023-01-02')` collapsed every day's snapshot onto the same PK space. Table growth was bounded (one row per user, forever overwriting).
- Post-PR behavior: PK now embeds `CURRENT_DATE` → **one row per user per day** with no pruning → table grows unbounded (~125M rows/day). At current row width and volume, this is a table-size / warehouse-cost incident within days-to-weeks of merge.
- Grep confirms the file is the only remaining `data_interval_end` var reference for the xtremepush directory (the other 4 hits are all in `models/loyalty/fancash/ledger/ledger.yaml`, out of scope for Pattern C).

**Recommendation:** In the same PR, change the post_hook to `snapshot_date < CURRENT_DATE - 2`. Do not merge without this — the moment prod runs post-merge, the pruning stops working.

---

### HIGH — `xp_user_attributes_delta` produces duplicate rows if the model runs twice in the same session-date, because the model is `incremental` with `strategy: append` and no `is_incremental()` guard or unique_key

**Files:** `models/xtremepush/xp_user_attributes_delta.sql`, `models/xtremepush/schema.yml:57-63`

- The delta model is `materialized: incremental, incremental_strategy: append` with **no `unique_key`** and **no `is_incremental()` filter** in the SQL.
- Under the old `var("data_interval_end")` placeholder, a re-run within the same run window emitted `insert_ts = '2023-01-02' + N microseconds` — same base each time → collisions only within-run, and consumers likely dedup on downstream side.
- Under the new `CURRENT_TIMESTAMP()`, every re-run emits a completely fresh insert_ts. The **`changed_attributes` set is recomputed** from the same snapshot day-pair; if the snapshot ran once and the delta runs twice, the delta will **append the exact same change set twice** with different timestamps. XP downstream will see the same "attribute change" event twice.
- This is a behavioral change in downstream consumer semantics. Fresh-run idempotency was already weak; this PR does not make it worse in the "single daily run" case, but it does eliminate the `insert_ts` collision that used to serve as a natural dedup key.
- The other two delta models (`xp_optin_preferences_delta`, `xp_push_last_opened_delta`) have the SAME `append` + no unique_key + no `is_incremental` pattern → same finding applies.

**Recommendation:** Add an `is_incremental()` guard or, better, a `unique_key: [user_id, attribute_name, snapshot_date]`-style dedup, or gate re-runs at the orchestrator. Not a blocker for this migration PR if operational practice ("run once per day") is enforced; call it out to the on-call team.

---

### HIGH — First run of `xp_user_attributes_delta` after a gap will emit ALL attributes as "new user" changes (data blast)

**File:** `models/xtremepush/xp_user_attributes_delta.sql:6-27`

- The delta compares `snapshot_date = CURRENT_DATE` vs `snapshot_date = CURRENT_DATE - 1`.
- If the snapshot has run for today but not for yesterday (e.g., first run after a scheduling gap), `previous_obj` returns 0 rows → LEFT JOIN → every user has `p.user_id IS NULL` → `is_new_user = TRUE` → **the entire user base's full attribute set is emitted as one giant append**.
- With 125M users × ~100 attributes each = 12B+ rows in one delta batch.
- Was the same risk present before? Yes, but before, `snapshot_date = '2023-01-02'` for both filters, so `current_obj` and `previous_obj` were both populated from the SAME rows. Result: no differences, empty delta. The placeholder behavior was accidentally protective.
- Post-PR, the empty-`previous_obj` case is a real production hazard when: (a) upstream retention prunes below 2 days (post_hook is broken as noted, but if fixed to `-2` and the snapshot only has 1 day), (b) the DAG resumes after a pause, (c) a `dbt build --full-refresh` on the snapshot but not the delta.

**Recommendation:** Add an explicit guard: `WHERE previous_obj HAS >0 rows` (via a `HAVING COUNT(*)` or `dbt run-operation` check) before proceeding, OR treat the "0 previous rows" case as a hard fail. At minimum, document the invariant in the model comment.

---

### MEDIUM — Timezone assumption: `CURRENT_DATE` uses Snowflake session timezone, which is user-configurable and typically not UTC in FBG

**Files:** all 6 modified xtremepush models

- Snowflake's `CURRENT_DATE` returns the date in the **session timezone**, set via `ALTER SESSION SET TIMEZONE = ...` or account-level default.
- The FBG dbt Cloud account TZ was not verified in this review (no `profiles.yml` or connection config in the repo). Snowflake's account default is `America/Los_Angeles` unless overridden. If dbt Cloud connects with default account TZ:
  - `CURRENT_DATE` in a run scheduled for 8am ET = same-day ET = still today PT (5am PT) → same date.
  - `CURRENT_DATE` in an ad-hoc run at 2am ET = still yesterday PT (11pm PT prev day) → **off-by-one**.
- The old `data_interval_end` placeholder `'2023-01-02T00:00:00.0000000+00:00'` was cast with `::DATE` — Snowflake takes the date portion in the session's TZ view of that timestamp, so had the same latent issue. Not a regression — but worth calling out as a latent bug the PR does not fix.
- The delta model comparing `snapshot_date = CURRENT_DATE` and `snapshot_date = CURRENT_DATE - 1` is only correct if both the snapshot job and the delta job compute `CURRENT_DATE` in the same session TZ. Since they run in the same dbt Cloud environment / connection, this is very likely true — but worth verifying.

**Recommendation:** Explicitly set `TIMEZONE = 'UTC'` in the dbt Cloud connection or add `SET TIMEZONE = 'UTC'` in a `+pre-hook` for these models. This eliminates ambiguity for future maintainers and matches downstream systems that assume UTC.

---

### MEDIUM — MERGE-during-midnight-crossing edge case is safe but worth verifying

**File:** `models/xtremepush/xp_user_attributes_snapshot.sql`

- `generate_pk(['user_id', 'CURRENT_DATE'])` expands to `HASH(CONCAT_WS('|', COALESCE(user_id::VARCHAR, ''), COALESCE(CURRENT_DATE::VARCHAR, '')))`.
- Snowflake evaluates `CURRENT_DATE` **per statement**, not per row. The dbt merge is a single MERGE statement:
  ```
  MERGE INTO <target> USING (<select from source query>) ON pk = pk WHEN MATCHED ...
  ```
  Both the USING-subquery and the ON-clause reference `CURRENT_DATE` — Snowflake computes it once for the whole MERGE. Even a MERGE that crosses midnight starts with a single fixed CURRENT_DATE value → the PK produced by the source will match the target PK for the same "date-partition" both before and after wall-clock midnight. **This is safe.**
- Contrast: if the snapshot MERGE and the downstream delta SELECT run as separate statements straddling midnight, they can disagree on which date is "today." Delta's WHERE `snapshot_date = CURRENT_DATE` could miss rows that the snapshot just wrote as "yesterday." Given the schedule (8am ET), this is not a practical concern.

**Recommendation:** No action required. Document the assumption for on-call: "these models must not be manually re-run after 23:30 UTC."

---

### LOW — `insert_ts` uniqueness across concurrent runs

**Files:** three delta models

```sql
TIMESTAMPADD('MICROSECOND',
  ROW_NUMBER() OVER (ORDER BY user_id, attribute_name),
  CURRENT_TIMESTAMP()::TIMESTAMP_NTZ) AS insert_ts
```

- Two concurrent runs of the same delta model within the same microsecond base + overlapping row_number offsets could theoretically produce identical `insert_ts` values.
- Snowflake `CURRENT_TIMESTAMP()` has nanosecond resolution but the cast to `TIMESTAMP_NTZ` retains microsecond precision. Two dbt runs started within the same ~1µs window is extraordinarily unlikely operationally, and dbt Cloud will not schedule concurrent runs of the same job by default.
- Pre-PR (placeholder `'2023-01-02'::TIMESTAMP_NTZ`), any two runs would emit identical `insert_ts` sequences. So this PR strictly *improves* uniqueness. Not a blocker.

**Recommendation:** None. Track as known-limitation.

---

### LOW — `xp_push_last_opened` and `xp_optin_preferences` upstream data is frozen at 2026-06-09; the sfmc_optin_preferences_import DAG has `end_date=pendulum.datetime(2026, 6, 9, ...)` and is no longer running (Salesforce sunset)

**File:** `/Users/alex.sotis/repos/fes-airflow/dags/salesforce/sfmc_optin_preferences_import.py:51`

- Confirms the 6-week staleness diagnostic is orchestration-driven (DAG terminated), not a code problem in this PR.
- Downstream implication: after this PR ships, if someone re-triggers `tag:optin_preferences` in dbt Cloud, the snapshots will get a new `snapshot_date = <today>` row but the upstream `xp_optin_preferences` / `xp_push_last_opened` tables will contain the SAME data from before (last SFMC dump was 2026-06-09). The delta's ranked-snapshot pattern (`rank=1` vs `rank=2` on `snapshot_date DESC`) will then compare today's snapshot to the most-recent-pre-June-9 snapshot → **large volume of "changes" emitted for users whose attributes haven't actually changed** — just because SFMC data is now compared across a 6-week freshness gap.
- Also: the model files are annotated `TEMPORARY: Remove after Salesforce Sunset`. Since Salesforce is sunset (based on the end_date), consider gating this cleanup in a follow-up rather than reactivating a schedule.

**Recommendation:** Do NOT unpause / re-enable a scheduled job on the optin_preferences or push_last_opened models. Coordinate with the marketing/XP owner: either drop these models, or backfill upstream and manually run.

---

### NIT — Model description in `schema.yml` still says "Merge on pk (user_id + snapshot_date)"

**File:** `models/xtremepush/schema.yml:23`

```yaml
description: Daily snapshot of xp_user_attributes. ... Merge on pk (user_id + snapshot_date) so reruns are idempotent.
```

- Post-PR, PK is `HASH(user_id | CURRENT_DATE)`. The description says "user_id + snapshot_date" — which is still accurate in effect (CURRENT_DATE == snapshot_date column), but a reader tracing the code may be confused because `snapshot_date` the column is not what's fed to the hash. Consider updating to: "Merge on pk = HASH(user_id, CURRENT_DATE), same value as snapshot_date column."

**Recommendation:** Doc fix, non-blocking.

---

## Confirmed non-issues

1. **PK stability under CURRENT_DATE evaluation timing** — Snowflake evaluates `CURRENT_DATE` per-statement; the MERGE statement is atomic. No source/target PK skew.
2. **Idempotent within-day re-runs of the snapshot model** — Confirmed. Same-day re-run uses same CURRENT_DATE → same PK per user → MERGE updates in place. Desired behavior. `_insert_ts` is excluded from merge via `merge_exclude_columns` so the first snapshot's insert_ts is preserved; `_update_ts` will be refreshed.
3. **HASH collision risk** — Unchanged by this PR. `HASH()` in Snowflake is 64-bit. At 125M users × 365 days over a year, birthday-collision is meaningfully non-zero, but this was already the case pre-fix.
4. **Downstream consumers in fes-airflow / data-transformations** — Searched all repos; no consumers directly reference the affected tables outside of the dbt project and the SFMC importer DAG (already end-dated). XtremePush consumes the delta tables via a separate ingestion path that we could not find in this codebase — presumed to be a pull from XP's side or a downstream Segment/reverse-ETL. Confirm before merge.
5. **Snapshot materialization semantics** — `incremental, merge, unique_key: ['pk']` is the correct choice for the daily-refresh model. `merge_exclude_columns: ['_insert_ts']` preserves the first-observed timestamp. Consistent with the two other snapshot models.

---

## Unresolved questions

1. **Snowflake session timezone in dbt Cloud** — Not verifiable from the repo. What TZ does the dbt Cloud project connection use? If not UTC, the whole `CURRENT_DATE` family of patterns should be reviewed org-wide (this PR touches 6 files; other Pattern-* PRs likely have the same latent question).
2. **XtremePush ingestion mechanism** — Who reads `XP.XP.XP_USER_ATTRIBUTES_DELTA` (and the two SFMC-derived tables)? Reverse-ETL job? Segment sync? A Snowflake-external XP process? Any consumer that expects `insert_ts` to be strictly monotonically increasing across runs, or that dedups on `insert_ts`, must be validated.
3. **dbt Cloud job schedule for `tag:xtremepush`** — What time (UTC/ET)? Once we confirm it runs at, say, 8am ET, the "midnight crossing" concern is closed. If it can run ad-hoc late-night, the timezone finding above escalates to HIGH.
4. **Retention on the delta tables** — `xp_*_delta` is `append` with no cleanup. Is there a downstream expiry policy? Snowflake time-travel? Do we care that yesterday's changed attributes for users who "un-changed" today are still in the table?
5. **What tests run in dbt Cloud CI for this PR?** The `dbt_utils.unique_combination_of_columns(user_id, snapshot_date)` test on `xp_user_attributes_snapshot` will pass on a green-field build but will start failing if the post_hook (CRITICAL above) is fixed and old rows are pruned mid-run. Verify CI runs the tests on a build large enough to catch retention issues.
