-- Step 4b: Investigate the 65 boundary-effect events
-- These have a Commerce ts inside our 3.5-day window but a FES event_ts outside
-- Want to understand: are they before or after our window? By how much?
USE WAREHOUSE FDE_DEVELOPER_XL_WH;

WITH fes_first_seen AS (
    SELECT
        loyalty_account_id,
        loyalty_txn_id,
        txn_status,
        MIN(event_ts) AS fes_first_event_ts
    FROM FANFLOW.SOURCE.loyalty_transaction_successful__account
    GROUP BY 1, 2, 3
)
SELECT
    DATE_TRUNC('hour', m.event_ts) AS commerce_hour_utc,
    CASE
        WHEN f.fes_first_event_ts <  '2026-05-24 20:00:00'::TIMESTAMP_NTZ THEN 'fes_before_window'
        WHEN f.fes_first_event_ts >= '2026-05-28 00:00:00'::TIMESTAMP_NTZ THEN 'fes_after_window'
        ELSE 'inside_window_unexpected'
    END AS where_fes_landed,
    COUNT(*) AS count_boundary_events,
    MIN(DATEDIFF('second', m.event_ts, f.fes_first_event_ts)) AS min_delay_sec,
    MAX(DATEDIFF('second', m.event_ts, f.fes_first_event_ts)) AS max_delay_sec,
    MIN(f.fes_first_event_ts) AS fes_earliest,
    MAX(f.fes_first_event_ts) AS fes_latest
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS m
JOIN fes_first_seen f
    ON COALESCE(NULLIF(m.loyalty_account_id, ''), '∅') = COALESCE(NULLIF(f.loyalty_account_id, ''), '∅')
   AND m.loyalty_txn_id = f.loyalty_txn_id
   AND m.txn_status    = f.txn_status
GROUP BY 1, 2
ORDER BY 1, 2;
