-- Step 7: Export all 599 missing events to CSV
-- Run in Snowsight and use "Download as CSV" — or pipe through snow CLI with --format csv
SELECT
    event_ts,
    DATE_TRUNC('hour', event_ts) AS gap_hour_utc,
    loyalty_account_id,
    loyalty_txn_id,
    txn_status,
    redeem_id,
    txn_amount,
    txn_reason,
    external_ref_id,
    site_id,
    tenant_id,
    private_fan_id,
    tenant_fan_id,
    is_test_txn,
    is_guest,
    add_type,
    earn_tenant_id,
    pii,
    raw_payload,
    raw_enriched_attrs
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
ORDER BY event_ts, loyalty_txn_id;
