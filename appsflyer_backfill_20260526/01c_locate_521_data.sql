-- ============================================================================
-- APPSFLYER BACKFILL — LOCATE THE 5/21 DATA
-- ============================================================================
-- The per-day _ingestion_time diagnostic suggests the vendor's 5/21 backfill
-- was stamped with a RECENT _ingestion_time (probably today's), not 5/21.
-- This query checks where data with dt = '2026-05-21' actually lives, by:
--   - bucketing source rows for dt=5/21 by DATE(_ingestion_time)
--   - comparing source vs target row counts for dt=5/21
--   - reporting target's current MAX(_ingestion_time) so we can predict
--     whether a normal incremental run would pick the data up
--
-- For each model, three blocks:
--   A) Source: COUNT(*) by DATE(_ingestion_time) for dt=2026-05-21
--   B) Target: COUNT(*) by DATE(_ingestion_time) for dt=2026-05-21
--   C) Target: MAX(_ingestion_time) overall
--
-- Verdict per model:
--   - target_dt521_n = source_dt521_n        → already loaded, nothing to do
--   - target_dt521_n = 0 AND source_dt521_n > 0:
--       - if MIN source _ingestion_time for dt=521 > target MAX → normal
--         dbt run will pick it up automatically
--       - else                                              → manual backfill
--         is needed (source's 5/21 data has _ingestion_time
--         older than target's MAX)
-- ============================================================================

WITH per_model_summary AS (

    -- INAPPS
    SELECT 'APPSFLYER_INAPPS' AS model_name,
        (SELECT COUNT(*) FROM appsflyer.appsflyer_fde_snowflake.inapps_view WHERE dt = '2026-05-21')      AS source_dt521_n,
        (SELECT MIN(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.inapps_view WHERE dt = '2026-05-21') AS source_dt521_min_ingest,
        (SELECT MAX(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.inapps_view WHERE dt = '2026-05-21') AS source_dt521_max_ingest,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS WHERE dt = '2026-05-21')                       AS target_dt521_n,
        (SELECT MAX(_ingestion_time) FROM FDE.FDE_INFO.APPSFLYER_INAPPS)                                   AS target_max_ingest

    UNION ALL

    -- INSTALLS
    SELECT 'APPSFLYER_INSTALLS',
        (SELECT COUNT(*) FROM appsflyer.appsflyer_fde_snowflake.installs_view WHERE dt = '2026-05-21'),
        (SELECT MIN(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.installs_view WHERE dt = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.installs_view WHERE dt = '2026-05-21'),
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INSTALLS WHERE dt = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM FDE.FDE_INFO.APPSFLYER_INSTALLS)

    UNION ALL

    -- SESSIONS
    SELECT 'APPSFLYER_SESSIONS',
        (SELECT COUNT(*) FROM appsflyer.appsflyer_fde_snowflake.sessions_view WHERE dt = '2026-05-21'),
        (SELECT MIN(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.sessions_view WHERE dt = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.sessions_view WHERE dt = '2026-05-21'),
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_SESSIONS WHERE dt = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM FDE.FDE_INFO.APPSFLYER_SESSIONS)

    UNION ALL

    -- SSOT_UNIFIED (no dt column — use install_date instead? Check schema.)
    -- The ssot_unified model has install_date, not dt. Skip this one or
    -- substitute install_date.
    SELECT 'APPSFLYER_SSOT_UNIFIED',
        (SELECT COUNT(*) FROM appsflyer.appsflyer_fde_snowflake.ssot_unified_view WHERE install_date = '2026-05-21'),
        (SELECT MIN(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.ssot_unified_view WHERE install_date = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.ssot_unified_view WHERE install_date = '2026-05-21'),
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_SSOT_UNIFIED WHERE install_date = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM FDE.FDE_INFO.APPSFLYER_SSOT_UNIFIED)

    UNION ALL

    -- SSOT_USER_ACQUISITION (also uses install_date)
    SELECT 'APPSFLYER_SSOT_USER_ACQUISITION',
        (SELECT COUNT(*) FROM appsflyer.appsflyer_fde_snowflake.ssot_user_acquisition_view WHERE install_date = '2026-05-21'),
        (SELECT MIN(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.ssot_user_acquisition_view WHERE install_date = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.ssot_user_acquisition_view WHERE install_date = '2026-05-21'),
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_SSOT_USER_ACQUISITION WHERE install_date = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM FDE.FDE_INFO.APPSFLYER_SSOT_USER_ACQUISITION)

    UNION ALL

    -- CLICKS
    SELECT 'APPSFLYER_CLICKS',
        (SELECT COUNT(*) FROM appsflyer.appsflyer_fde_snowflake.clicks_view WHERE dt = '2026-05-21'),
        (SELECT MIN(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.clicks_view WHERE dt = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM appsflyer.appsflyer_fde_snowflake.clicks_view WHERE dt = '2026-05-21'),
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_CLICKS WHERE dt = '2026-05-21'),
        (SELECT MAX(_ingestion_time) FROM FDE.FDE_INFO.APPSFLYER_CLICKS)
)
SELECT
    model_name,
    source_dt521_n,
    target_dt521_n,
    source_dt521_n - target_dt521_n          AS missing_n,
    source_dt521_min_ingest,
    source_dt521_max_ingest,
    target_max_ingest,
    CASE
        WHEN source_dt521_n = 0
            THEN 'no 5/21 data in source — vendor did not backfill this model'
        WHEN target_dt521_n = source_dt521_n
            THEN 'already loaded — nothing to do'
        WHEN target_dt521_n = 0 AND source_dt521_min_ingest > target_max_ingest
            THEN 'normal dbt run will pick it up — no manual backfill needed'
        WHEN target_dt521_n = 0 AND source_dt521_min_ingest <= target_max_ingest
            THEN 'manual backfill required — source 5/21 ingest time is older than target MAX'
        WHEN target_dt521_n > 0 AND target_dt521_n < source_dt521_n
            THEN 'partial — some 5/21 rows in target, some in source only'
        ELSE 'unexpected state — investigate'
    END AS verdict
FROM per_model_summary
ORDER BY model_name;
