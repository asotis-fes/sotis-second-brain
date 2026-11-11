-- Step 13: Final sanity checks
-- A. Distinct loyTranIds in our 599 missing set
-- B. CDE table search by loyTranId only (regardless of status)
-- C. fes_enriched_fanapp search by loyTranId only (re-confirm)
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

-- A. Distinct loyTranIds in 599
SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT loyalty_txn_id) AS distinct_txn_ids,
    COUNT(*) - COUNT(DISTINCT loyalty_txn_id) AS rows_with_duplicated_txn_ids
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS;

-- B. CDE table search by loyTranId only
WITH missing_ids AS (
    SELECT DISTINCT loyalty_txn_id FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
)
SELECT
    cde.status,
    COUNT(*) AS rows_in_cde,
    COUNT(DISTINCT cde.loyTranId) AS distinct_txn_ids
FROM CDE.CDE_CORE.FF_LOYALTY_TRANSACTION_SUCCESSFUL_ACCOUNT cde
INNER JOIN missing_ids m
    ON cde.loyTranId::STRING = m.loyalty_txn_id
GROUP BY 1
ORDER BY 2 DESC;

-- C. fanapp topic search by loyTranId only (no et filter)
WITH missing_ids AS (
    SELECT DISTINCT loyalty_txn_id FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
)
SELECT
    fes.fanflow_event:et::STRING AS et_in_fanapp,
    fes.fanflow_event:a:status::STRING AS fanapp_status,
    COUNT(*) AS matching_rows,
    COUNT(DISTINCT fes.fanflow_event:a:loyTranId::STRING) AS distinct_matching_txn_ids
FROM FANFLOW.SOURCE.fes_enriched_fanapp fes
INNER JOIN missing_ids m
    ON fes.fanflow_event:a:loyTranId::STRING = m.loyalty_txn_id
GROUP BY 1, 2
ORDER BY 3 DESC;
