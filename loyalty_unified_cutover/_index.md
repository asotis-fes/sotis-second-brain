# Loyalty Unified Ingest Cutover

Move **Tier Points** (program_id=2) and **One Credits** (program_id=3) dbt sources off the two
legacy per-program ingest DAGs and onto the single `loyalty_postgres_unified_to_s3` DAG, then
retire the legacy DAGs. FanCash (pid=1) already flows through unified for other paths.

## Why
The legacy `loyalty_postgres_to_s3_ingest` (OneCredits) OOMs table-by-table (SqlToS3Operator loads
whole window into pandas; many tables have no program_id to filter). When it fails, the `fesloyalty`
dbt job never triggers, so `loyalty_transaction` (tag fesloyalty) goes stale — which silently stales
the **tier** ledger too, since `tier_points_ledger_v2` reads `ref('loyalty_transaction')`. The unified
DAG streams `COPY→CSV` (bounded memory, no OOM, all programs) and dissolves that coupling.
See [[reference_loyalty_ingest_dag_topology]] in memory.

## Decisions
- **D1 — dbt trigger**: unified DAG fans out to BOTH existing dbt Cloud jobs after ingest —
  fesloyalty (prod `70437463793547`) + tierpoints (prod `70437463802429`). (Not a combined job.)
- **D2 — cutover style**: DIRECT — repoint sources + wire trigger + retire both legacy DAGs in the
  same change. Gated on full per-table parity being green first (no parallel-run safety net).

## Current state (2026-09-30)
- Legacy DAGs: `loyalty_postgres_to_s3_ingest.py` (OC, pid=3, +legacy tables), `loyalty_postgres_tier_to_s3_ingest.py`
  (tier, pid=2; already chunked). Both write PARQUET → `loyalty_postgres/` → `LOYALTY.SOURCE.<t>_ext`.
  Tier DAG imports `transaction` cfg from OC's `OC_POSTGRES_TABLE_CONFIGS`.
- Unified DAG `loyalty_postgres_unified_to_s3.py` (cfg `loyalty_unified_config.py`): streaming COPY→CSV
  → `loyalty_source/` → `LOYALTY.SOURCE.<t>_uni_ext`. All programs, no filter. Prod `20 * * * *`.
  **NO dbt trigger** (ends at ingest map). Running in parallel since ~2026-09-09; `_uni_ext` refreshed
  current (last refresh ~15:20 UTC today).
- Recent cleanup already merged: dropped 13 unused loyalty tables from OC DAG + dbt (fes-airflow #2382/#2384,
  dbt-fes-ae #409/#429; Jira DATA-18404). OC DAG now ingests only transaction + 4 blocked OC tables.

## Feasibility (investigated 2026-09-30) — VIABLE
- All 10 in-scope tables have a live, valid `_uni_ext` in `loyalty_unified_config.py`; tier tables
  included → tier can fully move.
- Schema parity: `_uni_ext` DDLs re-map positional CSV back to the SAME column names as parquet `_ext`
  (verified identical on `transaction`). dbt models select by name.
- **Data parity — transaction (2026-09-27, distinct id by program): EXACT.** pid=2 1,717,040==1,717,040;
  pid=3 52==52. (Legacy carries re-pull dups; dedup-on-id resolves identically.) pid=1 (4.57M) uni-only, expected.
- 9/10 model repoints are one-line `source()` swaps. Only `program_account_balance` needs a body edit
  (drop dead `available_minor`/`pending_minor` coalesce operands — absent in `_uni_ext`).
  `account_balance_uni_ext` has an unused extra `lifetime` col — harmless.
- Seam is safe because staging models are `materialized: incremental` (retain history; merge forward
  from source on MAX-watermark) — `_uni_ext` history coverage is a non-issue; only the forward feed matters,
  which transaction parity validates.

## Build plan
1. **dbt-fes-ae PR** — add 10 `_uni_ext` source decls to `models/sources/loyalty.yml`; repoint 10 model
   `source()` args `_ext`→`_uni_ext`; fix `program_account_balance.sql` coalesce.
2. **fes-airflow PR** — wire `create_dbt_cloud_task_group` for BOTH jobs onto unified DAG after the ingest
   map; remove the two legacy DAGs + their now-unused `create_<t>_ext.sql` DDLs (direct cutover).
3. **Merge order (matters!)**: dbt PR FIRST (models read `_uni_ext`, still triggered by legacy DAGs which
   feed `_uni_ext`-refreshed models), THEN fes-airflow PR (unified triggers dbt; legacy retired). Avoids a
   stale-`_ext` window.
4. Pre-merge gate: per-table parity + spot-check 3 JSON/VARIANT cols (transaction.metadata,
   program_account_balance.metadata, tier_account_override.extra_data).

## Open items
- Per-table parity for the other 9 tables (running) — see parity.md.
- Confirm `tierpoints` dbt Cloud job selector (does it use `+` ancestors? affects whether it rebuilds loyalty_transaction).
- `snowflake_service_user` must own/refresh `_uni_ext` (already does — unified DAG runs).

## Files
- fes-airflow: `dags/loyalty/loyalty_postgres_unified_to_s3.py`, `loyalty_unified_config.py`,
  `loyalty_postgres_to_s3_ingest.py`, `loyalty_postgres_tier_to_s3_ingest.py`, `dags/create_tables/sql/loyalty/create_*_ext.sql`
- dbt-fes-ae: `models/sources/loyalty.yml`, `models/loyalty/source/*.sql`
