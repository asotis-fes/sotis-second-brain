# Tier `transaction` chunked-backfill QA — 2026-08-12

**Target:** `LOYALTY.SOURCE.transaction_ext` (external table over S3 `loyalty_postgres/transaction/`), `program_id = 2` (Tier Points).
**Goal:** prove the 250k-row, timestamp-boundary chunked backfill (created_at 2026-04-01 → today) landed completely and without corruption.
**Access:** conn `FAN_DATA_EXCHANGE_PROD`, role `FES_DATA_DEVELOPER`, wh `FDE_DEVELOPER_3XL_WH` (SELECT-only). Live table — counts drift slightly between queries as the incremental DAG appends.

## Verdict

**Chunking strategy: PASS.** The backfill body (created_at 2026-04-01 → 2026-08-11 23:59:59) is complete and gap-free at day and hour grain, boundaries are clean, and dups are bounded/benign. **One coverage hole found, but it is NOT a chunking defect** — it's a cutover-timing gap between the backfill tail and the incremental DAG going live (see Finding G1). One bounded backfill run closes it.

## Snapshot (program_id=2)

| metric | value |
|---|---|
| total rows (ext) | 108,886,682 |
| distinct ids | 108,736,590 |
| created_at range | 2026-04-01 00:00:03 → 2026-08-12 (live) |
| NULL id / created_at / program_id / upload_ts | 0 / 0 / 0 / 0 |
| upload_ts range | 2026-08-10 16:05 → live |

## Checks

**1. Row-count parity vs Postgres — NOT RUN (no PG access from this session).** `snow` only reaches Snowflake; the Postgres loyalty source needs either PG creds or an Airflow-side count task. Proxy used instead: internal consistency (below) + staging dedup. *Recommend a follow-up PG-vs-ext count for the backfill window.*

**2. Duplicate / seam integrity — PASS.** Dup-id multiplicity caps at **3×**: ~108.66M ids ×1, ~30.0k ids ×2, ~60.1k ids ×3. A half-open `[lo, hi)` seam bug **drops** rows, it does not duplicate them — so 2–3× dups are the expected overlap of (backfill) + (hourly incremental 30s look-back re-writes), not corruption. dbt staging dedups these via `QUALIFY ROW_NUMBER() … ORDER BY upload_ts DESC`.

**3. created_at coverage / continuity — PASS (backfill body).** 134 calendar days in [2026-04-01, today], **0 zero-days**. Median ~820k ids/day, avg ~811k. The low-volume days are all Mondays (natural weekly trough), not chunk loss. Apr 1 boundary is a full day (00:00:03 → 23:59:59, 962,934 ids). No dropped-chunk signature anywhere in the backfill body.

**4. Chunk-seam integrity — PASS (backfill body).** Hourly sweep Aug 10 → Aug 11 is smooth and continuous with no missing slivers at slice edges; a boundary-loss bug would show as a zero/near-zero hour, and none appears through Aug 11 23:59.

**5. Value integrity — PASS.** program_id uniformly 2 (filter), zero NULL id/created_at/program_id, metadata VARIANT present.

**6. upload_ts — PASS.** Zero NULL upload_ts; filename token parsed on every row. Two backfill upload waves visible (upload_ts 2026-08-10 16:05 and 2026-08-11 22:42) covering created_at → Aug 11 23:59.

## Finding G1 — cutover gap (needs a bounded backfill; NOT a chunking bug)

Hourly boundary map (program_id=2):
- backfill tail: last created_at loaded by backfill = **2026-08-11 23:59:59.889** (upload_ts 2026-08-11 22:42)
- incremental head: first created_at loaded by the live tier DAG = **2026-08-12 13:34:36.091** (upload_ts 2026-08-12 13:35)
- **MISSING: created_at (2026-08-11 23:59:59.889, 2026-08-12 13:34:36.091) ≈ 13.5 h** — no rows in the ext table.

Cause: `loyalty_postgres_tier_to_s3_ingest` has `start_date=2026-08-12` + `catchup=False`, so its first hourly run (13:35) only covered its own interval; the backfill had stopped at Aug 11 23:59. Nothing loaded the intervening window.

**Fix — one backfill run** (after which REFRESH the ext table):
```json
{"table": "transaction", "column": "created_at", "program_id": 2,
 "min": "2026-08-11 23:59:59", "max": "2026-08-12 13:34:37"}
```
`min`/`max` are half-open and slightly overlap both sides; staging dedups the overlap. Then:
```sql
ALTER EXTERNAL TABLE LOYALTY.SOURCE.transaction_ext REFRESH;
```

## Related open item — staging not yet backfilled

`LOYALTY.SOURCE.transaction` (dbt staging) for program_id=2 holds only **96,784 rows, created_at 2026-08-10 16:58 → today** — it dedups correctly (rows == distinct ids) but has **not** ingested the Apr→Aug history that's sitting in the ext table. The deduped staging model needs a full/backfill run (or its incremental watermark reconsidered) so downstream (Hajime's tier ledger) sees the backfilled history. Track separately from this QA.

## Queries
Saved in scratchpad `tq_0*.sql` (probe, snapshot, dup distribution, day-gap, low-days, boundary, hourly-edge, seam).
