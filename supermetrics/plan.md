# Plan — Supermetrics Rollout

Two deliverable tracks: **(A) the design/rollout document** and **(B) the operating
processes**. Tasks below are sized to ~one working session each. Sequence is a best guess —
reorder as needed.

## Track A — The document(s)

- [ ] **A1. Rollout / design doc skeleton.** Decide format + home (Confluence RFC via the
  `rfc-writer` skill? which space?). Draft outline: context/POC recap → scope (Scope 1 +
  extended) → source inventory → landing-schema conventions → generic data-model design →
  consumption layer → per-opco separation → ownership (DE/AE split) → rollout phases → open
  vendor questions.
- [ ] **A2. Data-model design section.** Document the medallion stack (source → per-source
  entity tables → unified-metrics OBT, per `vision.md`/D-8). **Explicitly call out that the
  `dbt-shared-repo` standard transformations START from the Fivetran OSS dbt models, converted
  to the Supermetrics schema** (D-2). Map which Fivetran packages cover which Supermetrics
  sources; define the shared-repo consumption mechanism (package import vs dbt Mesh); define
  the canonical OBT column contract; naming conventions across the 3 opco schemas.
- [ ] **A3. Source inventory + prioritization.** Table of every source (Scope 1 + extended)
  × opco × status (live / planned) × ingestion method (API vs email report) × owner.

## Track B — The processes

- [ ] **B1. Onboarding-a-new-source process.** Repeatable runbook: request → Terraform/SSM
  connection setup (no ad-hoc SQL) → landing schema → dbt staging model → consumption →
  validation → handoff. Ties to vendor Q5 (onboarding 2–3 months post-launch).
- [ ] **B2. Ownership & intake process.** Who business teams ask for a new connection; DE vs
  AE responsibilities within DEMI; SLA/turnaround; Alex as central POC.
- [ ] **B3. Provisioning standard.** Codify the "100% Terraform/SSM from day one" rule — repo,
  module pattern, secrets in SSM, connection config. (See `project_supermetrics_no_poc_shortcuts`.)

## Track B′ — Monitoring build (new, from D-13)
- [ ] **B4. Weekly monitoring Airflow DAG.** Combine 3 signals: (1) Snowflake query-history
  query → Supermetrics sources not queried by dbt; (2) Supermetrics API → who added what/when;
  (3) pipeline health → transfer status/failures. *(Confluence documents endpoints + the
  query-history table; the script/query itself is built later, not now.)*
- [ ] **B5. Confluence "how we monitor" section.** Document the Supermetrics **API endpoints**
  for usage/who-added-what, and name the Snowflake **query-history** table for unused-source
  detection. Endpoints/queries documented, not written.

## Track C — Loose ends (not blocking the doc)

- [ ] **C1. Close vendor questions** (granularity, email-report sources, attribution
  writeback, pricing Scope 1 vs full, later-source onboarding) — from Mona's doc.
- [ ] **C2. Confirm VMO-2475 signature** and note the POC→paid account continuity.
- [ ] **C3. Inventory actual landing schemas** for FMX/FES (only `SUPERMETRICS_FBG` known).

## Immediate next task

**A1 — rollout/design doc skeleton.** Read the Core set first (`_index.md`, `decisions.md`,
`vision.md`, `rollout_policies.md`, `confluence_todo.md`). Decide doc home (likely Confluence
via `rfc-writer`) and produce the outline for review before drafting prose.
