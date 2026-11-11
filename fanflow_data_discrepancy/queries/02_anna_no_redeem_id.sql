-- Step 2: Anna's verification — run the join WITHOUT redeem_id
-- If we get 664, redeem_id was a no-op for this set and can be dropped from the join in the Confluence doc
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

WITH commerce AS (
    SELECT
        TRY_PARSE_JSON(c.a):loyActID::STRING  AS loyalty_account_id,
        TRY_PARSE_JSON(c.a):loyTranId::STRING AS loyalty_txn_id,
        TRY_PARSE_JSON(c.a):status::STRING    AS txn_status
    FROM FES_USERS.ALEX_SOTIS.INCIDENT_COMMERCE_LOYALTY_EVENTS_EXT c
    WHERE TRY_PARSE_JSON(c.a):loyTranId IS NOT NULL
),
fes AS (
    SELECT DISTINCT
        loyalty_account_id,
        loyalty_txn_id,
        txn_status
    FROM FANFLOW.SOURCE.loyalty_transaction_successful__account
    WHERE event_ts >= '2026-05-24 20:00:00'::TIMESTAMP_NTZ
      AND event_ts <  '2026-05-28 00:00:00'::TIMESTAMP_NTZ
)
SELECT COUNT(*) AS missing_without_redeem_id
FROM commerce c
LEFT JOIN fes f
    ON COALESCE(NULLIF(c.loyalty_account_id, ''), '∅') = COALESCE(NULLIF(f.loyalty_account_id, ''), '∅')
   AND c.loyalty_txn_id = f.loyalty_txn_id
   AND c.txn_status    = f.txn_status
WHERE f.loyalty_txn_id IS NULL;
