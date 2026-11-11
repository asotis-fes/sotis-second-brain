
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;
WITH active_source_loyalty AS (
    SELECT DISTINCT lm.LOYALTY_ACCOUNT_ID
    FROM FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT lm
    WHERE EXISTS (SELECT 1 FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 l
                  WHERE l.PRIVATE_FAN_ID = lm.PRIVATE_FAN_ID
                    AND COALESCE(l.EXTERNAL_ID_TYPE, '') <> 'NON_TRANSACTOR')
       OR EXISTS (SELECT 1 FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2 o
                  WHERE o.PRIVATE_FAN_ID = lm.PRIVATE_FAN_ID AND (o.PLACEMENT_TIER_OVERRIDE_NAME IS NOT NULL OR o.STATUS_MATCH_TIER_OVERRIDE_NAME IS NOT NULL OR o.ROLLOVER_TIER_OVERRIDE_NAME IS NOT NULL OR o.INVITE_ONLY_APPROVALS IS NOT NULL))
),
fmti_eff AS (   -- effective ids the FMTI export emits (mirrors sql_fmti's cohort filter)
    SELECT DISTINCT e.effective_loyalty_id AS loyalty_account_id
    FROM FES_USERS.ALEX_SOTIS.TP_EFFECTIVE_SNAPSHOT e
    WHERE e.source_loyalty_id IN (SELECT LOYALTY_ACCOUNT_ID::VARCHAR FROM active_source_loyalty)
),
ledger_eff AS (SELECT DISTINCT loyalty_account_id FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT),
override_eff AS (
    SELECT DISTINCT e.effective_loyalty_id AS loyalty_account_id
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2 o JOIN FES_USERS.ALEX_SOTIS.TP_EFFECTIVE_SNAPSHOT e ON e.private_fan_id = o.PRIVATE_FAN_ID
    WHERE ( o.INVITE_ONLY_APPROVALS IS NOT NULL OR o.PLACEMENT_TIER_OVERRIDE_NAME IS NOT NULL OR o.PLACEMENT_START IS NOT NULL OR o.PLACEMENT_EXPIRY IS NOT NULL OR o.PLACEMENT_NOTE IS NOT NULL OR o.PLACEMENT_EXTRA_DATA IS NOT NULL OR o.STATUS_MATCH_TIER_OVERRIDE_NAME IS NOT NULL OR o.STATUS_MATCH_START IS NOT NULL OR o.STATUS_MATCH_EXPIRY IS NOT NULL OR o.STATUS_MATCH_NOTE IS NOT NULL OR o.STATUS_MATCH_EXTRA_DATA IS NOT NULL OR o.TRIAL_START IS NOT NULL OR o.TRIAL_EXPIRY IS NOT NULL OR COALESCE(o.TRIAL_TARGET_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_LIFETIME_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_ROLLOVER_TIER_POINTS, 0) <> 0 )
)
SELECT
  (SELECT COUNT(*) FROM ledger_eff)                              AS ledger_members,
  (SELECT MAX(chunk_num) + 1 FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT)                 AS n_chunks,
  (SELECT COUNT(*) FROM fmti_eff)                                AS fmti_accounts,
  (SELECT COUNT(*) FROM override_eff)                            AS override_members,
  (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.TP_EFFECTIVE_SNAPSHOT WHERE dup_group)              AS decollide_secondary_or_dup,
  (SELECT COUNT(*) FROM ledger_eff
     WHERE loyalty_account_id NOT IN (SELECT loyalty_account_id FROM fmti_eff))
                                                                 AS ledger_missing_account,   -- MUST be 0
  (SELECT COUNT(*) FROM override_eff
     WHERE loyalty_account_id NOT IN (SELECT loyalty_account_id FROM fmti_eff))
                                                                 AS overrides_missing_account, -- MUST be 0
  (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.TP_MIGRATION_UNRESOLVED)                            AS unresolved_active_fanids,  -- §P1
  (SELECT COALESCE(SUM(points_at_stake), 0) FROM FES_USERS.ALEX_SOTIS.TP_MIGRATION_UNRESOLVED)   AS unresolved_points_at_stake;

