# Post-code-freeze dbt-model sync plan

Cutover: **2026-07-23**. Code freeze started **2026-07-21 19:00 ET**.

The `fes-airflow` feature branch `dbt-cloud-migration` was cut on **2026-07-10** at commit `3aa8ab13` ("Bump sensor timeout to 4 hours…"). Between then and code-freeze, **42 commits** landed on `fes-airflow/main`. We deleted `dags/dbt/` on the branch (commit `a88f0b10`), so we cannot merge main and keep dbt model changes there — we have to route each change to `dbt-fes-ae` or `dbt-fes-analytics` per D42 and merge only the non-dbt commits back into the feature branch.

## Classification summary

| Class | Count | Where it goes |
|---|---|---|
| A. dbt model / macro / source / yaml / test changes | 36 commits (some overlap) | `dbt-fes-ae` and/or `dbt-fes-analytics` |
| B. Non-dbt Airflow DAG / utility changes | 6 commits | Merge into `dbt-cloud-migration` |
| C. Mixed (both A and B in one commit) | 1 commit (`1d7d095f`) | Split into two PRs |
| D. `dbt_project.yml` var wobble | 4 commits (2 revert pairs, net-zero) | No action — already in sync |

## Merge into `dbt-cloud-migration` branch

**Result of a simulated `git merge origin/main` on a scratch branch:**

- **48 conflicts total.**
- **47** are `modify/delete` in `dags/dbt/**` — main modified these files, our branch deleted the parent folder. **Resolution: `git rm` each one** (the whole `dags/dbt/` tree stays deleted).
- **1** is a content conflict in `dags/loyalty/loyalty_fcc_slim_ledger.py`. Commit `75452eb9` on main repointed the `ExternalTaskSensor` at `dbt_hourly` (a DAG that also no longer exists in our world — see below), but our commit `40db9a48` deleted the sensor entirely. **Resolution: accept our version** (the sensor is gone; the DAG now runs on its own cron with no dbt-DAG dependency).

Auto-merged clean (kept from main, no action):
- `dags/identity/cassandra_extract.py` (from `ee38aa2d` — skip `credit_card` in cassandra extract)
- `dags/loyalty/loyalty_bonus_postgres_to_s3_ingest.py` (from `1c6061aa` — remove alert on bonus PG compare)

Added clean from main:
- `dags/identity/cassandra_schema_discovery.py` (from `ee38aa2d`)
- `dags/leap_event_tech/ffny_2026_transfers_import.py` + SQL scripts (from `2bcebff3` + `0b41d410`)
- `dags/loyalty/configs.py` (from `5944487d` — add tolerance)
- `dags/create_tables/create_tables.py` + `dags/create_tables/sql/cms/*.sql` (from `1d7d095f`, non-dbt half)

### Merge procedure

Before merging, commit or stash the 14 uncommitted AI-slop cleanup edits already in the working tree (files listed under "Loose ends" below).

```bash
cd ~/repos/fes-airflow
git checkout dbt-cloud-migration
git pull --ff-only origin dbt-cloud-migration

# 1. clean tree first — commit the AI-slop cleanup edits or stash them
# 2. do the merge:
git checkout -b sync/main-into-dbt-cloud-migration
git merge origin/main
#   → 48 conflicts

# 3. resolve mass modify/delete: drop everything under dags/dbt/
git rm -r dags/dbt/

# 4. resolve loyalty_fcc_slim_ledger.py conflict — accept ours (sensor stays deleted)
git checkout --ours dags/loyalty/loyalty_fcc_slim_ledger.py
git add dags/loyalty/loyalty_fcc_slim_ledger.py

# 5. sanity check: nothing under dags/dbt/ remains, no unresolved conflicts
git status
git diff --check
find dags/dbt -type f 2>/dev/null | head  # must be empty

# 6. verify ast/parse on the auto-merged .py files
python3 -c "import ast, pathlib; [ast.parse(p.read_text()) for p in pathlib.Path('dags').rglob('*.py')]"

# 7. commit
git commit -m "Merge main into dbt-cloud-migration (dbt model changes routed to dbt-fes-ae + dbt-fes-analytics)"

# 8. open PR into dbt-cloud-migration (NOT main)
gh pr create --base dbt-cloud-migration --head sync/main-into-dbt-cloud-migration --title "..."
```

**Do not push directly to `dbt-cloud-migration` without a PR** — Ponzu requires `[R] Change Request` gate on any merge into the branch; we've been following the two-PR pattern for weeks.

### Loose end: 14 uncommitted AI-slop cleanup edits in `fes-airflow`

Left over from the previous session — the AI-slop comment cleanup that never got committed. Files:
- `dags/airflow_ops/dbt_cloud_coupling_test.py`, `..._failure.py`, `..._upstream_mock.py`
- `dags/identity/cassandra_extract.py`
- `dags/lids/lids_loyalty_report.py`
- `dags/loyalty/dbt_loyalty_6hours.py`, `loyalty_fcc_slim_ledger.py`, `loyalty_kyros_data_transfer.py`
- `dags/salesforce/salesforce_marketing_cloud_daily.py`, `..._fanatics_one.py`, `..._fancash_export.py`, `sfmc_optin_preferences_import.py`
- `dags/utils/dbt_cloud.py`
- `dags/xtremepush/xtremepush_tier_change_events.py`

All verified `ast.parse` + `black --check` + `flake8` clean in the previous session. Options:
1. Commit as `chore: trim dbt-cloud-migration comments to human-shape` on the branch and push to update PR #2252 **before** the main-merge PR.
2. Rebase them into a fixup on the existing branch commits (messier — skip).

Recommend option 1: commit onto `dbt-cloud-migration` directly, then do the merge from the clean state.

## dbt content changes — routing

Routing rule (from D42 leave-in-place variant, hot.md 2026-07-19):
- Files in `dags/dbt/models/fes_users/{caroline_wylie,dylan_tuch,mitchell_mann,rmcspedon,rohan_gulati}/` — check the current dbt-fes-ae file list first; the **12 must-stay** models still live in AE, the other 116 are in dbt-fes-analytics.
- Files anywhere else in `dags/dbt/models/` or `dags/dbt/macros/` or `dags/dbt/tests/` → dbt-fes-ae.
- Shared subfolder yamls (`caroline.yaml`, `dylan_tuch.yaml`, `mitchell_mann.yaml`, `rohan.yaml`, `ryan.yaml`) exist in **both** repos: **split by target model** — new entries whose `.sql` lives in AE go into AE's yaml, entries whose `.sql` is in analytics go into analytics's yaml.
- yamls only in analytics (`natalie.yaml`, `stacy.yaml`, `kelsey_carrier.yaml`, `kevin_bokor.yaml`) → analytics only.

Current AE fes_users inventory (must-stay set): `caroline_wylie/{caroline.yaml, fancash_site_tenant_mapping.sql}`, `dylan_tuch/{amplitude_session_performance.sql, dylan_tuch.yaml, fraudulent_ips.sql}`, `mitchell_mann/{dim_appsflyer_campaign_mapping.sql, dim_appsflyer_creative_mapping.sql, mitchell_mann.yaml}`, `rmcspedon/{fangraph_ecosystem_daily_activity_v2.sql, ryan.yaml}`, `rohan_gulati/{fanapp_cohort_labels.sql, fanapp_install_attributes.sql, fanapp_install_identity_map.sql, fanapp_potential_fraud.sql, hashed_email_eco_profit.sql, hashed_email_ftu.sql, rohan.yaml}`.

## dbt-fes-ae PR — content to port

One PR titled roughly *"Sync AE dbt models from fes-airflow (branch-cut → code-freeze)"*, based on `dbt-fes-ae/main`. Add `[R] Change Request` label + ENTDATA-2147.

### New files to add

| From (main) | To (dbt-fes-ae) | Source commit |
|---|---|---|
| `dags/dbt/macros/standardize_state.sql` | `macros/standardize_state.sql` | `a34a7176` (+ `983df9e7` regex fix folded in) |
| `dags/dbt/macros/standardize_country.sql` | `macros/standardize_country.sql` | `a34a7176` |
| `dags/dbt/models/sources/imprint.yml` | `models/sources/imprint.yml` | `cc2db27e` |
| `dags/dbt/models/sources/cms.yml` | `models/sources/cms.yml` | `1d7d095f` |
| `dags/dbt/models/identity/source/fancash_site_tenant_map.sql` | `models/identity/source/fancash_site_tenant_map.sql` | `01578893` |
| `dags/dbt/models/enterprise_metrics/consumption/dcr_comm_user_revenue_dly_v.sql` | `models/enterprise_metrics/consumption/dcr_comm_user_revenue_dly_v.sql` | `65ca7eb0` |
| `dags/dbt/tests/redeems_match_pct.sql` | `tests/redeems_match_pct.sql` | `b0b04e65` |
| `dags/dbt/models/fanapp/cms/cms.yaml` | `models/fanapp/cms/cms.yaml` | `1d7d095f` |
| `dags/dbt/models/fanapp/cms/cms_custom_card.sql` | `models/fanapp/cms/cms_custom_card.sql` | `1d7d095f` |
| `dags/dbt/models/fanapp/cms/cms_custom_card_v2.sql` | `models/fanapp/cms/cms_custom_card_v2.sql` | `1d7d095f` |
| `dags/dbt/models/fanapp/cms/cms_feed.sql` | `models/fanapp/cms/cms_feed.sql` | `1d7d095f` |
| From `aa39c8e3`: `dags/dbt/models/enterprise_metrics/consumption/ecosystem_ftus.sql` + `enterprise_metrics/processed/ftu/{_ftu.yaml, ecosystem_collect_ftu.sql, ecosystem_commerce_ftu.sql, ecosystem_ftp_ftu.sql, ecosystem_live_ftu.sql, ecosystem_ticketmaster_ftu.sql, ecosystem_topps_ftu.sql}` + `fanapp/accounts/processed/{pfi_accounts_override.sql, pfi_email_identity_map.sql}` + `fanapp/ecosystem/processed/{_processed.yaml, ecosystem_activity_daily.sql, ecosystem_collect_orders.sql, ecosystem_collect_orders_daily.sql, ecosystem_commerce_orders.sql, ecosystem_commerce_orders_daily.sql, ecosystem_fancash_activity.sql, ecosystem_fancash_daily.sql, ecosystem_fbg_account_daily.sql, ecosystem_ftp_games_daily.sql, ecosystem_ftp_sessions.sql, ecosystem_live_orders.sql, ecosystem_live_orders_daily.sql, ecosystem_ticketmaster_orders_daily.sql, ecosystem_topps_orders.sql, ecosystem_topps_orders_daily.sql}` + `fanapp/installs/processed/{fbg_ftu_attribution.sql, fbg_ftu_base.sql, fbg_ftu_touchpoints.sql, install_enrichment.sql}` + `fanapp/installs/consumption/{pfi_installs.sql (moved from processed), pfi_installs_attribution.sql}` | Same paths under `models/…` | `aa39c8e3` (BIG — 47 files, +2095 lines) |

### Files to update (copy main's current content wholesale — main is source of truth)

- `models/enterprise_metrics/consumption/_consumption.yaml` (`aa39c8e3` + `04534562`)
- `models/enterprise_metrics/consumption/base_eco_transaction_daily.sql` (`04534562`)
- `models/enterprise_metrics/enterprise_metrics.yaml` (`65ca7eb0`)
- `models/enterprise_metrics/processed/commerce_commercial_daily.sql` (`aa39c8e3`)
- `models/fanapp/accounts/processed/_processed.yaml` (`aa39c8e3`)
- `models/fanapp/installs/consumption/_consumption.yaml` (`d7c1f8c6` + `aa39c8e3`)
- `models/fanapp/installs/consumption/appsflyer_install_attribution.sql` (`aa39c8e3`)
- `models/fanapp/installs/processed/_processed.yaml` (`d7c1f8c6` + `aa39c8e3`)
- `models/fanapp/installs/processed/appsflyer_campaign_mapping.sql` (`aa39c8e3`)
- `models/fanapp/installs/processed/appsflyerid_installs.sql` (was `device_installs.sql`) (`aa39c8e3` — rename)
- `models/fanapp/installs/processed/install_enrichment.sql` (`aa39c8e3`) — may be new
- `models/fanapp/reporting/fanapp_crm_push_reporting.sql` (`aa39c8e3`)
- `models/fanapp/reporting/fbg_affiliate_ftus.sql` (`aa39c8e3`)
- `models/fanapp/reporting/fde_fbg_fanapp_daily_metrics.sql` (`aa39c8e3`)
- `models/fanapp/sessions/consumption/_consumption.yaml` (`aa39c8e3`)
- `models/fanapp/sessions/consumption/amplitude_sessions.sql` (`aa39c8e3`)
- `models/fanapp/stage/retention_refactor.sql` (`aa39c8e3`)
- `models/fangraph/3rd_party/aaia_combined.sql` (`a34a7176`)
- `models/fangraph/fangraph/fangraph.sql` (`9f638d29`)
- `models/fangraph/fangraph/fangraph_base.sql` (`9f638d29`)
- `models/fangraph/fangraph/fangraph_fan_key_master.sql` (`a34a7176`)
- `models/fangraph/fangraph/fangraph_resolver_address.sql` (`a34a7176`)
- `models/fangraph/opco_collect/collect_users.sql` (`a34a7176`)
- `models/fangraph/opco_events/events_customers.sql` (`a34a7176`)
- `models/fangraph/opco_fbg/fbg_accounts.sql` (`a34a7176`)
- `models/fangraph/opco_topps/topps_customers.sql` (`a34a7176`)
- `models/fangraph/opco_topps_digital/topps_digital_profile_aggregated.sql` (`a34a7176`)
- `models/fangraph/private_fan_id/staging/pfi_user_profile.sql` (`b75a0c44` + `04534562`)
- `models/loyalty/bonus/bonus.yaml` (`7c897f78` — removes 11 lines)
- `models/loyalty/fancash/ledger/loyalty_analytics_ledger_stage.sql` (`89300092` + `8fad8894`)
- `models/sources/fes_integrations.yml` (`cc2db27e` — add `fcc_source_mapping` entry)
- **fes_users (must-stay-AE) updates:**
  - `models/fes_users/mitchell_mann/dim_appsflyer_campaign_mapping.sql` (`63e2b414` + `139e53fe`)
  - `models/fes_users/mitchell_mann/mitchell_mann.yaml` — **split**: only entries for `dim_appsflyer_campaign_mapping.sql` go to AE (delta from `63e2b414`); rest go to analytics
  - `models/fes_users/rohan_gulati/fanapp_cohort_labels.sql` (`63e2b414` + `e93a1837`)
  - `models/fes_users/rohan_gulati/fanapp_install_identity_map.sql` (`63e2b414`)
  - `models/fes_users/rohan_gulati/rohan.yaml` — **split**: entries for `fanapp_cohort_labels.sql`, `fanapp_install_identity_map.sql` go to AE; entries for `fanapp_cohort_activity.sql`, `fanapp_reporting.sql` go to analytics

### Verification

```bash
cd ~/repos/dbt-fes-ae
dbt deps
dbt parse   # must be clean, no warnings
git grep 'standardize_state\|standardize_country' models/  # must resolve now
```

## dbt-fes-analytics PR — content to port

One PR titled roughly *"Sync analytics dbt models from fes-airflow (branch-cut → code-freeze)"*, based on `dbt-fes-analytics/main`. Add `[R] Change Request` label + ENTDATA-2147.

### New files to add

| From (main) | To (dbt-fes-analytics) | Source commit |
|---|---|---|
| `dags/dbt/models/fes_users/mitchell_mann/fanapp_ecosystem_marketing_reporting_monthly_mtd.sql` | `models/fes_users/mitchell_mann/fanapp_ecosystem_marketing_reporting_monthly_mtd.sql` | `631ef437` (950 lines) |
| `dags/dbt/models/fes_users/mitchell_mann/analytics_cross_channel_backup.sql` | `models/fes_users/mitchell_mann/analytics_cross_channel_backup.sql` | `856f38ff` |
| `dags/dbt/models/fes_users/rmcspedon/fcc_base_reporting_model.sql` | `models/fes_users/rmcspedon/fcc_base_reporting_model.sql` | `7b093af7` (+ `7b012be5` + `cc2db27e` fixes) |
| `dags/dbt/models/fes_users/rmcspedon/fcc_daily_report_long.sql` | `models/fes_users/rmcspedon/fcc_daily_report_long.sql` | `7b093af7` (+ `7b012be5` + `cc2db27e` fixes) |
| `dags/dbt/models/fes_users/rmcspedon/fcc_daily_report_wide.sql` | `models/fes_users/rmcspedon/fcc_daily_report_wide.sql` | `7b093af7` (+ `cc2db27e` fix) |
| `dags/dbt/models/fes_users/rmcspedon/fcc_transactions_and_rewards.sql` | `models/fes_users/rmcspedon/fcc_transactions_and_rewards.sql` | `7b093af7` (+ e0aba2ac, 81bee94b, 7b012be5, cc2db27e fixes — pull the final main state) |
| `dags/dbt/models/fes_users/dylan_tuch/fyp_engagement_detail.sql` | `models/fes_users/dylan_tuch/fyp_engagement_detail.sql` | `6540e14b` (621 lines) |
| `dags/dbt/models/fes_users/dylan_tuch/fyp_net_demand_daily.sql` | `models/fes_users/dylan_tuch/fyp_net_demand_daily.sql` | `6540e14b` |
| `dags/dbt/models/fes_users/dylan_tuch/jumpnav_ld_group_performance.sql` | `models/fes_users/dylan_tuch/jumpnav_ld_group_performance.sql` | `36c8899f` |
| `dags/dbt/models/fes_users/natalie_cutter/all_microtiers.sql` | `models/fes_users/natalie_cutter/all_microtiers.sql` | `64221f95` |

### Files to update (copy main's current content wholesale)

- `models/fes_users/caroline_wylie/ob_reviews.sql` (`0b607904` + `fa7d5f0b` — 5 line drift)
- `models/fes_users/mitchell_mann/agg_fanapp_click_to_action_daily.sql` (`2a49144e` — ftu→activated rename)
- `models/fes_users/mitchell_mann/agg_fanapp_click_to_action_total.sql` (`2a49144e`)
- `models/fes_users/mitchell_mann/fct_fanapp_click_to_action.sql` (`2a49144e`)
- `models/fes_users/mitchell_mann/fanapp_ecosystem_marketing_reporting_daily.sql` (`bcd4f254` — long shape refactor, 64 lines added)
- `models/fes_users/mitchell_mann/fanapp_ecosystem_marketing_reporting_monthly.sql` (`bcd4f254`)
- `models/fes_users/mitchell_mann/fanapp_ecosystem_marketing_reporting_weekly.sql` (`bcd4f254`)
- `models/fes_users/rohan_gulati/fanapp_cohort_activity.sql` (`63e2b414` + `e93a1837`)
- `models/fes_users/rohan_gulati/fanapp_reporting.sql` (`63e2b414` + `e93a1837` + `bcd4f254`)
- **Shared yaml splits (analytics halves):**
  - `models/fes_users/mitchell_mann/mitchell_mann.yaml` — entries added by `631ef437`, `2a49144e`, `856f38ff`, `bcd4f254`
  - `models/fes_users/dylan_tuch/dylan_tuch.yaml` — entries added by `64af06cd`, `6540e14b`
  - `models/fes_users/rmcspedon/ryan.yaml` — entries added by `81bee94b`, `7b012be5`
  - `models/fes_users/rohan_gulati/rohan.yaml` — entries whose `.sql` is analytics-owned only
  - `models/fes_users/natalie_cutter/natalie.yaml` — `64221f95` (analytics-only, whole delta)

### Cross-project ref rewrites required

Wherever an incoming analytics file uses `ref('some_ae_model')`, rewrite to `ref('fes_data', 'some_ae_model')`. Follow the pattern in `analytics-project-split-access-public-models.md` §Bucket A/B/C/D. The AE-model targets to watch for in the new content: `fangraph_fan_id_tenant_map`, `pfi_user_profile`, `install_enrichment`, `fanapp_reporting` (if the file lives in analytics but refs AE's `fanapp_reporting`… actually `fanapp_reporting.sql` lives in analytics — check depth here), `loyalty_analytics_ledger`, plus any seed table via `source('fes_integrations_dbt_seeds', 'X')` per PR #5's pattern.

**Sanity grep before opening PR:**
```bash
cd ~/repos/dbt-fes-analytics
grep -rn "ref\('" models/fes_users/mitchell_mann/analytics_cross_channel_backup.sql \
                  models/fes_users/mitchell_mann/fanapp_ecosystem_marketing_reporting_monthly_mtd.sql \
                  models/fes_users/rmcspedon/fcc_*.sql \
                  models/fes_users/dylan_tuch/fyp_*.sql \
                  models/fes_users/dylan_tuch/jumpnav_ld_group_performance.sql \
                  models/fes_users/natalie_cutter/all_microtiers.sql \
  | grep -v "ref('fes_data'"   # anything that prints is a candidate for rewrite
```

### Verification

```bash
cd ~/repos/dbt-fes-analytics
dbt deps
dbt parse   # must resolve cleanly against fes_data manifest
```

## Full 42-commit disposition table

| # | Commit | Author | Subject | Class | Route |
|---|---|---|---|---|---|
| 1 | `63e2b414` | Mitchell | WBR taxonomy on dim_appsflyer_campaign_mapping + fanapp_reporting | A | split: AE (dim_*.sql, cohort_labels.sql, install_identity_map.sql, rohan.yaml half, mitchell_mann.yaml half) + analytics (cohort_activity.sql, fanapp_reporting.sql, rohan.yaml half) |
| 2 | `631ef437` | Mitchell | new fanapp_ecosystem_marketing_reporting_monthly_mtd | A | analytics |
| 3 | `e0aba2ac` | Stacy | remove reward status filter on fcc_transactions_and_rewards | A | analytics (via final rmcspedon/fcc_transactions_and_rewards.sql content) |
| 4 | `01578893` | Hemanth | Add fancash_site_tenant_map to IDENTITY.SOURCE | A | AE |
| 5 | `81bee94b` | Stacy | fcc config file fix + ryan.yaml | A | analytics |
| 6 | `7b012be5` | Stacy | Fcc report fix v2 | A | analytics |
| 7 | `8fad8894` | Rohan | adding fanatics one tenant to loyalty_analytics_ledger_stage | A | AE |
| 8 | `cc2db27e` | Stacy | Fix FCC daily reporting models + new sources/imprint.yml + fes_integrations.yml delta | A | split: AE (sources) + analytics (fcc_*.sql updates) |
| 9 | `d7c1f8c6` | Alvin | Restore appsflyer_install_attribution yml + move pfi_installs to processed | A | AE |
| 10 | `65ca7eb0` | Hemanth | DCR model for comm_user_revenue_dly | A | AE |
| 11 | `7b093af7` | Ryan | Add FCC daily reporting models | A | analytics |
| 12 | `aa39c8e3` | Alvin | Achai logged in installs (47 files, +2095 lines) | A | AE |
| 13 | `ee38aa2d` | alex_sotis | Skip credit_card in cassandra_extract + schema discovery DAG | B | merge into branch |
| 14 | `64af06cd` | Mitchell | add 'users' tag to fyp_* | A | analytics (dylan_tuch.yaml half) |
| 15 | `6540e14b` | Dylan | fyp performance model + yaml add | A | analytics |
| 16 | `139e53fe` | Mitchell | Fanatics Fest custom itinerary placements | A | AE (dim_appsflyer_campaign_mapping.sql — must-stay) |
| 17 | `1c6061aa` | alex_sotis | remove alert on bonus PG compare_row_count | B | merge into branch (auto-clean) |
| 18 | `b75a0c44` | Hemanth | Fix pfi_user_profile unique constraint | A | AE |
| 19 | `b0b04e65` | Megan | add redeem match_pct check | A | AE |
| 20 | `89300092` | Hemanth | Fix tenant_id mapping for myvenue and opsuite | A | AE |
| 21 | `e93a1837` | Mitchell | login timing, Fanatics One tier, pre-install xsell cohort | A | split: AE (cohort_labels.sql, rohan.yaml half) + analytics (cohort_activity.sql, fanapp_reporting.sql, rohan.yaml half) |
| 22 | `9f638d29` | Zoe | Fangraph first opco | A | AE |
| 23 | `5944487d` | alex_sotis | adding tolerance to loyalty configs | B | merge into branch |
| 24 | `2a49144e` | Mitchell | rename ftu→activated in click_to_action | A | analytics |
| 25 | `856f38ff` | Mitchell | Add analytics_cross_channel_backup | A | analytics |
| 26 | `0b607904` | Caroline | fixing blank acco_id issue in ob reviews | A | analytics |
| 27 | `96811c94` | Megan | Revert temp loyalty_lookback→17 | D | net-zero — no action |
| 28 | `04534562` | Hemanth | Entdata 2211 (enterprise_metrics + pfi_user_profile) | A | AE |
| 29 | `bcd4f254` | Mitchell | reshape ecosystem marketing funnel to long shape | A | analytics |
| 30 | `875e58d4` | Megan | temp loyalty_lookback→17 (reverted) | D | net-zero — no action |
| 31 | `0b41d410` | Sean | Update FFNY 2026 transfers DAG schedule | B | merge into branch |
| 32 | `2bcebff3` | Sean | Add FFNY 2026 transfers DAG + SQL | B | merge into branch |
| 33 | `75452eb9` | Sean | Update ExternalTaskSensor to reference dbt_hourly DAG | B (stale) | resolve conflict: accept ours (sensor deleted on our branch) |
| 34 | `fa7d5f0b` | Natalie | Update ob_reviews.sql | A | analytics |
| 35 | `983df9e7` | Zoe | Fix regex syntax in standardize_state macro | A | AE (fold into standardize_state.sql at final main state) |
| 36 | `36c8899f` | Dylan | Upsell ftp test groups → jumpnav_ld_group_performance | A | analytics |
| 37 | `64221f95` | Natalie | Add all_microtiers | A | analytics |
| 38 | `603bc700` | Megan | Revert temp loyalty_incremental_lookback_days→15 | D | net-zero — no action |
| 39 | `7c897f78` | Sean | Remove non-empty tests from bonus models | A | AE |
| 40 | `4369c389` | Megan | temp loyalty_incremental_lookback_days→15 (reverted) | D | net-zero — no action |
| 41 | `1d7d095f` | Sean | Feature/cms exports (CMS DAG + dbt models + sources/cms.yml) | C | split: AE (fanapp/cms models + sources/cms.yml) + branch (dags/create_tables/, sql/cms/) |
| 42 | `a34a7176` | Zoe | Add macros to standardize state and country | A | AE (2 new macros + fangraph model updates) |

## Suggested order of operations

1. **Right now:** commit the 14-file AI-slop cleanup on `fes-airflow` (`dbt-cloud-migration` branch), push to update PR #2252.
2. **Next:** open `dbt-fes-ae` sync PR — new files + updated files as above. Verify `dbt parse` clean. Get review + merge.
3. **In parallel with step 2:** open `dbt-fes-analytics` sync PR — new files + updated files + cross-project ref rewrites. Verify `dbt parse` clean (needs AE manifest published from the merged step-2 PR to resolve cross-project refs — order these to land AE first).
4. **After 2 + 3 merge:** merge `origin/main` into `dbt-cloud-migration` on a new branch, resolve the 48 conflicts as documented above (`git rm -r dags/dbt/` + `--ours` on `loyalty_fcc_slim_ledger.py`), open PR into `dbt-cloud-migration`, get review + merge.
5. **Cutover 2026-07-23:** activate the 20 dormant AE schedules + 1 analytics schedule (task #83).

## What does NOT need porting

- `dbt_project.yml` var changes 27, 30, 38, 40 — two revert pairs cancel to net-zero. AE already at `loyalty_incremental_lookback_days: 2, redeem_lookback_days: 2` matching main.
- `dbt_hourly` DAG (touched by `75452eb9` on main) — a dbt-Airflow DAG for hourly-tagged models. In our new architecture, dbt Cloud handles hourly runs; the source DAG is dead in our world. Discard.

## Post-cutover follow-ups (add to remaining-steps.md)

- After merge PRs land, verify no fes-airflow ref to `dags/dbt/` remains: `git grep -F 'dags/dbt/' origin/dbt-cloud-migration`.
- Double-check no orphaned schema-yaml entries in AE/analytics point at models that live in the other repo (may need `dbt parse` warning triage).
- Delete `dags/create_tables/sql/cms/*.sql` from the ext-table DAG if the CMS source ended up not needed on our side (only relevant if the CMS models end up dbt Cloud-only).
