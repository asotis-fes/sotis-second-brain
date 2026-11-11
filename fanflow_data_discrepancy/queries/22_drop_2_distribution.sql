-- Step 22: Characterize the drop_2 missing events
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- Headline by day
SELECT
    DATE_TRUNC('day', event_ts) AS event_date,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
GROUP BY 1
ORDER BY 1;

-- By site_id and tenant_id
SELECT
    site_id,
    tenant_id,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 20;

-- By status
SELECT
    txn_status,
    COUNT(*) AS event_count,
    ROUND(SUM(txn_amount), 4) AS total_amount
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
GROUP BY 1
ORDER BY 2 DESC;
