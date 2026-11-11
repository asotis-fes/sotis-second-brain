-- Verification queries to run AFTER create_fixed_sample.sql builds
-- FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_FIXED. All are SELECT-only.

-- V0 — FAITHFULNESS PROOF (run against prod, no sample table needed):
-- a NO-FIX reconstruction (MAX raw target over each interval's snapshots) must equal prod's
-- flattened trial_target_points exactly. 0 mismatches => the snapshot->interval mapping
-- faithfully reproduces prod's flatten, so the FIXED recomputation is trustworthy.
WITH cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         coalesce(trial_start,last_modified_date) AS ostart, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
),
recon AS (
  SELECT s.private_fan_id, s.override_id, s.interval_start, s.interval_end,
         any_value(s.trial_target_points) AS prod_tgt, max(c.tgt) AS recon_tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
  JOIN cdc c ON c.private_fan_id=s.private_fan_id AND c.override_id=s.override_id
    AND c.ostart>=s.interval_start AND c.ostart<s.interval_end
  WHERE s.override_id IS NOT NULL
  GROUP BY 1,2,3,4
)
SELECT count(*) AS intervals, count_if(prod_tgt <> recon_tgt) AS mapping_mismatches   -- expect 0
FROM recon;

-- V1 — the 10 sample fans, before vs after, from the materialized table
SELECT private_fan_id, split_part(override_id,'-',1) AS campaign,
       interval_start::date AS istart, interval_end::date AS iend,
       trial_target_points_before AS before, trial_target_points AS after,
       iff(trial_target_points <> trial_target_points_before,'x10','same') AS change
FROM FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_FIXED
WHERE private_fan_id IN (
 '000fba80-8490-4588-9eff-f5bcaad17e79','00190418-01ea-407c-b7ae-07c71f43cc17',
 '00577311-81a1-469e-93e6-f6dcdad3a4a8','005adfbe-df3c-4d81-8889-1a6746278e87',
 '00765d47-c2f4-4b2f-9edf-3264dfab0745','00776053-8248-41e6-b321-a5db6ac8aa81',
 '0091dfa3-c740-4b49-9ede-5b79b498df07','00c04343-31a9-4a1c-b3a1-67e7cccdef98',
 '00cf70ae-6867-4187-bdc6-f59a15c401e2','00d012f5-f4c5-46a6-b8e6-2d9bdff5cf63')
ORDER BY private_fan_id, interval_start;

-- V2 — whole-table impact + guard against double-10x: every CHANGED override row must be
-- exactly before*10 (ratio 10), never *100. real customers only (UUID) for the ratio check.
SELECT
  count(*)                                                             AS total_rows,
  count_if(trial_target_points <> trial_target_points_before)         AS changed_rows,
  count_if(override_id IS NOT NULL
           AND trial_target_points_before > 0
           AND private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
           AND trial_target_points <> trial_target_points_before
           AND trial_target_points <> trial_target_points_before * 10) AS bad_ratio_rows   -- expect 0
FROM FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_FIXED;

-- V3 — spot any interval whose FIXED target is out of 10x scale vs a sibling of the SAME
-- override_id (an override should end up on ONE scale). Shows fans where min/max fixed differ.
SELECT private_fan_id, override_id,
       min(trial_target_points) AS min_fixed, max(trial_target_points) AS max_fixed
FROM FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_FIXED
WHERE override_id IS NOT NULL AND trial_target_points IS NOT NULL
GROUP BY 1,2
HAVING min(trial_target_points) <> max(trial_target_points)
ORDER BY 1 LIMIT 50;
