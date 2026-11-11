# FanCash Migration — Scylla/Loyalty-Cloud → new Postgres backend (program_id = 1)

> **Standing directive:** Keep these files updated as work progresses. Treat them as the
> source of truth across sessions. Nothing under `projects/` is ever committed (gitignored).
> **This session's decisions supersede** whatever was recorded for the OneCredits / Tier Points
> migrations — those folders are reference/precedent only.

## High-level context / goal

Fanatics runs **three loyalty programs** — **FanCash**, **OneCredits**, and **Tier Points** —
each originally built in a separate engineering stack. All three are converging onto **one
backend service** backed by **Postgres**. The ingestion path is already built:
**Postgres → S3 → Snowflake** via an Airflow DAG in `fes-airflow`.

Migration order:
- **OneCredits** — migrated first, live in prod, no issues. (ref `../loyalty_ingest_migration`, `../loyalty_new_service`)
- **Tier Points** — mid-migration; parallel processing running, about to flip source-of-truth to the new tables. (ref `../loyalty_tier_points_migration`, `../loyalty_tier_points_s3_parallel_processing_data_dump`)
- **FanCash** — **this project.** `program_id = 1`.

**Scope for this session:** the **ingestion portion only**. A different analytics engineer owns
the dbt ledger rewrite. We reference the dbt code (the FanCash ledger is a generically-named
model like `loyalty_analytics_ledger` in **dbt-fes-ae**) only to understand how our ingestion
impacts ledger logic.

## Tasks (see `plan.md` for detail)

1. **[FIRST] Investigate data shape via dev ingest** — ingest the limited FanCash transactions
   present in **Postgres dev** so we can compare the two systems (old vs new) and learn the real
   shape of `program_id = 1` data in the new schema.
2. **Historical backfill export (ENTDATA-2021)** — write a query that transforms our source
   (**Scylla** / loyalty-cloud) into the **new Postgres `transaction` schema**, and land it in
   **S3** so the Loyalty engineers can backfill their tables with history (~2B transactions).
   Full column mapping captured in `backfill_mapping.md`.
3. **Full ingestion pipeline for `program_id = 1`** — wire FanCash through the existing
   PG → S3 → Snowflake DAG (same operational shape as OneCredits / Tier Points).

> **Ordering note (from framing):** investigating the data shape by ingesting the dev data is
> the **first step** — it informs both the backfill transform and the full pipeline.

## Key pointers
- Ingestion DAG + configs: `fes-airflow/dags/loyalty/` (see `pointers.md` for exact paths).
- FanCash ledger (impact reference only): **dbt-fes-ae** (`loyalty_analytics_ledger`).
- Backfill ticket: **ENTDATA-2021** — https://betfanatics.atlassian.net/browse/ENTDATA-2021
  (assignee: Alex Sotis; reporter: Anna Smith; status: To Do; P3).
- Reason-code mapping (backfill): Confluence 2771091472 — ask **Will Mack** / **Christine Nichols**
  for the final new-reason list.
- Cross-project + repo pointers (live, updated by other sessions): `pointers.md`.

## Table of Contents

| File | Purpose |
|------|---------|
| `_index.md` | This file — context, goal, tasks, TOC, status |
| `plan.md` | The three tasks broken into concrete steps |
| `pointers.md` | Pointers to sibling project folders (live) + repo/code paths |
| `backfill_mapping.md` | ENTDATA-2021 Scylla → PG `transaction` column & status mapping |
| `findings.md` | Investigation findings (dev ingest, schema diffs, data shape) |
| `decisions.md` | Decisions made (with why) + open questions |
| `progress.md` | Running session log |
| `unified_cutover_runbook.md` | Parallel-run + Tier→OC→FanCash cutover steps (Scope A) |
| `memory_benchmark.md` | Streaming-COPY vs pandas-chunk peak-memory benchmark (evidence for D-3) |

## Status
- **Phase:** ✅ **LIVE IN PROD** — unified ingest merged (**PR fanatics-gaming/fes-airflow#2358**, 2026-09-08)
  and running the isolated parallel-run. Now: watch `_uni_ext` output for a few days, then the dbt source repoint.
- **What shipped (Scope A, D-9):** ONE DAG `loyalty_postgres_unified_to_s3` — per table, `ingest_table` streams
  `COPY … TO STDOUT` off the loyalty reader → CSV to the isolated `loyalty_source/<t>/` prefix → targeted
  `ALTER EXTERNAL TABLE <t>_uni_ext REFRESH`. **dbt keeps the dedup** (QUALIFY on `upload_ts`); no native tables
  / MERGE. Prod `20 * * * *`, `retries=0`, `max_active_tasks` dev=1/prod=3.
- **Config (D-10 + configs.py shape):** single hand-maintained file `dags/loyalty/loyalty_unified_config.py` =
  `{table: {incr_col, cols}}` for the 24 tables; Snowflake types live only in the `create_*_uni_ext.sql` DDLs.
  The generated manifest + `information_schema` generator were removed as overkill. `test_loyalty_unified.py`
  asserts `cols` ⇄ ext-DDL positional match.
- **Prod schema verified (2026-09-08):** every `cols` column + `incr_col` exists in prod → no COPY failure.
  Two `incr_col` follow-ups pending loyalty's prod catch-up (`auth_bucket_hold`, `transfer_restriction`) — see **D-10**.
- **dbt side (Session 8, 2026-09-30) — D-11:** the source repoint landed on **dbt-fes-ae PR #260**
  (`sm/migrated-loyalty-ledger`, Sean McClure) as a **dual-write parallel run**: native `_uni` source tables over
  the CSV externals + `dual_write_*` ledger tables, tagged `daily`/`fancash_dual_write`, runs daily. My
  contributions (native sources, dual-write restructure, CI `full_refresh_prevention` prod-gate, 733-line
  comment cleanup) all pushed — latest `6bcbcf7`. See **D-11** + progress **Session 8**.
- **Next:** confirm CI green on #260 → **MERGE**; then full dual-write chain build+test in dev; airflow-side
  parity watch + D-10 `incr_col` switches remain. (Original repoint framing: parquet `SOURCE.<t>_ext` →
  `_uni_ext`, Tier → OC → FanCash, `unified_cutover_runbook.md`.)
- **Last updated:** 2026-09-30
