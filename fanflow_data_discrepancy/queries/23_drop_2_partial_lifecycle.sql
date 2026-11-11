-- Step 23: Categorize drop_2 missing as completely-missing vs partial-lifecycle
-- For each missing event, check if its loyalty_txn_id appears ANYWHERE in fes_enriched
-- (different status = partial lifecycle; not found at all = completely missing)
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

WITH missing_ids AS (
    SELECT DISTINCT loyalty_txn_id FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS_DROP_2
),
fes_loyTranId_set AS (
    -- Set of all loyalty_txn_ids present in FES fes_enriched (any status)
    SELECT DISTINCT fanflow_event:a:loyTranId::STRING AS loyalty_txn_id
    FROM FANFLOW.SOURCE.fes_enriched
    WHERE fanflow_event:et::STRING = 'LOYALTY_TRANSACTION_SUCCESSFUL.ACCOUNT'
      AND TO_TIMESTAMP_NTZ((fanflow_event:ts::NUMBER/1000)::NUMBER) >= '2026-04-01 00:00:00'::TIMESTAMP_NTZ
)
SELECT
    CASE
        WHEN f.loyalty_txn_id IS NULL THEN 'completely_missing'
        ELSE 'partial_lifecycle_fes_has_different_status'
    END AS category,
    COUNT(*) AS distinct_txn_count
FROM missing_ids m
LEFT JOIN fes_loyTranId_set f ON m.loyalty_txn_id = f.loyalty_txn_id
GROUP BY 1
ORDER BY 2 DESC;
