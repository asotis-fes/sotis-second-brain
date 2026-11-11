-- =============================================================================
-- Loyalty Analytics Ledger — historical tenant_id backfill
-- =============================================================================
-- Purpose : Relabel historical rows for three tenants that were added to
--           cte_tenant_map in loyalty_analytics_ledger_stage.sql but whose
--           pre-fix rows are still stranded at the commerce fallback (100001).
--
--   100034  Fanatics One   site 611458   (PR #2296, merged 2026-07-21)
--   100036  myvenue        site 611466   (PR #2280, merged 2026-07-15)
--   100038  opsuite        site 611699   (PR #2280, merged 2026-07-15)
--
-- Two derived columns must change:
--   tenant_id       -> filter on site_id       (the row's own site)
--   earn_tenant_id  -> filter on earn_site_id   (the earn's site; catches
--                                                cross-site burns a site_id
--                                                filter would miss)
--
-- Persistent tables (must both be fixed):
--   LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL   (consumer source)
--   LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE         (prevents future
--                                                                re-contamination
--                                                                via earn-join)
-- LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER is table_clone -> refresh after.
--
-- Workflow: clone STAGE_FINAL -> UPDATE clone -> validate (Steps 1-3) ->
--           apply to real tables + refresh clone + drop working clone (Step 4).
--
-- Author : alex.sotis  |  Date: 2026-07-21
-- =============================================================================

USE WAREHOUSE FDE_DEVELOPER_WH;

-- =============================================================================
-- STEP 1 — Clone the authoritative table (zero-copy, instant)
-- =============================================================================
CREATE TABLE LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721
  CLONE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL;

-- =============================================================================
-- STEP 2 — Run the UPDATEs on the CLONE
-- =============================================================================
-- Reports 17,827 rows MATCHED/updated (= all target rows: 11 + 17196 + 620).
-- Of these, only ~214 actually change value (100034:11, 100036:104, 100038:99);
-- the rest are already correct and rewritten to the same value (idempotent no-op,
-- _update_ts untouched). The genuine-change count is what V2/V3 surface.
UPDATE LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034'
         WHEN 611466 THEN '100036'
         WHEN 611699 THEN '100038'
       END
 WHERE site_id IN (611458, 611466, 611699);

-- Reports 104 rows MATCHED/updated (= all earn-site rows: 18 + 50 + 36).
-- Of these, only ~86 actually change value (100034:18, 100036:40, 100038:28).
UPDATE LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034'
         WHEN 611466 THEN '100036'
         WHEN 611699 THEN '100038'
       END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- =============================================================================
-- STEP 3 — Validate the CLONE against the still-pristine live table
-- (Run while the loyalty DAG is not mid-run; the live table is untouched
--  until Step 4, so it is the correct "before" image.)
-- =============================================================================

-- NOTE ON APPROACH: full-table MINUS is too slow at ~11.9B rows. It is also
-- unnecessary — an UPDATE only writes the SET columns on rows matching WHERE,
-- so off-target rows are physically untouched. With V1 confirming no rows were
-- added/dropped, we only need to confirm the IN-SCOPE rows are correct. The
-- checks below are single-pass, few-column aggregates (no join, no shuffle).
-- Run on FDE_DEVELOPER_XL_WH for speed.

-- V1 — no rows added/dropped. EXPECT: live_rows = clone_rows
-- (PASSED: 11,928,990,626 = 11,928,990,626)
SELECT
  (SELECT COUNT(*) FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL) AS live_rows,
  (SELECT COUNT(*) FROM LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721)       AS clone_rows;

-- V2 — correctness assertion: every target row holds the correct, non-null value.
-- IS DISTINCT FROM catches both wrong values and NULLs. EXPECT: 0, 0
-- (PASSED on clone 2026-07-21: bad_tenant_rows=0, bad_earn_rows=0)
SELECT
  COUNT_IF(site_id IN (611458,611466,611699)
           AND tenant_id IS DISTINCT FROM CASE site_id
                 WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END) AS bad_tenant_rows,
  COUNT_IF(earn_site_id IN (611458,611466,611699)
           AND earn_tenant_id IS DISTINCT FROM CASE earn_site_id
                 WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END) AS bad_earn_rows
FROM LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721
WHERE site_id IN (611458,611466,611699) OR earn_site_id IN (611458,611466,611699);

-- V3 — distribution (eyeball vs expected; each site collapses to ONE value).
-- EXPECT exactly:
--   site       611458/100034/11 , 611466/100036/17196 , 611699/100038/620
--   earn_site  611458/100034/18 , 611466/100036/50    , 611699/100038/36
-- (PASSED on clone 2026-07-21: all six rows matched expected exactly)
SELECT 'site' AS dim, site_id AS k, tenant_id AS v, COUNT(*) AS n
  FROM LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721
 WHERE site_id IN (611458, 611466, 611699) GROUP BY 1, 2, 3
UNION ALL
SELECT 'earn_site', earn_site_id, earn_tenant_id, COUNT(*)
  FROM LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721
 WHERE earn_site_id IN (611458, 611466, 611699) GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- =============================================================================
-- STEP 4 — Apply to the REAL tables (only after V1-V4b pass), refresh the
--          consumer clone, and drop the working clone.
-- =============================================================================

-- 4a. _STAGE_FINAL (durable source of the consumer clone)
--     Reports matched: tenant_id 17,827 / earn_tenant_id 104
--     (genuine value changes: 214 / 86)
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- 4b. _STAGE (prevents future burns from re-deriving 100001 via the earn-join)
--     Reports matched: tenant_id 17,827 / earn_tenant_id 57 (11/23/23 — fewer
--     earn_site matches here; redeem-enrichment happens in _STAGE_FINAL)
--     (genuine value changes: 214 / 45)
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE
   SET tenant_id = CASE site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE site_id IN (611458, 611466, 611699);
UPDATE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE
   SET earn_tenant_id = CASE earn_site_id
         WHEN 611458 THEN '100034' WHEN 611466 THEN '100036' WHEN 611699 THEN '100038' END
 WHERE earn_site_id IN (611458, 611466, 611699);

-- 4c. (Optional but recommended) Re-run V2 / V3 against the two REAL tables,
--     swapping the table name, to confirm each target site collapses to one value.
--     _STAGE expected earn_site counts: 611458/100034/11, 611466/100036/23, 611699/100038/23

-- 4d. Refresh the consumer table loyalty_analytics_ledger from corrected _STAGE_FINAL.
--     Preferred (goes through dbt, applies the RESUME RECLUSTER post_hook):
--         dbt run --select loyalty_analytics_ledger
--     Manual equivalent:
CREATE OR REPLACE TABLE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER
  CLONE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER_STAGE_FINAL;

-- 4e. Drop the working clone
DROP TABLE LOYALTY.LOYALTY_CORE.LAL_STAGE_FINAL_CLONE_20260721;

-- =============================================================================
-- Notes
-- -----------------------------------------------------------------------------
-- * site_id / earn_site_id are numeric; tenant_id / earn_tenant_id are strings.
-- * UPDATEs are idempotent — rows already at the correct value are set to the
--   same value (no-op); MINUS-based validation still counts only real changes.
-- * Manual UPDATE leaves _insert_ts/_update_ts at their original values
--   (a rebuild would refresh _update_ts) — cosmetic, harmless.
-- * Downstream consumers of loyalty_analytics_ledger refresh on their next run.
--   Any downstream INCREMENTAL carrying tenant_id/earn_tenant_id would need the
--   same treatment.
-- =============================================================================
