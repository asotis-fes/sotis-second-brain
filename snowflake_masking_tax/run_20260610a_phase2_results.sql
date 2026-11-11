-- ============================================================
-- PHASE 2 RESULTS PULL
-- ============================================================
-- Run after the matrix completes. Pulls steady-state medians (reps 3-10)
-- per cell from INFORMATION_SCHEMA.QUERY_HISTORY (live, 14-day window),
-- then computes the tax vs the matching BASELINE cell.
--
-- Key filters (lessons from Phase 1):
--   - query_type = 'SELECT'        (exclude ALTER SESSION pollution)
--   - query_tag LIKE 'mtax|phase=p2|%'
--   - drop reps 1-2 (warmup) for steady-state agg
--
-- Three deliverables:
--   1. Raw per-rep table (sanity check)
--   2. Per-cell aggregate (n, median, p90, stddev, bytes, credits)
--   3. Tax table: masked - baseline, joined by (q, role_label)
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;

-- ===== 1. Raw per-rep view (for spot-checking individual cells) =====
WITH raw AS (
    SELECT
        query_id, query_tag, query_text,
        compilation_time, execution_time, total_elapsed_time,
        bytes_scanned, credits_used_cloud_services, warehouse_size, start_time
    FROM TABLE(FES_USERS.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
        USER_NAME            => CURRENT_USER(),
        RESULT_LIMIT         => 5000,
        END_TIME_RANGE_START => DATEADD('hour', -3, CURRENT_TIMESTAMP())
    ))
    WHERE query_tag LIKE 'mtax|phase=p2|%'
      AND query_type = 'SELECT'
      AND query_text NOT ILIKE 'ALTER%'
),
parsed AS (
    SELECT
        SPLIT_PART(SPLIT_PART(query_tag, '|', 3), '=', 2) AS variant,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 4), '=', 2) AS q,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 5), '=', 2) AS role_label,
        TRY_TO_NUMBER(SPLIT_PART(SPLIT_PART(query_tag, '|', 6), '=', 2)) AS rep,
        compilation_time, execution_time, total_elapsed_time,
        bytes_scanned, credits_used_cloud_services, warehouse_size, start_time
    FROM raw
)
SELECT variant, q, role_label, rep,
       total_elapsed_time AS total_ms,
       compilation_time   AS compile_ms,
       execution_time     AS exec_ms,
       bytes_scanned, warehouse_size
FROM parsed
ORDER BY q, variant, role_label, rep;

-- ===== 2. Per-cell aggregate (steady-state, reps 3-10) =====
WITH raw AS (
    SELECT
        query_tag, query_text,
        compilation_time, execution_time, total_elapsed_time,
        bytes_scanned, credits_used_cloud_services, warehouse_size
    FROM TABLE(FES_USERS.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
        USER_NAME            => CURRENT_USER(),
        RESULT_LIMIT         => 5000,
        END_TIME_RANGE_START => DATEADD('hour', -3, CURRENT_TIMESTAMP())
    ))
    WHERE query_tag LIKE 'mtax|phase=p2|%'
      AND query_type = 'SELECT'
      AND query_text NOT ILIKE 'ALTER%'
),
parsed AS (
    SELECT
        SPLIT_PART(SPLIT_PART(query_tag, '|', 3), '=', 2) AS variant,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 4), '=', 2) AS q,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 5), '=', 2) AS role_label,
        TRY_TO_NUMBER(SPLIT_PART(SPLIT_PART(query_tag, '|', 6), '=', 2)) AS rep,
        compilation_time, execution_time, total_elapsed_time,
        bytes_scanned, credits_used_cloud_services, warehouse_size
    FROM raw
),
steady AS (
    SELECT * FROM parsed WHERE rep > 2
)
SELECT
    q, variant, role_label,
    COUNT(*) AS n_runs,
    ROUND(MEDIAN(total_elapsed_time))           AS total_ms_median,
    ROUND(MEDIAN(compilation_time))             AS compile_ms_median,
    ROUND(MEDIAN(execution_time))               AS exec_ms_median,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY total_elapsed_time)) AS total_ms_p90,
    ROUND(STDDEV(total_elapsed_time))           AS total_ms_stddev,
    ROUND(STDDEV(total_elapsed_time) / NULLIF(MEDIAN(total_elapsed_time), 0), 3) AS cv_steady,
    ROUND(AVG(bytes_scanned))                   AS bytes_scanned_avg,
    AVG(credits_used_cloud_services)            AS cloud_credits_avg,
    ANY_VALUE(warehouse_size)                   AS wh_size
FROM steady
GROUP BY q, variant, role_label
ORDER BY q, variant, role_label;

-- ===== 3. Tax table: masked vs baseline, per (q, role) pair =====
-- For Q1/Q2/Q3, compare each masked variant to BASELINE/ADMIN of same q.
-- For Q4, only BASELINE exists.
-- For Q_MC, compare P_HASH_4COL to BASELINE_4COL.
WITH raw AS (
    SELECT
        query_tag, query_text,
        compilation_time, execution_time, total_elapsed_time,
        bytes_scanned, credits_used_cloud_services
    FROM TABLE(FES_USERS.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
        USER_NAME            => CURRENT_USER(),
        RESULT_LIMIT         => 5000,
        END_TIME_RANGE_START => DATEADD('hour', -3, CURRENT_TIMESTAMP())
    ))
    WHERE query_tag LIKE 'mtax|phase=p2|%'
      AND query_type = 'SELECT'
      AND query_text NOT ILIKE 'ALTER%'
),
parsed AS (
    SELECT
        SPLIT_PART(SPLIT_PART(query_tag, '|', 3), '=', 2) AS variant,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 4), '=', 2) AS q,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 5), '=', 2) AS role_label,
        TRY_TO_NUMBER(SPLIT_PART(SPLIT_PART(query_tag, '|', 6), '=', 2)) AS rep,
        compilation_time, execution_time, total_elapsed_time,
        bytes_scanned, credits_used_cloud_services
    FROM raw
    WHERE TRY_TO_NUMBER(SPLIT_PART(SPLIT_PART(query_tag, '|', 6), '=', 2)) > 2
),
agg AS (
    SELECT q, variant, role_label,
           MEDIAN(total_elapsed_time) AS total_ms,
           MEDIAN(compilation_time)   AS compile_ms,
           MEDIAN(execution_time)     AS exec_ms,
           AVG(bytes_scanned)         AS bytes_avg
    FROM parsed
    GROUP BY q, variant, role_label
),
baseline AS (
    -- The baseline cell for Q1/Q2/Q3 is BASELINE/ADMIN; for Q_MC it's BASELINE_4COL/ADMIN
    SELECT q, total_ms AS b_total_ms, compile_ms AS b_compile_ms,
           exec_ms AS b_exec_ms, bytes_avg AS b_bytes_avg
    FROM agg
    WHERE variant IN ('BASELINE', 'BASELINE_4COL') AND role_label = 'ADMIN'
)
SELECT
    a.q,
    a.variant,
    a.role_label,
    ROUND(a.total_ms)                                                     AS masked_total_ms,
    ROUND(b.b_total_ms)                                                   AS baseline_total_ms,
    ROUND(a.total_ms - b.b_total_ms)                                      AS delta_total_ms,
    ROUND(100.0 * (a.total_ms - b.b_total_ms) / NULLIF(b.b_total_ms, 0), 1) AS delta_total_pct,
    ROUND(a.compile_ms - b.b_compile_ms)                                  AS delta_compile_ms,
    ROUND(a.exec_ms    - b.b_exec_ms)                                     AS delta_exec_ms,
    ROUND(100.0 * (a.exec_ms - b.b_exec_ms) / NULLIF(b.b_exec_ms, 0), 1)  AS delta_exec_pct,
    ROUND(100.0 * (a.bytes_avg - b.b_bytes_avg) / NULLIF(b.b_bytes_avg, 0), 1) AS delta_bytes_pct
FROM agg a
JOIN baseline b ON a.q = b.q
WHERE a.variant NOT IN ('BASELINE', 'BASELINE_4COL')
ORDER BY a.q, a.variant, a.role_label;
