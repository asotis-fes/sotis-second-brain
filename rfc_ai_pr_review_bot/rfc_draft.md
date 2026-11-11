# RFC: Standardized AI PR Code Review Across FBG Data Repos

> Draft for review. Target: Confluence space **DATA** (Project Proposal/RFC template).
> This is a **requirements document for the BARDS team** — it states what we need, not how
> BARDS implements the trigger. Implementation mechanics are intentionally left to BARDS.

## Summary

Establish a **standard, per-repo Markdown file that holds each repo's code-review
instructions**, and have an automated bot invoke Claude on every PR to review the diff
against that file and post review comments directly on the GitHub PR. This extends our
automated PR tooling from *description-writing and approval-gating* into actual
**best-practices code review**, consistently across all FBG Data repos.

## Problem

PR review today is **manual and uneven**, and our automation stops short of reviewing the
code itself:

- **Alfredo** writes PR descriptions and links Jira tickets — it does not review code.
- **Ponzu** is a risk-based approval gate (labels, Jira key, required checks, fresh
  approvals) — it governs *who must approve*, not *whether the code is good*.
- **EddyBot** (our existing Bedrock/Claude rule-based PR reviewer in `fanatics-gaming/envy`)
  *does* review code via LLM — but today the only LLM code-review rule is **`dbt_review`**,
  it runs mainly where `dbt == true`, and its review prompts are **hardcoded in Python in
  the envy repo**, not owned by each repo. There is no general best-practices review for
  Airflow/Python, Terraform, streaming, or most other code.
- **GitHub Copilot** review is **per-user and inconsistent** — it's gated by an individual
  GitHub setting, so whether a PR gets an automated review depends on *who opened it*, and
  Copilot reviews against a generic model, **not our standards**.

The result: the quality and even the *existence* of an automated first-pass review varies
by repo, by language, and by author. Standards nits and avoidable bugs reach human
reviewers — and when they slip through review, they become **on-call incidents**. Our
best-practices knowledge is also scattered across Confluence (e.g. the dbt best-practices
guides) and skills, with no single place a reviewer — human or bot — is pointed at per repo.

**Cost of inaction:** every repo without a standards-aware reviewer leans entirely on human
reviewers and on-call to catch the same recurring classes of issue, and newly created repos
start with zero review automation until someone wires it up by hand.

## Proposal

Adopt a **standard convention: every FBG Data repo contains a Markdown file (a fixed,
predictable path) that defines that repo's code-review instructions / best-practices
rubric.** On each PR, an automated bot (built and owned by **BARDS**) calls Claude, loads
that repo's review `.md`, reviews the diff against it, and **posts review comments on the
PR in GitHub**. Each team owns its repo's `.md`; the rubric can reference our canonical
best-practices docs (e.g. the dbt guides in Confluence) rather than duplicating them.

> The automated trigger/runtime is **BARDS's to design and build** — this RFC specifies the
> behavior we need (per-repo `.md` as the source of truth, review-on-PR, comments on the
> PR), not the implementation.

Because we **already** have an LLM PR-review system (EddyBot) doing most of this plumbing —
Bedrock invocation, PR-comment posting (idempotent, marker-based), CloudWatch metrics,
OIDC — there are two credible paths. We present both for reviewers and BARDS to choose
between; we are **not** pre-selecting one here.

### Option A — Extend EddyBot

Keep EddyBot as the engine. Add a generic "review against this repo's `.md`" rule that reads
the per-repo Markdown rubric instead of a Python-authored prompt, and roll it out beyond
dbt to all repos/languages.

| Pros | Cons |
| --- | --- |
| Reuses proven plumbing (Bedrock, comment posting, metrics, OIDC, required-check wiring) | Carries EddyBot's existing rule-in-Python model and backwards-compat surface |
| Lowest lift; incremental and low-risk | Teams must learn EddyBot's conventions to own their rubric |
| Already integrated with repo-standards / required-checks tooling | Generalizing a dbt-shaped system to all languages may need real refactoring |
| One system to operate and monitor | — |

### Option B — Deprecate EddyBot's review rule, build a new `.md`-driven review skill

Stand up a new, Claude-based review bot/skill driven **entirely** by the per-repo `.md`,
and retire EddyBot's LLM code-review rule (Alfredo/Ponzu/EddyBot's non-LLM checks can
remain).

| Pros | Cons |
| --- | --- |
| Clean, `.md`-first design with no legacy rule framework | Rebuilds plumbing EddyBot already has (comments, metrics, OIDC, required checks) |
| Simple mental model: the repo's `.md` *is* the review | Migration/deprecation cost and transition period |
| Easier for each team to own without envy-specific knowledge | Higher upfront build effort and risk than extending |
| Decouples review from the dbt-centric heritage | Two systems coexist during cutover |

**Common to both options:** a fixed per-repo `.md` path convention; review runs on PR
open/update; comments posted to the PR; the `.md` references our best-practices docs; BARDS
owns the trigger.

## Expected Impact

- **Operational / on-call (primary):** Shifting standards and common-bug detection left —
  before a human reviewer or on-call engineer sees them — reduces the recurring review toil
  and the share of avoidable issues that turn into on-call incidents. A consistent automated
  first pass means review quality no longer depends on who opened the PR or which repo it's
  in, which directly lightens reviewer and on-call load.
- **Business:** Faster, more consistent PR cycle time; fewer defects reaching production
  from under-reviewed repos.
- **Technical:** A single, standardized review mechanism across repos; best-practices
  captured as versioned, per-repo Markdown (reviewable, diffable, team-owned) instead of
  tribal knowledge; newly created repos get review coverage by dropping in the standard `.md`.

## Scope

**In Scope**
- A standard per-repo `.md` convention for code-review instructions (fixed path/filename).
- Requirement that the bot reviews PR diffs against that `.md` and comments on the PR.
- Pointing the rubric at our canonical best-practices docs (starting with dbt).
- Presenting the two implementation options (extend EddyBot vs. new skill) for a decision.

**Out of Scope**
- BARDS's trigger/runtime implementation details (their design to own).
- Replacing Alfredo (PR descriptions) or Ponzu (approval gate) — those stay.
- Making the review a hard merge-blocking gate (advisory vs. blocking is an open question).
- Authoring the full rubric content for every repo (each team owns its `.md`).

## Owner & Stakeholders

| Role | Name |
| --- | --- |
| Owner | Alex Sotis |
| Build owner | BARDS team (automated trigger/runtime) |
| Stakeholders | FBG Data engineering teams (each owns its repo `.md`); Analytics Engineering (dbt rubric); DSEA (PR-review policy, Confluence DATA/2118942973); Luke Kranz / `#fcore-data-support` (Alfredo/Ponzu/EddyBot) |

## Risks / Open Questions

- **Option decision:** Extend EddyBot (A) vs. deprecate + new skill (B) — needs a decision
  from reviewers/BARDS.
- **Standard `.md` path/filename:** not yet defined (e.g. `.github/code-review.md`).
- **Canonical best-practices docs:** confirm the source of truth — likely
  Confluence **DATA/3101687873** ("DBT Training, Guidelines, and Best Practices"); also
  DATA/1986200367 and Analytics/3529375811.
- **Copilot overlap:** keep per-user Copilot reviews or disable once this ships?
- **Advisory vs. blocking:** should the review be a required status check or comments-only?
- **Noise/false positives & cost:** model/runtime and comment-volume controls (BARDS).
- **Coverage gap:** `fanapp-terraform` has no Alfredo/Ponzu today (uses its own
  `github_jira.yaml`) and no Terraform review rule exists — call out as a first target.
- **Per-repo rule matrix:** exact current EddyBot rule-per-repo coverage not yet enumerated.

## Next Steps

1. Review and choose between Option A (extend EddyBot) and Option B (new `.md`-driven bot).
2. Define the standard per-repo `.md` path/filename convention.
3. Confirm the canonical best-practices doc(s) the rubric should reference (start with dbt).
4. Hand the agreed requirements to BARDS to design/build the trigger.
5. Pilot on 1–2 repos (candidates: a dbt repo already using `dbt_review`, plus
   `fanapp-terraform` to close the no-automation gap), with success metrics
   (review latency, issues caught pre-human-review, on-call deflection).
6. Roll out the `.md` convention to remaining repos.
