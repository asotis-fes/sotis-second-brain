# Loyalty Engineer Message — Tier Points table list

**Date:** 2026-07-13
**From:** Suneel Rachamallu

> "it is test_account_balance, test_tier_account_override, test_transacrion, test_tier, test_override_configuration, test_invite_approval"

## Interpretation vs schema doc

| Suneel's name | Likely PG name | Schema doc name | Status |
|---|---|---|---|
| `test_account_balance` | `test_account_balance` | `account_balance` | ✅ Shared with OneCredits — already ingested |
| `test_tier_account_override` | `test_tier_account_override` | `tier_account_override` | 🆕 Needs new pipeline |
| `test_transacrion` | `test_transaction` (typo) | `transaction` | ✅ Shared with OneCredits — already ingested |
| `test_tier` | `test_tier` | `tier` | 🆕 Needs new pipeline |
| `test_override_configuration` | `test_tier_override_configuration`? | `tier_override_configuration` | 🆕 **Name uncertain — confirm PG literal name** |
| `test_invite_approval` | `test_tier_invite_approval`? | `tier_invite_approval` | 🆕 **Name uncertain — confirm PG literal name** |

## Missing from Suneel's list (per schema doc)

- `tier_account_override_trial` — schema doc lists this. Used for STATUS_MATCH trial tracking. Confirm whether we need it.

## Column-level concerns

- **`account_balance`** already has an ingest / DDL / staging model from OneCredits. Schema doc mentions a `lifetime NUMERIC(18,6)` column added for TierPoints (`SUM(ADD) - SUM(VOID)`), NULL for non-TierPoints. **Verify our current `create_account_balance_ext.sql` projects `lifetime`.** If not, we need to add it.
- **`transaction`** — no known tier-specific column additions. Verify with Suneel.

## What "shared" means practically

For `transaction` and `account_balance`:
- No new ingest tasks needed (they're already firing hourly).
- Post-cutover, Tier Points rows will just start appearing with `program_id = 2` mixed alongside `program_id = 3` (Credits).
- Downstream models that filter by `program_id = 3` (like `one_credits_loyalty_analytics_ledger`) will continue to exclude Tier Points rows. A parallel `tier_points_loyalty_analytics_ledger` (or similar) would filter for `program_id = 2`.

## What "new pipeline" means

For each of the 4 (or 5) tier-only tables, need:
1. Config entry in `dags/loyalty/configs.py` (either extend `OC_POSTGRES_TABLE_CONFIGS` or add a new `TP_POSTGRES_TABLE_CONFIGS`).
2. Ext-table DDL at `dags/create_tables/sql/loyalty/create_<table>_ext.sql`.
3. Source declaration in `dags/dbt/models/sources/loyalty.yml`.
4. Staging model at `dags/dbt/models/loyalty/source/<table>.sql`.

Plus a toggle mechanism for cutover — see `onecredits_pattern_reference.md`.
