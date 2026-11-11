# External Table DDL Pattern

Answer to OQ-4 / Q7.

## Where DDLs live

`fes-airflow/dags/create_tables/sql/loyalty/`

One `.sql` file per ext table. Naming: `create_<table>_ext.sql`. Both legacy and new-backend (`test_`) DDLs sit side-by-side in the same folder.

## What runs them

`fes-airflow/dags/create_tables/create_tables.py` — manual-schedule DAG (tags `["snowflake", "adhoc"]`). Iterates every `.sql` file in `dags/create_tables/sql/<folder>/` and runs it via `SQLExecuteQueryOperator` against `snowflake_service_user`. Manual re-trigger after DDL changes.

## DAG already gates `create_test_*` out of prod

```python
# create_tables.py:167-169
if config.get_env() == "prod" and file.startswith("create_test_"):
    # Skip dev-only sandbox tables in prod (e.g. fes-loyalty PR 291 test data)
    continue
```

So today, in prod, only the 8 legacy ext tables are created. The 14 `create_test_*_ext.sql` files run only in dev.

## DDL Template

```sql
CREATE OR REPLACE EXTERNAL TABLE {{ params.target_db }}.source.<NAME>_ext (
    <col> <TYPE> AS (value:<col>::<TYPE>),
    ...
    source_file_name STRING AS (metadata$filename::STRING),
    upload_ts TIMESTAMP_NTZ AS (TO_TIMESTAMP(REPLACE(REGEXP_SUBSTR(metadata$filename, '\\d{8}T\\d{6}'), 'T', ''), 'YYYYMMDDHH24MISS')),
    upload_date DATE AS (TO_DATE(REPLACE(REGEXP_SUBSTR(metadata$filename, '\\d{8}T\\d{6}'), 'T', ''), 'YYYYMMDDHH24MISS'))
)
LOCATION = @{{ params.stage }}/loyalty_postgres/<table>
FILE_FORMAT = (TYPE = PARQUET)
PATTERN = '.*\\.parquet';
```

Bindings come from `folder_config["loyalty"]` in `create_tables.py`:
- `target_db`: `LOYALTY_DEV` in dev, `LOYALTY` in prod
- `stage`: `fes_integrations_dev.stage.fes_integrations_dev_stage` in dev, `fes_integrations.stage.fes_integrations_prod_stage` in prod

Final destination: `LOYALTY.source.<name>_ext` reading from `s3://fes-integrations[-dev]/loyalty_postgres/<table>/...`.

## Key precedent: same schema, prefix-based disambiguation

**Both** legacy and new-backend ext tables live in the same `source` schema (lowercase). Today's disambiguation is the `test_` prefix on:
- The ext table name (`LOYALTY_DEV.source.test_loyalty_account_ext` vs `LOYALTY_DEV.source.loyalty_account_ext`)
- The S3 location (`@stage/loyalty_postgres/test_loyalty_account` vs `@stage/loyalty_postgres/loyalty_account`)

DDL comments call it a "Dev sandbox over the test_ parquet path" / "Distinct from existing loyalty_account_ext (prod-shape path)" — wording suggests `test_` was a dev placeholder, not a permanent name. This **changes the collision recommendation** — see `../analysis/table_name_collisions.md`.

## State of the 14 new-backend ext tables today

All 14 exist in `LOYALTY_DEV.source` as `test_*_ext`. In prod today: none. At cutover, all 14 need prod equivalents.

⚠️ = collides with a legacy ext table that exists in prod.

| Table | Ext table (dev) | S3 path (dev) |
|-------|-----------|---------|
| loyalty_account ⚠️ | `test_loyalty_account_ext` | `loyalty_postgres/test_loyalty_account/` |
| program ⚠️ | `test_program_ext` | `loyalty_postgres/test_program/` |
| bucket_type | `test_bucket_type_ext` | `loyalty_postgres/test_bucket_type/` |
| bucket | `test_bucket_ext` | `loyalty_postgres/test_bucket/` |
| account_balance | `test_account_balance_ext` | `loyalty_postgres/test_account_balance/` |
| transfer_restriction | `test_transfer_restriction_ext` | `loyalty_postgres/test_transfer_restriction/` |
| transaction | `test_transaction_ext` | `loyalty_postgres/test_transaction/` |
| allocation | `test_allocation_ext` | `loyalty_postgres/test_allocation/` |
| allocation_remaining | `test_allocation_remaining_ext` | `loyalty_postgres/test_allocation_remaining/` |
| void_remaining | `test_void_remaining_ext` | `loyalty_postgres/test_void_remaining/` |
| auth_hold | `test_auth_hold_ext` | `loyalty_postgres/test_auth_hold/` |
| capture_event | `test_capture_event_ext` | `loyalty_postgres/test_capture_event/` |
| void_auth_event | `test_void_auth_event_ext` | `loyalty_postgres/test_void_auth_event/` |
| auth_bucket_hold | `test_auth_bucket_hold_ext` | `loyalty_postgres/test_auth_bucket_hold/` |

## Pipeline state recap (revised)

For the 14 new-backend tables:
- ✅ Layer 1 (Airflow ingest to S3) — exists, dev-only, uses `test_` prefix
- ✅ Layer 2 (Snowflake ext table) — exists in dev with `test_` prefix; prod versions need creation at cutover
- ❌ Layer 3 (dbt source declarations + staging models) — not yet
- ❌ Layer 4 (downstream models) — analytics engineer's scope
