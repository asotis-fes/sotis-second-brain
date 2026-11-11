-- Step 5: Dollar value totals by txn_status
-- Anna asked specifically for earns vs captures total value, separately
SELECT
    txn_status,
    COUNT(*) AS event_count,
    ROUND(SUM(txn_amount), 6) AS total_amount,
    ROUND(MIN(txn_amount), 8) AS min_amount,
    ROUND(MAX(txn_amount), 6) AS max_amount,
    ROUND(AVG(txn_amount), 8) AS avg_amount
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
GROUP BY 1
ORDER BY 2 DESC;

-- Grand total across all 599
SELECT
    COUNT(*) AS total_events,
    ROUND(SUM(txn_amount), 6) AS grand_total_amount
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS;

-- Re-check hour distribution to confirm 23:00 UTC dropped from gap hours
SELECT
    DATE_TRUNC('hour', event_ts) AS gap_hour_utc,
    txn_status,
    COUNT(*) AS event_count,
    ROUND(SUM(txn_amount), 6) AS total_amount
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
GROUP BY 1, 2
ORDER BY 1, 2;
