# Plan

## Task list

- [x] **T0. Scaffold project + ingest PR/models.** (done)
- [ ] **T1. Locate physical tables in Snowflake.** Resolve where the dbt models
  materialize: `tier_points_overrides_v2`, `tier_points_overrides__status_match`,
  `tier_points_ledger_v2`. Confirm schema/db (likely `FES_...`). Confirm the raw
  Salesforce source table for `TrialTargetPoints_c__c` etc.
- [ ] **T2. Build sample tables in `FES_USERS.ALEX_SOTIS`** filtered to the 2 fan ids:
  - raw overrides (`..._overrides_v2` slice)
  - `..._status_match` slice
  - the transaction journal / ledger slice for those members (to see earned points scale)
  - Prefix e.g. `TP10X_OVERRIDES_V2_SAMPLE`, `TP10X_STATUS_MATCH_SAMPLE`, etc.
- [ ] **T3. Diagnose the exact shape** for the 2 fan ids: how many override rows, their
  trial_start / interval_start / interval_end / trial_expiry / last_modified_date, and
  the stored trial_target_points values. Determine which rows are 1x vs already-10x by
  eyeballing magnitudes + dates.
- [ ] **T4. Derive correct 10x rule** (date-based). Candidate:
  `trial_target_points * 10 WHEN <date field> < 10x_launch_timestamp`. Validate it
  reproduces the intended target for both fan ids.
- [ ] **T5. Confirm PR #66 is wrong** on these fan ids (show a row it double-10xes or one
  it fails to 10x).
- [ ] **T6. Pick 10 more affected fan ids**, apply the derived rule, confirm correct.
- [ ] **T7. Generalizable validation query** — a single query over the full table that
  returns TRUE (or zero offending rows) when the fix is correct for everyone. If we can
  fix specific ids but can't fully generalize, document what's uncertain.
- [ ] **T8. Write up** the correct fix (SQL for the `status_match` CTE) in decisions.md.

## Constraints / notes
- SELECT-only in Snowflake per team safety rules. Creating tables in a personal
  `FES_USERS.ALEX_SOTIS` scratch schema is allowed for this investigation (CTAS). If the
  deny list blocks CREATE, provide the exact SQL for the user to run.
- Large warehouse (see progress.md for the exact WH once confirmed).
