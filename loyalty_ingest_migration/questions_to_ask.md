# Questions to Ask (2026-06-25)

Compiled question list for coworkers. Move answers into `decisions/` or update `open_questions.md` as they come in.

## Loyalty team engineer (their PG, their backend)

### Q1 — Confirm no PG-side collision ✅ RESOLVED (no need to ask)

Schema doc + ext-table DDL comparison gives a clear answer:
- `loyalty_account` columns: schema doc + `create_loyalty_account_ext.sql` + `create_test_loyalty_account_ext.sql` all match (`loyalty_id`, `created_at`).
- `program` columns: same in all three sources.
- Schema doc doesn't mark these as new/changed in migration 000011; deprecation list excludes them.

The `test_` prefix in dev PG is PR 291 sandbox naming. For the bucket-model tables it's a new physical table; for `loyalty_account` and `program` the dev sandbox is just a mirror of the existing identity/reference tables. At cutover, prod PG has one un-prefixed `loyalty_account` and one un-prefixed `program` — same as today, same shape. The "collision" in our DAG config is purely our own (two configs reading the same physical PG tables); Decision 01 resolves it.

### Q2 — Salesforce/Data Cloud write path

When does the Salesforce → legacy-table feed actually stop? Hard cutover at a specific time on go-live day, or phased shutdown? Affects when the legacy `compare_row_counts` check would start failing.

## Analytics engineer (FES Data, building new ledgers)

### Q3 — Staging model ownership ✅ ANSWERED

Data eng owns PG → S3 → Snowflake end to end, including the dbt staging models (Layer 3) that materialize external tables into native tables. AE picks up downstream of the materialized tables. New tables land in the same `LOYALTY.SOURCE` schema. Row-count check is on us.

### Q4 — Cutover timing of the ledger rewrite ✅ ANSWERED

Same PR. AE adds their commit(s) to our shared feature branch. Single deploy, bakes in dev for several days before prod cutover. Decision 03 also moves the OneCredits ledger models into this DAG (hourly cadence via `fesloyalty` tag).

### Q5 — Target schema for new ledger models

What Snowflake schema do you plan to land the rewritten ledger models in? Same `LOYALTY.ONE_CREDITS`, or somewhere new? Helps me decide what schema to land the staging surface in.

### Q6 — Draft work to look at

Have you drafted any new staging models, ext tables, or source declarations on a branch I should pull? Avoid duplicate work.

## DataOps / Terraform owner

### Q7 — External table DDL pattern (maps to OQ-4) ✅ ANSWERED

**Answer (2026-06-25, from user):** DDLs at `fes-airflow/dags/create_tables/sql/loyalty/`. Runner: `create_tables.py` DAG (manual schedule, `["snowflake", "adhoc"]` tags). Already gates `create_test_*` out of prod. All 14 new ext tables exist in dev as `test_*_ext`. See `context/ext_table_ddl_pattern.md`.

---

## Answers (fill in as they come back)

- Q1: _pending_
- Q2: _pending_
- Q3: _pending_
- Q4: _pending_
- Q5: _pending_
- Q6: _pending_
- Q7: _pending_
