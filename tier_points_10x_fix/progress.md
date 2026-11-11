# Progress log

## Snowflake connection (to confirm in T1)
- Likely conn: `FAN_DATA_EXCHANGE_PROD`, role `FES_DATA_DEVELOPER` (per prior loyalty work).
- Warehouse: use a **LARGE** — candidate `FDE_DEVELOPER_WH` sized L, or `FDE_DEVELOPER_3XL_WH`
  for huge fanflow tables. Confirm what's available.
- Scratch schema for sample tables: `FES_USERS.ALEX_SOTIS`.

## Log

### 2026-08-09 — session start
- Renamed session "10x tier points issue"; ran /project-new.
- Read PR #66 diff + the 3 dbt models + `flatten_override_intervals` macro from local
  `/Users/alex.sotis/repos/dbt-fes-ae` (branch `fix/fanflow-dedupe-pk`; PR #66 head is
  `aefb68e`, not checked out).
- Wrote up models, PR analysis, and root-cause hypothesis in findings.md.
- **T1 done:** located prod tables (`LOYALTY.LOYALTY_INFO.*`), confirmed conn/wh.
- **T3/T4 done:** CDC history for the 2 fans CONFIRMS root cause + the correct rule
  (`interval_end <= '2026-04-23 13:17:21' → ×10`). See findings.md ⭐ section and queries.md
  Q1/Q2. Rule validated against CDC ground truth for both fans (incl. a sliver-interval edge
  case that the rule handles correctly).
- **BLOCKED:** Snowflake OAuth token expired mid-session — `snow` now hangs (can't open a
  browser here). Full-table validation queries (rule-vs-PR counts, CDC cross-check) are
  written but not yet run.
  - Pending queries: `projects/tier_points_10x_fix/scratchpad`? No — the CDC validation is
    in the session scratchpad `validate_cdc.sql`; the rule-vs-PR count query is in queries.md
    below. Re-run after re-auth.
- **Sample tables:** DDL written to `sample_tables.sql` (CREATE is deny-listed for the agent,
  so user runs it). Not yet created.

### ⏭️ NEXT (after re-auth)
1. Run rule-vs-PR full-table comparison (counts of `pr_double_10x_bug` / `pr_under_10x_bug`).
2. Run the CDC per-interval cross-check (`scratchpad/validate_cdc.sql`) → expect 0 mismatches.
3. Pick 10 more affected fans, confirm rule.
4. Finalize the generalizable validation query + the corrected `status_match` CTE SQL.

### 2026-08-09 — re-auth + full validation COMPLETE
- Re-authenticated; ran Q3 (rule vs PR) and Q4 (CDC cross-check).
- **Q3:** 452 double-10x + 29 under-10x = 481 intervals PR #66 gets wrong.
- **Q4:** 33,231/33,232 intervals agree with CDC truth; 1 exception = `GOLDTEST500` test row.
- Concrete double-10x victims shown (fans `00368250`, `00577311`).
- 10 affected fans confirmed: 0 mismatches each.
- Deliverables written: `corrected_cte.sql`, `validation_query.sql`, `decisions.md` (locked).

### 2026-08-09 (later) — location decided + pre-ship tests done
- Consumer analysis → **fix upstream in `overrides__status_match`** (user-confirmed). pfi
  self-handles scale; override_transactions drops the target (dead passthrough).
- Test A (end-to-end): fix correctly removes false status-match grants (current prod
  over-grants pre-launch trials). Test B: override_transactions passthrough is dead.
  Test C: 3,396 affected fans, 415 double-10x fans, 1 migration-fuzzy interval; `goldtest%`
  = REAL "Gold Fast Track" campaign (not test).
- Chosen fix = per-snapshot `last_modified_date` normalize (`corrected_upstream.sql`).
  Definitive validation: **real customers 0 mismatches / 33,233**; only anomaly is dev
  account SuneelRachamallu (zero prod impact).

### 2026-08-10 — fix applied to a branch (UNCOMMITTED, per user)
- dbt-fes-ae: created branch `fix/entdata-2261-status-match-10x-target` off `origin/main`
  (fetched 00ec3d0). Working tree was clean.
- Confirmed the ledger `status_match` CTE on main is already a plain passthrough → no ledger
  change needed (PR #66 stays unmerged / to be closed).
- Applied the single upstream edit to
  `models/loyalty/fanatics_one/tier_points_overrides__status_match.sql` (status_match CTE):
  `o.trial_target_points` → `iff(o.last_modified_date < '{{ var("10x_launch_timestamp") }}',
  o.trial_target_points*10, o.trial_target_points) AS trial_target_points`. +comment.
- `last_modified_date` confirmed available in `remove_empty_rows_before_first_status_match`.
- NOT committed (per user). Diff = 10 insertions / 1 deletion, one file.
- TODO next: optionally `dbt compile`/parse sanity check; add a schema test; then user reviews
  & commits/PRs referencing ENTDATA-2261. Close PR #66.

### 2026-08-10 — FIX MERGED & VERIFIED LIVE IN PROD ✅
- Prod tables rebuilt today: `TIER_POINTS_OVERRIDES__STATUS_MATCH` last_altered 17:31,
  `TIER_POINTS_LEDGER_V2` 17:42. (Both `materialized: table` → fix applied on normal run;
  no full-refresh needed. Upstream ingestion incrementals — overrides_v2, transaction_journal
  — must NOT be full-refreshed, row-loss risk; not needed.)
- Live prod global check: 33,692 override intervals, 33,691 match fixed expectation,
  **0 real-customer mismatches** (1 non-match = SuneelRachamallu dev acct).
- Sample fans in live prod show corrected values: 8ad58668 600→6000/3000→30000/2000→20000,
  CaesarsRewards stays 1000; 00577311 Boosted 300→3000, newyear stays 1000 (no double-10x).
- End-to-end (live ledger): fan 00577311 post-trial-expiry now earn_tier=public_facing_tier=
  "ONE member pro", status_match_active=false, sm_target=3000. Public tier correctly dropped
  from "ONE gold". BUG FIXED IN PROD.
- FOLLOW-UP (not blocking): downstream INCREMENTAL reporting/fangraph models won't restate
  history on a normal run — targeted `--full-refresh` (safe; inputs are table models):
  pfi_fanatics_one_attributes, dim_fanatics_one, enterprise_metrics_fo_opco, tier_changes_all,
  tier_points_marketing_triggers.

### STATUS: FIX LIVE IN PROD & VERIFIED. Remaining (optional)
1. Apply `corrected_upstream.sql` to `dbt-fes-ae` on a fresh branch off `main`
   (`models/loyalty/fanatics_one/tier_points_overrides__status_match.sql`), revert the
   ledger `status_match` CTE to passthrough, open PR referencing ENTDATA-2261.
   NOTE: local clone is on branch `fix/fanflow-dedupe-pk` — branch off main.
2. (optional) Create FES_USERS.ALEX_SOTIS sample tables — run `sample_tables.sql`.
3. (optional hardening) cdc_expected-semantics variant if guarding against human-entered
   10x-magnitude pre-launch targets (only dev accounts observed).
