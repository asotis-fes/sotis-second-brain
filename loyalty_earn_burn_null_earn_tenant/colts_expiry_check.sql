-- Colts bonus FanCash expiry check: was the earn issued with a 1-day or 1-year expiry?
-- Run on FAN_DATA_EXCHANGE_PROD / role FES_DATA_DEVELOPER / wh FDE_DEVELOPER_WH.
-- Result: EXPIRY_DAYS = 365 (created 2026-08-13, expires 2027-08-13) -> a 1-YEAR expiry,
-- which is why FIFO burned the older base earn first instead of this bonus.

-- A) From the FANFLOW source (system of record for the loyalty event)
SELECT loyalty_txn_id, txn_status, loyalty_txn_type, txn_amount, site_id,
       loyalty_txn_reason, creation_time, loyalty_expiration,
       datediff('day', creation_time, loyalty_expiration) AS expiry_days
FROM fanflow.account_events.loyalty_transaction_successful__account
WHERE loyalty_txn_id = '8219cc40-972c-11f1-aa88-192461234716'
  AND txn_status = 'ADD';

-- B) Same earn as it landed in the analytics ledger (confirms it matches the source)
SELECT loyalty_txn_id, txn_status, txn_amount, fancash_type, add_activity, site_id,
       creation_time, loyalty_expiration,
       datediff('day', creation_time, loyalty_expiration) AS expiry_days
FROM loyalty.loyalty_core.loyalty_analytics_ledger
WHERE loyalty_txn_id = '8219cc40-972c-11f1-aa88-192461234716'
  AND txn_status = 'ADD';

-- C) All Colts (site 612131) bonus earns, in case more get issued — check the expiry pattern
SELECT loyalty_txn_id, loyalty_account_id, txn_amount, add_activity, fancash_type,
       creation_time, loyalty_expiration,
       datediff('day', creation_time, loyalty_expiration) AS expiry_days
FROM loyalty.loyalty_core.loyalty_analytics_ledger
WHERE earn_site_id = 612131 AND txn_status = 'ADD'
  AND creation_time >= '2026-08-01'
ORDER BY creation_time DESC;
