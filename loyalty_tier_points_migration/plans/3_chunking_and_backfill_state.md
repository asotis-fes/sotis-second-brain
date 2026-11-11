# Loyalty chunked-ingest + tier backfill — state (2026-08-20)

Continues [[2_status_and_qa]]. Repo: `fes-airflow`. This captures the chunk-by-id work and
the tier-points backfill state so it survives a compact.

## PR #2334 — row-count keyset chunking (MERGED to prod)

Branch `feature/loyalty-chunk-by-id`, merged. What it changed:

- **`dags/loyalty/chunked_ingest.py`** — decoupled the **window column** (`chunk_ts_col`, what the
  range filter applies to) from the **split key** (`chunk_key`, what boundaries balance on;
  defaults to `chunk_ts_col`). `_literal(v)` casts datetimes to `::TIMESTAMP` but leaves text/uuid
  keys uncast. `_slice_bounds(boundaries)` builds the half-open `[lo,hi)` ranges. `CHUNK_ROWS=250_000`.
- **`dags/loyalty/configs.py`** — per-table chunk key (see below).
- **backfill + tier DAGs** — pass `chunk_key` from config `pk` (backfill also honors a `chunk_key`
  **conf override**).
- **`tests/dags/test_chunked_ingest.py`** — 30 tests (SQL-shape + partition invariants + ~4.2k
  seeded fuzz iters), mutation-verified (dropping trailing edge → 23 fails; `<`→`<=` → 4 fails).

### Mechanism facts
- Boundaries = value at every `CHUNK_ROWS`-th row (`ROW_NUMBER() OVER (ORDER BY chunk_key)`,
  `MOD(rn,250000)=0`), **deduped + sorted**. Slices are half-open `[lo,hi)`.
- **A single repeated value can't be split by that column** → that slice balloons → OOM.
  Fix: chunk on a **unique** column (`pk`).
- With a unique key, each slice is exactly `CHUNK_ROWS` rows (tie-proof). Completeness/no-dupes
  holds for ANY distribution (proven by tests).
- Airflow dynamic-map cap = **1024** → a single run must stay < ~1000 chunks → date-bound big ranges.
- Backfill DAG `loyalty_postgres_backfill`: manual, `max_active_runs=1`, `max_active_tasks=1` (serial).
  Conf keys: `{table, column?, chunk_key?, min?, max?, program_id?}`. `min` inclusive, `max` **exclusive**
  (half-open); chained windows (`max_n == min_{n+1}`) tile with no gap/overlap.

## Per-table chunk-key decisions (why)

| table | window col (`incremental_col`) | chunk key | note |
|---|---|---|---|
| `transaction` | `created_at` | **`created_at` (NO pk)** | range-**partitioned by created_at** → chunking on it prunes to a partition; distributed. `pk:id` would defeat pruning. Append-only (no `updated_at`). |
| `tier_account_override` | `updated_at` | **`pk: id`** | migration flattened **all 4 timestamps** (created_at/updated_at/start_at/expires_at) to `2026-01-01` → only the uuid pk splits it. |
| `account_metadata` | `updated_at` | **`pk: id`** | insurance (not partitioned); tier-only (`program_id=2`). NOTE: **not consumed by any tier dbt model** — optional. |
| `tier`, `tier_override_configuration`, `tier_invite_approval`, `tier_account_override_trial` | `updated_at` | none (small → 1 chunk) | `tier` keys on `tier_id`, `tier_invite_approval` has no single `id` (composite) |
| `allocation` | `created_at` | none | partitioned; no DB-enforced unique key; created_at distributed |

## DAGs

- **`loyalty_postgres_to_s3_ingest`** = **OneCredits** DAG, `5 * * * *`. Ingests legacy-active +
  OC bucket-model tables. Uses the OLD single-query path (`max_rows_per_file=1M`, NOT chunked).
  STOPGAP: `PROGRAM_FILTERED_TABLES={bucket,account_balance,transaction}` filtered to
  `program_id=3`. **DO NOT pause/touch for tier work.**
- **`loyalty_postgres_tier_to_s3_ingest`** = **Tier** DAG, `35 * * * *`. Ingests `transaction`
  (program 2) + the TP tables. Chunked. **Pause only THIS for tier backfills.** `catchup=False`
  (paused hours don't self-heal → cover gaps with a backfill).
- **`loyalty_postgres_backfill`** — manual, chunked, serial.

## Shared-table gap analysis — RESOLVED (no gap)

Checked Hajime's `dbt-fes-ae` tier models. Tier ledger sources ONLY:
`transaction_ext` (program 2), `tier_ext`, `tier_account_override_ext`,
`tier_account_override_trial_ext`, `tier_invite_approval_ext`, `tier_override_configuration_ext`.
**No `bucket` / `account_balance` / `account_metadata`.** So the OneCredits `program_id=3` stopgap on
`bucket`/`account_balance` does NOT create a tier gap. `transaction` (program 2) + the 5 tier tables
= everything the tier ledger needs.

## Incremental watermark
`transaction` incremental filters on **`created_at`** (append-only ledger, no `updated_at`; voids/reversals
are new rows). Window = `created_at >= interval_start-30s AND < interval_end` (30s look-back for commit
skew, staging dedups). Backdated inserts (migration) fall outside the window → covered by backfills, not
incremental. (Don't use `available_at` — can be future-dated.)

## Backfill state (prod) + NEXT STEPS

Tier `transaction` (program 2): loaded **2026-04-01 → today**. Backfilling older history in date windows
`{table:transaction, program_id:2, column:created_at, min, max}` (half-open, `max=2026-04-01` for the
newest older-window so it abuts the already-loaded data — no overlap).

- Ran window **[2025-10-01, 2026-04-01)** → 599 chunks; **chunk301 OOM'd** (`map_index=301`).
  - Cause: migration-backdated block at **exactly `2026-01-01T08:00:00Z`** (whole-second `.000000`
    boundaries vs microseconds elsewhere). The tied second collapsed → chunk301 `[07:59:59, 08:00:00)`
    swallowed it. Bounded to that 1 second because neighbors chunk300 `[.., 07:59:59)` and
    chunk302 `[08:00:00, ..)` both succeeded.
  - **FIX (pending/verify)** — re-run just that second, split on `id`:
    ```json
    {"table":"transaction","program_id":2,"column":"created_at","min":"2026-01-01T07:59:59","max":"2026-01-01T08:00:00","chunk_key":"id"}
    ```
    then `ALTER EXTERNAL TABLE LOYALTY.SOURCE.transaction_ext REFRESH;`
  - **GOTCHA:** any transaction backfill window crossing `2026-01-01T08:00:00Z` hits this tied second →
    carve it out with `chunk_key:id` (or add `"chunk_key":"id"` to the whole run). One-time migration
    artifact; real-time incremental won't hit it.
- **TODO:** confirm source `MIN(created_at)` for program 2 (migration backdated to ~mid-2025) and load
  the remaining older window(s) below 2025-10-01, date-bounded, watching plan chunk count < ~1000.
- **Verify each load:** post-REFRESH, `COUNT(*)`/`COUNT(DISTINCT id)`/day-continuity on
  `transaction_ext` WHERE `program_id=2` for the window.

Tier tables + `account_metadata`: the 6-table runbook (pause tier DAG → REMOVE prefix → backfill
`{table:X}` → REFRESH) was provided. `tier_account_override` needs `pk:id` (now in config).
`tier_account_override_trial` was reloaded (REMOVE of dt=2026-08-12/13 partials). **Confirm which are
actually loaded/refreshed** — not all confirmed done at compact time.

## S3 / stage / access

- Prod stage `@FES_INTEGRATIONS.STAGE.FES_INTEGRATIONS_PROD_STAGE` → `s3://fes-integrations-prod/loyalty_postgres/<table>/`.
  Dev `@FES_INTEGRATIONS_DEV.STAGE.FES_INTEGRATIONS_DEV_STAGE` → `s3://fes-integrations-dev/`.
- Ext tables: `LOYALTY.SOURCE.<table>_ext` (prod), `LOYALTY_DEV.SOURCE.<table>_ext` (dev).
- s3_key = `loyalty_postgres/{table}/dt={ds}/{table}_{ts_nodash}_chunk{i}.parquet`. **Unique per run**
  (ts_nodash) → **no overwrite risk**; re-runs ADD files, staging dedups by pk via
  `QUALIFY ROW_NUMBER()... ORDER BY upload_ts DESC`. `REMOVE @stage/loyalty_postgres/<table>/` for a clean reload.
- `REMOVE` / `ALTER EXTERNAL TABLE ... REFRESH` need the stage/ext **owner role** `AR_FES_EXT_TABLE_OWNER`
  (FES_DATA_DEVELOPER may be denied).
- Snowflake: conn `FAN_DATA_EXCHANGE_PROD`, role `FES_DATA_DEVELOPER`, wh **`FDE_DEVELOPER_3XL_WH`**
  for `transaction` (SELECT-only). `LOYALTY_DEV` visible in same account.
- Dev testing was deemed unnecessary (dev/prod schema diverges → low signal); validated configs against
  the **prod** discovery dump instead. Every actively-ingested table's cols/incremental_col/pk exist in prod.

## Known latent items (not blocking)
- `idempotency_keys` config has `incremental_col=updated_at` but prod has no `updated_at` → would error if
  backfilled. It's in `LEGACY_DROPPED_AT_CUTOVER` — don't trigger it.
- `user_bonus_reward` config dropped `failure_reason` (removed from prod 2026-08-14).
