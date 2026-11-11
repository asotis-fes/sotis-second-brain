# Slack — #project-fancash-migration

**Channel:** [#project-fancash-migration](https://betfanatics.enterprise.slack.com/archives/C0BPV01HBKL) (`C0BPV01HBKL`)

Catch-up of the allocation-query discussion, mapping each raised concern → whether the **latest**
query (`inputs/fancash_attribution.sql`, materialized as `ALLOCATION_20260908`) closes it. Most
comments are from mid/late-Aug against an **earlier, simpler** version of the query; the current query
has evolved substantially since.

## The two query versions

- **v1** — Rohan's original ([thread, 08-17](https://betfanatics.enterprise.slack.com/archives/C0BPV01HBKL/p1787009144238039)):
  no mongo product split, no jurisdiction fallback/gating, no VOID handling, no per-txn expiry, no
  redistribution, output = flat columns. This is what most of the AI-flagged "critical issues" were against.
- **latest** — the reviewed query: adds mongo sportsbook/casino split (site 610887), jurisdiction
  coalesce (ledger→mongo→fbg_state) gated to 51 US codes, VOID/clawback subtraction, per-txn expiry gate,
  null-jurisdiction redistribution, largest-remainder rounding, JSON `attribution` array output.

## Open questions raised → status in the latest query

| # | Raised by | Concern | Status in latest query |
|---|---|---|---|
| 1 | Brett (AI review) | **Bonus FanCash** included in denominator but excluded from balance → dilutes % / drops bonus-only accts | **Verified separately** — see `findings.md` §Bonus. Brian: bonus handled in-service, no attribution needed; rationale is bonus ADD+REDEEM net out. Bonus-only accts dropped by `balance>0` (intended). |
| 2 | Brett (AI review) | **Positive-balance accts with no remaining earns silently dropped** | ⚠️ **Partly open**: these accts are simply ABSENT from the output (no row). Anton *floated* that missing accounts default to the FanaticsOne opco on loyalty's side but posed it as a question — **not confirmed**. My check: 12,448 real accts / ~$56.7k (~238 are actually load-test; rest is grain mismatch). Confirm loyalty's loader defaults vs. drops them. |
| 3 | Brett (AI review) | **$167.6M / 3.3% of ADDs no jurisdiction** | ✅ Fixed — mongo `jurisdiction_code` + `pfi_fbg_accounts.fbg_state` fallbacks brought FBG null-jurisdiction down to ~$10K/129 ids. |
| 4 | Hajime | **Voided redeems** — should a reversed redeem restore the earn? | ⚠️ Partially — latest query subtracts `%VOID%` via `adds_voided` (clawbacks). A voided *redeem* is an edge; deemed "likely small impact." Not independently quantified. |
| 5 | Andrew Stehman | `pct_of_balance` doesn't always sum to 100% | ✅ Fixed — largest-remainder rounding guarantees Σ=1.00. Verified 0 accounts off. |
| 6 | Anton / Andrew | Format: same-type tenant/site, `US-NY`, percent 0–1, unique loyalty_id, ≥1% rounding, null (not UNKNOWN), sbk/casino via separate site_id (610887) | ✅ **All done & verified** on the table (see `findings.md` invariants table). |
| 7 | Megan / Brian | Test txns can sit on non-test (employee) accounts | ✅ Handled — account flagged test if it has *any* `is_test_txn=1` row; excluded, **except** Daniel Friedwald's employee acct deliberately allowlisted (see #8). |
| 8 | Anton (09-03 canary thread) | Canary needs 1–2 **non-test internal employee** accounts present in the split file | ✅ **This explains the allowlist** — `48954a70-…` = Daniel Friedwald's account, intentionally kept for the canary test. ⚠️ Doc still says remove before the full prod backfill / before quoting business numbers → confirm the plan (keep for canary, strip for full run). |
| — | Megan | Sandbox source table, ledger self-join cost, incremental | N/A — Brett clarified this is a **one-time migration query**, not a daily model; perf/design comments moot. |
| — | Rohan (08-17) | Triage process for customer-balance issues during migration | Process question, not a query defect. |

## Other relevant decisions in-thread

- **Goodwill allocation budget not needed** ([thread, 08-24](https://betfanatics.enterprise.slack.com/archives/C0BPV01HBKL/p1787590838715419)):
  Brett confirmed FBG finance doesn't need the goodwill budget broken out — migration is just the
  jurisdiction + sbk/casino lumps. (Consistent with goodwill defaulting to sportsbook in the query.)
- **~90% of tenant-100002 earn dollars** have a reference_id that's neither CASINO nor SPORTS (promos/
  appeasements/goodwill) → **default to sportsbook**. Called out by Hajime; matches doc's $517K/1.22%.
- **Data-latency mismatch** (Rohan's opening Q): if the service balance differs from the split due to
  latency, how is it handled? → loyalty applies percent × *their* live balance; the percent is what's
  persisted. Ties to `findings.md` §Percent-vs-dollar.
- **Delivery**: query ready; Hajime materializes to `LOYALTY.FANCASH.ALLOCATION_<date>`; loyalty exports
  to `s3://fanatics.<env>.internal.regulated/fdsloyalty/fs_migration/attr_split`. Runs when loyalty turns
  on dual-write. Query is slow even on 3XL → materialize-and-share pattern (Anton/Andrew lack compute).

## Bottom line for the user

The thread's substantive concerns **are** addressed in the latest query — format, sum-to-1, jurisdiction
coverage, sbk/casino split, orphan-balance default all resolved. Two things to actively confirm rather
than assume: **(a)** the allowlisted employee account (#8) is intentional for canary but must be stripped
for the full prod backfill, and **(b)** the bonus-FanCash net-out (#1) — quantified in `findings.md`.
