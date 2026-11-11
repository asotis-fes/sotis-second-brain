# 10x Tier Points Fix — Project Index

> **Standing directive:** Keep these files updated as work progresses; treat them as the
> source of truth across sessions. Nothing under `projects/` is ever committed.

## Goal

On **2026-04-23** the FanCash loyalty program launched a "10x" tier points program:
every customer's tier points were multiplied by 10 (5 pts → 50 pts), and the points
required to redeem / achieve tiers were also 10xed — so functionally nothing changed for
the customer except a psychological bump in the number.

For the data to stay internally consistent, **historical records also had to be 10xed**.
This was done, but with a **bug** in how `status_match` **trial target points** were
multiplied. A fix PR ([dbt-fes-ae #66](https://github.com/fanatics-gaming/dbt-fes-ae/pull/66))
was written but is **incorrect** — it 10xes some rows that were *already* 10xed.

**Our job:** figure out the correct logic for which `trial_target_points` rows need the
10x, validate it against two known-affected `private_fan_id`s, then 10 more, then find a
generalizable check query that returns TRUE when the fix is correct for everyone.

### Sample fan ids (known affected)
- `8ad58668-3371-4bc5-9369-0cbffd592bb1`
- `7c25289f-9fc3-4839-8e7c-3e80464bf252`

### Working location
- Sample tables in `FES_USERS.ALEX_SOTIS` (filtered to the two fan ids first).
- Use a **large warehouse**. Snowflake conn: see progress.md.

## Status: ✅ SOLVED, validated, location decided (2026-08-09)

**Fix = normalize `trial_target_points` UPSTREAM in `tier_points_overrides__status_match`,
per snapshot via `last_modified_date`** (see `decisions.md` / `corrected_upstream.sql`), and
revert the ledger CTE to passthrough (abandon PR #66).
Validated: real customers **0 mismatches / 33,233 intervals** vs CDC truth; end-to-end
(Test A) correctly removes false status-match grants; PR #66 double-10xes 415 fans / 452
intervals. Edge cases are 2 single rows (1 real customer handled correctly by the lmd rule;
1 dev account, zero prod impact).

## Table of Contents

- [decisions.md](decisions.md) — ⭐ FINAL locked fix (upstream lmd), why, validation
- [corrected_upstream.sql](corrected_upstream.sql) — ⭐ the chosen fix (exact edit to overrides__status_match)
- [validation_query.sql](validation_query.sql) — ⭐ generalizable check (real customers → 0)
- [findings.md](findings.md) — models, root cause from CDC, consumer/location analysis
- [queries.md](queries.md) — SQL tried + all results (Q1–Q7)
- [corrected_cte.sql](corrected_cte.sql) — earlier ledger-only variant (interval_end proxy; superseded)
- [sample_tables.sql](sample_tables.sql) — CTAS for FES_USERS.ALEX_SOTIS (user runs; CREATE deny-listed)
- [plan.md](plan.md) — task breakdown
- [progress.md](progress.md) — running log + Snowflake connection details

## Key facts (quick reference)

- **10x launch timestamp** (dbt var `10x_launch_timestamp`): `2026-04-23 13:17:21.000 +0000`
- Central model: `models/loyalty/fanatics_one/tier_points_ledger_v2.sql`, `status_match` CTE
- Upstream: `tier_points_overrides__status_match.sql` → `tier_points_overrides_v2.sql`
  (source: Salesforce `FanMemberTierInformation` object)
- Jira: [ENTDATA-2261](https://betfanatics.atlassian.net/browse/ENTDATA-2261)
