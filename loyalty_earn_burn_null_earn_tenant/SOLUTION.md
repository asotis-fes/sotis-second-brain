# Solution

## Why the obvious fixes DON'T work

- **Self-healing / re-run:** won't help. The matcher already links these burns; re-running creates no `ADD` row.
- **Source backfill (Jan-incident style):** won't help. The data is **already in fanflow** (`AUTH`+`VOID_1` present, `site_id` populated). Nothing to backfill.
- The real gap is in **analytics enrichment logic**, not data completeness.

## 1. Immediate mitigation

- **No customer-facing urgency** — balances are correct; this is attribution for reporting/finance. Fix deliberately.
- **Recover the affected rows:**
  1. Patch the enrichment (see permanent fix below) to fall back to the `AUTH` row's `site_id`/`tenant_id`.
  2. Reprocess the affected window with the existing tooling:
     - `dbt-fes-ae/analysis/redeem_migration/garland.sql` → proc `generate_loyalty_redeems_ff()` (ad-hoc runnable).
     - Re-run the ledger + mapper models for the affected dates.
  3. Precedent playbook: Jan-2026 repair **ENTDATA-1893** (Megan Boyd) used
     `analysis/fanflow_backfills/loyalty_transaction_successful__account_backfill.sql` + reprocess.
- **Note:** models are guarded by `full_refresh_prevention()`. Reprocessing widens `redeem_lookback_days`
  (default `2`, `dbt_project.yml:93`) or runs the proc ad-hoc — do **not** `--full-refresh`.

## ⛔ Rejected fix — COALESCE `ADD` → `AUTH` (do NOT do this)

Originally proposed: stamp `earn_*` from the matched earn regardless of lifecycle status.
**Disproven by investigation A** (2026-08-06): the matched "earn" is a **voided authorization on the
same site/tenant as the burn** (166/169 = same 610942/100026; 41 share the burn's `order_id`). It is
**not a real earn**. Stamping from it would set `earn_tenant_id` = the burn's own tenant — a fabricated
same-opco earn. It would zero out Caroline's number while **corrupting** the cross-opco earn/burn data.

## Root cause is in the UDTF (confirmed in source)

`connect_loyalty_transactions` (`LoyaltyProcessor`, `docs/runbooks/fes-data/redeems-incident-repair.md:756-917`)
**deliberately includes voided authorizations in the earn pool** (`is_matchable_earn = earn_filter OR void_auth_filter`,
line 796). Burns connect to these void-auths and emit `REDEEM` rows with no real `ADD` earn behind them →
null `earn_tenant_id`. **These null rows are auth/void netting artifacts, not real earn→burn consumption.**

> NOTE: One Credits is a **separate loyalty program** from FanCash — NOT a parallel FanCash implementation.
> Do not treat `LOYALTY.ONE_CREDITS.*` as a source of truth for the FanCash earn-burn mapper. (Earlier draft
> wrongly proposed this + blamed the 2026-07-06 One Credits cutover for the July FanCash spike — both retracted.)

## 2. The solution (layered)

| Layer | Action | Where / Who |
|-------|--------|-------------|
| **0. Semantics decision (gates all)** | Confirm whether void-auth→burn linkages should count as "burned FanCash." They net authorization holds, not real earns. | loyalty / redeem-matching owner |
| **A. Targeted fix + replay** | Change the UDTF so void-auth linkages aren't surfaced as real earn-burns (drop `void_auth_filter` from `is_matchable_earn`, or tag the rows so the mapper excludes them). Then **replay** the affected window. | UDTF source (per runbook) → `redeem_matches.sql`; replay via `analysis/redeem_migration/garland.sql` `generate_loyalty_redeems_ff()` |
| **B. ~~Candidate: service native redeem linkage~~** | ❌ Checked — `loyalty_redeem_iceberg` is the same UDTF output (stale iceberg export), not an authoritative alternative. Dead end. | — |
| **C. DQ monitor** | Alert on NULL-`earn_tenant_id` burned-$ (MoM/threshold). | `ledger.yaml` alongside existing loyalty tests |

## On "just replay it"

Replay is **necessary but not sufficient**. The UDTF is deterministic — replaying with the current logic
reproduces the same void-auth linkages. Replay only helps *after* layer A (logic change) or B (new source).

## July timing — resolved

- Site `610942` is **authorization-only** (0 `ADD` earns, 0 `CAPTURE` burns in fanflow; only `AUTH`+`VOID_1`).
- The null "burns" are auth/void netting noise, not real burned FanCash. July void-auth *counts* are normal; the
  spike is **dollars** — a few large-value auth holds on **Jul 12–13**. No systemic change.
- Implication for the fix: the void-auth handling shouldn't emit mapper "burn" rows for auth-only activity at all.

## Candidate B (native linkage) — checked, dead end

- `loyalty_redeem_iceberg` is the iceberg export of the *same* UDTF output (5.57B rows, stale since 2026-06-29,
  0 model refs) — not an authoritative alternative linkage. Does not fix this. (If a different service source
  exists, TBD with owner.)

## Key open question (for the loyalty service / matcher owner)

> `void_auth_filter` is included in `is_matchable_earn` on purpose. What is the intended accounting behavior for
> voided authorizations, and should the resulting REDEEM rows count as burned FanCash with an earn? Answer picks
> between fix A (correct/tag the UDTF) and fix B (adopt One Credits linkage).

## Suggested next actions

- [ ] Reply to Caroline (see `caroline_reply.txt`).
- [ ] Take the open question to the loyalty / redeem-matching owner; decide A vs B.
- [ ] Add the DQ monitor (C) regardless.
- [ ] Confirm cutover→spike causation (One Credits event-mix change for tenant 100026 after 2026-07-06).
