-- one_credits_loyalty_analytics_ledger — DRAFT REWRITE on new backend sources
-- Revision 4: anomaly flag (no silent drops) + dedupe/incremental scaffolding.
--
-- Working assumptions (per Slack guidance + Anna's test data):
--   * Pattern A (Auth/Capture):  source emits AUTH and CAPTURE as separate rows,
--                                typically minutes apart. We emit one ledger row each.
--   * Pattern B (Redeem):        source is expected to emit this as a SINGLE row
--                                (likely a CAPTURE with no parent in capture_event,
--                                or a new type='REDEEM'). We emit one ledger row.
--                                NOTE: not represented in current test data — verify
--                                in dev.
--   * Refunds for Redeems come back as type='ADD' (not VOID-of-CAPTURE).
--   * VOID-of-AUTH and VOID-of-CAPTURE should not occur in clean data. We emit
--     them with is_anomaly=TRUE so QC can see them, but they don't contribute
--     to running balance.
--
-- Confirmed via prod query: old journal.cause vocabulary matches new transaction.type
-- exactly (ADD, VOID, AUTH, CAPTURE). cause = type is correct.
--
-- Confirmed via downstream grep: is_user_level_ledger is only used as a `= TRUE`
-- filter in two models (daily_one_credit_issuance, pfi_one_credits_daily_issuance).
-- New model has no system-bucket rows, so constant TRUE makes those filters
-- no-ops, which is semantically correct (the filtered-out class no longer exists).
--
-- DEFERRED until dev data lands:
--   * Real source YAML (currently hits FES_USERS.ANNA_SMITH directly)
--   * Pattern B detection heuristic confirmation
--   * Partial-capture handling via allocation table (no partial captures in
--     test data, so the simple amount-equality model holds for now)
--   * Authoritative available_minor / pending_minor source — currently
--     reconstructed via window sums; old model pulled from journal.metadata.balance
--
-- Output columns (parity with one_credits_loyalty_analytics_ledger):
--   loyalty_account_id, private_fan_id, journal_id, created_at, direction,
--   amount_minor, reason, cause, is_user_level_ledger, available_minor, pending_minor
-- Plus: is_anomaly (NEW — surfaces VOID-of-AUTH/CAPTURE rather than dropping)
-- Plus new-source extras: bucket_id, entry_type, campaign_code, external_id,
-- ref_id, ref_id_type, actor, site_id, tenant_id, jurisdiction, available_at,
-- expires_at, reversed_transaction_id, auth_transaction_id

WITH txn AS (
    SELECT
        transaction_id,
        program_id,
        loyalty_id,
        type,
        amount,
        bucket_id,
        entry_type,
        campaign_code,
        expires_at,
        available_at,
        external_id,
        actor,
        reason,
        site_id,
        tenant_id,
        ref_id,
        ref_id_type,
        metadata,
        jurisdiction,
        reversed_transaction_id,
        created_at
        -- TODO once new source YAML lands: add `upload_ts` (or whatever the
        -- ingest convention names it) and {{ add_incremental_timestamps() }}
    FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_TRANSACTION
    -- TODO swap to: FROM {{ source('loyalty__source_v2', 'transaction_ext') }}
    WHERE program_id = 3  -- Credits
    -- TODO once incremental:
    -- {% if is_incremental() %}
    --     AND created_at >= (SELECT max(created_at) FROM {{ this }})
    -- {% endif %}
    -- TODO once incremental and source includes upload_ts:
    -- QUALIFY row_number() OVER (
    --     PARTITION BY transaction_id
    --     ORDER BY upload_ts DESC
    -- ) = 1
),

capture_link AS (
    SELECT
        transaction_id AS capture_transaction_id,
        auth_transaction_id
    FROM FES_USERS.ANNA_SMITH.LOYALTY_TEST_CAPTURE_EVENT
    -- TODO swap to: FROM {{ source('loyalty__source_v2', 'capture_event_ext') }}
),

-- Pull reason forward from the parent AUTH onto each CAPTURE row.
-- Pattern A captures will have an auth_transaction_id; Pattern B captures will not.
captures_enriched AS (
    SELECT
        c.transaction_id,
        c.loyalty_id,
        c.type,
        c.amount,
        c.created_at,
        c.bucket_id,
        coalesce(a.reason, c.reason) AS reason,
        coalesce(a.actor, c.actor) AS actor,
        coalesce(a.entry_type, c.entry_type) AS entry_type,
        coalesce(a.campaign_code, c.campaign_code) AS campaign_code,
        coalesce(a.expires_at, c.expires_at) AS expires_at,
        coalesce(a.available_at, c.available_at) AS available_at,
        coalesce(a.external_id, c.external_id) AS external_id,
        coalesce(a.ref_id, c.ref_id) AS ref_id,
        coalesce(a.ref_id_type, c.ref_id_type) AS ref_id_type,
        coalesce(a.site_id, c.site_id) AS site_id,
        coalesce(a.tenant_id, c.tenant_id) AS tenant_id,
        coalesce(a.jurisdiction, c.jurisdiction) AS jurisdiction,
        c.reversed_transaction_id,
        cl.auth_transaction_id,
        cl.auth_transaction_id IS NULL AS is_pattern_b
    FROM txn AS c
    LEFT JOIN capture_link AS cl
        ON c.transaction_id = cl.capture_transaction_id
    LEFT JOIN txn AS a
        ON cl.auth_transaction_id = a.transaction_id
    WHERE c.type = 'CAPTURE'
),

-- Classify VOID rows by what they reverse. Per the new-API team, only
-- VOID-of-ADD is a valid ledger event in clean data; the other branches
-- get is_anomaly=TRUE.
voids_classified AS (
    SELECT
        v.*,
        r.type AS reversed_type
    FROM txn AS v
    LEFT JOIN txn AS r
        ON v.reversed_transaction_id = r.transaction_id
    WHERE v.type = 'VOID'
),

events AS (
    -- ADD (earn, including refunds-as-ADD per Pattern B)
    SELECT
        transaction_id,
        loyalty_id,
        'ADD' AS cause,
        'CREDIT' AS direction,
        amount,
        reason,
        bucket_id,
        entry_type,
        campaign_code,
        external_id,
        ref_id,
        ref_id_type,
        actor,
        site_id,
        tenant_id,
        jurisdiction,
        available_at,
        expires_at,
        reversed_transaction_id,
        NULL AS auth_transaction_id,
        created_at,
        amount  AS available_delta,
        0       AS pending_delta,
        FALSE   AS is_anomaly,
        NULL    AS anomaly_reason
    FROM txn
    WHERE type = 'ADD'

    UNION ALL

    -- AUTH (Pattern A hold — emitted separately from its CAPTURE)
    SELECT
        transaction_id,
        loyalty_id,
        'AUTH' AS cause,
        'DEBIT' AS direction,
        amount,
        reason,
        bucket_id,
        entry_type,
        campaign_code,
        external_id,
        ref_id,
        ref_id_type,
        actor,
        site_id,
        tenant_id,
        jurisdiction,
        available_at,
        expires_at,
        reversed_transaction_id,
        NULL AS auth_transaction_id,
        created_at,
        -amount AS available_delta,
        amount  AS pending_delta,
        FALSE   AS is_anomaly,
        NULL    AS anomaly_reason
    FROM txn
    WHERE type = 'AUTH'

    UNION ALL

    -- CAPTURE — Pattern A (paired w/ prior AUTH) OR Pattern B (no AUTH parent)
    SELECT
        ce.transaction_id,
        ce.loyalty_id,
        'CAPTURE' AS cause,
        'DEBIT' AS direction,
        ce.amount,
        ce.reason,
        ce.bucket_id,
        ce.entry_type,
        ce.campaign_code,
        ce.external_id,
        ce.ref_id,
        ce.ref_id_type,
        ce.actor,
        ce.site_id,
        ce.tenant_id,
        ce.jurisdiction,
        ce.available_at,
        ce.expires_at,
        ce.reversed_transaction_id,
        ce.auth_transaction_id,
        ce.created_at,
        iff(ce.is_pattern_b, -ce.amount, 0)            AS available_delta,
        iff(ce.is_pattern_b, 0,           -ce.amount)  AS pending_delta,
        FALSE   AS is_anomaly,
        NULL    AS anomaly_reason
    FROM captures_enriched AS ce

    UNION ALL

    -- VOID: split into clean VOID-of-ADD vs anomalous VOID-of-AUTH/CAPTURE.
    -- Anomalies are emitted with is_anomaly=TRUE and contribute ZERO to running
    -- balance so they don't pollute available/pending while still being visible
    -- for QC. Drop downstream via WHERE NOT is_anomaly if you need the clean view.
    SELECT
        v.transaction_id,
        v.loyalty_id,
        'VOID' AS cause,
        CASE
            WHEN v.reversed_type = 'ADD' THEN 'DEBIT'
            WHEN v.reversed_type IS NULL AND v.bucket_id IS NOT NULL THEN 'DEBIT'  -- bucket_id fallback for ADD-void
            WHEN v.reversed_type = 'AUTH' THEN 'CREDIT'   -- anomaly: would-be release of hold
            WHEN v.reversed_type = 'CAPTURE' THEN 'CREDIT' -- anomaly: would-be refund
            ELSE 'CREDIT'
        END AS direction,
        v.amount,
        v.reason,
        v.bucket_id,
        v.entry_type,
        v.campaign_code,
        v.external_id,
        v.ref_id,
        v.ref_id_type,
        v.actor,
        v.site_id,
        v.tenant_id,
        v.jurisdiction,
        v.available_at,
        v.expires_at,
        v.reversed_transaction_id,
        NULL AS auth_transaction_id,
        v.created_at,
        -- Clean VOID-of-ADD contributes to running balance; anomalies do not.
        CASE
            WHEN v.reversed_type = 'ADD' THEN -v.amount
            WHEN v.reversed_type IS NULL AND v.bucket_id IS NOT NULL THEN -v.amount
            ELSE 0
        END AS available_delta,
        0 AS pending_delta,
        CASE
            WHEN v.reversed_type = 'ADD' THEN FALSE
            WHEN v.reversed_type IS NULL AND v.bucket_id IS NOT NULL THEN FALSE
            ELSE TRUE
        END AS is_anomaly,
        CASE
            WHEN v.reversed_type = 'AUTH' THEN 'VOID_OF_AUTH_FORBIDDEN'
            WHEN v.reversed_type = 'CAPTURE' THEN 'VOID_OF_CAPTURE_FORBIDDEN'
            WHEN v.reversed_type IS NULL AND v.bucket_id IS NULL THEN 'VOID_UNCLASSIFIABLE'
            ELSE NULL
        END AS anomaly_reason
    FROM voids_classified AS v
)

SELECT
    e.loyalty_id AS loyalty_account_id,
    m.private_fan_id,
    e.transaction_id AS journal_id,
    e.created_at,
    e.direction,
    iff(e.direction = 'CREDIT', e.amount, -e.amount) AS amount_minor,
    e.reason,
    e.cause,
    TRUE AS is_user_level_ledger,
    sum(e.available_delta) OVER (
        PARTITION BY e.loyalty_id
        ORDER BY e.created_at, e.transaction_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS available_minor,
    sum(e.pending_delta) OVER (
        PARTITION BY e.loyalty_id
        ORDER BY e.created_at, e.transaction_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS pending_minor,
    e.is_anomaly,
    e.anomaly_reason,
    -- New-source extras
    e.bucket_id,
    e.entry_type,
    e.campaign_code,
    e.external_id,
    e.ref_id,
    e.ref_id_type,
    e.actor,
    e.site_id,
    e.tenant_id,
    e.jurisdiction,
    e.available_at,
    e.expires_at,
    e.reversed_transaction_id,
    e.auth_transaction_id
FROM events AS e
LEFT JOIN {{ ref('loyalty_private_fan_id_map') }} AS m
    ON e.loyalty_id = m.loyalty_account_id
