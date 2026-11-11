-- ============================================================================
-- APPSFLYER BACKFILL — DIAGNOSTICS
-- ============================================================================
-- Run this BEFORE 02_delete_insert.sql.
--
-- Decision rule per model: source row count must be >= target row count
-- for every day in the 5/12+ window. Otherwise the DELETE+INSERT would
-- lose data.
--
-- Verdict column shows 'safe to proceed' or 'not safe to proceed'.
-- If anything says 'not safe', scroll down to Query 2 for per-day detail.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- QUERY 1 — headline verdict per model
-- ----------------------------------------------------------------------------
WITH
inapps_days AS (
    SELECT 'APPSFLYER_INAPPS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.inapps_view
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_INAPPS
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) tgt USING (d)
),
installs_days AS (
    SELECT 'APPSFLYER_INSTALLS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.installs_view
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_INSTALLS
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) tgt USING (d)
),
sessions_days AS (
    SELECT 'APPSFLYER_SESSIONS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.sessions_view
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_SESSIONS
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) tgt USING (d)
),
ssot_unified_days AS (
    SELECT 'APPSFLYER_SSOT_UNIFIED' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.ssot_unified_view
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_SSOT_UNIFIED
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) tgt USING (d)
),
ssot_ua_days AS (
    SELECT 'APPSFLYER_SSOT_USER_ACQUISITION' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.ssot_user_acquisition_view
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_SSOT_USER_ACQUISITION
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) tgt USING (d)
),
clicks_days AS (
    -- clicks_view was contractually removed; included for completeness.
    -- If src_n is zero everywhere, do NOT include clicks in DELETE+INSERT.
    SELECT 'APPSFLYER_CLICKS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.clicks_view
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_CLICKS
        WHERE _ingestion_time > '2026-05-11' GROUP BY 1
    ) tgt USING (d)
),
all_days AS (
    SELECT * FROM inapps_days UNION ALL
    SELECT * FROM installs_days UNION ALL
    SELECT * FROM sessions_days UNION ALL
    SELECT * FROM ssot_unified_days UNION ALL
    SELECT * FROM ssot_ua_days UNION ALL
    SELECT * FROM clicks_days
)
SELECT
    model_name,
    SUM(src_n)                              AS total_source_window_rows,
    SUM(tgt_n)                              AS total_target_window_rows,
    SUM(src_n) - SUM(tgt_n)                 AS total_delta,
    MIN(src_n - tgt_n)                      AS worst_day_delta,
    CASE
        WHEN SUM(src_n) = 0 AND SUM(tgt_n) = 0
            THEN 'no rows in window — verify if expected'
        WHEN SUM(src_n) = 0 AND SUM(tgt_n) > 0
            THEN 'not safe to proceed: source has no rows in window'
        WHEN MIN(src_n - tgt_n) < 0
            THEN 'not safe to proceed: source is short on at least one day'
        ELSE 'safe to proceed'
    END                                      AS verdict
FROM all_days
GROUP BY model_name
ORDER BY model_name;

-- ----------------------------------------------------------------------------
-- QUERY 2 — per-day breakdown (only run if any verdict is "not safe")
-- ----------------------------------------------------------------------------
-- Uncomment to inspect:
--
-- WITH ... (same CTEs as above) ...
-- SELECT model_name, d, src_n, tgt_n, src_n - tgt_n AS delta
-- FROM all_days
-- WHERE src_n - tgt_n < 0  -- only days where source is short
-- ORDER BY model_name, d;
