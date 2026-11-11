# Monday's Terraform PR spec — SVC_DBT_CLOUD grants for diff testing

Weekend manual grants documented here so we can codify them in Terraform on Monday. Ideally lands as a single PR to `fanapp-terraform`.

## Manual grants Alex ran on 2026-07-11 (weekend)

For local loyalty diff testing under FES_DATA_DEVELOPER role, no grants were required — Alex's role already had them. The SVC_DBT_CLOUD_ROLE grants below are for Phase 2 (Cloud IDE / Airflow-triggered runs).

### Warehouse USAGE for SVC_DBT_CLOUD_ROLE

```sql
USE ROLE SECURITYADMIN;

-- Loyalty ledger diff (Phase 1) — sufficient
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_WH      TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_XL_WH   TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_2XL_WH  TO ROLE SVC_DBT_CLOUD_ROLE;

-- Fangraph diff (Phase 2) — adds these
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_XS_WH   TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_SM_WH   TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_LG_WH   TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_DEVELOPER_3XL_WH  TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_FANGRAPH_MD_WH    TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_FANGRAPH_LG_WH    TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_FANGRAPH_XL_WH    TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON WAREHOUSE FDE_FANGRAPH_3XL_WH   TO ROLE SVC_DBT_CLOUD_ROLE;

-- Note: there is no FDE_DEVELOPER_MD_WH warehouse. Existing dev warehouses
-- come in XS/SM/WH/LG/XL/2XL/3XL sizes; MD is skipped. Fangraph configs
-- use FDE_FANGRAPH_MD_WH (existing prod-side) — no follow-up needed.
```

### Source database SELECT for SVC_DBT_CLOUD_ROLE (Phase 2 only)

For the fangraph diff to work when the run role is SVC_DBT_CLOUD (not personal SSO), we need read access on all source DBs. Phase 1 (Alex-run, loyalty only) didn't need this because his role already had it.

```sql
-- One-DB pattern (repeat for each):
GRANT USAGE  ON DATABASE <DB>                     TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE  ON ALL SCHEMAS   IN DATABASE <DB>    TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT SELECT ON ALL TABLES    IN DATABASE <DB>    TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT SELECT ON ALL VIEWS     IN DATABASE <DB>    TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN DATABASE <DB> TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE  ON FUTURE SCHEMAS IN DATABASE <DB>   TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT SELECT ON FUTURE TABLES  IN DATABASE <DB>   TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT SELECT ON FUTURE VIEWS   IN DATABASE <DB>   TO ROLE SVC_DBT_CLOUD_ROLE;
```

Source DBs the fangraph 211-model tree touches:
`AAIA`, `AMPLITUDE`, `APPSFLYER`, `CDE`, `COLLECTIBLES_FDE`, `COMMERCE`, `COMMERCE_CDE`, `COMMERCE_FDE`, `COMMERCE_MDE`, `FANFLOW`, `FANGRAPH`, `FBG_FDE`, `FDE`, `FES_INTEGRATIONS`, `FES_USERS`, `IDENTITY`, `LEXIS_NEXIS`, `LIVE_FDE`, `LOYALTY`, `MONTEROSA`, `SALESFORCE`, `SALESFORCE_QC`.

That's ~22 databases. Full loop:

<details>
<summary>Full loop script</summary>

```sql
USE ROLE SECURITYADMIN;

DECLARE
  source_dbs ARRAY DEFAULT ARRAY_CONSTRUCT(
    'AAIA', 'AMPLITUDE', 'APPSFLYER', 'CDE', 'COLLECTIBLES_FDE',
    'COMMERCE', 'COMMERCE_CDE', 'COMMERCE_FDE', 'COMMERCE_MDE',
    'FANFLOW', 'FANGRAPH', 'FBG_FDE', 'FDE', 'FES_INTEGRATIONS',
    'FES_USERS', 'IDENTITY', 'LEXIS_NEXIS', 'LIVE_FDE',
    'LOYALTY', 'MONTEROSA', 'SALESFORCE', 'SALESFORCE_QC'
  );
  i INTEGER DEFAULT 0;
  db STRING;
BEGIN
  WHILE (i < ARRAY_SIZE(source_dbs)) DO
    db := source_dbs[i]::STRING;
    EXECUTE IMMEDIATE 'GRANT USAGE ON DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    EXECUTE IMMEDIATE 'GRANT USAGE ON ALL SCHEMAS IN DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    EXECUTE IMMEDIATE 'GRANT SELECT ON ALL TABLES IN DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    EXECUTE IMMEDIATE 'GRANT SELECT ON ALL VIEWS IN DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    EXECUTE IMMEDIATE 'GRANT SELECT ON ALL DYNAMIC TABLES IN DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUTURE SCHEMAS IN DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    EXECUTE IMMEDIATE 'GRANT SELECT ON FUTURE TABLES IN DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    EXECUTE IMMEDIATE 'GRANT SELECT ON FUTURE VIEWS IN DATABASE ' || db || ' TO ROLE SVC_DBT_CLOUD_ROLE';
    i := i + 1;
  END WHILE;
END;
```
</details>

## Terraform PR structure

Add to `fanapp-terraform` following the pattern established in PR #2830 (which added SVC_DBT_CLOUD to FES_ADS admin_roles).

### Warehouse grants

Add to `root/fes-data/snowflake-v2/persona-service_users.tf` or a new dedicated file:

```hcl
locals {
  dbt_cloud_warehouses = [
    "FDE_DEVELOPER_WH",
    "FDE_DEVELOPER_XL_WH",
    "FDE_DEVELOPER_2XL_WH",
    "FDE_DEVELOPER_XS_WH",
    "FDE_DEVELOPER_SM_WH",
    "FDE_DEVELOPER_LG_WH",
    "FDE_DEVELOPER_3XL_WH",
    # Note: no FDE_DEVELOPER_MD_WH exists.
    "FDE_FANGRAPH_MD_WH",
    "FDE_FANGRAPH_LG_WH",
    "FDE_FANGRAPH_XL_WH",
    "FDE_FANGRAPH_3XL_WH",
  ]
}

resource "snowflake_grant_privileges_to_account_role" "dbt_cloud_warehouse_usage" {
  for_each = toset(local.dbt_cloud_warehouses)

  privileges        = ["USAGE"]
  account_role_name = module.dbt_cloud_service_user.service_user_role_name

  on_account_object {
    object_type = "WAREHOUSE"
    object_name = each.key
  }
}
```

### Source database read grants

Extend the `admin_roles` pattern from PR #2830 to include SVC_DBT_CLOUD_ROLE on each source DB's admin role — but read-only. Or add a dedicated grant loop:

```hcl
locals {
  dbt_cloud_read_only_dbs = [
    "AAIA", "AMPLITUDE", "APPSFLYER", "CDE", "COLLECTIBLES_FDE",
    "COMMERCE", "COMMERCE_CDE", "COMMERCE_FDE", "COMMERCE_MDE",
    "FANFLOW", "FANGRAPH", "FBG_FDE", "FDE", "FES_INTEGRATIONS",
    "FES_USERS", "IDENTITY", "LEXIS_NEXIS", "LIVE_FDE",
    "LOYALTY", "MONTEROSA", "SALESFORCE", "SALESFORCE_QC",
  ]
}

# Note: this pattern below is illustrative — check what the existing
# fanapp-terraform convention is for adding read access to a role.
# Some DBs may already have a dedicated "reader" role we can grant to
# SVC_DBT_CLOUD_ROLE instead of listing privileges directly.

resource "snowflake_grant_privileges_to_account_role" "dbt_cloud_db_usage" {
  for_each = toset(local.dbt_cloud_read_only_dbs)

  privileges        = ["USAGE"]
  account_role_name = module.dbt_cloud_service_user.service_user_role_name

  on_account_object {
    object_type = "DATABASE"
    object_name = each.key
  }
}

resource "snowflake_grant_privileges_to_account_role" "dbt_cloud_all_schemas_usage" {
  for_each = toset(local.dbt_cloud_read_only_dbs)

  privileges        = ["USAGE"]
  account_role_name = module.dbt_cloud_service_user.service_user_role_name

  on_schema {
    all_schemas_in_database = each.key
  }
}

resource "snowflake_grant_privileges_to_account_role" "dbt_cloud_all_tables_select" {
  for_each = toset(local.dbt_cloud_read_only_dbs)

  privileges        = ["SELECT"]
  account_role_name = module.dbt_cloud_service_user.service_user_role_name

  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_database        = each.key
    }
  }
}

# Repeat for VIEWS, DYNAMIC TABLES, FUTURE SCHEMAS, FUTURE TABLES, FUTURE VIEWS.
```

## Follow-ups from this weekend's work

1. **`loyalty_earn_burn_mapper_stage_final` doesn't exist** (my Phase 1 diff script assumed the naming pattern). Different upstream naming. Doc'd in `loyalty-diff-runbook.md` "Optional step 4".

2. **Small diffs on 3 of 4 loyalty ledgers** are upstream data drift (stage tables rebuilt between clone times). Not Fusion behavior. For rigorous cutover validation, use Snowflake Time Travel or coordinate a MWAA pause.
