-- How many private_fan_ids are affected by the 10x status-match-target bug?
-- Three nested definitions (each stricter than the last), real customers only (UUID fan_id):
--   A. fans_target_changed        - >=1 status_match interval whose target gets x10'd by the fix
--   B. fans_sm_active_flips        - the fix flips status_match_active TRUE->FALSE on >=1 ledger row
--   C. fans_public_tier_impacted   - ...and public_facing_tier currently = the status-match tier
--                                    on that row (i.e. the public tier is very likely inflated today)
-- C <= B <= A.  (C may slightly over-count: in rare cases a placement/rollover override could
--  independently hold the same tier; an exact figure needs full public_facing_tier recompute.)

WITH launch AS (SELECT '2026-04-23 13:17:21'::timestamp_ntz AS ts),
cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         coalesce(trial_start, last_modified_date) AS ostart, last_modified_date AS lmd, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
),
sm AS (
  SELECT s.salesforce_member_id, s.private_fan_id, s.interval_start, s.interval_end,
         s.override_tier, s.override_expiry, s.trial_expiry,
         any_value(s.trial_target_points) AS target_raw,
         max(iff(c.lmd < (SELECT ts FROM launch), c.tgt * 10, c.tgt)) AS target_fixed
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
  JOIN cdc c ON c.private_fan_id = s.private_fan_id AND c.override_id = s.override_id
     AND c.ostart >= s.interval_start AND c.ostart < s.interval_end
  WHERE s.override_id IS NOT NULL
    AND s.private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  GROUP BY 1,2,3,4,5,6,7
),
joined AS (
  SELECT tp.private_fan_id,
         tp.status_match_active AS active_now,
         (tp.transaction_timestamp <= s.trial_expiry
          OR (tp.transaction_timestamp <= s.override_expiry
              AND tp.status_match_trial_earned_points >= s.target_fixed)) AS active_fixed,
         (tp.public_facing_tier = s.override_tier) AS public_is_sm
  FROM sm s
  JOIN LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 tp
    ON tp.salesforce_member_id = s.salesforce_member_id
   AND tp.transaction_timestamp >= s.interval_start
   AND tp.transaction_timestamp <  s.interval_end
)
SELECT
  (SELECT count(DISTINCT private_fan_id) FROM sm WHERE target_fixed <> target_raw)          AS a_fans_target_changed,
  count(DISTINCT iff(active_now AND NOT active_fixed, private_fan_id, NULL))                 AS b_fans_sm_active_flips,
  count(DISTINCT iff(active_now AND NOT active_fixed AND public_is_sm, private_fan_id, NULL)) AS c_fans_public_tier_impacted
FROM joined;
