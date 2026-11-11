-- Step 8: Deep search — do the 599 missing loyalty_txn_ids exist in fes_enriched (raw) at all?
-- If yes, what `et` value do they have? Could be a casing/whitespace variant that bronze's WHERE excluded.
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

WITH missing_ids AS (
    SELECT DISTINCT loyalty_txn_id
    FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
)
SELECT
    fes.fanflow_event:et::STRING AS et_in_fes,
    COUNT(DISTINCT fes.fanflow_event:a:loyTranId::STRING) AS distinct_matching_txn_ids,
    COUNT(*) AS matching_rows,
    MIN(TO_TIMESTAMP_NTZ((fes.fanflow_event:ts::NUMBER/1000)::NUMBER)) AS earliest_event_ts,
    MAX(TO_TIMESTAMP_NTZ((fes.fanflow_event:ts::NUMBER/1000)::NUMBER)) AS latest_event_ts
FROM FANFLOW.SOURCE.fes_enriched fes
INNER JOIN missing_ids m
    ON fes.fanflow_event:a:loyTranId::STRING = m.loyalty_txn_id
GROUP BY 1
ORDER BY 2 DESC;
