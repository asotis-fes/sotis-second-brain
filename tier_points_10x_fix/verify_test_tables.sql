-- Tests T1-T4 against the ALEX_SOTIS reproductions. All SELECT-only.

-- T1 — FAITHFULNESS: NOFIX (my full model+macro reproduction) must equal prod
-- overrides__status_match for the subset, row-for-row. 0/0 => macro reproduced exactly.
WITH prod AS (
  SELECT salesforce_member_id, private_fan_id, override_id, interval_start, interval_end,
         next_interval_start, override_tier, override_tier_rank, override_expiry,
         trial_target_points, trial_expiry
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH
  WHERE private_fan_id IN (SELECT private_fan_id FROM FES_USERS.ALEX_SOTIS.TP10X_FANS)
)
SELECT
  (SELECT count(*) FROM (SELECT * FROM FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX EXCEPT SELECT * FROM prod)) AS nofix_not_in_prod,
  (SELECT count(*) FROM (SELECT * FROM prod EXCEPT SELECT * FROM FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX)) AS prod_not_in_nofix;

-- T2 — INTERVAL INTEGRITY: NOFIX vs FIXED must have identical interval structure; only
-- trial_target_points may differ. interval_mismatches=0 proves the fix doesn't perturb the macro.
SELECT
  (SELECT count(*) FROM (
     SELECT salesforce_member_id, override_id, interval_start, interval_end, next_interval_start,
            override_tier, override_tier_rank, override_expiry, trial_expiry
     FROM FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX
     EXCEPT
     SELECT salesforce_member_id, override_id, interval_start, interval_end, next_interval_start,
            override_tier, override_tier_rank, override_expiry, trial_expiry
     FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED)) AS interval_mismatches,
  (SELECT count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX n
     JOIN FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED f
       USING (salesforce_member_id, override_id, interval_start, interval_end)
     WHERE n.trial_target_points IS DISTINCT FROM f.trial_target_points) AS target_changed_rows;

-- T3 — VALUE CORRECTNESS: FIXED target vs independent CDC ground truth, per interval.
-- real-customer mismatches must be 0; and every changed row must be exactly before*10.
WITH launch AS (SELECT '2026-04-23 13:17:21.000 +0000'::timestamp_tz AS ts),
cdc AS (
  SELECT private_fan_id, status_match_tier_override_name AS override_id,
         coalesce(trial_start,last_modified_date) AS ostart, last_modified_date AS lmd, trial_target_points AS tgt
  FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
  WHERE status_match_tier_name IS NOT NULL AND status_match_tier_override_name IS NOT NULL
    AND private_fan_id IN (SELECT private_fan_id FROM FES_USERS.ALEX_SOTIS.TP10X_FANS)
),
truth AS (
  SELECT f.private_fan_id, f.override_id, f.interval_start, f.interval_end,
         f.trial_target_points AS fixed_val,
         iff(count_if(c.lmd >= (SELECT ts FROM launch))=0, max(c.tgt)*10, max(c.tgt)) AS cdc_expected
  FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED f
  JOIN cdc c ON c.private_fan_id=f.private_fan_id AND c.override_id=f.override_id
     AND c.ostart>=f.interval_start AND c.ostart<f.interval_end
  WHERE f.override_id IS NOT NULL
  GROUP BY 1,2,3,4,5
)
SELECT
  count(*) AS override_intervals,
  count_if(fixed_val <> cdc_expected) AS all_mismatches,
  count_if(fixed_val <> cdc_expected
           AND private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') AS real_customer_mismatches
FROM truth;

-- T4a — DEV/QA GUARD: confirm the subset (and thus NOFIX/FIXED) contains ZERO non-UUID
-- (dev/QA) fan ids. All three must be 0.
SELECT
  (SELECT count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_FANS
     WHERE NOT private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') AS nonuuid_fans,
  (SELECT count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED
     WHERE NOT private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') AS nonuuid_fixed_rows,
  (SELECT count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED WHERE private_fan_id = 'SuneelRachamallu') AS suneel_rows;

-- T4b — REAL-CUSTOMER edge case (GOLDTEST500 = "Gold Fast Track") NOFIX vs FIXED.
SELECT n.private_fan_id, split_part(n.override_id,'-',1) AS campaign,
       n.interval_start::date AS istart, n.interval_end::date AS iend,
       n.trial_target_points AS nofix_target, f.trial_target_points AS fixed_target
FROM FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX n
JOIN FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED f
  USING (salesforce_member_id, override_id, interval_start, interval_end)
WHERE n.private_fan_id = '3aef9dfc-f86b-4986-b7a8-2d78fa5dad27'
ORDER BY n.interval_start;
