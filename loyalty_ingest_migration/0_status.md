# Status

Rolling status. Update at the end of any session where state moved forward.

## Current State (2026-06-24)

**Done:**
- Folder scaffolded with README and TOC.
- Initial read of DAG + configs complete.
- `open_questions.md` created with OQ-1 (legacy retire?), OQ-2 (PG-side name collision), OQ-3 (row-count check coverage).
- `analysis/table_name_collisions.md` drafted — recommends Option 2 (separate S3 prefix + separate Snowflake schema, e.g. `loyalty_postgres_v2/` → `LOYALTY.SOURCE_V2`) as the default while OQ-1/OQ-2 resolve.
- Confirmed: prod PG conn already established; cutover = old Salesforce stops, new tables appear un-prefixed in same prod PG.
- Confirmed: dbt is the path for native Snowflake tables (hourly TaskGroup already in the DAG).
- Confirmed: OneCredits-only for this cutover; Tier Points + FanCash later via `program_id` filter on same physical tables.

**Next up (in order):**
1. Decide on naming (Task #7): Snowflake schema + S3 prefix + dbt source group for the new backend. Pending user/team input.
2. With analytics engineer (OQ-5): clarify who authors the 14 new staging models.
3. Confirm with loyalty team (Q1): in-place schema change at cutover (no PG-side collision) or coexistence?
4. Draft `plans/0_cutover_plan.md` — concrete DAG diff + ext-table DDL + staging models + checklist + rollback path.

**Blocked / waiting on others:**
- OQ-2 / Q1 (loyalty team) — what does prod PG look like at the cutover moment.
- OQ-5 / Q3 (analytics engineer) — staging-model ownership and cutover timing.

## Key insights so far

### 2026-06-24 — the pipeline is 4 layers, not 2

Legacy ingest is **Airflow → S3 → ext table → dbt staging model → downstream**. For each of the 14 new-backend tables we need an ext table in Snowflake, a source declaration in `models/sources/loyalty.yml`, and a staging model in `models/loyalty/source/`. See `analysis/full_pipeline_pattern.md`. **Layer 2 (ext tables) is already done in dev** — 14 `create_test_*_ext.sql` files exist at `fes-airflow/dags/create_tables/sql/loyalty/`. Layer 3 (sources + staging models) is not done.

### 2026-06-25 — program scope reframe

Cutover is **OneCredits only**. FanCash and Tier Points are still on Salesforce Loyalty Cloud, NOT in `POSTGRES_TABLE_CONFIGS`. Their migrations to the new PG backend come later, separately, and are larger. The cutover is a schema change within OneCredits' existing Postgres (journal/entry → transaction bucket model). The new schema is multi-program-ready so when FanCash/TierPoints migrate later they land in the same tables filtered by `program_id`. See `context/program_scope_clarification.md`.

### 2026-06-25 — schema doc surprises

- `journal` and `entry` are **dropped** in migration 000011 → legacy load tasks **will fail** post-cutover unless removed first (Task #8).
- `idempotency_keys.updated_at` is **removed** → incremental config breaks; drop the table from legacy config.
- `loyalty_account` and `program` have **identical shapes** in legacy and new schemas — the collision is name-only, not shape-level.
- `allocation` requires consumer-side dedup on `(earn_transaction_id, consume_transaction_id)` — staging model can't use the standard single-key template (Task #9).
- `opco_program_account`, `program_account_balance`, `system_loyalty_account`, `operating_company` remain alive at cutover but are slated for future deprecation. Their load tasks keep running for now.

See `context/schema_doc_findings.md` for the full cross-reference.

## Quick Observations from First Pass

- The new-backend ingest is gated by `config.get_value_for_env(dev=True, prod=False)` — meaning today the only path that runs in prod is the legacy `POSTGRES_TABLE_CONFIGS` loop. Prod cutover means flipping that gate AND removing the `test_` prefix.
- `test_` prefix is applied via `source_table = f"test_{table_name}"` (DAG line ~172) and propagates into the S3 key. Easy to strip; less easy to coordinate with the external table definition that points at the prefixed S3 path.
- `compare_row_counts` ONLY iterates `POSTGRES_TABLE_CONFIGS`. New backend tables get no parity check today. That has to change before prod, or we go to prod blind on the new path.
- No Snowflake-side native tables for the new backend yet — only the external table over S3. The dbt TaskGroup runs against the `fesloyalty` tag, but no models exist for the new schema (analytics engineer is building those).

## Recent Sessions

**2026-06-24** — Created `loyalty_ingest_migration/` scaffold and READ the DAG + configs end-to-end. Identified two name collisions (`loyalty_account`, `program`) between legacy and new configs, and confirmed the new-backend path is dev-only and gated. Returning to user with starter questions before drafting collision analysis and cutover plan.
