-- Discovery: FES_USERS.* objects currently owned by SVC_MWAA_ROLE.
--
-- Run this before cutover. Output tells you which per-engineer sandbox objects
-- need ownership transferred to SVC_DBT_CLOUD_ROLE (because MWAA built them via
-- the deleted `dbt_users` DAG). Engineer-owned FES_USERS objects (created via
-- personal SSO) are irrelevant to the migration and should not be touched.
--
-- How to run:
--   snow sql -c <connection-name> -f projects/dbt_cloud_migration/sql/fes_users_ownership_discovery.sql
--
-- Then paste the GENERATED_GRANT column output into a new `-- FES_USERS`
-- section in cutover_ownership_transfer.sql. Mirror the rollback into
-- cutover_rollback.sql.

USE ROLE SECURITYADMIN;

SHOW TABLES IN DATABASE FES_USERS;
SELECT
    "database_name" AS database_name,
    "schema_name" AS schema_name,
    "name" AS object_name,
    'TABLE' AS object_type,
    "owner" AS current_owner,
    'GRANT OWNERSHIP ON TABLE ' || "database_name" || '.' || "schema_name" || '.' || "name" || ' TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;' AS generated_grant
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "owner" = 'SVC_MWAA_ROLE'
ORDER BY database_name, schema_name, object_name;

SHOW VIEWS IN DATABASE FES_USERS;
SELECT
    "database_name" AS database_name,
    "schema_name" AS schema_name,
    "name" AS object_name,
    'VIEW' AS object_type,
    "owner" AS current_owner,
    'GRANT OWNERSHIP ON VIEW ' || "database_name" || '.' || "schema_name" || '.' || "name" || ' TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;' AS generated_grant
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "owner" = 'SVC_MWAA_ROLE'
ORDER BY database_name, schema_name, object_name;
