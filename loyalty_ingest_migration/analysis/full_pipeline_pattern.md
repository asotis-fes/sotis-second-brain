# Full Pipeline Pattern (from legacy)

The legacy ingest is **not** "S3 → external table → done." It's a 4-layer pipeline, and the same shape needs to exist for each new-backend table before the analytics engineer can build ledger models on top.

## The 4 layers (per legacy table)

### Layer 1 — Airflow ingest
`SqlToS3Operator` task in `loyalty_postgres_to_s3_ingest`. PG → S3 parquet at:
```
s3://fes-integrations-{env}/loyalty_postgres/<table>/dt={{ ds }}/<table>_{{ ts_nodash }}.parquet
```
Driven by `POSTGRES_TABLE_CONFIGS` (`configs.py`). Incremental column per table. Backfill flag honored.

### Layer 2 — Snowflake external table
External table named `LOYALTY.SOURCE.<TABLE>_EXT` (uppercase, `_EXT` suffix) that reads the S3 parquet via a stage. **DDL lives outside the dbt repo** — likely Terraform or one-off SQL. Need to track that down separately.

Declared in dbt as a source: `models/sources/loyalty.yml`, under `sources: - name: loyalty__source, schema: SOURCE` (lines 31–53). One `tables: - name: <table>_ext` entry per ext table.

### Layer 3 — dbt staging model
File at `models/loyalty/source/<table>.sql`. Every model follows the same template:

```sql
SELECT
    <columns>,
    {{ add_incremental_timestamps() }}
FROM {{ source('loyalty__source', '<table>_ext') }}
{% if is_incremental() %}
    WHERE <incremental_col> >= (SELECT MAX(<incremental_col>) FROM {{ this }})
{% endif %}
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY <unique_key>
    ORDER BY upload_ts DESC
) = 1
```

Configured in `models/loyalty/source/source.yaml` with:
- `tags: ['fesloyalty']` — picked up by the DAG's `loyalty_dbt` TaskGroup
- `materialized: incremental`
- `unique_key` per table
- `pre_hook: "{{ refresh_external_table(table_name='<TABLE>_EXT') }}"` — refreshes ext partition list before reading
- `database: LOYALTY` (prod) / `LOYALTY_DEV` (dev)
- `schema: SOURCE`
- `alias:` if the model file name differs from the desired table name (e.g. `loyalty_account_postgres.sql` aliased to `loyalty_account`)

Final landing: `LOYALTY.SOURCE.<table>` (or aliased name) — native Snowflake table.

### Layer 4 — Downstream models
`models/loyalty/one_credits/*.sql`, etc. `ref()` the staging models. Analytics engineer's territory. Materialized in program-specific schemas like `LOYALTY.ONE_CREDITS`.

## Concrete example chain (one_credits)

```
fes-airflow ingest:        journal table → S3 (loyalty_postgres/journal/...)
Snowflake ext table:       LOYALTY.SOURCE.JOURNAL_EXT
dbt source decl:           loyalty__source.journal_ext
dbt staging model:         models/loyalty/source/journal.sql → LOYALTY.SOURCE.journal
Downstream consumer:       models/loyalty/one_credits/one_credits_loyalty_analytics_ledger.sql
                           → refs journal_normalized (ephemeral over journal), entry,
                             opco_program_account, system_loyalty_account, loyalty_private_fan_id_map
                           → materialized as LOYALTY.ONE_CREDITS.one_credits_loyalty_analytics_ledger
```

## What the legacy `one_credits.yaml` tells us

`models/loyalty/one_credits/one_credits.yaml` defines three downstream models. **All three still depend on legacy-shape staging models** (`journal`, `entry`, `opco_program_account`, `program_account_balance`, `system_loyalty_account`). The analytics engineer has NOT yet swapped these to the new bucket-model staging models.

**Implication for cutover:** at cutover, the legacy staging models stop receiving new rows (Salesforce flow dies). The historical data stays, but `LOYALTY.ONE_CREDITS.one_credits_loyalty_analytics_ledger` will stop accumulating new transactions unless the analytics engineer ships their rewrite at the same time.

**Not our problem to solve** — but worth flagging to coordinate timing. If the analytics engineer ships ledger rewrites on cutover day, they need the new staging models live by then. Which means **we need our pipeline ready before they need it.**

## What needs to exist for each new-backend table

For all 14 tables in `OC_POSTGRES_TABLE_CONFIGS`:

| Layer | Today | Needed by cutover |
|-------|-------|-------------------|
| 1 — Airflow ingest | ✅ exists (dev-only, `test_` prefix) | Strip prefix, ungate from dev-only, use new S3 prefix |
| 2 — Snowflake ext table | ⚠️ user mentions "we have an external table" but only legacy ones are declared as dbt sources — need to verify which/where | One per new table, in the new schema, pointing at the new S3 path |
| 3 — dbt source decl + staging model | ❌ does not exist | One source entry + one staging model per table, following legacy template |
| 4 — Downstream ledger models | ❌ analytics engineer's deliverable | (Not our scope) |

**Our scope to deliver:** layers 1, 2, 3. Layer 4 is the analytics engineer.

The line between "data eng builds staging models" and "analytics eng builds staging models" isn't a hard rule across teams, but the existing `models/loyalty/source/*.sql` files are mechanical 1:1 mirrors of source tables — that's a data-eng-shaped task here. **Worth confirming with the analytics engineer who owns which layer.**

## Open question added (OQ-4 in `../open_questions.md`)

Who creates and maintains the Snowflake external tables? Terraform (`fanapp-terraform`)? One-off SQL? A dbt `external_tables` package? The DDL pattern for the legacy ext tables needs to be located and replicated for the new schema.
