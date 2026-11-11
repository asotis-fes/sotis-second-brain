-- Step 26: 5/12 and 5/13 minute-level distribution (the smaller secondary bursts)
SELECT
    DATE_TRUNC('minute', event_ts) AS event_minute_utc,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) IN ('2026-05-12'::DATE, '2026-05-13'::DATE)
GROUP BY 1
ORDER BY 1;
