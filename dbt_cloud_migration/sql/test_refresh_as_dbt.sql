-- ============================================================================
-- Validate EVERY refresh pre-hook in dbt-fes-ae #45 runs cleanly as the DBT
-- service user — with NO admin masking (you are ACCOUNTADMIN in the UI).
--
-- dbt Cloud runs: primary = SVC_DBT_CLOUD_ROLE, DEFAULT_SECONDARY_ROLES = ALL
-- (which includes AR_FES_EXT_TABLE_OWNER).
--
-- Two object types, two ownership situations:
--   * ICEBERG tables  -> owned by SVC_DBT_CLOUD_ROLE   -> primary role refreshes
--   * EXTERNAL tables -> owned by AR_FES_EXT_TABLE_OWNER -> AR (secondary) refreshes
-- So each part activates exactly the role dbt would use, nothing more.
-- Every ALTER below MUST succeed. A failure = dbt would fail on that pre-hook.
-- ============================================================================

USE ROLE SVC_DBT_CLOUD_ROLE;
USE WAREHOUSE FDE_DBT_CLOUD_WH;

-- ----------------------------------------------------------------------------
-- PART 1 — ICEBERG (10). dbt-owned, so primary role alone must work.
-- SECONDARY ROLES NONE strips everything (incl. your admin) so nothing masks it.
-- ----------------------------------------------------------------------------
USE SECONDARY ROLES NONE;

ALTER ICEBERG TABLE COMMERCE.SOURCE.WEEKLY_TRADING_ICEBERG               REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.FANAPP_WEEKLY_TRADING_ICEBERG        REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.FANAPP_DAILY_PRODUCTS_ICEBERG        REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.UNIFIED_SEND_LOG_ICEBERG            REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.SES_OPENS_ICEBERG                   REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.SES_CLICKS_ICEBERG                  REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.ADOBE_OPENS_ICEBERG                 REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.ADOBE_CLICKS_ICEBERG                REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.EXP_PROD_FANKEY_MAP_ICEBERG         REFRESH;
ALTER ICEBERG TABLE COMMERCE.SOURCE.EXP_PROD_FILTERED_PAGE_VIEW_ICEBERG REFRESH;

-- ----------------------------------------------------------------------------
-- PART 2 — EXTERNAL (14). AR_FES_EXT_TABLE_OWNER-owned, so dbt refreshes via its
-- AR *secondary* role. Activate ONLY AR as secondary — this mimics dbt exactly
-- and avoids re-activating your admin roles (which USE SECONDARY ROLES ALL would).
-- If your account rejects a named secondary role, fall back to
--   USE SECONDARY ROLES ALL;
-- but know that then your admin roles are also active, so a pass is less conclusive.
-- ----------------------------------------------------------------------------
USE SECONDARY ROLES AR_FES_EXT_TABLE_OWNER;

ALTER EXTERNAL TABLE LOYALTY.SOURCE.BONUS_EXT                       REFRESH;
ALTER EXTERNAL TABLE LOYALTY.SOURCE.BONUS_REWARD_EXT                REFRESH;
ALTER EXTERNAL TABLE LOYALTY.SOURCE.BONUS_STEP_EXT                  REFRESH;
ALTER EXTERNAL TABLE LOYALTY.SOURCE.USER_BONUS_EXT                  REFRESH;
ALTER EXTERNAL TABLE LOYALTY.SOURCE.USER_BONUS_REWARD_EXT           REFRESH;
ALTER EXTERNAL TABLE LOYALTY.SOURCE.USER_BONUS_STEP_EVENT_EXT       REFRESH;
ALTER EXTERNAL TABLE LOYALTY.SOURCE.USER_BONUS_STEP_EXT             REFRESH;
ALTER EXTERNAL TABLE LOYALTY.SOURCE.USER_EVENT_EXT                  REFRESH;
ALTER EXTERNAL TABLE IDENTITY.SOURCE.CORE_EXT                       REFRESH;
ALTER EXTERNAL TABLE IDENTITY.SOURCE.FAVORITES_EXT                  REFRESH;
ALTER EXTERNAL TABLE IDENTITY.SOURCE.PREFERENCES_EXT                REFRESH;
ALTER EXTERNAL TABLE IDENTITY.SOURCE.LOYALTY_PRIVATE_FAN_ID_MAP_EXT REFRESH;
ALTER EXTERNAL TABLE IDENTITY.SOURCE.MARTECH_PRIVATE_FAN_ID_MAP_EXT REFRESH;
ALTER EXTERNAL TABLE XP.SOURCE.CAMPAIGN_ENGAGEMENT_EXT              REFRESH;

-- ----------------------------------------------------------------------------
-- reset your session
-- ----------------------------------------------------------------------------
USE SECONDARY ROLES ALL;
USE ROLE ACCOUNTADMIN;
-- All 24 succeeded as the dbt role -> every pre-hook in #45 is safe.
