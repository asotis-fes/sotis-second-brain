-- =============================================================================
-- Colts partnership bonus FanCash — "bonus earn shows no redeem" investigation
-- Slack: #C04HHMFHP38 (Rohan Gulati, 2026-08-13)
-- Run on FAN_DATA_EXCHANGE_PROD / role FES_DATA_DEVELOPER / wh FDE_DEVELOPER_WH (Medium)
--
-- VERDICT: NOT a source-data problem and NOT a mapper bug. FIFO working as designed —
-- the burn consumed the account's OLDER, sooner-expiring regular earn instead of the
-- newer Colts bonus, so the bonus sits unredeemed. Different root cause from the
-- null-earn_tenant_id (void-auth) issue documented in this folder.
--
-- Key entities:
--   account    = 48954a70-b9eb-11ed-9330-05d9b2b4828e  (test acct, IS_TEST_TXN=True)
--   bonus earn = 8219cc40-972c-11f1-aa88-192461234716  ($0.25, site 612131 Colts, promo/bonus)
--   FIFO chose = a51122a0-3095-11f1-9777-196befeb25ca  ($1,816 regular earn, site 608111)
-- =============================================================================

USE WAREHOUSE FDE_DEVELOPER_WH;

-- 1) The account's ledger for the day: the bonus ADD is present; the two $0.25 / $100
--    burns both redeem against a51122a0, NOT the bonus 8219cc40.
--    (bonus row: TXN_STATUS=ADD, FANCASH_TYPE=bonus, EARN_SITE_ID=612131, no matching REDEEM)
SELECT loyalty_txn_id, txn_status, loyalty_txn_type, loyalty_txn_add_type, txn_amount,
       site_id, tenant_id, earn_site_id, earn_tenant_id, fancash_type, add_activity,
       redeem_id, creation_time
FROM loyalty.loyalty_core.loyalty_analytics_ledger
WHERE loyalty_account_id = '48954a70-b9eb-11ed-9330-05d9b2b4828e'
  AND creation_time >= '2026-08-13' AND creation_time < '2026-08-14'
ORDER BY creation_time;

-- 2) NOT a source gap: the Colts bonus earn IS in fanflow (reason 'Claim bonus fancash',
--    add_type 2 = promo). It also made it into the ledger (query 1), so it's not missing.
SELECT loyalty_txn_id, txn_status, loyalty_txn_type, loyalty_txn_add_type, txn_amount,
       site_id, tenant_id, loyalty_txn_reason, redeem_id, loyalty_expiration, creation_time
FROM fanflow.account_events.loyalty_transaction_successful__account
WHERE loyalty_account_id = '48954a70-b9eb-11ed-9330-05d9b2b4828e'
  AND creation_time >= '2026-08-13' AND creation_time < '2026-08-14'
ORDER BY creation_time;

-- 3) Matcher output (loyalty_redeem): both burns tie to a51122a0, confirming the bonus
--    was not the consumed earn.
SELECT loyalty_txn_id, txn_status, txn_amount, site_id, tenant_id, redeem_id, creation_time
FROM loyalty.loyalty_core.loyalty_redeem
WHERE loyalty_account_id = '48954a70-b9eb-11ed-9330-05d9b2b4828e'
  AND creation_time >= '2026-08-13' AND creation_time < '2026-08-14'
ORDER BY creation_time;

-- 4) WHY FIFO chose a51122a0 (the smoking gun): it expires 2027-04-05, FOUR MONTHS BEFORE
--    the bonus's 2027-08-13, and had a $1,816 balance. FIFO = oldest-expiration first,
--    so it correctly drained a51122a0 before touching the newer bonus.
SELECT loyalty_txn_id, txn_status, loyalty_txn_add_type, txn_amount, fancash_type,
       site_id, tenant_id, creation_time, loyalty_expiration
FROM loyalty.loyalty_core.loyalty_analytics_ledger
WHERE loyalty_account_id = '48954a70-b9eb-11ed-9330-05d9b2b4828e'
  AND loyalty_txn_id = 'a51122a0-3095-11f1-9777-196befeb25ca'
  AND txn_status = 'ADD';
-- Result: $1,816.46, regular, created 2026-04-05, expires 2027-04-05.

-- 5) The bonus earn is genuinely unredeemed (expected, given #4). Returns 0.
SELECT count(*) AS redeems_against_bonus
FROM loyalty.loyalty_core.loyalty_analytics_ledger
WHERE loyalty_account_id = '48954a70-b9eb-11ed-9330-05d9b2b4828e'
  AND loyalty_txn_id = '8219cc40-972c-11f1-aa88-192461234716'
  AND STARTSWITH(txn_status, 'REDEEM');

-- 6) Bonus earn state: TXN_STATUS_FINAL='EARN', REDEEM_DISTRIBUTION all 0 (nothing burned
--    against it). Also note IS_TEST_TXN=True (test acct) and EARN_TENANT_ID=100001 (the
--    separate tenant-mapping bug — should be 100044).
SELECT loyalty_account_id, loyalty_txn_id, txn_status_final, txn_amount, add_activity,
       earn_creation_time, redeem_distribution, site_id, earn_site_id,
       tenant_id, earn_tenant_id, is_test_txn
FROM loyalty.loyalty_core.loyalty_state
WHERE loyalty_account_id = '48954a70-b9eb-11ed-9330-05d9b2b4828e'
  AND loyalty_txn_id = '8219cc40-972c-11f1-aa88-192461234716';

-- =============================================================================
-- SEPARATE (related) ISSUE: wrong earn_tenant_id (100001 instead of 100044)
-- Same site->tenant map-gap mechanism as the null-earn_tenant_id investigation.
-- Site 612131 is missing from the map, so the pipeline uses the commerce fallback.
-- Fix is upstream (MDM): map 612131->100044 / fix org 3431 FAN_TENANT='-999'.
-- =============================================================================

-- 7a) Site 612131 missing from the site->tenant map (0 rows => fallback to commerce 100001)
SELECT * FROM mde.mde_core.site_id_tenant_id_map WHERE site_id = 612131;

-- 7b) Root of the mapping gap: org 3431 (Indianapolis Colts) has FAN_TENANT = '-999'
SELECT org_id, org_nm, fan_tenant, org_desc
FROM commerce_mde.mde_info.org_lkp_v
WHERE org_id = 3431;

-- =============================================================================
-- HOW TO TRACK THE $1.5M COLTS BONUS (don't rely on earn_burn_mapper redemption —
-- FIFO won't attribute a burn to the bonus unless it's the soonest-expiring earn).
-- =============================================================================

-- 8a) Issuance / balance of the bonus FanCash (reliable) — populated by the loyalty_6hours job
SELECT * FROM loyalty.loyalty_info.bonus_fancash WHERE mdm_parent_site_id = 612131;

-- 8b) Remaining balance of Colts bonus earns via loyalty_state (fancash_type=bonus).
--     Track issuance vs remaining, rather than which earn a burn was attributed to.
SELECT loyalty_account_id, loyalty_txn_id, txn_status_final, txn_amount,
       earn_creation_time, loyalty_expiration, redeem_distribution, earn_tenant_id
FROM loyalty.loyalty_core.loyalty_state
WHERE earn_site_id = 612131
  AND add_activity = 'Promo earn'
ORDER BY earn_creation_time DESC;
