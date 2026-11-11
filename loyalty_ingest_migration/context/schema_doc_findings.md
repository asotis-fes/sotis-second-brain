# Schema Doc Cross-Reference (2026-06-25)

Source: https://github.com/fanatics-gaming/fes-loyalty/blob/schema2/docs/SCHEMA_DATA.md (branch `schema2`)

## ⚠️ Headline findings (things that change cutover work)

### F9 — `transaction.id` UUIDv7 PK added to PG on 2026-06-25

The schema doc described a dual-ID design (`id` UUIDv7 internal PK + `transaction_id` UUIDv5 API identifier), but until 2026-06-25 the actual PG `transaction` table only had `transaction_id`. Suneel added the `id` column that day and updated the test_ tables. Implications:
- `cols` list in `OC_POSTGRES_TABLE_CONFIGS` for `transaction` includes `id` as the first column.
- `create_transaction_ext.sql` declares `id VARCHAR` as the first projected column.
- `models/loyalty/source/transaction.sql` selects `id` and uses it as the `PARTITION BY` for the QUALIFY dedup.
- `source.yaml` for `transaction` uses `unique_key: id` and tests `unique`/`not_null` on `id`, `not_null` on `transaction_id`.
- Companion tables (`auth_hold.transaction_id`, `capture_event.transaction_id`, etc.) actually store `transaction.id` (UUIDv7) values — column name is misleading. The AE's ledger rewrite still maps `t.transaction_id AS journal_id` (API identifier), unchanged.

### F1 — `journal` and `entry` are DROPPED in migration 000011

The schema doc's "Deprecated Tables" section lists `journal` and `entry` as **Dropped (migration 000011)**, replaced by `transaction`. So at the moment the new schema is applied in prod PG, the source tables for these legacy ingest tasks **cease to exist**:

- `load_journal` task → source table gone → **task will fail**
- `load_entry` task → source table gone → **task will fail**

**Action required:** Both have to be removed from `POSTGRES_TABLE_CONFIGS` at cutover (or before, gated by env), or the DAG goes red.

### F2 — `idempotency_keys` got its `updated_at` column REMOVED

Quote from schema doc: "Immutable — `updated_at` removed in migration 000011."

Our current config:
```python
{"table": "idempotency_keys", "incremental_col": "updated_at"},
```

Without `updated_at`, the incremental filter `WHERE updated_at < cutoff` will fail. **Action required:** drop `idempotency_keys` from the legacy config, or rewrite the incremental column (the new shape has `created_at` we could use).

Note: the new-backend `OC_POSTGRES_TABLE_CONFIGS` correctly **excludes** `idempotency_keys` per PR 291 — so we don't ingest it on the new side anyway. Simplest path: drop from legacy config at cutover.

### F3 — `void_event` was RENAMED to `void_auth_event`

Not in our config, so doesn't affect us. But notable: dbt models that ref `void_event` (if any) would break. Our new config already uses `void_auth_event` (correct name).

### F4 — `loyalty_account` and `program` schemas are IDENTICAL across legacy and new

Both have the exact same columns:
- `loyalty_account`: `loyalty_id` (UUID PK), `created_at` (TIMESTAMPTZ)
- `program`: `program_id`, `code`, `display_name`, `is_active`, `created_at`, `updated_at` — same in both

This means the "collision" for these two tables is **only at the name level, not the shape level**. Same data, same columns. The new ingest path could in principle land in the legacy ext-table location without breaking anything — but we'd still have two tasks writing to the same S3 path concurrently, which is a race condition. So still need to dedupe or pick one.

### F5 — `allocation` requires consumer-side deduplication

Schema doc explicit warning:
> "⚠️ Deduplication required for consumers: Because no DB-enforced unique constraint exists, crash-resume retries can produce duplicate rows with the same `(earn_transaction_id, consume_transaction_id)` pair across different partitions. Any downstream consumer (analytics, Snowflake, reporting) must deduplicate on `(earn_transaction_id, consume_transaction_id)` before aggregating amounts."

**Action required in the Layer 3 staging model for `allocation`:** dedupe by `(earn_transaction_id, consume_transaction_id)` on top of the existing `QUALIFY ROW_NUMBER() ... ORDER BY upload_ts DESC` pattern. Cannot simply use the legacy template — need a different unique key.

### F6 — Tables still alive post-cutover but slated for future deprecation

These remain "Active — will be deprecated":
- `opco_program_account` → eventually replaced by `bucket`
- `program_account_balance` → eventually replaced by `account_balance`
- `system_loyalty_account` → eventually removed (house bucket concept gone)
- `operating_company` → eventually removed

**Action:** keep their legacy ingest tasks running. They'll keep working at cutover. Future cleanup project, not now.

### F7 — Tier tables exist in the schema but are intentionally out of scope

5 tables (`tier`, `tier_override_configuration`, `tier_account_override_trial`, `tier_account_override`, `tier_invite_approval`) per schema doc. None are in `OC_POSTGRES_TABLE_CONFIGS` — consistent with the PR 291 exclusion comment. These come into scope only when TierPoints migrates off Loyalty Cloud (future).

### F8 — Program IDs are stable across legacy and new

| program_id | code |
|------------|------|
| 1 | FANCASH |
| 2 | TIERPOINTS |
| 3 | CREDITS |

Matches what `one_credits_loyalty_analytics_ledger.sql` hardcodes (`WHERE j.program_id = 3`). The analytics engineer's rewrite can keep this filter unchanged for the OneCredits-only post-cutover view.

## Confirmation: things already in our analysis

- 14 tables in `OC_POSTGRES_TABLE_CONFIGS` matches schema doc tables marked ★ (new in migration 000011) plus `loyalty_account` and `program`. ✓
- `transaction` is the new ledger, replacing `journal`+`entry`. ✓ (was in `hot.md` and `loyalty_new_service/mapping.md`)
- `allocation` is the earn→burn link (FIFO, replaces old `loyalty_earn_burn_mapper`). ✓
- `bucket_id NULL` for pre-FC Credits rows — meaningful for the analytics engineer's reconciliation logic. ✓

## What this means for the cutover plan

Updated DAG-change scope:

1. **Remove from `POSTGRES_TABLE_CONFIGS`** (or env-gate to dev-only):
   - `journal` (table dropped)
   - `entry` (table dropped)
   - `idempotency_keys` (incremental col removed)

2. **Keep in `POSTGRES_TABLE_CONFIGS`** (still exist, deprecated-but-active):
   - `loyalty_account`
   - `opco_program_account`
   - `operating_company`
   - `program`
   - `program_account_balance`
   - `system_loyalty_account`

3. **`OC_POSTGRES_TABLE_CONFIGS` un-prefix and un-gate** (the main work):
   - Strip `test_` from source-table name
   - Remove `if config.get_value_for_env(dev=True, prod=False)` gate
   - Update S3 key to bare name (will need collision resolution for `loyalty_account` and `program`)

4. **Allocation staging model** needs deduplication on `(earn_transaction_id, consume_transaction_id)` — not the standard template.

5. **`compare_row_counts`** needs to know the new tables and the new Snowflake landing location.
