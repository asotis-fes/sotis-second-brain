# Findings — Data-Error Review

**Artifacts reviewed**
- Doc: [Fancash Allocation Logic](https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/3486875693) (v12) → summarized in `spec.md`
- Query: `inputs/fancash_attribution.sql` ([repo](https://github.com/fanatics-gaming/fes-loyalty-fancash-migration-ws/blob/main/snowflake/fancash_attribution.sql))
- Table: `LOYALTY.FANCASH.ALLOCATION_20260908` (materialized query output; profiled on `FDE_DEVELOPER_2XL_WH`, 2026-09-08)

Legend: 🟢 verified-ok · 🟡 concern/confirm · 🔴 fix before prod backfill

---

## Bottom line

The materialized table is **structurally clean** — every "by construction" invariant in the doc
was independently reproduced on all 4.1M rows with **zero violations**. The allocation is
**percentage-based, not dollar-based**, and coverage exclusions are **99.98% test-account
dollars (correct by design)**. Three items need a human decision before a **prod** loyalty-postgres
backfill: an allowlisted test account in the output (🔴), the percent-vs-dollar contract (🟡), a
small real-money coverage gap (🟡), and a residual bonus-FanCash denominator dilution (🟡, $1.49M / 0.43%).

---

## 🟢 Structural invariants — independently verified on the table (4,101,158 rows)

| Check | Result |
|---|---|
| Rows / distinct `loyalty_id` / dup ids | 4,101,158 / 4,101,158 / **0 dups** |
| Null `loyalty_id`, null array, empty array | **0 / 0 / 0** |
| Attribution objects total / avg / max buckets | 4,525,750 / 1.104 / 16 |
| `percent` sums to 1.00 per account (tol 1e-7) | **0 accounts off** |
| `percent` below 0.01 / ≤0 / >1 | **0 / 0 / 0** (min 0.01, max 1.00, 100 distinct values, clean 0.01 steps) |
| `tenant_id` / `site_id` null | **0 / 0** |
| `site_id` with trailing decimal (`%.%`) | **0** (int-cast strips `.0`) |
| `jurisdiction` bad format (not `US-XX`, non-null) | **0** |
| `jurisdiction` non-null on tenant ≠ 100002 | **0** |
| Duplicate `(tenant,site,jurisdiction)` within an account | **0** |
| Distinct tenants / sites / jurisdictions | 18 / 174 / **51** |

All match the doc's self-reported figures (allowing for ~0.3%/day live-table drift; doc numbers are 09-07,
table is 09-08). The 50,844 "not-whole-percent" objects flagged on a first pass were **pure IEEE-754 float
noise** — 0 violations once a tolerance is applied.

Tenant/opco distribution is sane: 100002 (FBG) 2.47M objects, 100001 (Commerce) 1.32M, 100004 646k,
100005 72k, then a long tail down to single-digit tenants. 18 tenants total.

---

## 🔴 1. Allowlisted **test account** is present in the output

The query deliberately allowlists one test account so the pipeline can be checked end-to-end:
```sql
WHERE ( is_test_account = 'FALSE'
        OR loyalty_account_id IN ('48954a70-b9eb-11ed-9330-05d9b2b4828e') )  -- deliberate test-account sample
```
**Confirmed present in the table: 1 row for `48954a70-b9eb-11ed-9330-05d9b2b4828e`.**
The doc itself warns: *"Remove the allowlist before quoting any figure as a business number."*

**Impact:** if this materialization feeds a **prod** backfill of loyalty-postgres `allocation`, a known
test account is written as a real customer allocation. Dollars are trivial, but it's a test row in prod.
**Action:** strip the allowlist (make it `is_test_account = 'FALSE'` only) for the production run, or
delete that `loyalty_id` from the load set.

## 🟡 2. Table carries **percentages, not dollars**

Output contract is `{tenant_id, site_id, jurisdiction, percent}` where `percent` is 0–1. **There is no
dollar amount in the table.** The dollar split (`round(pct × fancash_balance, 2)`) is computed inside the
query (`final_attribution.amount`) but **not emitted**. The framing for this project was a *"lump sum of
unburned FanCash by customer."* — that's dollars.
**Confirm the backfill contract:** does loyalty-postgres `allocation` store the **percent** (and the
service multiplies by the live balance at read time), or does the loader apply `percent × balance` and
store **dollars**? If dollars, note the balance drifts (doc: query differed −2.87% on dollars over 3 days),
so the load must pin a balance-as-of date. Percent is the more stable thing to persist.

## 🟡 3. Small **real-money coverage gap** (balance-vs-ledger grain mismatch)

Accounts with a **positive `fancash_balance` but no allocation row**, decomposed:

| segment | accounts | dollars | verdict |
|---|---|---|---|
| **Test accounts** (excluded by design) | 36,979 | **$291,455,361.38** | 🟢 correct — this is the $291M "missing" |
| Non-test, has ledger earns, all consumed → `remaining_earned=0` | 12,442 | $56,084.27 | 🟡 real customers, no allocation |
| Non-test, **no** ADD rows since 2023 | 6 | $575.70 | 🟡 edge (pre-2023 / migration balance) |

So of the $335.4M positive-balance pool, **$291.46M is test money (correctly excluded)**, and only
**~$56,660 across 12,448 real customers (avg ~$4.55)** is dropped because the ledger shows zero remaining
earns despite a positive balance. **These accounts are entirely ABSENT from the output** — not a null-tenant
row (the output never has a null `tenant_id`); they have no row at all. What happens to a positive-balance
account missing from the file is **loyalty-side ingestion behavior, not handled by this query**. Anton
floated in Slack that missing accounts "will be attributed to fanatics one opco," but posed it as a
question and it was **not explicitly confirmed** in-thread — so treat it as an **open question**: confirm
loyalty's loader assigns these to a default opco rather than silently dropping ~$56.7k of real balance.

**Why the 12,448 drop, by reason** (query in `inputs/` / progress log; reproduces the pipeline's drop logic):

| Reason | Accts | Dollars | Responsible filter |
|---|---|---|---|
| C — remaining killed by **per-txn expiry gate** | 6,771 | $23,675.57 | `coalesce(x.eff_expiry > current_timestamp(), TRUE)` (L188) |
| B — **fully consumed** (redeem/void) since 2023 | 4,946 | $21,058.68 | `HAVING sum(remaining_amount) > 0` (L255) |
| D — should-appear (**snapshot drift, confirmed**) | 725 | $11,350.03 | none — see below |
| A2 — 2023+ rows, no ADD | 6 | $575.70 | `WHERE txn_status='ADD'` (L183) |

B+C ($44.7k, 94%) = the documented *balance-vs-ledger grain mismatch*. The `ledger` CTE's
**`creation_time >= '2023-01-01'`** scope (L33) compounds C/A2 (pre-2023 earns are invisible).

**Drift proof for D (confirmed 2026-09-08):** table `ALLOCATION_20260908` was built at **16:26 UTC**
(altered 16:42); the query runs for hours on a consistent read-snapshot (as of query *start*). **722 of
725 D accounts (99.6%) had their earn TODAY** — i.e. after the snapshot start, so they legitimately aren't
in the committed table and self-heal on the next run. By contrast only **28 of 11,717 B+C accounts (0.24%)**
earned today; their activity spans 2025-09→2026-08 (genuinely old). So D is **not a defect**.

**Materiality:** largest genuinely-dropped (non-drift) account is **$554**; no whales, money is small and
dispersed (avg ~$4.55). Full per-account list (12,448 ids + evidence) → `inputs/missing_accounts.csv`.

**Test-classification caveat (real):** these are "non-test" *only by the query's own `is_test_txn=1`
definition* (L1-5). A second signal — Anton's Slack `LOAD_TEST%` / `%-api%` reason codes — flags **238 of
the 12,448** as perf/load-test the flag misses. So the truly-real dropped set is ~12,210 accts. Broader
point: **the query de-tests solely via `is_test_txn`**, so load-test accounts flagged only by reason code
are not excluded by that mechanism — confirm that's intended (matters for accounts that *do* have
remaining and thus land in the output, not just these dropped ones).

Reconciliation sanity: non-test positive balance ≈ $335.4M − $291.46M = **$43.96M**, minus the $56.7k gap
≈ **$43.9M** attributable — consistent with the doc's ~$41.1M allocated (09-07) after drift + rounding. ✓

---

## 🟡 4. Bonus FanCash net-out — mostly, but not exactly, zero

Brett's AI review flagged that the query includes **both** regular and bonus `ADD` rows in the
attribution denominator, while the dollar side (`fancash_balance`) is **regular-only**. The team's
resolution was "bonus ADD + bonus REDEEM cancel out" (claimed bonus converts to regular). The final
query has **no `fancash_type` filter** in the `adds` CTE, relying on that net-out.

**Measured (2026-09-08, positive-balance accounts, per-txn remaining floored at 0):**

| fancash_type | remaining $ in denominator | accounts w/ positive bonus remaining |
|---|---|---|
| regular | $347,615,007.90 | 4,119,251 |
| **bonus** | **$1,486,532.51** | **189,611** |

The net-out holds for ~99.6% of bonus, but **$1.49M of unclaimed bonus remains** in the denominator
(bonus that's been ADDed but not yet claimed/redeemed → lives in `bonus_fancash`, which the numerator
excludes). Effect: a **split-level dilution** — for the ~190k affected accounts, bonus inflates their
FBG-earned buckets, shifting a few percent of the *regular* balance toward those buckets. **Totals are
unaffected** (percentages still sum to 1 × `fancash_balance`), so no customer sees a wrong total — only a
slightly-wrong split. Population impact is 0.43% of the remaining pool; per-affected-account it's ~$7.84
of misweighted remaining on average (low-single-digit % of their split).

**Fix if the business wants it exact:** add `AND fancash_type = 'regular'` (or exclude bonus) to the
`adds` CTE — one line, removes the dilution entirely. Given the doc already tolerates larger weight-vs-
balance disagreements (99% within $28.65), this is likely acceptable as-is, but it **is** a real residual
of the flagged issue, not a fully-closed one. Worth a conscious call rather than silent reliance on
"cancel out."

## Accepted design tradeoffs (from the doc — not errors, but business should be aware)

- **Sportsbook-by-default**: unlabelled/`GOODWILL` earns on (100002, 608111) read as sportsbook.
  $517,315 = 1.22% of allocation. The doc's Real Example 3 shows a single account where 66% of a bucket
  is unlabelled goodwill counted as sportsbook.
- **Largest-remainder rounding, not a hard 1% cutoff**: 83,092 sub-1% buckets are *promoted* to 0.01
  rather than dropped. If the business wants "drop everything <1% and renormalize survivors," the current
  logic does **not** do that — flag noted in the doc.
- **Jurisdiction stranded null**: $10,327 / 129 ids on FBG off-FMX stay null (goodwill/manual credit with
  no geolocated jurisdiction). Reallocation only fires for 25 accounts / $1,450.

## What I did NOT do

- Did not re-run the query (used the materialized table per instruction).
- Did not diff the table against a fresh query run (drift makes this noisy; construction rules verified instead).
- Slack channel `C0BPV01HBKL` review — see `slack_thread.md`.
