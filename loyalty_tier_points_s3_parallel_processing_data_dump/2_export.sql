USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/fmti/fmti.csv.gz
FROM (
  SELECT
      lm.LOYALTY_ACCOUNT_ID AS loyalty_id,
      m."Id__c" AS id,
      m."MembershipNumber_c__c" AS privatefanid,
      m."InviteOnlyApprovals_c__c" AS inviteonlyapprovals,
      m."PlacementTierOverrideName_c__c" AS placementtieroverridename,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."PlacementStart_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS placementstart,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."PlacementExpiry_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS placementexpiry,
      m."PlacementNote_c__c" AS placementnote,
      m."PlacementExtraData_c__c" AS placementextradata,
      m."StatusMatchTierOverrideName_c__c" AS statusmatchtieroverridename,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."StatusMatchStart_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS statusmatchstart,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."StatusMatchExpiry_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS statusmatchexpiry,
      m."StatusMatchNote_c__c" AS statusmatchnote,
      m."StatusMatchExtraData_c__c" AS statusmatchextradata,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."TrialStart_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS trialstart,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."TrialExpiry_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS trialexpiry,
      m."TrialTargetPoints_c__c" AS trialtargetpoints,
      m."TrialStartTierPoints_c__c" AS trialstarttierpoints,
      m."TrialStartLifetimeTierPoints_c__c" AS trialstartlifetimetierpoints,
      m."TrialStartRolloverTierPoints_c__c" AS trialstartrollovertierpoints,
      m."RolloverTierOverrideName_c__c" AS rollovertieroverridename,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."RolloverStart_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS rolloverstart,
      TO_CHAR(CONVERT_TIMEZONE('UTC', m."RolloverExpiry_c__c"), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS rolloverexpiry,
      m."RollOverNote_c__c" AS rollovernote,
      m."RolloverExtraData_c__c" AS rolloverextradata,
      m."RolloverBalance_c__c" AS rolloverbalance,
      TRY_TO_NUMBER(NULLIF(TRIM(m."RolloverBalanceYear_c__c"::VARCHAR), ''))::INT      AS rolloverbalanceyear,
      TRY_TO_NUMBER(NULLIF(TRIM(m."BalanceOnLastRolloverYear_c__c"::VARCHAR), ''))::INT AS balanceonlastrolloveryear,
      m."TierPointsBeforeRollOver_c__c" AS tierpointsbeforerollover,
      m."RolloverPercent_c__c" AS rolloverpercent,
      m."LTTPMigrationF_c__c" AS lt_currentvalue,
      m."SMTPMigration_c__c" AS sm_currentvalue,
      m."TPMigration_c__c" AS tp_pointsbalance,
      m."isManuallyInviteApproved_c__c" AS manual_invite_approval,
      m."isInviteApprovedOnSmBlack_c__c" AS sm_invite_approval,
      m."isInviteApprovedOnPlacementBlack_c__c" AS placement_invite_approval
  FROM SALESFORCE."schema_FanJourney_Loyalty_Promotion_Shares"."FanMemberTierInformation_00DHs000003WzIz__dll" m
  JOIN FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT lm ON lm.PRIVATE_FAN_ID = m."MembershipNumber_c__c"
  WHERE (
        EXISTS (SELECT 1 FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 l
                WHERE l.PRIVATE_FAN_ID = m."MembershipNumber_c__c"
                  AND COALESCE(l.EXTERNAL_ID_TYPE, '') <> 'NON_TRANSACTOR')
     OR EXISTS (SELECT 1 FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2 o
                WHERE o.PRIVATE_FAN_ID = m."MembershipNumber_c__c"
                  AND ( o.INVITE_ONLY_APPROVALS IS NOT NULL OR o.PLACEMENT_TIER_OVERRIDE_NAME IS NOT NULL OR o.PLACEMENT_START IS NOT NULL OR o.PLACEMENT_EXPIRY IS NOT NULL OR o.PLACEMENT_NOTE IS NOT NULL OR o.PLACEMENT_EXTRA_DATA IS NOT NULL OR o.STATUS_MATCH_TIER_OVERRIDE_NAME IS NOT NULL OR o.STATUS_MATCH_START IS NOT NULL OR o.STATUS_MATCH_EXPIRY IS NOT NULL OR o.STATUS_MATCH_NOTE IS NOT NULL OR o.STATUS_MATCH_EXTRA_DATA IS NOT NULL OR o.TRIAL_START IS NOT NULL OR o.TRIAL_EXPIRY IS NOT NULL OR COALESCE(o.TRIAL_TARGET_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_LIFETIME_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_ROLLOVER_TIER_POINTS, 0) <> 0 )))
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY lm.LOYALTY_ACCOUNT_ID
    ORDER BY m."LastModifiedDate__c" DESC NULLS LAST, m."Id__c" DESC) = 1
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/override_cdc/overrides.csv.gz
FROM (
  WITH override_rows AS (
    SELECT
        lm.LOYALTY_ACCOUNT_ID, o.PRIVATE_FAN_ID, o.LAST_MODIFIED_DATE, o.INVITE_ONLY_APPROVALS,
        o.PLACEMENT_TIER_OVERRIDE_NAME, o.PLACEMENT_START, o.PLACEMENT_EXPIRY, o.PLACEMENT_NOTE, o.PLACEMENT_EXTRA_DATA,
        o.STATUS_MATCH_TIER_OVERRIDE_NAME, o.STATUS_MATCH_START, o.STATUS_MATCH_EXPIRY, o.STATUS_MATCH_NOTE, o.STATUS_MATCH_EXTRA_DATA,
        o.TRIAL_START, o.TRIAL_EXPIRY, o.TRIAL_TARGET_POINTS, o.TRIAL_START_TIER_POINTS,
        o.TRIAL_START_LIFETIME_TIER_POINTS, o.TRIAL_START_ROLLOVER_TIER_POINTS,
        CASE WHEN ( o.INVITE_ONLY_APPROVALS IS NOT NULL OR o.PLACEMENT_TIER_OVERRIDE_NAME IS NOT NULL OR o.PLACEMENT_START IS NOT NULL OR o.PLACEMENT_EXPIRY IS NOT NULL OR o.PLACEMENT_NOTE IS NOT NULL OR o.PLACEMENT_EXTRA_DATA IS NOT NULL OR o.STATUS_MATCH_TIER_OVERRIDE_NAME IS NOT NULL OR o.STATUS_MATCH_START IS NOT NULL OR o.STATUS_MATCH_EXPIRY IS NOT NULL OR o.STATUS_MATCH_NOTE IS NOT NULL OR o.STATUS_MATCH_EXTRA_DATA IS NOT NULL OR o.TRIAL_START IS NOT NULL OR o.TRIAL_EXPIRY IS NOT NULL OR COALESCE(o.TRIAL_TARGET_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_LIFETIME_TIER_POINTS, 0) <> 0 OR COALESCE(o.TRIAL_START_ROLLOVER_TIER_POINTS, 0) <> 0 ) THEN 1 ELSE 0 END AS has_override_data
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2 o
    JOIN FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT lm ON lm.PRIVATE_FAN_ID = o.PRIVATE_FAN_ID
  ),
  override_history AS (
    SELECT override_rows.*,
           MAX(has_override_data) OVER (
               PARTITION BY PRIVATE_FAN_ID ORDER BY LAST_MODIFIED_DATE
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS had_previous_override
    FROM override_rows
  )
  SELECT
      LOYALTY_ACCOUNT_ID,
      PRIVATE_FAN_ID,
      TO_CHAR(CONVERT_TIMEZONE('UTC', LAST_MODIFIED_DATE), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS last_modified_date,
      INVITE_ONLY_APPROVALS,
      PLACEMENT_TIER_OVERRIDE_NAME,
      TO_CHAR(CONVERT_TIMEZONE('UTC', PLACEMENT_START), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS placement_start,
      TO_CHAR(CONVERT_TIMEZONE('UTC', PLACEMENT_EXPIRY), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS placement_expiry,
      PLACEMENT_NOTE,
      PLACEMENT_EXTRA_DATA,
      STATUS_MATCH_TIER_OVERRIDE_NAME,
      TO_CHAR(CONVERT_TIMEZONE('UTC', STATUS_MATCH_START), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS status_match_start,
      TO_CHAR(CONVERT_TIMEZONE('UTC', STATUS_MATCH_EXPIRY), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS status_match_expiry,
      STATUS_MATCH_NOTE,
      STATUS_MATCH_EXTRA_DATA,
      TO_CHAR(CONVERT_TIMEZONE('UTC', TRIAL_START), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS trial_start,
      TO_CHAR(CONVERT_TIMEZONE('UTC', TRIAL_EXPIRY), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS trial_expiry,
      TRIAL_TARGET_POINTS,
      TRIAL_START_TIER_POINTS,
      TRIAL_START_LIFETIME_TIER_POINTS,
      TRIAL_START_ROLLOVER_TIER_POINTS
  FROM override_history
  WHERE (has_override_data = 1 OR COALESCE(had_previous_override, 0) = 1)
  ORDER BY LOYALTY_ACCOUNT_ID, LAST_MODIFIED_DATE
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00000/chunk_00000.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 0
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00001/chunk_00001.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 1
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00002/chunk_00002.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 2
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00003/chunk_00003.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 3
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00004/chunk_00004.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 4
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00005/chunk_00005.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 5
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00006/chunk_00006.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 6
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00007/chunk_00007.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 7
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00008/chunk_00008.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 8
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00009/chunk_00009.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 9
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00010/chunk_00010.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 10
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00011/chunk_00011.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 11
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00012/chunk_00012.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 12
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00013/chunk_00013.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 13
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00014/chunk_00014.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 14
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00015/chunk_00015.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 15
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00016/chunk_00016.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 16
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00017/chunk_00017.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 17
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00018/chunk_00018.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 18
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00019/chunk_00019.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 19
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00020/chunk_00020.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 20
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00021/chunk_00021.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 21
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/ledger/chunk_00022/chunk_00022.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 22
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;

