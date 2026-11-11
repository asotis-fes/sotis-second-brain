-- Cutover ownership transfer — SVC_MWAA_ROLE -> SVC_DBT_CLOUD_ROLE
--
-- Dynamic, MWAA-owner-guarded. Only touches objects whose current owner is
-- SVC_MWAA_ROLE within the target databases below. Every attempt (success,
-- error, or dry-run) is logged to
-- FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG, tagged with a run_id
-- so cutover_rollback.sql can reverse exactly this run.
--
-- When to run:
--   Cutover moment (monday-cutover-plan.md step 10). Idempotent — a re-run
--   finds zero MWAA-owned objects (they're now DBT_CLOUD-owned) and does
--   nothing.
--
-- How to run:
--   snow sql -c <connection-name> -f projects/dbt_cloud_migration/sql/cutover_ownership_transfer.sql
--
-- Dry run: change `is_dry_run` in the DECLARE section to TRUE. Logs what
-- WOULD be transferred without executing GRANT OWNERSHIP.
--
-- Reversal:
--   projects/dbt_cloud_migration/sql/cutover_rollback.sql
--
-- Scope: TABLES, VIEWS, DYNAMIC TABLES, MATERIALIZED VIEWS across every
-- database dbt Cloud writes to at cutover. INFORMATION_SCHEMA is skipped.
-- FES_USERS is included and filtered by owner — engineer-owned personal
-- schemas are ignored automatically; only MWAA-owned objects created by the
-- deleted dbt_users DAG will transfer.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_WH;  -- Medium; admin ad-hoc workload

-- ---------------------------------------------------------------------------
-- 1. Setup: schema + log table
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS FES_USERS.DBT_CLOUD_MIGRATION;
USE SCHEMA FES_USERS.DBT_CLOUD_MIGRATION;  -- temp tables need a current DB

CREATE TABLE IF NOT EXISTS FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG (
    run_id           VARCHAR,
    transfer_id      BIGINT AUTOINCREMENT,
    transferred_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP,
    database_name    VARCHAR,
    schema_name      VARCHAR,
    object_name      VARCHAR,
    object_type      VARCHAR,          -- TABLE / VIEW / DYNAMIC TABLE / MATERIALIZED VIEW
    previous_owner   VARCHAR,
    new_owner        VARCHAR,
    grant_statement  VARCHAR,
    status           VARCHAR,          -- SUCCESS / ERROR / DRY_RUN / SHOW_FAILED
    error_message    VARCHAR
);

-- ---------------------------------------------------------------------------
-- 2. Discover MWAA-owned objects + transfer
-- ---------------------------------------------------------------------------

EXECUTE IMMEDIATE $$
DECLARE
    -- CONFIG: set to TRUE for a dry run (logs what WOULD transfer, no GRANTs).
    is_dry_run BOOLEAN := FALSE;

    -- Every DB dbt Cloud writes to at cutover, prod + dev. FES_USERS is
    -- included; per-engineer schemas are auto-filtered by owner so only
    -- MWAA-owned objects (from the deleted dbt_users DAG) transfer.
    target_dbs ARRAY := ARRAY_CONSTRUCT(
        'AAIA_CORTEX',        -- no AAIA_CORTEX_DEV (does not exist)
        'CDE',                'CDE_DEV',
        'COMMERCE',           'COMMERCE_DEV',
        'ENTERPRISE_METRICS', 'ENTERPRISE_METRICS_DEV',
        'FANAPP',             'FANAPP_DEV',
        'FANFLOW',            'FANFLOW_DEV',
        'FANGRAPH',           'FANGRAPH_DEV',
        'FDE',                'FDE_DEV',
        'FDE_COLLECTIBLES',   'FDE_COLLECTIBLES_DEV',
        'FDE_FBG',            'FDE_FBG_DEV',
        'FDE_FMX',            'FDE_FMX_DEV',
        'FDE_IMPRINT',        'FDE_IMPRINT_DEV',
        'FES_INTEGRATIONS',   'FES_INTEGRATIONS_DEV',
        'FES_USERS',
        'GROWTHLOOP',         'GROWTHLOOP_DEV',
        'IDENTITY',           'IDENTITY_DEV',
        'LOYALTY',            'LOYALTY_DEV',
        'MDE',                'MDE_DEV',
        'MONTEROSA',          'MONTEROSA_DEV',
        'SEEK_INSIGHTS',      'SEEK_INSIGHTS_DEV',
        'TREASURE_DATA',
        'XP',                 'XP_DEV'
    );

    -- SHOW keyword :: GRANT keyword pairs
    obj_kinds ARRAY := ARRAY_CONSTRUCT(
        'TABLES::TABLE',
        'VIEWS::VIEW',
        'DYNAMIC TABLES::DYNAMIC TABLE',
        'MATERIALIZED VIEWS::MATERIALIZED VIEW'
    );

    run_id      VARCHAR := UUID_STRING();
    db_count    INTEGER := ARRAY_SIZE(target_dbs);
    kind_count  INTEGER := ARRAY_SIZE(obj_kinds);
    db_name     VARCHAR;
    kind_pair   VARCHAR;
    show_kind   VARCHAR;
    grant_kind  VARCHAR;
    stmt        VARCHAR;
    fqn         VARCHAR;
    -- Cursor row fields copied into locals before use in INSERT VALUES
    -- (Snowflake Scripting binding namespace is scripting-vars only).
    this_db     VARCHAR;
    this_sch    VARCHAR;
    this_obj    VARCHAR;
BEGIN
    FOR i IN 0 TO db_count - 1 DO
        db_name := target_dbs[i]::VARCHAR;

        FOR j IN 0 TO kind_count - 1 DO
            kind_pair  := obj_kinds[j]::VARCHAR;
            show_kind  := SPLIT_PART(kind_pair, '::', 1);
            grant_kind := SPLIT_PART(kind_pair, '::', 2);

            BEGIN
                stmt := 'SHOW ' || show_kind || ' IN DATABASE ' || db_name;
                EXECUTE IMMEDIATE :stmt;

                -- Materialize SHOW output so subsequent EXECUTE IMMEDIATE calls
                -- inside the loop don't clobber RESULT_SCAN's query id.
                CREATE OR REPLACE TEMPORARY TABLE _show_scan AS
                SELECT
                    "database_name" AS db,
                    "schema_name"   AS sch,
                    "name"          AS obj
                FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
                WHERE "owner" = 'SVC_MWAA_ROLE'
                  AND "schema_name" <> 'INFORMATION_SCHEMA';

                LET cur CURSOR FOR SELECT db, sch, obj FROM _show_scan;

                FOR rec IN cur DO
                    this_db  := rec.db;
                    this_sch := rec.sch;
                    this_obj := rec.obj;
                    fqn  := this_db || '.' || this_sch || '.' || this_obj;
                    stmt := 'GRANT OWNERSHIP ON ' || :grant_kind || ' ' || fqn
                         || ' TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS';

                    IF (is_dry_run) THEN
                        INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                            (run_id, database_name, schema_name, object_name,
                             object_type, previous_owner, new_owner,
                             grant_statement, status)
                        VALUES
                            (:run_id, :this_db, :this_sch, :this_obj,
                             :grant_kind, 'SVC_MWAA_ROLE', 'SVC_DBT_CLOUD_ROLE',
                             :stmt, 'DRY_RUN');
                    ELSE
                        BEGIN
                            EXECUTE IMMEDIATE :stmt;
                            INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                                (run_id, database_name, schema_name, object_name,
                                 object_type, previous_owner, new_owner,
                                 grant_statement, status)
                            VALUES
                                (:run_id, :this_db, :this_sch, :this_obj,
                                 :grant_kind, 'SVC_MWAA_ROLE', 'SVC_DBT_CLOUD_ROLE',
                                 :stmt, 'SUCCESS');
                        EXCEPTION
                            WHEN OTHER THEN
                                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                                    (run_id, database_name, schema_name, object_name,
                                     object_type, previous_owner, new_owner,
                                     grant_statement, status, error_message)
                                VALUES
                                    (:run_id, :this_db, :this_sch, :this_obj,
                                     :grant_kind, 'SVC_MWAA_ROLE', 'SVC_DBT_CLOUD_ROLE',
                                     :stmt, 'ERROR', :SQLERRM);
                        END;
                    END IF;
                END FOR;
            EXCEPTION
                WHEN OTHER THEN
                    -- Database missing, insufficient visibility, or SHOW failed.
                    -- Log and continue with next DB/kind.
                    INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
                        (run_id, database_name, object_type, status, error_message)
                    VALUES
                        (:run_id, :db_name, :grant_kind, 'SHOW_FAILED', :SQLERRM);
            END;
        END FOR;
    END FOR;

    RETURN 'Done. run_id=' || :run_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Post-run summary (most recent run, identified by max transfer_id)
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

WITH latest AS (
    SELECT run_id
    FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
    ORDER BY transfer_id DESC
    LIMIT 1
)
SELECT
    l.database_name, l.schema_name, l.object_name, l.object_type, l.error_message
FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG l
JOIN latest ON l.run_id = latest.run_id
WHERE l.status IN ('ERROR', 'SHOW_FAILED')
ORDER BY l.database_name, l.schema_name, l.object_name;
