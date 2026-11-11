# plan.md — RFC outline & proposed mechanism

## Deliverable

A Confluence RFC authored with the **`rfc-writer`** skill (FBG Data Project Proposal/RFC
template). Draft locally here first, publish last.

## RFC outline (map to Project Proposal/RFC template)

1. **Summary / TL;DR** — one-paragraph: automate forking + delta review of
   high-blast-radius model changes, gated on stakeholder approval.
2. **Problem / Motivation** — manual validation of changes to models like fangraph is
   slow, inconsistent, and risky; no standard "here's exactly what this PR changes in the
   data" artifact; stakeholders can't review before merge.
3. **Goals / Non-goals** — Goal: generic, PR-driven fork + delta report + approval, usable
   for *any* model. Non-goal (v1): replacing dbt tests / CI; full auto-merge.
4. **Proposed solution** — the mechanism (below) + the file/folder layout (below).
5. **How it works (walkthrough)** — fangraph as the worked example; loyalty as the
   "second pipeline" showing genericity.
6. **Where the new files live** — folder layout section.
7. **Rollout / phasing** — v1 one pipeline, then onboard more by adding
   `custom-delta-report/<pipeline>/`.
8. **Risks & open questions** — cost of isolated builds, fork cleanup/TTL, scope
   detection accuracy, approval-gate placement.
9. **References** — `dbfork`/`auto-delta` source, Jira FEAT, fangraph docs.

## Proposed mechanism (rough — refine with findings)

```
PR touches model(s)
   │
   ▼
[scope detection]  which pipeline(s)/models are affected  (state:modified / Mesh / label)
   │
   ▼
[dbfork]  zero-copy clone prod → isolated Snowflake location (per-PR fork)
   │
   ▼
[build]   dbt builds the modified models INTO the fork (new version)
   │
   ▼
[delta report] = generic (auto-delta diff: rows/cols/PKs) + custom-delta-report/<pipeline>/*.sql
   │
   ▼
[publish report]  to stakeholders (PR comment / Confluence / Slack)
   │
   ▼
[approval gate]  affected stakeholders approve → merge allowed
```

## Proposed file/folder layout (best guess — to validate)

Likely in **dbt-fes-ae**:

```
dbt-fes-ae/
  macros/
    dbfork/            # existing — clone to isolated location
    auto_delta/        # existing — generic diff
    data_fork_review/  # NEW — orchestration macro(s) composing the above
  custom-delta-report/
    _README.md         # contract: inputs (forked vs prod relations), output shape
    fangraph/
      *.sql            # fangraph-specific diff queries
    loyalty/
      *.sql            # loyalty-specific diff queries
  .github/workflows/
    data-fork-review.yml  # NEW — CI trigger on PR, runs fork+delta, posts report
```

Open: does `custom-delta-report/` live at repo root or under `macros/`/`analysis/`? Does
orchestration belong in dbt (run-operation) or in CI (Actions)? Decide in `decisions.md`.

## Steps to produce the RFC

- [ ] Capture the Jira FEAT (key + scope) from the user.
- [ ] Confirm `dbfork` + `auto-delta` mechanics from source (scout in progress).
- [ ] Confirm the custom-report contract and the scope-detection approach.
- [ ] Draft RFC sections 1–9 locally.
- [ ] Review against `rfc-writer` quality checklist.
- [ ] Publish to Confluence (DATA space) once user approves draft.
