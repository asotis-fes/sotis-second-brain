-- =============================================================================
-- Loyalty tenant_id backfill — ALL UPDATEs (ledger + downstream)
-- Tenants/sites: 611458->100034, 611466->100036, 611699->100038
-- Run top-to-bottom (ledger before downstream). Run on FDE_DEVELOPER_XL_WH.
-- tenant/earn_tenant are TEXT (quoted); site_id/earn_site_id are NUMBER.
-- Propagation (loyalty_analytics_ledger table_clone; loyalty_state /
-- loyalty_state_stage_final tables) is left to the next scheduled DAG run.
-- loyalty_balance_monthly_snapshot: intentionally NOT touched.
-- =============================================================================

USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- ===== LEDGER: loyalty_analytics_ledger_stage_final (matched 17,827 / 104) =====
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- ===== LEDGER: loyalty_analytics_ledger_stage (matched 17,827 / 57) =====
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- ===== DOWNSTREAM: loyalty_earn_burn_mapper_stage (matched 14,874 / 47) =====
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER_STAGE
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER_STAGE
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- ===== DOWNSTREAM: loyalty_earn_burn_mapper (append) (matched 14,874 / 47) =====
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- ===== DOWNSTREAM: loyalty_state_stage — labels (matched ~15,242 / 57) =====
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_STATE_STAGE
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_STATE_STAGE
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- ===== DOWNSTREAM: loyalty_state_stage — redeem_distribution recompute =====
-- VALIDATED 2026-07-21: recompute formula matches the model's stored JSON on all
-- 14,331 affected groups (14,331/14,331 exact, 0 mismatch) — TO_JSON format + logic
-- proven faithful. Reads the CORRECTED _STAGE_FINAL, so the ledger UPDATEs above
-- MUST run first (they do, in this script's order). ~14,331 groups.
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_STATE_STAGE s
   SET redeem_distribution = TO_JSON(OBJECT_CONSTRUCT(
         'ECOM_REDEEM', r.ecom_redeem, 'FBG_REDEEM', r.fbg_redeem))
  FROM (
    SELECT loyalty_account_id, loyalty_txn_id,
           SUM(IFF(STARTSWITH(txn_status,'REDEEM') AND tenant_id='100001', txn_amount, 0)) AS ecom_redeem,
           SUM(IFF(STARTSWITH(txn_status,'REDEEM') AND tenant_id='100002', txn_amount, 0)) AS fbg_redeem
      FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
     WHERE (loyalty_account_id, loyalty_txn_id) IN (
             SELECT DISTINCT loyalty_account_id, loyalty_txn_id
               FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
              WHERE STARTSWITH(txn_status,'REDEEM') AND site_id IN (611458,611466,611699))
     GROUP BY 1, 2
  ) r
 WHERE s.loyalty_account_id = r.loyalty_account_id
   AND s.loyalty_txn_id     = r.loyalty_txn_id;
