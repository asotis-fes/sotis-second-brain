# The flatten_override_intervals macro — what it does, and how the fix interacts

## What the macro does (applied to the `status_match` CTE, one row per surviving CDC snapshot)
Input row cols: private_fan_id, salesforce_member_id, override_start (=coalesce(trial_start,
last_modified_date)), override_end (=lead(override_start) per member else 9999), override_id,
override_tier, override_tier_rank, override_expiry, original_override_start (NULL for
status_match), **trial_target_points (← the fix is applied here, per snapshot)**, trial_start,
trial_expiry.

1. **override_changes** — per member, ordered by (override_start, override_end), sets
   `is_override_changed = 1` when the identity tuple
   `override_id || override_tier || trial_start || original_override_start` differs from the
   previous row (LAG). i.e. marks the start of a new distinct override "state".
2. **override_grouped_changes** — `group_id = running SUM(is_override_changed)` per member, so
   consecutive rows with the same identity tuple share one group_id.
3. **overrides** — `GROUP BY (member, group_id)`, collapsing each run into ONE interval:
   `interval_start = MIN(override_start)`, `interval_end = MAX(override_end)`,
   **`trial_target_points = MAX(trial_target_points)`**, and MAX() of override_id/tier/rank/
   expiry/trial_expiry. `next_interval_start = lead(interval_start)`.

## Key facts for the fix
- **The grouping identity tuple does NOT include trial_target_points** (nor last_modified_date).
  ⇒ the fix (which only changes trial_target_points) **cannot change how rows are grouped**,
  the interval boundaries, or the number of intervals. Verified: V0 mapping proof = 0 diffs.
- The fix is applied **per snapshot** in the `status_match` CTE, THEN the macro takes
  **`MAX(trial_target_points)` per group**. So the effective per-interval value =
  `MAX over the interval's snapshots of iff(lmd < launch, tgt*10, tgt)`.

## "Wonky" scenarios enumerated (the colleague's concern)
- **W1 — mixed-scale group (spans launch).** A migrated override's group has pre-launch (1x)
  and post-launch (already-10x) snapshots. Fix ×10s the pre ones → equal to the post (migration
  is exactly ×10), so `MAX` is unchanged/consistent. ✅ Correct.
- **W2 — pre-launch snapshot whose value ×10 exceeds the post value** (a human set a big value
  pre-launch). Then `MAX` picks the ×10'd pre value → over-scale. This is the ONLY genuinely
  wonky interaction. In prod it occurs on exactly 1 row: `SuneelRachamallu` (dev account). 0 real
  (UUID) customers. Shown explicitly in the test.
- **W3 — sliver intervals (trial_start change).** trial_start IS in the identity tuple, so a
  trial_start correction splits into separate groups/intervals; each is fixed by its own
  snapshots' lmd. ✅ (the 68-min newyear sliver: 100→1000, correct.)
- **W4 — grouping/interval count.** Unchanged by the fix (see key facts). Test asserts identical
  (interval_start, interval_end, override_id) sets before/after.

## EXACT test (runs the REAL macro on a subset, tables in FES_USERS.ALEX_SOTIS, 2XL)
Reproduce the FULL model — remove_empty_rows → valid_trials → status_match → **the real
flatten macro (inlined verbatim)** — twice, filtered to a subset of fan ids:
- `TP10X_SM_NOFIX`  = model with the ORIGINAL status_match CTE (raw target).
- `TP10X_SM_FIXED`  = model with the FIX in the status_match CTE.

Then:
- **T1 Faithfulness / macro understood:** `TP10X_SM_NOFIX` == prod `overrides__status_match`
  for the subset, all columns → proves the reproduction (incl. macro) is exact ⇒ we model the
  macro correctly. (If this matches, the macro is not doing anything we don't account for.)
- **T2 Interval integrity:** `TP10X_SM_FIXED` and `TP10X_SM_NOFIX` have identical
  (interval_start, interval_end, override_id) per fan — same #rows, same intervals; only
  trial_target_points differs. ⇒ the fix does not perturb the macro's grouping.
- **T3 Value correctness:** `TP10X_SM_FIXED.trial_target_points` vs independent CDC ground
  truth per interval → 0 real-customer mismatches; every changed row is exactly before×10.
- **T4 Edges:** show GOLDTEST500 (real customer, handled correctly) and SuneelRachamallu
  (dev, W2 over-scale) explicitly.

Subset = the 12 known fans + double-10x victim 00368250 + GOLDTEST500 fan 3aef9dfc + Suneel +
a deterministic sample (status-match fans with private_fan_id LIKE '00%') to add volume cheaply.

## RESULTS (2026-08-10) — tables in FES_USERS.ALEX_SOTIS, built with the REAL macro
Subset: 101 fans, 121 intervals each (NOFIX & FIXED). Build script `build_test_tables.sql`,
verify `verify_test_tables.sql`. Tables left in place for the colleague:
`TP10X_FANS`, `TP10X_SM_NOFIX`, `TP10X_SM_FIXED`.

- **T1 Faithfulness:** `NOFIX EXCEPT prod = 0` and `prod EXCEPT NOFIX = 0`. My full
  reproduction (incl. the flatten macro, inlined verbatim) equals prod
  `overrides__status_match` **row-for-row** for all 101 fans. ⇒ the macro is reproduced
  exactly = fully understood; it does nothing unaccounted-for.
- **T2 Interval integrity:** `interval_mismatches = 0` (NOFIX vs FIXED identical on
  interval_start/end, next_interval_start, tier, rank, expiries), `target_changed_rows = 16`.
  ⇒ **the fix does NOT perturb the macro** — same intervals, only trial_target_points changes.
  (This is the direct answer to the "wonky macro" concern.)
- **T3 Value correctness:** 118 override intervals, `all_mismatches = 1`,
  **`real_customer_mismatches = 0`**. The 1 is the Suneel dev account (W2). Every real
  customer's fixed target == independent CDC truth.
- **T4 Edges (NOFIX → FIXED):**
  - GOLDTEST500 (REAL customer 3aef9dfc), pre-launch trial: 500 → **5000** ✅ (the row the
    interval_end proxy got wrong; the deployed lmd fix through the real macro gets it right).
  - SuneelRachamallu (DEV): 6000 → 60000 (W2 over-scale; non-customer, zero prod impact).

**Conclusion:** the macro is deterministic and well-understood; the fix changes only the
target value and leaves every interval boundary/grouping identical; correct for 100% of real
customers when run through the actual macro.

## RE-RUN with dev/QA EXCLUDED (2026-08-10) — real customers only
All 3 tables SELECTed from prod (`LOYALTY.LOYALTY_INFO.*`); `TP10X_FANS` now filters to UUID
`private_fan_id` (drops dev/QA like SuneelRachamallu). Subset: 100 fans / 120 intervals.
- T1: NOFIX == prod → 0 / 0.
- T2: interval_mismatches = 0; target_changed_rows = 15.
- T3: 117 override intervals, **all_mismatches = 0, real_customer_mismatches = 0** (Suneel gone).
- T4a: nonuuid_fans = 0, nonuuid_fixed_rows = 0, suneel_rows = 0 (dev/QA fully excluded).
- T4b: GOLDTEST500 (real cust 3aef9dfc) 500 → 5000.
⇒ With only real prod customers, the fix is EXACTLY correct — zero mismatches of any kind
through the actual macro.

## REVIEW of Hajime's dbfork tables (2026-08-10) — his ACTUAL built model output
Tables: `FES_USERS.HAJIME_ALABANZA.DBFORK___{PROD|FIX_TP_SM_EARNED_BUG}__..._TIER_POINTS_OVERRIDES__STATUS_MATCH`
and `..._TIER_POINTS_LEDGER_V2`. (Names stored UPPERCASE — reference unquoted.)

**Verdict: Hajime's fix is value-correct and equivalent to the recommended fix on real
customers.** Evidence:
- Value pattern (33,694 matched intervals): 29,617 unchanged, **4,077 exactly ×10**,
  **0 double-10x**, 0 other ratios, **0 ×100 on real customers**. (4,077 = the exact count
  my rule predicts.)
- Correctness vs independent CDC truth: **0 real-customer mismatches** (33,692 intervals;
  lone mismatch = Suneel dev acct, same as ours).
- End-to-end on the built ledger (impacted fans): `public_facing_tier` changes for **961
  fans** / 104,042 rows; `status_match_active` for **964 fans**. Matches our independent CDC
  estimate (962 / 963) within ±1 → strong cross-validation.

**One thing to raise with Hajime (not a correctness bug):** `sm_fix` has **+2 rows** vs
`sm_prod` (33,812 vs 33,810) — entirely **extra zero-width `[t,t)` sliver intervals**
(zero_width: prod 2 → fix 4). Zero-width intervals match no transactions in the ledger join
(`ts >= t AND ts < t` is empty) so they're inert, and zero-width slivers already exist in
prod. BUT: a **target-only** fix (the one on branch `fix/entdata-2261-status-match-10x-target`
= `iff(last_modified_date < launch, tgt*10, tgt)` in the status_match CTE) provably CANNOT
change row count — so the +2 slivers mean Hajime's implementation either touches a grouping
column or the two forks were built from slightly different overrides_v2 snapshots (freshness).
Recommend confirming his diff is target-only; the minimal version yields zero structural churn.
