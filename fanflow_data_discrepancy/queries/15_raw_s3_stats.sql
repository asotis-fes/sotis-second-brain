-- Step 15: Sanity check the raw S3 working table
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- Overall stats
SELECT
    COUNT(*) AS raw_event_count,
    COUNT(DISTINCT loyalty_txn_id) AS distinct_txn_ids,
    COUNT(DISTINCT _filename) AS distinct_files,
    MIN(event_ts) AS earliest_event_ts,
    MAX(event_ts) AS latest_event_ts,
    MIN(_file_modified_ts) AS earliest_file_ts,
    MAX(_file_modified_ts) AS latest_file_ts
FROM FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS;

-- Distribution by gap hour
SELECT
    DATE_TRUNC('hour', event_ts) AS event_hour_utc,
    COUNT(*) AS events,
    COUNT(DISTINCT loyalty_txn_id) AS distinct_txn_ids
FROM FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS
GROUP BY 1
ORDER BY 1;
