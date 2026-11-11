# Loyalty Ingest Migration

Context folder for finishing the Postgres → S3 → Snowflake ingestion pipeline for the new Loyalty backend service (replacement for Salesforce Loyalty Cloud / Data Cloud).

## ⚠️ Instructions for Claude

**Keep important context in files in this folder, not in the conversation context window.** This work will span multiple sessions; the conversation may be `/clear`-ed or `/compact`-ed.

**What to write to files (durable):**
- Decisions made and *why* — go in `decisions/`
- Investigation findings (e.g. table name overlaps, schema diffs, env-config quirks) — go in `analysis/`
- Migration plan + cutover checklist — go in `plans/`
- Reusable SQL or scripts (verification queries, diffs) — go in `queries/`
- Snapshots of the "current state" that future-you will need to re-read — go in `context/`

**What NOT to write:**
- Every tool result, every transient grep output, conversational back-and-forth.
- Step-by-step narration of what was done — the git log and the actual code changes are the source of truth.
- Status updates ("now working on X") — those are ephemeral.

**Rule of thumb:** if a future session would need it to pick up where this one left off, write it down. If it's just commentary, don't.

**When to update `0_status.md`:** at the end of any session where state moved forward — what's done, what's next, what's blocked.

## Initial Prompt (verbatim, for record)

> I am a data engineer on a data team. We have a separate engineering team for our Loyalty program. This loyalty team was originally using salesforce loyalty cloud, and is migrating to their own backend service. We would receive data from loyalty cloud (or I think technically data cloud did the transfer to snowflake, but it originated from loyalty cloud), and built ledgers on top for the 3 different loyalty programs, one credits, fancash, and tier points. Their new backend service retains this data in a postgres database. We need to pull the data from their postgres into s3, then into snowflake. There is a different analytics engineer working on recreating our existing ledgers based on the new schema. Your task here is to help me finish out the data ingestion pipeline, which is already mostly in place.
>
> Main DAG: `/Users/alex.sotis/repos/fes-airflow/dags/loyalty/loyalty_postgres_to_s3_ingest.py`
> Config: `/Users/alex.sotis/repos/fes-airflow/dags/loyalty/configs.py`
>
> Current state: new schemas are available in their dev postgres, with `test_` prefix. Our DAG ingests those tables into S3 only, and we have an external table that queries S3. No job currently loads these into native Snowflake tables. We need to make sure when we go live to prod in a week, the DAG is ready to ingest prod data, and the tables will not have `test_` prefix. Also, we need to check if any of the new tables have the same name as the old tables, and if so, figure out how to name the new ones so there is no overlap.

## Key Facts (load-bearing)

- **Go-live target:** ~1 week from 2026-06-24 (so roughly 2026-07-01).
- **Old source:** Salesforce Loyalty Cloud → Data Cloud → Snowflake. We built ledgers on top.
- **New source:** Loyalty team's own Postgres backend. We pull PG → S3 → Snowflake.
- **Three programs riding on this:** OneCredits, FanCash, Tier Points.
- **Division of labor:**
  - **Me (FES Data, this work):** finish the ingestion pipeline (PG → S3 → Snowflake native tables).
  - **Another analytics engineer (separate work):** rebuilding the 3 ledgers on top of the new schema.
- **Current pipeline state:**
  - DAG ingests `test_`-prefixed dev tables to S3.
  - External table queries S3.
  - No native Snowflake load job exists for the new tables yet.
- **Two table config lists in `configs.py`:**
  - `POSTGRES_TABLE_CONFIGS` — the existing/legacy (Loyalty Cloud-shape) ingestion. Drives load tasks + dbt + `compare_row_counts`. Production today.
  - `OC_POSTGRES_TABLE_CONFIGS` — the NEW backend (OneCredits / FanCash bucket model). **Dev-only**, source resolved as `test_<table>` at runtime, NOT fed into dbt or row-count checks.
- **Schema source for new backend:** `fanatics-gaming/fes-loyalty` PR #291 (`scripts/test_data/000_schema.sql`). Credits program + BASE entry type only. Excluded: idempotency_keys, job_queue, all tier tables, legacy journal/entry, account/opco tables.
- **Related folder in this repo:** `loyalty_new_service/` — the ledger reconstruction draft (the other analytics engineer's domain). Not this folder's scope, but cross-reference for schema understanding.

## Open Questions / What Needs to Happen Before Prod

(Tracked in detail in `plans/0_cutover_plan.md` once drafted. High-level for orientation:)

1. **Drop the `test_` prefix** in the new-backend ingest path when prod is enabled — currently hardcoded in the `if dev` block of the DAG.
2. **Table name collision check** — do any tables in `OC_POSTGRES_TABLE_CONFIGS` collide with tables in `POSTGRES_TABLE_CONFIGS`? (`loyalty_account` and `program` definitely do — they appear in both lists.) Decide naming strategy so the two ingests don't fight over the same Snowflake/S3 paths.
3. **Native Snowflake tables** — currently only an external table over S3. Need a job (likely dbt or direct COPY) to materialize native tables.
4. **Row-count parity for new tables** — `compare_row_counts` only iterates `POSTGRES_TABLE_CONFIGS`. Decide whether/how to extend it to the new tables once they have Snowflake-side models.
5. **Connection ID** — DAG currently uses `loyalty_postgres_dev` in dev, `loyalty_postgres` in prod. Confirm the prod conn points at the new backend's prod PG, not the old one.
6. **Are the legacy `POSTGRES_TABLE_CONFIGS` tables still ingested post-cutover, or do they retire?** Affects whether we need to coexist or can replace.

## Folder Structure (Table of Contents)

```
loyalty_ingest_migration/
├── README.md                       ← you are here
├── 0_status.md                     ← rolling session status; update at end of each session
├── context/                        ← background snapshots, system understanding
│   └── (e.g. dag_overview.md, schema_notes.md)
├── analysis/                       ← investigation outputs
│   └── (e.g. table_name_collisions.md, schema_diff.md)
├── decisions/                      ← decisions log (one decision per file or one consolidated doc)
│   └── (e.g. 01_naming_strategy.md)
├── plans/                          ← migration plan + cutover checklist
│   └── (e.g. 0_cutover_plan.md)
└── queries/                        ← reusable SQL (verification, diffs, etc.)
```

Subfolders are created on demand. Add new top-level subfolders only if the existing five genuinely don't fit.

## Cross-References

- DAG: `/Users/alex.sotis/repos/fes-airflow/dags/loyalty/loyalty_postgres_to_s3_ingest.py`
- Config: `/Users/alex.sotis/repos/fes-airflow/dags/loyalty/configs.py`
- Incremental SQL template: `/Users/alex.sotis/repos/fes-airflow/dags/loyalty/sql/loyalty_postgres_incremental.sql`
- Ext-table DDLs (legacy + test_): `/Users/alex.sotis/repos/fes-airflow/dags/create_tables/sql/loyalty/`
- Ext-table DAG runner: `/Users/alex.sotis/repos/fes-airflow/dags/create_tables/create_tables.py`
- dbt source declarations: `/Users/alex.sotis/repos/fes-airflow/dags/dbt/models/sources/loyalty.yml`
- dbt staging models (legacy): `/Users/alex.sotis/repos/fes-airflow/dags/dbt/models/loyalty/source/`
- dbt OneCredits downstream models: `/Users/alex.sotis/repos/fes-airflow/dags/dbt/models/loyalty/one_credits/`

External:
- **Schema reference (loyalty team, schema2 branch)**: https://github.com/fanatics-gaming/fes-loyalty/blob/schema2/docs/SCHEMA_DATA.md
- Live Lucidchart ERD (link inside schema doc): https://lucid.app/lucidchart/3faa0c14-2ae9-4371-8e99-605e185657b3
- Schema source (external repo): `fanatics-gaming/fes-loyalty` → `scripts/test_data/000_schema.sql` (PR #291)

This repo:
- Ledger reconstruction work (separate scope): `loyalty_new_service/`
