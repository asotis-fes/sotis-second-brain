# Fanflow Data Discrepancy — Plan of Attack

## Context

Team requested additional rigor before the Confluence doc (https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/3066134696) gets handed to the platform team.

**Anna's asks** (Slack thread C0A6X3B3WBT, parent ts 1779993005.412689):
1. Attach full list of missing events to the doc
2. Triple-check it's not a boundary issue, and verify the `redeem_id` part of the join isn't causing false positives
3. Add total `$` value of missed earns vs captures separately
4. Trace through pipeline (FES Kafka → Commerce Kafka) to localize drop point

**Anna's Confluence comment**: "`redeem_id` shouldn't be needed in join – i believe this can be NULL and those don't join well"

**Megan's contribution**: Pointed at FES Kafka UI (https://kafka-ui.prod.fanatics-app.com) with MessagePack deserialization now available for readable payload search.

## Working environment

- Snowflake connection: `FAN_DATA_EXCHANGE_PROD` (default)
- Role: `FES_DATA_DEVELOPER`
- Warehouse: bumping to `FDE_DEVELOPER_XL_WH` for heavier queries
- External table from prior session: `FES_USERS.ALEX_SOTIS.INCIDENT_COMMERCE_LOYALTY_EVENTS_EXT`
- Working dir: `fanflow_data_discrepancy/`
  - `queries/` — SQL files (one per step)
  - `results/` — query result markdown files (one per step)

## Steps

| # | Step | Query file | Result file | Status |
|---|------|-----------|-------------|--------|
| 0 | Verify external table accessible | `queries/00_verify_external_table.sql` | `results/00_verify_external_table.md` | pending |
| 1 | Recreate `LOYALTY_MISSING_EVENTS` persistent table with NULLIF | `queries/01_create_missing_table.sql` | `results/01_create_missing_table.md` | pending |
| 2 | Anna's verification: same query without `redeem_id` in join | `queries/02_anna_no_redeem_id.sql` | `results/02_anna_no_redeem_id.md` | pending |
| 3 | `redeem_id` distribution (null vs empty vs value) | `queries/03_redeem_id_distribution.sql` | `results/03_redeem_id_distribution.md` | pending |
| 4 | Boundary check: full silver history join | `queries/04_boundary_full_silver.sql` | `results/04_boundary_full_silver.md` | pending |
| 5 | Dollar value totals by `txn_status` | `queries/05_dollar_totals.sql` | `results/05_dollar_totals.md` | pending |
| 6 | Sample loyTranIds for Kafka UI traces | `queries/06_kafka_trace_samples.sql` | `results/06_kafka_trace_samples.md` | pending |
| 7 | Export full 664 events to CSV | `queries/07_export_csv.sql` | `results/07_export_csv.md` (+ CSV) | pending |

## Closure

When all steps complete:
- Write `results/SUMMARY.md` — for Confluence update + Slack reply to Anna/Megan
- Drop `redeem_id` from the join in the Confluence doc (assuming Step 2 confirms it's a no-op)
- Add dollar totals + boundary confirmation to the Confluence doc
- Attach the CSV to the Confluence page
- Provide sample loyTranIds for the Kafka UI trace, which Alex will run manually

## Decision tree for Kafka trace (per runbook 2322170081)

For each sample loyTranId, check in order:
1. **FES Kafka `fes_enriched`** (https://kafka-ui.prod.fanatics-app.com — use MessagePack deserialize)
   - Found: drop is FES Kafka → S3 sink (FES platform team)
   - Not found: continue
2. **Commerce `fes_enriched`** (https://master.fanflow-kafka-ui.prod.frgcloud.com)
   - Found: drop is MirrorMaker2 (FES platform team)
   - Not found: continue
3. **Commerce ALL** topic
   - Found: drop is enrichment service (Identity team `#lids-data-identity-eng`)
   - Not found: dig further upstream
