-- ============================================================
-- MASKING TAX - PHASE 2 STAGE B: full 22-cell matrix + MC
-- Run ID:     20260610A
-- Warehouse:  FDE_DEVELOPER_SM_WH (SMALL)
-- Table:      FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A
-- Masked col: FANGRAPH_EMAIL
-- N reps:     10 per cell
-- ============================================================
-- ASSUMES STAGE A ALREADY RAN (clone exists, grants in place,
-- gut-check passed).
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_SM_WH;
ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SET WAREHOUSE_SIZE = 'SMALL';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;

-- Grant USAGE on SMALL warehouse to test roles (so cells under
-- READER/EXCLUDED can run there)
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_SM_WH TO ROLE TEST_PII_READER_20260610A;
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_SM_WH TO ROLE TEST_PII_EXCLUDED_20260610A;

SELECT CURRENT_ROLE() AS r, CURRENT_WAREHOUSE() AS w,
       CURRENT_SECONDARY_ROLES() AS sr;

-- ============================================================
-- CELL 15: variant=BASELINE q=Q3 role=ADMIN
-- ============================================================
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;

-- Suspend WH to clear local cache (tolerant of 'already suspended')
EXECUTE IMMEDIATE $$
BEGIN
    ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
    RETURN 'suspended';
EXCEPTION
    WHEN OTHER THEN RETURN 'already suspended (ok)';
END;
$$;

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_SM_WH;

EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER DEFAULT 10;
    i INTEGER DEFAULT 1;
    base_tag STRING DEFAULT 'mtax|phase=p2|variant=BASELINE|q=Q3|role=ADMIN';
    rep_tag STRING;
BEGIN
    WHILE (i <= n) DO
        rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
        EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A WHERE FANGRAPH_EMAIL = ''NEVER_MATCH_FOR_MTAX_TEST@example.com''';
        i := i + 1;
    END WHILE;
    RETURN 'cell 15 done';
END;
$$;
    -- ============================================================
    -- CELL 16: variant=P_NULL q=Q3 role=ADMIN
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_NULL_20260610A;

    -- Suspend WH to clear local cache (tolerant of 'already suspended')
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE ACCOUNTADMIN;
    USE WAREHOUSE FDE_DEVELOPER_SM_WH;

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT 10;
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_NULL|q=Q3|role=ADMIN';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A WHERE FANGRAPH_EMAIL = ''NEVER_MATCH_FOR_MTAX_TEST@example.com''';
            i := i + 1;
        END WHILE;
        RETURN 'cell 16 done';
    END;
    $$;
    -- ============================================================
    -- CELL 17: variant=P_HASH q=Q3 role=ADMIN
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_20260610A;

    -- Suspend WH to clear local cache (tolerant of 'already suspended')
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE ACCOUNTADMIN;
    USE WAREHOUSE FDE_DEVELOPER_SM_WH;

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT 10;
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_HASH|q=Q3|role=ADMIN';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A WHERE FANGRAPH_EMAIL = ''NEVER_MATCH_FOR_MTAX_TEST@example.com''';
            i := i + 1;
        END WHILE;
        RETURN 'cell 17 done';
    END;
    $$;
    -- ============================================================
    -- CELL 18: variant=P_COND q=Q3 role=READER
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_20260610A;

    -- Suspend WH to clear local cache (tolerant of 'already suspended')
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE TEST_PII_READER_20260610A;
    USE WAREHOUSE FDE_DEVELOPER_SM_WH;

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT 10;
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_COND|q=Q3|role=READER';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A WHERE FANGRAPH_EMAIL = ''NEVER_MATCH_FOR_MTAX_TEST@example.com''';
            i := i + 1;
        END WHILE;
        RETURN 'cell 18 done';
    END;
    $$;
    -- ============================================================
    -- CELL 19: variant=P_COND q=Q3 role=EXCLUDED
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_20260610A;

    -- Suspend WH to clear local cache (tolerant of 'already suspended')
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE TEST_PII_EXCLUDED_20260610A;
    USE WAREHOUSE FDE_DEVELOPER_SM_WH;

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT 10;
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_COND|q=Q3|role=EXCLUDED';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A WHERE FANGRAPH_EMAIL = ''NEVER_MATCH_FOR_MTAX_TEST@example.com''';
            i := i + 1;
        END WHILE;
        RETURN 'cell 19 done';
    END;
    $$;
    -- ============================================================
    -- CELL 20: variant=P_COND_ISR q=Q3 role=READER
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_ISR_20260610A;

    -- Suspend WH to clear local cache (tolerant of 'already suspended')
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE TEST_PII_READER_20260610A;
    USE WAREHOUSE FDE_DEVELOPER_SM_WH;

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT 10;
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_COND_ISR|q=Q3|role=READER';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A WHERE FANGRAPH_EMAIL = ''NEVER_MATCH_FOR_MTAX_TEST@example.com''';
            i := i + 1;
        END WHILE;
        RETURN 'cell 20 done';
    END;
    $$;
    -- ============================================================
    -- CELL 21: variant=P_COND_ISR q=Q3 role=EXCLUDED
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_ISR_20260610A;

    -- Suspend WH to clear local cache (tolerant of 'already suspended')
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE TEST_PII_EXCLUDED_20260610A;
    USE WAREHOUSE FDE_DEVELOPER_SM_WH;

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT 10;
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_COND_ISR|q=Q3|role=EXCLUDED';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A WHERE FANGRAPH_EMAIL = ''NEVER_MATCH_FOR_MTAX_TEST@example.com''';
            i := i + 1;
        END WHILE;
        RETURN 'cell 21 done';
    END;
    $$;
-- ============================================================
-- CELL 22: variant=BASELINE q=Q4 role=ADMIN
-- ============================================================
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;

-- Suspend WH to clear local cache (tolerant of 'already suspended')
EXECUTE IMMEDIATE $$
BEGIN
    ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
    RETURN 'suspended';
EXCEPTION
    WHEN OTHER THEN RETURN 'already suspended (ok)';
END;
$$;

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_SM_WH;

EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER DEFAULT 10;
    i INTEGER DEFAULT 1;
    base_tag STRING DEFAULT 'mtax|phase=p2|variant=BASELINE|q=Q4|role=ADMIN';
    rep_tag STRING;
BEGIN
    WHILE (i <= n) DO
        rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
        EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
        EXECUTE IMMEDIATE 'SELECT MAX(LENGTH(FANGRAPH_STATE)) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A';
        i := i + 1;
    END WHILE;
    RETURN 'cell 22 done';
END;
$$;
-- ============================================================
-- CELL 23: variant=BASELINE_4COL q=Q_MC role=ADMIN
-- ============================================================
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_FIRST_NAME UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_LAST_NAME UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_ADDRESS_1 UNSET MASKING POLICY;
EXECUTE IMMEDIATE $$
BEGIN
    ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
    RETURN 'suspended';
EXCEPTION
    WHEN OTHER THEN RETURN 'already suspended (ok)';
END;
$$;

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_SM_WH;

EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER DEFAULT 10;
    i INTEGER DEFAULT 1;
    base_tag STRING DEFAULT 'mtax|phase=p2|variant=BASELINE_4COL|q=Q_MC|role=ADMIN';
    rep_tag STRING;
BEGIN
    WHILE (i <= n) DO
        rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
        EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
        EXECUTE IMMEDIATE 'SELECT MAX(LENGTH(FANGRAPH_EMAIL)), MAX(LENGTH(FANGRAPH_FIRST_NAME)), MAX(LENGTH(FANGRAPH_LAST_NAME)), MAX(LENGTH(FANGRAPH_ADDRESS_1)) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A';
        i := i + 1;
    END WHILE;
    RETURN 'cell 23 done';
END;
$$;
-- ============================================================
-- CELL 24: variant=P_HASH_4COL q=Q_MC role=ADMIN
-- ============================================================
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_20260610A;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_FIRST_NAME SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_20260610A;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_LAST_NAME SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_20260610A;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_ADDRESS_1 SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_20260610A;
EXECUTE IMMEDIATE $$
BEGIN
    ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SUSPEND;
    RETURN 'suspended';
EXCEPTION
    WHEN OTHER THEN RETURN 'already suspended (ok)';
END;
$$;

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_SM_WH;

EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER DEFAULT 10;
    i INTEGER DEFAULT 1;
    base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_HASH_4COL|q=Q_MC|role=ADMIN';
    rep_tag STRING;
BEGIN
    WHILE (i <= n) DO
        rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
        EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
        EXECUTE IMMEDIATE 'SELECT MAX(LENGTH(FANGRAPH_EMAIL)), MAX(LENGTH(FANGRAPH_FIRST_NAME)), MAX(LENGTH(FANGRAPH_LAST_NAME)), MAX(LENGTH(FANGRAPH_ADDRESS_1)) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A';
        i := i + 1;
    END WHILE;
    RETURN 'cell 24 done';
END;
$$;
-- Detach MC policies before cleanup
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_FIRST_NAME UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_LAST_NAME UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_ADDRESS_1 UNSET MASKING POLICY;

-- ============================================================
-- POST-RUN: detach any remaining policy, unset query tag
-- ============================================================
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A MODIFY COLUMN FANGRAPH_EMAIL UNSET MASKING POLICY;
ALTER SESSION UNSET QUERY_TAG;

-- Results pull happens in a separate script (run_20260610a_phase2_results.sql)
-- so we can re-pull without re-running the matrix.
SELECT 'phase 2 matrix complete' AS status;

