# Airflow-owned managed SOURCE tables — design + open questions (2026-08-20)

**Focus of this doc:** move per-table dedup/merge into the Airflow ingestion pipeline so it lands
into a **clean, deduped Snowflake `LOYALTY.SOURCE.<table>` table** — one the AE can treat as
"just good to go." Other asks (self-healing, merge OC+tier DAGs, tier dbt-cloud trigger) are logged
as TODO at the bottom; **this piece first.**

## Current state (what already exists — important)

Ingestion today is: Airflow lands parquet → S3 → `LOYALTY.SOURCE.<table>_ext` (external table) →
**dbt incremental-merge models** in `dbt-fes-ae/models/loyalty/source/*.sql` produce the clean
`LOYALTY.SOURCE.<table>`. Confirmed from dbt logs (`merge into LOYALTY.SOURCE.entry / opco_program_account /
journal / system_loyalty_account …`) and the model files.

The existing pattern is uniform "latest-upload-wins upsert":
```sql
SELECT <cols>, {{ add_incremental_timestamps() }}
FROM {{ source('loyalty__source', '<table>_ext') }}
{% if is_incremental() %} WHERE <watermark> >= (SELECT MAX(<watermark>) FROM {{ this }}) {% endif %}
QUALIFY ROW_NUMBER() OVER (PARTITION BY <merge_key> ORDER BY upload_ts DESC) = 1
```
- `transaction`: merge_key `transaction_id`, watermark `created_at`
- `account_balance`: merge_key `id`, watermark `updated_at`
- `allocation`: merge_key `(earn_transaction_id, consume_transaction_id)`, watermark `created_at`

**The gap / inconsistency:** only 8 OC/legacy tables have these source models
(`account_balance, allocation, bucket, entry, journal, opco_program_account, system_loyalty_account,
transaction`). The **tier** ledger models read `*_ext` **directly** and dedup inline — so tier has no
clean source table, and dedup logic is scattered across dbt.

## Goal

Airflow owns a clean, deduped, per-table `LOYALTY.SOURCE.<table>` for **every** ingested table.
dbt consumers (OC + tier) read those and assume-good — no inline dedup, no per-model merge upkeep.
Centralizes the "how do we dedup THIS table" decision in one config-driven place.

## Why a real table (not just the ext table)
- Dedup **once** at load, not in every downstream model.
- Per-table strategy (immutable insert vs mutable upsert vs SCD2) lives in ingestion.
- MERGE is **idempotent** on the key → re-running a batch self-heals (no dupes), which feeds the
  separate self-healing goal.
- Lets us expire old S3 parquet (managed table is the source of truth).

## Proposed mechanism (follows existing repo pattern)

Repo already has `COPY INTO <db>.<schema>.<table>` + `snowflake_service_user` conn
(`dags/leap_event_tech/sql/copy_into_leap_table.sql`, `truncate_copy_ffny_transfers.sql`). Reuse it.

Per table, after the S3 land step, run a Snowflake `MERGE` into the managed table:
```sql
MERGE INTO LOYALTY.SOURCE.<table> t
USING (
    SELECT <cols>, upload_ts
    FROM LOYALTY.SOURCE.<table>_ext
    WHERE upload_date = '{{ ds }}'                 -- scope to this batch's files (partition prune)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY <merge_key> ORDER BY <order_col> DESC) = 1
) s
ON t.<merge_key> = s.<merge_key>
WHEN MATCHED AND s.<order_col> >= t.<order_col> THEN UPDATE SET ...   -- mutable/upsert only
WHEN NOT MATCHED THEN INSERT ...
```
- **Keep the ext table** as the MERGE source (scoped by `upload_date`/`upload_ts` to the current batch,
  so we don't re-scan all history). No extra landing table needed.
- Config-driven off the same `configs.py` entries (add `merge_key`, `strategy`, reuse `incremental_col`).
- Idempotent: re-running a batch re-MERGEs the same rows → no change.

## Per-table load-strategy taxonomy

| strategy | when | MERGE behavior |
|---|---|---|
| `insert_only` | append-only immutable ledgers (created_at, no updated_at) | `WHEN NOT MATCHED INSERT`; never UPDATE |
| `upsert_latest` (SCD1) | mutable current-state (has updated_at) | UPDATE if incoming newer, else INSERT; keep latest only |
| `scd2` | mutable **and** AE needs point-in-time history | close old row, insert new with effective dates — **only if AE asks** |

### Tentative per-table matrix (confirm keys empirically + with AE)
Append-only → `insert_only`, watermark `created_at`:
`transaction` (key ❓ `transaction_id` per existing model vs `id`), `allocation` (`allocation_id` surrogate
exists, existing model uses the `(earn,consume)` pair), `auth_hold`, `capture_event`, `void_auth_event`,
`auth_bucket_hold`, `bucket_type`, `transfer_restriction` (watermark `starts_at`), `loyalty_account`,
`system_loyalty_account`, `user_event`, `user_bonus_step_event`.

Mutable → `upsert_latest`, watermark `updated_at`:
`bucket`, `account_balance`, `program_account_balance`, `opco_program_account`, `operating_company`,
`program`, `tier`, `tier_account_override`, `tier_override_configuration`, `tier_invite_approval`,
`tier_account_override_trial`, `account_metadata`, `allocation_remaining`, `void_remaining`, bonus tables.

## Questions WE answer ourselves (DB/data facts)

1. **Merge key per table.** Known for most (`id`); confirm the composites and surrogates empirically
   (`COUNT(*)` vs `COUNT(DISTINCT key)` on the loaded ext data): `capture_event`, `void_auth_event`,
   `allocation_remaining`, `void_remaining`, `tier_invite_approval`, `system_loyalty_account`,
   `auth_hold`. Cross-check against the existing `models/loyalty/source/*` unique_key configs.
2. **Watermark column** = `created_at` (append-only) / `updated_at` (mutable) / `starts_at`
   (transfer_restriction). From schema — done.
3. **Mutability** (insert_only vs upsert) = presence of `updated_at`. From schema — done.
4. **Dedup ordering.** Current dbt uses `upload_ts DESC`. For **mutable** tables `updated_at DESC`
   (upload_ts tiebreaker) is more correct — a late backfill re-upload of *old* state shouldn't clobber
   newer state. **Decision to make** (lean: `updated_at DESC, upload_ts DESC` for mutable; `upload_ts`
   fine for immutable). 
5. **Batch scoping** for the MERGE source (`upload_date = ds` / `upload_ts` window) so we don't rescan
   all files. Mechanics — ours.
6. **Managed-table DDL + schema evolution.** Who creates `LOYALTY.SOURCE.<table>` (extend `create_tables`)
   and how we handle source column add/drop (saw `user_bonus_reward` drop `failure_reason`). Ours.

## Questions for the ANALYTICS ENGINEER (semantic/consumption)

1. **SCD1 vs SCD2 per table** — does any analysis need *point-in-time history* of a mutable row
   (balance-over-time, tier changes-over-time), or is **current state only** sufficient? Default we'll
   assume **current-state (SCD1/latest)**. (Note: `tier_changes_all`, tier history models exist — do those
   need SCD2 on `tier_account_override`, or do they derive history from the append-only `transaction`?)
2. **`transaction` grain** — the existing source model dedups on **`transaction_id`** (not `id`). Confirm
   that's the intended grain (one row per `transaction_id`, latest upload), vs row-level `id`. This decides
   the merge key and whether state-transition rows collapse.
3. **Hard deletes** — does any consumer need source-side row *deletions* reflected in the SOURCE table?
   (Incremental insert/upsert won't remove deleted rows; reflecting deletes needs a periodic full-key
   reconcile — more expensive.) Default: **no delete handling**.
4. **Append-only confirmation** — for the ledgers (`transaction`, `allocation`, `capture_event`,
   `auth_hold`, `void_auth_event`, events): keep **all** rows forever, reversals/voids as separate rows,
   never UPDATE. Confirm.
5. **dbt source-model retirement** — OK to **retire `models/loyalty/source/*`** (the 8 incremental-merge
   models) once Airflow produces those tables, and repoint tier models off `*_ext` onto the clean source
   tables? Any transforms in those source models beyond dedup that must be preserved?

## Key decisions to surface (before building)

- **A. Ownership shift (the big one):** Airflow takes over the `models/loyalty/source/*` merge from dbt;
  AE retires those models and reads the Airflow-produced source tables. Needs a coordinated cutover
  (build Airflow merge → validate parity vs dbt table → repoint models → drop dbt source models).
- **B. Ordering fix:** move mutable-table dedup ordering to `updated_at DESC` (see Q-self-4).
- **C. Delete handling:** default none; add reconcile only if the AE needs it (Q-AE-3).
- **D. Where the MERGE runs:** a per-table Snowflake step in the (to-be-merged) ingest DAG, right after
  the S3 land, gated so a failed MERGE is retryable/idempotent.
- **E. Parity gate:** before cutover, compare Airflow-merged table vs current dbt source table
  (row counts + key-level diff) so we prove equivalence.

## TODO backlog (other pieces from the ask — NOT this pass)

- [ ] **Self-healing incremental** — idempotent MERGE (this pass helps), gap detection
      (missing `created_at`/`upload` windows), auto-retry/alerting, reconcile job.
- [ ] **Merge OC + tier DAGs** into one loyalty ingest DAG (currently
      `loyalty_postgres_to_s3_ingest` [OneCredits, unchunked] + `loyalty_postgres_tier_to_s3_ingest`
      [tier, chunked]). Fold tier into the shared DAG; retire the program-filter stopgap once the OC path
      is chunked.
- [ ] **Tier dbt-cloud trigger** — trigger the tier dbt job from the ingest DAG the way OC does today
      (`create_dbt_cloud_task_group`, `DBT_CLOUD_FESLOYALTY_JOB_ID`).

## Snowflake / repo facts
- Write conn: `snowflake_service_user`. COPY/MERGE pattern: `dags/leap_event_tech/sql/copy_into_leap_table.sql`.
- Ext tables `LOYALTY.SOURCE.<table>_ext` carry `upload_ts` / `upload_date` (parsed from filename) — use for
  batch scoping + dedup ordering.
- dbt trigger util: `utils/dbt_cloud.create_dbt_cloud_task_group`.
- SELECT-only investigative access: conn `FAN_DATA_EXCHANGE_PROD`, role `FES_DATA_DEVELOPER`,
  wh `FDE_DEVELOPER_3XL_WH`.
