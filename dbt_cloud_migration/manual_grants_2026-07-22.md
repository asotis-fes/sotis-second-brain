# Manual Grants Applied 2026-07-22

Running log of every manual Snowflake grant applied today as a stop-gap before Terraform codification. Use this as the input list for the TF PR extension of `dbt-cloud-grants-full-scope`.

**Grantee (unless noted):** `SVC_DBT_CLOUD_ROLE`
**Executor role:** `ACCOUNTADMIN`
**Warehouse:** `FDE_DEVELOPER_WH`

All grants will drift on TF apply if not codified — track each row until the TF PR merges.

---

## A. External volume USAGE (7 volumes) — ✅ verified via SHOW GRANTS

Iceberg tables in Snowflake need USAGE on both the external volume (S3 data) and the catalog integration (AWS Glue metadata). This section covers the volume half; see section D for integrations.

```sql
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_CRM_ICEBERG_DB_CDM_VOLUME_PROD          TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_CRM_ICEBERG_DB_VOLUME_PROD              TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_EXP_PROD_DB_VOLUME_PROD                 TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_AVEXP_VOLUME_PROD                       TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_ORDER_INTELLIGENCE_ANALYTICS_DB_MAIN_VOLUME_PROD TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_CUSTOMER_DB_VOLUME_PROD                 TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_TRANSACTIONS_DB_MAIN_PII_VOLUME_PROD    TO ROLE SVC_DBT_CLOUD_ROLE;
```

**Ad-hoc human role grant (Rohan Gulati unblock):**
```sql
GRANT USAGE ON EXTERNAL VOLUME ECOMM_ANALYTICS_EXP_PROD_DB_VOLUME_PROD TO ROLE "SNOWFLAKE-FES-FES_ANALYST";
```

**TF pattern:** `snowflake_grant_privileges_to_account_role` with `on_account_object { object_type = "EXTERNAL VOLUME" }`.

---

## B. SALESFORCE inbound share — ⚠️ empirical validation pending

```sql
GRANT IMPORTED PRIVILEGES ON DATABASE SALESFORCE TO ROLE SVC_DBT_CLOUD_ROLE;
```

**Note:** SHOW GRANTS output only shows a pre-existing `USAGE granted_by SYSADMIN` row; whether my IMPORTED PRIVILEGES grant added a separate row is unclear from the CLI output. Validation: `dbt_fanatics_one` (run `70437511490814`) has been running 15+ min without erroring on SALESFORCE — strong indication the grant is effective.

**TF pattern:** add `SVC_DBT_CLOUD_ROLE` to `salesforce_share.read_only_roles` list in `root/fes-data/snowflake-v2/db_from_share-salesforce.tf`. Mirror PR #2881 which added `ecosystem_engineer`.

---

## C. PMG_FANAPP database — ✅ landed as USAGE

```sql
GRANT IMPORTED PRIVILEGES ON DATABASE PMG_FANAPP TO ROLE SVC_DBT_CLOUD_ROLE;
```

**Note:** SHOW GRANTS shows this as `USAGE granted_by ACCOUNTADMIN` (IMPORTED PRIVILEGES on a shared DB is displayed as USAGE by Snowflake).

**TF gap:** `PMG_FANAPP` is **NOT currently in fanapp-terraform**. No `db_from_share-pmg_fanapp.tf` exists — only outbound `outbound_shares-pmg.tf` (FBG→PMG direction). Open question for the TF PR:
- (a) Is PMG_FANAPP an inbound share that should be provisioned via a new `db_from_share-pmg_fanapp.tf`?
- (b) Was it created manually outside TF?

If (a), the TF PR should add the new file using the `database-from-share` module pattern (see e.g. `db_from_share-appsflyer.tf`).

---

## D. Catalog integration USAGE (7 needed, 1 applied so far)

Iceberg tables need catalog integration USAGE in addition to external volume USAGE. Discovery via `SHOW INTEGRATIONS` — CATALOG integrations `ECOMM_ANALYTICS_GLUE_*_PROD` pair 1:1 with the 7 volumes we granted USAGE on.

### Applied (1):
```sql
GRANT USAGE ON INTEGRATION ECOMM_ANALYTICS_GLUE_CUSTOMER_DB_PROD TO ROLE SVC_DBT_CLOUD_ROLE;
```

### Pending (6):
```sql
USE ROLE ACCOUNTADMIN;
GRANT USAGE ON INTEGRATION ECOMM_ANALYTICS_GLUE_CRM_ICEBERG_DB_CDM_PROD        TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON INTEGRATION ECOMM_ANALYTICS_GLUE_CRM_ICEBERG_DB_PROD            TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON INTEGRATION ECOMM_ANALYTICS_GLUE_EXP_PROD_DB_PROD               TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON INTEGRATION ECOMM_ANALYTICS_GLUE_AVEXP_PROD                     TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON INTEGRATION ECOMM_ANALYTICS_GLUE_ORDER_INTELLIGENCE_ANALYTICS_DB_MAIN_PROD TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON INTEGRATION ECOMM_ANALYTICS_GLUE_TRANSACTIONS_DB_MAIN_PII_PROD  TO ROLE SVC_DBT_CLOUD_ROLE;
```

### Not granted (evaluate case-by-case, no evidence of need yet):
- `ECOMM_ANALYTICS_GLUE_FES_FANFLOW_DB_PROD`
- `ECOMM_ANALYTICS_GLUE_FES_LOYALTY_PROD`
- `ECOMM_ANALYTICS_GLUE_LOYALTY_PROD`
- `ECOMM_ANALYTICS_GLUE_LOYALTY_DEV`
- 4× `ECOMM_ANALYTICS_S3_INTEGRATION_*` (storage integrations, not catalog)

**TF pattern:** `snowflake_grant_privileges_to_account_role` with `on_account_object { object_type = "INTEGRATION" }`.

---

## Non-grant fixes applied today (for TF PR context, not codification)

1. **Ownership transfer script** (`sql/cutover_ownership_transfer.sql`) — ran, transferred ~1347 objects to `SVC_DBT_CLOUD_ROLE`. Accidental over-transfer on `FES_INTEGRATIONS.FES_SHEETZU` reverted via a scoped rollback (see `rollback_fes_sheetzu.txt` scratchpad file).
2. **9 LOYALTY_DEV.SOURCE + FDE_FBG_DEV ownership transfers** — dev artifacts owned by `FES_DATA_DEVELOPER`, transferred to `SVC_DBT_CLOUD_ROLE`. Root cause was wrong `target` in prod job, now fixed; grants no longer needed long-term. Skip TF codification.
3. **dbt Cloud dev fangraph job `--selector` → `--select`** — updated via API from `dbt build --selector fangraph` to `dbt build --select tag:fangraph`. Prod already fixed prior. Not a TF concern (dbt Cloud job config, not Snowflake grants).

---

## Verification snapshot

```sql
USE ROLE ACCOUNTADMIN;
SHOW GRANTS TO ROLE SVC_DBT_CLOUD_ROLE;
SELECT "privilege", "granted_on", "name", "granted_by"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE ("granted_on" = 'VOLUME'      AND "name" LIKE 'ECOMM_ANALYTICS%')
   OR ("granted_on" = 'INTEGRATION' AND "name" LIKE 'ECOMM_ANALYTICS%')
   OR ("granted_on" = 'DATABASE'    AND "name" IN ('SALESFORCE','PMG_FANAPP'))
ORDER BY "granted_on", "name";
```

Expected final state after all 6 pending integrations land: **7 VOLUME rows + 7 INTEGRATION rows + 2 DATABASE rows = 16 rows total** for the Ecomm/share grants.
