-- Step 24: Minute-level distribution within 2026-05-08 (the 1,763-event burst day)
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- Hour-level on 5/08 first
SELECT
    DATE_TRUNC('hour', event_ts) AS event_hour_utc,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) = '2026-05-08'::DATE
GROUP BY 1
ORDER BY 1;

-- Minute-level on 5/08 — only minutes with at least one missing event
SELECT
    DATE_TRUNC('minute', event_ts) AS event_minute_utc,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) = '2026-05-08'::DATE
GROUP BY 1
ORDER BY 1
LIMIT 100;

-- The actual time range (min, max, span) of the 5/08 burst
SELECT
    MIN(event_ts) AS earliest_missing,
    MAX(event_ts) AS latest_missing,
    DATEDIFF('minute', MIN(event_ts), MAX(event_ts)) AS span_minutes
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
WHERE DATE_TRUNC('day', event_ts) = '2026-05-08'::DATE;
