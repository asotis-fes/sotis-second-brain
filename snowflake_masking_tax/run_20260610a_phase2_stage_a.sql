-- ============================================================
-- PHASE 2 - STAGE A: clone fangraph + gut-check timing on XS
-- ============================================================
-- Purpose: determine whether XS is fast enough for the full
-- Phase 2 matrix, or whether we need to size up to SMALL/MEDIUM.
-- Threshold: if Q2 baseline >60s on XS, size up before kicking
-- off the full matrix (per test_plan.md §6).
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_XS_WH;
ALTER WAREHOUSE FDE_DEVELOPER_XS_WH SET WAREHOUSE_SIZE = 'XSMALL';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;

-- Zero-copy clone (metadata only; should be near-instant)
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A
    CLONE FANGRAPH.ADMIN.FANGRAPH;

SELECT COUNT(*) AS row_count FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A;

-- Grant SELECT on clone to scratch roles (needed for cells under READER/EXCLUDED)
GRANT SELECT ON FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A TO ROLE TEST_PII_READER_20260610A;
GRANT SELECT ON FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A TO ROLE TEST_PII_EXCLUDED_20260610A;

-- Gut check: cold then warm timing of Q2 baseline on XS
ALTER WAREHOUSE FDE_DEVELOPER_XS_WH SUSPEND;
SELECT 1;  -- triggers resume

ALTER SESSION SET QUERY_TAG = 'mtax|phase=p2|gutcheck=cold';
SELECT COUNT(DISTINCT FANGRAPH_EMAIL) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A;

ALTER SESSION SET QUERY_TAG = 'mtax|phase=p2|gutcheck=warm';
SELECT COUNT(DISTINCT FANGRAPH_EMAIL) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_20260610A;

ALTER SESSION UNSET QUERY_TAG;
