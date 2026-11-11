-- ============================================================
-- PHASE 5 SETUP: clone fangraph + grants for imprint-style query
-- on SMALL warehouse
-- ============================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_SM_WH;
ALTER WAREHOUSE FDE_DEVELOPER_SM_WH SET WAREHOUSE_SIZE = 'SMALL';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;

-- Zero-copy clone of fangraph (the final 190M-row table, what consumer queries actually hit)
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.MTAX_IMP_FG_20260611A
    CLONE FANGRAPH.ADMIN.FANGRAPH;

-- Test roles already exist from Phase 3 redo setup (TEST_PII_READER_20260611A)
-- Grant SM warehouse + table access
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_SM_WH                          TO ROLE TEST_PII_READER_20260611A;
GRANT SELECT ON FES_USERS.ALEX_SOTIS.MTAX_IMP_FG_20260611A            TO ROLE TEST_PII_READER_20260611A;
-- CREATE TABLE was granted in Phase 3 redo setup; idempotent re-grant
GRANT CREATE TABLE ON SCHEMA FES_USERS.ALEX_SOTIS                     TO ROLE TEST_PII_READER_20260611A;

SELECT 'p5 setup ok' AS status,
       (SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_IMP_FG_20260611A) AS fg_rows;
