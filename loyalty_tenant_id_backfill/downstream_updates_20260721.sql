-- =============================================================================
-- Loyalty tenant_id backfill — DOWNSTREAM UPDATEs
-- =============================================================================
-- Prereq: run the LEDGER updates first (tenant_id_backfill_20260721.sql Step 4:
--         _STAGE + _STAGE_FINAL). The redeem_distribution recompute (Section D)
--         re-aggregates from the CORRECTED _STAGE_FINAL, so the ledger UPDATEs
--         MUST land before Section D runs.
--
-- Propagation left to the next scheduled DAG run (per decision, no manual dbt):
--   - loyalty_analytics_ledger        (table_clone)  -> re-clones from _STAGE_FINAL
--   - loyalty_state_stage_final, loyalty_state (table) -> rebuild from state_stage
--   These carry the correction forward automatically; no UPDATE needed here.
--   loyalty_balance_monthly_snapshot  -> NO action (leave history; auto-corrects fwd).
--
-- Site -> tenant map (same as ledger): 611458->100034, 611466->100036, 611699->100038.
-- Tenant/earn_tenant are TEXT (quote literals); site_id/earn_site_id are NUMBER.
-- Run on FDE_DEVELOPER_XL_WH.
-- =============================================================================

USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- =============================================================================
-- TIER 1 — RELABELS (same verified pattern as the ledger; safe to run)
-- =============================================================================

-- --- A. loyalty_earn_burn_mapper_stage (incremental/merge) — pure relabel -----
-- Expect matched: tenant_id 14,874 ; earn_tenant_id 47
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER_STAGE
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER_STAGE
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- --- B. loyalty_earn_burn_mapper (incremental/APPEND) — pure relabel ----------
-- UPDATE-in-place is the ONLY clean fix for an append table (a rebuild/lookback
-- would duplicate rows). Expect matched: tenant_id 14,874 ; earn_tenant_id 47
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- --- C. loyalty_state_stage (incremental/merge) — label columns ---------------
-- Expect matched: tenant_id ~15,242 ; earn_tenant_id 57
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_STATE_STAGE
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_STATE_STAGE
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- =============================================================================
-- TIER 2 — state_stage redeem_distribution RECOMPUTE  *** VALIDATE FIRST ***
-- =============================================================================
-- redeem_distribution JSON embeds ECOM_REDEEM/FBG_REDEEM =
--   SUM(REDEEM txn_amount WHERE tenant_id = '100001' / '100002') per (account,txn).
-- The target-site redeems were counted as ECOM (tenant='100001'); once re-attributed
-- they must drop out. This re-aggregates from the CORRECTED _STAGE_FINAL for the
-- 14,331 affected (account,txn) groups and rebuilds the JSON exactly as the model does.
--
-- RISK: this is hand-rolled. The TO_JSON(OBJECT_CONSTRUCT(...)) numeric formatting
-- must match the model byte-for-byte. DO NOT run in prod until validated on a
-- clone against the model's own compiled output for the affected accounts.
-- (I will build that clone + parity check before this is run.)
--
-- UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_STATE_STAGE s
--    SET redeem_distribution = TO_JSON(OBJECT_CONSTRUCT(
--          'ECOM_REDEEM', r.ecom_redeem, 'FBG_REDEEM', r.fbg_redeem))
--   FROM (
--     SELECT loyalty_account_id, loyalty_txn_id,
--            SUM(IFF(STARTSWITH(txn_status,'REDEEM') AND tenant_id='100001', txn_amount, 0)) AS ecom_redeem,
--            SUM(IFF(STARTSWITH(txn_status,'REDEEM') AND tenant_id='100002', txn_amount, 0)) AS fbg_redeem
--       FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
--      WHERE (loyalty_account_id, loyalty_txn_id) IN (
--              SELECT DISTINCT loyalty_account_id, loyalty_txn_id
--                FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
--               WHERE STARTSWITH(txn_status,'REDEEM') AND site_id IN (611458,611466,611699))
--      GROUP BY 1, 2
--   ) r
--  WHERE s.loyalty_account_id = r.loyalty_account_id
--    AND s.loyalty_txn_id     = r.loyalty_txn_id;   -- expect ~14,331 groups matched

-- =============================================================================
-- VALIDATION (run per table after its UPDATEs; run on XL). EXPECT 0,0 each.
-- =============================================================================
-- Template — swap <TABLE>:
--   SELECT
--     COUNT_IF(site_id IN (611458,611466,611699)
--              AND tenant_id IS DISTINCT FROM CASE site_id
--                    WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END) AS bad_tenant,
--     COUNT_IF(earn_site_id IN (611458,611466,611699)
--              AND earn_tenant_id IS DISTINCT FROM CASE earn_site_id
--                    WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END) AS bad_earn
--   FROM LOYALTY.LOYALTY_CORE.<TABLE>
--   WHERE site_id IN (611458,611466,611699) OR earn_site_id IN (611458,611466,611699);
-- Tables: LOYALTY_EARN_BURN_MAPPER_STAGE, LOYALTY_EARN_BURN_MAPPER, LOYALTY_STATE_STAGE
