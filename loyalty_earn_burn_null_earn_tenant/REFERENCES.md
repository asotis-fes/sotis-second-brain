# References

## Source of the question

- **Slack:** #fes-data (`C07J0KWHY77`), Caroline Wylie, 2026-08-05
  `https://betfanatics.slack.com/archives/C07J0KWHY77/p1785967898162009`

## Jira / incidents

- **ENTDATA-1893** — Jan-2026 missed-redeems repair (Megan Boyd). Related but distinct failure mode.
- **Jan-2026 incident** — Confluence `2884239362`
  `https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/2884239362` (Commerce Airflow change → ~4.2M late earns → broke FIFO for ~148k accts → full-history replay)
- Vault: `vault/wiki/incidents/incident-2026-01-04-missed-redeems.md`, `…-redeems-repair.md`

## Tables (prod)

| Table | Role |
|-------|------|
| `LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER` | Final mapper (the one with null `earn_tenant_id`) |
| `LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER` | Where `earn_*` attribution is stamped |
| `FANFLOW.ACCOUNT_EVENTS.LOYALTY_TRANSACTION_SUCCESSFUL__ACCOUNT` | Fanflow source of loyalty txns (earns/auths) |
| `MDE.MDE_CORE.SITE_ID_TENANT_ID_MAP` | site_id → tenant_id lookup |

## Model paths (repo: `dbt-fes-ae`, dir `models/loyalty/fancash/`)

| File | Role |
|------|------|
| `ledger/loyalty_analytics_ledger_stage.sql` | **Lines 451-456**: `earn_*` stamped `ADD`-only ← root cause |
| `ledger/loyalty_earn_burn_mapper_stage.sql` | Aggregates REDEEM rows → mapper |
| `ledger/loyalty_earn_burn_mapper.sql` | `table_clone` of stage |
| `ledger/ledger.yaml` | Model config + tests (`loyalty_row_count_check`, `loyalty_required_site_ids_daily`) |
| `redeem_matching/redeem_matches.sql` | FIFO matcher; `unconnected_earns` CTE hardcodes `NULL` site/tenant |
| `redeem_matching/new_ledger_txn.sql` | New txns within `redeem_lookback_days` |
| `redeem_matching/unconnected_earn.sql` | Unconnected-earn table — **no site_id/tenant_id columns** |
| `redeem_matching/unconnected_burn.sql` | Unconnected-burn table (re-fed every run) |
| `ledger_upstream/loyalty_redeem.sql` | REDEEM output → ledger |
| `analysis/redeem_migration/garland.sql` | Proc `generate_loyalty_redeems_ff()` — ad-hoc reprocess/replay |
| `analysis/fanflow_backfills/loyalty_transaction_successful__account_backfill.sql` | Backfill precedent (ENTDATA-1893) |
| `models/loyalty/fancash/ledger_upstream/loyalty_redeem.sql` + source `loyalty_redeem_iceberg` | FanCash service redeem data — candidate "native linkage" source (UNVERIFIED) |

## UDTF source & the `void_auth` behavior

- **`docs/runbooks/fes-data/redeems-incident-repair.md:756-917`** — Python UDTF `LoyaltyProcessor` (`connect_loyalty_transactions`, registered in `LOYALTY(_DEV).LOYALTY_STAGE`).
  - `void_auth_filter` (line 789), `is_matchable_earn = earn OR void_auth` (**line 796** ← root cause), `connect()` emits REDEEM (line 851), `l_txn_type` fallback (line 857).

## One Credits — SEPARATE PROGRAM, not relevant (do not use for FanCash)

`LOYALTY.ONE_CREDITS.*` is a different loyalty program. Earlier draft wrongly treated it as a parallel FanCash
implementation and blamed its 2026-07-06 cutover for the July FanCash spike — both retracted. Ignore for this issue.

## Config vars (`dbt-fes-ae/dbt_project.yml`)

- `redeem_lookback_days: 2` (line 93) · `loyalty_incremental_lookback_days: 2` (line 94)
- `tenant_id_commerce: '100001'`, `tenant_id_fbg: '100002'`, `tenant_id_live: '100004'`, `tenant_id_summit: '100024'` …
  **`100026` is not named** (the affected opco).

## Confluence — FanCash data model

- FES and Fancash (parent): `1365082658` · FAQ: `1370980449`
- Earn-Burn Mapper data dictionary: `1972764959`
- Local domain ref: `docs/domain/loyalty-fancash.md`

## Diagnostic queries

Saved in scratchpad `ebm_diag*.sql` (session-local; reproduce as needed). Run on `FAN_DATA_EXCHANGE_PROD`
/ role `FES_DATA_DEVELOPER` / warehouse `FDE_DEVELOPER_WH` (Medium).

Key results:
- Monthly null-earn burned & share (reproduces Caroline's numbers + July = $692k / 1.28%).
- July by day → spikes Jul 12–14, 1, 8.
- July by burn-side `tenant_id`/`site_id` → `100026`/`610942` = $372k.
- `earn_txn_id IS NULL` split → **0 unmatched** (all matched).
- Join matched earn IDs → ledger: **0 `ADD` rows** (only AUTH/VOID/REDEEM).
- Join to fanflow source: earn IDs are **AUTH + VOID_1 only**, `site_id` populated.

### Gotchas
- `snow sql` on this large table auto-backgrounds; wait for completion. Use `--format csv`.
- `rows` is a reserved word — alias counts as `n_rows`.
- Temp tables need `USE DATABASE`/`USE SCHEMA` first.
- Table scans by `site_id`/`earn_site_id` across all months are expensive — bound by `creation_time` (July) and prefer `LIMIT`.
