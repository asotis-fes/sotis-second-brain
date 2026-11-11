-- Step 16: Are there events in raw S3 that did NOT make it to fes_enriched?
-- This catches dbt ingest failures (file landed in S3 but skipped by dbt model)
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

-- Compare raw S3 events to fes_enriched on (account, loyalty_txn_id, status)
-- For raw S3 events, do we find a matching event in fes_enriched?
WITH fes_enriched_keys AS (
    SELECT DISTINCT
        fanflow_event:a:loyActID::STRING  AS loyalty_account_id,
        fanflow_event:a:loyTranId::STRING AS loyalty_txn_id,
        fanflow_event:a:status::STRING    AS txn_status
    FROM FANFLOW.SOURCE.fes_enriched
    WHERE fanflow_event:et::STRING = 'LOYALTY_TRANSACTION_SUCCESSFUL.ACCOUNT'
      AND TO_TIMESTAMP_NTZ((fanflow_event:ts::NUMBER/1000)::NUMBER) >= '2026-05-26 00:00:00'::TIMESTAMP_NTZ
      AND TO_TIMESTAMP_NTZ((fanflow_event:ts::NUMBER/1000)::NUMBER) <  '2026-05-26 16:00:00'::TIMESTAMP_NTZ
)
SELECT
    COUNT_IF(f.loyalty_txn_id IS NULL) AS in_s3_but_not_in_fes_enriched,
    COUNT_IF(f.loyalty_txn_id IS NOT NULL) AS in_both,
    COUNT(*) AS total_s3_event_keys
FROM (
    SELECT DISTINCT
        COALESCE(NULLIF(loyalty_account_id, ''), '∅') AS account_norm,
        loyalty_txn_id,
        txn_status
    FROM FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS
) s
LEFT JOIN fes_enriched_keys f
    ON s.account_norm     = COALESCE(NULLIF(f.loyalty_account_id, ''), '∅')
   AND s.loyalty_txn_id  = f.loyalty_txn_id
   AND s.txn_status       = f.txn_status;
