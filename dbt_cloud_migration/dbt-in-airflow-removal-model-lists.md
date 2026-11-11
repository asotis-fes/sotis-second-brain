# Phase 0 §0.2 — Model set per tag (dbt-fes-ae)
Source: `dbt ls --resource-type model --output json` against dbt-fes-ae fix/fusion-parse-cleanup
(4 commits ahead of origin/main; delta is CI-only, tag map identical)

Total models in project: **980**
Total seeds in project: **11**

---

## The 8 new ingest-DAG tags

### Tag `mdm_sdp`  (3 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `mdm_to_sdp_leagues` | `mdm_to_sdp_leagues` | `models/mde/mdm_sdp/mdm_to_sdp_leagues.sql` | — |
| `mdm_to_sdp_players` | `mdm_to_sdp_players` | `models/mde/mdm_sdp/mdm_to_sdp_players.sql` | — |
| `mdm_to_sdp_teams` | `mdm_to_sdp_teams` | `models/mde/mdm_sdp/mdm_to_sdp_teams.sql` | — |

### Tag `google_ad_manager`  (9 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `gam_advertiser_spend_summary` | `gam_advertiser_spend_summary` | `models/fes_integrations/google_ads/gam_advertiser_spend_summary.sql` | — |
| `gam_daily_filled` | `gam_daily_filled` | `models/fes_integrations/google_ads/gam_daily_filled.sql` | — |
| `gam_executive_revenue_summary` | `gam_executive_revenue_summary` | `models/fes_integrations/google_ads/gam_executive_revenue_summary.sql` | — |
| `gam_fill_rate_by_ad_unit` | `gam_fill_rate_by_ad_unit` | `models/fes_integrations/google_ads/gam_fill_rate_by_ad_unit.sql` | — |
| `gam_inventory_fill_rate_by_ad_unit` | `gam_inventory_fill_rate_by_ad_unit` | `models/fes_integrations/google_ads/gam_inventory_fill_rate_by_ad_unit.sql` | — |
| `gam_inventory_sell_through_forecasting` | `gam_inventory_sell_through_forecasting` | `models/fes_integrations/google_ads/gam_inventory_sell_through_forecasting.sql` | — |
| `gam_line_item_pacing_delivery` | `gam_line_item_pacing_delivery` | `models/fes_integrations/google_ads/gam_line_item_pacing_delivery.sql` | — |
| `gam_unified_impressions_analysis` | `gam_unified_impressions_analysis` | `models/fes_integrations/google_ads/gam_unified_impressions_analysis.sql` | — |
| `gam_viewability_by_placement` | `gam_viewability_by_placement` | `models/fes_integrations/google_ads/gam_viewability_by_placement.sql` | — |

### Tag `identity`  (5 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `loyalty_private_fan_id_map` | `loyalty_private_fan_id_map` | `models/identity/orchestration/loyalty_private_fan_id_map.sql` | — |
| `martech_private_fan_id_map` | `martech_private_fan_id_map` | `models/identity/orchestration/martech_private_fan_id_map.sql` | — |
| `unified_profile_core` | `core` | `models/identity/unified_profile/unified_profile_core.sql` | — |
| `unified_profile_favorites` | `favorites` | `models/identity/unified_profile/unified_profile_favorites.sql` | — |
| `unified_profile_preferences` | `preferences` | `models/identity/unified_profile/unified_profile_preferences.sql` | — |

### Tag `impact`  (1 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `ticketmaster_order_listing` | `ticketmaster_order_listing` | `models/fes_integrations/impact/ticketmaster_order_listing.sql` | — |

### Tag `fesbonus`  (8 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `bonus` | `bonus` | `models/loyalty/bonus/bonus.sql` | — |
| `bonus_reward` | `bonus_reward` | `models/loyalty/bonus/bonus_reward.sql` | — |
| `bonus_step` | `bonus_step` | `models/loyalty/bonus/bonus_step.sql` | — |
| `user_bonus` | `user_bonus` | `models/loyalty/bonus/user_bonus.sql` | — |
| `user_bonus_reward` | `user_bonus_reward` | `models/loyalty/bonus/user_bonus_reward.sql` | — |
| `user_bonus_step` | `user_bonus_step` | `models/loyalty/bonus/user_bonus_step.sql` | — |
| `user_bonus_step_event` | `user_bonus_step_event` | `models/loyalty/bonus/user_bonus_step_event.sql` | — |
| `user_event` | `user_event` | `models/loyalty/bonus/user_event.sql` | — |

### Tag `fesloyalty`  (25 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `account_balance` | `account_balance` | `models/loyalty/source/account_balance.sql` | — |
| `allocation` | `allocation` | `models/loyalty/source/allocation.sql` | — |
| `allocation_remaining` | `allocation_remaining` | `models/loyalty/source/allocation_remaining.sql` | — |
| `auth_bucket_hold` | `auth_bucket_hold` | `models/loyalty/source/auth_bucket_hold.sql` | — |
| `auth_hold` | `auth_hold` | `models/loyalty/source/auth_hold.sql` | — |
| `bucket` | `bucket` | `models/loyalty/source/bucket.sql` | — |
| `bucket_type` | `bucket_type` | `models/loyalty/source/bucket_type.sql` | — |
| `capture_event` | `capture_event` | `models/loyalty/source/capture_event.sql` | — |
| `entry` | `entry` | `models/loyalty/source/entry.sql` | — |
| `idempotency_keys` | `idempotency_keys` | `models/loyalty/source/idempotency_keys.sql` | — |
| `journal` | `journal` | `models/loyalty/source/journal.sql` | — |
| `journal_normalized` | `journal_normalized` | `models/loyalty/source/journal_normalized.sql` | — |
| `loyalty_account_postgres` | `loyalty_account` | `models/loyalty/source/loyalty_account_postgres.sql` | — |
| `one_credits_loyalty_analytics_ledger` | `one_credits_loyalty_analytics_ledger` | `models/loyalty/one_credits/one_credits_loyalty_analytics_ledger.sql` | — |
| `one_credits_loyalty_analytics_ledger_fbg` | `one_credits_loyalty_analytics_ledger_fbg` | `models/loyalty/one_credits/one_credits_loyalty_analytics_ledger_fbg.sql` | — |
| `one_credits_loyalty_analytics_ledger_no_auth` | `one_credits_loyalty_analytics_ledger_no_auth` | `models/loyalty/one_credits/one_credits_loyalty_analytics_ledger_no_auth.sql` | — |
| `opco_program_account` | `opco_program_account` | `models/loyalty/source/opco_program_account.sql` | — |
| `operating_company` | `operating_company` | `models/loyalty/source/operating_company.sql` | — |
| `program` | `program` | `models/loyalty/source/program.sql` | — |
| `program_account_balance` | `program_account_balance` | `models/loyalty/source/program_account_balance.sql` | — |
| `system_loyalty_account` | `system_loyalty_account` | `models/loyalty/source/system_loyalty_account.sql` | — |
| `transaction` | `transaction` | `models/loyalty/source/transaction.sql` | — |
| `transfer_restriction` | `transfer_restriction` | `models/loyalty/source/transfer_restriction.sql` | — |
| `void_auth_event` | `void_auth_event` | `models/loyalty/source/void_auth_event.sql` | — |
| `void_remaining` | `void_remaining` | `models/loyalty/source/void_remaining.sql` | — |

### Tag `magnite`  (1 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `magnite_pa_hourly` | `magnite_pa_hourly` | `models/fes_integrations/magnite/magnite_pa_hourly.sql` | — |

### Tag `optin_preferences`  (6 models)

| model | alias | file | other tags on this model |
|---|---|---|---|
| `xp_optin_preferences` | `xp_optin_preferences` | `models/xtremepush/xp_optin_preferences.sql` | — |
| `xp_optin_preferences_delta` | `xp_optin_preferences_delta` | `models/xtremepush/xp_optin_preferences_delta.sql` | — |
| `xp_optin_preferences_snapshot` | `xp_optin_preferences_snapshot` | `models/xtremepush/xp_optin_preferences_snapshot.sql` | — |
| `xp_push_last_opened` | `xp_push_last_opened` | `models/xtremepush/xp_push_last_opened.sql` | — |
| `xp_push_last_opened_delta` | `xp_push_last_opened_delta` | `models/xtremepush/xp_push_last_opened_delta.sql` | — |
| `xp_push_last_opened_snapshot` | `xp_push_last_opened_snapshot` | `models/xtremepush/xp_push_last_opened_snapshot.sql` | — |

---

## Tag collisions — models tagged with an ingest tag AND another job's tag

**No tag collisions detected** — each ingest-tagged model is built by exactly one job.

---

## Reference: standalone-DAG tags (existing 22 jobs)

| tag | model count | notes |
|---|---|---|
| `loyalty_6hours` | 13 |  |
| `loyalty` | 42 |  |
| `loyalty_metrics` | 12 |  |
| `loyalty_monthly` | 1 |  |
| `fanflow` | 138 |  |
| `hourly` | 6 |  |
| `daily` | 147 |  |
| `daily_9am` | 4 |  |
| `3hours` | 12 |  |
| `6hours` | 34 |  |
| `weekly` | 0 | 0 hits — variant may not match (e.g. `fanatics_one` vs `fanaticsone`) |
| `meta_ads` | 1 |  |
| `ltv` | 22 |  |
| `mde` | 68 |  |
| `fanapp_recs` | 10 |  |
| `enterprise_metrics` | 36 |  |
| `enterprise_metrics_daily` | 12 |  |
| `fanaticsone` | 21 |  |
| `xtremepush` | 4 |  |
| `users` | 124 |  |
| `sources` | 0 | 0 hits — variant may not match (e.g. `fanatics_one` vs `fanaticsone`) |
| `fangraph` | 209 |  |

---

## Seed dependencies per ingest tag  (Phase 0 §0.3)

Seed inventory (11): `dma`, `fanapp_paid_campaign_mapping`, `fanapp_paid_marketing_march_madness_forecast`, `fanapp_recs__signal_weights`, `fc_site_tenant_mapping`, `nba_opco_experiment_metadata`, `nba_opco_rollout_schedule`, `osb_states`, `survivor_team_lkp`, `tenant_mapping`, `ticketmaster_sport_mapping`

### `mdm_sdp`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

### `google_ad_manager`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

### `identity`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

### `impact`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

### `fesbonus`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

### `fesloyalty`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

### `magnite`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

### `optin_preferences`  →  seed refs

_(no seed dependencies — dbt Cloud job needs no seed pre-load)_

