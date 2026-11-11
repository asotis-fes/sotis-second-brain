-- Sanity checks for the new-source ledger draft.
-- Run against FES_USERS.ANNA_SMITH on Anna's test data first; rerun against
-- prod-like data once the new backend lands in the loyalty source schema.

-- 1. Direction split sanity — every transaction should have a direction.
WITH txn AS (
    SELECT * FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION WHERE program_id = 3
)
SELECT
    type,
    count_if(reversed_transaction_id IS NOT NULL) AS reversed_present,
    count_if(reversed_transaction_id IS NULL) AS reversed_missing,
    count(*) AS total
FROM txn
GROUP BY type
ORDER BY type;


-- 2. Running balance reconciliation — does the cumulative running
--    (available, pending) per loyalty_id match the snapshot account_balance?
WITH ledger AS (
    -- paste/inline the ledger_v2_draft.sql body here, or query the materialized
    -- model once it's built; for a quick check, use this minimal version:
    SELECT
        loyalty_id,
        created_at,
        CASE type
            WHEN 'ADD' THEN amount
            WHEN 'AUTH' THEN -amount
            WHEN 'CAPTURE' THEN 0
            WHEN 'VOID' THEN CASE WHEN bucket_id IS NOT NULL THEN -amount ELSE amount END
        END AS avail_delta,
        CASE type
            WHEN 'AUTH' THEN amount
            WHEN 'CAPTURE' THEN -amount
            WHEN 'VOID' THEN CASE WHEN bucket_id IS NULL THEN -amount ELSE 0 END
            ELSE 0
        END AS pend_delta
    FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION
    WHERE program_id = 3
),
totals AS (
    SELECT
        loyalty_id,
        sum(avail_delta) AS computed_available,
        sum(pend_delta)  AS computed_pending
    FROM ledger
    GROUP BY loyalty_id
)
SELECT
    t.loyalty_id,
    t.computed_available,
    b.available AS snapshot_available,
    t.computed_available - b.available AS available_drift,
    t.computed_pending,
    b.pending AS snapshot_pending,
    t.computed_pending - b.pending AS pending_drift
FROM totals AS t
INNER JOIN FES_USERS.ANNA_SMITH.LOYALTY_TEST_ACCOUNT_BALANCE AS b
    ON t.loyalty_id = b.loyalty_id;


-- 3. VOID coverage — every VOID should resolve to an ADD/AUTH/CAPTURE parent.
SELECT
    v.transaction_id AS void_id,
    v.bucket_id AS void_bucket,
    v.reversed_transaction_id,
    p.type AS reversed_type
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION AS v
LEFT JOIN FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION AS p
    ON v.reversed_transaction_id = p.transaction_id
WHERE v.type = 'VOID'
ORDER BY v.created_at;


-- 4. AUTH ↔ auth_bucket_hold coverage — every AUTH should have ≥1 bucket hold row,
--    and the per-bucket hold totals should match the AUTH amount.
SELECT
    t.transaction_id AS auth_id,
    t.amount AS auth_amount,
    sum(coalesce(abh.available_balance, 0) + coalesce(abh.pending_balance, 0)) AS bucket_hold_total,
    count(abh.auth_bucket_hold_id) AS bucket_row_count
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION AS t
LEFT JOIN FES_USERS.ANNA_SMITH.LOYALTY_TEST_AUTH_BUCKET_HOLD AS abh
    ON t.transaction_id = abh.auth_transaction_id
WHERE t.type = 'AUTH'
GROUP BY t.transaction_id, t.amount
ORDER BY t.created_at;


-- 5. CAPTURE ↔ allocation coverage — every CAPTURE's amount should equal the sum
--    of its allocations against earn transactions.
SELECT
    t.transaction_id AS capture_id,
    t.amount AS capture_amount,
    sum(a.amount) AS allocated_total,
    t.amount - sum(a.amount) AS drift
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION AS t
LEFT JOIN FES_USERS.ANNA_SMITH.LOYALTY_TEST_ALLOCATION AS a
    ON t.transaction_id = a.consume_transaction_id
WHERE t.type = 'CAPTURE'
GROUP BY t.transaction_id, t.amount
ORDER BY t.created_at;
