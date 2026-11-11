-- Shows the 10x status-match-target bug reaching public_facing_tier, for ONE fan.
-- Swap the fan id in the WHERE clause (others commented). Self-contained: recomputes the
-- fixed target inline (same snapshot-level rule the fix deploys) so no sample table needed.
--
-- Read the result: after the trial expired, `active_now`/`public_now` show the customer
-- CURRENTLY carrying the elevated status-match tier because earned_10x >= target_raw (1x).
-- With the fix, target_fixed (10x) makes active_fixed = FALSE, so public_facing_tier should
-- fall back to earn_tier. Rows where active_now=TRUE but active_fixed=FALSE and
-- public_now = sm_tier are the ones whose public tier is wrong today.

WITH launch AS (SELECT '2026-04-23 13:17:21'::timestamp_ntz AS ts),
cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         coalesce(trial_start, last_modified_date) AS ostart,
         last_modified_date AS lmd, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
),
sm AS (   -- per status-match interval: current (raw) target + fixed target
  SELECT s.salesforce_member_id, s.private_fan_id, s.interval_start, s.interval_end,
         s.override_tier, s.override_expiry, s.trial_expiry,
         any_value(s.trial_target_points) AS target_raw,
         max(iff(c.lmd < (SELECT ts FROM launch), c.tgt * 10, c.tgt)) AS target_fixed
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
  JOIN cdc c ON c.private_fan_id = s.private_fan_id AND c.override_id = s.override_id
     AND c.ostart >= s.interval_start AND c.ostart < s.interval_end
  WHERE s.override_id IS NOT NULL
  GROUP BY 1,2,3,4,5,6,7
)
SELECT
    tp.transaction_timestamp::date       AS ts,
    tp.earn_tier,                              -- tier they actually earned
    sm.override_tier                      AS sm_trial_tier,
    tp.public_facing_tier                 AS public_tier_now,      -- current prod (buggy)
    tp.status_match_active                AS sm_active_now,
    round(tp.status_match_trial_earned_points, 0) AS earned_10x,
    sm.target_raw                         AS target_now_1x,        -- current prod target (under-scaled)
    sm.target_fixed                       AS target_fixed_10x,
    -- recompute status_match_active under the fixed target (ledger logic lines 222-226)
    (tp.transaction_timestamp <= sm.trial_expiry
     OR (tp.transaction_timestamp <= sm.override_expiry
         AND tp.status_match_trial_earned_points >= sm.target_fixed)) AS sm_active_fixed,
    iff(tp.status_match_active
        AND NOT (tp.transaction_timestamp <= sm.trial_expiry
                 OR (tp.transaction_timestamp <= sm.override_expiry
                     AND tp.status_match_trial_earned_points >= sm.target_fixed))
        AND tp.public_facing_tier = sm.override_tier,
        'PUBLIC TIER DROPS -> ' || tp.earn_tier, '') AS impact
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 tp
JOIN sm ON tp.salesforce_member_id = sm.salesforce_member_id
       AND tp.transaction_timestamp >= sm.interval_start
       AND tp.transaction_timestamp <  sm.interval_end
WHERE tp.private_fan_id = '00577311-81a1-469e-93e6-f6dcdad3a4a8'
--WHERE tp.private_fan_id = '8ad58668-3371-4bc5-9369-0cbffd592bb1'
--WHERE tp.private_fan_id = '7c25289f-9fc3-4839-8e7c-3e80464bf252'
--WHERE tp.private_fan_id = '000fba80-8490-4588-9eff-f5bcaad17e79'
--WHERE tp.private_fan_id = '00190418-01ea-407c-b7ae-07c71f43cc17'
--WHERE tp.private_fan_id = '005adfbe-df3c-4d81-8889-1a6746278e87'
--WHERE tp.private_fan_id = '00765d47-c2f4-4b2f-9edf-3264dfab0745'
--WHERE tp.private_fan_id = '00776053-8248-41e6-b321-a5db6ac8aa81'
--WHERE tp.private_fan_id = '0091dfa3-c740-4b49-9ede-5b79b498df07'
--WHERE tp.private_fan_id = '00c04343-31a9-4a1c-b3a1-67e7cccdef98'
--WHERE tp.private_fan_id = '00cf70ae-6867-4187-bdc6-f59a15c401e2'
--WHERE tp.private_fan_id = '00d012f5-f4c5-46a6-b8e6-2d9bdff5cf63'
  AND sm.override_tier IS NOT NULL
QUALIFY row_number() OVER (
    PARTITION BY sm.interval_start, tp.public_facing_tier, tp.status_match_active,
                 (tp.transaction_timestamp <= sm.trial_expiry
                  OR (tp.transaction_timestamp <= sm.override_expiry
                      AND tp.status_match_trial_earned_points >= sm.target_fixed))
    ORDER BY tp.transaction_timestamp
) = 1   -- one representative row per (interval, public tier, active-now, active-fixed) state
ORDER BY ts;
