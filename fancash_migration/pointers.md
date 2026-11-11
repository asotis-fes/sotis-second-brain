# Pointers (live)

These point at **other project folders** and **repo code**. The sibling loyalty projects are
maintained by other Claude sessions and update as their work moves — **re-read them for current
context rather than copying their contents here.** Whatever we decide in *this* project supersedes
them.

## Sibling project folders (reference / precedent)

| Program | Folder | What it holds |
|---------|--------|---------------|
| OneCredits | `../loyalty_ingest_migration/` | The PG→S3→Snowflake ingestion migration pattern (completed, prod cutover 2026-07-06). Start here for the operational shape we mirror. |
| OneCredits | `../loyalty_new_service/` | Source→ledger field mapping / ledger v2 draft (the other AE's domain, useful for schema understanding). |
| Tier Points | `../loyalty_tier_points_migration/` | 2nd migration; test_-prefixed dev tables, dormant-deploy + flip-2-config-values cutover pattern. |
| Tier Points | `../loyalty_tier_points_s3_parallel_processing_data_dump/` | One-time Snowflake→S3 `COPY INTO` historical export (v4 de-collide model). **Closest analog to our Task 2 backfill export.** |

## Repo / code paths (in `~/repos`)

**fes-airflow** — ingestion DAG code:
- **LIVE (unified, D-9, PR #2358 merged):** `fes-airflow/dags/loyalty/loyalty_postgres_unified_to_s3.py`
  + config `fes-airflow/dags/loyalty/loyalty_unified_config.py` (`{table: {incr_col, cols}}`, 24 tables).
  Ext-table DDLs: `dags/create_tables/sql/loyalty/create_*_uni_ext.sql`. Test: `tests/dags/test_loyalty_unified.py`.
- **Legacy (being retired at cutover):** `loyalty_postgres_to_s3_ingest.py` + `configs.py`
  (`POSTGRES_TABLE_CONFIGS` legacy Loyalty-Cloud shape; `OC_POSTGRES_TABLE_CONFIGS` bucket model).
- Ext-table DAG runner: `fes-airflow/dags/create_tables/create_tables.py`

**dbt-fes-ae** — FanCash ledger:
- Live ledger: `models/loyalty/fancash/ledger/loyalty_analytics_ledger_stage.sql` (+ `_final`, redeem/mapper).
- **Dual-write cutover (D-11, PR #260, active):** `models/loyalty/fancash/dual_write/**`
  (`dual_write_*` tables) + native sources `models/loyalty/source/dual_write/{transaction,allocation,capture_event,void_auth_event}_uni.sql`.

## External
- Backfill ticket: https://betfanatics.atlassian.net/browse/ENTDATA-2021
- Reason codes: https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/2771091472/Reason+codes
- fes-loyalty schema doc (new backend): `fanatics-gaming/fes-loyalty` → `docs/SCHEMA_DATA.md`
