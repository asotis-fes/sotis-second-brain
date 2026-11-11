-- ============================================================================
-- APPSFLYER BACKFILL — DELETE+INSERT for affected dates in INAPPS
-- ============================================================================
-- Per user's manual dt-based investigation, INAPPS is missing/partial on
-- 5/20, 5/21, and 5/22. Source has the complete data for these days now.
--
-- Strategy:
--   - DELETE target rows where dt IN ('2026-05-20', '2026-05-21', '2026-05-22')
--     (5/21 is a no-op since target has 0 rows there; included for symmetry.)
--   - INSERT all rows from source for those same 3 dates.
--
-- IMPORTANT: Run 01d_check_dt_window.sql FIRST and confirm:
--   1. For APPSFLYER_INAPPS dt 2026-05-20, 2026-05-21, 2026-05-22: each row
--      shows flag 'target empty…' or 'target partial…' (i.e., source >= target).
--      If any shows 'NOT SAFE', STOP — do not run this script as-is.
--   2. If 01d surfaces issues for OTHER models on the same days, add separate
--      DELETE+INSERT blocks for them (this file only handles INAPPS).
--
-- AFTER THIS SCRIPT:
--   cd ~/repos/fes-airflow/dags/dbt
--   source ../../.env
--   dbt run --select appsflyer_user_id appsflyer_inapps_correction \
--           --full-refresh --target prod
--
--   Then run 03_validation.sql.
-- ============================================================================

BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_INAPPS
WHERE dt IN ('2026-05-20', '2026-05-21', '2026-05-22');

INSERT INTO FDE.FDE_INFO.APPSFLYER_INAPPS (
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_attribution_lookback, af_c_id, af_channel, af_cost_currency, af_cost_model,
    af_cost_value, af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3,
    af_sub4, af_sub5, af_sub_siteid, amazon_aid, app_id, app_name, app_type,
    app_version, appsflyer_id, att, attributed_touch_time, attributed_touch_type,
    bundle_id, campaign, campaign_type, carrier, city, conversion_type,
    country_code, customer_user_id, deeplink_url, device_category,
    device_download_time, device_model, dma, dt, engagement_type, event_name,
    event_revenue, event_revenue_currency, event_revenue_usd, event_source,
    event_time, event_value, gp_broadcast_referrer, h, http_referrer, idfa,
    idfv, install_time, ip, is_lat, is_organic, is_primary_attribution,
    is_retargeting, keyword_id, keyword_match_type, language, match_type,
    media_source, network_account_id, operator, original_url, os_version,
    platform, postal_code, region, sdk_version, state, user_agent, wifi,
    _ingestion_time, android_id, custom_data, store_product_page
)
SELECT
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_attribution_lookback, af_c_id, af_channel, af_cost_currency, af_cost_model,
    af_cost_value, af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3,
    af_sub4, af_sub5, af_sub_siteid, amazon_aid, app_id, app_name, app_type,
    app_version, appsflyer_id, att, attributed_touch_time, attributed_touch_type,
    bundle_id, campaign, campaign_type, carrier, city, conversion_type,
    country_code, customer_user_id, deeplink_url, device_category,
    device_download_time, device_model, dma, dt, engagement_type, event_name,
    event_revenue, event_revenue_currency, event_revenue_usd, event_source,
    event_time, event_value, gp_broadcast_referrer, h, http_referrer, idfa,
    idfv, install_time, ip, is_lat, is_organic, is_primary_attribution,
    is_retargeting, keyword_id, keyword_match_type, language, match_type,
    media_source, network_account_id, operator, original_url, os_version,
    platform, postal_code, region, sdk_version, state, user_agent, wifi,
    _ingestion_time, android_id, custom_data, store_product_page
FROM appsflyer.appsflyer_fde_snowflake.inapps_view
WHERE dt IN ('2026-05-20', '2026-05-21', '2026-05-22');

COMMIT;
