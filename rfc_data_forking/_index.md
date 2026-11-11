# rfc_data_forking — RFC: Automated Data Forking & Delta Review

> **Standing directive:** Keep these files updated as work progresses; treat them as
> the source of truth across sessions. Nothing under `projects/` is ever committed.

## Goal

Write an **RFC / Project Proposal** (FBG Data Project Proposal/RFC template → see the
`rfc-writer` skill) for a Jira FEAT that builds a generic, automated **data-forking +
delta-review** capability on top of the existing `dbfork` and `auto-delta` dbt macros in
**dbt-fes-ae**.

The ask: when a PR touches a pipeline/model, we want to — programmatically and
automatically — **fork the affected data models into an isolated Snowflake location**,
**generate a delta report** comparing new-vs-current output, and **route that report to
affected stakeholders for approval** before the change merges.

This is the **RFC prior to starting the work** — it outlines the value added and roughly
describes the implementation, how it would work, and where the new files would live. It is
*not* the implementation plan.

### The core idea (as framed)

- Changes to high-blast-radius models (e.g. **fangraph**) have wide downstream
  implications. Today, validating such a change is manual and ad hoc.
- Build a **generic** mechanism usable for *any* data model, driven off a PR.
- The delta report has two parts:
  1. **Generic diff** via `auto-delta` — every pipeline gets this.
  2. **Pipeline-specific SQL** — lives in a per-pipeline folder,
     e.g. `custom-delta-report/fangraph/*.sql`, `custom-delta-report/loyalty/*.sql`.
- The fork lands the new models in an **isolated Snowflake location** (zero-copy clone /
  dbfork target), so stakeholders can inspect real built data before approving.

### What this RFC must deliver

1. **Motivate** — the cost of unreviewed high-blast-radius changes; why manual validation
   doesn't scale; the value of stakeholder-approvable, data-grounded diffs.
2. **Describe the mechanism** — PR → fork → build in isolation → generic + custom delta
   report → stakeholder approval gate. Roughly, not exhaustively.
3. **Define the file/folder layout** — where `custom-delta-report/<pipeline>/` lives, how
   `dbfork` + `auto-delta` are composed, where the orchestration/CI hook sits.
4. **Scope & open questions** — what's in v1 (fangraph as the first concrete pipeline?)
   vs. deferred; risks; cost of the isolated builds.

## Table of Contents

- `_index.md` — this file (context + TOC)
- `findings.md` — facts gathered: how `dbfork` & `auto-delta` work today, repo layout,
  CI wiring, the Jira FEAT, fangraph/loyalty model context
- `plan.md` — RFC outline (mapped to the Project Proposal template) + the proposed
  mechanism and file layout
- `decisions.md` — scoping decisions, assumptions, open questions for reviewers
- `progress.md` — session log / what's done vs. open

## Key open questions (seed list — refine as we learn)

- **Jira FEAT:** what is the FEAT key / exact scope the user filed? (ingest it)
- **`dbfork` today:** zero-copy clone of DB/schema? naming of the forked target? how
  invoked (run-operation / CI / hook)? who has access to the forked location?
- **`auto-delta` today:** what diff does it emit (row counts, column-level, PK-level)?
  output artifact (table/view/markdown)? how parameterized per model?
- **Composition:** do `dbfork` + `auto-delta` already compose, or is wiring them the new
  work?
- **Custom report contract:** what interface must `custom-delta-report/<pipeline>/*.sql`
  satisfy (inputs = forked vs. prod relations; output shape the report expects)?
- **Trigger & scope detection:** how does a PR map to "affected models" → which pipelines
  to fork? (dbt state:modified? Mesh? label? manifest diff?)
- **Approval gate:** where does stakeholder approval live (PR check, Confluence, Slack)?
  blocking vs. advisory?
- **Cost/cleanup:** isolated builds cost compute + storage; TTL/teardown of forks.
- **Where it lives:** new macros + orchestration in dbt-fes-ae? a CI workflow? a skill?

## Jira anchor

- **FEAT-10458 — "Data Forking and Review"** (status: Idea). This RFC fulfills epic
  **DEMI-676** ("Documentation and RFC…", In Progress — done when written, reviewed, and
  linked from the FEAT). The other two epics scope the build: **DEMI-646** (isolated fork
  env + teardown on merge/close) and **DEMI-888** (generic `auto-delta` + custom metrics,
  Fangraph implementation first). See `findings.md` for the verbatim scope + the Ads-team /
  audiences worked example.

## Status

Phase 0 (setup) done; Phase 1 grounding done — `dbfork`/`auto-delta` mechanics confirmed
from source, and FEAT-10458 + its 3 epics ingested. Next: draft the RFC against the
Project Proposal template via the `rfc-writer` skill (pending the design-fork calls in
`decisions.md` Q-2/Q-3/Q-4, or draft-with-defaults on user's go).
