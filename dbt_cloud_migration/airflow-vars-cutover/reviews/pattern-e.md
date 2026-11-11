# Pattern E Adversarial Review

## Summary verdict

**MERGE WITH CAVEATS.** Pattern E's code diff is correct and safe on its own — it stops new `'2023-01-02'` placeholder stamps and preserves the anti-join incremental semantics — but the PR body **understates** the downstream breakage: a second downstream consumer (the SFMC `salesforce_marketing_cloud_fanatics_one` DAG) has the same exact-match `WHERE update_ts = data_interval_end` bug as the XP DAG and is **not** listed in the "STILL REQUIRED" section. Merging without a coordinated fes-airflow follow-up will leave XP tier events + SFMC tier-change emails at zero deliverability indefinitely.

## Findings

### CRITICAL

**C1. Second downstream consumer (SFMC export) missing from PR's "STILL REQUIRED" list**
- **What**: `fes-airflow/dags/salesforce/sql/export_fanatics_one_tier_changes.sql:28` filters `where mt.update_ts = '{{ data_interval_end | ts }}'` against `LOYALTY.loyalty_info.tier_points_marketing_triggers`. This DAG (`salesforce_marketing_cloud_fanatics_one.py`) runs every 30 min in prod and pushes tier-change rows to SFMC via SFTP for email triggers.
- **Evidence**: `grep -rn "tier_points_marketing_triggers" /Users/alex.sotis/repos/fes-airflow/` → `dags/salesforce/sql/export_fanatics_one_tier_changes.sql:23`. PR body's "STILL REQUIRED" section names only `xtremepush_tier_change_events.py`, not the SFMC DAG. Both use the identical exact-match anti-pattern.
- **Impact after merge**: 0 tier-upgrade emails via SFMC in addition to 0 events to XtremePush. This is a **customer-facing communication outage** whose scope is wider than what the PR body claims.
- **Recommendation**: Update PR body to add the SFMC DAG to "STILL REQUIRED" #1. Both DAGs need the same range-filter fix; ship them in one fes-airflow PR alongside this merge.

**C2. XP + SFMC DAG fix design isn't actually specified**
- **What**: PR body suggests `WHERE update_ts >= DATEADD('hour', -1, CURRENT_TIMESTAMP)` for the XP DAG. Both DAGs are scheduled `*/30 * * * *` (every 30 min). A 1-hour lookback overlaps with the previous run → **every tier change delivered twice** to XP and to SFMC.
- **Evidence**: `xtremepush_tier_change_events.py:141` schedule `*/30 * * * *`; `salesforce_marketing_cloud_fanatics_one.py:30` same. XP DAG has no idempotency key on the XP side (no dedupe on `user_id + transaction_timestamp`), so duplicates land as duplicate events. SFMC will re-export the same rows into a new hourly CSV → double email trigger.
- **Recommendation**: The range filter must be a **half-open window aligned to `data_interval_start` / `data_interval_end`** (e.g., `WHERE update_ts >= '{{ data_interval_start | ts }}' AND update_ts < '{{ data_interval_end | ts }}'`) — or a persistent high-water-mark checkpoint. Do not merge the fes-airflow companion PR without dedupe verification.

### HIGH

**H1. Session timezone drift risk — Snowflake `CURRENT_TIMESTAMP()::TIMESTAMP_NTZ` depends on session TZ**
- **What**: `CURRENT_TIMESTAMP()` returns `TIMESTAMP_LTZ`; the cast to `TIMESTAMP_NTZ` **preserves the wall-clock in the current session TZ**, not UTC. If the dbt Cloud PROD environment (env 70437463672974, connection 70437463660199) runs with a non-UTC session TZ, `update_ts` will drift from the wall-clock consumers expect.
- **Evidence**: I queried the dbt Cloud env config: `credentials.id=70437463679983`, `warehouse=FDE_DBT_CLOUD_WH`, `user=DBT_CLOUD`, `role=SVC_DBT_CLOUD_ROLE`. The env config does **not** declare `TIMEZONE` explicitly. `dbt_project.yml` has no `+session_parameters: {TIMEZONE: UTC}`. Snowflake's account default TZ is `America/Los_Angeles` unless overridden. If the warehouse/user parameter is not UTC, `update_ts` will be PST/PDT wall-clock cast as NTZ — 7–8 hours off from what downstream Python (which uses `pendulum` UTC-aware `data_interval_end`) expects.
- **Recommendation** (must happen before the range-filter fix ships): Run `SHOW PARAMETERS LIKE 'TIMEZONE' IN USER DBT_CLOUD;` and `SHOW PARAMETERS LIKE 'TIMEZONE' IN WAREHOUSE FDE_DBT_CLOUD_WH;`. If not `UTC`, either (a) set it explicitly, or (b) write `CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ` in the two models to guarantee UTC-anchored wall-clock. Ship a fix immediately; the current `CURRENT_TIMESTAMP()::TIMESTAMP_NTZ` is a latent timezone bug even after XP/SFMC DAGs switch to range filters (a 7-hour skew is still an easy off-by-one on window edges).

**H2. Historical bad rows (`'2023-01-02'` × 79,569) — cleanup plan is under-specified**
- **What**: PR body says "Neither model has `full_refresh_prevention` — `DELETE ... WHERE update_ts::DATE = '2023-01-02'` + `dbt run --full-refresh -s <model>` works. Or targeted UPDATE from transaction_timestamp." Both statements are technically true but leave ambiguity that will bite whoever cleans up.
- **Evidence**: `grep -rn "full_refresh_prevention" /Users/alex.sotis/repos/dbt-fes-ae/models/loyalty/fanatics_one/` → no matches. Anti-join is `transaction_id + salesforce_member_id`; `--full-refresh` will rebuild the full history from `tier_points_ledger_v2` and re-stamp **every historical row** with today's `CURRENT_TIMESTAMP()`. That obliterates historical audit trail (`update_ts` becomes "when we last rebuilt", not "when the tier change was first detected") and — critically — triggers the XP + SFMC DAGs (once fixed to a range filter) to **replay every single tier change ever recorded** as if it happened today. Estimated blast: 98K XP events + 2.3M SFMC CSV rows re-sent to customers.
- **Recommendation**: **Do not `--full-refresh`.** Use targeted UPDATE: `UPDATE tier_points_marketing_triggers SET update_ts = transaction_timestamp WHERE update_ts::DATE = '2023-01-02';` (same for `tier_changes_all`). This is roughly the correct historical value; even if not exact, it lands the rows outside any reasonable "recent tier changes" range filter and prevents the mass replay. Confirm the cleanup happens **after** the XP/SFMC DAGs are switched to range filters so the DELETE-then-DML isn't itself misread as new activity.

### MEDIUM

**M1. `unique_key` includes `public_facing_tier` but PR narrative implies `transaction_id + salesforce_member_id` uniqueness**
- **What**: `fanatics_one.yaml:297-313` — both models' `unique_key: [salesforce_member_id, transaction_id, public_facing_tier]`. The **anti-join in the SQL uses only `transaction_id + salesforce_member_id`** (`tier_changes_all.sql:80-83`). This asymmetry is fine as long as `public_facing_tier` is deterministic for a given `(salesforce_member_id, transaction_id)` — which it is, because it's computed from `tier_points_ledger_v2`. But: if `public_facing_tier` ever *changes* for an existing `(salesforce_member_id, transaction_id)` (e.g., an override backfill), the anti-join sees it as "already exists" and drops it, while the `unique_key` MERGE would have treated it as a new row. Net result: overrides that change tier assignment silently disappear from the marketing triggers table.
- **Evidence**: Anti-join in `tier_changes_all.sql:80-83` and `tier_points_marketing_triggers.sql:83-87`; unique_key at `fanatics_one.yaml:297-313`.
- **Recommendation**: Not a Pattern E bug (pre-existing), but worth flagging: either drop `public_facing_tier` from `unique_key` (matches anti-join) or add it to the anti-join JOIN condition. Track as a follow-up.

**M2. Downstream `WHERE update_ts >= ...` semantic change affects SFMC file cadence**
- **What**: SFMC DAG `COPY INTO @stage/...csv.gz` produces one file per DAG run, named by `data_interval_start`. If the DAG's SQL becomes a range filter aligned to the DAG's own window, files stay 30-min-cadence-aligned. If it becomes a naive `>= NOW() - 1h` lookback, files will overlap and SFMC will see duplicate rows across successive imports (importable but noisy — SFMC dedupes on primary key, not always tier_change_ts).
- **Recommendation**: SFMC fix must use half-open window aligned to `data_interval_start`/`data_interval_end`, not a lookback interval. Same as C2 for XP.

### LOW

**L1. `CURRENT_TIMESTAMP()` vs `run_started_at` — narrative in PR body claim is defensible but not fully audited**
- **What**: PR body says "Same value for all rows in one INSERT (Snowflake evaluates CURRENT_TIMESTAMP() once per statement)." True for a single incremental MERGE (each of these two models is one statement). But `dbt build --select tag:fanaticsone` runs many statements over ~10-20 min; each model gets its own `CURRENT_TIMESTAMP()` value. Any downstream logic that assumes `tier_points_marketing_triggers.update_ts == tier_changes_all.update_ts` for rows from the same "run" will be off by however long the intervening builds take.
- **Evidence**: `grep` in `fes-airflow` + `dbt-fes-ae` for cross-model `update_ts` join → no matches. So this is theoretical, not actual. Downgrading to LOW.
- **Recommendation**: None required now. Note in the followup fes-airflow PR that XP and SFMC DAGs must not assume the two tables share the same `update_ts` in a given window — always range-filter independently.

**L2. `on_schema_change: append_new_columns` present, but no upstream schema changes in this diff**
- **What**: Both models have `on_schema_change: append_new_columns` — safe. Just noting we're not exercising it.

## Confirmed non-issues

- **Anti-join under retry**: Correct. If run 1 commits some rows with `update_ts = T1` and then fails, run 2 sees those `transaction_id`s in `{{ this }}` and skips them. Rows produced by run 2 get `update_ts = T2`. No duplicates, no gaps. The `unique_key`-driven MERGE doesn't touch existing rows because the anti-join filters them out **before** the MERGE sees them.
- **`CURRENT_TIMESTAMP()` per-statement consistency**: Confirmed via docs — Snowflake evaluates `CURRENT_TIMESTAMP()` once per statement; all rows in one MERGE get the same value. Fine.
- **Pattern E stops the bleeding for the *data model***: New rows post-merge get real timestamps, not `'2023-01-02'`. Confirmed by reading both SQL files.
- **`is_incremental()` guard is still correct**: The anti-join only fires on incremental runs; a `--full-refresh` skips it and rebuilds everything. (Blast radius of `--full-refresh` is a separate concern — see H2.)
- **`dbt_project.yml` fallback `data_interval_end: '2023-01-02T00:00:00...'`**: These two models no longer reference `var("data_interval_end")`, so the fallback is dead code for them. Fine.

## Unresolved questions

1. **What is the session TIMEZONE for `SVC_DBT_CLOUD_ROLE` / `FDE_DBT_CLOUD_WH` / `DBT_CLOUD` user?** Need to run `SHOW PARAMETERS LIKE 'TIMEZONE' IN USER DBT_CLOUD;` (and warehouse + account) before merging. If not UTC, the `CURRENT_TIMESTAMP()::TIMESTAMP_NTZ` bug is real, not theoretical. **This is the last unknown gating "MERGE WITH CAVEATS" vs "DO NOT MERGE".**
2. **Is there any other downstream reader of `tier_changes_all.update_ts` or `tier_points_marketing_triggers.update_ts` beyond the two DAGs I found?** I grepped `fes-airflow` and `dbt-fes-ae`; nothing else. But CDW/reverse-ETL tools (e.g., Census, Hightouch, RudderStack, direct SFMC SQL query) are outside these two repos. Worth a broader Snowflake `QUERY_HISTORY` sweep filtering on these two table names before the cutover.
3. **Was the placeholder-stamped 79,569 rows ever delivered to XP/SFMC as-is?** If the DAGs matched `data_interval_end` exactly, they'd have missed the `'2023-01-02'` rows too (mismatch). But there may be a period where placeholder rows *did* match a run whose interval-end straddled Jan 2 2023 — extremely unlikely with the schedule but worth confirming there's no "we sent a bunch of Fanatics One customers a wrong tier-upgrade email in July 2026" scenario before we DELETE the bad rows.
4. **Does the `fes-airflow` PR that fixes the XP + SFMC DAGs already exist, and is it gated to merge *after* this dbt PR?** PR body says a separate fix is required but doesn't link it. Cutover ordering matters: dbt PR merges → next 30-min job stamps real timestamps → THEN fes-airflow DAG fix ships → THEN historical cleanup. Confirm the sequence with the PR author.
