-- Step 4: Boundary check using full silver history (no time filter on FES side)
-- Do the 664 events appear anywhere in fes_enriched silver at any time?
-- If yes -> boundary issue (events did arrive in FES, just outside our compared window)
-- If no -> truly missing
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

SELECT
    COUNT_IF(f.loyalty_txn_id IS NOT NULL) AS found_in_silver_any_time,
    COUNT_IF(f.loyalty_txn_id IS NULL)     AS truly_missing
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS m
LEFT JOIN (
    SELECT DISTINCT loyalty_account_id, loyalty_txn_id, txn_status
    FROM FANFLOW.SOURCE.loyalty_transaction_successful__account
) f
    ON COALESCE(NULLIF(m.loyalty_account_id, ''), '∅') = COALESCE(NULLIF(f.loyalty_account_id, ''), '∅')
   AND m.loyalty_txn_id = f.loyalty_txn_id
   AND m.txn_status    = f.txn_status;
