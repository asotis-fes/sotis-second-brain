# Loyalty Earn-Burn Mapper — NULL `earn_tenant_id` on burns

**Status:** Root-caused & confirmed (2026-08-06). Fix is upstream (matcher), not analytics. Needs loyalty-service owner.
**Reporter:** Caroline Wylie (Slack, 2026-08-05) · **Owner:** Alex Sotis
**Team:** Data Engineering Integrations · **Impact:** analytics/finance attribution only — **customer balances NOT affected**

## The question

Burned FanCash with a NULL `earn_tenant_id` in `loyalty.loyalty_core.loyalty_earn_burn_mapper` sat at
~$200–280k/month since January, then jumped to **$692k in July 2026**. Why?

## One-paragraph answer

The July spike is **one opco** — tenant `100026` / site `610942` = **$372k of $692k (54%)**, 169 burns,
19 accounts, concentrated **Jul 12–14**. These burns *are* FIFO-matched to an earn (not orphaned), but the
matched "earn" is a **voided authorization** (`AUTH`→`VOID_1`, no `ADD`) in fanflow. `earn_tenant_id`/`earn_site_id`
are stamped **only from an earn's `ADD` row** (`loyalty_analytics_ledger_stage.sql:451-456`), so with no `ADD`
row the attribution is NULL — even though the `site_id` exists on the `AUTH` row. It is **not** missing/late data
and **not** a repeat of the Jan-2026 missed-redeems incident.

## Files in this folder

| File | Contents |
|------|----------|
| [`SOLUTION.md`](SOLUTION.md) | Immediate mitigation + permanent patch options |
| [`DISCOVERIES.md`](DISCOVERIES.md) | Confirmed findings + hypotheses ruled out (with evidence) |
| [`REFERENCES.md`](REFERENCES.md) | Slack/Confluence/Jira links, model paths, diagnostic queries |
| [`QUERIES.md`](QUERIES.md) | Runnable SQL: rule out missing-data, show the void-auth cause, contrast, and the fix |
| [`colts_bonus_fifo.sql`](colts_bonus_fifo.sql) | Related but distinct: Colts bonus earn shows no redeem — FIFO consumed an older earn (by design), not a bug/source gap |

## TL;DR for the next session

- Null `earn_tenant_id` ≠ "unconnected burn." Here it means **the matched "earn" has no `ADD` row** — it's a voided authorization on the burn's own site/tenant, not a real earn.
- Enrichment is `ADD`-only (`IFF(STARTSWITH(txn_status,'ADD'), …, NULL)`) — that's why it's null, but the deeper cause is the matcher linking burns to voided auths.
- **Do NOT "fix" this by stamping from the AUTH row** — that fabricates `earn_tenant_id` = burn tenant. See `SOLUTION.md` rejected-fix note.
- Real fix is upstream in the FIFO matcher (`connect_loyalty_transactions`); needs the loyalty-service owner. Same mechanism across all months (confirmed via May baseline).
- UDTF **deliberately** puts voided authorizations in the earn pool (`is_matchable_earn`, runbook `redeems-incident-repair.md:796`) → burns link to void-auths → null attribution. These rows are auth/void netting artifacts, not real burns.
- Replay alone ≠ fix (UDTF is deterministic). Fix the void-auth logic first, then replay.
- **One Credits is a SEPARATE loyalty program — not a FanCash source.** (Earlier draft wrongly used it; retracted. See `DISCOVERIES.md`.)
- `loyalty_redeem_iceberg` checked as a "native linkage" source → dead end (same UDTF output, stale since 2026-06-29).
- **July timing resolved:** site 610942 is authorization-only (0 earns, 0 captures in fanflow) — the null "burns" are auth/void netting noise, **not real burned FanCash**; July spike = a few large auth holds on Jul 12–13.
