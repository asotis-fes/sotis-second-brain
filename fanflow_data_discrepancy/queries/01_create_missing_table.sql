-- Step 1: Recreate LOYALTY_MISSING_EVENTS as persistent table
-- Adds NULLIF(..., '') wrapper inside COALESCE on the join keys to treat null and empty string as equivalent
-- This is the V2 query plus the NULLIF protection Anna asked us to verify
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
fes AS (
    SELECT DISTINCT
        loyalty_account_id,
        loyalty_txn_id,
        txn_status,
        redeem_id
    FROM FANFLOW.SOURCE.loyalty_transaction_successful__account
    WHERE event_ts >= '2026-05-24 20:00:00'::TIMESTAMP_NTZ
      AND event_ts <  '2026-05-28 00:00:00'::TIMESTAMP_NTZ
)
SELECT c.*
FROM commerce c
LEFT JOIN fes f
    ON COALESCE(NULLIF(c.loyalty_account_id, ''), '∅') = COALESCE(NULLIF(f.loyalty_account_id, ''), '∅')
   AND c.loyalty_txn_id = f.loyalty_txn_id
   AND c.txn_status    = f.txn_status
   AND COALESCE(NULLIF(c.redeem_id, ''), '∅') = COALESCE(NULLIF(f.redeem_id, ''), '∅')
WHERE f.loyalty_txn_id IS NULL;

SELECT COUNT(*) AS missing_count FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS;
