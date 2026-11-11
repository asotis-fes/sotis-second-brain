-- Step 4c: Recreate LOYALTY_MISSING_EVENTS without a FES time filter
-- This excludes the 65 boundary-effect events (which exist in FES at event_ts = 2026-05-28 00:00:00 exactly)
-- After this, the table should contain exactly 599 truly-missing events
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS AS
WITH commerce AS (
    SELECT
        TRY_PARSE_JSON(c.a):loyActID::STRING  AS loyalty_account_id,
        TRY_PARSE_JSON(c.a):loyTranId::STRING AS loyalty_txn_id,
        TRY_PARSE_JSON(c.a):status::STRING    AS txn_status,
        TRY_PARSE_JSON(c.a):redeemId::STRING  AS redeem_id,
        TO_TIMESTAMP_NTZ(REPLACE(c.ts, ' UTC', '')) AS event_ts,
        TRY_PARSE_JSON(c.a):tstTxn::STRING    AS is_test_txn,
        TRY_PARSE_JSON(c.a):isGuest::STRING   AS is_guest,
        TRY_PARSE_JSON(c.a):addType::STRING   AS add_type,
        TRY_PARSE_JSON(c.a):amount::FLOAT     AS txn_amount,
        TRY_PARSE_JSON(c.a):reason::STRING    AS txn_reason,
        TRY_PARSE_JSON(c.a):extRefId::STRING  AS external_ref_id,
        TRY_PARSE_JSON(c.a):eti::STRING       AS earn_tenant_id,
        c.st AS site_id,
        c.ti AS tenant_id,
        c.fi AS private_fan_id,
        c.ft AS tenant_fan_id,
        c.pii,
        c.a AS raw_payload,
        c.enriched_attrs AS raw_enriched_attrs
    FROM FES_USERS.ALEX_SOTIS.INCIDENT_COMMERCE_LOYALTY_EVENTS_EXT c
    WHERE TRY_PARSE_JSON(c.a):loyTranId IS NOT NULL
),
fes_all_time AS (
    -- No time filter — search the full FES silver history
    SELECT DISTINCT
        loyalty_account_id,
        loyalty_txn_id,
        txn_status
    FROM FANFLOW.SOURCE.loyalty_transaction_successful__account
)
SELECT c.*
FROM commerce c
LEFT JOIN fes_all_time f
    ON COALESCE(NULLIF(c.loyalty_account_id, ''), '∅') = COALESCE(NULLIF(f.loyalty_account_id, ''), '∅')
   AND c.loyalty_txn_id = f.loyalty_txn_id
   AND c.txn_status    = f.txn_status
WHERE f.loyalty_txn_id IS NULL;

SELECT COUNT(*) AS truly_missing_count FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS;
