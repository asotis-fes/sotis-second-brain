# FES Loyalty — Database Schema Reference

This document is the consolidated schema reference for the FES Loyalty system — an immutable transaction ledger for loyalty programs (Credits, FanCash, TierPoints). It covers table definitions, enum types, and design notes for both data/analytics and engineering audiences.

## Table of Contents

- [Overview](#overview)
- [Entity Relationship Diagram](#entity-relationship-diagram)
- [Enum Types](#enum-types)
- [Identity & Reference Tables](#identity--reference-tables)
- [Ledger Tables](#ledger-tables)
- [Auth/Capture Tables](#authcapture-tables)
- [Idempotency](#idempotency)
- [Mapper Tables](#mapper-tables)
  - [`account_metadata`](#account_metadata)
- [Deprecated Tables](#deprecated-tables)

---

## Overview

The schema implements an **immutable transaction ledger**. Key design principles:

| Principle | Description |
|-----------|-------------|
| **Immutable Ledger** | The `transaction` table is append-only (updates/deletes trigger exceptions) |
| **Single-Row Transactions** | One row per operation (ADD/AUTH/CAPTURE/VOID/EXPIRY) — no double-entry |
| **Idempotency** | External IDs prevent duplicate transaction processing |
| **Lazy Provisioning** | Accounts are created on first transaction using deterministic UUIDs |
| **FEFO Burn** | FanCash earn lots are consumed earliest-expiring-first via the allocation worker |

---

## Entity Relationship Diagram

Live Lucidchart ERD: [Open in Lucidchart](https://lucid.app/lucidchart/3faa0c14-2ae9-4371-8e99-605e185657b3/edit?viewport_loc=-124%2C38%2C2260%2C1329%2Cp1&invitationId=inv_4b3d3248-f6b6-4459-b57f-841debfa7142)

```
IDENTITY & ACCOUNTS
═══════════════════

┌──────────────────────┐     ┌─────────────────────────────────────────────────┐
│   loyalty_account    │     │  bucket_type ★                                  │
│   (root identity)    │     │  (program_id, tenant_id, site_id,               │
└──────────┬───────────┘     │   jurisdiction, entry_type)                     │
           │ 1:N             └───────────┬───────────────────┬─────────────────┘
           │                             │ 1:N               │ both columns FK here
           ├──────────────┐              │                   ▼
           │              │              │    ┌──────────────────────────────────┐
           │              │              │    │  transfer_restriction ★          │
           │              │              │    │  (from_bucket_type_id,           │
           │              │              │    │   to_bucket_type_id,             │
           │              │              │    │   starts_at, ends_at)            │
           │              │              │    └──────────────────────────────────┘
           │              ▼              ▼
           │       ┌──────────────────────────────────────────────┐
           │       │  bucket ★                                    │
           │       │  (bucket_id PK, bucket_type_id,              │
           │       │   loyalty_id, program_id,                    │
           │       │   expires_at NOT NULL, available_at NOT NULL,│
           │       │   available_balance, pending_balance,        │
           │       │   is_matured bool)                           │
           │       └──────────────┬───────────────────────────────┘
           │                      │ N:1 (sum)
           │                      ▼
           │       ┌──────────────────────────────────┐
           │       │ account_balance ★                │
           │       │ (aggregate per loyalty×program;  │
           │       │  available, pending, maturing)   │
           │       └──────────────────────────────────┘
           │ 1:N
           ▼
   ┌──────────────────────────────────────┐
   │  account_metadata ✦                  │
   │  (metadata per loyalty×program;      │
   │  tier points, current_period_tier)   │
   └──────────────────────────────────────┘

LEDGER & AUTH
═════════════

┌────────────────────────────────────────────────────────────────┐
│  transaction ★                                                 │
│  (one row per operation: ADD/AUTH/CAPTURE/VOID/EXPIRY;           │
│   immutable, append-only)                     │
└──────────────────────────────┬─────────────────────────────────┘
                               │ 1:1 (ADD rows only)
                               ▼
                  ┌────────────────────────────┐     ┌──────────────────────────────────┐
                  │  allocation_remaining ★    │     │  void_remaining ★                │
                  │  (un-burned remaining per  │     │  (un-voided remaining per        │
                  │   earn lot; O(1) FEFO gate;│     │   earn lot; main Postgres;       │
                  │   allocation Postgres)     │     │   sync read/write)               │
                  └────────────────────────────┘     └──────────────────────────────────┘
                               │
          ┌────────────────────┴──────────────────┐
          │ earn_transaction_id   consume_transaction_id
          ▼                                        ▼
┌──────────────────────────────────────────────────┐
│  allocation ★                                    │
│  (earn→burn/expiry link; immutable, append-only) │
└──────────────────────────────────────────────────┘

┌─────────────────────┐       ┌───────────────────────────┐
│      auth_hold      │◄──────│  auth_bucket_hold ★       │
│ (aggregate hold)    │       │  (per-bucket drain at     │
└─────────┬───────────┘       │   AUTH sync time)         │
          │                   └───────────────────────────┘
     ┌────┴──────┐
     ▼           ▼
┌──────────┐  ┌──────────────────────────────┐
│ capture_ │  │ void_auth_event               │
│ event    │  └──────────────────────────────┘
└──────────┘

ASYNC OUTBOX
════════════

┌──────────────────────────────────────────────┐
│  job_queue ★                                 │
│  type: ALLOCATION | VOID_ADD |               │
│         EXPIRY | VOID_BALANCE                │
│  status: PENDING → PROCESSING → DONE/FAILED  │
│  payload (JSONB): auth_transaction_id,       │
│                   loyalty_id, remaining, …   │
└──────────────────────────────────────────────┘
  Written by sync phase (same transaction as ADD/AUTH/etc.).
  Consumed by fes-loyalty-consumer workers.

★ = new tables added in migration 000012
✦ = new table added in migration 000013 (account_metadata)
```

---

## Enum Types

### `transaction_type`

Operation type for each row in the `transaction` table.

| Value | Description |
|-------|-------------|
| `ADD` | Points/FanCash earned and credited to account |
| `AUTH` | Authorization hold placed on balance |
| `CAPTURE` | Finalize a previous authorization (burn) |
| `VOID` | Release an authorization hold (VOID_AUTH path) or reverse a previous ADD (VOID_ADD path) |
| `EXPIRY` | Points/FanCash expired due to TTL |

### `entry_type`

Type of earn lot. Replaces the former `credit_entry_type` enum. Used by both FanCash bucket entries and Credits entries. Credits entries use only `BASE`/`PROMO`; FanCash adds `GIFT`/`PURCHASE`.

| Value | Description |
|-------|-------------|
| `BASE` | Standard earned value; uses default program expiration |
| `PROMO` | Promotional/bonus value; uses short fixed expiration |
| `GIFT` | Points/FanCash transfer between accounts |
| `PURCHASE` | Value earned by buying points or FanCash |

> **Declaration order is load-bearing — do not reorder, and add new values deliberately.** AUTH's eligible-bucket selection (`GetBurnableBuckets`) sorts by `entry_type DESC` as a FEFO tie-break, so on an `expires_at` tie the value latest in the enum's declaration order drains first. With the current order `('BASE', 'PROMO', 'GIFT', 'PURCHASE')`, `DESC` yields `PURCHASE > GIFT > PROMO > BASE` (promo/gift/purchase burn before base). Postgres compares enums by declaration order, **not** alphabetically. `ALTER TYPE entry_type ADD VALUE` *appends* by default, placing a new value last → highest burn priority under `DESC`; if that isn't intended, position it explicitly with `ADD VALUE '…' BEFORE '…'`.

### `ref_id_type`

External reference identifier type for traceability.

| Value | Description |
|-------|-------------|
| `BET_ID` | Sportsbook bet reference |
| `ORDER_ID` | E-commerce order reference |
| `FANCASH_ID` | FanCash transaction reference |
| `BACKOFFICE_ID` | Internal backoffice/admin reference |

### `reason_type`

Business reason for the transaction (audit & reporting).

| Value | Use Case |
|-------|----------|
| `PURCHASE` | E-commerce purchase earning |
| `WAGER` | Generic betting wager |
| `SPORTS_BOOK_BETTING` | Sportsbook betting activity |
| `CASINO_BETTING` | Casino betting activity |
| `REFUND` | Transaction refund |
| `APPEASEMENT` | Customer service credit |
| `GOODWILL` | Goodwill gesture/compensation |
| `GOODWILL_APPEASEMENTS` | Legacy combined goodwill/appeasement reason (000001) |
| `MIGRATION` | Data migration from legacy system |
| `SYSTEM_ERROR` | Correction for system error |
| `RECONCILE_NEGATIVE` | Reconciliation of negative balance |
| `BONUS_BET_CONVERSION` | Bonus bet converted to credits |
| `BONUS_SETTLEMENT` | Bonus bet settlement |
| `BONUS_BET_CONVERSION_REFUND` | Refund of bonus conversion |
| `RETAIL_SPORTS_BOOK` | Retail sportsbook activity |
| `CASINO_CREDIT_CONVERSION` | Casino credits converted |
| `PROFIT_BOOST_CONVERSION` | Profit boost converted |
| `BOOST_CONVERSION_REFUND` | Refund of boost conversion |
| `BONUS_BET_CASHOUT` | Bonus bet cashed out |
| `SWEEPS_ENTRY` | Sweepstakes entry |
| `FANCASH_WAGERED` | FanCash used in wager |
| `FANCASH_WAGERED_RESETTLEMENT` | FanCash wager resettlement |
| `FANCASH_WAGERED_REFUND` | FanCash wager refund |
| `FANCASH_WAGERED_CASHOUT` | FanCash wager cashout |
| `FANCASH_PURCHASED` | FanCash purchased |
| `TIER_POINTS_CONVERSION` | Tier points converted to credits |
| `TIER_POINTS_STATUS_MATCH_COMPLETE` | Tier status match completed |
| `REDEEM_ITEM` | Item redeemed from loyalty program |
| `REDEEM_FANCASH` | FanCash redeemed from loyalty program |
| `VOID` | Transaction voided/reversed |
| `BONUS_AWARD` | Award from the Bonus Engine |

### `tier_override_type`

Type of tier override (for tier management).

| Value | Description |
|-------|-------------|
| `PLACEMENT` | Direct placement into tier |
| `ROLLOVER` | Rollover-based tier override |
| `STATUS_MATCH` | Match tier from external program |

### `tier_override_reason`

Business reason for a tier account override.

| Value | Use Case |
|-------|----------|
| `COMPETITOR_MATCH` | Match based on competitor tier |
| `END_OF_YEAR_ROLLOVER` | End-of-year rollover adjustment |
| `MANUAL_DOWNGRADE` | Manual downgrade by operator |
| `MANUAL_UPGRADE` | Manual upgrade by operator |
| `NEAR_THRESHOLD_TRIAL` | Trial granted near tier threshold |
| `NEW_YEAR_ADJUSTMENT` | New year tier adjustment/reset |
| `ONEBLACK_APPROVAL_GRANTED` | OneBlack approval granted |
| `ONEBLACK_APPROVAL_REVOKED` | OneBlack approval revoked |
| `OTHER` | Catch-all for uncategorized reasons |
| `PROMOTIONAL_ADJUSTMENT` | Promotion or campaign-based adjustment |
| `RESET_OVERRIDE` | System/manual reset of override |
| `STATUS_MATCH_BOOST` | Boost applied within status match flow |
| `STATUS_MATCH_FALLBACK` | Fallback when status match criteria are not fully met |
| `STATUS_MATCH_REISSUE` | Re-issued or restarted status match for the user |
| `SYSTEM_ADJUSTMENT` | Automated system-driven adjustment |
| `TEST_OVERRIDE` | Test or non-production override |
| `VIP_OVERRIDE` | VIP customer override |

### `job_queue_type`

Type of async background job.

| Value | Description |
|-------|-------------|
| `ALLOCATION` | Link earn lots to a CAPTURE burn transaction (FEFO, cursor-checkpointed) |
| `VOID_ADD` | Decrement `allocation_remaining` for the earn lot and other lots in FEFO order across the bucket list. `void_remaining` is not touched by async — it was already upserted (inserted on first void, decremented on re-void) by VOID_ADD sync before the job was enqueued. |
| `EXPIRY` | Bucket-wide scan: link all earn lots in expired bucket to expiry transaction; zero `allocation_remaining` per lot. `void_remaining` is zeroed by EXPIRY sync (not here). |
| `VOID_BALANCE` | FEFO scan of earn lots via `allocation_remaining`; write allocation rows linking earn lots to the VOID transaction; decrement `allocation_remaining` in cursor-checkpointed batches. `void_remaining` is not touched — VOID_BALANCE is a balance-level operation, not a per-earn-transaction void. |

### `job_queue_status`

Status of an async background job in `job_queue`.

| Value | Description |
|-------|-------------|
| `PENDING` | Waiting to be claimed by a worker |
| `PROCESSING` | Currently being processed (locked) |
| `DONE` | Completed successfully |
| `FAILED` | Exhausted max attempts |

### `tier_invite_status`

Status for invite-only tier approvals.

| Value | Description |
|-------|-------------|
| `APPROVED` | Invite is currently approved |
| `REVOKED` | Invite was revoked |

---

## Identity & Reference Tables

### `loyalty_account`

Root identity table for all loyalty members. Represents a loyalty identity — usually a user.

| Column | Type | Description |
|--------|------|-------------|
| `loyalty_id` | UUID PK, default `gen_random_uuid()` | Primary key and global loyalty identifier. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When this loyalty account record was created. |

---

### `program`

Reference table for loyalty programs like FanCash, TierPoints, or Credits.

| Column | Type | Description |
|--------|------|-------------|
| `program_id` | BIGSERIAL PK | Primary key for the program. |
| `code` | TEXT UNIQUE NOT NULL | Program code (e.g., `'FANCASH'`, `'TIERPOINTS'`, `'CREDITS'`). |
| `display_name` | TEXT NOT NULL | Human-readable program name. |
| `is_active` | BOOLEAN NOT NULL DEFAULT TRUE | Whether this program accepts transactions. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When the program was created. |
| `updated_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When the program was last updated. |
**Unique Constraint**: `(code)`

**Seed Data**:

| program_id | code | display_name |
|------------|------|--------------|
| 1 | FANCASH | FanCash |
| 2 | TIERPOINTS | Tier Points |
| 3 | CREDITS | Credits |

---

## Ledger Tables

### `transaction`

Immutable single-row transaction log. One row per operation. Replaces the former `journal` + `entry` double-entry model (migration 000012).

**Partitioned by `RANGE (created_at)`, monthly** (migration 000012). Allocation workers no longer scan `transaction` directly — FEFO queries go through `allocation_remaining` (which carries `bucket_id`). `transaction` is accessed only by the API (ledger, balance history) with `created_at` date-range filters, so partition pruning is effective. Inbound FK constraints from all dependent tables intentionally omitted — allows row-level DELETE and `DROP PARTITION` without FK cascade. The immutability trigger (UPDATE only) prevents field-level changes; DELETEs are allowed for eviction. Stage 1: row-level DELETE where `allocation_remaining.remaining = 0` and past retention. Stage 2: `DROP PARTITION` after confirmed replication to allocation Postgres.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK (composite with `created_at`) | UUIDv7 internal primary key, generated by consumer/storage at write time. Time-ordered for efficient B-tree inserts and FEFO scans. All companion tables reference this column. |
| `transaction_id` | UUID NOT NULL | Deterministic `UUIDv5(seed, external_id)` — computed by the program service before publishing to Kafka. Returned to API callers. Callers always use this for references (VOID_ADD, CAPTURE, etc.). Indexed via `idx_transaction_lookup(loyalty_id, program_id, transaction_id)`. Uniqueness enforced by `idempotency_keys`. |
| `program_id` | BIGINT NOT NULL FK → `program(program_id)` | Program whose ledger this transaction belongs to. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer identity. |
| `type` | `transaction_type` NOT NULL | Operation type: `ADD`, `AUTH`, `CAPTURE`, `VOID`, `EXPIRY`. |
| `amount` | NUMERIC(18,6) NOT NULL CHECK (`amount > 0`) | Positive magnitude. `type` determines the semantic direction. |
| `bucket_id` | UUID FK → `bucket(bucket_id)` | FanCash bucket this transaction belongs to. NULL for pre-FC Credits/TierPoints rows. |
| `entry_type` | `entry_type` | Earn lot sub-classification (`BASE`, `PROMO`, `GIFT`, `PURCHASE`). NULL for burn/auth operations. |
| `campaign_code` | TEXT | Optional campaign identifier for promotional earns. |
| `expires_at` | TIMESTAMPTZ | Expiry time for this earn lot (ADD only). |
| `available_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When this earn becomes spendable. |
| `external_id` | TEXT | Business reference / idempotency key (order ID, bet ID, etc.). |
| `actor` | TEXT NOT NULL DEFAULT `'system'` | Who initiated the action (`api`, `system`, `backoffice`, service name). |
| `reason` | `reason_type` | Business reason for the transaction. |
| `site_id` | INTEGER | Site identifier (multi-tenant). |
| `tenant_id` | INTEGER | Tenant identifier (multi-tenant). |
| `ref_id` | TEXT | External reference ID (bet_id, order_id, etc.). |
| `ref_id_type` | `ref_id_type` | Type of the ref_id. |
| `jurisdiction` | TEXT | Regulatory/legal jurisdiction of the transaction. |
| `reversed_transaction_id` | UUID | References the ADD `transaction.id` this VOID_ADD reverses. FK intentionally omitted. NULL for non-reversal types. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Creation timestamp. Partition key. |

**Primary Key**: `(id, created_at)` — partition key must be included in PK.
**Uniqueness**: `(loyalty_id, program_id, transaction_id)` — enforced by `idempotency_keys` table. Since `transaction_id` is deterministic (`UUIDv5(seed, external_id)`), this also guarantees `external_id` uniqueness per user/program. No separate `external_id` unique index needed.
**Immutability**: UPDATE blocked by `transaction_immutable_u` trigger; DELETE allowed for eviction.

> **Dual ID design**: `id` (UUIDv7) is the internal row identity — time-ordered for write performance and used by all companion tables (allocation_remaining, auth_hold, etc.). `transaction_id` (UUIDv5) is the deterministic API-facing identity — same `external_id` always produces the same `transaction_id`, enabling the program service to return it before the consumer writes the row. This supports async ADD/VOID_ADD while keeping API responses deterministic.

---

### `allocation_remaining`

Mutable companion to the immutable `transaction` table for FEFO allocation tracking. Lives on the **allocation Postgres** instance. One row per FanCash ADD transaction with a bucket. Written exclusively by async workers. VOID_ADD sync may do a single PK read of `original` (on the first void of an earn lot) to seed `void_remaining` — this is the only sync read against this table; all writes remain async-only.

`bucket_id` and `original` are intentionally denormalized here (removes workers' and VOID_ADD sync's dependency on `transaction`). Both `transaction` and `allocation` can be independently partitioned by `RANGE (created_at)`.

| Column | Type | Description |
|--------|------|-------------|
| `transaction_id` | UUID NOT NULL PK | References `transaction.id` (UUIDv7). FK omitted — `transaction` is partitioned. Time-ordered for FEFO scan within a bucket (oldest earn first). |
| `loyalty_id` | UUID NOT NULL | Denormalized from `transaction`. FK → `loyalty_account`. |
| `bucket_id` | UUID NOT NULL | Denormalized from `transaction`. FK → `bucket`. |
| `remaining` | NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK ≥ 0 | Un-burned, un-expired amount. Initialized to ADD amount. Decremented by ALLOCATION, EXPIRY, VOID_ADD, and VOID_BALANCE async workers. Used by FEFO scan to skip fully consumed lots. |
| `original` | NUMERIC(18,6) NOT NULL CHECK > 0 | Original ADD amount. Written once at INSERT; never updated. Read by VOID_ADD sync on the first void of this earn lot to initialise `void_remaining` without a join to `transaction`. |
| `updated_at` | TIMESTAMPTZ NOT NULL | Last write timestamp. |

**Index**: `idx_ar_fefo ON (loyalty_id, bucket_id, transaction_id) WHERE remaining > 0` — covers the full FEFO scan predicate. `transaction_id` stores `transaction.id` (UUIDv7, time-ordered), so `ORDER BY transaction_id ASC` = oldest earn first.

---

### `void_remaining`

Tracks how much of each ADD earn transaction is still voidable. Lives on **main Postgres**. Created lazily — one row is inserted only when VOID_ADD first targets a given earn transaction. Subsequent VOID_ADD calls decrement `remaining`. EXPIRY sync zeroes `remaining` to 0 for all rows in the expired bucket, preventing post-expiry voids. Async workers never touch this table.

| Column | Type | Description |
|--------|------|-------------|
| `transaction_id` | UUID NOT NULL PK | References `transaction.id` (UUIDv7). FK omitted — `transaction` is partitioned. |
| `loyalty_id` | UUID NOT NULL | Denormalized from `transaction`. FK → `loyalty_account`. |
| `bucket_id` | UUID NOT NULL | Denormalized from `transaction`. FK → `bucket`. |
| `remaining` | NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK ≥ 0 | Un-voided amount. Seeded from `allocation_remaining.original` on the first void. Decremented on subsequent voids. Zeroed by EXPIRY sync. Default void ceiling in VOID_ADD sync when caller omits `amount`: `amount ?? void_remaining.remaining`. |
| `updated_at` | TIMESTAMPTZ NOT NULL | Last write timestamp. |

---

## Auth/Capture Tables

### `auth_hold`

Represents an authorization hold on a user's account. Tracks active holds (pending balance).

| Column | Type | Description |
|--------|------|-------------|
| `transaction_id` | UUID PK | References `transaction.id` (UUIDv7). FK omitted — `transaction` is RANGE-partitioned. |
| `amount` | NUMERIC(18,6) NOT NULL | Original held amount (immutable). Completeness determined by summing `capture_event` and `void_auth_event`. |
| `expires_at` | TIMESTAMPTZ | When the hold should auto-release (if not captured/voided). |
| `metadata` | JSONB NOT NULL DEFAULT `'{}'` | Extra info (merchant data, reason codes, etc.). |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When the hold was created. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer identity. Backfilled from `journal.loyalty_id` in migration 000012. |
**Primary Key**: `(transaction_id)`

---

### `capture_event`

Records capture of an authorization (partial or full). The actual ledger changes live in the referenced transaction.

| Column | Type | Description |
|--------|------|-------------|
| `transaction_id` | UUID PK | References `transaction.id` (UUIDv7). FK omitted — `transaction` is RANGE-partitioned. |
| `auth_transaction_id` | UUID NOT NULL | Original AUTH `transaction.id` being captured. FK → `auth_hold(transaction_id)`. |
| `amount` | NUMERIC(18,6) NOT NULL | Amount captured in this event. |
| `metadata` | JSONB NOT NULL DEFAULT `'{}'` | Extra contextual info (item, shipment, reasons). |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When this capture was recorded. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer identity. Backfilled from `journal.loyalty_id` in migration 000012. |
**Primary Key**: `(transaction_id)`

---

### `void_auth_event`

Records void/release of an authorization (partial or full) without spending. Renamed from `void_event` in migration 000012.

| Column | Type | Description |
|--------|------|-------------|
| `transaction_id` | UUID PK | References `transaction.id` (UUIDv7). FK omitted — `transaction` is RANGE-partitioned. |
| `auth_transaction_id` | UUID NOT NULL | Original AUTH `transaction.id` being voided. FK → `auth_hold(transaction_id)`. |
| `amount` | NUMERIC(18,6) NOT NULL | Amount voided (released) in this event. |
| `metadata` | JSONB NOT NULL DEFAULT `'{}'` | Extra contextual info. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When the void event was recorded. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer identity. Backfilled from `journal.loyalty_id` in migration 000012. |
**Primary Key**: `(transaction_id)`
**Note**: No unique constraint on `auth_transaction_id` — multiple partial voids against the same auth are supported (migration 000012). Uniqueness is enforced per-call via `idempotency_keys(loyalty_id, program_id, transaction_id)`.

---

## Idempotency

### `idempotency_keys`

Prevents duplicate transaction processing. Ensures each (program, loyalty_id, transaction_id) combination runs at most once.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | Sequential UUIDv7 primary key. Added in migration 000012. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer identity. |
| `program_id` | BIGINT NOT NULL FK → `program(program_id)` | Program context for this idempotent action. |
| `external_id` | TEXT NOT NULL | Caller-provided idempotency key (request ID, business key). |
| `transaction_type` | `transaction_type` NOT NULL | Operation type that created this record (`ADD`, `VOID`, `AUTH`, `CAPTURE`). Renamed from `journal_cause` in migration 000012; type cast from `journal_cause` to `transaction_type` enum. |
| `transaction_id` | UUID NOT NULL | Deterministic `UUIDv5(seed, external_id)` — the API-facing transaction ID. Maps to `transaction.transaction_id`. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | When this idempotency record was created. Immutable — `updated_at` removed in migration 000012. |
**Unique Constraint**: `(loyalty_id, program_id, transaction_id)` — since `transaction_id = UUIDv5(seed, external_id)`, this enforces one-per-external_id per user/program.

---

## Mapper Tables

These tables are the new unified model for Credits, FanCash, and TierPoints. They cover lot tracking (`bucket`, `bucket_type`), balance aggregation (`account_balance`), auth holds (`auth_bucket_hold`), transfer rules (`transfer_restriction`), async work (`job_queue`), and the earn-burn mapper itself (`allocation`).

### `bucket_type`

Dimension table: one row per (program × tenant × site × jurisdiction × entry_type). `bucket_type_id` is a deterministic UUIDv5 computed by the application — used as the PK and FK target by other tables.

| Column | Type | Description |
|--------|------|-------------|
| `bucket_type_id` | UUID PK | Deterministic UUIDv5 business key (application-computed). |
| `program_id` | BIGINT NOT NULL FK → `program(program_id)` | Program scope. |
| `tenant_id` | INTEGER NOT NULL DEFAULT 0 | Tenant identifier (0 = program-wide). |
| `site_id` | INTEGER NOT NULL DEFAULT 0 | Site identifier (0 = all sites). |
| `jurisdiction` | TEXT NOT NULL DEFAULT '' | Jurisdiction code (empty string = all jurisdictions). |
| `entry_type` | `entry_type` NOT NULL | Type of earn: `BASE`, `PROMO`, `GIFT`, or `PURCHASE`. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Creation timestamp. |

**Unique Constraint**: `(program_id, tenant_id, site_id, jurisdiction, entry_type)` — sentinel values (0, '') replace NULLs for "all" semantics, so a plain unique index suffices.

---

### `bucket`

One earn lot per (loyalty_id × program_id × bucket_type × available_at × expires_at).

| Column | Type | Description |
|--------|------|-------------|
| `bucket_id` | UUID PK | Application-supplied UUID. UUIDv5(`program_id`, `loyalty_id`, `bucket_type_id`) for BASE rolling buckets — deterministic, enables lock-free `ON CONFLICT (bucket_id) DO NOTHING`. UUIDv7 for all other entry types (PROMO, GIFT, PURCHASE). |
| `bucket_type_id` | UUID NOT NULL FK → `bucket_type(bucket_type_id)` | Dimension this lot belongs to. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Owner identity. |
| `program_id` | BIGINT NOT NULL FK → `program(program_id)` | Program scope. |
| `expires_at` | TIMESTAMPTZ NOT NULL | Expiry time for this lot. |
| `available_at` | TIMESTAMPTZ NOT NULL DEFAULT `NOW()` | When lot becomes spendable. Defaults to `NOW()` for immediately-available buckets; set to a future timestamp for maturing buckets. |
| `is_matured` | BOOLEAN NOT NULL DEFAULT TRUE | Whether lot is ready to spend. |
| `available_balance` | NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK ≥ 0 | Spendable balance. |
| `pending_balance` | NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK ≥ 0 | Balance under active AUTH holds. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Creation timestamp. |
| `updated_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Last balance update. |
**Unique Constraint**: `(loyalty_id, program_id, bucket_type_id, expires_at, available_at)`

---

### `account_balance`

Aggregate balance per `(loyalty_id × program_id)`. Maintained in sync with `bucket` by every write that modifies available/pending/maturing balances.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | Application-supplied UUIDv7 primary key. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Owner identity. |
| `program_id` | BIGINT NOT NULL FK → `program(program_id)` | Program scope. |
| `available` | NUMERIC(18,6) NOT NULL DEFAULT 0 | Spendable now. |
| `pending` | NUMERIC(18,6) NOT NULL DEFAULT 0 | Under active AUTH holds. |
| `maturing` | NUMERIC(18,6) NOT NULL DEFAULT 0 | Earned but `available_at > NOW()`. |
| `updated_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Last update. |
**Unique Constraint**: `(loyalty_id, program_id)`

---

### `transfer_restriction`

Deny-list of blocked `(from_bucket_type_id, to_bucket_type_id)` pairs. All pairs allowed by default; exceptions listed here.

| Column | Type | Description |
|--------|------|-------------|
| `restriction_id` | UUID PK | Application-supplied UUIDv7 primary key. |
| `from_bucket_type_id` | UUID NOT NULL FK → `bucket_type(bucket_type_id)` | Source type. |
| `to_bucket_type_id` | UUID NOT NULL FK → `bucket_type(bucket_type_id)` | Destination type. |
| `starts_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Restriction start. |
| `ends_at` | TIMESTAMPTZ | Restriction end (null = indefinite). |

---

### `auth_bucket_hold`

Per-bucket amounts drained during an AUTH sync. Bridges AUTH → async ALLOCATION and VOID_AUTH workers.

| Column | Type | Description |
|--------|------|-------------|
| `auth_bucket_hold_id` | UUID PK | Application-supplied UUIDv7 primary key. |
| `auth_transaction_id` | UUID NOT NULL FK → `auth_hold(transaction_id)` | AUTH `transaction.id` (UUIDv7) this hold belongs to. |
| `available_balance` | NUMERIC(18,6) NOT NULL CHECK ≥ 0 | Still drainable for CAPTURE/VOID. |
| `pending_balance` | NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK ≥ 0 | Amount moved from `available_balance` at CAPTURE sync; used by ALLOCATION worker to scope the bucket — not modified by async workers. |
| `bucket_id` | UUID NOT NULL FK → `bucket(bucket_id)` | Customer bucket drained. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer loyalty identity. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Creation timestamp. |
**Unique Constraint**: `(auth_transaction_id, bucket_id)`

The original drain magnitude is recoverable as `available_balance + pending_balance + SUM(allocation.amount WHERE allocation references this auth)`.

---

### `allocation`

Final earn→burn/expiry link. Written by the ALLOCATION worker (CAPTURE path), VOID_ADD worker, and EXPIRY worker. Each row says "this operation consumed this amount from that earn transaction."

**Partitioned** by `RANGE (created_at)`, monthly. Old partitions are dropped once data is replicated to cold storage — works for both Stage 1 (single Postgres) and Stage 2 (allocation Postgres). This is the primary eviction mechanism for allocation data.

| Column | Type | Description |
|--------|------|-------------|
| `allocation_id` | UUID | Application-supplied UUIDv7. |
| `earn_transaction_id` | UUID NOT NULL | ADD `transaction.id` (UUIDv7) the funds came from. FK to `transaction` intentionally omitted — `transaction` is partitioned and referencing tables would need to carry `created_at`. |
| `consume_transaction_id` | UUID NOT NULL | CAPTURE/VOID/EXPIRY `transaction.id` (UUIDv7) that consumed them. FK to `transaction` intentionally omitted for the same reason. |
| `amount` | NUMERIC(18,6) NOT NULL | Amount consumed from this earn lot. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer loyalty identity. |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Creation timestamp. Partition key. |
**Primary Key**: `(allocation_id, created_at)` — partition key must be included in PK (PostgreSQL requirement).
**Uniqueness**: No unique index on `(earn_transaction_id, consume_transaction_id)` — a global unique constraint cannot span partitions and a per-partition index would require `created_at` in the conflict target. Duplicate prevention relies on worker idempotency logic. Application INSERT uses `ON CONFLICT DO NOTHING` as a safety net.

> ⚠️ **Deduplication required for consumers**: Because no DB-enforced unique constraint exists, crash-resume retries can produce duplicate rows with the same `(earn_transaction_id, consume_transaction_id)` pair across different partitions. Any downstream consumer (analytics, Snowflake, reporting) **must deduplicate on `(earn_transaction_id, consume_transaction_id)` before aggregating amounts.**

---

### `job_queue`

Async work queue for background workers (ALLOCATION, VOID). Workers claim jobs with `FOR UPDATE SKIP LOCKED` to prevent concurrent double-processing.

**Plain heap — not partitioned.** ClaimJob claims by `job_id` using `FOR UPDATE SKIP LOCKED`; partitioning would require `created_at` in every claim UPDATE, complicating the worker. Jobs complete quickly and the table stays small.

| Column | Type | Description |
|--------|------|-------------|
| `job_id` | UUID | Application-supplied UUIDv7. |
| `type` | `job_queue_type` NOT NULL | Job type: `ALLOCATION`, `VOID_ADD`, `EXPIRY`, `VOID_BALANCE`. |
| `status` | `job_queue_status` NOT NULL DEFAULT `'PENDING'` | `PENDING`, `PROCESSING`, `DONE`, `FAILED`. |
| `payload` | JSONB NOT NULL | Job-specific data. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Customer identity. Enables per-account job serialization via `idx_job_queue_loyalty`. |
| `program_id` | BIGINT FK → `program(program_id)` | Program scope for this job. |
| `attempt_count` | INT NOT NULL DEFAULT 0 | Attempts made. |
| `max_attempts` | INT NOT NULL DEFAULT 3 | Max allowed attempts. |
| `locked_until` | TIMESTAMPTZ | Lock expiry for stuck-job reaper. |
| `last_error` | TEXT | Last error message (if failed). |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Creation timestamp. |
| `started_at` | TIMESTAMPTZ | When last processing attempt began. |
**Primary Key**: `(job_id)`

---

### `account_metadata`

Durable per-loyalty, per-program metadata store. Separated from `account_balance` to keep the hot balance row small and to decouple metadata from `program_account_balance`, which will be dropped in a future migration.

Written by `lf_add` and `lf_void_add` when `p_balance_metadata IS NOT NULL`. Read by `lf_get_balance_with_metadata` via LEFT JOIN. One row per `(loyalty_id × program_id)`.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | Application-supplied UUIDv7 primary key. |
| `loyalty_id` | UUID NOT NULL FK → `loyalty_account(loyalty_id)` | Owner identity. |
| `program_id` | BIGINT NOT NULL FK → `program(program_id)` | Program scope. |
| `metadata` | JSONB NOT NULL DEFAULT `'{}'` | Program-specific metadata. For Credits: `credit_tier_points` (map of expiry → TP balance) and `current_period_tier` (OneBlack status UUID). |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Creation timestamp. |
| `updated_at` | TIMESTAMPTZ NOT NULL DEFAULT `now()` | Last update timestamp. |

**Unique Constraint**: `(loyalty_id, program_id)`

---

## Deprecated tables

These tables remain in the DB but will be phased out as programs migrate to the bucket model.

| Table | Status | Replaced by |
|---|---|---|
| `opco_program_account` | **Active — will be deprecated** | `bucket` |
| `program_account_balance` | **Active — will be deprecated** | `account_balance` |
| `system_loyalty_account` | **Active — will be deprecated** | — (house bucket concept removed) |
| `operating_company` | Legacy — will be deprecated | — |
| `journal` | **Dropped** (migration 000013) | `transaction` |
| `entry` | **Dropped** (migration 000013) | `transaction` |
| `entry_remaining` | Never created (design artifact) | `allocation_remaining`, `void_remaining` |
| `house_bucket` | Never created (design artifact) | — (house bucket concept removed before migration) |
| `void_event` | **Renamed** (migration 000012) | `void_auth_event` |

---