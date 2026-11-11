# FanCash Allocation Review

> **Private working memory.** Everything under `projects/` is gitignored — never committed,
> never seen by teammates. Keep these files updated as work progresses; treat them as the
> **source of truth across sessions.**

## Goal

Vet a proposed **backfill of the loyalty Postgres `allocation` table** (the earn↔burn mapper
in the loyalty Postgres backend) for **obvious data errors** before it runs.

The backfill lands a **lump-sum row per customer of their unburned (unredeemed) FanCash**,
**split out by opco and jurisdiction id**. In other words: for each customer, take their
current unburned FanCash and write allocation rows that partition that balance across
(opco, jurisdiction_id).

My job = **data-error review** (a QA / sanity pass), not authoring the migration. I am a
copilot: read-only first, flag problems, recommend fixes; the human decides.

## What the user is providing (Phase 1 ingest — pending)

Three artifacts, to be summarized into local files as they arrive:
1. **A document** — the design / spec for the backfill → summarize into `spec.md`.
2. **A query** — the SQL that generates the backfill rows → capture in `inputs/` + review in `findings.md`.
3. **A table** — sample/target output of the backfill → capture in `inputs/` + review in `findings.md`.

## Review lens (what "obvious data errors" means here)

Working checklist to apply once the artifacts land (refine in `plan.md`):
- **Conservation:** does Σ(allocation rows per customer) == that customer's unburned FanCash? No over-/under-allocation.
- **Grain / dedup:** one row per (customer, opco, jurisdiction_id)? Any duplicate keys? Unintended fan-out from joins?
- **Null / missing keys:** null opco or jurisdiction_id; customers dropped by inner joins; unmapped opcos.
- **Sign / range:** no negative balances; no allocations for fully-burned customers; sensible magnitudes.
- **Unburned definition:** is "unburned" computed correctly (earn − burn, matching the earn/burn/state model)? Cross-tenant burns handled?
- **Opco / jurisdiction split logic:** is the split derived from real per-transaction attribution, or arbitrarily apportioned?
- **Scope:** all programs (FanCash / OC / Tier) or FanCash only? Which balance source of truth?

## Domain anchors (repo context)

- FanCash data model & lifecycle: `docs/domain/loyalty-fancash.md` (earn `ADD→AUTH→CAPTURE`, burn adds `→REDEEM`;
  ledger vs state vs balance vs earn_burn_mapper tables).
- Loyalty Postgres → S3 → Snowflake ingest is being unified (see `projects/fancash_migration/`,
  `vault/wiki/hot.md`). The `allocation` table is one of the 24 loyalty QC tables.
- Prior related investigation: `projects/loyalty_earn_burn_null_earn_tenant/` — null `earn_tenant_id`
  attribution bug in `loyalty_earn_burn_mapper` (opco/jurisdiction attribution is a known soft spot).

## Table of Contents

- [`_index.md`](./_index.md) — this file (goal, review lens, TOC)
- [`spec.md`](./spec.md) — summary of the [Fancash Allocation Logic doc](https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/3486875693)
- [`findings.md`](./findings.md) — **data-error review results** (invariants verified + 3 items to confirm)
- [`slack_thread.md`](./slack_thread.md) — [#project-fancash-migration](https://betfanatics.enterprise.slack.com/archives/C0BPV01HBKL) catch-up; open Qs → status in latest query
- [`decisions.md`](./decisions.md) — decisions established + open questions
- [`progress.md`](./progress.md) — session log & next steps
- [`inputs/fancash_attribution.sql`](./inputs/fancash_attribution.sql) — the reviewed query (from [repo](https://github.com/fanatics-gaming/fes-loyalty-fancash-migration-ws/blob/main/snowflake/fancash_attribution.sql))
- [`inputs/missing_accounts.csv`](./inputs/missing_accounts.csv) — all 12,448 non-test dropped accts + per-account evidence
- [`hajime_message.txt`](./hajime_message.txt) — **ready-to-send** note + tested query on the coverage gap (not in the doc)

## Status

**Review complete (2026-09-08).** Table `LOYALTY.FANCASH.ALLOCATION_20260908` (4,101,158 rows) is
**structurally clean** — every doc invariant reproduced with zero violations. The allocation is
**percentage-based, not dollar-based**; exclusions are 99.98% test-account dollars (by design). Three
items for a human to confirm before a **prod** backfill: allowlisted employee acct (🔴, intentional for
canary — strip for full run), percent-vs-dollar contract (🟡), small real-money coverage gap (🟡).
See `findings.md` for details.
