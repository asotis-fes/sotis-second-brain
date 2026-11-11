-- Verification queries for the 10 affected sample fans.
-- NOTE ON METHOD: Queries 1-3 run against EXISTING prod tables and reproduce the fix's
-- arithmetic inline (they do NOT require the model to be rebuilt). Query 4 is the CTAS to
-- materialize the ACTUAL fixed model output; Query 5 is the true "run the code" path (dbt).

-- ============================================================================
-- Q1 — BEFORE/AFTER target per interval (reproduces deployed snapshot-level logic)
-- ============================================================================
WITH launch AS (SELECT '2026-04-23 13:17:21'::timestamp_ntz AS ts),
fans AS (SELECT column1 AS pfi FROM VALUES
 ('000fba80-8490-4588-9eff-f5bcaad17e79'),('00190418-01ea-407c-b7ae-07c71f43cc17'),
 ('00577311-81a1-469e-93e6-f6dcdad3a4a8'),('005adfbe-df3c-4d81-8889-1a6746278e87'),
 ('00765d47-c2f4-4b2f-9edf-3264dfab0745'),('00776053-8248-41e6-b321-a5db6ac8aa81'),
 ('0091dfa3-c740-4b49-9ede-5b79b498df07'),('00c04343-31a9-4a1c-b3a1-67e7cccdef98'),
 ('00cf70ae-6867-4187-bdc6-f59a15c401e2'),('00d012f5-f4c5-46a6-b8e6-2d9bdff5cf63')),
cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         coalesce(trial_start,last_modified_date) AS ostart, last_modified_date AS lmd, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
    AND private_fan_id IN (SELECT pfi FROM fans)
)
SELECT s.private_fan_id, split_part(s.override_id,'-',1) AS campaign,
       s.interval_start::date AS istart, s.interval_end::date AS iend,
       any_value(s.trial_target_points) AS raw_current_target,
       max(iff(c.lmd < (SELECT ts FROM launch), c.tgt*10, c.tgt)) AS fixed_target,
       iff(max(iff(c.lmd < (SELECT ts FROM launch), c.tgt*10, c.tgt)) <> any_value(s.trial_target_points),'x10','same') AS change
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
JOIN cdc c ON c.private_fan_id=s.private_fan_id AND c.override_id=s.override_id
  AND c.ostart>=s.interval_start AND c.ostart<s.interval_end
WHERE s.override_id IS NOT NULL
GROUP BY 1,2,3,4 ORDER BY 1,3;

-- ============================================================================
-- Q2 — Raw CDC timeline for ONE fan: SEE the x10 jump (or absence of one) directly.
-- ============================================================================
SELECT private_fan_id, status_match_tier_override_name AS override_id,
       last_modified_date, trial_start, trial_expiry,
       trial_start_tier_points, trial_target_points
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
WHERE private_fan_id = '00577311-81a1-469e-93e6-f6dcdad3a4a8'
  AND status_match_tier_name IS NOT NULL
ORDER BY status_match_tier_override_name, last_modified_date;

-- ============================================================================
-- Q3 — END-TO-END: does the customer's status-match ACHIEVEMENT change?
--   achieved = 10x earned in trial window >= target.  current(raw) vs fixed.
--   A flip from TRUE->FALSE = a false grant that the fix removes.
-- ============================================================================
WITH launch AS (SELECT '2026-04-23 13:17:21'::timestamp_ntz AS ts),
fans AS (SELECT column1 AS pfi FROM VALUES
 ('000fba80-8490-4588-9eff-f5bcaad17e79'),('00190418-01ea-407c-b7ae-07c71f43cc17'),
 ('00577311-81a1-469e-93e6-f6dcdad3a4a8'),('005adfbe-df3c-4d81-8889-1a6746278e87'),
 ('00765d47-c2f4-4b2f-9edf-3264dfab0745'),('00776053-8248-41e6-b321-a5db6ac8aa81'),
 ('0091dfa3-c740-4b49-9ede-5b79b498df07'),('00c04343-31a9-4a1c-b3a1-67e7cccdef98'),
 ('00cf70ae-6867-4187-bdc6-f59a15c401e2'),('00d012f5-f4c5-46a6-b8e6-2d9bdff5cf63')),
cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         coalesce(trial_start,last_modified_date) AS ostart, last_modified_date AS lmd, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
    AND private_fan_id IN (SELECT pfi FROM fans)
),
s AS (
  SELECT s.salesforce_member_id, s.private_fan_id, s.override_id, s.interval_start, s.trial_expiry,
         any_value(s.trial_target_points) AS raw_target,
         max(iff(c.lmd < (SELECT ts FROM launch), c.tgt*10, c.tgt)) AS fixed_target
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
  JOIN cdc c ON c.private_fan_id=s.private_fan_id AND c.override_id=s.override_id
    AND c.ostart>=s.interval_start AND c.ostart<s.interval_end
  WHERE s.override_id IS NOT NULL
  GROUP BY 1,2,3,4,5
),
earned AS (
  SELECT s.private_fan_id, s.override_id, s.interval_start,
         round(sum(tp.derived_tier_points_amount),2) AS trial_earned_10x
  FROM s JOIN LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 tp
    ON tp.salesforce_member_id=s.salesforce_member_id
   AND tp.transaction_timestamp>=s.interval_start AND tp.transaction_timestamp<=s.trial_expiry
   AND coalesce(tp.notes,'')<>'EOY-Rollover'
  GROUP BY 1,2,3
)
SELECT s.private_fan_id, split_part(s.override_id,'-',1) AS campaign, s.interval_start::date AS istart,
       s.raw_target, s.fixed_target, coalesce(e.trial_earned_10x,0) AS earned_10x,
       (coalesce(e.trial_earned_10x,0) >= s.raw_target)   AS achieved_current,
       (coalesce(e.trial_earned_10x,0) >= s.fixed_target) AS achieved_fixed,
       iff((coalesce(e.trial_earned_10x,0) >= s.raw_target) <> (coalesce(e.trial_earned_10x,0) >= s.fixed_target),'FLIP','') AS note
FROM s LEFT JOIN earned e ON e.private_fan_id=s.private_fan_id AND e.override_id=s.override_id AND e.interval_start=s.interval_start
ORDER BY 1,3;

-- ============================================================================
-- Q4 — CTAS: materialize the ACTUAL fixed model output for these fans (run yourself;
--   CREATE is deny-listed for the agent). Requires the fixed model to be built first (Q5),
--   OR compare against prod to see the pre-fix state.
-- ============================================================================
-- CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_PROD AS
--   SELECT * FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH
--   WHERE private_fan_id IN ( ...the 10 ids... );

-- ============================================================================
-- Q5 — TRUE "run the code": build the fixed model into your dev schema and compare.
--   From the dbt-fes-ae repo, on branch fix/entdata-2261-status-match-10x-target:
--     dbt run --select tier_points_overrides__status_match     # dev target -> FES_USERS.ALEX_SOTIS
--   Then diff dev (fixed) vs prod (unfixed) for the 10 fans:
--   SELECT d.private_fan_id, d.override_id, d.interval_start,
--          p.trial_target_points AS prod_raw, d.trial_target_points AS dev_fixed
--   FROM FES_USERS.ALEX_SOTIS.TIER_POINTS_OVERRIDES__STATUS_MATCH d
--   JOIN LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH p
--     USING (private_fan_id, override_id, interval_start, interval_end)
--   WHERE d.private_fan_id IN ( ...the 10 ids... )
--   ORDER BY 1,3;
