# Prototype Tracker

Things created manually in `FES_USERS.ALEX_SOTIS` (or at account level) for prototyping, before terraform exists. **Every item here gets a cleanup checkbox.** When terraform promotes it to its proper location, mark the cleanup task and drop the prototype.

**Why we prototype outside terraform**: Alex is Snowflake admin, so we can iterate fast in their personal schema without blocking on a `fanapp-terraform` PR cycle. Once end-to-end works, terraform PR promotes to governance schema.

## Status

| Item | Created | Terraform location | Promoted | Prototype dropped |
|---|---|---|---|---|
| Role `FES_PII_READER` | 2026-06-10 ✓ | account-level | ☐ | ☐ |
| Policy `FES_PII_MASK_STRING` | 2026-06-10 ✓ | `GOVERNANCE.MASKING` | ☐ | ☐ |
| Policy `FES_PII_MASK_NUMBER` | 2026-06-10 ✓ | `GOVERNANCE.MASKING` | ☐ | ☐ |
| Policy `FES_PII_MASK_DATE` | 2026-06-10 ✓ | `GOVERNANCE.MASKING` | ☐ | ☐ |
| Grant: `FES_PII_READER` → alex.sotis user | 2026-06-10 ✓ | (alex stays granted; same grant via terraform) | ☐ | n/a |
| Grant: `APPLY` on policies → MWAA service role | — | terraform | ☐ | n/a |
| Smoke test (`MASKING_SMOKE_TEST` table, role-switching verified) | 2026-06-10 ✓ | — | — | ☐ (drop after end-to-end validation) |
| dbt macros `apply_pii_masking_policies` + `get_masking_policy_for_type` in `fes-airflow` | 2026-06-10 ✓ | (stays — production infrastructure) | n/a | n/a |
| Policy attached to `FANGRAPH_DEV.ADMIN.FANGRAPH_RESOLVER_PII.FANGRAPH_EMAIL` via macro | 2026-06-10 ✓ | (stays — re-attached automatically when var flips to `GOVERNANCE.MASKING`) | ☐ (flip to gov location post-terraform) | n/a |
| YAML tag on `fangraph_resolver_pii.fangraph_email` (`meta.classification: critical`) | 2026-06-10 ✓ | (stays — production tag) | n/a | n/a |

Update the "Created" date and tick boxes as we go.

## Prototype object locations

```
Account-level
└── FES_PII_READER (role)

FES_USERS.ALEX_SOTIS  (Alex's user schema)
├── FES_PII_MASK_STRING        (masking policy)
├── FES_PII_MASK_NUMBER        (masking policy)
└── FES_PII_MASK_DATE          (masking policy)
```

After terraform promotes:

```
Account-level
└── FES_PII_READER (role)  — same role, possibly re-created or imported by terraform

GOVERNANCE.MASKING  (governance schema, terraform-managed)
├── FES_PII_MASK_STRING
├── FES_PII_MASK_NUMBER
└── FES_PII_MASK_DATE
```

## Bootstrap SQL (run in Alex's session)

```sql
-- Role (account-level; SNOWFLAKE admin only)
CREATE OR REPLACE ROLE FES_PII_READER COMMENT = 'V1 prototype — secondary role unlocks PII via masking policy. Will be terraform-managed.';
GRANT ROLE FES_PII_READER TO USER "ALEX.SOTIS@BETFANATICS.COM";

-- Policies in user schema
CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.FES_PII_MASK_STRING
  AS (val STRING) RETURNS STRING ->
  CASE WHEN IS_ROLE_IN_SESSION('FES_PII_READER') THEN val
       ELSE '*** MASKED ***'
  END
  COMMENT = 'V1 prototype — will move to GOVERNANCE.MASKING via terraform.';

CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.FES_PII_MASK_NUMBER
  AS (val NUMBER) RETURNS NUMBER ->
  CASE WHEN IS_ROLE_IN_SESSION('FES_PII_READER') THEN val
       ELSE -1
  END
  COMMENT = 'V1 prototype — will move to GOVERNANCE.MASKING via terraform.';

CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.FES_PII_MASK_DATE
  AS (val DATE) RETURNS DATE ->
  CASE WHEN IS_ROLE_IN_SESSION('FES_PII_READER') THEN val
       ELSE DATE '1900-01-01'
  END
  COMMENT = 'V1 prototype — will move to GOVERNANCE.MASKING via terraform.';
```

## Smoke test

```sql
-- Create a test column
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.MASKING_SMOKE_TEST (
  fan_id  STRING,
  email   STRING,
  dob     DATE
);
INSERT INTO FES_USERS.ALEX_SOTIS.MASKING_SMOKE_TEST VALUES
  ('fan_001', 'alice@example.com', DATE '1990-01-15'),
  ('fan_002', 'bob@example.com',   DATE '1985-07-22');

-- Attach policies
ALTER TABLE FES_USERS.ALEX_SOTIS.MASKING_SMOKE_TEST
  MODIFY COLUMN email SET MASKING POLICY FES_USERS.ALEX_SOTIS.FES_PII_MASK_STRING FORCE;
ALTER TABLE FES_USERS.ALEX_SOTIS.MASKING_SMOKE_TEST
  MODIFY COLUMN dob   SET MASKING POLICY FES_USERS.ALEX_SOTIS.FES_PII_MASK_DATE FORCE;

-- Without the role, masked
USE SECONDARY ROLES NONE;
SELECT * FROM FES_USERS.ALEX_SOTIS.MASKING_SMOKE_TEST;
-- Expect: email='*** MASKED ***', dob=1900-01-01

-- With the role as secondary, unmasked
USE SECONDARY ROLES ALL;
SELECT * FROM FES_USERS.ALEX_SOTIS.MASKING_SMOKE_TEST;
-- Expect: real values
```

## Cleanup SQL (after terraform PR is merged and applied)

```sql
-- Detach policies from any tables in ALEX_SOTIS schema first (Snowflake blocks DROP if attached)
-- ALTER TABLE ... MODIFY COLUMN ... UNSET MASKING POLICY;

DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.FES_PII_MASK_STRING;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.FES_PII_MASK_NUMBER;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.FES_PII_MASK_DATE;

DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MASKING_SMOKE_TEST;
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.CLASSIFICATION_TEST;
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.HASHED_EMAIL_CLASSIFICATION_TEST;

-- Role: leave in place. Terraform should `terraform import` rather than recreate, to preserve existing grants.
-- If terraform recreates instead of imports, drop here:
-- DROP ROLE IF EXISTS FES_PII_READER;  -- ONLY if terraform is re-creating
```

## Cutover from prototype policy location to governance

Once terraform PR creates `GOVERNANCE.MASKING.FES_PII_MASK_*`:

1. Edit `fes-airflow/dags/dbt/dbt_project.yml`: the defaults already point at `GOVERNANCE` / `MASKING` — no change needed there. Just stop passing the prototype override.
2. Run the macro once to re-attach: `dbt run-operation apply_pii_masking_policies` (without the prototype `--vars` override). The `FORCE` replaces the prototype-location policy with the governance-location one in a single ALTER per column.
3. Verify via `INFORMATION_SCHEMA.POLICY_REFERENCES` that the new policy name is attached.
4. Drop the prototype policies per the Cleanup SQL section above.

No code changes; pure config + sql.

## Notes on role recreation vs import

When terraform takes over `FES_PII_READER`:

- **Preferred**: terraform `import` block adopts the existing role. Grants are preserved. No re-grant needed.
- **Alternative**: terraform creates a new role. Then we have to re-grant to users (and possibly fail-over during the window). Avoid if possible.

If terraform import isn't feasible in `fanapp-terraform` conventions, plan a maintenance window for the cutover.
