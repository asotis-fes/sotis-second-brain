-- Materialize the FIXED tier_points_overrides__status_match output into a sample table.
-- CREATE is deny-listed for the agent, so run this yourself:
--   ! snow sql -c FAN_DATA_EXCHANGE_PROD --warehouse FDE_DEVELOPER_2XL_WH -f projects/tier_points_10x_fix/create_fixed_sample.sql
--
-- Faithfulness: the fix changes only trial_target_points, and the flatten's intervals do NOT
-- depend on trial_target_points (they key on override_id/tier/trial_start). So the deployed
-- model's output == prod's flattened rows with trial_target_points recomputed via the same
-- snapshot-level rule the model now applies:  MAX over the interval's CDC snapshots of
-- iff(last_modified_date < launch, tgt*10, tgt).  (Validated: 0 real-customer mismatches.)

CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_FIXED AS
WITH launch AS (SELECT '2026-04-23 13:17:21'::timestamp_ntz AS ts),
cdc AS (
  SELECT private_fan_id,
         status_match_tier_override_name AS override_id,
         coalesce(trial_start, last_modified_date) AS ostart,
         last_modified_date AS lmd,
         trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL
    AND status_match_tier_override_name IS NOT NULL
),
fixed_tgt AS (
  SELECT s.private_fan_id, s.override_id, s.interval_start, s.interval_end,
         max(iff(c.lmd < (SELECT ts FROM launch), c.tgt * 10, c.tgt)) AS trial_target_points_fixed
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
  JOIN cdc c
    ON c.private_fan_id = s.private_fan_id
   AND c.override_id     = s.override_id
   AND c.ostart >= s.interval_start
   AND c.ostart <  s.interval_end
  WHERE s.override_id IS NOT NULL
  GROUP BY 1,2,3,4
)
SELECT
    s.salesforce_member_id,
    s.private_fan_id,
    s.override_id,
    s.interval_start,
    s.interval_end,
    s.next_interval_start,
    s.override_tier,
    s.override_tier_rank,
    s.override_expiry,
    s.trial_target_points                                   AS trial_target_points_before,  -- current prod (mixed scale)
    coalesce(f.trial_target_points_fixed, s.trial_target_points) AS trial_target_points,     -- FIXED (drop-in replacement)
    s.trial_expiry
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
LEFT JOIN fixed_tgt f
  ON  f.private_fan_id = s.private_fan_id
  AND f.override_id     = s.override_id
  AND f.interval_start  = s.interval_start
  AND f.interval_end    = s.interval_end;
