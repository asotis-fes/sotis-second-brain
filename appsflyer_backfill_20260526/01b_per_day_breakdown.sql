-- ============================================================================
-- APPSFLYER BACKFILL — PER-DAY BREAKDOWN (diagnostic deep-dive)
-- ============================================================================
-- Run this after 01_diagnostics.sql to see WHICH days are problematic and by
-- how much.
--
-- Each row = one (model, day) combination. Columns:
--   src_n   — rows in the source view for that day
--   tgt_n   — rows in the target table for that day
--   delta   — src_n - tgt_n  (negative = source short; positive = source ahead)
--   flag    — quick interpretation:
--               'gap (target missing data)'  → source has rows target doesn't
--               'source short'               → target has rows source doesn't
--               'match'                      → exact match
--               'minor delta'                → within 1% — likely noise
--
-- Read this output to answer:
--   1. Is 5/21 genuinely missing from target? Look for flag = 'gap' on 2026-05-21.
--   2. Which days does source appear lossy on? Are they at retention edges
--      (5/12, today) or interior days (concerning)?
--   3. Does the lossy pattern look like retention rolloff or schema/filter
--      drift?
-- ============================================================================

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
    d,
    src_n,
    tgt_n,
    src_n - tgt_n AS delta,
    CASE
        WHEN tgt_n = 0 AND src_n > 0           THEN 'gap (target missing data)'
        WHEN src_n = 0 AND tgt_n > 0           THEN 'source short (target only)'
        WHEN src_n = tgt_n                     THEN 'match'
        WHEN ABS(src_n - tgt_n) * 100.0 / GREATEST(src_n, tgt_n) < 1.0 THEN 'minor delta'
        WHEN src_n > tgt_n                     THEN 'source ahead'
        ELSE 'source short'
    END AS flag
FROM all_days
ORDER BY model_name, d;
