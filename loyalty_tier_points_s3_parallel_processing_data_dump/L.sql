USE WAREHOUSE FDE_DEVELOPER_3XL_WH;
CREATE OR REPLACE TRANSIENT TABLE FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT AS
WITH ledger_export AS (
    SELECT 
        TO_CHAR(CONVERT_TIMEZONE('UTC', l.TRANSACTION_TIMESTAMP), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS transaction_timestamp,
        l.SALESFORCE_TRANSACTION_ID        AS salesforce_transaction_id,
        e.effective_loyalty_id             AS loyalty_account_id,
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
    JOIN FES_USERS.ALEX_SOTIS.TP_EFFECTIVE_SNAPSHOT e ON e.private_fan_id = l.PRIVATE_FAN_ID
    WHERE 1=1
      AND (COALESCE(l.DERIVED_TIER_POINTS_AMOUNT, 0) <> 0 OR l.NOTES = 'EOY-Rollover')
      AND COALESCE(l.EXTERNAL_ID_TYPE, '') NOT IN ('OVERRIDE', 'NON_TRANSACTOR')
      AND COALESCE(l.NOTES, '') <> 'TierPoints 10x Loyalty Program'
      AND l.TRANSACTION_TIMESTAMP IS NOT NULL
      AND COALESCE(l.IS_TEST_TRANSACTION, FALSE) <> TRUE
      AND l.TRANSACTION_TIMESTAMP < '2026-08-10T13:00:00.000Z'::TIMESTAMP_LTZ
),
ranked AS (
    SELECT loyalty_account_id,
           FLOOR((DENSE_RANK() OVER (ORDER BY loyalty_account_id) - 1) / 200000) AS chunk_num
    FROM (SELECT DISTINCT loyalty_account_id FROM ledger_export)
)
SELECT e.*, r.chunk_num
FROM ledger_export e JOIN ranked r USING (loyalty_account_id);
