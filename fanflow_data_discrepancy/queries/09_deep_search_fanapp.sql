-- Step 9: Deep search the fanapp topic (no time filter, no et filter)
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

WITH missing_ids AS (
    SELECT DISTINCT loyalty_txn_id
    FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
)
SELECT
    fes.fanflow_event:et::STRING AS et_in_fes,
    COUNT(DISTINCT fes.fanflow_event:a:loyTranId::STRING) AS distinct_matching_txn_ids,
    COUNT(*) AS matching_rows
FROM FANFLOW.SOURCE.fes_enriched_fanapp fes
INNER JOIN missing_ids m
    ON fes.fanflow_event:a:loyTranId::STRING = m.loyalty_txn_id
GROUP BY 1
ORDER BY 2 DESC;
