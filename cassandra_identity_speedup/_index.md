# Cassandra Identity Speedup

**Slug:** `cassandra_identity_speedup`
**Started:** 2026-09-28
**Team:** Data Engineering Integrations
**Status:** ✅ **DRAFT PR OPEN → https://github.com/fanatics-gaming/dbt-fes-ae/pull/411**
(branch `identity/cdc-source-migration`, pushed @ `19ff2a4`, labels `[R] Change Request`+`enhancement`).
6 tables repointed batch→CDC (identity 5 + auth_id); CDC branch defaults OFF (`identity_cdc_enabled`)
so merge is a no-op until activated. `dbt parse`+`compile` green; transforms validated read-only vs
prod. **Draft because merge gates on:** dev e2e test, prod-sandbox parity, consumer parity, companion
fes-airflow DAG wiring, commit re-sign (currently UNSIGNED). Token-range PARKED.
See [progress.md](progress.md) / [testing.md](testing.md) / [dbt_integration.md](dbt_integration.md).

## Goal

Speed up the **Cassandra → S3 extract** in `fes-airflow`. Today it's a ~5-hour daily
**full snapshot** and needs to be materially faster. This is a **performance task**, NOT
the loyalty COPY/CSV ingestion pattern.

## Scope

- **Repo:** `~/repos/fes-airflow`
- **DAG:** `dags/identity/cassandra_extract.py` (on `main`)
- **Companion:** `dags/identity/cassandra_schema_discovery.py` (ad-hoc, read-only schema lister)
- **Work branch:** `fix/cassandra-token-range-extract` (worktree at `~/repos/fes-airflow-token-range`)
- **Deliverable:** confirm the bottleneck split (one giant table vs. many), implement
  token-range chunking, open a **labeled PR to `main`**.

## What the DAG does today

- Extracts keyspaces **`profile`** and **`id`** (skips `credit_card`) → Parquet in S3,
  which feeds the **identity dbt Cloud** job.
- Conn: `cassandra_identity_loyalty` (prod) / `cassandra_identity_loyalty_test` (dev).
- Schedule: daily **6am EST**, full snapshot (not incremental), `max_active_runs=1`.
- S3 layout: `s3://{bucket}/cassandra/{keyspace}/{table}/{YYYY-MM-DD}/batch_NNNN.parquet`

## The two bottlenecks (hypothesis to confirm)

1. **Tables run one at a time** — `extract_table` has `max_active_tis_per_dagrun=1`.
2. **Each table is a single-coordinator `SELECT *` paged scan** — `fetch_size=5000`,
   `LOCAL_ONE`, no token-ring parallelism (one coordinator streams the whole table).

## Primary fix

**Token-range parallel scans.** Split the Murmur3 token space into N ranges and query
`... WHERE token(pk) > ? AND token(pk) <= ?` concurrently, with `TokenAwarePolicy`
routing each range to a replica that owns it. Clean Airflow shape:

```
discover_tables → compute (table, start_token, end_token) chunks → extract_range.expand(...)
```

Plus: bump table/range concurrency, raise `fetch_size`, write **fewer/larger** Parquet files.

## Sizing constraints (READ before coding)

- Schema discovery gives **NO row counts** (`system_schema.columns` only).
- **Do NOT** `SELECT COUNT(*)` — full scan, times out.
- Get per-table durations from the **last prod run** (ground truth) and/or query
  **`system.size_estimates`** (scan-free; per-node/coordinator-local — good for ranking the
  hog and planning token splits, not exact counts).

## TOC

- [cdc_investigation.md](cdc_investigation.md) — ⭐ CDC docs, S3/stage locations, Anna's SQL, caveats
- [design.md](design.md) — ⭐ target build: layers, dedup macro, seed+union, pilot, repo/PR split
- [dbt_integration.md](dbt_integration.md) — ⭐ how to repoint the identity source: contract, steps, the funky bits
- [testing.md](testing.md) — ⭐ full pre-prod test plan (synthetic dev + prod sandbox + parity)
- [parity.md](parity.md) — parity queries (cdc_current vs batch ext)
- [plan.md](plan.md) — approach, milestones, open questions
- [findings.md](findings.md) — current-state code facts + sizing evidence
- [decisions.md](decisions.md) — design decisions log (D-1..D-5)
- [progress.md](progress.md) — running work log
