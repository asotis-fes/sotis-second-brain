# Analytics-project ref surface (§3 recon, 2026-07-19)

Informational output of substep §3 in [`analytics-project-split.md`](analytics-project-split.md). Not gating anything. Emitted from a scan of the 116 movable fes_users models against `dbt-fes-ae` at `origin/main` (commit `04a14df`).

## Summary

| Bucket | Distinct targets | Total refs |
|---|---:|---:|
| **A. Intra-analytics** (movers → movers, stay as `ref('X')`) | 22 | 69 |
| **B. Analytics → AE residuals** (movers → 12 residuals, become `ref('fes_data', 'X')`) | 11 | 78 |
| **C. Analytics → AE proper** (movers → non-fes_users AE models, become `ref('fes_data', 'X')`) | 58 | 329 |
| **D. Analytics → source()** (need own `sources.yml` in analytics) | 50 | 119 |
| **Unrecognized refs** (not found in AE — likely renamed/stale) | 3 | 6 |

**Total cross-project refs to rewrite (B + C)**: 407 across the 116 movers.

**Under folder-level `+access: public` (§4)**: every AE model becomes public by default, so buckets B and C are automatically covered. Bucket D requires an analytics-side `sources.yml` (or re-routing via an intermediate AE model that wraps the source — see the D section for whether any are AE-owned).

## A. Intra-analytics refs (movers → movers)

Refs that stay as `ref('X')` — same project. 69 refs across 22 distinct target models.

Top 20 most-referenced intra-analytics targets:

| Target | Refs from |
|---|---:|
| `fanapp_reporting` | 19 |
| `amplitude_to_pfi_bridge` | 5 |
| `ftp_daily_submissions` | 5 |
| `base_fanapp_deeplink_engagements` | 5 |
| `f1_attributes_audits` | 4 |
| `f1_attributes` | 4 |
| `fct_fanapp_click_to_action` | 4 |
| `dim_email_campaign_mapping` | 3 |
| `pfi_fanapp_customer_segmentation` | 2 |
| `pfi_install_attributes` | 2 |
| `pfi_install_identity_map` | 2 |
| `fanapp_cohort_activity` | 2 |
| `ticketmaster_loyalty` | 2 |
| `fanapp_early_life` | 2 |
| `fc_daily_issuance_and_redemption` | 1 |
| `fc_daily_forecast` | 1 |
| `ftu_funnel` | 1 |
| `fanapp_daily_report` | 1 |
| `fanapp_crm_sfmc_push_reporting` | 1 |
| `fct_fanapp_spend` | 1 |

## B. Cross-project refs to the 12 AE residuals

Rewrite `ref('X')` → `ref('fes_data', 'X')` in the 116 movers. 78 refs across 11 distinct residuals.

| Residual (target) | Refs from analytics-side files |
|---|---:|
| `fancash_site_tenant_mapping` | 22 |
| `amplitude_session_performance` | 13 |
| `fanapp_cohort_labels` | 12 |
| `hashed_email_eco_profit` | 11 |
| `fanapp_install_attributes` | 5 |
| `dim_appsflyer_campaign_mapping` | 5 |
| `hashed_email_ftu` | 3 |
| `dim_appsflyer_creative_mapping` | 3 |
| `fanapp_install_identity_map` | 2 |
| `fangraph_ecosystem_daily_activity_v2` | 1 |
| `fanapp_potential_fraud` | 1 |

## C. Cross-project refs to AE-proper models (non-fes_users)

Rewrite `ref('X')` → `ref('fes_data', 'X')` in the 116 movers. 329 refs across 58 distinct AE-proper models.

### Top 30 by ref count

| AE model (target) | Refs from analytics-side files |
|---|---:|
| `pfi_customer_mart` | 47 |
| `amplitude_events_correction` | 35 |
| `weekly_trading` | 24 |
| `fanapp_daily_products_wt_view` | 21 |
| `loyalty_analytics_ledger` | 20 |
| `loyalty_earn_burn_mapper` | 16 |
| `base_em_user_txn_with_fc_snapshot` | 16 |
| `tier_points_ledger_v2` | 14 |
| `fbg_affiliate_ftus` | 13 |
| `fanapp_game_results` | 9 |
| `fanapp_user_account_id_map` | 9 |
| `fan_id_tenant_map` | 7 |
| `pfi_ecosystem_daily_activity` | 6 |
| `appsflyer_inapps_correction` | 5 |
| `fanapp_metrics_daily_all` | 5 |
| `appsflyer_installs` | 4 |
| `fanapp_crm_push_fct` | 4 |
| `unified_send_log` | 4 |
| `pfi_status_matches` | 4 |
| `fangraph` | 4 |
| `shop_redemptions` | 3 |
| `pfi_fanatics_one_attributes` | 3 |
| `pfi_ftu_dates` | 3 |
| `fan_key_fan_id_map` | 3 |
| `fan_key_account_map` | 3 |
| `appsflyer_clicks` | 3 |
| `loyalty_one_credits_balance_daily_snapshot` | 2 |
| `tier_points_overrides_v2` | 2 |
| `appsflyer_metrics` | 2 |
| `fanapp_crm_sfmc_push_fct` | 2 |

### Full list (58 models)

<details><summary>Expand</summary>

- `amplitude_events_correction` (35 refs)
- `appsflyer_clicks` (3 refs)
- `appsflyer_inapps_correction` (5 refs)
- `appsflyer_installs` (4 refs)
- `appsflyer_metrics` (2 refs)
- `base_em_user_txn_with_fc_snapshot` (16 refs)
- `dim_commerce_purchase` (1 refs)
- `dim_site` (1 refs)
- `fan_id_tenant_map` (7 refs)
- `fan_key_account_map` (3 refs)
- `fan_key_fan_id_map` (3 refs)
- `fan_key_subscriber_key_map` (1 refs)
- `fanapp_crm_push_fct` (4 refs)
- `fanapp_crm_sfmc_push_fct` (2 refs)
- `fanapp_daily_products` (1 refs)
- `fanapp_daily_products_wt_view` (21 refs)
- `fanapp_game_results` (9 refs)
- `fanapp_metrics_daily_all` (5 refs)
- `fanapp_user_account_id_map` (9 refs)
- `fanapp_weekly_trading` (1 refs)
- `fangraph` (4 refs)
- `fangraph_fan_id_tenant_map` (1 refs)
- `fbg_affiliate_ftus` (13 refs)
- `fbg_to_fde_accounts` (2 refs)
- `fct_purchase_dtl` (1 refs)
- `fraudstatus_reject__order` (1 refs)
- `imprint_fg_us_customers` (1 refs)
- `loyalty_account_id_fan_id_map` (2 refs)
- `loyalty_account_tenant_map` (2 refs)
- `loyalty_analytics_ledger` (20 refs)
- `loyalty_balance` (2 refs)
- `loyalty_earn_burn_mapper` (16 refs)
- `loyalty_one_credits_balance_daily_snapshot` (2 refs)
- `one_credits_loyalty_analytics_ledger` (1 refs)
- `pfi_customer_mart` (47 refs)
- `pfi_ecosystem_daily_activity` (6 refs)
- `pfi_fanatics_one_attributes` (3 refs)
- `pfi_ftu_dates` (3 refs)
- `pfi_status_matches` (4 refs)
- `pfi_tenant_id_mapping` (1 refs)
- `place_order_success__new_product_launch` (1 refs)
- `product_lkp` (1 refs)
- `raw_badges` (1 refs)
- `register__account` (1 refs)
- `salesforce_fanid_mapping` (2 refs)
- `shop_redemptions` (3 refs)
- `signin__account` (1 refs)
- `site_id_tenant_map` (2 refs)
- `submission_result__new_product_launch` (1 refs)
- `submit_entry__new_product_launch` (2 refs)
- `ticketmaster` (1 refs)
- `ticketmaster_order_listing` (1 refs)
- `tier_points_ledger_v2` (14 refs)
- `tier_points_overrides_v2` (2 refs)
- `tier_points_tiers_info` (1 refs)
- `total_revenue` (2 refs)
- `unified_send_log` (4 refs)
- `weekly_trading` (24 refs)

</details>

## D. Direct source() calls from movers

119 source() calls across 50 distinct (source, table) pairs.

**Handling**: analytics repo needs its own `sources.yml` declaring these sources. Copy the source blocks from `dbt-fes-ae/models/sources/*.yml` into `dbt-fes-analytics/models/sources/`. Sources are NOT part of dbt Mesh's `access: public` model — each project declares the sources it uses.

### By source name

| Source | Tables used |
|---|---:|
| `fes_integrations__sheetzu` | 11 |
| `fbg_fde__fbg_transactions` | 7 |
| `fes_users__rohan_gulati` | 5 |
| `live_fde__data_views_fanatics` | 4 |
| `fbg_fde__fbg_users` | 4 |
| `salesforce__schema_fanjourney_loyalty_promotion_shares` | 4 |
| `fde__fde_info` | 2 |
| `fes_users__caroline_wylie` | 1 |
| `amplitude__amplitude` | 1 |
| `FES_USERS__DYLAN_TUCH` | 1 |
| `launch_darkly__public` | 1 |
| `commerce_mde__mde_info` | 1 |
| `fanapp_recommendation` | 1 |
| `appsflyer__appsflyer_fde_snowflake` | 1 |
| `fangraph__admin` | 1 |
| `pmg_fanapp__fanapp_custom` | 1 |
| `fes_users__kevin_bokor` | 1 |
| `fes_users__mitchell_mann` | 1 |
| `salesforce_qc__schema_loyalty_tier_points` | 1 |
| `enterprise_metrics__reporting` | 1 |

<details><summary>Expand (source, table) pairs</summary>

- `source('FES_USERS__DYLAN_TUCH', 'dim_states')` (5 refs)
- `source('amplitude__amplitude', 'merge_ids_537355')` (14 refs)
- `source('appsflyer__appsflyer_fde_snowflake', 'inapps_retargeting_view')` (1 refs)
- `source('commerce_mde__mde_info', 'product_lkp_v')` (1 refs)
- `source('enterprise_metrics__reporting', 'reporting_periods_ttm')` (1 refs)
- `source('fanapp_recommendation', 'fanapp_recs__carousel_widgets')` (1 refs)
- `source('fangraph__admin', 'fan_id_tenant_map')` (6 refs)
- `source('fbg_fde__fbg_transactions', 'fde_account_revenue_summary_daily')` (4 refs)
- `source('fbg_fde__fbg_transactions', 'fde_customer_metrics_daily')` (2 refs)
- `source('fbg_fde__fbg_transactions', 'fde_customer_variable_profit')` (3 refs)
- `source('fbg_fde__fbg_transactions', 'fde_f1_attributes_audits')` (3 refs)
- `source('fbg_fde__fbg_transactions', 'fde_f1customerforecast')` (1 refs)
- `source('fbg_fde__fbg_transactions', 'fde_f1ltforecast')` (1 refs)
- `source('fbg_fde__fbg_transactions', 'fde_loyalty_gifting_tracker')` (1 refs)
- `source('fbg_fde__fbg_users', 'fbg_to_fde_accounts')` (1 refs)
- `source('fbg_fde__fbg_users', 'fbg_to_fde_vip_events_dash_query')` (1 refs)
- `source('fbg_fde__fbg_users', 'v_fbg_customer_mart')` (12 refs)
- `source('fbg_fde__fbg_users', 'v_kyc_final')` (2 refs)
- `source('fde__fde_info', 'appsflyer_clicks_retargeting')` (3 refs)
- `source('fde__fde_info', 'appsflyer_inapps_retargeting')` (2 refs)
- `source('fes_integrations__sheetzu', 'fanapp_forecast_installs_placement')` (1 refs)
- `source('fes_integrations__sheetzu', 'fanapp_forecast_installs_placement_by_day')` (1 refs)
- `source('fes_integrations__sheetzu', 'fanapp_forecast_placement_mapping')` (2 refs)
- `source('fes_integrations__sheetzu', 'fanapp_paid_marketing_creative_mapping_field_values')` (1 refs)
- `source('fes_integrations__sheetzu', 'fanapp_paid_marketing_creative_mapping_meta_historicals')` (1 refs)
- `source('fes_integrations__sheetzu', 'fanapp_paid_marketing_creative_mapping_nonmeta_historicals')` (1 refs)
- `source('fes_integrations__sheetzu', 'journey_messaging_reporting_labels')` (1 refs)
- `source('fes_integrations__sheetzu', 'live_collect_opt_out')` (1 refs)
- `source('fes_integrations__sheetzu', 'ob_declined')` (3 refs)
- `source('fes_integrations__sheetzu', 'ob_topps_drops_inventory')` (2 refs)
- `source('fes_integrations__sheetzu', 'vip_microtier_list')` (2 refs)
- `source('fes_users__caroline_wylie', 'tlc_beta_list_6_3')` (1 refs)
- `source('fes_users__kevin_bokor', 'fanapp_paid_installs_ab_test_full')` (1 refs)
- `source('fes_users__mitchell_mann', 'fct_contribution_margin_actuals')` (1 refs)
- `source('fes_users__rohan_gulati', 'fcbudget26cleaned')` (1 refs)
- `source('fes_users__rohan_gulati', 'internalusers')` (1 refs)
- `source('fes_users__rohan_gulati', 'naecommsites')` (7 refs)
- `source('fes_users__rohan_gulati', 'site_tenant_mapping')` (6 refs)
- `source('fes_users__rohan_gulati', 'tlcbetafinallistnew511')` (1 refs)
- `source('launch_darkly__public', 'eval_view')` (1 refs)
- `source('live_fde__data_views_fanatics', 'dim_collect_submissions_v')` (2 refs)
- `source('live_fde__data_views_fanatics', 'fanatics_collect_orders_v')` (3 refs)
- `source('live_fde__data_views_fanatics', 'fanatics_live_orders_v')` (2 refs)
- `source('live_fde__data_views_fanatics', 'fct_live_orders_v2_v')` (1 refs)
- `source('pmg_fanapp__fanapp_custom', 'analytics_cross_channel')` (5 refs)
- `source('salesforce__schema_fanjourney_loyalty_promotion_shares', 'LoyaltyProgramMbrPromoti_00DHs000003WzIz__dll')` (1 refs)
- `source('salesforce__schema_fanjourney_loyalty_promotion_shares', 'LoyaltyProgramMember_00DHs000003WzIz__dll')` (1 refs)
- `source('salesforce__schema_fanjourney_loyalty_promotion_shares', 'Promotion_00DHs000003WzIz__dll')` (1 refs)
- `source('salesforce__schema_fanjourney_loyalty_promotion_shares', 'ssot__Promotion__dlm')` (1 refs)
- `source('salesforce_qc__schema_loyalty_tier_points', 'ssot__Promotion__dlm')` (1 refs)

</details>

## Unrecognized refs (not found in AE)

These refs don't resolve to any model in `dbt-fes-ae/origin/main`. Likely reasons: renamed since, macros returning a name, or already two-arg cross-project refs (which would need investigation).

- `fanapp_paid_campaign_mapping` — 4 refs
    - mitchell_mann/fanapp_paid_marketing_reporting.sql:34
    - mitchell_mann/fanapp_paid_marketing_reporting.sql:69
    - rohan_gulati/fanapp_paid_spend.sql:45
    - _(and 1 more)_
- `fanapp_paid_marketing_march_madness_forecast` — 1 refs
    - mitchell_mann/fanapp_paid_marketing_march_madness_pacing_dashboard.sql:507
- `pfi_app_engagement` — 1 refs
    - mitchell_mann/pfi_fanapp_crm_user_segments.sql:57

---

## Method

- Ref extraction: `git grep -nE "ref\(\s*['\"]" origin/main -- 'models/fes_users/*.sql'` → 1656 lines, then parsed via Python regex handling one-arg + two-arg forms.
- Source extraction: `git grep -nE "source\(\s*['\"]" origin/main -- 'models/fes_users/*.sql'` → 133 lines.
- AE-proper model set: enumerated from `git ls-tree -r origin/main --name-only | grep '^models/.*\.sql$'` minus fes_users models (128).
- Movers vs residuals: 116 movers = 128 fes_users minus the 12-model must-stay closure (§1 result table in [`analytics-project-split.md`](analytics-project-split.md)).
