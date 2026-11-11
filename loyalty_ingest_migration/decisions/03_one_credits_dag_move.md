# Decision 03 — Move one_credits dbt models into `loyalty_postgres_to_s3_ingest`

**Date:** 2026-06-25
**Status:** Implemented in this PR (AE rewrite folded in 2026-06-25)

Tag change applied to `one_credits_loyalty_analytics_ledger` and `one_credits_loyalty_analytics_ledger_fbg`. The Jinja-conditional SQL (Decision 02 / 04) means the OLD branch runs in prod pre-cutover and the NEW branch runs in dev and post-cutover prod, both under `tag: ['fesloyalty']` via the hourly `loyalty_postgres_to_s3_ingest`. The daily snapshot stays on `tag: ['daily_9am']`.

## Current state

| Model | Tag | Current runner DAG | Schedule |
|-------|-----|--------------------|----------|
| `one_credits_loyalty_analytics_ledger` | `loyalty` | `dbt_loyalty.py` | every 6 hours (0 5,11,17,23 UTC) |
| `one_credits_loyalty_analytics_ledger_fbg` | `loyalty` | `dbt_loyalty.py` | every 6 hours |
| `loyalty_one_credits_balance_daily_snapshot` | `daily_9am` | (presumed daily_9am runner) | daily |

`dbt_loyalty.py` is gated behind two upstream sensors:
- `transaction_raw_replication_handshake_sensor` — waits for Loyalty Cloud `loyalty_transaction_raw` replication
- `bonus_fancash_incremental_sensor` — waits for `loyalty_bonus_fancash_incremental` DAG

Neither sensor is relevant to OneCredits post-cutover (OneCredits is Postgres-only).

## Decision

**Move the two ledger models to `loyalty_postgres_to_s3_ingest` by changing their tag from `loyalty` to `fesloyalty`.** That DAG already runs `dbt --select tag:fesloyalty` hourly.

```yaml
# Before
- name: one_credits_loyalty_analytics_ledger
  config:
    tags: ['loyalty']
# After
- name: one_credits_loyalty_analytics_ledger
  config:
    tags: ['fesloyalty']
```

Same change for `_fbg`.

**Don't move the daily snapshot.** `loyalty_one_credits_balance_daily_snapshot` is conceptually a once-per-day capture; hourly is wasteful. Leave its `daily_9am` tag alone. It'll continue running daily, reading the same materialized `LOYALTY.SOURCE.<table>` tables the hourly ingest DAG maintains. (AE will rewrite this model to ref the new `account_balance` staging model post-cutover, but that's mechanical — no DAG change.)

## Why this is the right move

1. **Latency:** OneCredits ledger updates go from every-6-hours to hourly (matches the ingest cadence).
2. **Dependency correctness:** OneCredits no longer depends on `loyalty_transaction_raw` (Loyalty Cloud) or `loyalty_bonus_fancash_incremental` (FanCash-specific). Running it in the same DAG as the ingest means it depends on exactly the right upstream — fresh Postgres data.
3. **Atomic data freshness:** ingest → staging → downstream ledger all in one DAG run = no possibility of consuming half-fresh data.
4. **Cleaner mental model:** `dbt_loyalty.py` remains the "Loyalty Cloud–backed program" DAG (FanCash, Tier Points). `loyalty_postgres_to_s3_ingest` becomes the "Postgres-backed program" DAG (OneCredits today; FanCash and Tier Points when they migrate later).

## Edge cases

- **Snapshot model staleness:** the daily snapshot reads legacy staging models (`opco_program_account`, `program_account_balance`, `system_loyalty_account`) which remain alive but unchanging post-cutover (Decision 02). AE will rewrite the snapshot to ref new staging (`account_balance`) in the cutover PR. Until then, running it would write a snapshot of stale data — not catastrophic for a few days of dev validation, but worth being aware of.
- **No-op for `dbt_loyalty.py`:** removing the `loyalty` tag from the two OneCredits models simply means `dbt_loyalty.py` selects fewer models. No DAG changes there. The DAG can stay exactly as it is for FanCash + Tier Points work.
