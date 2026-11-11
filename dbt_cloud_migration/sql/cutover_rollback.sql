-- Cutover rollback — SVC_DBT_CLOUD_ROLE -> SVC_MWAA_ROLE
--
-- Reverses one run of cutover_ownership_transfer.sql by reading its log at
-- FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG and issuing
-- GRANT OWNERSHIP back to SVC_MWAA_ROLE for every SUCCESS row. Rollback
-- attempts are themselves logged to
-- FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG.
--
-- Selects the most recent SUCCESS transfer batch by default. To reverse a
-- specific run, set `override_run_id` in the DECLARE section below.
--
-- Only touches objects whose current owner is still SVC_DBT_CLOUD_ROLE.
-- If ownership has drifted (an object was re-created or manually re-granted
-- since cutover), the row is logged as SKIPPED_OWNER_DRIFT and left alone —
-- rollback never wrests ownership from an unexpected role.
--
-- When to run:
--   Only when unwinding a cutover within the rollback window. Idempotent —
--   a re-run finds nothing owned by SVC_DBT_CLOUD_ROLE that came from the
--   named transfer and does nothing.
--
-- How to run:
--   snow sql -c <connection-name> -f projects/dbt_cloud_migration/sql/cutover_rollback.sql

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FDE_DEVELOPER_WH;  -- Medium; admin ad-hoc workload

-- ---------------------------------------------------------------------------
-- 1. Setup: rollback log table
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS FES_USERS.DBT_CLOUD_MIGRATION;
USE SCHEMA FES_USERS.DBT_CLOUD_MIGRATION;  -- temp tables need a current DB

CREATE TABLE IF NOT EXISTS FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG (
    rollback_run_id   VARCHAR,
    reverses_run_id   VARCHAR,
    rollback_id       BIGINT AUTOINCREMENT,
    rolled_back_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP,
    database_name     VARCHAR,
    schema_name       VARCHAR,
    object_name       VARCHAR,
    object_type       VARCHAR,
    current_owner     VARCHAR,           -- observed at rollback time
    restored_owner    VARCHAR,
    grant_statement   VARCHAR,
    status            VARCHAR,           -- SUCCESS / ERROR / SKIPPED_OWNER_DRIFT / SKIPPED_MISSING
    error_message     VARCHAR
);

-- ---------------------------------------------------------------------------
-- 2. Reverse ownership for every SUCCESS row in the selected transfer batch
-- ---------------------------------------------------------------------------

EXECUTE IMMEDIATE $$
DECLARE
    -- CONFIG: To reverse a specific transfer, replace NULL with '<uuid>'.
    -- Otherwise the most recent SUCCESS transfer batch is used.
    override_run_id  VARCHAR := NULL;

    reverses_run_id  VARCHAR;
    rollback_run_id  VARCHAR := UUID_STRING();
    fqn              VARCHAR;
    show_kind        VARCHAR;
    grant_stmt       VARCHAR;
    current_owner    VARCHAR;
    -- Cursor row fields copied into locals before use in INSERT VALUES.
    this_db          VARCHAR;
    this_sch         VARCHAR;
    this_obj         VARCHAR;
    this_obj_type    VARCHAR;
BEGIN
    IF (override_run_id IS NOT NULL) THEN
        reverses_run_id := :override_run_id;
    ELSE
        -- Scalar subquery returns NULL if the log has zero SUCCESS rows,
        -- rather than raising NO_DATA_FOUND.
        reverses_run_id := (
            SELECT run_id
            FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
            WHERE status = 'SUCCESS'
            ORDER BY transferred_at DESC
            LIMIT 1
        );
    END IF;

    IF (reverses_run_id IS NULL) THEN
        RETURN 'No SUCCESS transfer batch found to reverse. Nothing to do.';
    END IF;

    LET cur CURSOR FOR
        SELECT
            database_name AS db,
            schema_name   AS sch,
            object_name   AS obj,
            object_type   AS obj_type
        FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG
        WHERE run_id = :reverses_run_id
          AND status = 'SUCCESS';

    FOR rec IN cur DO
        this_db       := rec.db;
        this_sch      := rec.sch;
        this_obj      := rec.obj;
        this_obj_type := rec.obj_type;

        fqn        := this_db || '.' || this_sch || '.' || this_obj;
        show_kind  := CASE this_obj_type
                          WHEN 'TABLE'              THEN 'TABLES'
                          WHEN 'VIEW'               THEN 'VIEWS'
                          WHEN 'DYNAMIC TABLE'      THEN 'DYNAMIC TABLES'
                          WHEN 'MATERIALIZED VIEW'  THEN 'MATERIALIZED VIEWS'
                      END;
        grant_stmt := 'GRANT OWNERSHIP ON ' || this_obj_type || ' ' || fqn
                   || ' TO ROLE SVC_MWAA_ROLE COPY CURRENT GRANTS';
        current_owner := NULL;

        BEGIN
            -- Check current owner before touching anything.
            EXECUTE IMMEDIATE 'SHOW ' || :show_kind || ' LIKE ''' || this_obj
                           || ''' IN SCHEMA ' || this_db || '.' || this_sch;

            CREATE OR REPLACE TEMPORARY TABLE _owner_scan AS
            SELECT "owner" AS own
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

            -- MAX() returns NULL for empty result (object was dropped between
            -- transfer and rollback) instead of raising NO_DATA_FOUND.
            SELECT MAX(own) INTO :current_owner FROM _owner_scan;

            IF (current_owner IS NULL) THEN
                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG
                    (rollback_run_id, reverses_run_id, database_name, schema_name,
                     object_name, object_type, current_owner, restored_owner,
                     grant_statement, status)
                VALUES
                    (:rollback_run_id, :reverses_run_id, :this_db, :this_sch,
                     :this_obj, :this_obj_type, NULL, 'SVC_MWAA_ROLE',
                     :grant_stmt, 'SKIPPED_MISSING');
            ELSEIF (current_owner <> 'SVC_DBT_CLOUD_ROLE') THEN
                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG
                    (rollback_run_id, reverses_run_id, database_name, schema_name,
                     object_name, object_type, current_owner, restored_owner,
                     grant_statement, status)
                VALUES
                    (:rollback_run_id, :reverses_run_id, :this_db, :this_sch,
                     :this_obj, :this_obj_type, :current_owner, 'SVC_MWAA_ROLE',
                     :grant_stmt, 'SKIPPED_OWNER_DRIFT');
            ELSE
                BEGIN
                    EXECUTE IMMEDIATE :grant_stmt;
                    INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG
                        (rollback_run_id, reverses_run_id, database_name, schema_name,
                         object_name, object_type, current_owner, restored_owner,
                         grant_statement, status)
                    VALUES
                        (:rollback_run_id, :reverses_run_id, :this_db, :this_sch,
                         :this_obj, :this_obj_type, :current_owner, 'SVC_MWAA_ROLE',
                         :grant_stmt, 'SUCCESS');
                EXCEPTION
                    WHEN OTHER THEN
                        INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG
                            (rollback_run_id, reverses_run_id, database_name, schema_name,
                             object_name, object_type, current_owner, restored_owner,
                             grant_statement, status, error_message)
                        VALUES
                            (:rollback_run_id, :reverses_run_id, :this_db, :this_sch,
                             :this_obj, :this_obj_type, :current_owner, 'SVC_MWAA_ROLE',
                             :grant_stmt, 'ERROR', :SQLERRM);
                END;
            END IF;
        EXCEPTION
            WHEN OTHER THEN
                -- Object likely dropped, or SHOW failed (schema gone).
                INSERT INTO FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG
                    (rollback_run_id, reverses_run_id, database_name, schema_name,
                     object_name, object_type, restored_owner,
                     grant_statement, status, error_message)
                VALUES
                    (:rollback_run_id, :reverses_run_id, :this_db, :this_sch,
                     :this_obj, :this_obj_type, 'SVC_MWAA_ROLE',
                     :grant_stmt, 'SKIPPED_MISSING', :SQLERRM);
        END;
    END FOR;

    RETURN 'Done. rollback_run_id=' || :rollback_run_id
        || ' reversed transfer run_id=' || :reverses_run_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Post-run summary (most recent rollback, identified by max rollback_id)
-- ---------------------------------------------------------------------------

WITH latest AS (
    SELECT rollback_run_id
    FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG
    ORDER BY rollback_id DESC
    LIMIT 1
)
SELECT
    l.status,
    l.object_type,
    COUNT(*) AS n
FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG l
JOIN latest ON l.rollback_run_id = latest.rollback_run_id
GROUP BY l.status, l.object_type
ORDER BY l.status, l.object_type;

WITH latest AS (
    SELECT rollback_run_id
    FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG
    ORDER BY rollback_id DESC
    LIMIT 1
)
SELECT
    l.database_name, l.schema_name, l.object_name, l.object_type,
    l.current_owner, l.status, l.error_message
FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_ROLLBACK_LOG l
JOIN latest ON l.rollback_run_id = latest.rollback_run_id
WHERE l.status <> 'SUCCESS'
ORDER BY l.status, l.database_name, l.schema_name, l.object_name;
