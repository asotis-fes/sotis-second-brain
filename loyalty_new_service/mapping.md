# Old → New Source Mapping (One Credits Ledger)

## TL;DR — Shape change

The new backend collapses the old **`journal` (header) + `entry` (1+ rows per journal)**
two-table pattern into a single **`loyalty_test_transaction`** table — one row per
ledger event, already tied directly to a `loyalty_id`. The old "opco program account"
hierarchy (`account_id` → `loyalty_id`) is gone; there is no separate "ledger
account" entity. The old `system_loyalty_account` concept that powered
`is_user_level_ledger` does not exist either.

## Business rules from the new-API team (Slack guidance)

The new backend exposes two spend patterns:

- **Pattern A — Auth/Capture**: intentional two-step. AUTH and CAPTURE arrive as two
  separate rows in the transaction stream, typically minutes apart. Each is
  emitted as its own ledger row.
- **Pattern B — Redeem**: convenience endpoint that bundles auth + capture
  atomically. The current working assumption (per the new-API team) is that
  source emits this as a **single row** in the transaction stream — likely a
  `CAPTURE` with no parent in `capture_event`, or a new `type='REDEEM'`. If
  source instead emits two same-timestamp rows, we'll discover that in QC and
  add an explicit collapse step. Refunds for Redeems come back as fresh
  `ADD` transactions (not as VOID-of-CAPTURE).

Ledger rules dictated by the new-API team:

1. **No collapsing** — emit one ledger row per source transaction. Pattern A
   produces an AUTH row and a CAPTURE row; Pattern B produces a single row
   already at source.
2. **`reason` lives on the AUTH** in the raw transaction stream — pull it
   forward onto the CAPTURE row via `loyalty_test_capture_event.auth_transaction_id`.
   Pattern B captures keep their own reason (no parent AUTH to inherit from).
3. **VOID-of-AUTH should never exist** in clean data. If it does, treat it as
   a data-quality issue, not a normal ledger row.
4. **CAPTURE should never appear as a CREDIT** in the ledger. Always DEBIT.
5. **Returns are `ADD` transactions**, not VOID-of-CAPTURE. The VOID-of-CAPTURE
   branch is dead in the new model.

### Balance-delta logic per row

| Event                 | Avail Δ      | Pending Δ    |
|-----------------------|-------------:|-------------:|
| ADD                   |     +amount  |       0      |
| AUTH                  |     -amount  |   +amount    |
| CAPTURE — Pattern A   |        0     |   -amount    |
| CAPTURE — Pattern B   |     -amount  |       0      |
| VOID-of-ADD           |     -amount  |       0      |
| VOID-of-AUTH          |       0      |       0      | (emitted with `is_anomaly=TRUE`, `anomaly_reason='VOID_OF_AUTH_FORBIDDEN'`) |
| VOID-of-CAPTURE       |       0      |       0      | (emitted with `is_anomaly=TRUE`, `anomaly_reason='VOID_OF_CAPTURE_FORBIDDEN'`) |

Pattern A vs B is detected by the presence of a parent AUTH via `capture_event`.

### Reconciliation note on Anna's test data

Anna's `loyalty_test_*` schema was constructed **before** the new-API rules
were finalized. It contains exactly the patterns the slack now forbids:

- 15 AUTH transactions, only 10 of which have CAPTUREs (the other 5 are "stuck")
- 5 VOID-of-AUTH transactions (`eeee1111-1411`, `eeee1111-1811`, `eeee2222-1622`, `eeee3333-1433`, `eeee3333-1633`) that exist solely to release those stuck AUTHs and zero out pending
- Every AUTH-CAPTURE pair in the test data is 5–15 minutes apart, so Pattern B is **not represented** in the test data at all

Because the v3 draft drops VOID-of-AUTH per slack rule 3, running this draft on
Anna's test data leaves the 5 stuck AUTHs sitting in pending forever. The
reconciliation against `account_balance` shows:

|              | snapshot.available | snapshot.pending | ledger.available | ledger.pending |
|--------------|-------------------:|-----------------:|-----------------:|---------------:|
| user 1       |              200.0 |              0.0 |             60.0 |          140.0 |
| user 2       |              110.0 |              0.0 |             50.0 |           60.0 |
| user 3       |              140.0 |              0.0 |             40.0 |          100.0 |

In every case `ledger.available + ledger.pending = snapshot.available`. This is
the expected residue when you drop the synthetic VOID-of-AUTH rows.

**Production expectation**: in QC and prod data, orphan AUTHs (and therefore
VOID-of-AUTH) should not exist, so the ledger pending and snapshot pending
should both close to 0. If they don't, that's a real data-quality signal worth
flagging, not a model bug.

Per-bucket detail (which the old model didn't expose at the ledger row level) now
lives in side tables: `auth_bucket_hold` for AUTH, `allocation` for CAPTURE,
`void_remaining` for VOID. The old `journal.metadata.balance.available/pending`
snapshot is **not present** on the new transaction — balances are kept in
`account_balance` (current state only) and `bucket` (current per-bucket).

## Old upstream models that feed `one_credits_loyalty_analytics_ledger`

```
journal              → header per event (program_id, cause, actor, reason, metadata, …)
journal_normalized   → unpacks metadata.balance.{available,pending}_minor
entry                → 1..N per journal (account_id, direction, amount_minor, state, …)
opco_program_account → account_id → loyalty_id (program-scoped)
system_loyalty_account → marks loyalty_ids that are system buckets (NOT user-level)
loyalty_private_fan_id_map → loyalty_id → private_fan_id (identity)
```

## New source tables

| Table                           | Rows | Role                                                                |
|---------------------------------|-----:|---------------------------------------------------------------------|
| `loyalty_test_program`          |    1 | Program catalog (3 = CREDITS)                                       |
| `loyalty_test_loyalty_account`  |    3 | One row per user account                                            |
| `loyalty_test_bucket_type`      |    1 | Bucket type catalog (program/tenant/site/jurisdiction/entry_type)   |
| `loyalty_test_bucket`           |    3 | Per-account earn bucket (the sub-ledger unit)                       |
| `loyalty_test_account_balance`  |    3 | Current available/pending/maturing per (loyalty_id, program_id)     |
| `loyalty_test_transaction`      |   60 | **The new "journal+entry" combined** — one row per ledger event     |
| `loyalty_test_auth_hold`        |   15 | Summary row per AUTH transaction                                    |
| `loyalty_test_auth_bucket_hold` |   15 | Per-bucket portion of an AUTH (an AUTH may span buckets)            |
| `loyalty_test_capture_event`    |   10 | Links a CAPTURE transaction to its parent AUTH                      |
| `loyalty_test_void_auth_event`  |    5 | Links a VOID transaction to its parent AUTH                         |
| `loyalty_test_allocation`       |   27 | FIFO map of earn_transaction_id → consume_transaction_id (amount)   |
| `loyalty_test_allocation_remaining` | 23 | Per-bucket remaining/original for each earn transaction         |
| `loyalty_test_void_remaining`   |    7 | Per-bucket remaining after VOIDs                                    |
| `loyalty_test_transfer_restriction` | 0 | Bucket-type → bucket-type transfer rules                          |

### Transaction `type` distribution in the sample
```
ADD     23   (earns — go into a specific bucket)
AUTH    15   (debit holds — span buckets via auth_bucket_hold)
CAPTURE 10   (realized debits — allocated FIFO via allocation table)
VOID    12   (reverse an ADD, AUTH, or CAPTURE; reversed_transaction_id is set)
```

## Field-by-field mapping

### Ledger row (output of `one_credits_loyalty_analytics_ledger`)

| Old column              | Old source                                               | New equivalent                                                                 |
|-------------------------|----------------------------------------------------------|--------------------------------------------------------------------------------|
| `account_id`            | `opco_program_account.account_id`                        | **Gone.** No separate ledger-account entity in new schema. Drop from output, or alias to `loyalty_id` if downstream depends on it. |
| `loyalty_account_id`    | `opco_program_account.loyalty_id`                        | `loyalty_test_transaction.loyalty_id`                                          |
| `private_fan_id`        | `loyalty_private_fan_id_map.private_fan_id` (LEFT JOIN)  | Same — still `loyalty_private_fan_id_map` (identity model is unchanged)        |
| `journal_id`            | `journal.journal_id`                                     | `loyalty_test_transaction.transaction_id` (renamed event id)                   |
| `created_at`            | `journal.created_at`                                     | `loyalty_test_transaction.created_at`                                          |
| `direction`             | `entry.direction` (`CREDIT`/`DEBIT`)                     | **Derived** from `type` + `reversed_transaction.type` (see logic below)        |
| `amount_minor` (signed) | `entry.amount_minor` with sign from direction            | `loyalty_test_transaction.amount` signed by derived direction                  |
| `reason`                | `journal.reason`                                         | `loyalty_test_transaction.reason`                                              |
| `cause`                 | `journal.cause`                                          | **`loyalty_test_transaction.type`** — confirmed via prod query: old `journal.cause` for program_id=3 has exactly `{ADD, VOID, AUTH, CAPTURE}` (3016 / 281 / 3 / 3 rows respectively). Vocabularies match 1:1. |
| `is_user_level_ledger`  | `system_loyalty_account.loyalty_id IS NULL`              | **Constant `TRUE`.** Downstream grep confirms the column is only used as `= TRUE` filter in `daily_one_credit_issuance.sql` and `pfi_one_credits_daily_issuance.sql` (and the `<> 'FALSE'` not-null test). The new model has no system-bucket rows, so the filters become no-ops, but they were filtering out a class of rows that no longer exists — semantically correct. |
| `available_minor`       | `journal_normalized.balance_available_minor`             | **Not on the transaction.** Reconstruct via running sum, or look up `account_balance.available` for current-state only. |
| `pending_minor`         | `journal_normalized.balance_pending_minor`               | Same — reconstruct via running sum of AUTH-CAPTURE-VOID(AUTH) deltas, or look up `account_balance.pending`. |

### Direction derivation (new model)

The new `transaction.type` plus `reversed_transaction_id` carry the same
information `entry.direction` did in the old model:

| `type`    | `reversed_transaction.type` | Derived direction | Reason                                  |
|-----------|-----------------------------|-------------------|-----------------------------------------|
| `ADD`     | —                           | `CREDIT`          | Earn into a bucket                       |
| `AUTH`    | —                           | `DEBIT`           | Available → pending hold                |
| `CAPTURE` | —                           | `DEBIT`           | Pending → consumed (realized)           |
| `VOID`    | `ADD`                       | `DEBIT`           | Clawback of an earn                     |
| `VOID`    | `AUTH`                      | `CREDIT`          | Release a hold                          |
| `VOID`    | `CAPTURE`                   | `CREDIT`          | Refund a realized debit                 |

Fallback signal if `reversed_transaction_id` is null: VOIDs that touch an ADD
will have `bucket_id` populated on the transaction; VOIDs that touch an AUTH
have `bucket_id = NULL` (because AUTH spans buckets via `auth_bucket_hold`).

### `available_minor` / `pending_minor` reconstruction (cumulative window sums)

The new system does not persist a balance snapshot per transaction. To
reproduce the old ledger's `available_minor` / `pending_minor`, compute running
sums per `loyalty_id` ordered by `created_at`:

| Event                  | `available` Δ | `pending` Δ |
|------------------------|--------------:|------------:|
| ADD                    |       +amount |           0 |
| AUTH                   |       −amount |     +amount |
| CAPTURE                |             0 |     −amount |
| VOID(ADD)              |       −amount |           0 |
| VOID(AUTH)             |       +amount |     −amount |
| VOID(CAPTURE)          |       +amount |           0 |

Cross-check against `loyalty_test_account_balance.available` /
`loyalty_test_account_balance.pending` for the latest row per `loyalty_id`.

### Other fields you may want to surface (new columns not in old ledger)

The new transaction carries metadata the old ledger threw away:

- `bucket_id` — which bucket the row touched (NULL for AUTH/CAPTURE — see side tables)
- `entry_type` — bucket-type classification (e.g. `BASE`)
- `campaign_code`, `external_id`, `ref_id`, `ref_id_type`
- `actor` (who issued) — distinct from `type` (what happened)
- `site_id`, `tenant_id`, `jurisdiction`
- `available_at`, `expires_at`
- `reversed_transaction_id` — direct link to the voided event

Recommend adding these to the new ledger output rather than dropping them on the
floor — they were either buried in `journal.metadata` or simply absent in the
old model.

## Notes on the old-vs-new "double entry" question

The old `entry` table could in principle emit multiple rows per journal (one
per affected ledger account — e.g. user CREDIT + system bucket DEBIT). In the
new model:

- ADD = one transaction row, one bucket touched
- AUTH = one transaction row at user level + N rows in `auth_bucket_hold` per bucket
- CAPTURE = one transaction row at user level + N rows in `allocation` per consumed earn
- VOID = one transaction row at user level (+ entries in `void_remaining` for ADD voids)

The cleanest port is **one ledger row per transaction**, matching the new
service's accounting unit. If downstream truly needs per-bucket exploded rows,
build that as a *separate* model (e.g. `one_credits_loyalty_analytics_ledger_by_bucket`)
that joins to `auth_bucket_hold` / `allocation` / `void_remaining` — don't
distort the headline ledger to fake the old double-entry shape.
