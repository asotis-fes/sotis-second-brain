# Queries log

Format: what we ran, why, result, verdict (confirms / denies hypothesis).

## Setup facts (T1)
- Prod tables: `LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2` (60M CDC rows),
  `..._OVERRIDES__STATUS_MATCH` (33,350 flattened intervals), `..._TIER_POINTS_LEDGER_V2`.
- Conn `FAN_DATA_EXCHANGE_PROD`, role `FES_DATA_DEVELOPER`, wh `FDE_DEVELOPER_2XL_WH`.
- `10x_launch_timestamp = '2026-04-23 13:17:21'` (UTC / ntz).

## Q1 — Raw CDC series for the 2 fans (overrides_v2)
Showed target `100`/`600`/`3000`/`2000` pre-4/23, and the member's **current** override
target jumping ×10 on the 2026-04-23T14:xx CDC row (100→1000; start_pts 25.83→258.30,
2132.32→21323.20). CONFIRMS: migration multiplied the current record's target in place.
Older/expired overrides never got a post-4/23 row → stayed 1x. **Confirms root cause.**

## Q2 — interval_end rule vs CDC ground-truth, 2 fans
`rule_x10 = (interval_end <= launch)` vs `truth_x10 = (no post-launch CDC row for override)`.
Agreed on 5/6 rows. The 1 "mismatch" is a **sliver interval** and is actually the rule
being MORE correct than the coarse proxy:

- Fan `7c25289f` override `newyear-…` is split into 2 intervals because `trial_start` was
  corrected 17:51:17 → 18:59:55 on 2026-01-07 (override_start = coalesce(trial_start,lmd)):
  - sliver `[17:51:17, 18:59:55)` stored target **100** (1x) — superseded 68 min later, so
    its own snapshots were never migrated. rule_x10=True → 100×10=1000. **Correct.**
  - main `[18:59:55, 9999)` stored **1000** (already 10x). rule_x10=False → keep. **Correct.**
  - My `truth_x10` was keyed at override level (n_post>0 for the whole override) so it said
    "don't x10" for BOTH — too coarse. Per-interval, the sliver's stored 100 IS 1x and
    DOES need ×10. **Rule wins; proxy was mis-keyed.**

**Takeaway:** the discriminator is per-interval `interval_end <= launch`, and it is
provably equivalent to "this interval's stored value is still 1x" because intervals are
contiguous (all constituent CDC snapshots have last_modified < launch  ⇔  interval_end ≤
launch).

## Q3 — Full-table rule vs PR #66 (PENDING re-auth)
```sql
WITH launch AS (SELECT '2026-04-23 13:17:21'::timestamp_ntz AS ts),
base AS (
  SELECT s.*, (SELECT ts FROM launch) AS launch_ts,
    max(CASE WHEN override_id IS NOT NULL THEN interval_start END)
      OVER (PARTITION BY salesforce_member_id, private_fan_id) AS latest_override_start
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
),
flags AS (
  SELECT *,
    (override_id IS NOT NULL AND interval_end <= launch_ts) AS rule_x10,
    (override_id IS NOT NULL AND interval_start <> latest_override_start) AS pr_x10
  FROM base
)
SELECT count(*) total_intervals, count_if(override_id IS NOT NULL) override_intervals,
  count_if(rule_x10) rule_x10_cnt, count_if(pr_x10) pr_x10_cnt,
  count_if(rule_x10 <> pr_x10) disagreements,
  count_if(pr_x10 AND NOT rule_x10) pr_double_10x_bug,   -- PR ×10s an already-10x row
  count_if(rule_x10 AND NOT pr_x10) pr_under_10x_bug     -- PR fails to ×10 a 1x row
FROM flags;
```

## Q5 — Test A: end-to-end achievement (sample fans + victims)
Sum of 10x `derived_tier_points_amount` over each trial window vs target under raw/fix/pr.
**3 real achievement flips** where CURRENT prod (raw 1x target) falsely grants status match:
- `00577311` Boosted-DraftKingsDynasty: earned 1,072 vs raw 300 → fix 3,000 (was ✅, now ❌)
- `7c25289f` newyear sliver: earned 655 vs raw 100 → fix 1,000 (was ✅, now ❌)
- `8ad58668` nfl_mgm_noir: earned 11,906 vs raw 2,000 → fix 20,000 (was ✅, now ❌)
→ **Current unfixed ledger OVER-grants** pre-launch trial tiers. Fix restores the correct bar.
Caveat: earned sum is approximate (includes some void/clawback rows → a few large negatives),
but all positive cases flip correctly. Fix and PR agree on achievement for these fans (the
PR double-10x victims here didn't earn near target, so no achievement flip — but PR is still
wrong on VALUE and would flip customers who earned between 1x·10 and 1x·100).

## Q6 — Test C: boundary + population
| metric | value |
|---|---|
| intervals in migration fuzzy window (13:17→15:00) | **1** (GOLDTEST500 only) |
| fans needing ≥1 ×10 | 3,396 |
| fans PR #66 double-10xes | 415 |
| intervals needing ×10 | 4,078 |
| `%TEST%`/goldtest override intervals | 14,696 (**real "Gold Fast Track" campaign — NOT test**) |

⚠️ **Correction:** `goldtest%` → "Gold Fast Track" (real campaign, per `pfi_status_matches`
line 224). The 1 CDC mismatch (`GOLDTEST500`, fan `3aef9dfc`) is a REAL customer. The
`interval_end` proxy mis-handles it; the **`last_modified_date` per-snapshot rule handles it
correctly** (only snapshot dated 2026-04-06 < launch → ×10). Do NOT exclude `%TEST%`.

## Q7 — DEFINITIVE validation of the chosen upstream (last_modified_date) fix
`validation_query.sql`: per interval, `fix_output = MAX(iff(lmd<launch, tgt*10, tgt))` vs
`cdc_expected = iff(no post-launch snapshot, MAX(tgt)*10, MAX(tgt))`.
- All 33,235 intervals: **1 mismatch** = `SuneelRachamallu` (a **dev/QA account**, non-UUID).
  Its BetRivers override had a human-entered 6000 target pre-launch (not 1x); the lmd rule
  ×10s it to 60000 while the authoritative post-launch value is 6000. Opposite failure mode
  from GOLDTEST500, and it lands on a non-customer.
- **Real customers only (UUID fan_id): 33,233 intervals, `0` mismatches.** ✅

**Net:** the upstream lmd fix is correct for **100% of real customers** (handles the
GOLDTEST500 real-customer edge that the interval_end proxy misses). The one dev-account
over-scale has zero production/customer-facing impact. The interval_end proxy, by contrast,
gets 1 REAL customer wrong. → upstream lmd fix confirmed.

## Q8 — Sample-table materialization + faithfulness (2026-08-10)
CREATE is deny-listed for the agent → user runs `create_fixed_sample.sql` to build
`FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_FIXED` (prod flattened rows + trial_target_points
recomputed via the deployed snapshot-level rule; keeps `trial_target_points_before` for diff).
- **Faithfulness proof (V0):** a NO-FIX reconstruction (MAX raw target over each interval's
  snapshots) == prod's flattened trial_target_points → **0 mismatches / 33,692 intervals.**
  Confirms the snapshot→interval mapping reproduces prod's flatten, so the FIXED recompute is
  a trustworthy stand-in for the built model. Verify queries in `verify_fixed_sample.sql`.
- Method note: fix changes only trial_target_points; flatten grouping is independent of it,
  so recomputing the target on prod's rows == the deployed model's output.

## Q9 — public_facing_tier impact (per-fan, `public_tier_impact.sql`)
Joins `tier_points_ledger_v2` to the inline fixed target; shows status_match_active &
public_facing_tier current-vs-fixed. Fan `00577311`: after the DraftKings trial expired
(2025-10-16) the customer is publicly **ONE gold** because target=300 (1x) & earned=1072
(10x); fixed target=3000 → not achieved → public tier should drop to **ONE member pro**
(their earn_tier). The later newyear trial (target already 10x=1000) is unaffected —
confirms the fix only corrects under-scaled pre-launch trials. Query filtered on 00577311
with the other 11 sample/affected fan ids commented in the WHERE block.

## Q4 — Independent CDC per-interval cross-check
See `scratchpad/validate_cdc.sql`. Maps each raw CDC snapshot to its flattened interval by
override_start window and flags "already 10x" iff a post-launch snapshot contributed;
compares to `interval_end <= launch`.

## RESULTS (2026-08-09, after re-auth)

### Q3 — rule vs PR #66 (all 33,235 override intervals)
| metric | value |
|---|---|
| rule ×10 count | 4,077 |
| PR ×10 count | 4,500 |
| disagreements | **481** |
| **PR double-10x BUG** (PR ×10s an already-10x row → 100x) | **452** |
| PR under-10x BUG (PR fails to ×10 a 1x row) | 29 |

→ PR #66 mis-scales 481 intervals. The 452 double-10x is exactly the reported symptom.

### Q4 — CDC cross-check
`33,232` intervals checked, **`1` mismatch**. The rule agrees with the independent
CDC-derived ground truth on 33,231 (99.997%).

The single mismatch: fan `3aef9dfc-…`, override **`GOLDTEST500-…`** (a TEST override).
interval `[2026-04-06, 2026-04-23T14:44:53)`; one CDC snapshot only (target 500, lmd
2026-04-06), never migrated (n_post=0). It was active at the 13:17:21 launch instant yet
the migration did NOT 10x it (test data), then it was replaced 14:44 same day. rule says
keep (interval_end > launch) but truth says ×10.
- **No date-based rule on the interval table can catch this** — it was active at launch, so
  every such rule expects it to have been migrated. It's a migration data-exception on a
  test account, not a logic error. Negligible (1 test row).
