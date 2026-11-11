-- ============================================================================
-- Cross-validation query: our commerce_web_session_visitor_day vs. commerce
-- team's exp_prod.daily_visitor_activity_leading_indicators.
--
-- Run BOTH queries below and compare the result rows cell-by-cell. Same
-- column shape, same GROUP BY, same row order — diffs surface immediately.
--
-- Last anchor numbers (from the commerce team's source, 6/1-6/3 × 515620+515621)
-- are in sqllab_untitled_query_6_20260605T170123 (1).csv in this folder.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- A. Our model — COMMERCE_DEV.ORDERS.commerce_web_session_visitor_day
-- ----------------------------------------------------------------------------
SELECT
    dt,
    site_id,
    COUNT(DISTINCT CASE WHEN hp_viewed                          THEN visitor_id END) AS hp_viewed,
    COUNT(DISTINCT CASE WHEN grid_viewed                        THEN visitor_id END) AS grid_viewed,
    COUNT(DISTINCT CASE WHEN pdp_viewed                         THEN visitor_id END) AS pdp_viewed,
    COUNT(DISTINCT CASE WHEN product_page_viewed                THEN visitor_id END) AS product_page_viewed,
    COUNT(DISTINCT CASE WHEN has_pdp_to_cart_activity           THEN visitor_id END) AS has_pdp_to_cart_activity,
    COUNT(DISTINCT CASE WHEN has_product_page_to_cart_activity  THEN visitor_id END) AS has_product_page_to_cart_activity,
    COUNT(DISTINCT CASE WHEN has_cart_activity                  THEN visitor_id END) AS has_cart_activity,
    COUNT(DISTINCT CASE WHEN order_ref_num IS NOT NULL          THEN order_ref_num END) AS orders,
    COUNT(DISTINCT CASE WHEN order_ref_num IS NOT NULL          THEN visitor_id END)    AS visitors_that_ordered
FROM COMMERCE_DEV.ORDERS.commerce_web_session_visitor_day
WHERE site_id IN (515620, 515621)
  AND dt BETWEEN '2026-06-01' AND '2026-06-03'
GROUP BY dt, site_id
ORDER BY site_id, dt;


-- ----------------------------------------------------------------------------
-- B. Commerce team's reference — exp_prod.daily_visitor_activity_leading_indicators
-- ----------------------------------------------------------------------------
SELECT
    dt,
    site_id,
    COUNT(DISTINCT CASE WHEN hp_viewed                          = TRUE  THEN visitor_id END) AS hp_viewed,
    COUNT(DISTINCT CASE WHEN grid_viewed                        = TRUE  THEN visitor_id END) AS grid_viewed,
    COUNT(DISTINCT CASE WHEN pdp_view_count                     > 0     THEN visitor_id END) AS pdp_viewed,
    COUNT(DISTINCT CASE WHEN product_page_viewed                = TRUE  THEN visitor_id END) AS product_page_viewed,
    COUNT(DISTINCT CASE WHEN has_pdp_to_cart_activity           = TRUE  THEN visitor_id END) AS has_pdp_to_cart_activity,
    COUNT(DISTINCT CASE WHEN has_product_page_to_cart_activity  = TRUE  THEN visitor_id END) AS has_product_page_to_cart_activity,
    COUNT(DISTINCT CASE WHEN has_cart_activity                  = TRUE  THEN visitor_id END) AS has_cart_activity,
    COUNT(DISTINCT CASE WHEN order_ref_num IS NOT NULL                  THEN order_ref_num END) AS orders,
    COUNT(DISTINCT CASE WHEN order_ref_num IS NOT NULL                  THEN visitor_id END)    AS visitors_that_ordered
FROM exp_prod.daily_visitor_activity_leading_indicators
WHERE dt BETWEEN DATE '2026-06-01' AND DATE '2026-06-03'
  AND site_id IN (515620, 515621)
GROUP BY dt, site_id
ORDER BY site_id, dt;
