# Decisions & Open Questions

> Log decisions, sign-offs, and open questions. Dates absolute.

## Established (from Slack + doc)

- **Bonus FanCash excluded from attribution** — Brian Phipps: bonus FC migrated to separate balance
  buckets in the loyalty service; attribution comes from the current system. So the allocation query
  covers **regular FanCash only** (`fancash_balance`). [Slack allocation-code thread]
- **Orphan positive-balance accounts** — accounts with a positive balance but no attributable remaining
  earns are **absent from the output entirely** (no row; the query has no null-tenant bucket). Anton
  *floated* on Slack that loyalty would default missing accounts to the FanaticsOne opco, but posed it as
  a question — **NOT confirmed**. → moved to Open Question #4. [Anton, Slack timeline thread]
- **Goodwill budget not broken out** — FBG finance doesn't need goodwill as its own bucket; migration is
  the jurisdiction + sbk/casino lumps. Goodwill/unlabelled defaults to sportsbook. [Brett, 2026-08-24]
- **Sportsbook vs casino via separate `site_id`** (casino → 610887), not a `product` key; derived from
  mongo `finance_transaction_source='ICASINO'`. [Anton/Hajime]
- **Output contract**: one row per `loyalty_id`, `attribution` array of {tenant_id, site_id, jurisdiction,
  percent(0–1)}; percent rounded to whole-% (≥0.01) via largest-remainder, sums to 1.00.
- **Delivery mechanism**: query is slow even on 3XL → data team **materializes** to
  `LOYALTY.FANCASH.ALLOCATION_<date>`; loyalty exports to
  `s3://fanatics.<env>.internal.regulated/fdsloyalty/fs_migration/attr_split` when dual-write turns on.
- **One test account deliberately allowlisted** — `48954a70-b9eb-11ed-9330-05d9b2b4828e` = Daniel
  Friedwald's employee account, kept in the output for the **canary test** loyalty wants to run with
  internal employees before opening the gate. [Anton, 2026-09-03]

## Open questions (confirm with the team)

1. **Percent vs dollars** — does loyalty-postgres `allocation` store the **percent** (service multiplies
   by live balance) or does the loader persist `percent × balance` **dollars**? The table carries percent
   only. If dollars, pin a balance-as-of date (balances drift ~2.87%/3 days). → `findings.md §🟡2`
2. **Allowlisted employee account** — keep `48954a70-…` for canary, but is it **stripped for the full
   prod backfill**? Doc says remove before quoting business numbers. → `findings.md §🔴1`
3. **Bonus net-out** — **measured: NOT exactly zero.** $1.49M unclaimed bonus (189,611 accts) stays in
   the denominator (0.43% of remaining pool), diluting the split for those accounts. Totals unaffected.
   One-line fix: `AND fancash_type='regular'` in `adds`. Accept as-is or fix? → `findings.md §🟡4`
4. **Real-money coverage gap** — 12,448 non-test accounts / ~$56.7k are **absent** from the file (ledger
   shows zero remaining despite positive balance; B+C = documented grain mismatch; ~238 are load-test).
   **What does loyalty's loader do with a positive-balance account missing from the file** — default it to
   an opco, or silently drop the balance? Unconfirmed. Also: the query de-tests **only** via `is_test_txn`,
   not reason codes — confirm load-test accounts with *remaining* aren't leaking into the output.
5. **Voided redeems** (Hajime) — a reversed redeem restoring an earn is an unhandled edge; deemed low
   impact but never quantified.

## Sign-off status

- Query was circulated for team sign-off (Brett, 2026-08-19). Doc v12 (2026-09-07) is the current
  reference. This review found **no structural data errors** in the materialized table; items above are
  confirmations, not defects.
