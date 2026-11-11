-- Step 12: Search the CDE table for the 599 missing loyalty_txn_ids
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

WITH missing_ids AS (
    SELECT DISTINCT loyalty_txn_id, txn_status
    FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
)
SELECT
    COUNT(*) AS rows_in_cde_matching,
    COUNT(DISTINCT loyTranId) AS distinct_txn_ids_in_cde
FROM CDE.CDE_CORE.FF_LOYALTY_TRANSACTION_SUCCESSFUL_ACCOUNT cde
INNER JOIN missing_ids m
    ON cde.loyTranId::STRING = m.loyalty_txn_id
   AND cde.status::STRING = m.txn_status;
