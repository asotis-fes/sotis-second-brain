# Snowflake Intelligence — Agent Access & Role Model

**Status:** short-term unblock DONE; medium-term Terraform authored, **not yet committed/PR'd**.
**Owner:** Alex Sotis (SI_ADMIN via FES_DATA_DEVELOPER). **Started:** 2026-08-24.

## Goal
Unblock the FES Benefits agent (Rohan Gulati) for BETA + evals, and stand up a durable
medium-term access model so agent devs/consumers aren't blocked (build, eval, publish, edit).

## TOC
- This file = index + running log (single-file project for now).
- Related memory: `reference_snowflake_intelligence_agent_access.md` (auto-memory).
- Related projects: [[pii_strategy]], [[snowflake_masking_tax]] (PII masking is a separate effort).

## Key facts (verified this session)
- **SI role hierarchy:** `read_only → modeling → admin`. Agents + evals run as the **caller**
  (inherits `read_only`). `SNOWFLAKE_INTELLIGENCE_ADMIN` is granted to `FES_DATA_DEVELOPER`
  (so Alex has it) + Daniel Fox / Jacob Weiss / Kevin Bokor + `SVC_MWAA_ROLE`.
- **Benefits agent:** `SNOWFLAKE_INTELLIGENCE.AGENTS.FES_BENEFITS` (prod, published this session)
  + sandbox `FES_USERS.CORTEX.FES_BENEFITS`. Semantic view `FES_USERS.CORTEX.BENEFITS`
  (single base table `FES_USERS.SANDBOX.BENEFITS_CUSTOMER_MART`, 43.5M rows, dbt-built, owned
  by `SVC_DBT_CLOUD_ROLE`). Mart is customer PII.
- **Root causes solved:** (1) per-table grant on the mart got dropped on every dbt
  `CREATE OR REPLACE` → fixed durably via module `read_only_roles`. (2) Agent's Cortex Analyst
  tool was pinned to `FDE_FES_ANALYST_XL_WH` (only FES_ANALYST can use it) → repointed to
  `SNOWFLAKE_INTELLIGENCE_WH` (X-Large, read_only can use). (3) MODELING lacked SANDBOX read
  that LOYALTY_ANALYST had.

## Done (short-term, applied)
- Local perm fix: Rovo Jira mutation tools allow-listed in `.claude/settings.local.json`.
- Reviewed/approved BTS Snowflake-FES queue: Sam Alameen (had LOYALTY_ANALYST), Melissa
  Worthington (FANGRAPH-INTELLIGENCE), Kassie/Hayden/Jordan (interim FANGRAPH-INTELLIGENCE),
  Annie Frenette (LOYALTY_ANALYST, per Rohan).
- Merged PR #3163 "benefits agent for Rohan" (ad-hoc grants — now superseded by medium-term).
- Published `FES_BENEFITS` to prod AGENTS + granted read_only USAGE on the agent.
- Warehouse repointed to `SNOWFLAKE_INTELLIGENCE_WH` on BOTH agents (Rohan did via UI).
  Verified: both agents = SNOWFLAKE_INTELLIGENCE_WH; Rohan default_warehouse = same.
- Verified as MODELING on SNOWFLAKE_INTELLIGENCE_WH: `SEMANTIC_VIEW(...METRICS CUSTOMER_COUNT)`
  → 43,568,722. Full chain works.

## Pending / open threads
1. **Medium-term TF PR — NOT committed.** Branch `si-agent-dev-access` in
   `fanapp-terraform` (off main), working-tree edits to
   `root/fes-data/snowflake-v2/db-fes_users.tf` (+ SI read_only to CORTEX/SANDBOX
   read_only_roles) and `snowflake-intelligence.tf` (all/future SEMANTIC VIEWS SELECT for
   read_only; modeling CREATE AGENT + CREATE SEMANTIC VIEW + MODIFY all/future agents;
   removes ad-hoc BENEFITS block). `terraform fmt` clean. **Needs: 2 sign-offs** (a) any
   modeler can create/edit any prod agent? (b) add more data domains beyond FES_USERS? →
   then commit + open labeled PR. CI runs the real plan (no terraform locally; binary in scratchpad).
2. **New Okta roles** `SNOWFLAKE-FES-LOYALTY_INTELLIGENCE` / `SNOWFLAKE-FES-GROWTH_INTELLIGENCE`
   — #fbg-tech-stop Slack draft created (Slack Connect → must send manually), likely UNSENT.
   Once live: fanapp-terraform grants + ENTDATA ticket; re-route Kassie/Hayden/Jordan off
   interim FANGRAPH.
3. **Eval re-run:** pre-fix eval (21Q, experiment "asdfkljasdkfja;klsdfj;las", AC 0.54/LC 0.82)
   was all warehouse errors — stale. Rohan to re-run (dataset already exists). Offered to
   analyze `EVENTS.EVENTS.EVENTS` traces after re-run to separate real misses from infra noise.

## Decisions
- Two segregated agent roles chosen (LOYALTY_INTELLIGENCE, GROWTH_INTELLIGENCE), `_INTELLIGENCE`
  suffix; PII masking handled by separate project (direct PII query OK for now).
- Medium-term = beef up existing read_only + modeling roles (module-native), not new roles;
  breadth accepted, least-privilege deferred to long-term.
