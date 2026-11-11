-- Dev pre-walkthrough grants + ownership — unblock Phase 3 §3.3
--
-- Distinct from sql/cutover_ownership_transfer.sql:
--   The prod script SHOW-scans by owner (`owner = SVC_MWAA_ROLE`). In dev,
--   the tables we need to hand to SVC_DBT_CLOUD_ROLE are owned by various
--   admin roles (ACCOUNTADMIN, per-team admins, or historical roles) — not
--   by SVC_MWAA_ROLE. A straight clone of the prod script finds nothing.
--
--   This script iterates a HARDCODED classification list (from
--   coupling-test-plan.md §Test 9) and transfers ownership regardless of
--   current owner, existence-guarded. If a table doesn't yet exist in dev
--   (dbt will CREATE it on first run), the SQL fails with "does not exist"
--   and is logged as ERROR — the follow-up CREATE grant on the schema
--   handles that case.
--
-- Scope:
--   - 55 dbt-materialized dev targets → OWNERSHIP to SVC_DBT_CLOUD_ROLE
--   - ~37 ingested _EXT / _RAW / landing tables → SELECT to SVC_DBT_CLOUD_ROLE
--   - 5 dev DBs → USAGE
--   - 12 dev schemas → USAGE + CREATE TABLE + CREATE VIEW
--
-- Never touches:
--   - Prod DBs (that's the cutover script)
--   - Ingested tables' ownership (would break MWAA writes — user rule 2026-07-19)
--   - AAIA_CORTEX_DEV (does not exist per prior dry-run)
--
-- When to run:
--   Before Phase 3 §3.3 dev-MWAA walkthrough. Idempotent.
--
-- How to run (dry-run first):
--   snow sql -c FAN_DATA_EXCHANGE_PROD \
--     -f projects/dbt_cloud_migration/sql/dev_pre_walkthrough_grants_and_ownership.sql \
--     --enable-templating NONE
--
--   (Same Snowflake account VYB11067 holds both prod and _DEV DBs; there is
--   no separate _DEV connection.)
--
--   Review OWNERSHIP_TRANSFER_LOG rows with status='DRY_RUN'. Then flip
--   `is_dry_run := FALSE` and re-run.
--
-- Rollback:
--   Same-shape script pointing back to SVC_MWAA_ROLE (or whichever role
--   owned each object before). Given dev owners are heterogeneous, rollback
--   would need per-row previous_owner from OWNERSHIP_TRANSFER_LOG. Prefer
--   forward-fix over rollback in dev.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_MWAA_3XL_WH;  -- 3XL; matches other admin scripts in this workspace

CREATE SCHEMA IF NOT EXISTS FES_USERS.DBT_CLOUD_MIGRATION;
USE SCHEMA FES_USERS.DBT_CLOUD_MIGRATION;

-- Reuse OWNERSHIP_TRANSFER_LOG from cutover script (same DDL). Statuses added:
--   USAGE_GRANTED     — DB or schema USAGE succeeded
--   SCHEMA_GRANTED    — schema USAGE + CREATE TABLE + CREATE VIEW succeeded
--   SELECT_GRANTED    — SELECT on ingested source succeeded
--   SUCCESS           — OWNERSHIP transfer on materialized target succeeded
--   DRY_RUN           — is_dry_run=TRUE; logged but not executed
--   ERROR             — statement failed; error_message captured
CREATE TABLE IF NOT EXISTS FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG (
    run_id           VARCHAR,
    transfer_id      BIGINT AUTOINCREMENT,
    transferred_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP,
    database_name    VARCHAR,
    schema_name      VARCHAR,
    object_name      VARCHAR,
    object_type      VARCHAR,
    previous_owner   VARCHAR,
    new_owner        VARCHAR,
    grant_statement  VARCHAR,
    status           VARCHAR,
    error_message    VARCHAR
);

EXECUTE IMMEDIATE $$
DECLARE
    -- CONFIG: TRUE = log only, no GRANTs. Flip to FALSE for real execution.
    is_dry_run BOOLEAN := TRUE;

    role_name VARCHAR := 'SVC_DBT_CLOUD_ROLE';
    run_id    VARCHAR := UUID_STRING();

    -- Databases: USAGE only. Dedup of every DB appearing below.
    dbs ARRAY := ARRAY_CONSTRUCT(
        'MDE_DEV',
        'FES_INTEGRATIONS_DEV',
        'IDENTITY_DEV',
        'LOYALTY_DEV',
        'XP_DEV'
    );

    -- Schemas: USAGE + CREATE TABLE + CREATE VIEW. Every schema that holds
    -- a dbt-materialized target (so dbt Cloud can CREATE net-new tables).
    schemas ARRAY := ARRAY_CONSTRUCT(
        'MDE_DEV.MDE_INFO',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS',
        'FES_INTEGRATIONS_DEV.IMPACT',
        'FES_INTEGRATIONS_DEV.MAGNITE',
        'FES_INTEGRATIONS_DEV.SALESFORCE',
        'IDENTITY_DEV.UNIFIED_PROFILE',
        'IDENTITY_DEV.ORCHESTRATION',
        'IDENTITY_DEV.IDENTITY__SOURCE',
        'LOYALTY_DEV.SOURCE',
        'LOYALTY_DEV.ONE_CREDITS',
        'XP_DEV.STAGE',
        'XP_DEV.XP'
    );

    -- dbt-materialized dev targets. OWNERSHIP transfer. Format: <fqn>::<obj_type>.
    -- Count: 55 (matches coupling-test-plan.md §Test 9; fesloyalty doc claims
    -- 22 incremental but lists 21 — TBD, add missing one if §3.3 surfaces it).
    materialized ARRAY := ARRAY_CONSTRUCT(
        -- mdm_sdp (3 table)
        'MDE_DEV.MDE_INFO.MDM_TO_SDP_LEAGUES::TABLE',
        'MDE_DEV.MDE_INFO.MDM_TO_SDP_PLAYERS::TABLE',
        'MDE_DEV.MDE_INFO.MDM_TO_SDP_TEAMS::TABLE',
        -- google_ad_manager (9 incremental)
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_ADVERTISER_SPEND_SUMMARY::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_DAILY_FILLED::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_EXECUTIVE_REVENUE_SUMMARY::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_FILL_RATE_BY_AD_UNIT::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_INVENTORY_FILL_RATE_BY_AD_UNIT::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_INVENTORY_SELL_THROUGH_FORECASTING::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_LINE_ITEM_PACING_DELIVERY::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_UNIFIED_IMPRESSIONS_ANALYSIS::TABLE',
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_VIEWABILITY_BY_PLACEMENT::TABLE',
        -- identity (3 table + 2 incremental)
        'IDENTITY_DEV.UNIFIED_PROFILE.PREFERENCES::TABLE',
        'IDENTITY_DEV.UNIFIED_PROFILE.FAVORITES::TABLE',
        'IDENTITY_DEV.UNIFIED_PROFILE.CORE::TABLE',
        'IDENTITY_DEV.ORCHESTRATION.LOYALTY_PRIVATE_FAN_ID_MAP::TABLE',
        'IDENTITY_DEV.ORCHESTRATION.MARTECH_PRIVATE_FAN_ID_MAP::TABLE',
        -- impact (1 incremental)
        'FES_INTEGRATIONS_DEV.IMPACT.TICKETMASTER_ORDER_LISTING::TABLE',
        -- fesbonus (8 incremental)
        'LOYALTY_DEV.SOURCE.BONUS::TABLE',
        'LOYALTY_DEV.SOURCE.BONUS_REWARD::TABLE',
        'LOYALTY_DEV.SOURCE.BONUS_STEP::TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS::TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS_REWARD::TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS_STEP::TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS_STEP_EVENT::TABLE',
        'LOYALTY_DEV.SOURCE.USER_EVENT::TABLE',
        -- fesloyalty (21 incremental — doc says 22, off-by-one flagged;
        -- ephemeral `journal_normalized` has no target, no ownership needed)
        'LOYALTY_DEV.SOURCE.ACCOUNT_BALANCE::TABLE',
        'LOYALTY_DEV.SOURCE.ALLOCATION::TABLE',
        'LOYALTY_DEV.SOURCE.ALLOCATION_REMAINING::TABLE',
        'LOYALTY_DEV.SOURCE.AUTH_BUCKET_HOLD::TABLE',
        'LOYALTY_DEV.SOURCE.AUTH_HOLD::TABLE',
        'LOYALTY_DEV.SOURCE.BUCKET::TABLE',
        'LOYALTY_DEV.SOURCE.BUCKET_TYPE::TABLE',
        'LOYALTY_DEV.SOURCE.CAPTURE_EVENT::TABLE',
        'LOYALTY_DEV.SOURCE.ENTRY::TABLE',
        'LOYALTY_DEV.SOURCE.IDEMPOTENCY_KEYS::TABLE',
        'LOYALTY_DEV.SOURCE.JOURNAL::TABLE',
        'LOYALTY_DEV.SOURCE.LOYALTY_ACCOUNT::TABLE',
        'LOYALTY_DEV.SOURCE.OPCO_PROGRAM_ACCOUNT::TABLE',
        'LOYALTY_DEV.SOURCE.OPERATING_COMPANY::TABLE',
        'LOYALTY_DEV.SOURCE.PROGRAM::TABLE',
        'LOYALTY_DEV.SOURCE.PROGRAM_ACCOUNT_BALANCE::TABLE',
        'LOYALTY_DEV.SOURCE.SYSTEM_LOYALTY_ACCOUNT::TABLE',
        'LOYALTY_DEV.SOURCE.TRANSACTION::TABLE',
        'LOYALTY_DEV.SOURCE.TRANSFER_RESTRICTION::TABLE',
        'LOYALTY_DEV.SOURCE.VOID_AUTH_EVENT::TABLE',
        'LOYALTY_DEV.SOURCE.VOID_REMAINING::TABLE',
        -- fesloyalty ONE_CREDITS layer (1 table + 2 views)
        'LOYALTY_DEV.ONE_CREDITS.ONE_CREDITS_LOYALTY_ANALYTICS_LEDGER::TABLE',
        'LOYALTY_DEV.ONE_CREDITS.ONE_CREDITS_LOYALTY_ANALYTICS_LEDGER_FBG::VIEW',
        'LOYALTY_DEV.ONE_CREDITS.ONE_CREDITS_LOYALTY_ANALYTICS_LEDGER_NO_AUTH::VIEW',
        -- magnite (1 incremental)
        'FES_INTEGRATIONS_DEV.MAGNITE.MAGNITE_PA_HOURLY::TABLE',
        -- optin_preferences (2 stage table + 2 stage incremental + 2 xp incremental)
        'XP_DEV.STAGE.XP_OPTIN_PREFERENCES::TABLE',
        'XP_DEV.STAGE.XP_PUSH_LAST_OPENED::TABLE',
        'XP_DEV.STAGE.XP_OPTIN_PREFERENCES_SNAPSHOT::TABLE',
        'XP_DEV.STAGE.XP_PUSH_LAST_OPENED_SNAPSHOT::TABLE',
        'XP_DEV.XP.XP_OPTIN_PREFERENCES_DELTA::TABLE',
        'XP_DEV.XP.XP_PUSH_LAST_OPENED_DELTA::TABLE'
    );

    -- Ingested sources (~37): SELECT only. Format: <fqn>::<obj_type>.
    -- Never OWNERSHIP — MWAA-side ingest writes to these; transferring
    -- ownership breaks the pipeline (user rule 2026-07-19).
    sources ARRAY := ARRAY_CONSTRUCT(
        -- google_ad_manager (1)
        'FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_REPORT_RAW_EXT::EXTERNAL TABLE',
        -- identity (4 Cassandra→S3→external)
        'IDENTITY_DEV.IDENTITY__SOURCE.PREFERENCES_EXT::EXTERNAL TABLE',
        'IDENTITY_DEV.IDENTITY__SOURCE.FAVORITES_EXT::EXTERNAL TABLE',
        'IDENTITY_DEV.IDENTITY__SOURCE.LOYALTY_PRIVATE_FAN_ID_MAP_EXT::EXTERNAL TABLE',
        'IDENTITY_DEV.IDENTITY__SOURCE.MARTECH_PRIVATE_FAN_ID_MAP_EXT::EXTERNAL TABLE',
        -- impact (1 API-CSV COPY landing — regular TABLE, not external)
        'FES_INTEGRATIONS_DEV.IMPACT.TICKETMASTER_ORDER_LISTING_RAW::TABLE',
        -- fesbonus (8 SqlToS3 external)
        'LOYALTY_DEV.SOURCE.BONUS_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.BONUS_REWARD_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.BONUS_STEP_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS_REWARD_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS_STEP_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.USER_BONUS_STEP_EVENT_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.USER_EVENT_EXT::EXTERNAL TABLE',
        -- fesloyalty (21 SqlToS3 external)
        'LOYALTY_DEV.SOURCE.ACCOUNT_BALANCE_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.ALLOCATION_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.ALLOCATION_REMAINING_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.AUTH_BUCKET_HOLD_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.AUTH_HOLD_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.BUCKET_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.BUCKET_TYPE_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.CAPTURE_EVENT_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.ENTRY_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.IDEMPOTENCY_KEYS_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.JOURNAL_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.LOYALTY_ACCOUNT_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.OPCO_PROGRAM_ACCOUNT_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.OPERATING_COMPANY_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.PROGRAM_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.PROGRAM_ACCOUNT_BALANCE_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.SYSTEM_LOYALTY_ACCOUNT_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.TRANSACTION_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.TRANSFER_RESTRICTION_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.VOID_AUTH_EVENT_EXT::EXTERNAL TABLE',
        'LOYALTY_DEV.SOURCE.VOID_REMAINING_EXT::EXTERNAL TABLE',
        -- magnite (1 S3 auto-refresh external)
        'FES_INTEGRATIONS_DEV.MAGNITE.MAGNITE_PA_HOURLY_EXT::EXTERNAL TABLE',
        -- optin_preferences (1 SFMC SFTP COPY landing — regular TABLE)
        'FES_INTEGRATIONS_DEV.SALESFORCE.OPTIN_AND_PREFERENCES::TABLE'
    );

    n           INTEGER;
    entry_str   VARCHAR;
    fqn         VARCHAR;
    obj_type    VARCHAR;
    stmt        VARCHAR;
    parsed_db   VARCHAR;
    parsed_sch  VARCHAR;
    parsed_obj  VARCHAR;
BEGIN
    -- ---------------------------------------------------------------
    -- Section A: USAGE on databases
    -- ---------------------------------------------------------------
    n := ARRAY_SIZE(dbs);
    FOR i IN 0 TO n - 1 DO
        parsed_db := dbs[i]::VARCHAR;
        stmt := 'GRANT USAGE ON DATABASE ' || parsed_db
             || ' TO ROLE ' || role_name;

        IF (is_dry_run) THEN
            INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                (run_id, database_name, object_type, new_owner,
                 grant_statement, status)
            VALUES
                (:run_id, :parsed_db, 'DATABASE', :role_name,
                 :stmt, 'DRY_RUN');
        ELSE
            BEGIN
                EXECUTE IMMEDIATE :stmt;
                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                    (run_id, database_name, object_type, new_owner,
                     grant_statement, status)
                VALUES
                    (:run_id, :parsed_db, 'DATABASE', :role_name,
                     :stmt, 'USAGE_GRANTED');
            EXCEPTION
                WHEN OTHER THEN
                    INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                        (run_id, database_name, object_type, new_owner,
                         grant_statement, status, error_message)
                    VALUES
                        (:run_id, :parsed_db, 'DATABASE', :role_name,
                         :stmt, 'ERROR', :SQLERRM);
            END;
        END IF;
    END FOR;

    -- ---------------------------------------------------------------
    -- Section B: USAGE + CREATE TABLE + CREATE VIEW on schemas
    -- (so dbt Cloud can materialize net-new tables that don't yet exist in dev)
    -- ---------------------------------------------------------------
    n := ARRAY_SIZE(schemas);
    FOR i IN 0 TO n - 1 DO
        entry_str  := schemas[i]::VARCHAR;
        parsed_db  := SPLIT_PART(entry_str, '.', 1);
        parsed_sch := SPLIT_PART(entry_str, '.', 2);
        stmt := 'GRANT USAGE, CREATE TABLE, CREATE VIEW ON SCHEMA '
             || entry_str || ' TO ROLE ' || role_name;

        IF (is_dry_run) THEN
            INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                (run_id, database_name, schema_name, object_type, new_owner,
                 grant_statement, status)
            VALUES
                (:run_id, :parsed_db, :parsed_sch, 'SCHEMA', :role_name,
                 :stmt, 'DRY_RUN');
        ELSE
            BEGIN
                EXECUTE IMMEDIATE :stmt;
                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                    (run_id, database_name, schema_name, object_type, new_owner,
                     grant_statement, status)
                VALUES
                    (:run_id, :parsed_db, :parsed_sch, 'SCHEMA', :role_name,
                     :stmt, 'SCHEMA_GRANTED');
            EXCEPTION
                WHEN OTHER THEN
                    INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                        (run_id, database_name, schema_name, object_type, new_owner,
                         grant_statement, status, error_message)
                    VALUES
                        (:run_id, :parsed_db, :parsed_sch, 'SCHEMA', :role_name,
                         :stmt, 'ERROR', :SQLERRM);
            END;
        END IF;
    END FOR;

    -- ---------------------------------------------------------------
    -- Section C: OWNERSHIP transfer on 55 dbt-materialized dev targets
    -- (per-object, existence-guarded; missing objects log ERROR and are
    -- covered by the schema-level CREATE grant in Section B)
    -- ---------------------------------------------------------------
    n := ARRAY_SIZE(materialized);
    FOR i IN 0 TO n - 1 DO
        entry_str  := materialized[i]::VARCHAR;
        fqn        := SPLIT_PART(entry_str, '::', 1);
        obj_type   := SPLIT_PART(entry_str, '::', 2);
        parsed_db  := SPLIT_PART(fqn, '.', 1);
        parsed_sch := SPLIT_PART(fqn, '.', 2);
        parsed_obj := SPLIT_PART(fqn, '.', 3);
        stmt := 'GRANT OWNERSHIP ON ' || obj_type || ' ' || fqn
             || ' TO ROLE ' || role_name || ' COPY CURRENT GRANTS';

        IF (is_dry_run) THEN
            INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                (run_id, database_name, schema_name, object_name, object_type,
                 new_owner, grant_statement, status)
            VALUES
                (:run_id, :parsed_db, :parsed_sch, :parsed_obj, :obj_type,
                 :role_name, :stmt, 'DRY_RUN');
        ELSE
            BEGIN
                EXECUTE IMMEDIATE :stmt;
                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                    (run_id, database_name, schema_name, object_name, object_type,
                     new_owner, grant_statement, status)
                VALUES
                    (:run_id, :parsed_db, :parsed_sch, :parsed_obj, :obj_type,
                     :role_name, :stmt, 'SUCCESS');
            EXCEPTION
                WHEN OTHER THEN
                    INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                        (run_id, database_name, schema_name, object_name, object_type,
                         new_owner, grant_statement, status, error_message)
                    VALUES
                        (:run_id, :parsed_db, :parsed_sch, :parsed_obj, :obj_type,
                         :role_name, :stmt, 'ERROR', :SQLERRM);
            END;
        END IF;
    END FOR;

    -- ---------------------------------------------------------------
    -- Section D: SELECT on 37 ingested sources
    -- (belt-and-suspenders; TF `dbt-cloud-grants-full-scope` is the durable
    -- source. Idempotent — re-grants are no-ops.)
    -- ---------------------------------------------------------------
    n := ARRAY_SIZE(sources);
    FOR i IN 0 TO n - 1 DO
        entry_str  := sources[i]::VARCHAR;
        fqn        := SPLIT_PART(entry_str, '::', 1);
        obj_type   := SPLIT_PART(entry_str, '::', 2);
        parsed_db  := SPLIT_PART(fqn, '.', 1);
        parsed_sch := SPLIT_PART(fqn, '.', 2);
        parsed_obj := SPLIT_PART(fqn, '.', 3);
        stmt := 'GRANT SELECT ON ' || obj_type || ' ' || fqn
             || ' TO ROLE ' || role_name;

        IF (is_dry_run) THEN
            INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                (run_id, database_name, schema_name, object_name, object_type,
                 new_owner, grant_statement, status)
            VALUES
                (:run_id, :parsed_db, :parsed_sch, :parsed_obj, :obj_type,
                 :role_name, :stmt, 'DRY_RUN');
        ELSE
            BEGIN
                EXECUTE IMMEDIATE :stmt;
                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                    (run_id, database_name, schema_name, object_name, object_type,
                     new_owner, grant_statement, status)
                VALUES
                    (:run_id, :parsed_db, :parsed_sch, :parsed_obj, :obj_type,
                     :role_name, :stmt, 'SELECT_GRANTED');
            EXCEPTION
                WHEN OTHER THEN
                    INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                        (run_id, database_name, schema_name, object_name, object_type,
                         new_owner, grant_statement, status, error_message)
                    VALUES
                        (:run_id, :parsed_db, :parsed_sch, :parsed_obj, :obj_type,
                         :role_name, :stmt, 'ERROR', :SQLERRM);
            END;
        END IF;
    END FOR;

    RETURN 'Done. run_id=' || :run_id
        || '  (dbs=' || ARRAY_SIZE(dbs)
        || ', schemas=' || ARRAY_SIZE(schemas)
        || ', materialized=' || ARRAY_SIZE(materialized)
        || ', sources=' || ARRAY_SIZE(sources) || ')';
END;
$$;

-- ---------------------------------------------------------------------------
-- Post-run summary: counts by status × object_type for the most recent run
-- ---------------------------------------------------------------------------
WITH latest AS (
    SELECT run_id
    FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
    ORDER BY transfer_id DESC
    LIMIT 1
)
SELECT
    l.status,
    l.object_type,
    COUNT(*) AS n
FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG l
JOIN latest ON l.run_id = latest.run_id
GROUP BY l.status, l.object_type
ORDER BY l.status, l.object_type;

-- Errors + missing objects for triage
WITH latest AS (
    SELECT run_id
    FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
    ORDER BY transfer_id DESC
    LIMIT 1
)
SELECT
    l.database_name, l.schema_name, l.object_name, l.object_type,
    l.grant_statement, l.error_message
FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG l
JOIN latest ON l.run_id = latest.run_id
WHERE l.status = 'ERROR'
ORDER BY l.database_name, l.schema_name, l.object_name;
