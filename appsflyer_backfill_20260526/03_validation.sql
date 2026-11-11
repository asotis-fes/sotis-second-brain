-- ============================================================================
-- APPSFLYER BACKFILL — VALIDATION (3-date refresh strategy)
-- ============================================================================
-- Run AFTER:
--   1. 02_refresh_affected_dts.sql completed.
--   2. dbt run --select appsflyer_user_id appsflyer_inapps_correction \
--                --full-refresh --target prod
--
-- Each row's verdict says 'validated' or 'NOT VALIDATED: <reason>'.
-- If every row says 'validated', recovery is complete.
-- ============================================================================

WITH
-- ----------------------------------------------------------------------------
-- INAPPS — DELETE+INSERT for dt IN (5/20, 5/21, 5/22)
-- ----------------------------------------------------------------------------
inapps_check AS (
    SELECT
        'APPSFLYER_INAPPS' AS model_name,
        -- counts post-operation
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS
            WHERE dt IN ('2026-05-20', '2026-05-21', '2026-05-22'))                          AS post_window,
        -- expected = source's count for the same window
        (SELECT COUNT(*) FROM appsflyer.appsflyer_fde_snowflake.inapps_view
            WHERE dt IN ('2026-05-20', '2026-05-21', '2026-05-22'))                          AS source_window,
        -- pre-window unchanged (rows with dt NOT in the affected set)
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS
            WHERE dt NOT IN ('2026-05-20', '2026-05-21', '2026-05-22')
               OR dt IS NULL)                                                                AS post_outside,
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_INAPPS_BACKUP20260526
            WHERE dt NOT IN ('2026-05-20', '2026-05-21', '2026-05-22')
               OR dt IS NULL)                                                                AS backup_outside,
        -- per-day counts for the verdict's detail field
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS WHERE dt = '2026-05-20')         AS post_d20,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS WHERE dt = '2026-05-21')         AS post_d21,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS WHERE dt = '2026-05-22')         AS post_d22
),
inapps_verdict AS (
    SELECT model_name,
        CASE
            WHEN post_outside != backup_outside
                THEN 'NOT VALIDATED: rows outside affected window changed (post=' || post_outside || ' backup=' || backup_outside || ')'
            WHEN post_window != source_window
                THEN 'NOT VALIDATED: affected window count does not match source (post=' || post_window || ' source=' || source_window || ')'
            WHEN post_d21 = 0
                THEN 'NOT VALIDATED: dt=5/21 still empty'
            ELSE 'validated'
        END AS verdict,
        'window=' || post_window || '/' || source_window
            || '  outside=' || post_outside || '/' || backup_outside
            || '  d20/21/22=' || post_d20 || '/' || post_d21 || '/' || post_d22 AS details
    FROM inapps_check
),

-- ----------------------------------------------------------------------------
-- INAPPS_CORRECTION — full-refreshed via dbt; mirrors INAPPS 1:1
-- ----------------------------------------------------------------------------
correction_check AS (
    SELECT
        'APPSFLYER_INAPPS_CORRECTION' AS model_name,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS_CORRECTION)                       AS post_rows,
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_INAPPS_CORRECTION_BACKUP20260526) AS backup_rows,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS)                                  AS inapps_rows,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INAPPS_CORRECTION
            WHERE dt IN ('2026-05-20', '2026-05-21', '2026-05-22'))                           AS post_window
),
correction_verdict AS (
    SELECT model_name,
        CASE
            WHEN post_rows != inapps_rows
                THEN 'NOT VALIDATED: row count does not match inapps (correction=' || post_rows || ' inapps=' || inapps_rows || ')'
            WHEN post_window = 0
                THEN 'NOT VALIDATED: no rows for affected window (5/20-5/22)'
            ELSE 'validated'
        END AS verdict,
        'rows=' || post_rows || '/' || backup_rows
            || '  inapps=' || inapps_rows
            || '  window=' || post_window AS details
    FROM correction_check
),

-- ----------------------------------------------------------------------------
-- USER_ID — full-refreshed via dbt
-- ----------------------------------------------------------------------------
user_id_check AS (
    SELECT
        'APPSFLYER_USER_ID' AS model_name,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_USER_ID)                                AS post_rows,
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_USER_ID_BACKUP20260526)         AS backup_rows
),
user_id_verdict AS (
    SELECT model_name,
        CASE
            WHEN post_rows < backup_rows
                THEN 'NOT VALIDATED: row count went down (post=' || post_rows || ' backup=' || backup_rows || ')'
            ELSE 'validated'
        END AS verdict,
        'rows=' || post_rows || '/' || backup_rows AS details
    FROM user_id_check
),

-- ----------------------------------------------------------------------------
-- Untouched models — exact match against backup
-- ----------------------------------------------------------------------------
untouched_check AS (
    SELECT 'APPSFLYER_CLICKS' AS model_name,
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_CLICKS) AS post_rows,
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_CLICKS_BACKUP20260526) AS backup_rows
    UNION ALL
    SELECT 'APPSFLYER_INSTALLS',
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_INSTALLS),
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_INSTALLS_BACKUP20260526)
    UNION ALL
    SELECT 'APPSFLYER_SESSIONS',
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_SESSIONS),
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_SESSIONS_BACKUP20260526)
    UNION ALL
    SELECT 'APPSFLYER_SSOT_UNIFIED',
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_SSOT_UNIFIED),
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_SSOT_UNIFIED_BACKUP20260526)
    UNION ALL
    SELECT 'APPSFLYER_SSOT_USER_ACQUISITION',
        (SELECT COUNT(*) FROM FDE.FDE_INFO.APPSFLYER_SSOT_USER_ACQUISITION),
        (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.APPSFLYER_SSOT_USER_ACQUISITION_BACKUP20260526)
),
untouched_verdict AS (
    SELECT model_name,
        CASE
            WHEN post_rows = backup_rows THEN 'validated'
            ELSE 'NOT VALIDATED: row count changed (post=' || post_rows || ' backup=' || backup_rows || ')'
        END AS verdict,
        'rows=' || post_rows || '/' || backup_rows AS details
    FROM untouched_check
)

-- ----------------------------------------------------------------------------
-- Final union — one row per model
-- ----------------------------------------------------------------------------
SELECT model_name, verdict, details FROM inapps_verdict
UNION ALL
SELECT model_name, verdict, details FROM correction_verdict
UNION ALL
SELECT model_name, verdict, details FROM user_id_verdict
UNION ALL
SELECT model_name, verdict, details FROM untouched_verdict
ORDER BY model_name;
