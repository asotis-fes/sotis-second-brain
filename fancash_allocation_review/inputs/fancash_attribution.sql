WITH test_accounts AS (
    SELECT DISTINCT loyalty_account_id
    FROM loyalty.loyalty_core.loyalty_analytics_ledger
    WHERE is_test_txn = 1
),

-- current balance per account, expired balances zeroed (fc_outstanding_daily logic);
-- test accounts kept and flagged instead of excluded
balances AS (
    SELECT
        b.loyalty_account_id,
        CASE
            WHEN
                b.fancash_expiration IS NOT NULL
                AND cast(b.fancash_expiration AS date) < current_date THEN 0
            ELSE coalesce(b.fancash_balance, 0)
        END AS balance,
        t.loyalty_account_id IS NOT NULL AS is_test_account
    FROM loyalty.loyalty_core.loyalty_balance AS b
    LEFT JOIN test_accounts AS t
        ON b.loyalty_account_id = t.loyalty_account_id
    QUALIFY row_number() OVER (
        PARTITION BY b.loyalty_account_id
        ORDER BY b.fancash_updated_timestamp DESC
    ) = 1
),

-- REDEEM allocation rows only exist from 2023-01-01; scope all lifecycle
-- reads to that era so earns and burns are measured over the same window
ledger AS (
    SELECT *
    FROM loyalty.loyalty_core.loyalty_analytics_ledger
    WHERE creation_time >= '2023-01-01'
),

txn_expiry AS (
    SELECT
        loyalty_account_id,
        loyalty_txn_id,
        max(loyalty_expiration) AS eff_expiry
    FROM ledger
    GROUP BY 1, 2
),

mongo_fancash AS (
    SELECT
        try_parse_json(additional_details):externalId::varchar AS external_id,
        nullif(finance_transaction_source, '') AS finance_transaction_source,
        -- Fallback jurisdiction. Bare 2-letter US codes (MI/PA/NJ/WV/NY/...),
        -- i.e. the SAME shape as the ledger's `state`, so it needs no
        -- normalisation before the US-XX mapping in the final SELECT.
        nullif(jurisdiction_code, '') AS jurisdiction_code
    FROM fbg_fde.fbg_transactions.v_fancash_mongodb
    WHERE
        try_parse_json(additional_details):externalId::varchar IS NOT NULL
        -- defensive; currently a no-op (0 deleted rows observed)
        AND NOT coalesce(is_deleted, false)
    QUALIFY row_number() OVER (
        PARTITION BY try_parse_json(additional_details):externalId::varchar
        ORDER BY fanx_modified_date DESC NULLS LAST,
                 last_raw_updated_at DESC NULLS LAST
    ) = 1
),

us_states AS (
    -- SINGLE source of truth for the 51 mapped US codes (50 states + DC).
    -- Referenced by `adds`, `fbg_account_state` and the final SELECT so the list
    -- cannot drift between them.
    SELECT column1 AS code FROM VALUES
        ('AL'),('AK'),('AZ'),('AR'),('CA'),('CO'),('CT'),('DE'),
        ('FL'),('GA'),('HI'),('ID'),('IL'),('IN'),('IA'),('KS'),
        ('KY'),('LA'),('ME'),('MD'),('MA'),('MI'),('MN'),('MS'),
        ('MO'),('MT'),('NE'),('NV'),('NH'),('NJ'),('NM'),('NY'),
        ('NC'),('ND'),('OH'),('OK'),('OR'),('PA'),('RI'),('SC'),
        ('SD'),('TN'),('TX'),('UT'),('VT'),('VA'),('WA'),('WV'),
        ('WI'),('WY'),('DC')
),

fbg_account_state AS (
    SELECT
        m.loyalty_account_id,
        -- accept fbg_state ONLY if it normalises to one of the 51 mapped US codes.
        -- fbg_state is dirty: it carries full names ('Pennsylvania', 'New Jersey'),
        -- case variants ('pa', 'Pa', 'Fl'), padded values ('PA ', ' IL') and US
        -- territories ('PR', 'VI', 'GU'). Any of those would fall through the ELSE
        -- in the final SELECT and emit BARE, e.g. "jurisdiction": "Pennsylvania".
        -- upper(trim(...)) recovers the case/whitespace variants; everything else
        -- becomes NULL so it cannot leak an unmapped value into the output.
        CASE WHEN upper(trim(fa.fbg_state)) IN (SELECT code FROM us_states)
             THEN upper(trim(fa.fbg_state)) END AS fbg_state
    FROM (
        SELECT loyalty_account_id, private_fan_id
        FROM loyalty.loyalty_info.loyalty_account_id_fan_id_map
        QUALIFY row_number() OVER (
            PARTITION BY loyalty_account_id
            ORDER BY last_modified_time DESC
        ) = 1
    ) AS m
    LEFT JOIN fangraph.private_fan_id.pfi_fbg_accounts AS fa
        ON m.private_fan_id = fa.private_fan_id
),

fmx_sites AS (
    SELECT DISTINCT site_id
    FROM fes_users.sandbox.fancash_site_tenant_mapping
    WHERE grouped_nm = 'FMX'
        -- DISTINCT above is load-bearing: a duplicate site_id would fan out the
        -- LEFT JOIN below and multiply remaining_earned.
        -- IS NOT NULL is defensive: a NULL site_id here cannot poison a LEFT JOIN
        -- the way it would poison `NOT IN (subquery)`, but it would still produce
        -- a useless row, so it is filtered at the source.
        AND site_id IS NOT NULL
),

adds AS (
    SELECT
        l.loyalty_account_id,
        l.loyalty_txn_id,
        coalesce(l.earn_tenant_id, l.tenant_id) AS earn_tenant_id,
        CASE
            -- Only tenant '100002' on site 608111 conflates the products. Verified:
            -- that is the ONLY (tenant, site) pair in the whole ledger carrying
            -- CASINO_BETTING%/SPORTS% prefixes, and tenant 100002 has six other
            -- site_ids that must keep their own identity.
            WHEN
                coalesce(l.earn_tenant_id, l.tenant_id) = '100002'
                AND coalesce(l.earn_site_id, l.site_id) = 608111
                THEN
                    CASE
                        -- Product comes SOLELY from the mongo enrichment. The old
                        -- earn_external_reference_id prefix rule has been removed
                        -- entirely — do not reintroduce it as a fallback.
                        WHEN mg.finance_transaction_source = 'ICASINO' THEN 610887
                        -- RETAIL is not present in the data today; included so a new
                        -- value cannot silently change behaviour.
                        -- ASSUMPTION: retail counts as sportsbook — confirm with business.
                        WHEN mg.finance_transaction_source IN ('INTERNET', 'RETAIL')
                            THEN 608111
                        -- Unlabelled (no mongo match, or a label we don't recognise):
                        -- leave the site_id exactly as it arrived. On 608111 that means
                        -- it continues to read as sportsbook.
                        ELSE coalesce(l.earn_site_id, l.site_id)
                    END
            ELSE coalesce(l.earn_site_id, l.site_id)
        END AS earn_site_id,
        -- CHANGED (2026-09-02): the mongo jurisdiction_code is now a FALLBACK for a
        -- missing ledger state. Order matters — the ledger stays authoritative and
        -- mongo is consulted only when `state` is NULL or ''. Nothing that already
        -- had a jurisdiction changes.
        CASE
            WHEN coalesce(l.earn_tenant_id, l.tenant_id) <> '100002' THEN 'UNKNOWN'
            -- FMX is jurisdiction-less, like every non-100002 tenant
            WHEN coalesce(l.earn_site_id, l.site_id)
                 IN (SELECT site_id FROM fmx_sites) THEN 'UNKNOWN'
            -- Each source is gated on the mapped list, so an unmapped value can never
            -- reach the output. Gating HERE rather than in the final SELECT is
            -- deliberate: it collapses unmapped values into the single 'UNKNOWN'
            -- bucket upstream. Nulling them in the final SELECT instead would leave
            -- two distinct buckets that both emit jurisdiction null on the same
            -- tenant/site -- duplicate keys within an account, breaking rule R4.
            ELSE coalesce(
                CASE WHEN upper(trim(l.state)) IN (SELECT code FROM us_states)
                     THEN upper(trim(l.state)) END,
                CASE WHEN upper(trim(mg.jurisdiction_code)) IN (SELECT code FROM us_states)
                     THEN upper(trim(mg.jurisdiction_code)) END,
                fs.fbg_state,
                'UNKNOWN')
        END AS earn_jurisdiction,
        sum(l.txn_amount) AS earned_amount
    FROM ledger AS l
    -- account-level FBG state, third fallback for jurisdiction; 1:1, cannot fan out
    LEFT JOIN fbg_account_state AS fs
        ON l.loyalty_account_id = fs.loyalty_account_id
    -- effective (per-txn) expiry gate; see the txn_expiry CTE above
    LEFT JOIN txn_expiry AS x
        ON l.loyalty_account_id = x.loyalty_account_id
        AND l.loyalty_txn_id = x.loyalty_txn_id
    -- LEFT, never INNER: ~0.1% of tenant-100002 earns and 100% of other tenants have
    -- no mongo partner. An INNER JOIN would drop them from the allocation base and
    -- silently re-weight every account's percentages.
    LEFT JOIN mongo_fancash AS mg
        ON l.earn_external_reference_id = mg.external_id
    WHERE l.txn_status = 'ADD'
        AND l.LOYALTY_TXN_REASON != 'reconcile_negative'
        -- coalesce(..., TRUE) treats a missing expiry as "never expires" so the
        -- filter can only ever drop money it is sure about. Currently a no-op:
        -- loyalty_expiration is non-NULL on all 6.1B ADD rows measured.
        AND coalesce(x.eff_expiry > current_timestamp(), TRUE)
    GROUP BY ALL
),

-- system-generated voids / clawbacks against an earn txn
adds_voided AS (
    SELECT
        loyalty_account_id,
        loyalty_txn_id,
        coalesce(earn_tenant_id, tenant_id) AS earn_tenant_id,
        coalesce(earn_site_id, site_id) AS earn_site_id,
        CASE
            WHEN coalesce(earn_tenant_id, tenant_id) <> '100002' THEN 'UNKNOWN'
            WHEN coalesce(earn_site_id, site_id)
                 IN (SELECT site_id FROM fmx_sites) THEN 'UNKNOWN'
            ELSE coalesce(nullif(state, ''), 'UNKNOWN')
        END AS earn_jurisdiction,
        sum(txn_amount) AS earn_voided_amount
    FROM ledger
    WHERE txn_status ILIKE '%VOID%'
    GROUP BY ALL
),

-- redeems roll up to the earn txn they consumed (REDEEM rows share the earn's loyalty_txn_id)
redeems AS (
    SELECT
        loyalty_account_id,
        loyalty_txn_id,
        sum(txn_amount) AS redeemed_amount
    FROM ledger
    WHERE txn_status ILIKE '%REDEEM%'
    GROUP BY ALL
),

-- unredeemed, unvoided remainder of each earn txn, floored at zero
remaining_by_earn_txn AS (
    SELECT
        a.loyalty_account_id,
        a.earn_tenant_id,
        a.earn_site_id,
        a.earn_jurisdiction,
        greatest(
            a.earned_amount
            - coalesce(av.earn_voided_amount, 0)
            - coalesce(r.redeemed_amount, 0),
            0
        ) AS remaining_amount
    FROM adds AS a
    LEFT JOIN adds_voided AS av
        ON
            a.loyalty_account_id = av.loyalty_account_id
            AND a.loyalty_txn_id = av.loyalty_txn_id
    LEFT JOIN redeems AS r
        ON
            a.loyalty_account_id = r.loyalty_account_id
            AND a.loyalty_txn_id = r.loyalty_txn_id
),

remaining_by_group AS (
    SELECT
        loyalty_account_id,
        earn_tenant_id,
        earn_site_id,
        earn_jurisdiction,
        sum(remaining_amount) AS remaining_earned
    FROM remaining_by_earn_txn
    GROUP BY ALL
    HAVING sum(remaining_amount) > 0
),

redistribution_scope AS (
    SELECT
        g.*,
        -- anti-join, NOT `NOT IN (...)`: with NOT IN, a single NULL in the subquery
        -- makes the whole predicate NULL for every row, in_scope goes NULL, the CASE
        -- below falls through to ELSE and the redistribution SILENTLY stops firing.
        g.earn_tenant_id = '100002' AND f.site_id IS NULL AS in_scope
    FROM remaining_by_group AS g
    LEFT JOIN fmx_sites AS f
        -- site_id alone is enough: the tenant '100002' guard is already applied
        -- above, and it avoids a TEXT-vs-NUMBER cast on tenant_id.
        ON g.earn_site_id = f.site_id
),

-- per account: the pool of in-scope null-jurisdiction money, and how many
-- in-scope non-null buckets are available to receive it
redistribution_basis AS (
    SELECT
        loyalty_account_id,
        sum(iff(in_scope AND earn_jurisdiction = 'UNKNOWN', remaining_earned, 0))
            AS null_pool,
        count_if(in_scope AND earn_jurisdiction <> 'UNKNOWN')
            AS n_recipients
    FROM redistribution_scope
    GROUP BY 1
),

remaining_redistributed AS (
    SELECT
        loyalty_account_id,
        earn_tenant_id,
        earn_site_id,
        earn_jurisdiction,
        remaining_earned
    FROM (
        SELECT
            s.loyalty_account_id,
            s.earn_tenant_id,
            s.earn_site_id,
            s.earn_jurisdiction,
            CASE
                -- in-scope, labelled: take an EQUAL share of the null pool
                WHEN s.in_scope
                    AND s.earn_jurisdiction <> 'UNKNOWN'
                    AND b.n_recipients > 0
                    THEN s.remaining_earned + b.null_pool / nullif(b.n_recipients, 0)
                WHEN s.in_scope
                    AND s.earn_jurisdiction = 'UNKNOWN'
                    AND b.n_recipients > 0
                    THEN 0
                -- untouched: other tenants, FMX, and in-scope null buckets on
                -- accounts with NO labelled in-scope bucket to receive the money
                -- (those keep their null bucket rather than losing the balance)
                ELSE s.remaining_earned
            END AS remaining_earned
        FROM redistribution_scope AS s
        INNER JOIN redistribution_basis AS b
            ON s.loyalty_account_id = b.loyalty_account_id
    )
    -- drops the emptied null buckets; total per account is unchanged, so
    -- ratio_to_report below still sums to 1
    WHERE remaining_earned > 0
),

allocation AS (
    SELECT
        loyalty_account_id,
        earn_tenant_id,
        earn_site_id,
        earn_jurisdiction,
        ratio_to_report(remaining_earned) OVER (
            PARTITION BY loyalty_account_id
        ) AS pct_of_balance
    FROM remaining_redistributed
),

la_to_pfi AS (
    SELECT
        loyalty_account_id,
        private_fan_id
    FROM loyalty.loyalty_info.loyalty_account_id_fan_id_map
    QUALIFY row_number() OVER (
        PARTITION BY loyalty_account_id
        ORDER BY last_modified_time DESC
    ) = 1
),

site_names AS (
    SELECT
        tenant_id,
        site_id,
        grouped_nm
    FROM fes_users.sandbox.fancash_site_tenant_mapping
),

emails AS (
    SELECT
        private_fan_id,
        final_email
    FROM fangraph.private_fan_id.pfi_customer_mart
),

final_attribution AS (
    SELECT
        m.private_fan_id,
        al.loyalty_account_id,
        e.final_email,
        b.is_test_account,
        concat_ws(
            ' / ',
            coalesce(sn.grouped_nm, 'Tenant ' || al.earn_tenant_id),
            coalesce(cast(al.earn_site_id AS varchar), 'UNKNOWN'),
            al.earn_jurisdiction
        ) AS grp,
        concat_ws(
            '_',
            al.earn_tenant_id,
            coalesce(cast(al.earn_site_id AS varchar), 'unknown'),
            lower(al.earn_jurisdiction)
        ) AS grp_key,
        concat_ws(
            '_',
            al.earn_tenant_id,
            coalesce(cast(al.earn_site_id AS varchar), 'unknown'),
            lower(al.earn_jurisdiction)
        ) || ': ' || round(al.pct_of_balance * b.balance, 2) AS grp_key_amount,
        al.earn_tenant_id,
        al.earn_site_id,
        al.earn_jurisdiction,
        round(al.pct_of_balance * b.balance, 2) AS amount,
        round(al.pct_of_balance * 100, 4) AS pct_of_balance,
        b.balance
    FROM allocation AS al
    INNER JOIN balances AS b
        ON al.loyalty_account_id = b.loyalty_account_id
    LEFT JOIN la_to_pfi AS m
        ON al.loyalty_account_id = m.loyalty_account_id
    LEFT JOIN emails AS e
        ON m.private_fan_id = e.private_fan_id
    LEFT JOIN site_names AS sn
        ON
            al.earn_tenant_id = sn.tenant_id
            AND al.earn_site_id = sn.site_id
    WHERE b.balance > 0
),

-- pct_of_balance to whole-percent (0.01) granularity on a 0-1 scale.
-- Floor every slice, then hand the leftover hundredths to the largest
-- fractional parts, so slices below ~0.5% collapse to 0.00 while each
-- account still sums to exactly 1.00.
pct_parts AS (
    SELECT
        loyalty_account_id,
        earn_tenant_id,
        earn_site_id,
        earn_jurisdiction,
        floor(pct_of_balance) AS whole_pct,
        100 - sum(floor(pct_of_balance)) OVER (
            PARTITION BY loyalty_account_id
        ) AS residual_pts,
        row_number() OVER (
            PARTITION BY loyalty_account_id
            ORDER BY
                pct_of_balance - floor(pct_of_balance) DESC,
                pct_of_balance DESC,
                earn_tenant_id,
                earn_site_id,
                earn_jurisdiction
        ) AS frac_rank
    FROM final_attribution
    WHERE (
        is_test_account = 'FALSE'
        OR loyalty_account_id IN (
            '48954a70-b9eb-11ed-9330-05d9b2b4828e'   -- deliberate test-account sample
        )
    )
),

pct_whole AS (
    SELECT
        loyalty_account_id,
        earn_tenant_id,
        earn_site_id,
        earn_jurisdiction,
        (whole_pct + iff(frac_rank <= residual_pts, 1, 0)) / 100 AS percent
    FROM pct_parts
)

SELECT
    loyalty_account_id AS loyalty_id,
    array_agg(
        -- KEEP_NULL is required: plain object_construct silently DROPS any key
        -- whose value is NULL, which would remove `jurisdiction` entirely
        -- instead of emitting "jurisdiction": null
        object_construct_keep_null(
            'tenant_id', cast(earn_tenant_id AS varchar),
            'site_id', to_varchar(cast(earn_site_id AS int)),
            'jurisdiction', CASE
                -- GUARANTEE: this column is either 'US-XX' (one of 51 values) or
                -- JSON null. Never a bare code, never a full name.
                WHEN earn_jurisdiction = 'UNKNOWN' THEN NULL
                WHEN earn_jurisdiction IN (SELECT code FROM us_states)
                    THEN 'US-' || earn_jurisdiction
                -- unreachable: `adds` already collapsed unmapped values to 'UNKNOWN'.
                -- Kept so the invariant holds even if an upstream gate is removed.
                ELSE NULL
            END,
            'percent', percent
        )
    ) WITHIN GROUP (
        ORDER BY percent DESC, earn_tenant_id, earn_site_id, earn_jurisdiction
    ) AS attribution
FROM pct_whole
WHERE percent > 0
GROUP BY loyalty_account_id
