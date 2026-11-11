# Snowflake Permissions Model — YOLO Weekend

> **UPDATE (2026-07-24):** The post-cutover external-table ownership / auto-refresh / grant-audit work (incl. `AR_FES_EXT_TABLE_OWNER`, PR #2958/#2960/#2950, and the auto-refresh re-enable) is tracked in **[[external-table-ownership-audit.md]]**. The plan below is the migration-era design; some of it (e.g. "grant SVC_DBT_CLOUD_ROLE to SVC_MWAA_ROLE") was superseded.

The single trickiest piece of the migration.

## The problem

Every existing dbt model table was created by `SVC_MWAA_ROLE`, so MWAA owns them. dbt Cloud will run as `SVC_DBT_CLOUD_ROLE`. dbt's `CREATE OR REPLACE TABLE` (used for every `--full-refresh` and every non-incremental model) requires **OWNERSHIP** of the existing table:

> "The destination table for a CREATE OR REPLACE TABLE statement cannot be owned by a different role." — Snowflake docs

Admin privileges on the schema (`admin_roles` in the Terraform module) let a role CREATE new tables but not REPLACE ones owned by a different role. That's a `CREATE TABLE` grant on the schema — not ownership over existing objects.

**Every Snowflake object has exactly one owner role.** No dual ownership. `COPY CURRENT GRANTS` preserves non-ownership grants during transfer, but doesn't create multiple owners.

## What `COPY CURRENT GRANTS` actually does

```
Before transfer:
  Owner: SVC_MWAA_ROLE  (implicit all-privileges)
  Explicit grants on table: SELECT to FES_DATA_DEVELOPER, SELECT to FANATICS_ADS

After GRANT OWNERSHIP ... TO SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS:
  Owner: SVC_DBT_CLOUD_ROLE  (implicit all-privileges)
  Explicit grants: SELECT to FES_DATA_DEVELOPER, SELECT to FANATICS_ADS   ← preserved
  MWAA: nothing explicit — its access came from ownership, gone
```

Without a safety net, MWAA loses ALL access to the tables it previously owned. Downstream Airflow tasks (exports, Python tasks reading dbt tables) break the moment ownership transfers.

## The plan

Three moves that unlock a clean end-state on day 1:

### Step 1 — Terraform PR: `admin_roles` parity

Add `module.dbt_cloud_service_user.service_user_role_name` alongside MWAA in `admin_roles` for every FES-owned database. Same pattern as [fanapp-terraform#2830](https://github.com/fanatics-gaming/fanapp-terraform/pull/2830) but scoped to the other target databases.

Target databases (from grepping `fes-airflow/dags/dbt/models/`):

`FANAPP`, `FANFLOW`, `FANGRAPH`, `IDENTITY`, `CDE`, `COMMERCE`, `ENTERPRISE_METRICS`, `FDE`, `FDE_FBG`, `FDE_FMX`, `FDE_IMPRINT`, `FDE_COLLECTIBLES`, `FES_INTEGRATIONS`, `LOYALTY`, `MDE`, `MONTEROSA`, `SEEK_INSIGHTS`, `XP`, `AAIA_CORTEX`

Plus their `*_DEV` twins. Skip `TREASURE_DATA` (source-only) and `FES_USERS` (per-user dev schemas).

Purpose: ensures FUTURE grants and CREATE privileges are correctly set for new tables that dbt Cloud creates going forward. Doesn't fix the ownership problem on existing tables — that's Step 2.

### Step 2 — Ownership transfer (one-time script)

Per schema per database:

```sql
GRANT OWNERSHIP ON ALL TABLES              IN SCHEMA <DB>.<SCHEMA>
  TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL VIEWS               IN SCHEMA <DB>.<SCHEMA>
  TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL DYNAMIC TABLES      IN SCHEMA <DB>.<SCHEMA>
  TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL MATERIALIZED VIEWS  IN SCHEMA <DB>.<SCHEMA>
  TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;
```

Idempotent. Safe to re-run.

### Step 3 — Role hierarchy safety net

Give MWAA full access to everything DBT_CLOUD owns during transition:

```sql
GRANT ROLE SVC_DBT_CLOUD_ROLE TO ROLE SVC_MWAA_ROLE;
```

One statement covers all databases. MWAA inherits every privilege DBT_CLOUD has (including ownership). Airflow tasks that still SELECT from dbt tables (exports, downstream Python tasks) keep working with zero change.

Post-cutover, once confident:
```sql
REVOKE ROLE SVC_DBT_CLOUD_ROLE FROM ROLE SVC_MWAA_ROLE;
```

Replace with explicit grants for MWAA on tables it still legitimately needs (probably SELECT only for exports).

## Rollback

To restore MWAA ownership:

```sql
GRANT OWNERSHIP ON ALL TABLES         IN SCHEMA <DB>.<SCHEMA>
  TO ROLE SVC_MWAA_ROLE COPY CURRENT GRANTS;
-- repeat for views, dynamic tables, materialized views
-- repeat per schema, per database
```

Scriptable. ~5 minutes per database. Combined with reverting the Airflow sensor PR, full rollback is 15–30 minutes total.

Terraform PR (admin_roles addition) doesn't need reverting — having DBT_CLOUD listed as admin doesn't hurt anything if unused.

## Ownership-transfer script scaffold

Not yet written. Should:
- Loop over all target databases + their `*_DEV` twins
- Get schema list dynamically per DB
- Transfer ownership for tables + views + dynamic tables + materialized views
- Idempotent (safe to re-run)
- Log progress per (DB, schema, object type)

Rough sketch:

```bash
#!/usr/bin/env bash
set -euo pipefail

DBS=(FANAPP FANFLOW FANGRAPH IDENTITY CDE COMMERCE ENTERPRISE_METRICS \
     FDE FDE_FBG FDE_FMX FDE_IMPRINT FDE_COLLECTIBLES FES_INTEGRATIONS \
     LOYALTY MDE MONTEROSA SEEK_INSIGHTS XP AAIA_CORTEX)

for DB_BASE in "${DBS[@]}"; do
  for DB in "${DB_BASE}" "${DB_BASE}_DEV"; do
    # snow sql to fetch schemas, then per schema:
    #   GRANT OWNERSHIP ON ALL TABLES/VIEWS/DYNAMIC TABLES/MATERIALIZED VIEWS
    #   IN SCHEMA $DB.$SCHEMA TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS
    ...
  done
done
```

Write and commit Saturday morning before running against dev.

## Alternative considered and rejected

**Run dbt Cloud as `SVC_MWAA_ROLE` (via role grant + `role: SVC_MWAA_ROLE` in the dbt profile).**

Pros: no ownership transfer needed, MWAA-owned tables just work, rollback is trivial.

Cons: dbt Cloud isn't a first-class Snowflake identity — it's proxying MWAA. Same ownership migration would still be needed later, just delayed. Audit logs show correct user but effective role is MWAA, muddying the audit story.

Decision: transfer ownership upfront (D20 in `decisions.md`). Cleaner end-state, migration debt paid now instead of deferred.
