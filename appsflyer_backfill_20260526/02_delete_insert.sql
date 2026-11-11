-- ============================================================================
-- APPSFLYER BACKFILL — DELETE + INSERT for the 6 source-fed models
-- ============================================================================
-- PREREQUISITES:
--   1. Backups created (FES_USERS.ALEX_SOTIS.<table>_BACKUP20260526) — DONE.
--   2. 01_diagnostics.sql shows 'safe to proceed' for every model you plan
--      to touch. If a model says 'not safe' or 'no rows in window', SKIP
--      its block here.
--   3. Airflow appsflyer DAG is PAUSED to avoid concurrent writes.
--
-- AFTER THIS SCRIPT:
--   Run the downstream full-refresh in your terminal (NOT in Snowflake):
--     cd ~/repos/fes-airflow/dags/dbt
--     source ../../.env
--     dbt run --select appsflyer_user_id appsflyer_inapps_correction \
--             --full-refresh --target prod
--
--   Then run 03_validation.sql.
--
-- NOTE on clicks: skip block 6 if diagnostics shows clicks source has no
-- rows (the view was contractually removed per appsflyer.yml).
-- ============================================================================


-- ============================================================================
-- BLOCK 1 / 6 — APPSFLYER_INAPPS
-- ============================================================================
BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_INAPPS
WHERE _ingestion_time > '2026-05-11';

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
WHERE _ingestion_time > '2026-05-11';

COMMIT;


-- ============================================================================
-- BLOCK 2 / 6 — APPSFLYER_INSTALLS
-- ============================================================================
BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_INSTALLS
WHERE _ingestion_time > '2026-05-11';

INSERT INTO FDE.FDE_INFO.APPSFLYER_INSTALLS (
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_attribution_lookback, af_c_id, af_channel, af_cost_currency, af_cost_model,
    af_cost_value, af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3,
    af_sub4, af_sub5, af_sub_siteid, amazon_aid, android_id, app_id, app_name,
    app_type, app_version, appsflyer_id, att, attributed_touch_time,
    attributed_touch_type, bundle_id, campaign, campaign_type, carrier, city,
    contributor_1_af_prt, contributor_1_campaign, contributor_1_engagement_type,
    contributor_1_match_type, contributor_1_media_source, contributor_1_touch_time,
    contributor_1_touch_type, contributor_2_af_prt, contributor_2_campaign,
    contributor_2_engagement_type, contributor_2_match_type,
    contributor_2_media_source, contributor_2_touch_time, contributor_2_touch_type,
    contributor_3_af_prt, contributor_3_campaign, contributor_3_engagement_type,
    contributor_3_match_type, contributor_3_media_source, contributor_3_touch_time,
    contributor_3_touch_type, conversion_type, country_code, customer_user_id,
    deeplink_url, device_category, device_download_time, device_model, dma, dt,
    engagement_type, event_name, event_source, event_time, gp_click_time,
    gp_install_begin, gp_referrer, h, http_referrer, idfa, idfv,
    install_app_store, install_time, ip, is_lat, is_organic, is_retargeting,
    keyword_id, keyword_match_type, language, match_type, media_source,
    network_account_id, operator, original_url, os_version, platform,
    postal_code, region, sdk_version, state, user_agent, wifi, _ingestion_time,
    gdpr_applies, raw_consent_data, custom_data, store_product_page
)
SELECT
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_attribution_lookback, af_c_id, af_channel, af_cost_currency, af_cost_model,
    af_cost_value, af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3,
    af_sub4, af_sub5, af_sub_siteid, amazon_aid, android_id, app_id, app_name,
    app_type, app_version, appsflyer_id, att, attributed_touch_time,
    attributed_touch_type, bundle_id, campaign, campaign_type, carrier, city,
    contributor_1_af_prt, contributor_1_campaign, contributor_1_engagement_type,
    contributor_1_match_type, contributor_1_media_source, contributor_1_touch_time,
    contributor_1_touch_type, contributor_2_af_prt, contributor_2_campaign,
    contributor_2_engagement_type, contributor_2_match_type,
    contributor_2_media_source, contributor_2_touch_time, contributor_2_touch_type,
    contributor_3_af_prt, contributor_3_campaign, contributor_3_engagement_type,
    contributor_3_match_type, contributor_3_media_source, contributor_3_touch_time,
    contributor_3_touch_type, conversion_type, country_code, customer_user_id,
    deeplink_url, device_category, device_download_time, device_model, dma, dt,
    engagement_type, event_name, event_source, event_time, gp_click_time,
    gp_install_begin, gp_referrer, h, http_referrer, idfa, idfv,
    install_app_store, install_time, ip, is_lat, is_organic, is_retargeting,
    keyword_id, keyword_match_type, language, match_type, media_source,
    network_account_id, operator, original_url, os_version, platform,
    postal_code, region, sdk_version, state, user_agent, wifi, _ingestion_time,
    gdpr_applies, raw_consent_data, custom_data, store_product_page
FROM appsflyer.appsflyer_fde_snowflake.installs_view
WHERE _ingestion_time > '2026-05-11';

COMMIT;


-- ============================================================================
-- BLOCK 3 / 6 — APPSFLYER_SESSIONS
-- ============================================================================
BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_SESSIONS
WHERE _ingestion_time > '2026-05-11';

INSERT INTO FDE.FDE_INFO.APPSFLYER_SESSIONS (
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_c_id, af_channel, af_cost_currency, af_cost_model, af_cost_value,
    af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3, af_sub4, af_sub5,
    af_sub_siteid, amazon_aid, android_id, app_id, app_name, app_type,
    app_version, appsflyer_id, att, attributed_touch_time, attributed_touch_type,
    bundle_id, campaign, campaign_type, carrier, city, conversion_type,
    country_code, customer_user_id, device_category, device_model, dma, dt,
    engagement_type, event_name, event_source, event_time, gp_click_time,
    gp_install_begin, gp_referrer, h, http_referrer, idfa, idfv,
    install_app_store, install_time, ip, is_lat, is_organic, is_primary_attribution,
    is_retargeting, keyword_id, language, match_type, media_source,
    network_account_id, operator, original_url, os_version, platform,
    postal_code, region, sdk_version, state, user_agent, wifi, _ingestion_time,
    gdpr_applies, raw_consent_data, custom_data, store_product_page
)
SELECT
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_c_id, af_channel, af_cost_currency, af_cost_model, af_cost_value,
    af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3, af_sub4, af_sub5,
    af_sub_siteid, amazon_aid, android_id, app_id, app_name, app_type,
    app_version, appsflyer_id, att, attributed_touch_time, attributed_touch_type,
    bundle_id, campaign, campaign_type, carrier, city, conversion_type,
    country_code, customer_user_id, device_category, device_model, dma, dt,
    engagement_type, event_name, event_source, event_time, gp_click_time,
    gp_install_begin, gp_referrer, h, http_referrer, idfa, idfv,
    install_app_store, install_time, ip, is_lat, is_organic, is_primary_attribution,
    is_retargeting, keyword_id, language, match_type, media_source,
    network_account_id, operator, original_url, os_version, platform,
    postal_code, region, sdk_version, state, user_agent, wifi, _ingestion_time,
    gdpr_applies, raw_consent_data, custom_data, store_product_page
FROM appsflyer.appsflyer_fde_snowflake.sessions_view
WHERE _ingestion_time > '2026-05-11';

COMMIT;


-- ============================================================================
-- BLOCK 4 / 6 — APPSFLYER_SSOT_UNIFIED
-- ============================================================================
BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_SSOT_UNIFIED
WHERE _ingestion_time > '2026-05-11';

INSERT INTO FDE.FDE_INFO.APPSFLYER_SSOT_UNIFIED (
    af_ad, af_adset, af_adset_id, af_ad_id, af_c_id, app_id,
    attributed_touch_type, attribution_method, campaign, conversion_type,
    days_post_attribution, event_name, geo, install_date, is_primary_attribution,
    media_source, revenue_selected_currency, revenue_usd, selected_currency,
    skan_duplicates, uninstalls_count, unique_users, version, _ingestion_time
)
SELECT
    af_ad, af_adset, af_adset_id, af_ad_id, af_c_id, app_id,
    attributed_touch_type, attribution_method, campaign, conversion_type,
    days_post_attribution, event_name, geo, install_date, is_primary_attribution,
    media_source, revenue_selected_currency, revenue_usd, selected_currency,
    skan_duplicates, uninstalls_count, unique_users, version, _ingestion_time
FROM appsflyer.appsflyer_fde_snowflake.ssot_unified_view
WHERE _ingestion_time > '2026-05-11';

COMMIT;


-- ============================================================================
-- BLOCK 5 / 6 — APPSFLYER_SSOT_USER_ACQUISITION
-- ============================================================================
BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_SSOT_USER_ACQUISITION
WHERE _ingestion_time > '2026-05-11';

INSERT INTO FDE.FDE_INFO.APPSFLYER_SSOT_USER_ACQUISITION (
    af_ad, af_adset, af_adset_id, af_ad_id, af_c_id, app_id,
    attributed_touch_type, attribution_method, campaign, conversion_type,
    days_post_attribution, event_name, geo, install_date, is_primary_attribution,
    media_source, revenue_selected_currency, revenue_usd, selected_currency,
    skan_duplicates, uninstalls_count, unique_users, version, _ingestion_time
)
SELECT
    af_ad, af_adset, af_adset_id, af_ad_id, af_c_id, app_id,
    attributed_touch_type, attribution_method, campaign, conversion_type,
    days_post_attribution, event_name, geo, install_date, is_primary_attribution,
    media_source, revenue_selected_currency, revenue_usd, selected_currency,
    skan_duplicates, uninstalls_count, unique_users, version, _ingestion_time
FROM appsflyer.appsflyer_fde_snowflake.ssot_user_acquisition_view
WHERE _ingestion_time > '2026-05-11';

COMMIT;


-- ============================================================================
-- BLOCK 6 / 6 — APPSFLYER_CLICKS  (SKIP if diagnostics shows source empty)
-- ============================================================================
-- The clicks_view was contractually removed per appsflyer.yml. Only run this
-- block if 01_diagnostics returned 'safe to proceed' for APPSFLYER_CLICKS.
BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_CLICKS
WHERE _ingestion_time > '2026-05-11';

INSERT INTO FDE.FDE_INFO.APPSFLYER_CLICKS (
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_attribution_lookback, af_c_id, af_channel, af_cost_currency, af_cost_model,
    af_cost_value, af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3,
    af_sub4, af_sub5, af_sub_siteid, android_id, app_id, blocked_reason,
    blocked_sub_reason, campaign, city, country_code, device_category,
    device_model, dma, dt, engagement_type, event_name, event_source, event_time,
    event_value, h, http_referrer, idfa, idfv, ip, is_organic, is_retargeting,
    language, media_source, oaid, original_url, os_version, platform,
    postal_code, region, state, user_agent, _ingestion_time, ad_placement,
    af_web_id, appsflyer_id, bundle_id, campaign_type, customer_user_id,
    device_id_type, imei, network_account_id, store_product_page
)
SELECT
    advertising_id, af_ad, af_ad_id, af_ad_type, af_adset, af_adset_id,
    af_attribution_lookback, af_c_id, af_channel, af_cost_currency, af_cost_model,
    af_cost_value, af_keywords, af_prt, af_siteid, af_sub1, af_sub2, af_sub3,
    af_sub4, af_sub5, af_sub_siteid, android_id, app_id, blocked_reason,
    blocked_sub_reason, campaign, city, country_code, device_category,
    device_model, dma, dt, engagement_type, event_name, event_source, event_time,
    event_value, h, http_referrer, idfa, idfv, ip, is_organic, is_retargeting,
    language, media_source, oaid, original_url, os_version, platform,
    postal_code, region, state, user_agent, _ingestion_time, ad_placement,
    af_web_id, appsflyer_id, bundle_id, campaign_type, customer_user_id,
    device_id_type, imei, network_account_id, store_product_page
FROM appsflyer.appsflyer_fde_snowflake.clicks_view
WHERE _ingestion_time > '2026-05-11';

COMMIT;
