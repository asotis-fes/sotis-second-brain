# Supermetrics Rollout — FCORE Data Org

> **Standing directive:** Keep these files updated as work progresses; treat them as the
> source of truth across sessions. **`decisions.md` is the authoritative decision log — where
> any file disagrees, it wins.** Everything under `projects/` is private working memory and is
> **never committed** (never `git add` here).

## Goal
Bring **Supermetrics** (marketing/ads ingestion) into the **FCORE data org** across the **FBG,
FMX, FES** opcos. POC is complete — remaining work is to **write the rollout/design doc + the
operating processes** for the business and data (DE + AE) teams. Alex is the single POC across
FBG/FES/FMX.

## Current state (2026-10-02)
Architecture + policies **decided** (D-1…D-20); vendor research done. **FBG live in prod**
(`SUPERMETRICS_FBG`, ~30 tables since 2026-09-21); FanApp in prod since Aug 2026. Contract
signed (per Mona's thread). **Next:** work `confluence_todo.md`, then draft the rollout doc
(task A1). Target architecture: per-opco Snowflake schemas (FBG+FMX in FBG Snowflake, FES
separate) + a shared `dbt-shared-repo` feeding 3 opco dbt projects + medallion
(source → per-source entity tables → unified-metrics OBT, grain daily×DMA×ad).

## Files

### Core — read first (small, current, authoritative)
- [`decisions.md`](decisions.md) — **source of truth.** Final decisions D-1…D-20.
- [`vision.md`](vision.md) — target architecture (per-opco schemas, shared repo, medallion).
- [`rollout_policies.md`](rollout_policies.md) — decided stances (approvals, build-vs-buy,
  deprecation, monitoring, alerting, destinations, CI, licensing, Fivetran-OSS start).
- [`confluence_todo.md`](confluence_todo.md) — what's left to resolve before sending the doc.
- [`plan.md`](plan.md) — task tracks (doc, processes, monitoring build) + immediate next task.
- [`rollout_doc_draft.md`](rollout_doc_draft.md) — the rollout/design doc **skeleton** (task A1,
  in review) → becomes the Confluence page.

### Reference — read on demand
- [`findings.md`](findings.md) — durable facts: scope, vendor capabilities, pricing, Funnel
  comparison, stakeholders, Drive source artifacts.
- [`antoine_handoff.md`](antoine_handoff.md) — summary of Antoine's FBG handoff plan (reference;
  superseded by our vision) + the differences cheat-sheet for the meeting.
- [`research.md`](research.md) — Supermetrics capability research: roles/workspaces (Part 1) +
  pipeline health / API connector cloning (Part 2).

### Archive / source
- [`progress.md`](progress.md) — condensed changelog.
- [`raw/`](raw/) — raw source docs (`DATA_ENG_HANDOFF_PLAN_2026-09-17.md`).
- [`images/`](images/) — vision diagrams (`supermetrics_data_flow.png`,
  `supermetrics_github_shared_transformation.png`).

## Key external links
- Mona's scope doc "Fanatics x Supermertrics":
  https://docs.google.com/document/d/1nFLUJAu-sSa48XqWqkyqI0h6luSNYynkair8dSWIwA4/edit
- #dsea-leads thread (2026-09-22):
  https://betfanatics.enterprise.slack.com/archives/C03MZD3QQMA/p1790090230809409?thread_ts=1790087039.530519&cid=C03MZD3QQMA
- VMO-2475 (contract): https://betfanatics.atlassian.net/browse/VMO-2475
