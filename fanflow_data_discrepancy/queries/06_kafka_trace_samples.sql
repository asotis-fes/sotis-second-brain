-- Step 6: Pull sample loyalty_txn_ids per anomalous hour to use in Kafka UI traces
-- One representative event per (hour, status) combo, ordered by event_ts
WITH ranked AS (
    SELECT
        DATE_TRUNC('hour', event_ts) AS gap_hour_utc,
        txn_status,
        loyalty_txn_id,
        loyalty_account_id,
        external_ref_id,
        txn_amount,
        site_id,
        tenant_id,
        event_ts,
        ROW_NUMBER() OVER (PARTITION BY DATE_TRUNC('hour', event_ts), txn_status ORDER BY event_ts) AS rn
    FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
)
SELECT
    gap_hour_utc,
    txn_status,
    loyalty_txn_id,
    loyalty_account_id,
    external_ref_id,
    txn_amount,
    site_id,
    tenant_id,
    event_ts
FROM ranked
WHERE rn = 1
ORDER BY gap_hour_utc, txn_status;
