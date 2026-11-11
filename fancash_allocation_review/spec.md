# Spec — Fancash Allocation Logic (design doc summary)

**Source:** [Fancash Allocation Logic](https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/3486875693) (space FAN, v12)
**Query:** `inputs/fancash_attribution.sql` · [repo](https://github.com/fanatics-gaming/fes-loyalty-fancash-migration-ws/blob/main/snowflake/fancash_attribution.sql)

## Core idea

Split each customer's **current FanCash balance** across the places it was earned
(tenant / site / jurisdiction). Two independent inputs, multiplied:

> **allocated = (remaining earns in bucket ÷ remaining earns across all buckets) × `fancash_balance`**

- **Left factor (the %)** comes *only* from the ledger `loyalty.loyalty_core.loyalty_analytics_ledger`.
- **Right factor ($)** comes *only* from `loyalty.loyalty_core.loyalty_balance` (source of truth for dollars).

"opco" in the framing = **tenant_id**; "product" (sportsbook vs casino) = **site_id**;
jurisdiction = **earn_jurisdiction** (US-XX or null).

## How the % is derived (Stage 1, ledger)

- `adds` — one row per `ADD` earn, tagged `earn_tenant_id` / `earn_site_id` / `earn_jurisdiction`.
  - `coalesce(earn_*, tenant/site)` fallback for unstamped rows.
  - Casino repointed 608111→610887 **only** via mongo `finance_transaction_source='ICASINO'` (no prefix rule).
  - Jurisdiction resolved: ledger `state` → mongo `jurisdiction_code` → account `fbg_state`, each gated to
    the **51 US codes** (50 states + DC); forced `UNKNOWN` off tenant 100002 and on FMX sites.
  - Excludes `reconcile_negative`; drops earns past **per-txn** effective expiry (`txn_expiry` = max per txn).
- `adds_voided` (`%VOID%`, incl. clawbacks) and `redeems` (`%REDEEM%`) key off the **same `loyalty_txn_id`**
  as the earn they reverse/consume → burn↔earn attribution without the earn/burn mapper.
- `remaining_by_earn_txn` = `greatest(earned − voided − redeemed, 0)` **per txn** (floors individually).
- `remaining_by_group` sums to (account, tenant, site, jurisdiction), keeps positive groups.
- Null-jurisdiction money on tenant 100002 off-FMX is **redistributed equally** to that account's non-null
  in-scope buckets (`redistribution_*`); null bucket emptied and dropped. Totals unchanged.
- `allocation` = `ratio_to_report(remaining_earned) OVER (PARTITION BY loyalty_account_id)` = the **%**.

## Apply % to balance (Stage 2)

- `balances` = latest `loyalty_balance` per account (`fancash_updated_timestamp DESC`), zeroed if past
  `fancash_expiration`. `amount = round(pct × balance, 2)`.

## Shape (Stage 3)

- One row per `loyalty_id`, `attribution` = `array_agg` of `object_construct_keep_null(tenant_id, site_id,
  jurisdiction, percent)`.
- **percent** on 0–1 scale, whole-percent (0.01) steps via **largest-remainder rounding**
  (floor each, hand `residual_pts = 100 − Σfloor` to largest discarded fractions). Guarantees Σ=1.00 and
  no bucket <1% (either promoted to 0.01 or dropped by `WHERE percent > 0`). **Not** a hard 1% cutoff —
  83,092 sub-1% buckets are promoted.
- `jurisdiction` = `US-XX` or JSON `null` (never bare/full name). `tenant_id`,`site_id` both VARCHAR;
  `site_id` int-cast strips `.0`.
- Test accounts excluded **except one allowlisted** (`48954a70-…`) — doc says remove before business use.

## Output contract

`{tenant_id: "100002", site_id: "608111", jurisdiction: "US-TN"|null, percent: 0.55}` — **percent only,
no dollar amount emitted**.

## Doc's self-reported numbers (2026-09-07)

4,113,989 rows · 0 dup ids · 0 accounts off Σ=1.00 · 51 jurisdictions · $41.1M allocated · 90.9% single-bucket
· sportsbook-by-default $517k (1.22%) · stranded null $10,327/129 ids. (Table 09-08 reproduces all of these.)
