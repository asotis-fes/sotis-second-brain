-- Investigation: missing field #1 — per-event balance snapshot
-- Goal: verify the gap is real and understand its shape before asking the
-- source team. Three angles:
--   A. Confirm old prod shape (what `journal.metadata.balance` actually carries)
--   B. Confirm new test data lacks it
--   C. Check whether the snapshot might live elsewhere in the new schema
--      (side tables, account_balance history, audit log, etc.) before
--      concluding the field is truly missing


-- ============================================================================
-- A. OLD PROD SHAPE — what does journal.metadata actually carry?
-- ============================================================================

-- A1. Population rate of metadata.balance per program. If it's not 100% in
--     prod, that tells us the OLD ledger is also tolerating missing values
--     and we don't need to fight as hard on the new side.
SELECT
    program_id,
    count(*) AS total_rows,
    count_if(metadata IS NULL) AS metadata_null,
    count_if(metadata IS NOT NULL AND metadata:balance IS NULL) AS metadata_no_balance_key,
    count_if(metadata:balance:available IS NOT NULL
          OR metadata:balance:available_minor IS NOT NULL) AS has_available,
    count_if(metadata:balance:pending IS NOT NULL
          OR metadata:balance:pending_minor IS NOT NULL) AS has_pending
FROM LOYALTY.SOURCE.JOURNAL
GROUP BY program_id
ORDER BY program_id;


-- A2. Distinct top-level keys in journal.metadata. Confirms `balance` is the
--     only relevant subkey (vs. some other balance-like field we missed).
SELECT DISTINCT
    f.key AS metadata_top_key,
    count(*) AS cnt
FROM LOYALTY.SOURCE.JOURNAL AS j,
    LATERAL flatten(input => j.metadata) AS f
WHERE j.program_id = 3
GROUP BY 1
ORDER BY cnt DESC;


-- A3. Distinct keys INSIDE metadata.balance. Confirms `available` / `pending`
--     (or `_minor` variants) are the only fields, vs. something like
--     `lifetime_earned` or `frozen_balance` we'd need to preserve too.
SELECT DISTINCT
    f.key AS balance_subkey,
    count(*) AS cnt
FROM LOYALTY.SOURCE.JOURNAL AS j,
    LATERAL flatten(input => j.metadata:balance) AS f
WHERE j.program_id = 3
GROUP BY 1
ORDER BY cnt DESC;


-- A4. Sanity: does the balance in metadata actually match a running sum of
--     entry.amount_minor at the journal timestamp? If yes, the OLD ledger's
--     authoritative `available_minor` and a window-sum reconstruction would
--     be equivalent in steady state (and the "we lose source truth" worry is
--     mostly about edge cases like out-of-order arrival).
--     Pick a handful of loyalty_ids with non-trivial activity.
WITH sample_users AS (
    SELECT a.loyalty_id, count(*) AS journal_count
    FROM LOYALTY.SOURCE.JOURNAL AS j
    INNER JOIN LOYALTY.SOURCE.ENTRY AS e ON j.journal_id = e.journal_id
    INNER JOIN LOYALTY.SOURCE.OPCO_PROGRAM_ACCOUNT AS a ON e.account_id = a.account_id
    LEFT JOIN LOYALTY.SOURCE.SYSTEM_LOYALTY_ACCOUNT AS s ON a.loyalty_id = s.loyalty_id
    WHERE j.program_id = 3
      AND s.loyalty_id IS NULL  -- user-level only
    GROUP BY a.loyalty_id
    HAVING count(*) BETWEEN 5 AND 20
    LIMIT 3
)
SELECT
    a.loyalty_id,
    j.journal_id,
    j.created_at,
    j.cause,
    iff(e.direction = 'CREDIT', coalesce(e.amount, e.amount_minor),
                              -coalesce(e.amount, e.amount_minor)) AS signed_amount,
    coalesce(try_to_number(j.metadata:balance.available::STRING, 18, 6),
             try_to_number(j.metadata:balance.available_minor::STRING, 18, 6))
        AS snapshot_available,
    sum(iff(e.direction = 'CREDIT', coalesce(e.amount, e.amount_minor),
                                  -coalesce(e.amount, e.amount_minor)))
        OVER (PARTITION BY a.loyalty_id ORDER BY j.created_at, j.journal_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        AS reconstructed_available,
    snapshot_available - reconstructed_available AS drift
FROM LOYALTY.SOURCE.JOURNAL AS j
INNER JOIN LOYALTY.SOURCE.ENTRY AS e ON j.journal_id = e.journal_id
INNER JOIN LOYALTY.SOURCE.OPCO_PROGRAM_ACCOUNT AS a ON e.account_id = a.account_id
INNER JOIN sample_users AS u ON a.loyalty_id = u.loyalty_id
WHERE j.program_id = 3
ORDER BY a.loyalty_id, j.created_at, j.journal_id;


-- ============================================================================
-- B. NEW TEST SHAPE — confirm metadata is genuinely empty (not just looks NULL)
-- ============================================================================

-- B1. Per-type count of NULL / empty-object metadata. `{}` and NULL look the
--     same in many tools but are different in Snowflake.
SELECT
    type,
    count(*) AS total,
    count_if(metadata IS NULL) AS truly_null,
    count_if(metadata IS NOT NULL AND metadata::TEXT = '{}') AS empty_object,
    count_if(metadata IS NOT NULL AND metadata::TEXT <> '{}') AS populated
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION
GROUP BY type
ORDER BY type;


-- B2. If any rows have populated metadata, surface them.
SELECT transaction_id, type, metadata::TEXT AS metadata_blob
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION
WHERE metadata IS NOT NULL AND metadata::TEXT <> '{}'
LIMIT 20;


-- B3. Also check the side tables — auth_hold and capture_event also have
--     metadata columns. Maybe the balance snapshot lives there in the new model.
SELECT 'auth_hold' AS tbl, type_check.*
FROM (
    SELECT
        count(*) AS total,
        count_if(metadata IS NULL) AS truly_null,
        count_if(metadata IS NOT NULL AND metadata::TEXT = '{}') AS empty_object,
        count_if(metadata IS NOT NULL AND metadata::TEXT <> '{}') AS populated
    FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_AUTH_HOLD
) AS type_check
UNION ALL
SELECT 'capture_event',
    count(*),
    count_if(metadata IS NULL),
    count_if(metadata IS NOT NULL AND metadata::TEXT = '{}'),
    count_if(metadata IS NOT NULL AND metadata::TEXT <> '{}')
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_CAPTURE_EVENT
UNION ALL
SELECT 'void_auth_event',
    count(*),
    count_if(metadata IS NULL),
    count_if(metadata IS NOT NULL AND metadata::TEXT = '{}'),
    count_if(metadata IS NOT NULL AND metadata::TEXT <> '{}')
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_VOID_AUTH_EVENT;


-- ============================================================================
-- C. CAN WE FIND THE SNAPSHOT ELSEWHERE IN THE NEW SCHEMA?
-- ============================================================================

-- C1. Per-bucket auth_bucket_hold has `available_balance` and `pending_balance`.
--     Question: are these the BUCKET's post-event balance, or just the hold's
--     own portion of the transaction? Inspect to decide whether they could
--     substitute for the journal-level snapshot.
SELECT
    abh.auth_transaction_id,
    abh.bucket_id,
    abh.available_balance AS abh_avail,
    abh.pending_balance AS abh_pend,
    t.amount AS auth_amount,
    b.available_balance AS bucket_curr_avail,
    b.pending_balance AS bucket_curr_pend
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_AUTH_BUCKET_HOLD AS abh
LEFT JOIN FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION AS t
    ON abh.auth_transaction_id = t.transaction_id
LEFT JOIN FES_USERS.ANNA_SMITH.LOYALTY_TEST_BUCKET AS b
    ON abh.bucket_id = b.bucket_id
ORDER BY abh.created_at
LIMIT 20;


-- C2. account_balance — is it a single current-state row per loyalty, or
--     does it carry history (multiple rows per loyalty over time)?
SELECT
    loyalty_id,
    count(*) AS row_count,
    min(updated_at) AS earliest,
    max(updated_at) AS latest
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_ACCOUNT_BALANCE
GROUP BY loyalty_id;


-- C3. Does the `account_balance.updated_at` line up with any
--     transaction.created_at? If yes, there might be a hidden link telling
--     us which balance row corresponds to which transaction. If no, the
--     balance table is purely a "current snapshot" and we have no per-event
--     history at all.
SELECT
    b.loyalty_id,
    b.updated_at AS balance_updated_at,
    t.transaction_id,
    t.type AS txn_type,
    t.created_at AS txn_created_at,
    datediff(second, t.created_at, b.updated_at) AS seconds_apart
FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_ACCOUNT_BALANCE AS b
LEFT JOIN FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION AS t
    ON b.loyalty_id = t.loyalty_id
   AND t.created_at <= b.updated_at
QUALIFY row_number() OVER (PARTITION BY b.loyalty_id ORDER BY t.created_at DESC) = 1
ORDER BY b.loyalty_id;


-- C4. Inspect every column on every loyalty_test_* table for anything that
--     looks like an event-level balance. (Pattern-matches names ending in
--     'balance', 'available', 'pending' that we may have missed.)
SELECT table_name, column_name, data_type
FROM FES_USERS.INFORMATION_SCHEMA.COLUMNS
WHERE table_schema = 'ANNA_SMITH'
  AND table_name LIKE 'LOYALTY_TEST_%'
  AND (column_name ILIKE '%balance%'
       OR column_name ILIKE '%available%'
       OR column_name ILIKE '%pending%'
       OR column_name ILIKE '%remaining%')
ORDER BY table_name, ordinal_position;


-- ============================================================================
-- D. WHAT TO ASK THE SOURCE TEAM
-- ============================================================================
-- Once A/B/C are run, you'll have answers to the three questions worth posing:
--
--   1. Is per-event balance available somewhere in the new schema we haven't
--      been shown (audit log, event store, balance-history table)? — answered
--      by surveying with Q4 above + asking directly.
--
--   2. If not, will the new service ADD a balance snapshot to
--      transaction.metadata (or similar), matching the old contract? — direct
--      ask.
--
--   3. If neither, downstream models that rely on `available_minor` from
--      the ledger need to know they're now reading a reconstruction. — flag
--      it as a known semantic shift, not a bug.
