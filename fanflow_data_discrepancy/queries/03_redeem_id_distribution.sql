-- Step 3: redeem_id distribution check
-- Confirm redeem_id is null/empty for all 664 missing events (no REDEEM statuses)
SELECT
    CASE
        WHEN redeem_id IS NULL THEN 'null'
        WHEN redeem_id = ''   THEN 'empty_string'
        ELSE 'has_value'
    END AS redeem_id_kind,
    txn_status,
    COUNT(*) AS missing_count
FROM FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS
GROUP BY 1, 2
ORDER BY 3 DESC;
