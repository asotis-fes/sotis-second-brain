# Program Scope Clarification (2026-06-25)

User correction: my earlier mental model about which programs are where was wrong. Here's the actual breakdown.

## What's on what

| Program | Today's data source | Migration status |
|---------|---------------------|------------------|
| **OneCredits** | Loyalty team's Postgres (always has been; rolled out recently) | Cutover **next week** — schema change from old PG shape to new bucket-model PG shape, in the same Postgres |
| **FanCash** | Salesforce Loyalty Cloud → Data Cloud → Snowflake | Migration to new Postgres backend is **later** and **larger** |
| **Tier Points** | Salesforce Loyalty Cloud → Data Cloud → Snowflake | Migration to new Postgres backend is **later** and **larger** |

## Implication for the legacy `POSTGRES_TABLE_CONFIGS` ingest

That ingest is **OneCredits data only**, not a multi-program legacy feed. The tables (`journal`, `entry`, `opco_program_account`, etc.) hold OneCredits ledger rows filtered by `program_id = 3` (per `one_credits_loyalty_analytics_ledger.sql`).

FanCash and TierPoints data does NOT flow through `POSTGRES_TABLE_CONFIGS`. It comes through the `loyalty__loyalty_stage` source group (`LOYALTY_STAGE` schema — `BONUS_FANCASH`, `loyalty_transaction_raw`, etc.) — that's the Loyalty Cloud / Data Cloud path, untouched by this cutover.

## What "cutover" actually means

The loyalty team is migrating OneCredits **within their Postgres** from the old `journal`+`entry` ledger model to the new `transaction` bucket model. The cutover is the moment that switch happens in their prod PG.

The new schema is **multi-program ready**: same `transaction` table can later hold FanCash (`program_id=1`) and TierPoints (`program_id=2`) rows when those programs migrate off Loyalty Cloud. But that's later, larger work. This cutover is only OneCredits.

## Bounding our scope tightly

- ✅ In scope: ingest the 14 new-backend tables (`OC_POSTGRES_TABLE_CONFIGS`), retire/adjust the legacy OneCredits ingest tasks that break.
- ❌ Out of scope: FanCash, TierPoints, Loyalty Cloud / Data Cloud, `LOYALTY_STAGE`, `LOYALTY_CORE`. None of those move during this cutover.

## Source references

- Schema reference (loyalty team): https://github.com/fanatics-gaming/fes-loyalty/blob/schema2/docs/SCHEMA_DATA.md
- New-backend table list in our DAG: `OC_POSTGRES_TABLE_CONFIGS` in `fes-airflow/dags/loyalty/configs.py`
- Legacy OneCredits ingest: `POSTGRES_TABLE_CONFIGS` in same file
- Downstream model that filters to Credits: `models/loyalty/one_credits/one_credits_loyalty_analytics_ledger.sql` (`WHERE j.program_id = 3`)
