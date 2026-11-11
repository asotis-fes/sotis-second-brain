# Diagnostic & fix queries — null `earn_tenant_id` in `loyalty_earn_burn_mapper`

Run on `FAN_DATA_EXCHANGE_PROD` / role `FES_DATA_DEVELOPER` / warehouse `FDE_DEVELOPER_WH` (Medium).
Tenant `100026` / site `610942` is the opco driving the July 2026 spike.

**Tables**
- `LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER` — the mapper (has the null `earn_tenant_id` rows). `earn_txn_id`/`redeem_txn_id` = matched earn/redeem; `tenant_id`/`site_id` = burn side.
- `LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER` — ledger; `earn_*` stamped only from `ADD` rows.
- `FANFLOW.ACCOUNT_EVENTS.LOYALTY_TRANSACTION_SUCCESSFUL__ACCOUNT` — raw fanflow txns (`loyalty_txn_type` = `ADD`/`AUTH`/`CAPTURE`).

---

## A. It is NOT a missing / late-data problem

**A1 — The null-earn burns are all *matched*, not orphaned.** If this were missing data they'd be unconnected (`earn_txn_id IS NULL`). Expected: every row is `earn_unmatched = FALSE`.
```sql
SELECT (earn_txn_id IS NULL) AS earn_unmatched,
       count(*) AS n_rows,
       sum(txn_amount) AS burned
FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01'
  AND earn_tenant_id IS NULL AND NOT is_test_txn
GROUP BY 1;
```

**A2 — The matched "earn" transactions DO exist in fanflow** (the source has them; nothing is missing). Expected: `present_in_fanflow` = `matched_earn_ids`.
```sql
WITH nulls AS (
    SELECT DISTINCT loyalty_account_id, earn_txn_id
    FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
    WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01'
      AND earn_tenant_id IS NULL AND NOT is_test_txn
      AND tenant_id = '100026' AND site_id = 610942
)
SELECT count(DISTINCT n.earn_txn_id) AS matched_earn_ids,
       count(DISTINCT CASE WHEN s.loyalty_txn_id IS NOT NULL THEN n.earn_txn_id END) AS present_in_fanflow
FROM nulls n
LEFT JOIN fanflow.account_events.loyalty_transaction_successful__account s
  ON s.loyalty_account_id = n.loyalty_account_id
 AND s.loyalty_txn_id     = n.earn_txn_id;
```

---

## B. The real cause: burns matched to *voided authorizations*

**B1 — The matched "earn" is a voided authorization, not an earn.** Expected: only `AUTH` + `VOID_1` statuses — no `ADD` (earn) and no `CAPTURE` (completed) rows. `earn_tenant_id` is stamped only from an `ADD` row, so no `ADD` ⇒ null.
```sql
WITH nulls AS (
    SELECT DISTINCT loyalty_account_id, earn_txn_id
    FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
    WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01'
      AND earn_tenant_id IS NULL AND NOT is_test_txn
      AND tenant_id = '100026' AND site_id = 610942
)
SELECT s.txn_status, s.loyalty_txn_type, count(*) AS n
FROM nulls n
JOIN fanflow.account_events.loyalty_transaction_successful__account s
  ON s.loyalty_account_id = n.loyalty_account_id
 AND s.loyalty_txn_id     = n.earn_txn_id
GROUP BY 1,2 ORDER BY n DESC;
```

**B2 — Site 610942 is authorization-only.** It never emits a real earn or a completed burn, so the "burns" the mapper reports here are pure auth/void noise. Expected: `add_earns = 0` and `captures = 0`; only auth/void activity.
```sql
SELECT count_if(loyalty_txn_type = 'ADD')                                  AS add_earns,
       count_if(loyalty_txn_type ILIKE 'CAPTURE%')                         AS captures,
       count_if(loyalty_txn_type = 'AUTH' AND txn_status = 'AUTH')         AS auths,
       count_if(loyalty_txn_type = 'AUTH' AND txn_status ILIKE 'VOID%')    AS void_auths
FROM fanflow.account_events.loyalty_transaction_successful__account
WHERE site_id = 610942
  AND creation_time >= '2026-06-01' AND creation_time < '2026-08-01';
```

**B3 — Positive control (the causal proof).** Cross the two things directly: does the matched earn have an `ADD` row, and is `earn_tenant_id` null? Expected clean split — `ADD present ⇒ earn_tenant_id populated`, `ADD absent ⇒ null`. This proves the null is caused by the missing `ADD` earn, not anything else.
```sql
WITH burns AS (
    SELECT loyalty_account_id, earn_txn_id, earn_tenant_id, txn_amount
    FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
    WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01'
      AND NOT is_test_txn AND earn_txn_id IS NOT NULL
),
add_earns AS (
    SELECT DISTINCT b.loyalty_account_id, b.earn_txn_id
    FROM burns b
    JOIN loyalty.loyalty_core.loyalty_analytics_ledger l
      ON l.loyalty_account_id = b.loyalty_account_id
     AND l.loyalty_txn_id     = b.earn_txn_id
     AND l.txn_status ILIKE 'ADD%'
)
SELECT (a.earn_txn_id IS NOT NULL) AS matched_earn_has_add_row,
       (b.earn_tenant_id IS NULL)  AS earn_tenant_id_null,
       count(*)          AS n_rows,
       sum(b.txn_amount) AS burned
FROM burns b
LEFT JOIN add_earns a
  ON a.loyalty_account_id = b.loyalty_account_id AND a.earn_txn_id = b.earn_txn_id
GROUP BY 1,2 ORDER BY 1,2;
```

---

## C. Contrast — where/when this isn't a problem

**C1 — Monthly share.** Null-earn burned $ is a tiny fraction most months (~0.3–0.4%); July jumps (~1.28%) on a few large auth holds. Shows the baseline "healthy" months vs the spike.
```sql
SELECT date_trunc('month', creation_time)::date AS month,
       sum(iff(earn_tenant_id IS NULL, txn_amount, 0)) AS null_earn_burned,
       sum(txn_amount)                                 AS total_burned,
       round(100 * sum(iff(earn_tenant_id IS NULL, txn_amount, 0)) / nullif(sum(txn_amount),0), 3) AS pct_null
FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
WHERE creation_time >= '2026-01-01' AND creation_time < '2026-08-01' AND NOT is_test_txn
GROUP BY 1 ORDER BY 1;
```

**C2 — By tenant (July).** The problem is concentrated in tenant `100026`; healthy tenants have a near-zero null-earn rate. Contrast the top row against the rest.
```sql
SELECT tenant_id,
       sum(iff(earn_tenant_id IS NULL, txn_amount, 0)) AS null_earn_burned,
       round(100 * count_if(earn_tenant_id IS NULL) / count(*), 3) AS pct_rows_null,
       count(*) AS total_rows
FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01' AND NOT is_test_txn
GROUP BY 1 ORDER BY null_earn_burned DESC;
```

---

## D. The fix — separate real burns from void-auth artifacts

**D1 — Classify the null-earn population precisely.** A row is a *void-auth artifact* when its matched earn has **no `ADD` (earn-origination) row** in the ledger; otherwise it's a real earn-burn. This is the signal the fix keys on. Expected (July): the "artifact" bucket accounts for the bulk of the null-earn $.
```sql
WITH burns AS (
    SELECT loyalty_account_id, earn_txn_id, txn_amount
    FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
    WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01'
      AND NOT is_test_txn AND earn_txn_id IS NOT NULL
),
earn_has_add AS (
    SELECT DISTINCT b.earn_txn_id
    FROM burns b
    JOIN loyalty.loyalty_core.loyalty_analytics_ledger l
      ON l.loyalty_account_id = b.loyalty_account_id
     AND l.loyalty_txn_id     = b.earn_txn_id
     AND l.txn_status ILIKE 'ADD%'
)
SELECT iff(e.earn_txn_id IS NULL, 'void-auth artifact (no ADD earn)', 'real earn-burn') AS classification,
       count(*) AS n_rows,
       sum(b.txn_amount) AS burned
FROM burns b
LEFT JOIN earn_has_add e ON e.earn_txn_id = b.earn_txn_id
GROUP BY 1 ORDER BY burned DESC;
```

**D2 — Effect of the fix (before / after).** Interim mapper-side exclusion of the void-auth artifacts. The proper/root fix is upstream — the `connect_loyalty_transactions` UDTF should not put voided authorizations in the earn pool (`is_matchable_earn = earn_filter OR void_auth_filter`) so they never become mapper "burn" rows — but this shows the reporting impact today.
```sql
SELECT 'current (includes void-auth artifacts)' AS view, sum(txn_amount) AS burned_fancash
FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01' AND NOT is_test_txn
UNION ALL
SELECT 'fixed (exclude void-auth artifacts)', sum(m.txn_amount)
FROM loyalty.loyalty_core.loyalty_earn_burn_mapper m
WHERE m.creation_time >= '2026-07-01' AND m.creation_time < '2026-08-01' AND NOT m.is_test_txn
  AND NOT (
      m.earn_tenant_id IS NULL
      AND m.earn_txn_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM loyalty.loyalty_core.loyalty_analytics_ledger l
          WHERE l.loyalty_account_id = m.loyalty_account_id
            AND l.loyalty_txn_id     = m.earn_txn_id
            AND l.txn_status ILIKE 'ADD%'
      )
  );
```

---

## E. Rule out late-arrival and a stale external (Scylla) source

**E1 — Late-arrival test.** For the null burns, do real FIFO-eligible `ADD` earns exist, and did any arrive *after* the matcher window (so the UDTF couldn't have seen them)? Expected: eligible earns exist for ~all burns, and **~0 arrived late** ⇒ not a late-data problem. `_INSERT_TS` = fanflow arrival (clean only for post-2026-06-09 rows, when that table was backfilled).
```sql
WITH burns AS (
    SELECT DISTINCT loyalty_account_id, earn_txn_id, creation_time AS burn_ct
    FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
    WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01'
      AND earn_tenant_id IS NULL AND NOT is_test_txn
      AND tenant_id='100026' AND site_id=610942
)
SELECT count(DISTINCT b.loyalty_account_id||'|'||b.earn_txn_id) AS null_burns_total,
       count(DISTINCT CASE WHEN s.loyalty_txn_id IS NOT NULL
                           THEN b.loyalty_account_id||'|'||b.earn_txn_id END) AS burns_with_any_eligible_real_earn,
       count(DISTINCT CASE WHEN s._insert_ts::timestamp_ntz > dateadd('day',2,b.burn_ct::timestamp_ntz)
                           THEN b.loyalty_account_id||'|'||b.earn_txn_id END) AS burns_with_late_eligible_real_earn
FROM burns b
LEFT JOIN fanflow.account_events.loyalty_transaction_successful__account s
  ON s.loyalty_account_id = b.loyalty_account_id
 AND s.txn_status ILIKE 'ADD%' AND s.txn_amount > 0
 AND s.creation_time      <= b.burn_ct::timestamp_ntz
 AND s.loyalty_expiration >= b.burn_ct::timestamp_ntz;
```
Result (2026-08-07): `null_burns_total = 94`, `any_eligible = 94`, `late_eligible = 0`.

**E2 — Cross-source: is the missing `ADD` hiding in the previous (Scylla) source?** Refresh the external table first (needs OWNERSHIP; use a 2XL — it's large). Then compare the matched IDs' lifecycle in Scylla vs fanflow. Expected: Scylla shows the same `AUTH`+`VOID_1`, no `ADD` ⇒ not a source/freshness gap.
```sql
-- run on FDE_DEVELOPER_2XL_WH
ALTER EXTERNAL TABLE LOYALTY.LOYALTY_STAGE.LOYALTY_TRANSACTION_RAW REFRESH;

WITH nulls AS (
    SELECT DISTINCT loyalty_account_id, earn_txn_id
    FROM loyalty.loyalty_core.loyalty_earn_burn_mapper
    WHERE creation_time >= '2026-07-01' AND creation_time < '2026-08-01'
      AND earn_tenant_id IS NULL AND NOT is_test_txn
      AND tenant_id='100026' AND site_id=610942
)
SELECT r.txn_status, r.loyalty_txn_type,
       (r.tenant_id IS NULL) AS tenant_null, (r.site_id IS NULL) AS site_null,
       count(*) AS n
FROM nulls n
JOIN loyalty.loyalty_stage.loyalty_transaction_raw r
  ON r.loyalty_account_id = n.loyalty_account_id
 AND r.loyalty_txn_id     = n.earn_txn_id
WHERE r.partition_date >= '2026-06-01'   -- prune S3 partitions
GROUP BY 1,2,3,4 ORDER BY n DESC;
```
Result (2026-08-07): refresh surfaced Scylla data through today (490M+ June+ rows); the 94 IDs show only `AUTH` + `VOID_1` (type 1), no `ADD` — same as fanflow.
