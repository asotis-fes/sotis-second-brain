# Unified Loyalty Ingestion — Parallel-Run + Tier-First Cutover Runbook (Scope A)

Migrates OneCredits (program_id=3), Tier Points (2), and FanCash (1) from the per-program
chunked/parquet extraction DAGs onto ONE streaming-COPY DAG that writes CSV + CSV external tables
(decision **D-7**, reduced to extraction-only by **D-9**). Branch: `loyalty/unified-postgres-ingest`.

**Scope A:** the DAG owns EXTRACTION only — COPY → CSV → refresh `SOURCE.<t>_uni_ext`. **dbt keeps the
dedup** (its existing loyalty source models: incremental + `QUALIFY ROW_NUMBER() OVER (PARTITION BY pk
ORDER BY upload_ts DESC)`). No Airflow-owned native tables, no MERGE. Same shape as the merged
bonus-engine DAG (**#2347**, `loyalty_bonus_postgres_to_s3_ingest`).

> **Status (2026-09-30):** Phase 1 is DONE — PR **fes-airflow#2358** (branch
> `loyalty/unified-ingest-extract`, NOT the `loyalty/unified-postgres-ingest` named below) merged
> 2026-09-08; `loyalty_postgres_unified_to_s3` is live in prod on `20 * * * *`, writing `loyalty_source/`
> + refreshing `_uni_ext`. Phase 2 (validate) is underway. Phases 3-5 (the dbt flip) remain — but the
> dbt cutover is currently being done as a **dual-write parallel run** (dbt-fes-ae PR #260, D-11), not
> the in-place source repoint sketched in Phase 3; reconcile the two before the final flip. NOTE: the
> DAG's `compare_counts` task was **REMOVED** (Session 7) — parity is now eyeballed via the 24-table
> ext-summary query (rows/files/latest_upload), not logged by the DAG.

## Target architecture (recap)
- One DAG `loyalty_postgres_unified_to_s3` — per table: scheduled/backfill window → streaming COPY off
  the reader → S3 CSV (`loyalty_source/<t>/`) → targeted refresh of `SOURCE.<t>_uni_ext`.
- dbt owns the deduped source layer (unchanged). Programs separate by `program_id`.
- Fully isolated from the live pipeline (new `loyalty_source/` prefix + `_uni_ext` names) → safe parallel-run.

## Pre-flight (before any flip)
1. **AE sign-off** — at flip, the dbt loyalty source models repoint from the parquet `SOURCE.<t>_ext`
   tables to the new CSV `SOURCE.<t>_uni_ext` tables. Same dedup logic, new upstream. Agree first.
2. **Confirm prod `loyalty_postgres` is a reader** (`pg_is_in_recovery()=true`) — the DAG logs it on run 1.

## Phase 1 — Parallel run (no downstream impact)
1. Merge/deploy the branch so `create_tables` builds all 24 `SOURCE.<t>_uni_ext` (dev + prod; inert until files land).
2. Enable `loyalty_postgres_unified_to_s3` in dev (manual) → later prod (`20 * * * *`). It writes only
   `loyalty_source/` and refreshes `_uni_ext`; the current `loyalty_postgres_to_s3_ingest` /
   `loyalty_postgres_tier_to_s3_ingest` DAGs keep running untouched.
3. First run pulls the scheduled window (or a `{"min","max"}` slice / backfill-flag full pull); incremental thereafter.

## Phase 2 — Validate output (a few days)
- Run the 24-table ext-summary query (rows / file count / latest_upload per `_uni_ext`) over the parallel-run
  days and watch for healthy growth. (The old in-DAG `compare_counts` distinct-PK parity task was removed in
  Session 7 — parity is now a manual cross-check, below.)
- Cross-check `SOURCE.<t>_uni_ext` (deduped via QUALIFY on `upload_ts`, filtered by `program_id`) against the
  current parquet `SOURCE.<t>_ext` for the program being cut over.
- Spot-check jsonb (`metadata`/`extra_data`) parse and timestamp casts on a few tables.
- Let it run several incremental cycles; confirm mutable-row updates converge (dedup by `upload_ts`).

## Phase 3 — Flip Tier Points first (coordinated dbt PR)
1. In dbt-fes-ae, repoint the Tier source reads (`loyalty__source` → the `tier_*` / `loyalty_transaction`
   @ program_id=2) from the parquet `SOURCE.<t>_ext` tables to `SOURCE.<t>_uni_ext`. dbt keeps its existing
   incremental + QUALIFY dedup; move the `ALTER EXTERNAL TABLE … REFRESH` pre_hook onto the `_uni_ext` table.
2. Merge in a low-traffic window; verify tier metrics unchanged vs a pre-flip snapshot.
3. Leave the old Tier ingest DAG one more cycle as a safety net, then disable it.

## Phase 4 — Flip OneCredits, then FanCash
1. Repoint the OC source reads (program_id=3) at `_uni_ext`; validate; disable the OC ingest DAG.
2. FanCash (program_id=1) source points at `_uni_ext` from the start (no legacy DAG to retire).

## Phase 5 — Retire the old pipeline
1. Disable + delete `loyalty_postgres_to_s3_ingest` and `loyalty_postgres_tier_to_s3_ingest`.
2. Drop the parquet `SOURCE.<t>_ext` tables + `loyalty_postgres/` prefix once parity has held for an agreed window.
3. Optionally rename `SOURCE.<t>_uni_ext` → canonical `SOURCE.<t>_ext` (one dbt + `EXT_SUFFIX` config change).
   Once dbt refreshes `_uni_ext` via its pre_hook, the DAG's `refresh_ext` task can be dropped.

## Rollback
At any phase before deleting the old objects: revert the dbt repoint PR (source models read the old parquet
`_ext` again). The unified DAG + `_uni_ext` tables keep running harmlessly in parallel. Zero data loss —
the old pipeline was never touched.

## Out of scope
Bonus-Engine (`fes-loyalty-bonus`) and Partnerships (`fes-partnerships`) — different source DBs, separate DAGs.
