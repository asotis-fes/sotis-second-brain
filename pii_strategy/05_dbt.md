# dbt Changes (fes-airflow/dags/dbt)

YAML tag conventions, the on-run-end macro, and dbt-side wiring. Lives in the `fes-airflow` repo.

**Status**: Not implemented. This document is the spec.

**Policy location must be configurable.** During prototype the policies live in `FES_USERS.ALEX_SOTIS`; after terraform promotion they live in `GOVERNANCE.MASKING`. The dbt macro reads the location from `var()` so the cutover is a one-line config change, not a code change. See "Policy location config" below.

## Files to add or modify

```
fes-airflow/dags/dbt/
├── dbt_project.yml                                     # add on-run-end entry
├── macros/
│   ├── apply_pii_masking_policies.sql                  # NEW: main macro
│   └── pii_helpers.sql                                 # NEW: lookup helpers
└── models/fangraph_dev/.../schema.yml                  # tag columns (pilot)
```

## YAML conventions

Tag PII columns via per-column `meta`:

```yaml
version: 2

models:
  - name: dim_customer
    columns:
      - name: customer_id
        description: Surrogate key
        # not PII — no meta needed

      - name: email
        description: Customer email address
        meta:
          classification: critical
          pii_category: email

      - name: date_of_birth
        description: Customer DOB
        meta:
          classification: critical
          pii_category: dob

      - name: ip_address
        description: Last login IP
        meta:
          classification: highly_confidential
          pii_category: ip_address
```

Rules:
- `classification` is **required** if any tag is present. Values: `critical`, `highly_confidential`, `confidential`, `public`.
- `pii_category` is **recommended** (helps audit and future tiered roles). Enum: see [`03_classification_catalog.md`](03_classification_catalog.md).
- Columns without `meta.classification` are **not masked**.
- Only `critical` and `highly_confidential` trigger masking in Phase 1.

## Policy location config

Add to `dbt_project.yml`:

```yaml
vars:
  pii_masking_policy_database: GOVERNANCE       # prod default
  pii_masking_policy_schema: MASKING            # prod default

  # During prototype, override per-target or per-engineer:
  # pii_masking_policy_database: FES_USERS
  # pii_masking_policy_schema: ALEX_SOTIS
```

For the prototype phase, override on the command line or in a `profiles.yml`/target-level config so the defaults remain prod-correct:

```bash
dbt run --vars '{pii_masking_policy_database: FES_USERS, pii_masking_policy_schema: ALEX_SOTIS}' ...
```

Or via target-level config in `dbt_project.yml`. Decide during impl based on the team's `dbfork`-style conventions.

After terraform promotes the policies and we cut over, the defaults take effect and no override is needed.

## Macro design

Two macros, both at `fes-airflow/dags/dbt/macros/pii/`:

- **`apply_pii_masking_policies()`** — manifest sweeper. For every `model` / `snapshot` node, finds columns where `meta.classification` is `critical` or `highly_confidential` and emits one `ALTER TABLE … MODIFY COLUMN … SET MASKING POLICY <fqn> FORCE`. Models with no tagged columns produce zero DDL.
- **`get_masking_policy_for_type(data_type)`** — pure lookup. Maps a Snowflake column data_type (STRING / VARCHAR / TEXT / CHAR / NUMBER / INT / BIGINT / DECIMAL / NUMERIC / DATE) to the fully-qualified policy name, using `var('pii_masking_policy_database')` and `var('pii_masking_policy_schema')`. Returns empty string for unmapped types — the caller logs and skips.

Behavior notes:

- **`FORCE`** makes the ALTER idempotent across fresh tables (`create or replace` mat) and persistent tables (incremental). One statement, no INFORMATION_SCHEMA pre-check.
- **Type resolution**: YAML `data_type` (when present) takes precedence; otherwise the macro introspects via `adapter.get_columns_in_relation`. `dbt-snowflake`'s relation cache misses during `run-operation` are handled via an `api.Relation.create` fallback.
- **`execute` guard**: macro is a no-op during parse/compile.
- **Lazy type expansion** (D12): unmapped types log and skip rather than crashing the run. Adding a new type = one mapping entry + one terraform resource, single PR.

## `dbt_project.yml` wiring

```yaml
# at the root of dbt_project.yml
on-run-end:
  - "{{ apply_pii_masking_policies() }}"
```

This runs the macro once at the end of every `dbt run`, `dbt build`, `dbt test`, etc. Confirm during impl: do we want it on `dbt test` too? Probably yes — test runs often follow incremental runs and reassertion is cheap.

## Pilot scope

- Database: `fangraph_dev` only
- Models: start with a single representative model (e.g., a dim that holds customer email/name/phone)
- Iterate until comfortable, then enable across all `fangraph_dev` models, then promote to prod

## Required Snowflake permissions

The dbt service role needs:

- `APPLY` on each masking policy in `GOVERNANCE.MASKING` (granted via terraform — see [`04_terraform.md`](04_terraform.md))
- `OWNERSHIP` or appropriate ALTER privilege on the model tables (already has this)

## Race window note

After `CREATE OR REPLACE TABLE` runs as part of a model materialization, the new table has no masking policy. The on-run-end re-applies. Between those two events (seconds to minutes depending on run size), the table is briefly readable unmasked by anyone with table access.

Mitigations available if this becomes a concern:
1. Add a per-model `post-hook` that applies policies immediately (belt + suspenders with on-run-end).
2. Restrict the dbt service role to be the only role with table access during dbt runs (not practical).
3. Accept the window (current choice — MWAA service runs without concurrent external query traffic).

## Testing the macro

```bash
cd fes-airflow
# Compile only — should produce no DDL since execute is false
make dbt-compile MODELS=path/to/pilot/model

# Run on dev DB — should produce DDL in on-run-end
make dbt-run TARGET=dev MODELS=path/to/pilot/model

# Verify policy attached in Snowflake
snow sql -q "
  SELECT * FROM TABLE(FANGRAPH_DEV.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME=>'FANGRAPH_DEV.SCHEMA.TABLE',
    REF_ENTITY_DOMAIN=>'TABLE'
  ))
"
```

## Open questions for this doc

- Does the FES dbt project consistently populate `data_type` in column YAML? If not, the type-lookup macro needs the introspection fallback.
- Does the on-run-end fire on `dbt test`? Confirm dbt 1.8 behavior.
- How does this interact with the `dbfork` workflow (per-engineer dev databases)? Each fork sees the same global masking policies; ALTERs happen against the fork's tables. Should work as-is, but confirm during pilot.
