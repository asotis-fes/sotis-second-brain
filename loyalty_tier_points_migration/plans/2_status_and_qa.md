# Tier Ingest — Current State + Data QA Plan (2026-08-12)

## Where things stand (fes-airflow)

PRs (all off `main`, squash-merged unless noted):
- **#2325 MERGED** (`b90e0807`) — chunked-ingest helper + manual backfill DAG + schema-discovery DAG (additive).
- **#2327 MERGED** (`5af1746d`) — Tier Points ingest: separate scheduled DAG `loyalty_postgres_tier_to_s3_ingest`
  (extract-only, chunked, prod `35 * * * *`), `TP_POSTGRES_TABLE_CONFIGS` (5 tier tables), 5 `create_tier*_ext.sql`,
  backfill DAG recognizes tier tables. Includes the schema-drift fix (real prod tier tables dropped `program_id`).
- **#2328 OPEN, CI GREEN, pending review approval** (`feat/loyalty-account-metadata`) — ingest `account_metadata`
  **tier-only** (program_id=2 in tier DAG; NOT in OneCredits DAG). New `create_account_metadata_ext.sql`.

## Chunking design (the load-bearing facts)
- `SqlToS3Operator` buffers the whole result in a pandas DataFrame -> OOM (SIGKILL -9 / "zombie") on big pulls.
- Fix = `chunked_ingest.build_chunk_specs`: split a (filtered) window into ~`CHUNK_ROWS`-row slices along a
  **timestamp column** (row-balanced boundaries via `ROW_NUMBER() OVER (ORDER BY chunk_ts_col)`), NOT PK-hash.
- Settled knobs: **CHUNK_ROWS = 250_000**; backfill DAG **max_active_tasks = 1** (serial). Peak worker mem ≈
  CHUNK_ROWS × avg_row_bytes × pandas_overhead × concurrency. `transaction` is wide (~939 B/row + metadata JSON);
  1M OOM'd, 250k serial succeeded in dev.
- Backfill conf: `{table, column(ts, default incremental_col), min, max(exclusive), program_id?}`.
  Airflow dynamic-map cap = 1024, so a single run must stay < ~1000 chunks -> bound big ranges by date.

## What's actually been loaded to prod so far
- OneCredits pipeline live (stopgap: OC DAG filters bucket/account_balance/transaction to program_id=3).
- Tier `transaction` (program_id=2) BACKFILLED **2026-04-01 -> today** via backfill DAG
  (`{table:transaction, column:created_at, program_id:2, min:2026-04-01, max:...}`). Ran serial, 250k chunks, succeeded.
- Tier `transaction` history is BACKDATED to 2025-06+; full history ≈ 328M rows (~1300 chunks) -> must be
  date-bounded per run; pre-Apr-2026 NOT yet backfilled.
- Tier-specific 5 tables + account_metadata: NOT yet loaded (need #2328 merge -> create_tables in prod -> backfill).

## Program mapping (LOYALTY.SOURCE.program): 1=FANCASH, 2=TIERPOINTS, 3=CREDITS(OneCredits)

## Snowflake access: conn FAN_DATA_EXCHANGE_PROD, role FES_DATA_DEVELOPER, wh FDE_DEVELOPER_WH (use >= MEDIUM).
Tier transaction ext table: `LOYALTY.SOURCE.transaction_ext` (external table over S3 loyalty_postgres/transaction/).
dbt staging `LOYALTY.SOURCE.transaction` is built by the dbt Cloud job (reads *_ext).

---

## NEXT: QA / audit tier transaction data in the external table (validate chunking worked)

Goal: prove the chunked backfill of tier `transaction` (program_id=2, 2026-04 -> today) landed **completely and
without corruption/dupes** in `LOYALTY.SOURCE.transaction_ext`. This validates the chunking strategy end-to-end.

Checks to run (Snowflake, read-only; compare against PG source counts where possible):
1. **Row count parity**: COUNT(*) in transaction_ext WHERE program_id=2 AND created_at in [2026-04-01, cutoff)
   vs the PG source count for the same predicate (loyalty_postgres, program_id=2). Should match (allow tiny
   drift from live writes near the cutoff).
2. **No chunk gaps / boundary loss**: the row-balanced slices used half-open `[lo, hi)` ranges; a boundary bug
   would drop/dup rows exactly at slice edges. Check for duplicate `id` (PK) — `GROUP BY id HAVING COUNT(*)>1`
   should be empty (or explained by the incremental DAG + backfill overlap, which staging dedups via QUALIFY).
   Audit the EXT table (raw parquet union) for dup `id`; expect some overlap dups in ext (backfill + any live
   incremental), confirm staging `transaction` dedups them to 1 per id.
3. **created_at coverage/continuity**: min/max(created_at) for program_id=2 == expected [2026-04-01, ~today];
   per-day counts have no unexpected zero-days inside the range (a dropped chunk shows as a gap).
4. **Chunk-seam integrity**: pick the boundary timestamps from a plan_backfill log (or re-derive) and confirm
   counts just below/above a seam sum correctly (no rows lost at `< hi` / `>= lo`).
5. **Value integrity**: metadata (VARIANT) parses; program_id is uniformly 2; no NULL created_at/id.
6. **Cross-check upload_ts**: rows carry non-NULL upload_ts/upload_date (filename token parsed) — confirms the
   backfill s3_key naming worked.

Deliverable: short QA note in this folder (`analysis/tier_transaction_qa_<date>.md`) with the queries + results and
a pass/fail verdict on chunking. If gaps found -> identify the missing created_at window and re-run a bounded backfill.

Open follow-ups after QA: merge #2328; run create_tables in prod; backfill the 5 tier tables + account_metadata;
optionally backfill pre-Apr-2026 tier transaction history; confirm tier ext-table refresh (AUTO_REFRESH vs dbt
pre-hook) with the dbt owner; heads-up to AE (Hajime) that tier tables dropped program_id.
