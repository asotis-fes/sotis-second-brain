# rfc_ai_pr_review_bot — RFC: Automated AI PR Review Bot

> **Standing directive:** Keep these files updated as work progresses; treat them as
> the source of truth across sessions. Nothing under `projects/` is ever committed.

## Goal

Write an **RFC / Project Proposal** (FBG Data Project Proposal/RFC template → use the
`rfc-writer` skill) proposing an **automated AI-powered PR review bot** for FBG Data repos.
The bot would, on PR open/update:

1. Review the diff against a **team best-practices `.md` doc** (the review rubric/source
   of truth the bot is pointed at).
2. **Post review comments directly on the GitHub PR** (inline + summary).

## What the RFC must deliver

1. **Survey the current state** — enumerate the PR review bots we have today (Alfredo,
   Ponzu, any others), what each does, and where they run.
2. **Name their limitations** — what they do *not* do (notably: no automated
   best-practices code review with inline comments).
3. **Coverage gap** — which repos have a PR review bot today and which do **not**.
4. **The proposal** — an automated AI PR review bot triggered on PR events, pointed at a
   versioned best-practices `.md` doc, posting comments to the PR in GitHub.
5. **Value framing** — a few sentences on why this **reduces on-call / reviewer load**:
   catches standards violations and common bugs before a human reviewer or on-call
   engineer has to, shrinks review latency, and standardizes review quality across repos.

## Table of Contents

- `_index.md` — this file (context + TOC)
- `findings.md` — facts gathered: existing bots (Alfredo/Ponzu etc.), their mechanics &
  limits, per-repo coverage, candidate best-practices docs, CI/trigger mechanics
- `plan.md` — RFC outline + open questions to resolve before drafting
- `decisions.md` — scoping decisions, assumptions, open questions for reviewers
- `progress.md` — session log / what's done vs. open

## Key open questions (seed list — refine as we learn)

- **Existing bots:** Exactly what do Alfredo (AI PR description + Jira linker) and Ponzu
  (risk-based approval gate) do, and what do they explicitly *not* do? (Start: the
  `pr-policy-onboarder` skill.)
- **Coverage:** Which FBG Data repos (fes-airflow, data-transformations, dbt-fes-ae,
  fanapp-terraform, data-lake-services, data-platform-*, etc.) have Alfredo/Ponzu wired
  in, and which have no review automation at all?
- **Best-practices doc:** Does a single canonical best-practices `.md` exist, or is it
  scattered (fes-airflow-standards skill, CLAUDE.md, fbg-tech-guidelines MCP)? What should
  the bot point at?
- **Trigger mechanics:** GitHub Action on `pull_request`? Which model/runtime? How do
  comments get posted (gh API / Actions bot token)?
- **Value/metrics:** What on-call or reviewer pain are we actually relieving — review
  latency, repeat standards nits, bugs that reach on-call? Any baseline numbers?

## Status

Phase 0 (setup) complete. **No external doc/code links provided in framing.** Next:
Phase 1 discovery — read the `pr-policy-onboarder` skill (Alfredo/Ponzu), survey repo
coverage, and locate the best-practices doc(s) the bot should reference.
