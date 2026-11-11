# Cutover PR — Scope and Sequence

**Status:** Draft — single PR with AE collaboration
**Target merge:** ~5 days before cutover (≈ 2026-06-26) so it bakes in dev
**Cutover deploy to prod:** ~2026-07-01 (coordinate with loyalty team)

## Branch strategy

One feature branch off `main`, shared with the analytics engineer. AE adds their commit(s) for the OneCredits ledger rewrite. Single PR, single review, single deploy.

## Files changed

### Data eng changes (us)

1. **`fes-airflow/dags/loyalty/configs.py`**
   - Remove from `POSTGRES_TABLE_CONFIGS`: `journal`, `entry`, `idempotency_keys` (Decision 02).
   - Remove from `OC_POSTGRES_TABLE_CONFIGS`: `loyalty_account`, `program` (Decision 01 — legacy config already covers them).
   - (Leave the other 12 entries; they're the new tables we want.)

2. **`fes-airflow/dags/loyalty/loyalty_postgres_to_s3_ingest.py`**
   - In the new-backend loop: drop the `test_` prefix from `source_table = f"test_{table_name}"` (now just `table_name`), and from the S3 key.
   - Remove the `if config.get_value_for_env(dev=True, prod=False):` gate around the new-backend loop. Loop runs in both dev and prod.
   - Extend `compare_row_counts`: iterate `OC_POSTGRES_TABLE_CONFIGS` too, with composite-key handling for `allocation` (Task #9 — dedupe by `(earn_transaction_id, consume_transaction_id)` before count).

3. **`fes-airflow/dags/create_tables/sql/loyalty/`** — ext table DDLs
   - Either rename or create new files for each of the 12 new tables. Cleanest: create new `create_<table>_ext.sql` files (un-prefixed names, un-prefixed S3 LOCATION), keep the `create_test_*_ext.sql` files (still useful in dev as a sandbox if needed, or delete them in a follow-up).
   - **Practical recommendation:** delete the 12 `create_test_*_ext.sql` files and create 12 new `create_<table>_ext.sql` files. No reason to maintain the test_ sandbox tables in dev once the un-prefixed names work for both envs.
   - Note: `create_tables` DAG is manual-trigger, so this needs to be triggered post-deploy in dev (and again post-deploy in prod at cutover) to actually create/recreate the ext tables.

4. **`fes-airflow/dags/dbt/models/sources/loyalty.yml`**
   - Remove source declarations: `entry_ext`, `journal_ext`, `idempotency_keys_ext` (Decision 02).
   - Add 12 new source declarations under `loyalty__source` (existing source group, schema `SOURCE`).

5. **`fes-airflow/dags/dbt/models/loyalty/source/`** — staging models
   - Delete: `entry.sql`, `journal.sql`, `journal_normalized.sql`, `idempotency_keys.sql` (Decision 02).
   - Add 12 new staging models, one per new-backend table. Follow the legacy template (`pre_hook: refresh_external_table`, `incremental` materialized in `SOURCE` schema, `QUALIFY ROW_NUMBER() PARTITION BY <pk> ORDER BY upload_ts DESC`).
   - **Special case:** the `allocation` staging model needs composite-key dedup `(earn_transaction_id, consume_transaction_id)` instead of single-key. Document the why inline (schema doc F5 / Task #9).
   - **Special case:** `transfer_restriction` has no `created_at`/`updated_at`; its incremental column is `starts_at` (matches the config).
   - Update `source.yaml` schema config entries for the 12 new models.

6. **`fes-airflow/dags/dbt/models/loyalty/one_credits/one_credits.yaml`**
   - Change `tags: ['loyalty']` → `tags: ['fesloyalty']` for `one_credits_loyalty_analytics_ledger` and `one_credits_loyalty_analytics_ledger_fbg` (Decision 03).
   - Leave `loyalty_one_credits_balance_daily_snapshot` alone (`tags: ['daily_9am']`).

### AE rewrites (folded into this PR from PR #2126)

7. **`one_credits_loyalty_analytics_ledger.sql`** — wrapped in `{% if var('oc_ingest_live', false) or target.name == 'dev' %}` Jinja block. NEW branch refs `ref('transaction')`. OLD branch unchanged. Both branches produce the same 12-column schema (with `NULL::NUMBER AS account_id`, `TRUE AS is_user_level_ledger` in the NEW branch).

8. **`loyalty_one_credits_balance_daily_snapshot.sql`** — same Jinja-conditional shape. NEW branch refs `ref('account_balance')`, OLD branch unchanged. Both produce the same 7-column schema.

9. **`one_credits_loyalty_analytics_ledger_fbg.sql`** — unchanged. It does `SELECT ocl.*` so it adapts to whichever branch the ledger picks.

## Dev-validation period (revised per Decision 04)

Two independent toggles. Dev is **fully active** from PR deploy day; prod is dormant until cutover.

| env | `OC_INGEST_LIVE` | `OC_TABLE_PREFIX` | new ingest | legacy journal/entry/idempotency_keys |
|-----|------------------|-------------------|------------|---------|
| dev (PR deploy) | True | `test_` | YES (test_-prefixed) | stopped |
| dev (after loyalty un-prefix dev PG) | True | `""` | YES (un-prefixed) | stopped |
| prod (PR deploy) | False | `""` (unused) | NO (dormant) | unchanged |
| prod (cutover) | True | `""` | YES | stopped |

Cutover-day flip: `OC_INGEST_LIVE` prod from False to True. One line.

See `decisions/04_deferred_prod_activation.md` for the full mechanism (templated DDL prefix, dbt model gating).

## Cutover-day procedure (prod)

Code changes at cutover: **two config flips, no new code**.

1. Loyalty team applies migration 000011 in prod PG. journal/entry dropped, idempotency_keys updated, new bucket-model tables present with un-prefixed names.
2. **PR flips two lines** and is merged:
   - `dags/loyalty/configs.py`: `OC_INGEST_LIVE = config.get_value_for_env(dev=True, prod=True)`
   - `dags/dbt/dbt_project.yml`: `oc_ingest_live: true`
3. Manually trigger `create_tables` DAG in prod — the templated DDLs now resolve to un-prefixed LOCATIONs, creating/replacing the 12 new ext tables.
4. Confirm next scheduled `loyalty_postgres_to_s3_ingest` run succeeds end-to-end. The new-backend ingest tasks are now active; legacy `journal`/`entry`/`idempotency_keys` tasks are now skipped. The Jinja-conditional OneCredits ledger now picks its NEW branch and reads `ref('transaction')` / `ref('account_balance')`.
5. Watch the first 2-3 hourly DAG runs: ingest, new staging models, OneCredits ledger all complete.
6. Spot-check row counts: `LOYALTY.SOURCE.transaction` should have positive row counts and increment hourly.
7. Confirm `compare_row_counts` succeeds for the new tables (may need a one-shot backfill via `loyalty_postgres_backfill=True` first run — see I2 from review).

## Rollback procedure

If cutover-day reveals a blocker:
- The DAG changes are reversible by reverting the PR. Re-run the `create_tables` DAG to recreate the legacy ext tables (DDLs are still in the repo at this point — pre-Phase 2).
- The dropped legacy ingest tasks (`journal`, `entry`, `idempotency_keys`) can't be re-introduced if the PG tables are gone in prod. But the dbt staging models can be restored from the revert — they'd materialize historical data that's still in S3 / ext tables. Newer data is lost but historical is intact.
- For a clean rollback to fully-working legacy state, loyalty team would have to revert migration 000011 — almost certainly not happening. So practical rollback = restore historical access only, not real-time ingest.

## Post-cutover (Phase 2, ~2026-07-22)

Per Decision 02:
- Confirm with AE that historical `LOYALTY.SOURCE.journal`, `entry`, `idempotency_keys` are no longer needed.
- Drop those Snowflake tables + ext tables.
- Delete `create_journal_ext.sql`, `create_entry_ext.sql`, `create_idempotency_keys_ext.sql`.
- Optionally archive the S3 parquet files at `loyalty_postgres/journal/`, `loyalty_postgres/entry/`, `loyalty_postgres/idempotency_keys/`.
