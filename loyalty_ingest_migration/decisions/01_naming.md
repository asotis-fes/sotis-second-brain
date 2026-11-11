# Decision 01 — Naming and Landing Locations

**Date:** 2026-06-25
**Status:** Decided (pending loyalty-team confirmation of no PG collision — see caveat)

## Decision

Land the new-backend ingest **in the same `loyalty.source` schema and the same S3 path** as the legacy ingest. No new schema, no new S3 prefix, no `v2_` / `nc_` table-name suffix.

- **S3:** `s3://fes-integrations[-dev]/loyalty_postgres/<table>/...` (no prefix change)
- **Snowflake ext tables:** `LOYALTY.source.<table>_ext` (no prefix)
- **Snowflake staging models:** `LOYALTY.source.<table>` (no prefix)
- **dbt source group:** existing `loyalty__source` (no new group)

## Why

1. The legacy and new `loyalty_account` / `program` tables have **identical column shapes** (schema doc F4). No semantic reason to disambiguate.
2. The other 12 new-backend tables have no name collision with legacy. They take their bare names.
3. The schema doc strongly implies prod PG already has the un-prefixed `loyalty_account` and `program` — the `test_*` versions in dev are sandbox-only and don't land in prod. Both our ingest configs reading the same physical PG tables is a **config-side dedup problem**, not a true collision.
4. Matches team precedent — every existing loyalty ext/staging table is in `loyalty.source`. A separate schema would be unnecessary infra and break the convention.
5. Cheap rollback for the colliding two: just stop deploying the dropped-prefix DAG change.

## How the collision is actually resolved

Drop `loyalty_account` and `program` from `OC_POSTGRES_TABLE_CONFIGS`. They're already in `POSTGRES_TABLE_CONFIGS`; one ingest task per physical PG table. No race, no overwrite.

## Caveat (resolved 2026-06-25)

Schema doc + ext-table DDL comparison resolves the prod-side concern: legacy and `test_` versions of `loyalty_account` and `program` have identical column definitions, and the schema doc doesn't mark them as changed in migration 000011. PG-side has one un-prefixed table per name at cutover.

## Refinement 2026-06-25 (post-dev-test) — dev needs the test_ data

Dev validation revealed the un-prefixed `loyalty_account` in dev PG is stale; the bucket-model sandbox lives in `test_loyalty_account`. With the un-prefixed table feeding our materialized `loyalty_account` staging, foreign keys from the new `transaction` staging didn't resolve (NULL `private_fan_id` in the ledger).

Resolution: `loyalty_account` and `program` get an `oc_prefix_aware: True` flag in `POSTGRES_TABLE_CONFIGS`. The DAG and `compare_row_counts` apply `OC_TABLE_PREFIX` only to these entries (not the other legacy ones, which have no test_ versions). The two ext-table DDLs (`create_loyalty_account_ext.sql`, `create_program_ext.sql`) use `{{ params.oc_prefix }}` in their LOCATION. In prod (prefix=""), behavior is unchanged. In dev (prefix="test_"), they read the sandbox tables. Same staging-model targets (`LOYALTY.SOURCE.loyalty_account`, `LOYALTY.SOURCE.program`) in both envs.

Still no double-ingestion in prod, so the original Decision 01 conclusion stands; this is just an env-aware refinement of which PG row source we read.

## What changes if we need to relocate S3 data later

User noted: if pre-cutover we discover we need to wipe/relocate the existing S3 data at `loyalty_postgres/<table>/` (e.g., schema-shape divergence for one of the new tables that we missed), we can move the historical objects to an archive path before flipping the ingest. Cleaner than building dual ingest logic.

## Implications

- DAG change is minimal: strip `test_` prefix in `OC_POSTGRES_TABLE_CONFIGS` loop, drop the `loyalty_account` and `program` entries from it, remove the `if dev` gate.
- Ext tables: rename the 14 `create_test_*_ext.sql` files to `create_*_ext.sql` (or create new files; old ones may be deleted post-cutover). Strip `test_` from the SQL bodies (ext table name + LOCATION path). Since `create_test_*` is gated out of prod, removing the `test_` prefix means they'll run in prod.
- Staging models: 12 new files in `models/loyalty/source/` (one per non-colliding new-backend table). No new file for `loyalty_account` or `program` — legacy staging models already serve those.
- Source declaration: add 12 new `tables:` entries under existing `loyalty__source` group in `models/sources/loyalty.yml`.

## Unblocks

- Task #1 (collision strategy) — resolved by this decision
- Task #2 (productionize DAG) — can now proceed
- Task #7 (this decision itself) — done

## Doesn't unblock yet

- Task #4 (staging-model ownership) — still waiting on analytics engineer (OQ-5).
- Task #8 (remove dropped tables from legacy config) — independent, can ship anytime.
