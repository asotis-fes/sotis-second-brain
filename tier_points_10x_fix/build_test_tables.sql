-- Build test tables in FES_USERS.ALEX_SOTIS by reproducing the FULL
-- tier_points_overrides__status_match model INCLUDING the real flatten_override_intervals
-- macro (inlined verbatim), on a subset of fans. Two copies: NOFIX (raw target) and FIXED.
-- 2XL warehouse. Refs resolved to prod physical tables.
USE WAREHOUSE FDE_DEVELOPER_2XL_WH;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;

-- ---------------------------------------------------------------------------
-- 0) Subset of fans: the 15 named (samples, affected, victim, GOLDTEST500 real cust, Suneel dev)
--    + every status-match fan whose id starts with '00' (deterministic ~1/256 UUID sample).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_FANS AS
SELECT DISTINCT private_fan_id
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH
WHERE override_id IS NOT NULL
  -- REAL CUSTOMERS ONLY: exclude dev/QA accounts (non-UUID private_fan_id, e.g. SuneelRachamallu).
  -- prod contains dev/QA rows; this keeps them out of the test subset.
  AND private_fan_id RLIKE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  AND (
    private_fan_id IN (
      '8ad58668-3371-4bc5-9369-0cbffd592bb1','7c25289f-9fc3-4839-8e7c-3e80464bf252',
      '000fba80-8490-4588-9eff-f5bcaad17e79','00190418-01ea-407c-b7ae-07c71f43cc17',
      '00577311-81a1-469e-93e6-f6dcdad3a4a8','005adfbe-df3c-4d81-8889-1a6746278e87',
      '00765d47-c2f4-4b2f-9edf-3264dfab0745','00776053-8248-41e6-b321-a5db6ac8aa81',
      '0091dfa3-c740-4b49-9ede-5b79b498df07','00c04343-31a9-4a1c-b3a1-67e7cccdef98',
      '00cf70ae-6867-4187-bdc6-f59a15c401e2','00d012f5-f4c5-46a6-b8e6-2d9bdff5cf63',
      '00368250-6775-4e06-8417-f53f0d271a80','3aef9dfc-f86b-4986-b7a8-2d78fa5dad27'  -- GOLDTEST500 = REAL "Gold Fast Track" customer
    )
    OR left(private_fan_id, 2) = '00'
  );

-- ---------------------------------------------------------------------------
-- 1) NOFIX  = the model exactly as it is on main (raw target passthrough).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX AS
WITH remove_empty_rows_before_first_status_match AS (
    SELECT
        salesforce_member_id, private_fan_id, last_modified_date,
        status_match_tier_override_name, status_match_tier_name, status_match_expiry,
        NULL AS original_override_start,
        trial_target_points::int AS trial_target_points,
        trial_start, trial_expiry,
        max(status_match_tier_name) OVER (PARTITION BY private_fan_id ORDER BY last_modified_date) AS max_status_match
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
    WHERE private_fan_id IN (SELECT private_fan_id FROM FES_USERS.ALEX_SOTIS.TP10X_FANS)
    QUALIFY max_status_match IS NOT NULL
),
valid_trials AS (
    SELECT private_fan_id, status_match_tier_override_name, trial_start,
           min(last_modified_date) AS min_last_modified_date
    FROM remove_empty_rows_before_first_status_match
    GROUP BY ALL
    QUALIFY coalesce(min(trial_start) OVER (PARTITION BY private_fan_id ORDER BY min_last_modified_date DESC), '9999-12-31') >= trial_start
),
status_match AS (
    SELECT DISTINCT
        o.salesforce_member_id, o.private_fan_id,
        coalesce(o.trial_start, o.last_modified_date) AS override_start,
        coalesce(lead(override_start) OVER (PARTITION BY o.salesforce_member_id ORDER BY override_start), '9999-12-31'::timestamp_ntz) AS override_end,
        o.status_match_tier_override_name AS override_id,
        o.status_match_tier_name AS override_tier,
        status_match_rank.tier_rank AS override_tier_rank,
        o.status_match_expiry AS override_expiry,
        o.original_override_start,
        o.trial_target_points,
        o.trial_start, o.trial_expiry,
        valid_trials.status_match_tier_override_name AS vt_name
    FROM remove_empty_rows_before_first_status_match AS o
    LEFT JOIN valid_trials
        ON o.private_fan_id = valid_trials.private_fan_id
       AND o.status_match_tier_override_name = valid_trials.status_match_tier_override_name
       AND o.trial_start = valid_trials.trial_start
    LEFT JOIN LOYALTY.LOYALTY_INFO.TIER_POINTS_TIERS_INFO AS status_match_rank
        ON o.status_match_tier_name = status_match_rank.tier_name
    WHERE override_id IS NULL OR valid_trials.status_match_tier_override_name IS NOT NULL
),
override_changes AS (
  SELECT private_fan_id, salesforce_member_id, override_start, override_end, override_id,
    override_tier, override_tier_rank, override_expiry, original_override_start,
    trial_target_points::int AS trial_target_points, trial_start, trial_expiry,
    CASE WHEN override_id || '-' || override_tier || '-' || coalesce(to_varchar(trial_start),'') || '-' || coalesce(to_varchar(original_override_start),'')
              IS DISTINCT FROM LAG(override_id || '-' || override_tier || '-' || coalesce(to_varchar(trial_start),'') || '-' || coalesce(to_varchar(original_override_start),''))
              OVER (PARTITION BY salesforce_member_id ORDER BY override_start, override_end) THEN 1 ELSE 0 END AS is_override_changed
  FROM status_match
),
override_grouped_changes AS (
  SELECT private_fan_id, salesforce_member_id, override_start, override_end, override_id,
    override_tier, override_tier_rank, override_expiry, trial_target_points::int AS trial_target_points,
    trial_start, trial_expiry,
    SUM(is_override_changed) OVER (PARTITION BY salesforce_member_id ORDER BY override_start, override_end ROWS UNBOUNDED PRECEDING) AS group_id
  FROM override_changes
),
overrides AS (
  SELECT private_fan_id, salesforce_member_id,
    MIN(override_start) AS interval_start, MAX(override_end) AS interval_end,
    MAX(override_id) AS override_id,
    lead(interval_start) over (partition by salesforce_member_id order by interval_start) as next_interval_start,
    MAX(override_tier) as override_tier, MAX(override_tier_rank) as override_tier_rank,
    MAX(override_expiry) as override_expiry, MAX(trial_target_points) AS trial_target_points,
    MAX(trial_expiry) as trial_expiry
  FROM override_grouped_changes
  GROUP BY private_fan_id, salesforce_member_id, group_id
)
SELECT salesforce_member_id, private_fan_id, override_id, interval_start, interval_end,
       next_interval_start, override_tier, override_tier_rank, override_expiry,
       trial_target_points, trial_expiry
FROM overrides;

-- ---------------------------------------------------------------------------
-- 2) FIXED = identical, EXCEPT the one-line fix in the status_match CTE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED AS
WITH remove_empty_rows_before_first_status_match AS (
    SELECT
        salesforce_member_id, private_fan_id, last_modified_date,
        status_match_tier_override_name, status_match_tier_name, status_match_expiry,
        NULL AS original_override_start,
        trial_target_points::int AS trial_target_points,
        trial_start, trial_expiry,
        max(status_match_tier_name) OVER (PARTITION BY private_fan_id ORDER BY last_modified_date) AS max_status_match
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
    WHERE private_fan_id IN (SELECT private_fan_id FROM FES_USERS.ALEX_SOTIS.TP10X_FANS)
    QUALIFY max_status_match IS NOT NULL
),
valid_trials AS (
    SELECT private_fan_id, status_match_tier_override_name, trial_start,
           min(last_modified_date) AS min_last_modified_date
    FROM remove_empty_rows_before_first_status_match
    GROUP BY ALL
    QUALIFY coalesce(min(trial_start) OVER (PARTITION BY private_fan_id ORDER BY min_last_modified_date DESC), '9999-12-31') >= trial_start
),
status_match AS (
    SELECT DISTINCT
        o.salesforce_member_id, o.private_fan_id,
        coalesce(o.trial_start, o.last_modified_date) AS override_start,
        coalesce(lead(override_start) OVER (PARTITION BY o.salesforce_member_id ORDER BY override_start), '9999-12-31'::timestamp_ntz) AS override_end,
        o.status_match_tier_override_name AS override_id,
        o.status_match_tier_name AS override_tier,
        status_match_rank.tier_rank AS override_tier_rank,
        o.status_match_expiry AS override_expiry,
        o.original_override_start,
        -- THE FIX (matches deployed literal):
        iff(o.last_modified_date < '2026-04-23 13:17:21.000 +0000', o.trial_target_points * 10, o.trial_target_points) AS trial_target_points,
        o.trial_start, o.trial_expiry,
        valid_trials.status_match_tier_override_name AS vt_name
    FROM remove_empty_rows_before_first_status_match AS o
    LEFT JOIN valid_trials
        ON o.private_fan_id = valid_trials.private_fan_id
       AND o.status_match_tier_override_name = valid_trials.status_match_tier_override_name
       AND o.trial_start = valid_trials.trial_start
    LEFT JOIN LOYALTY.LOYALTY_INFO.TIER_POINTS_TIERS_INFO AS status_match_rank
        ON o.status_match_tier_name = status_match_rank.tier_name
    WHERE override_id IS NULL OR valid_trials.status_match_tier_override_name IS NOT NULL
),
override_changes AS (
  SELECT private_fan_id, salesforce_member_id, override_start, override_end, override_id,
    override_tier, override_tier_rank, override_expiry, original_override_start,
    trial_target_points::int AS trial_target_points, trial_start, trial_expiry,
    CASE WHEN override_id || '-' || override_tier || '-' || coalesce(to_varchar(trial_start),'') || '-' || coalesce(to_varchar(original_override_start),'')
              IS DISTINCT FROM LAG(override_id || '-' || override_tier || '-' || coalesce(to_varchar(trial_start),'') || '-' || coalesce(to_varchar(original_override_start),''))
              OVER (PARTITION BY salesforce_member_id ORDER BY override_start, override_end) THEN 1 ELSE 0 END AS is_override_changed
  FROM status_match
),
override_grouped_changes AS (
  SELECT private_fan_id, salesforce_member_id, override_start, override_end, override_id,
    override_tier, override_tier_rank, override_expiry, trial_target_points::int AS trial_target_points,
    trial_start, trial_expiry,
    SUM(is_override_changed) OVER (PARTITION BY salesforce_member_id ORDER BY override_start, override_end ROWS UNBOUNDED PRECEDING) AS group_id
  FROM override_changes
),
overrides AS (
  SELECT private_fan_id, salesforce_member_id,
    MIN(override_start) AS interval_start, MAX(override_end) AS interval_end,
    MAX(override_id) AS override_id,
    lead(interval_start) over (partition by salesforce_member_id order by interval_start) as next_interval_start,
    MAX(override_tier) as override_tier, MAX(override_tier_rank) as override_tier_rank,
    MAX(override_expiry) as override_expiry, MAX(trial_target_points) AS trial_target_points,
    MAX(trial_expiry) as trial_expiry
  FROM override_grouped_changes
  GROUP BY private_fan_id, salesforce_member_id, group_id
)
SELECT salesforce_member_id, private_fan_id, override_id, interval_start, interval_end,
       next_interval_start, override_tier, override_tier_rank, override_expiry,
       trial_target_points, trial_expiry
FROM overrides;

SELECT 'TP10X_FANS' AS t, count(*) n FROM FES_USERS.ALEX_SOTIS.TP10X_FANS
UNION ALL SELECT 'TP10X_SM_NOFIX', count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_NOFIX
UNION ALL SELECT 'TP10X_SM_FIXED', count(*) FROM FES_USERS.ALEX_SOTIS.TP10X_SM_FIXED;
