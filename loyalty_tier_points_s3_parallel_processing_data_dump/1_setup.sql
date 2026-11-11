
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

-- 1) pin the map (rn=1 dedup, non-null loyalty_id + fan_id) ---------------------
CREATE OR REPLACE TRANSIENT TABLE FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT AS
SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM (
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID,
           ROW_NUMBER() OVER (PARTITION BY PRIVATE_FAN_ID
             ORDER BY CASE WHEN LOYALTY_ACCOUNT_DIRECTORY_ID = 2 THEN 1 ELSE 2 END,
                      LAST_MODIFIED_TIME DESC) AS rn
    FROM LOYALTY.LOYALTY_INFO.LOYALTY_ACCOUNT_ID_FAN_ID_TENANT_MAP WHERE LOYALTY_ACCOUNT_ID IS NOT NULL AND PRIVATE_FAN_ID IS NOT NULL
) WHERE rn = 1;

-- 2) materialize the ledger export + a STABLE chunk_num (chunk by loyalty_account_id)
--    (deleted accounts are INCLUDED per Suneel — they become stale in the new ledger)
CREATE OR REPLACE TRANSIENT TABLE FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT AS
WITH ledger_export AS (
    SELECT 
        TO_CHAR(CONVERT_TIMEZONE('UTC', l.TRANSACTION_TIMESTAMP), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS transaction_timestamp,
        l.SALESFORCE_TRANSACTION_ID        AS salesforce_transaction_id,
        m.LOYALTY_ACCOUNT_ID               AS loyalty_account_id,
        l.EXTERNAL_ID                      AS external_id,
        l.EXTERNAL_ID_TYPE                 AS external_id_type,
        l.REFERENCE_ID                     AS reference_id,
        l.TRANSACTION_STATUS               AS transaction_status,
        l.DERIVED_TIER_POINTS_AMOUNT       AS derived_tier_points_amount,
        l.PROGRAM_FLAG                     AS program_flag,
        l.TENANT_ID                        AS tenant_id,
        l.SITE_ID                          AS site_id,
        l.INITIATED_BY                     AS initiated_by,
        l.IS_TEST_TRANSACTION              AS is_test_transaction,
        l.CURRENT_BALANCE                  AS current_balance,
        l.LIFETIME_BALANCE                 AS lifetime_balance,
        l.NOTES                            AS notes,
        l.EARN_TIER                        AS earn_tier,
        l.PUBLIC_FACING_TIER               AS public_facing_tier,
        l.INVITE_ONLY_TIER_NAME            AS invite_only_tier_name,
        l.STATUS_MATCH_ACTIVE              AS status_match_active,
        l.PLACEMENT_ACTIVE                 AS placement_active,
        l.ROLLOVER_ACTIVE                  AS rollover_active,
        l.STATUS_MATCH_TRIAL_EARNED_POINTS AS status_match_trial_earned_points,
        l.TIER_POINTS_MULTIPLIER           AS tier_points_multiplier
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 l
    JOIN FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT m ON m.PRIVATE_FAN_ID = l.PRIVATE_FAN_ID
    WHERE 1=1
      AND (COALESCE(l.DERIVED_TIER_POINTS_AMOUNT, 0) <> 0 OR l.NOTES = 'EOY-Rollover')
      AND COALESCE(l.EXTERNAL_ID_TYPE, '') NOT IN ('OVERRIDE', 'NON_TRANSACTOR')
      AND COALESCE(l.NOTES, '') <> 'TierPoints 10x Loyalty Program'
      AND l.TRANSACTION_TIMESTAMP IS NOT NULL
      AND COALESCE(l.IS_TEST_TRANSACTION, FALSE) <> TRUE
      AND l.TRANSACTION_TIMESTAMP < '2026-08-05 09:09:45'::TIMESTAMP_LTZ
),
ranked AS (
    SELECT loyalty_account_id,
           FLOOR((DENSE_RANK() OVER (ORDER BY loyalty_account_id) - 1) / 200000) AS chunk_num
    FROM (SELECT DISTINCT loyalty_account_id FROM ledger_export)
)
SELECT e.*, r.chunk_num
FROM ledger_export e JOIN ranked r USING (loyalty_account_id);

-- 3) reference list of DROPPED members (unmapped = no loyalty_id, can't migrate) -----
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP_MIGRATION_MISSING_KEYS AS
WITH led AS (
    SELECT DISTINCT l.PRIVATE_FAN_ID
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 l
    WHERE 1=1
      AND (COALESCE(l.DERIVED_TIER_POINTS_AMOUNT, 0) <> 0 OR l.NOTES = 'EOY-Rollover')
      AND COALESCE(l.EXTERNAL_ID_TYPE, '') NOT IN ('OVERRIDE', 'NON_TRANSACTOR')
      AND COALESCE(l.NOTES, '') <> 'TierPoints 10x Loyalty Program'
      AND l.TRANSACTION_TIMESTAMP IS NOT NULL
      AND COALESCE(l.IS_TEST_TRANSACTION, FALSE) <> TRUE
      AND l.TRANSACTION_TIMESTAMP < '2026-08-05 09:09:45'::TIMESTAMP_LTZ
),
ovr AS (
    SELECT DISTINCT o.PRIVATE_FAN_ID FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2 o
    WHERE ( o.INVITE_ONLY_APPROVALS IS NOT NULL OR o.PLACEMENT_TIER_OVERRIDE_NAME IS NOT NULL OR o.PLACEMENT_START IS NOT NULL OR o.PLACEMENT_EXPIRY IS NOT NULL OR o.PLACEMENT_NOTE IS NOT NULL OR o.PLACEMENT_EXTRA_DATA IS NOT NULL OR o.STATUS_MATCH_TIER_OVERRIDE_NAME IS NOT NULL OR o.STATUS_MATCH_START IS NOT NULL OR o.STATUS_MATCH_EXPIRY IS NOT NULL OR o.STATUS_MATCH_NOTE IS NOT NULL OR o.STATUS_MATCH_EXTRA_DATA IS NOT NULL OR o.TRIAL_START IS NOT NULL OR o.TRIAL_EXPIRY IS NOT NULL OR COALESCE(o.TRIAL_TARGET_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_LIFETIME_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_ROLLOVER_TIER_POINTS, 0) <> 0 )
),
cohort AS (SELECT PRIVATE_FAN_ID, 'ledger' AS source_dataset FROM led
           UNION ALL SELECT PRIVATE_FAN_ID, 'override' FROM ovr)
SELECT c.source_dataset, c.PRIVATE_FAN_ID, 'unmapped' AS reason
FROM cohort c
WHERE c.PRIVATE_FAN_ID NOT IN (SELECT PRIVATE_FAN_ID FROM FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT);

