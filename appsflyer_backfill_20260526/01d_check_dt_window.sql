-- ============================================================================
-- APPSFLYER BACKFILL — Per-_ingestion_time mismatch check across all 6
--                     source-fed models
-- ============================================================================
-- For each model, compares source vs target row counts grouped by
-- DATE(_ingestion_time). Use this version to directly demonstrate whether
-- the incremental WHERE clause has caused a gap — any (model, day) where
-- target < source on the _ingestion_time axis is data the model would have
-- ingested but didn't.
--
-- Only rows where source != target are returned. If a model has no rows
-- in the output, that model is fully in sync for the window.
--
-- Window: _ingestion_time >= '2026-05-14'.
--
-- Flag meanings:
--   'target empty — safe to INSERT only'        target has 0, source > 0
--   'target partial — safe to DELETE+INSERT'    source > target > 0
--   'NOT SAFE: source short'                    source < target  (would lose
--                                               data — leave it alone)
--   'NOT SAFE: source empty'                    source = 0, target > 0
-- ============================================================================

WITH
inapps_d AS (
    SELECT 'APPSFLYER_INAPPS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.inapps_view
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_INAPPS
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) tgt USING (d)
),
installs_d AS (
    SELECT 'APPSFLYER_INSTALLS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.installs_view
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_INSTALLS
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) tgt USING (d)
),
sessions_d AS (
    SELECT 'APPSFLYER_SESSIONS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.sessions_view
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_SESSIONS
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) tgt USING (d)
),
clicks_d AS (
    SELECT 'APPSFLYER_CLICKS' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.clicks_view
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_CLICKS
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) tgt USING (d)
),
ssot_unified_d AS (
    SELECT 'APPSFLYER_SSOT_UNIFIED' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.ssot_unified_view
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_SSOT_UNIFIED
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) tgt USING (d)
),
ssot_ua_d AS (
    SELECT 'APPSFLYER_SSOT_USER_ACQUISITION' AS model_name, d, COALESCE(src_n, 0) AS src_n, COALESCE(tgt_n, 0) AS tgt_n
    FROM (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS src_n
        FROM appsflyer.appsflyer_fde_snowflake.ssot_user_acquisition_view
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) src
    FULL OUTER JOIN (
        SELECT DATE(_ingestion_time) AS d, COUNT(*) AS tgt_n
        FROM FDE.FDE_INFO.APPSFLYER_SSOT_USER_ACQUISITION
        WHERE _ingestion_time >= '2026-05-14' GROUP BY 1
    ) tgt USING (d)
),
all_models AS (
    SELECT * FROM inapps_d UNION ALL
    SELECT * FROM installs_d UNION ALL
    SELECT * FROM sessions_d UNION ALL
    SELECT * FROM clicks_d UNION ALL
    SELECT * FROM ssot_unified_d UNION ALL
    SELECT * FROM ssot_ua_d
)
SELECT
    model_name,
    d,
    src_n,
    tgt_n,
    src_n - tgt_n AS delta,
    CASE
        WHEN tgt_n = 0 AND src_n > 0           THEN 'target empty — safe to INSERT only'
        WHEN src_n = 0 AND tgt_n > 0           THEN 'NOT SAFE: source empty'
        WHEN src_n > tgt_n                     THEN 'target partial — safe to DELETE+INSERT'
        WHEN src_n < tgt_n                     THEN 'NOT SAFE: source short'
        ELSE 'match'  -- should not appear due to WHERE filter below
    END AS flag
FROM all_models
WHERE src_n != tgt_n
ORDER BY model_name, d;
