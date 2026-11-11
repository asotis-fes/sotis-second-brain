# Edge cases to hammer in the full test

Ordered by how likely they are to actually break the fix. Queries assume prod
`LOYALTY.LOYALTY_INFO.*` and launch var `2026-04-23 13:17:21.000 +0000`.

## 1. Boundary robustness: program-launch (13:17) vs data-migration write (~14:47) ⭐ highest value
The fix keys on `last_modified_date < 13:17:21`. But the migration that actually ×10'd the
Salesforce values wrote rows ~14:47–14:57. A snapshot last-modified in that ~1.5h gap could
still hold a 1x value yet be treated as "already 10x" (kept) → silent under-scale. We found
only 1 interval in that window (GOLDTEST500, whose snapshot was actually pre-launch). Prove
the boundary choice is immaterial for real customers: recompute the fix with two boundaries
and diff — expect 0.
```sql
WITH cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         coalesce(trial_start,last_modified_date) AS ostart, last_modified_date AS lmd, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
),
per AS (
  SELECT s.private_fan_id, s.interval_start, s.interval_end,
     max(iff(c.lmd < '2026-04-23 13:17:21.000 +0000', c.tgt*10, c.tgt)) AS fix_1317,
     max(iff(c.lmd < '2026-04-23 15:00:00.000 +0000', c.tgt*10, c.tgt)) AS fix_1500
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
  JOIN cdc c ON c.private_fan_id=s.private_fan_id AND c.override_id=s.override_id
     AND c.ostart>=s.interval_start AND c.ostart<s.interval_end
  WHERE s.override_id IS NOT NULL
    AND s.private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  GROUP BY 1,2,3
)
SELECT count(*) intervals, count_if(fix_1317 <> fix_1500) boundary_sensitive_rows  -- expect 0
FROM per;
```

## 2. post != 10x*pre for a REAL customer (the MAX-goes-wonky case, W2)
Suneel (dev) hit this. Confirm no REAL customer has an override where a post-launch snapshot
value isn't exactly 10x a pre-launch value (which would make MAX over the ×10'd group wrong).
This is what `validation_query.sql` already flags as a mismatch — run it (real-customer filter
already in it) and confirm `mismatch_rows = 0`. To see any offenders explicitly:
```sql
WITH launch AS (SELECT '2026-04-23 13:17:21.000 +0000'::timestamp_tz ts),
cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         last_modified_date AS lmd, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
    AND private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
)
SELECT private_fan_id, override_id,
       max(iff(lmd <  (SELECT ts FROM launch), tgt, NULL)) AS max_pre,
       max(iff(lmd >= (SELECT ts FROM launch), tgt, NULL)) AS max_post
FROM cdc GROUP BY 1,2
HAVING max_pre IS NOT NULL AND max_post IS NOT NULL AND max_post <> max_pre*10
ORDER BY 1 LIMIT 100;
```

## 3. In-progress trials that SPAN the launch (trial_start < launch <= trial_expiry)
For active/current trials the target only matters once the trial ends, so the customer-facing
tier won't change today — but the eventual achievement check must use the 10x target. Confirm
these overrides end up 10x (they were active at launch => migrated), and none is left at 1x.
```sql
-- list current trials (trial_expiry in future) and their fixed target scale
SELECT private_fan_id, override_id, interval_start::date, trial_expiry,
       trial_target_points AS current_prod_target
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH
WHERE override_id IS NOT NULL AND trial_expiry > current_timestamp()
  AND private_fan_id RLIKE '[0-9a-fA-F]{8}-...'  -- fill UUID regex
ORDER BY 1 LIMIT 100;   -- eyeball: any small (1x-looking) targets among live trials?
```

## 4. Same override_id re-used across non-contiguous intervals (re-enrollment)
A customer enrolled in the same campaign twice, with different targets, produces multiple
groups. Make sure each gets its own correct scale (not a merged MAX across both).
```sql
SELECT private_fan_id, override_id, count(*) AS n_intervals,
       min(trial_target_points), max(trial_target_points)
FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED
WHERE override_id IS NOT NULL
GROUP BY 1,2 HAVING count(*) > 1 ORDER BY n_intervals DESC;
```

## 5. NULL-override gap rows unchanged, and null/zero targets sane
The fix applies iff() to every row; gap rows (override_id NULL) carry null target -> stay null.
Confirm FIXED gap rows == NOFIX gap rows, and check for override rows with null/0 target.
```sql
SELECT
 (SELECT count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX WHERE override_id IS NULL
  MINUS SELECT count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED WHERE override_id IS NULL) AS gap_row_delta,
 (SELECT count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED WHERE override_id IS NOT NULL AND coalesce(trial_target_points,0)=0) AS null_or_zero_targets;
```

## 6. SCOPE question (not this model): parallel 1x/10x issues elsewhere ⭐ worth a decision
The 10x program multiplied ALL tier points. `trial_target_points` in status_match is the one
we fixed — but any OTHER stored tier-point figure compared against (now-10x) balances could
have the same bug. Check specifically:
  - `tier_points_overrides__rollover` -> `rollover_balance` (is it a tier-point balance? scaled?)
  - `tier_points_tiers_info.min_balance_number / max_balance_number` (were tier thresholds
    rescaled at launch? earn_tier is computed from current_balance vs these).
  - placement / invite_only overrides (do they carry any point threshold?)
If any of these mix 1x/10x the way status_match did, they need their own fix. Confirm this
model is the ONLY affected target, or scope follow-ups.

## RESULTS (2026-08-10)
- **#1 Boundary — PASSED.** `13:17:21` vs `14:45` differs on 4,006 real-customer intervals,
  but raw CDC shows the migration ×10 flips land at **~14:41–14:57** (all after 13:17:21) with
  a clean gap before them. So `13:17:21` correctly keeps the migrated 10x values and ×10s only
  true pre-flip 1x. For all 4,006 sensitive intervals `fix_var == authoritative latest value`
  (0 wrong); moving the cut to 14:45 would DOUBLE those 4,006. The var is on the correct side.
  (Sensitive set is mostly GOLDTEST / newyear real-customer campaigns.)
- **#6 Scope — no parallel bug in the ledger.**
  - `tier_points_tiers_info` thresholds WERE ×10'd WITH SCD versioning: 1x version valid_to
    `2026-04-23 13:01:04`, 10x version valid_from `13:01:04`. `earn_tier` joins the version
    valid at each txn timestamp → self-corrects. Not affected.
  - `rollover_balance` is in 10x units post-launch (avg ~44 pre → ~788 post) BUT the ledger
    uses rollover as a date-only check (no point threshold) → no analogous bug in tier calc.
    Flag only if rollover_balance is compared in reporting/fangraph (out of this model's scope).
- Also confirmed (per user): the `sm_fix` +2 rows vs `sm_prod` are pure CDC freshness between
  the two clone builds (prod SM clone 15:01, fix SM clone 15:11; fan ed7bed09 has a snapshot
  from today 14:17). Both extra rows are inert zero-width slivers. Not a fix/grouping effect.

## 7. Stability / idempotency (note, not a query)
The fix is a permanent re-derivation, not a one-time backfill: it keys on last_modified_date
which only increases, so past snapshots are stable and future (post-launch) snapshots are
already 10x. Re-running the model yields the same result. Confirm a second `dbt run` is a
no-op diff.
