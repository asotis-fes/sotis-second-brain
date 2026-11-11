# Missing Fields — New Loyalty Backend Test Sources vs. Old Ledger Lineage

**Goal**: Provide feedback to the loyalty backend team on what fields are
required in the new sources (`FES_USERS.ANNA_SMITH.LOYALTY_TEST_*`) to
recreate `one_credits_loyalty_analytics_ledger` and feed its downstream
lineage.

**Method**: For each candidate "missing field", verify that the OLD ledger
lineage actually reads it from source. Withdraw any claim that turns out to
be source-column-that-exists-but-is-never-read.

## What the ledger actually reads from old source columns

`one_credits_loyalty_analytics_ledger.sql` is the only model in scope as
"the ledger". Walking its SELECT / JOIN chain:

| Source model           | Columns read by ledger                                             |
|------------------------|---------------------------------------------------------------------|
| `journal_normalized`   | `journal_id, program_id, created_at, cause, reason, balance_available_minor, balance_pending_minor` (last two derived from `journal.metadata:balance.available[_minor] / pending[_minor]`) |
| `entry`                | `account_id, journal_id, direction, amount_minor` (or `amount`, coalesced) |
| `opco_program_account` | `account_id, loyalty_id`                                            |
| `system_loyalty_account` | `loyalty_id` (presence check only, for `is_user_level_ledger`)    |
| `loyalty_private_fan_id_map` | `loyalty_account_id, private_fan_id`                          |

Confirmed by reading `journal_normalized.sql`, `entry.sql`,
`opco_program_account.sql`, `system_loyalty_account.sql`,
`loyalty_private_fan_id_map.sql`, and the ledger SQL itself.

Also relevant in the lineage:
- `loyalty_one_credits_balance_daily_snapshot.sql` reads
  `opco_program_account.account_id, opco_program_account.loyalty_account_id`,
  `program_account_balance.available_minor, .pending_minor, .updated_at`,
  `loyalty_private_fan_id_map.private_fan_id`, and
  `system_loyalty_account.loyalty_account_id` (presence check).
- Three downstream consumers (`one_credits_loyalty_analytics_ledger_fbg`,
  `pfi_one_credits_daily_issuance`, `daily_one_credit_issuance`,
  `pfi_fanatics_one_attributes`) read only from the ledger's own emitted
  columns (`private_fan_id`, `created_at`, `amount_minor`, `available_minor`,
  `reason`, `direction`, `is_user_level_ledger`). None of them read
  `account_id` from the ledger output.

## Verified-via-prod-INFORMATION_SCHEMA real columns on old `*_EXT` tables

So we're comparing like-for-like to the new schema:

- **`JOURNAL_EXT`**: VALUE, JOURNAL_ID, PROGRAM_ID, CREATED_AT, EXTERNAL_ID,
  CAUSE, ACTOR, REASON, SITE_ID, TENANT_ID, REF_ID, REF_ID_TYPE, **METADATA**,
  REVERSED_JOURNAL_ID, PREV_HASH, THIS_HASH, SOURCE_FILE_NAME, UPLOAD_TS,
  UPLOAD_DATE
- **`ENTRY_EXT`**: VALUE, ENTRY_ID, JOURNAL_ID, ACCOUNT_ID, DIRECTION, STATE,
  AMOUNT_MINOR, AMOUNT, AVAILABLE_AT, EXPIRES_AT, ENTRY_TYPE, CAMPAIGN_CODE,
  METADATA, SOURCE_FILE_NAME, UPLOAD_TS, UPLOAD_DATE
- **`OPCO_PROGRAM_ACCOUNT_EXT`**: VALUE, ACCOUNT_ID, LOYALTY_ID, PROGRAM_ID,
  OPCO_ID, STATUS, CREATED_AT, UPDATED_AT, SOURCE_FILE_NAME, UPLOAD_TS, UPLOAD_DATE
- **`SYSTEM_LOYALTY_ACCOUNT_EXT`**: VALUE, OPCO_ID, LOYALTY_ID, CREATED_AT,
  SOURCE_FILE_NAME, UPLOAD_TS, UPLOAD_DATE
- **`PROGRAM_ACCOUNT_BALANCE_EXT`**: VALUE, ACCOUNT_ID, AVAILABLE_MINOR,
  AVAILABLE, PENDING_MINOR, PENDING, UPDATED_AT, EARNED, METADATA,
  SOURCE_FILE_NAME, UPLOAD_TS, UPLOAD_DATE

## Critical missing fields in the new test schema

### 1. Per-event balance snapshot — nowhere in the new source

**Old source**: `journal.metadata` carries `{"available": N, "pending": N}` (or
older `{"available_minor": N, "pending_minor": N}`) — the source-of-truth
balance **as of that event**. Populated on every row in prod.

**Old ledger usage**: `journal_normalized.sql` unpacks this to
`balance_available_minor` and `balance_pending_minor`; the ledger emits these
as `available_minor` and `pending_minor` on every row.

**Due diligence across the new schema**: we profiled all 14 `loyalty_test_*`
tables to confirm the snapshot doesn't live somewhere we hadn't noticed.

*All 4 `metadata` VARIANT columns are 100% empty in the test data*:

| Table                          | Total rows | Populated metadata |
|--------------------------------|-----------:|-------------------:|
| `loyalty_test_transaction`     |         60 |                  0 |
| `loyalty_test_auth_hold`       |         15 |                  0 |
| `loyalty_test_capture_event`   |         10 |                  0 |
| `loyalty_test_void_auth_event` |          5 |                  0 |

*All balance-named columns across all 14 tables, and why none of them serve
as a per-event user-level balance snapshot*:

| Column                                                  | Semantics                                  | Substitute? |
|---------------------------------------------------------|--------------------------------------------|:-----------:|
| `account_balance.{available, pending, maturing}`        | Current state, 1 row per (loyalty, program) | No — no history |
| `bucket.{available_balance, pending_balance}`           | Current state per bucket                   | No — bucket-level, not user-level, no history |
| `auth_bucket_hold.{available_balance, pending_balance}` | Per-bucket portion of a specific AUTH      | No — auth-specific, not a balance snapshot |
| `allocation_remaining.{remaining, original}`            | FIFO accounting per earn-bucket            | No — earn-side residue, not a user balance |
| `void_remaining.remaining`                              | FIFO accounting after voids                | No — same |

Confirmed: the per-event balance snapshot is genuinely absent from the new
source. The information needed to populate `available_minor` /
`pending_minor` on the ledger does not exist anywhere in the new schema.

**Downstream consequence**: every model that reads `available_minor` or
`pending_minor` from the ledger output (`pfi_fanatics_one_attributes`,
`pfi_one_credits_daily_issuance`, `daily_one_credit_issuance`,
`loyalty_one_credits_balance_daily_snapshot`) is now reading a window-sum
reconstruction instead of source truth.

**Ask**: Will the new loyalty service emit a per-event balance snapshot
(matching the old `journal.metadata.balance` contract)? If yes, on which
table and under what key. If no, downstream models that depend on
`available_minor` from the ledger need to be told they're now consuming a
reconstruction.

### 2. Ingest metadata: `UPLOAD_TS` / `UPLOAD_DATE` (or equivalent)

**Old source**: Every `*_EXT` table has `SOURCE_FILE_NAME, UPLOAD_TS,
UPLOAD_DATE` added by Snowpipe/external-table ingestion.

**Old ledger usage**: every source-layer model in
`fes-airflow/dags/dbt/models/loyalty/source/*.sql` uses the same dedupe
pattern:
```sql
QUALIFY row_number() OVER (PARTITION BY <pk> ORDER BY upload_ts DESC) = 1
```
This is required because the same logical row can land in the external
location more than once (retried Snowpipe loads, replays, etc.) and we must
keep the most recently uploaded version.

**New source**: `loyalty_test_transaction` and the other `loyalty_test_*`
tables have no `upload_ts` / `upload_date` / `source_file_name`. The test
data is a clean one-shot load, but production ingest will need this
convention (or an equivalent).

**Ask**: What's the planned ingest pattern? External tables with Snowpipe
metadata columns (matching the existing convention)? CDC stream with
sequence numbers? Snowflake `LAST_UPDATED_TS`? Whatever the answer, we need
a column to dedupe on, and we need to know it before writing the new source
layer.

### 3. `reason` vocabulary alignment — semantic, not structural

This isn't a missing **column** (both old and new have `reason`). It's a
missing **value** in the vocabulary that the downstream models depend on.

**Old prod `journal.reason` for program_id=3 distinct values**: `GOODWILL,
PURCHASE, REDEEM_FANCASH, REDEEM_ITEM, REFUND, TIER_POINTS_CONVERSION,
TIER_POINTS_STATUS_MATCH_COMPLETE, VOID, NULL`.

**Anna's test data `reason` distinct values**: `WAGER, SPORTS_BOOK_BETTING,
CASINO_BETTING, BONUS_BET_CONVERSION, APPEASEMENT, GOODWILL, REFUND,
BONUS_SETTLEMENT, MIGRATION, PURCHASE, GOODWILL_APPEASEMENTS, VOID,
BACKOFFICE`.

**Downstream usage** (`pfi_one_credits_daily_issuance`,
`daily_one_credit_issuance`):
```sql
SELECT ...
FROM {{ ref('one_credits_loyalty_analytics_ledger') }}
WHERE
    is_user_level_ledger = TRUE
    AND reason = 'PURCHASE'
    AND direction = 'DEBIT'
```

**The specific gap**: this filter is looking for credits **spent on a
purchase** — i.e. a non-fancash redemption. In Anna's data, `PURCHASE` only
appears on an ADD (CREDIT) row, never on a DEBIT row. Either the test data
is incomplete for this case, or the new system isn't producing
`reason='PURCHASE'` on debit/redeem rows at all.

**Additionally**: old vocabulary had `REDEEM_FANCASH` and `REDEEM_ITEM`
which distinguished where a credit was spent. New vocabulary collapses all
redemption-side reasons into sportsbook-flavored values
(WAGER/SPORTS_BOOK_BETTING/CASINO_BETTING). If credits will continue to be
usable on the Fanatics commerce/retail side, that channel needs a reason
value the downstream filter can match on.

**Ask**: Will the new loyalty service emit `reason='PURCHASE'` (or some
equivalent) on debit rows when a credit is redeemed for a non-bet purchase?
If the reason vocabulary is fundamentally changing, the two downstream
issuance models need to know.

## Withdrawn from the missing-fields list (with reason)

These were on my initial list. After verifying against the actual ledger
SQL, they're either not consumed by this lineage or have a clean substitute
in the new schema.

| Field                          | Status     | Reason                                                                                          |
|--------------------------------|------------|-------------------------------------------------------------------------------------------------|
| `account_id`                   | Withdraw   | Old ledger uses it as entry↔opco join key and emits it. Downstream doesn't read `o.account_id`. New ledger joins on `loyalty_id` directly. |
| `opco_id`                      | Withdraw   | Only used by `system_loyalty_account` for the `is_user_level_ledger` presence check. New model has no system-bucket entries; constant `TRUE` is semantically correct. |
| `status` on account            | Withdraw   | Selected in `opco_program_account.sql` but never referenced by the ledger or its downstreams.   |
| `prev_hash` / `this_hash`      | Withdraw   | Real columns on `JOURNAL_EXT` but never read by the ledger lineage. Audit-side concern only.    |
| `state` on entry               | Withdraw   | Selected in `entry.sql` but never referenced by the ledger or its downstreams.                  |
| `earned` on `account_balance`  | Withdraw   | `program_account_balance.sql` selects it, but `loyalty_one_credits_balance_daily_snapshot.sql` only reads `available_minor`, `pending_minor`, `updated_at`. |
| `updated_at` on transaction    | Withdraw   | Old `JOURNAL_EXT` doesn't have `UPDATED_AT` either — journal is immutable in the source system. Not a regression. |
| Test-transaction flag          | Withdraw   | `is_test_transaction` exists on `tier_points_ledger`, not on journal/entry. The credits lineage filters tests via `pfi_customer_mart.test = 0`, not on the journal. |
| `idempotency_keys` table       | Withdraw   | Separate source model. Ledger never reads it.                                                   |

## Open questions for the source team (priority order)

1. **Per-event balance snapshot** — yes/no, and if yes under what JSON key.
   This is the only "blocks-the-ledger" question.
2. **Ingest plumbing convention** — `upload_ts`, CDC, or other dedupe key.
   Blocks writing the new source-layer dbt models.
3. **`reason='PURCHASE'` on debits** — confirms whether non-bet credit
   redemptions will be detectable downstream, or whether the two issuance
   models need rewiring.

## What we do NOT need to ask about

The new schema has no system-bucket account concept (no
`system_loyalty_account` equivalent). That's fine — the old `is_user_level_ledger`
flag exists only to filter out system rows, and there are no system rows in
the new model. We can hard-code `TRUE`.

The new schema has no `account_id`/`opco_id`/`status`. That's fine for the
ledger — the new model joins transactions directly to `loyalty_id` and
emits one row per user-level transaction.

The new schema does carry `tenant_id, site_id, jurisdiction, bucket_id,
entry_type` etc. — richer than what the old ledger output exposed. The
revised draft passes these through as new columns.

---

**Files in this workspace**:
- `mapping.md` — full old→new field map + slack-derived business rules
- `ledger_v2_draft.sql` — rev 4 draft (per-transaction, no collapse, anomaly flag)
- `validation_queries.sql` — sanity-check queries
- `missing_fields.md` — this document
