# Plan

> **Status note (2026-09-30):** This three-task framing is from the early **FanCash-only** phase.
> Ground truth now (see `_index.md` Status + `decisions.md` D-9/D-11): **Task 1 = done**;
> **Task 3 = shipped** via the **UNIFIED** pipeline (D-7→D-9, PR fes-airflow#2358 merged 2026-09-08,
> live in prod) — no longer FanCash-specific; **Task 2 (ENTDATA-2021 backfill) is the one still-open
> task in this folder**; and a NEW dbt-side workstream — the ledger cutover as a dual-write parallel
> run (**D-11 / dbt-fes-ae PR #260**) — is the current active work. The Task 3 section below describes
> the superseded FanCash-only loader and is kept for history.

Three workstreams. Task 1 comes first — it informs the other two.

## Task 1 — Dev ingest to learn the data shape  ✅ DONE (via QC/COPY)
Pulled FanCash `program_id=1` from the QC env (`loyalty_postgres_test`) into dev S3 via the streaming
COPY loader (not the original parquet DAG). QC shape (2026-08-26): transaction 1,891, bucket 13,
account_balance 10, account_metadata 0.

- [x] Confirm which FanCash tables/rows exist — schema discovery dump in `findings.md`; QC counts above.
- [x] Determine how FanCash rides the shared bucket-model tables — program-scoped transaction/bucket/
      account_balance/account_metadata @ `program_id=1`.
- [x] Build + run the loader in dev — `loyalty_fancash_copy_to_s3` ran clean against QC.
- [ ] Finish validation: `create_tables` 4 fancash tasks + SELECT (confirm CSV parse) → then old-vs-new compare.
- [ ] loyalty_id source (OQ-8) — still open, relevant to Task 2 backfill.

## Task 2 — Historical backfill export (ENTDATA-2021)
Transform Scylla → new PG `transaction` schema and land in S3 for the Loyalty team to backfill
(~2B transactions). Mapping in `backfill_mapping.md`.

- [ ] Resolve the open items: `transaction_id` transform, final reason codes, S3 format.
- [ ] Build the transform query (closest analog: `../loyalty_tier_points_s3_parallel_processing_data_dump/`).
- [ ] Validate output schema against the new PG `transaction` DDL.
- [ ] `COPY INTO` S3 (sample → full), coordinate stage/format with Loyalty engineers.

## Task 3 — Formalize the FanCash ingest pipeline  ← CURRENT (post-/compact)
Approach chosen: **streaming COPY-from-reader → CSV → `loyalty_fancash/` → `fancash_*_ext`** (D-3/D-4).
POC loader works in dev (full-table pull). Remaining to productionize:

- [x] Loader built + validated in dev (`loyalty_fancash_copy_to_s3`, ran clean 2026-08-26).
- [ ] Run `create_tables` (dev) 4 fancash tasks + validation SELECTs (confirm CSV parsing).
- [ ] **Incremental**: add schedule + `created_at`/`updated_at` window with lookback (currently
      manual full-table). Decide dedup: downstream `QUALIFY ROW_NUMBER() … ORDER BY upload_ts DESC`,
      or AE native incremental-merge SOURCE tables. Mutable tables rely on `updated_at` bump (confirm trigger).
- [ ] **Satellites** (OQ-7): ledger also needs `capture_event` (+ allocation/void_auth_event), which
      have no program_id → pull unfiltered into `loyalty_fancash/` + add their `fancash_*_ext`? Confirm with AE.
- [ ] AE points FanCash ledger (`loyalty_analytics_ledger`, dbt-fes-ae) at `fancash_*_ext`.
- [ ] **Prod cutover**: confirm prod `loyalty_postgres` is a reader; deploy loader + fancash ext tables
      to prod (they already build in prod). Confirm prod S3 path `fes-integrations-prod/loyalty_fancash/`.
- [ ] Nice-to-have: repoint the QC conn to a RO user (currently `loyalty_engineer_rw`).

## Notes
- Ingestion only. dbt ledger rewrite owned by another AE; we reference it for impact only.
- The old chunked/parquet plan (config entries, parity checks) is SUPERSEDED by the COPY approach.
- **D-9 (2026-09-04):** FanCash-only was subsumed into the UNIFIED DAG (D-7), now reduced to
  **extraction-only** — COPY→CSV→`_uni_ext`; **dbt keeps the dedup** (no Airflow native tables / MERGE).
  The "dedup: downstream QUALIFY vs AE native tables" choice above is settled: **downstream QUALIFY** on
  `upload_ts`, same as OC/Tier and the merged bonus DAG (#2347). See `decisions.md` D-9 + `unified_cutover_runbook.md`.
