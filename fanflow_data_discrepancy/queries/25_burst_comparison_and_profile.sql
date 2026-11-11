-- Step 25: Compare 5/08 burst vs 5/26 burst characteristics + account/state profile
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- 1. 5/12 and 5/13 minute-level (the smaller secondary bursts in drop_2)
SELECT
    DATE_TRUNC('minute', event_ts) AS event_minute_utc,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) IN ('2026-05-12'::DATE, '2026-05-13'::DATE)
GROUP BY 1
ORDER BY 1;

-- 2. Status mix comparison: 5/08 burst vs 5/26 burst
SELECT
    '5/08 burst' AS burst_window,
    txn_status,
    COUNT(*) AS event_count,
    ROUND(SUM(txn_amount), 4) AS total_amount
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) = '2026-05-08'::DATE
GROUP BY 1, 2

UNION ALL

SELECT
    '5/26 burst' AS burst_window,
    txn_status,
    COUNT(*) AS event_count,
    ROUND(SUM(txn_amount), 4) AS total_amount
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
WHERE DATE_TRUNC('day', event_ts) = '2026-05-26'::DATE
GROUP BY 1, 2

ORDER BY 1, 3 DESC;

-- 3. US state (sub_div) distribution for the 5/08 burst
SELECT
    TRY_PARSE_JSON(raw_payload):subdiv::STRING AS sub_div,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) = '2026-05-08'::DATE
GROUP BY 1
ORDER BY 2 DESC;

-- 4. Account concentration on 5/08
SELECT
    COUNT(*) AS total_events,
    COUNT(DISTINCT loyalty_account_id) AS distinct_accounts,
    ROUND(COUNT(*) * 1.0 / COUNT(DISTINCT loyalty_account_id), 2) AS events_per_account
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) = '2026-05-08'::DATE;

-- 5. add_type distribution on 5/08 (1=EARN, 2=PROMO, etc per data dictionary)
SELECT
    add_type,
    txn_reason,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) = '2026-05-08'::DATE
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 20;
