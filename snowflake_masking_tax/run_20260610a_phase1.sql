-- ============================================================
-- MASKING TAX - PHASE 1 SMOKE TEST
-- Run ID:    20260610a
-- Warehouse: FDE_DEVELOPER_XS_WH (XS)
-- Table:     FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A (1M rows)
-- Purpose:   Verify harness produces a directionally-correct,
--            non-zero P_HASH vs BASELINE delta before committing
--            to the 180M-row Phase 2.
-- ============================================================

-- ---- 0. SESSION SETUP ----
USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_XS_WH;
ALTER WAREHOUSE FDE_DEVELOPER_XS_WH SET WAREHOUSE_SIZE = 'XSMALL';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;

SELECT
    CURRENT_ROLE()             AS primary_role,
    CURRENT_SECONDARY_ROLES()  AS secondary_roles_json,
    CURRENT_WAREHOUSE()        AS wh;

-- ---- 1. SYNTHETIC TABLE (1M rows) ----
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A AS
WITH base AS (
    SELECT SEQ8() AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 1000000))
)
SELECT
    rn                                                                  AS id,
    UUID_STRING()                                                       AS fan_id,
    'user' || rn || '@example.com'                                      AS email,
    LPAD(MOD(ABS(HASH(rn)), 9000000000) + 1000000000, 10, '0')          AS phone,
    'First' || MOD(rn, 1000)                                            AS first_name,
    'Last'  || MOD(rn, 5000)                                            AS last_name,
    DATEADD('day', -MOD(rn, 3650), CURRENT_DATE())                      AS dob,
    DATEADD('second', -MOD(rn, 3 * 365 * 86400), CURRENT_TIMESTAMP())   AS event_ts,
    CASE MOD(rn, 5)
        WHEN 0 THEN 'NY' WHEN 1 THEN 'NJ' WHEN 2 THEN 'PA'
        WHEN 3 THEN 'FL' ELSE 'CA' END                                  AS state,
    (MOD(ABS(HASH(rn)), 10000000) / 100.0)::NUMBER(12,2)                AS amount,
    MOD(rn, 7) = 0                                                      AS is_vip,
    'note ' || SUBSTR(SHA1(rn::STRING), 1, 40)                          AS notes
FROM base;

SELECT COUNT(*) AS row_count FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A;

-- ---- 2. SCRATCH ROLES + GRANTS ----
CREATE OR REPLACE ROLE TEST_PII_READER_20260610A;
CREATE OR REPLACE ROLE TEST_PII_EXCLUDED_20260610A;

GRANT ROLE TEST_PII_READER_20260610A   TO USER "ALEX.SOTIS@BETFANATICS.COM";
GRANT ROLE TEST_PII_EXCLUDED_20260610A TO USER "ALEX.SOTIS@BETFANATICS.COM";

GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_XS_WH         TO ROLE TEST_PII_READER_20260610A;
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_XS_WH         TO ROLE TEST_PII_EXCLUDED_20260610A;
GRANT USAGE ON DATABASE FES_USERS                    TO ROLE TEST_PII_READER_20260610A;
GRANT USAGE ON DATABASE FES_USERS                    TO ROLE TEST_PII_EXCLUDED_20260610A;
GRANT USAGE ON SCHEMA   FES_USERS.ALEX_SOTIS         TO ROLE TEST_PII_READER_20260610A;
GRANT USAGE ON SCHEMA   FES_USERS.ALEX_SOTIS         TO ROLE TEST_PII_EXCLUDED_20260610A;
GRANT SELECT ON TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A TO ROLE TEST_PII_READER_20260610A;
GRANT SELECT ON TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A TO ROLE TEST_PII_EXCLUDED_20260610A;

-- ---- 3. MASKING POLICIES (all 4 — even though smoke test uses only P_HASH,
--       creating them all now means Phase 2 won't need to recreate them) ----
CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_NULL_20260610A AS
    (val STRING) RETURNS STRING -> NULL;

CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_20260610A AS
    (val STRING) RETURNS STRING -> SHA2(val, 256);

CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_20260610A AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() = 'TEST_PII_READER_20260610A' THEN val
        ELSE SHA2(val, 256)
    END;

CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_ISR_20260610A AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN IS_ROLE_IN_SESSION('TEST_PII_READER_20260610A') THEN val
        ELSE SHA2(val, 256)
    END;

-- ---- 4. ENFORCEMENT VERIFICATION ----
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A
    MODIFY COLUMN email
    SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_20260610A;

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
SELECT 'COND / ACCOUNTADMIN / sec=NONE' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A LIMIT 3;
-- expect: 64-char SHA2 hex strings

USE ROLE TEST_PII_READER_20260610A;
SELECT 'COND / READER / sec=NONE' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A LIMIT 3;
-- expect: 'user0@example.com', 'user1@example.com', ...

USE ROLE TEST_PII_EXCLUDED_20260610A;
SELECT 'COND / EXCLUDED / sec=NONE' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A LIMIT 3;
-- expect: SHA2 strings

USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A
    MODIFY COLUMN email UNSET MASKING POLICY;

-- Verify ISR variant
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A
    MODIFY COLUMN email
    SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_ISR_20260610A;

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
SELECT 'ISR / ACCOUNTADMIN / sec=NONE' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A LIMIT 3;
-- expect: SHA2

USE ROLE TEST_PII_READER_20260610A;
SELECT 'ISR / READER / sec=NONE' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A LIMIT 3;
-- expect: plaintext

USE SECONDARY ROLES ALL;
USE ROLE ACCOUNTADMIN;
SELECT 'ISR / ACCOUNTADMIN / sec=ALL (DANGER demo)' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A LIMIT 3;
-- expect: plaintext — TEST_PII_READER is in user's secondary role set,
--         so IS_ROLE_IN_SESSION returns TRUE. This is the failure mode
--         the §1.3 mitigation prevents.

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A
    MODIFY COLUMN email UNSET MASKING POLICY;

-- ============================================================
-- 5. SMOKE-TEST CELLS
-- ============================================================
-- 10 reps each, query tag carries cell identity + rep number.
-- Discard reps 1-2 as warmup, report median/p90/stddev of reps 3-10.
-- Cache control: WH suspend/resume once per cell + USE_CACHED_RESULT = FALSE.

ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_XS_WH;

-- ===== CELL S1: BASELINE Q2 (no policy on email) =====
ALTER WAREHOUSE FDE_DEVELOPER_XS_WH SUSPEND;
SELECT 1;  -- triggers RESUME

EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER DEFAULT 10;
    i INTEGER DEFAULT 1;
    base_tag STRING DEFAULT 'mtax|phase=p1|variant=BASELINE|q=Q2|role=ADMIN';
    rep_tag STRING;
BEGIN
    WHILE (i <= n) DO
        rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
        EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
        EXECUTE IMMEDIATE 'SELECT COUNT(DISTINCT email) FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A';
        i := i + 1;
    END WHILE;
    RETURN 'S1 done';
END;
$$;

-- ===== CELL S2: P_HASH on email, Q2 =====
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A
    MODIFY COLUMN email
    SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_20260610A;

ALTER WAREHOUSE FDE_DEVELOPER_XS_WH SUSPEND;
SELECT 1;

EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER DEFAULT 10;
    i INTEGER DEFAULT 1;
    base_tag STRING DEFAULT 'mtax|phase=p1|variant=P_HASH|q=Q2|role=ADMIN';
    rep_tag STRING;
BEGIN
    WHILE (i <= n) DO
        rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
        EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
        EXECUTE IMMEDIATE 'SELECT COUNT(DISTINCT email) FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A';
        i := i + 1;
    END WHILE;
    RETURN 'S2 done';
END;
$$;

ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_20260610A
    MODIFY COLUMN email UNSET MASKING POLICY;

-- ============================================================
-- 6. RESULTS PULL
-- ============================================================

ALTER SESSION UNSET QUERY_TAG;

WITH raw AS (
    SELECT
        query_id,
        query_tag,
        compilation_time,
        execution_time,
        total_elapsed_time,
        bytes_scanned,
        credits_used_cloud_services,
        warehouse_size,
        start_time
    FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
        USER_NAME            => CURRENT_USER(),
        RESULT_LIMIT         => 1000,
        END_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())
    ))
    WHERE query_tag LIKE 'mtax|phase=p1|%'
),
parsed AS (
    SELECT
        SPLIT_PART(SPLIT_PART(query_tag, '|', 3), '=', 2) AS variant,
        TRY_TO_NUMBER(SPLIT_PART(SPLIT_PART(query_tag, '|', 6), '=', 2)) AS rep,
        compilation_time,
        execution_time,
        total_elapsed_time,
        bytes_scanned,
        credits_used_cloud_services,
        warehouse_size,
        start_time
    FROM raw
)
SELECT
    variant,
    COUNT(*) AS n_runs,
    -- Steady-state (reps 3-10)
    MEDIAN(CASE WHEN rep > 2 THEN total_elapsed_time END) AS total_ms_median_steady,
    MEDIAN(CASE WHEN rep > 2 THEN compilation_time   END) AS compile_ms_median_steady,
    MEDIAN(CASE WHEN rep > 2 THEN execution_time     END) AS exec_ms_median_steady,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY total_elapsed_time)
                                                          AS total_ms_p90_all,
    STDDEV(CASE WHEN rep > 2 THEN total_elapsed_time END) AS total_ms_stddev_steady,
    -- All reps (for visibility into warmup)
    MIN(total_elapsed_time)  AS total_ms_min_all,
    MAX(total_elapsed_time)  AS total_ms_max_all,
    AVG(bytes_scanned)       AS bytes_scanned_avg,
    AVG(credits_used_cloud_services) AS cloud_credits_avg,
    ANY_VALUE(warehouse_size) AS wh_size
FROM parsed
GROUP BY variant
ORDER BY variant;

-- ============================================================
-- NOTE: Cleanup is intentionally NOT run here.
-- The synthetic table, roles, and policies are reused by Phase 2.
-- Cleanup runs at the end of Phase 2.
-- ============================================================
