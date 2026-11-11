-- Step 27: Direct confirmation that the incident hour (2026-05-26 21:00-22:00 UTC) had 0 missing events
-- This re-runs the canonical anti-join scoped specifically to the incident window
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- Method 1: Count missing for incident hour using the persistent missing-events table
SELECT
    'incident_hour_21_22_UTC' AS scope,
    COUNT(*) AS missing_events
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
WHERE event_ts >= '2026-05-26 21:00:00'::TIMESTAMP_NTZ
  AND event_ts <  '2026-05-26 22:00:00'::TIMESTAMP_NTZ;

-- Method 2: Tighter — the actual ~8-minute outage window only
SELECT
    'incident_outage_window_21_13_to_21_22' AS scope,
    COUNT(*) AS missing_events
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
WHERE event_ts >= '2026-05-26 21:13:00'::TIMESTAMP_NTZ
  AND event_ts <  '2026-05-26 21:22:00'::TIMESTAMP_NTZ;

-- Method 3: Per-hour breakdown across our entire window — shows 21:00 hour has 0
-- (uses GENERATOR to include all hours, not just hours with gaps)
WITH all_hours AS (
    SELECT
        DATEADD('hour', SEQ4(), '2026-05-24 20:00:00'::TIMESTAMP_NTZ) AS hour_utc
    FROM TABLE(GENERATOR(ROWCOUNT => 76))  -- 76 hours covering 2026-05-24 20:00 -> 2026-05-28 00:00
),
gap_by_hour AS (
    SELECT
        DATE_TRUNC('hour', event_ts) AS hour_utc,
        COUNT(*) AS missing_events
    FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
    GROUP BY 1
)
SELECT
    h.hour_utc,
    COALESCE(g.missing_events, 0) AS missing_events,
    CASE
        WHEN h.hour_utc = '2026-05-26 21:00:00'::TIMESTAMP_NTZ THEN ' <-- INCIDENT HOUR'
        ELSE ''
    END AS note
FROM all_hours h
LEFT JOIN gap_by_hour g ON h.hour_utc = g.hour_utc
WHERE h.hour_utc >= '2026-05-26 18:00:00'::TIMESTAMP_NTZ
  AND h.hour_utc <  '2026-05-27 00:00:00'::TIMESTAMP_NTZ
ORDER BY h.hour_utc;
