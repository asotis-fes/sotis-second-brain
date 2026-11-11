USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00000/chunk_00000.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 0
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00001/chunk_00001.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 1
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00002/chunk_00002.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 2
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00003/chunk_00003.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 3
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00004/chunk_00004.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 4
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00005/chunk_00005.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 5
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00006/chunk_00006.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 6
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00007/chunk_00007.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 7
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00008/chunk_00008.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 8
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00009/chunk_00009.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 9
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00010/chunk_00010.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 10
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00011/chunk_00011.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 11
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00012/chunk_00012.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 12
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00013/chunk_00013.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 13
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00014/chunk_00014.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 14
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00015/chunk_00015.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 15
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00016/chunk_00016.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 16
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00017/chunk_00017.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 17
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00018/chunk_00018.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 18
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00019/chunk_00019.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 19
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00020/chunk_00020.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 20
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00021/chunk_00021.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 21
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;


COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod/ledger/chunk_00022/chunk_00022.csv.gz
FROM (
  SELECT transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, external_id_type, reference_id, transaction_status, derived_tier_points_amount, program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, status_match_active, placement_active, rollover_active, status_match_trial_earned_points, tier_points_multiplier
  FROM FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT
  WHERE chunk_num = 22
  ORDER BY loyalty_account_id, transaction_timestamp
)
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP)
HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE;

