-- ⭐ DEFINITIVE GENERALIZABLE VALIDATION for the chosen upstream (last_modified_date) fix.
-- Returns mismatch_rows = 0 when the fix is correct for EVERYONE (no exclusions).
--
-- For each flattened status_match interval it computes, from the raw CDC snapshots that
-- form that interval:
--   fix_output   = MAX over snapshots of iff(last_modified_date < launch, target*10, target)
--                  (exactly what the upstream per-snapshot normalize + flatten MAX produces)
--   cdc_expected = iff(no post-launch snapshot, MAX(raw target)*10, MAX(raw target))
--                  (independent ground truth: interval is 1x iff never touched post-launch)
-- and counts intervals where they disagree. Disagreement would also flag any override whose
-- post-launch value != 10x its pre-launch value (a data anomaly worth knowing about).
--
-- Post-deploy variant: swap `fix_output` for the built model's trial_target_points and join
-- on (private_fan_id, override_id, interval_start).

WITH launch AS (SELECT '2026-04-23 13:17:21'::timestamp_ntz AS ts),
cdc_snap AS (
  SELECT private_fan_id,
         status_match_tier_override_name AS override_id,
         coalesce(trial_start, last_modified_date) AS ostart,
         last_modified_date AS lmd,
         trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL
    AND status_match_tier_override_name IS NOT NULL
    AND private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'  -- real customers only (excludes dev accts like SuneelRachamallu)
),
mapped AS (
  SELECT s.private_fan_id, s.override_id, s.interval_start, s.interval_end, c.lmd, c.tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH s
  JOIN cdc_snap c
    ON c.private_fan_id = s.private_fan_id
   AND c.override_id     = s.override_id
   AND c.ostart >= s.interval_start
   AND c.ostart <  s.interval_end
  WHERE s.override_id IS NOT NULL
),
per_interval AS (
  SELECT private_fan_id, override_id, interval_start, interval_end,
         max(iff(lmd < (SELECT ts FROM launch), tgt * 10, tgt)) AS fix_output,
         iff(count_if(lmd >= (SELECT ts FROM launch)) = 0, max(tgt) * 10, max(tgt)) AS cdc_expected
  FROM mapped
  GROUP BY 1,2,3,4
)
SELECT count(*)                                  AS intervals_checked,
       count_if(fix_output <> cdc_expected)      AS mismatch_rows   -- expect 0
FROM per_interval;
