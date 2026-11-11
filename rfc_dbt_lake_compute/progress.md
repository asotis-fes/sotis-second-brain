# Progress log

## 2026-10-21 — Phase 0 setup

- Created `projects/rfc_dbt_lake_compute/` with `_index.md`, `findings.md`, `plan.md`,
  `decisions.md`, `progress.md`.
- Framed the goal: RFC to evaluate dbt Labs "Lake Compute" (Iceberg-in/Iceberg-out
  transforms on dbt compute, bypassing Snowflake compute cost).
- Seeded the pressure-test questions and the measurement plan in `plan.md`.
- **No doc/code links ingested** — Phase 1 discovery not started.

## 2026-10-21 — Phase 1 discovery (2 parallel agents)

- **Product research (web):** Lake Compute = hosted **single-node DuckDB** engine on
  **Iceberg**, **private beta** (announced dbt Summit 2026), dbt Labs+Fivetran, **free in
  beta**, AWS-only. Catalogs = **Fivetran MDLS/Polaris + Snowflake Horizon + (ltd) Unity
  — NOT Glue**. **DuckDB dialect, no merge/upsert, no grants/hooks/views.** Non-goals:
  large/cross joins, warehouse replacement, RBAC. ~50% figure NOT publicly confirmed.
  Sources captured in `findings.md`.
- **Footprint inventory (repos):** 11 Commerce Iceberg tables **on Glue via Airflow**;
  canonical dbt project `dbt-fes-ae` ~1,022 models; heavy compute on **3XL (fanflow
  silver)** + XL (SF/Meta/XP). External-table lake reads throughout.
- **Key synthesis (D-1, R-1..R-5):** our biggest-cost models are the *worst* technical
  fit for single-node DuckDB; our Iceberg catalog (Glue) isn't a beta option. RFC =
  narrow measured beta eval on small/mid append models, not a Snowflake-displacement bet.
- Verbal Summit facts recorded: ~50% Snowflake-compute target; we're offered private
  preview.

## 2026-10-21 — Full RFC drafted

- User decision D-2: RFC = motivation doc, NOT metrics. No cost baseline query. Full draft.
- Confirmed live template (DATA page 3147891094) matches the 8-section skill structure.
- Wrote full RFC to `rfc_draft.md` — all 8 sections, honest single-node/Glue tension
  front-and-center, go/no-go gates, scope fences out heavy models + merge/UDF/RBAC.
  Passed the rfc-writer quality checklist.
- **NOT published to Confluence yet** — awaiting user approval + target space/parent.

## 2026-10-21 — Published to Confluence

- Created under **DEMI Project Proposals** (parent 3120365775), DATA space.
- Page: https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3654615114
  ("Project Proposal: Evaluate dbt Lake Compute for FES Data transformations").
- Owner listed as Alex Sotis (proposer). Per D-3 this is a handoff/motivation doc —
  executing team not yet named; Owner may later be reframed proposer-vs-executor.

### Open / next

- (If desired) reframe Owner to proposer-vs-executor once the handoff team is identified.
- (Deferred, not needed for RFC) Snowflake cost baseline — query
  `account_usage` warehouse/query history for transform credits by warehouse. Connection
  `FAN_DATA_EXCHANGE_PROD` configured; awaiting go-ahead.
- Decide catalog path for eval (Snowflake Horizon vs. Fivetran MDLS).
- Then draft the RFC via the `rfc-writer` skill against the FBG template.
