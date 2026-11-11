-- Step 20: Verify drop_2 external table
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT TRY_PARSE_JSON(a):loyTranId::STRING || '|' || TRY_PARSE_JSON(a):status::STRING) AS distinct_txn_id_status,
    MIN(TO_TIMESTAMP_NTZ(REPLACE(ts, ' UTC', ''))) AS min_ts,
    MAX(TO_TIMESTAMP_NTZ(REPLACE(ts, ' UTC', ''))) AS max_ts,
    DATEDIFF('day', MIN(TO_TIMESTAMP_NTZ(REPLACE(ts, ' UTC', ''))), MAX(TO_TIMESTAMP_NTZ(REPLACE(ts, ' UTC', '')))) AS days_covered
FROM FES_USERS.ALEX_SOTIS.INCIDENT_COMMERCE_LOYALTY_EVENTS_DROP_2_EXT;
