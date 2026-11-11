-- Step 17: Search raw S3 for our 599 missing events using TWO strategies
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- Strategy A: strict 3-column match (canonical join)
SELECT
    'A_strict_3_column' AS strategy,
    COUNT_IF(s.loyalty_txn_id IS NOT NULL) AS found_in_raw_s3,
    COUNT_IF(s.loyalty_txn_id IS NULL)     AS still_missing,
    COUNT(*) AS total_checked
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS m
LEFT JOIN FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS s
    ON COALESCE(NULLIF(m.loyalty_account_id, ''), '∅') = COALESCE(NULLIF(s.loyalty_account_id, ''), '∅')
   AND m.loyalty_txn_id = s.loyalty_txn_id
   AND m.txn_status    = s.txn_status

UNION ALL

-- Strategy B: loose match — by loyalty_txn_id alone (no account, no status filter)
SELECT
    'B_loose_loyTranId_only' AS strategy,
    COUNT_IF(EXISTS(SELECT 1 FROM FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS s WHERE s.loyalty_txn_id = m.loyalty_txn_id)) AS found_in_raw_s3,
    COUNT_IF(NOT EXISTS(SELECT 1 FROM FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS s WHERE s.loyalty_txn_id = m.loyalty_txn_id)) AS still_missing,
    COUNT(*) AS total_checked
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS m;
