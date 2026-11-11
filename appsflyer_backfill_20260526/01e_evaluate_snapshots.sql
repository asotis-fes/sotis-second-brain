-- ============================================================================
-- APPSFLYER — Evaluate two snapshots for "stale _ingestion_time" bug pattern
-- ============================================================================
-- Setup: appsflyer_inapps_snapshot and appsflyer_installs_snapshot each have
--        TWO runs at this point (yesterday + today).
--
-- The bug we're hunting: rows that appear in today's snapshot but were absent
-- yesterday, AND whose _ingestion_time is at or before yesterday's MAX. Those
-- rows would NEVER be pulled in by the incremental WHERE clause
-- (`_ingestion_time > MAX(_ingestion_time) FROM {{ this }}`), because target's
-- MAX has already advanced past them.
--
-- Three queries below:
--   1. Summary verdict per model — one row per model with a yes/no answer.
--   2. Per-ingest-day delta — shows where the row-count change happened.
--   3. Sample of the bug-pattern rows (limit 20) — for spot-checking what
--      content these rows carry.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. SUMMARY VERDICT PER MODEL
-- ----------------------------------------------------------------------------
WITH
inapps_snaps AS (
    SELECT
        snapshot_ts,
        _ingestion_time,
        row_hash
    FROM FDE.FDE_INFO.APPSFLYER_INAPPS_SNAPSHOT
),
inapps_pair AS (
    SELECT MIN(snapshot_ts) AS y_ts, MAX(snapshot_ts) AS t_ts
    FROM (SELECT DISTINCT snapshot_ts FROM inapps_snaps)
),
inapps_y_max AS (
    SELECT MAX(_ingestion_time) AS y_max
    FROM inapps_snaps, inapps_pair
    WHERE snapshot_ts = y_ts
),
inapps_y_hashes AS (
    SELECT DISTINCT row_hash
    FROM inapps_snaps, inapps_pair
    WHERE snapshot_ts = y_ts
),
inapps_today AS (
    SELECT _ingestion_time, row_hash
    FROM inapps_snaps, inapps_pair
    WHERE snapshot_ts = t_ts
),
inapps_summary AS (
    SELECT
        'APPSFLYER_INAPPS' AS model_name,
        (SELECT y_ts FROM inapps_pair)                                                       AS yesterday_ts,
        (SELECT t_ts FROM inapps_pair)                                                       AS today_ts,
        (SELECT y_max FROM inapps_y_max)                                                     AS yesterday_max_ingest,
        (SELECT COUNT(*) FROM inapps_today)                                                  AS today_total_rows,
        (SELECT COUNT(*) FROM inapps_today t WHERE t.row_hash NOT IN (SELECT row_hash FROM inapps_y_hashes)) AS new_rows_in_today,
        (SELECT COUNT(*) FROM inapps_today t, inapps_y_max y
            WHERE t._ingestion_time <= y.y_max
              AND t.row_hash NOT IN (SELECT row_hash FROM inapps_y_hashes))                  AS bug_rows
),

installs_snaps AS (
    SELECT
        snapshot_ts,
        _ingestion_time,
        row_hash
    FROM FDE.FDE_INFO.APPSFLYER_INSTALLS_SNAPSHOT
),
installs_pair AS (
    SELECT MIN(snapshot_ts) AS y_ts, MAX(snapshot_ts) AS t_ts
    FROM (SELECT DISTINCT snapshot_ts FROM installs_snaps)
),
installs_y_max AS (
    SELECT MAX(_ingestion_time) AS y_max
    FROM installs_snaps, installs_pair
    WHERE snapshot_ts = y_ts
),
installs_y_hashes AS (
    SELECT DISTINCT row_hash
    FROM installs_snaps, installs_pair
    WHERE snapshot_ts = y_ts
),
installs_today AS (
    SELECT _ingestion_time, row_hash
    FROM installs_snaps, installs_pair
    WHERE snapshot_ts = t_ts
),
installs_summary AS (
    SELECT
        'APPSFLYER_INSTALLS' AS model_name,
        (SELECT y_ts FROM installs_pair),
        (SELECT t_ts FROM installs_pair),
        (SELECT y_max FROM installs_y_max),
        (SELECT COUNT(*) FROM installs_today),
        (SELECT COUNT(*) FROM installs_today t WHERE t.row_hash NOT IN (SELECT row_hash FROM installs_y_hashes)),
        (SELECT COUNT(*) FROM installs_today t, installs_y_max y
            WHERE t._ingestion_time <= y.y_max
              AND t.row_hash NOT IN (SELECT row_hash FROM installs_y_hashes))
)

SELECT
    model_name,
    yesterday_ts,
    today_ts,
    yesterday_max_ingest,
    today_total_rows,
    new_rows_in_today,
    bug_rows,
    CASE
        WHEN bug_rows > 0
            THEN 'EVIDENCE FOUND: ' || bug_rows || ' row(s) would be skipped by incremental'
        ELSE 'no evidence of stale-_ingestion_time late arrivals between these two snapshots'
    END AS verdict
FROM (
    SELECT * FROM inapps_summary
    UNION ALL
    SELECT * FROM installs_summary
)
ORDER BY model_name;


-- ----------------------------------------------------------------------------
-- 2. PER-INGEST-DAY DELTA (where the row count change happened)
-- ----------------------------------------------------------------------------
-- For each (model, DATE(_ingestion_time)) bucket: how many rows in yesterday's
-- snapshot vs today's. Positive delta on an OLD day (i.e. not today's ingest
-- date) = rows showed up in source with a stale _ingestion_time = bug pattern.
--
-- Uncomment and run separately:
--
-- WITH
-- inapps_pair AS (SELECT MIN(snapshot_ts) AS y_ts, MAX(snapshot_ts) AS t_ts
--                 FROM (SELECT DISTINCT snapshot_ts FROM FDE.FDE_INFO.APPSFLYER_INAPPS_SNAPSHOT)),
-- inapps_by_day AS (
--     SELECT 'APPSFLYER_INAPPS' AS model_name,
--            DATE(_ingestion_time) AS ingest_d,
--            SUM(CASE WHEN snapshot_ts = (SELECT y_ts FROM inapps_pair) THEN 1 ELSE 0 END) AS y_n,
--            SUM(CASE WHEN snapshot_ts = (SELECT t_ts FROM inapps_pair) THEN 1 ELSE 0 END) AS t_n
--     FROM FDE.FDE_INFO.APPSFLYER_INAPPS_SNAPSHOT
--     GROUP BY 1, 2
-- ),
-- installs_pair AS (SELECT MIN(snapshot_ts) AS y_ts, MAX(snapshot_ts) AS t_ts
--                   FROM (SELECT DISTINCT snapshot_ts FROM FDE.FDE_INFO.APPSFLYER_INSTALLS_SNAPSHOT)),
-- installs_by_day AS (
--     SELECT 'APPSFLYER_INSTALLS' AS model_name,
--            DATE(_ingestion_time) AS ingest_d,
--            SUM(CASE WHEN snapshot_ts = (SELECT y_ts FROM installs_pair) THEN 1 ELSE 0 END) AS y_n,
--            SUM(CASE WHEN snapshot_ts = (SELECT t_ts FROM installs_pair) THEN 1 ELSE 0 END) AS t_n
--     FROM FDE.FDE_INFO.APPSFLYER_INSTALLS_SNAPSHOT
--     GROUP BY 1, 2
-- )
-- SELECT model_name, ingest_d, y_n AS yesterday_n, t_n AS today_n,
--        t_n - y_n AS delta,
--        CASE WHEN t_n > y_n AND ingest_d < CURRENT_DATE THEN 'late-arriving rows at stale ingest date'
--             WHEN t_n < y_n THEN 'rows aged out of source view'
--             WHEN t_n > y_n THEN 'new rows at today''s ingest date (normal)'
--             ELSE 'no change' END AS flag
-- FROM (SELECT * FROM inapps_by_day UNION ALL SELECT * FROM installs_by_day)
-- WHERE y_n != t_n
-- ORDER BY model_name, ingest_d;


-- ----------------------------------------------------------------------------
-- 3. SAMPLE BUG ROWS (spot-check what data these are)
-- ----------------------------------------------------------------------------
-- Pulls the first 20 actual "bug-pattern" rows from today's INAPPS snapshot,
-- so you can eyeball what content the vendor is late-loading with stale
-- ingestion_time. Useful if the verdict above says EVIDENCE FOUND.
--
-- Uncomment to run:
--
-- WITH
-- inapps_pair AS (SELECT MIN(snapshot_ts) AS y_ts, MAX(snapshot_ts) AS t_ts
--                 FROM (SELECT DISTINCT snapshot_ts FROM FDE.FDE_INFO.APPSFLYER_INAPPS_SNAPSHOT)),
-- inapps_y_max AS (SELECT MAX(_ingestion_time) AS y_max
--                  FROM FDE.FDE_INFO.APPSFLYER_INAPPS_SNAPSHOT s, inapps_pair
--                  WHERE s.snapshot_ts = y_ts),
-- inapps_y_hashes AS (SELECT DISTINCT row_hash
--                     FROM FDE.FDE_INFO.APPSFLYER_INAPPS_SNAPSHOT s, inapps_pair
--                     WHERE s.snapshot_ts = y_ts)
-- SELECT *
-- FROM FDE.FDE_INFO.APPSFLYER_INAPPS_SNAPSHOT s, inapps_y_max y, inapps_pair p
-- WHERE s.snapshot_ts = p.t_ts
--   AND s._ingestion_time <= y.y_max
--   AND s.row_hash NOT IN (SELECT row_hash FROM inapps_y_hashes)
-- LIMIT 20;
