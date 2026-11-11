-- Sample tables for the 10x tier points investigation, scoped to the 2 known-affected fans.
-- CREATE TABLE is on Brock's deny list (auto-execution blocked), so run these yourself:
--   ! snow sql -c FAN_DATA_EXCHANGE_PROD --warehouse FDE_DEVELOPER_2XL_WH -f projects/tier_points_10x_fix/sample_tables.sql
-- (or paste into a worksheet). They are cheap (a few thousand rows).

USE WAREHOUSE FDE_DEVELOPER_2XL_WH;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;

-- 1) Raw Salesforce CDC snapshots (status-match relevant columns) for the 2 fans.
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_OVERRIDES_V2_SAMPLE AS
SELECT *
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2
WHERE private_fan_id IN ('8ad58668-3371-4bc5-9369-0cbffd592bb1',
                         '7c25289f-9fc3-4839-8e7c-3e80464bf252');

-- 2) Flattened status-match intervals for the 2 fans (the table the ledger fix edits).
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_STATUS_MATCH_SAMPLE AS
SELECT *
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES__STATUS_MATCH
WHERE private_fan_id IN ('8ad58668-3371-4bc5-9369-0cbffd592bb1',
                         '7c25289f-9fc3-4839-8e7c-3e80464bf252');

-- 3) Ledger rows for the 2 fans (to inspect status_match_active / trial_earned vs target).
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP10X_LEDGER_V2_SAMPLE AS
SELECT *
FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2
WHERE private_fan_id IN ('8ad58668-3371-4bc5-9369-0cbffd592bb1',
                         '7c25289f-9fc3-4839-8e7c-3e80464bf252');
