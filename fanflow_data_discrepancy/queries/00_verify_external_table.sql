-- Verify external table from prior session is still queryable
SELECT
    COUNT(*) AS commerce_rows,
    COUNT(DISTINCT TRY_PARSE_JSON(a):loyTranId::STRING || '|' || TRY_PARSE_JSON(a):status::STRING) AS distinct_txn_id_status,
    MIN(TO_TIMESTAMP_NTZ(REPLACE(ts, ' UTC', ''))) AS min_ts,
    MAX(TO_TIMESTAMP_NTZ(REPLACE(ts, ' UTC', ''))) AS max_ts
FROM FES_USERS.ALEX_SOTIS.INCIDENT_COMMERCE_LOYALTY_EVENTS_EXT;
