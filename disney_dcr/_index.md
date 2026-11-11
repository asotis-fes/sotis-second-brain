# Disney DCR — Snowflake Data Clean Room (Fanatics ↔ Disney)

> **Standing directive:** Keep these files updated as work progresses. Treat them as the
> source of truth across sessions. Nothing under `projects/` is ever committed (gitignored).

## High-level context / goal

A **Snowflake Data Clean Room (DCR)** was set up to share data between **Fanatics** and
**Disney**. The DCR is reportedly **broken**. This project has two jobs:

1. **Gather all context & documentation** (Slack, `fanapp-terraform` code, `dbt-fes-ae`,
   Snowflake DCR docs) into local `.md` files.
2. **Investigate the failure** — figure out what is wrong. **Do not guess.** If the error
   cannot be determined from available evidence, escalate to a Disney-side contact.

### Known fix requirement (carry into any remediation)
- **The wrong object was shared to the DCR.** We must share the **view `gl_fangraph`**,
  NOT the **table** produced by the dbt model named `fangraph`. (Verify in `dbt-fes-ae`.)

### Key pointers
- Terraform / infra for the DCR: **`fanapp-terraform`**.
- dbt view vs table: **`dbt-fes-ae`** (`gl_fangraph` view vs `fangraph` model/table).
- Main Slack thread (context on what was done):
  https://betfanatics.slack.com/archives/C0A6X3B3WBT/p1783711805778439

## Table of Contents

| File | Purpose |
|------|---------|
| `_index.md` | This file — context, goal, TOC |
| `findings.md` | Evidence gathered: Slack, terraform, dbt, Snowflake docs |
| `dcr-reference.md` | Snowflake DCR concepts & best practices (how DCRs work) |
| `plan.md` | Investigation & remediation plan, broken into tasks |
| `decisions.md` | Decisions made and open questions |
| `progress.md` | Running log of what's been done each session |
| `habu_ui_runbook.md` | Step-by-step LiveRamp/Habu UI actions to finish the DCR (Issue #2) |
| `attachments/` | Disney In-Platform Success Guide PDF + Disney↔Fanatics email (.eml) — ingested |

## TL;DR — current state (2026-09-01)
- It's a **LiveRamp/Habu clean room on Snowflake** (Fanatics = provider, Disney = consumer).
  There were **two problems**, both now fixed. **All Fanatics-side work is complete** — only
  Disney running the questions remains.
- **Issue #1 (wrong object) — FIXED + DEPLOYED.** `disney_base` now sources from the GrowthLoop
  view `gl_fangraph` (PR #193, merged). `DISNEY_SEGMENTS.LEAGUE_AFFINITY` also changed from an
  ARRAY to a **comma-delimited string** (PR #196, merged) so the Habu connection can split
  audience segments. Both verified live in Snowflake 8/26.
- **Issue #2 (Disney can't see it) — FIXED.** The in-platform workflow was never finished; it now
  is: ID declared as **User Identifier → SHA256**, both datasets **configured at clean-room level**
  and **assigned to all 4 questions** (LEAGUE_AFFINITY mapped as the audience column). Not a
  Snowflake grant problem.
- **Access blocker (was 🔴, now RESOLVED):** org-Admin ≠ clean-room membership (Zoe got Access
  Denied). **Anna** (the one active Partner Admin) added **Zoe** as Partner Admin from inside the
  room. See `decisions.md` → "LiveRamp access model" and `progress.md` Session 3.
- **⏳ REMAINING:** notify **Jade Lopez** (jade.a.lopez@disney.com) → Disney runs the 4 questions →
  **verify Match Report shows real overlap** = DCR fixed → close ENTDATA-2077. One open item: the
  Match Report CRM1/2/3 mapping (we put DISNEY_IDENTIFIERS/ID in all 3 slots) needs Jade's OK.

## References (external)

- 📄 **Confluence — Disney Habu clean room:**
  https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/3041722401/Disney+Habu+clean+room
  (team wiki page; not yet summarized here — read on demand)
- **Jira:** ENTDATA-2077 (Disney DCR)
- **dbt fix PRs:** [#193](https://github.com/fanatics-gaming/dbt-fes-ae/pull/193) (source →
  gl_fangraph) + [#196](https://github.com/fanatics-gaming/dbt-fes-ae/pull/196) (league_affinity
  ARRAY → comma string) — both merged & deployed
- **LiveRamp docs:** managing-users / managing-user-roles / invite-a-partner (docs.liveramp.com/connect/en/)
- **Terraform:** `fanatics-gaming/fanapp-terraform` → `root/fes-data/snowflake-v2/integrations-habu-dcr.tf`
  (PRs #2882, #2885)
- **dbt models:** `fanatics-gaming/dbt-fes-ae` → `models/fes_integrations/habu/` and
  `models/growthloop/gl_fangraph.sql`
- **Main Slack thread:** https://betfanatics.slack.com/archives/C0A6X3B3WBT/p1783711805778439
- **Local attachments:** `attachments/` (Disney In-Platform Success Guide PDF; Disney↔Fanatics .eml)

## Status
- **Phase:** 3 (remediation nearly complete). dbt fixes merged & deployed; LiveRamp clean-room
  access resolved; in-platform workflow finished (datasets configured + assigned to all 4
  questions). **Awaiting: notify Jade → Disney runs questions → verify Match Report overlap.**
- **Last updated:** 2026-09-01
