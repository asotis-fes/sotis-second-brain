-- ============================================================================
-- APPSFLYER BACKFILL — Round 2: stuck rows on INAPPS ingest_d=5/26
-- ============================================================================
-- Per 01e analysis + the dt breakdown:
--   INAPPS has 11.17M rows stuck:
--     dt=2026-05-23, _ingestion_time on 5/26: 4,847,541 stuck
--     dt=2026-05-26, _ingestion_time on 5/26: 6,322,425 stuck
--   INSTALLS: 0 stuck (no action needed).
--
-- Strategy: DELETE target rows where _ingestion_time falls on 5/26 AND dt in
-- the affected set, then re-INSERT all source rows matching the same filter.
--
-- NOTE: this REPLACES the affected slice of target with whatever source
-- currently has. Before running, verify the diagnostic still says source >=
-- target on these (model, dt) buckets — that's a precondition for DELETE+
-- INSERT to be safe.
--
-- Recommended pre-flight (copy to your editor and confirm src >= tgt):
--   SELECT dt, COUNT(*) AS n FROM appsflyer.appsflyer_fde_snowflake.inapps_view
--     WHERE DATE(_ingestion_time) = '2026-05-26' AND dt IN ('2026-05-23','2026-05-26')
--     GROUP BY 1 ORDER BY 1;
--   SELECT dt, COUNT(*) AS n FROM FDE.FDE_INFO.APPSFLYER_INAPPS
--     WHERE DATE(_ingestion_time) = '2026-05-26' AND dt IN ('2026-05-23','2026-05-26')
--     GROUP BY 1 ORDER BY 1;
--
-- AFTER THIS SCRIPT:
--   cd ~/repos/fes-airflow/dags/dbt
--   source ../../.env
--   dbt run --select appsflyer_user_id appsflyer_inapps_correction \
--           --full-refresh --target prod
-- ============================================================================

BEGIN;

DELETE FROM FDE.FDE_INFO.APPSFLYER_INAPPS
WHERE DATE(_ingestion_time) = '2026-05-26'
  AND dt IN ('2026-05-23', '2026-05-26');

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
WHERE DATE(_ingestion_time) = '2026-05-26'
  AND dt IN ('2026-05-23', '2026-05-26');

COMMIT;
