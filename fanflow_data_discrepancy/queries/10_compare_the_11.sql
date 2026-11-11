-- Step 10: For the 11 found in fes_enriched but missing from bronze,
-- compare commerce vs FES side fields to see why bronze's join missed them
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

WITH missing_ids AS (
    SELECT DISTINCT loyalty_txn_id
    FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
),
fes_versions AS (
    SELECT
        fes.fanflow_event:a:loyTranId::STRING AS fes_loyalty_txn_id,
        fes.fanflow_event:a:loyActID::STRING AS fes_loyalty_account_id,
        fes.fanflow_event:a:status::STRING AS fes_txn_status,
        fes.fanflow_event:et::STRING AS fes_et,
        TO_TIMESTAMP_NTZ((fes.fanflow_event:ts::NUMBER/1000)::NUMBER) AS fes_event_ts,
        fes.pk AS fes_kafka_pk,
        fes._insert_ts AS fes_insert_ts,
        fes._update_ts AS fes_update_ts
    FROM FANFLOW.SOURCE.fes_enriched fes
    INNER JOIN missing_ids m
        ON fes.fanflow_event:a:loyTranId::STRING = m.loyalty_txn_id
)
SELECT
    m.loyalty_txn_id,
    m.txn_status AS commerce_status,
    f.fes_txn_status,
    m.loyalty_account_id AS commerce_account_id,
    f.fes_loyalty_account_id,
    f.fes_et,
    m.event_ts AS commerce_event_ts,
    f.fes_event_ts,
    f.fes_insert_ts,
    f.fes_update_ts,
    CASE
        WHEN m.txn_status != f.fes_txn_status THEN 'status_mismatch'
        WHEN COALESCE(m.loyalty_account_id, '∅') != COALESCE(f.fes_loyalty_account_id, '∅') THEN 'account_id_mismatch'
        ELSE 'fields_match_but_missing_from_bronze'
    END AS diagnosis
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS m
INNER JOIN fes_versions f ON m.loyalty_txn_id = f.fes_loyalty_txn_id
ORDER BY m.event_ts, m.loyalty_txn_id;
