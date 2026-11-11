# Terraform Changes (fanapp-terraform)

Snowflake account-level objects: secondary role, masking policy objects, and grants. Lives in the `fanapp-terraform` repo.

**Status**: Not implemented. This document is the spec.

**Promotion model**: We prototype the same objects manually in `FES_USERS.ALEX_SOTIS` first (see [`08_prototype_tracker.md`](08_prototype_tracker.md)). The terraform PR is what **promotes** the validated design to the governance schema. After terraform applies, the prototype objects are dropped per the cleanup checklist in `08`.

## Objects to create

### 1. Role: `FES_PII_READER`

- Account-level role (not a database role)
- Used as a **secondary role** by holders (granted via `USE SECONDARY ROLES ALL` or explicit `USE SECONDARY ROLES FES_PII_READER`)
- This is why our masking policies use `IS_ROLE_IN_SESSION()` not `CURRENT_ROLE()` — secondary roles aren't the current role, but they are in the session

### 2. One masking policy per Snowflake data type

Three account-level masking policy objects covering every PII column type observed in fangraph_dev:

```
FES_PII_MASK_STRING
FES_PII_MASK_NUMBER
FES_PII_MASK_DATE
```

Per D12, additional types (FLOAT, BOOLEAN, TIMESTAMP_*, VARIANT) are added lazily as new PII columns surface — each is one terraform resource plus one line in `get_masking_policy_for_type.sql`.

**Where they live**: A dedicated account-level schema, e.g. `GOVERNANCE.MASKING.<POLICY_NAME>` or `UTIL.SECURITY.<POLICY_NAME>`. Decide during impl — should match `fanapp-terraform` conventions for shared governance objects.

### 3. Grants

```
GRANT APPLY ON MASKING POLICY <policy> TO ROLE <dbt_service_role>;
   -- Allows the dbt service role (MWAA) to attach the policy via ALTER TABLE.
   -- Required for the on-run-end macro to work.

GRANT USAGE ON MASKING POLICY <policy> TO ROLE <reader_roles>;
   -- Allows roles to reference the policy in their session.
   -- Generally implicit via OWNERSHIP but document the expected grants.

GRANT ROLE FES_PII_READER TO USER <mwaa_service_user>;
   -- Per D6: MWAA sees unmasked data so dbt tests work.

GRANT ROLE FES_PII_READER TO ROLE <admin_role>;
   -- Optional: grant to admin roles for ops debugging. TBD by data-platform team.
```

## Policy DDL (reference)

The Terraform resources will produce SQL equivalent to:

```sql
-- STRING
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASKING.FES_PII_MASK_STRING
  AS (val STRING) RETURNS STRING ->
  CASE WHEN IS_ROLE_IN_SESSION('FES_PII_READER') THEN val
       ELSE '*** MASKED ***'
  END;

-- NUMBER
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASKING.FES_PII_MASK_NUMBER
  AS (val NUMBER) RETURNS NUMBER ->
  CASE WHEN IS_ROLE_IN_SESSION('FES_PII_READER') THEN val
       ELSE -1
  END;

-- DATE
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASKING.FES_PII_MASK_DATE
  AS (val DATE) RETURNS DATE ->
  CASE WHEN IS_ROLE_IN_SESSION('FES_PII_READER') THEN val
       ELSE DATE '1900-01-01'
  END;

-- Other Snowflake types added lazily per D12 (one resource per type when first needed)
```

## Terraform implementation notes

- Snowflake provider: confirm whether `fanapp-terraform` is on the new `snowflakedb/snowflake` (v2.x) or the legacy `snowflake-labs/snowflake` (v0.93). The terraform-snowflake skill in this repo can advise.
- Resource for masking policy: `snowflake_masking_policy` (or `snowflake_masking_policy` in the new provider — names align across providers).
- Resource for role: `snowflake_account_role` (new) or `snowflake_role` (old).
- Resource for grant: `snowflake_grant_privileges_to_account_role` (new) or `snowflake_role_grants` (old).

## Pre-implementation checklist

- [ ] Confirm Snowflake provider version in `fanapp-terraform`
- [ ] Confirm location for governance/security policies (existing schema or new one)
- [ ] Identify the exact MWAA service user name(s) — there may be one per env (dev/stg/prod)
- [ ] Identify the dbt service role(s) — same dimension
- [ ] Confirm admin roles that should also receive `FES_PII_READER`
- [ ] **Decide**: terraform `import` block to adopt the prototype role, or recreate? Import preserves user grants without a cutover window. See [`08_prototype_tracker.md`](08_prototype_tracker.md) "Notes on role recreation vs import".

## Validation after deploy

```sql
-- Policy exists
SHOW MASKING POLICIES LIKE 'FES_PII_MASK_%';

-- MWAA service user has the role
SHOW GRANTS TO USER <mwaa_service_user>;

-- A test attach works
ALTER TABLE FANGRAPH_DEV.SOME_SCHEMA.SOME_TABLE
  MODIFY COLUMN EMAIL SET MASKING POLICY GOVERNANCE.MASKING.FES_PII_MASK_STRING FORCE;

-- Without the role, masked
USE SECONDARY ROLES NONE;
SELECT EMAIL FROM FANGRAPH_DEV.SOME_SCHEMA.SOME_TABLE LIMIT 1;  -- expect '*** MASKED ***'

-- With the role as secondary, unmasked
USE SECONDARY ROLES ALL;
SELECT EMAIL FROM FANGRAPH_DEV.SOME_SCHEMA.SOME_TABLE LIMIT 1;  -- expect real value
```

## Open questions for this doc

- Where in `fanapp-terraform` does this code live? Existing governance module or new?
- Are there approval flows (CODEOWNERS, security review) that gate role creation?
