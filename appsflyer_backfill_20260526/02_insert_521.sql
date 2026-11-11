-- ============================================================================
-- APPSFLYER BACKFILL — Surgical INSERT for dt = '2026-05-21'
-- ============================================================================
-- Per 01c_locate_521_data.sql, only APPSFLYER_INAPPS needs action.
-- The other 5 source-fed models are either already loaded or have no 5/21
-- data in source.
--
-- Strategy: INSERT rows from source WHERE dt = '2026-05-21'. Target currently
-- has 0 rows for that dt, so no anti-join / no DELETE needed.
--
-- We deliberately do NOT trigger a `dbt run` on appsflyer_inapps, because
-- source has ~67M rows of recent _ingestion_time data spanning multiple dt
-- values (5/22-5/27). An incremental run would pull those in and could
-- duplicate rows already in target for dt 5/22/5/23 etc.
--
-- AFTER THIS SCRIPT:
--   Run downstream full-refresh in your terminal:
--     cd ~/repos/fes-airflow/dags/dbt
--     source ../../.env
--     dbt run --select appsflyer_user_id appsflyer_inapps_correction \
--             --full-refresh --target prod
--
--   Then run 03_validation.sql.
-- ============================================================================

BEGIN;

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
WHERE dt = '2026-05-21';

COMMIT;
