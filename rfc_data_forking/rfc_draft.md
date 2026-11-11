# RFC: Data Forking and Review

> **Status:** Draft · **Jira:** [FEAT-10458](https://betfanatics.atlassian.net/browse/FEAT-10458) (epics [DEMI-646](https://betfanatics.atlassian.net/browse/DEMI-646), [DEMI-676](https://betfanatics.atlassian.net/browse/DEMI-676) ← this RFC, [DEMI-888](https://betfanatics.atlassian.net/browse/DEMI-888)) · **Author:** Alex Sotis · **Date:** 2026-10-21

## Summary

Build a generic, PR-driven capability that **forks the data a code change affects into an
isolated Snowflake location, builds the new version there, and generates a plain-language
delta report** so affected stakeholders can approve the change against *real data* before
it merges to production. The mechanism is one parent dbt macro — composed from the existing
`dbfork` and `auto-delta` macros plus a pipeline-specific diff — delivered as a self-contained
HTML report. Designed to work across all three Fcore Data P&Ls (**FES, FBG, FMX**); **V1 ships
for Fangraph on FES**, with the Ads team as the first approving stakeholder.

## Problem

When a PR changes a high-blast-radius data model, we cannot see what it does to the *data*
until it is in production. Reviewers approve SQL diffs, not data diffs. For models with wide
downstream dependence this is a real risk, not a theoretical one.

**Fangraph is the motivating case.** The Ads team builds their audiences on top of Fangraph.
A change to Fangraph can silently shift the membership of those audiences — but today the Ads
team has no way to see that impact before merge, and they should not have to write SQL to
find out. The only options are: (a) trust the code review and find out in production, or
(b) an engineer hand-writes one-off comparison queries, shares screenshots, and chases
approval over Slack. Both are slow, inconsistent, and unauditable.

Two reusable building blocks already exist in `dbt-fes-ae` and get us most of the way there,
but they are **manual and unintegrated**:

- **`dbfork`** (`macros/dbfork/`) — creates Snowflake zero-copy clones of a model's tables
  into an isolated test schema, and (via `generate_alias_name`) lets `dbt run --target test`
  build the branch's version *into* that fork. Teardown exists (`clean_dbfork`).
- **`auto-delta`** (`macros/auto_delta/`) — compares two tables on a primary key and writes
  three report tables: row/PK metrics, row-level conflicts, and a per-column conflict count.

Today an engineer runs `dbfork`, then hand-writes two env files, then runs `auto-delta` —
and there is no standard per-pipeline impact report (e.g. "how did this change the audiences?"),
no automation, and no artifact a non-SQL stakeholder can read.

**Cost of inaction:** every change to a shared model like Fangraph carries unquantified
audience/reporting risk, validated (if at all) by bespoke manual effort that does not scale
to the other P&Ls or to the next important model.

## Proposal

Introduce a single parent macro — `fork_and_review(pipeline, models)` — that orchestrates
the whole flow end to end, invoked by a **dbt Cloud job that a GitHub Actions workflow
triggers from a PR** (the same GitHub → dbt Cloud CI pattern we already operate).

**The flow:**

0. **Trigger** — a label-gated GitHub Actions workflow fires on the PR and drives a **dbt
   Cloud job** (the same GitHub → dbt Cloud pattern we already run for other CI jobs); all
   dbt steps below execute in dbt Cloud, not on a runner. (Today `dbfork` runs only on an
   engineer's laptop; this moves it into CI.)
1. **Detect** the affected models from the PR (`dbt ls --select state:modified`, compared
   against the production manifest).
2. **Fork** — `dbfork` zero-copy-clones the current production tables into a per-PR isolated
   location.
3. **Build** — `dbt build --target test --select state:modified+` builds the branch's new
   version of those models into the fork.
4. **Diff (generic)** — `auto-delta` runs on each (prod vs. forked) pair, writing its three
   standard report tables.
5. **Diff (custom)** — the parent macro dispatches to a **pipeline-specific** diff
   (for Fangraph: audience-impact metrics) that writes additional report tables.
6. **Render & deliver** — a renderer reads the report tables and produces one **self-contained
   HTML report**, published as a CI artifact and linked in a PR comment. The Ads team opens
   the HTML directly — no SQL, no Snowflake login.
7. **Tear down (manual)** — the fork and its report tables **persist after the report is
   generated** and are removed only when a developer explicitly runs `clean_dbfork`. This is
   deliberate: stakeholders must be able to drill into the forked data and the report tables
   behind the HTML *after* review, including after the PR merges. Teardown is never automatic
   on merge/close. V1 has **no automatic reaper** — see Scope / Risks for the accepted
   accumulation tradeoff.

**Where the code lives — the generic/custom split:**

- **Generic layer → `fanatics-gaming/dbt-shared-utils`** (the shared dbt package already
  imported by all three P&L projects; README: *"shared macros … across FBG/FES/FMX projects"*).
  This holds the parent `fork_and_review` macro, the `dbfork`/`auto-delta` orchestration, and
  the dispatch framework that finds a pipeline's custom diff. Because every P&L project already
  pins this package in `packages.yml`, the capability is available to FES, FBG, and FMX the
  moment they adopt it — no per-repo reimplementation.
- **Custom layer → the owning project repo.** Each pipeline's bespoke diff lives with the
  pipeline it describes. For V1, Fangraph's custom SQL lives in **`dbt-fes-ae`** under a
  dedicated `custom-delta-report/fangraph/` folder. That folder is registered as a dbt
  **macro path**, so each `.sql` file is a uniquely-named macro (`custom_delta__fangraph`)
  that the shared parent macro resolves and calls by pipeline name. This keeps a clean,
  discoverable per-pipeline folder *and* lets the single parent macro call it — onboarding a
  new pipeline is "add `custom-delta-report/<pipeline>/` in that pipeline's repo," with zero
  change to the shared package.

**Where the new files live:**

```
# fanatics-gaming/dbt-shared-utils   (GENERIC — imported by FES, FBG, FMX)
macros/
  fork_and_review/
    fork_and_review.sql        # parent macro: orchestrates the whole flow
    dispatch_custom_delta.sql  # resolves + calls custom_delta__<pipeline> by name
    render_report.sql          # writes the standardized report tables
  dbfork/                      # existing (enhanced as needed)
  auto_delta/                  # existing

# fanatics-gaming/dbt-fes-ae      (CUSTOM — one folder per FES pipeline)
custom-delta-report/
  fangraph/
    custom_delta__fangraph.sql # V1: audience-impact metrics for the Ads team
  loyalty/                     # illustrative future pipeline
    custom_delta__loyalty.sql
dbt_project.yml                # macro-paths: ['macros', 'custom-delta-report']

# fanatics-gaming/dbt-finance, dbt-fmx, ...   (future P&L adopters)
custom-delta-report/
  <pipeline>/
    custom_delta__<pipeline>.sql
```

Each `custom_delta__<pipeline>.sql` is a macro taking the forked and prod relations and
writing one or more report tables; the shared `dispatch_custom_delta` finds it by the
`<pipeline>` name passed to `fork_and_review`. Convention is strict: one folder per pipeline,
one macro uniquely prefixed `custom_delta__` (the single flat macro namespace requires it).

Reusing `dbfork` and `auto-delta` rather than building new diff/fork primitives is deliberate:
they already encode the hard parts (zero-copy cloning, alias routing, PK-aware column diffing).
This RFC's net-new work is the **composition, the automation trigger, the custom-report
framework, and the human-readable artifact** — not the primitives.

## Expected Impact

**Business impact.** Stakeholders who depend on a model (Ads on Fangraph first) can approve
or reject a change based on its *actual* effect on their data — e.g. "this PR moves N accounts
in/out of audience X" — before it reaches production. This converts an unquantified risk on
every shared-model change into a reviewable, evidence-backed decision, and removes the Ads
team's dependence on an engineer to write comparison SQL.

**Operational impact.** Eliminates the manual `dbfork` → hand-written env files → `auto-delta`
→ screenshots → Slack-chase loop. The report is generated and delivered by CI. Fewer
"we didn't realize this would change the numbers" production surprises and the restatements
that follow.

**Technical impact.** One parent macro and a shared package give all three P&Ls a uniform,
versioned capability (the package is tag-pinned, so adoption is controlled). Zero-copy clones
make the isolated builds cheap on storage, and label-gating means forks are only created on
opt-in PRs. Custom diffs live beside their pipelines, keeping the shared package small and
generic.

## Scope

**In Scope**
- A parent macro `fork_and_review(pipeline, models)` in `dbt-shared-utils`, composing
  `dbfork`, the `--target test` build, `auto-delta`, and a dispatched pipeline-specific diff.
- A GitHub Actions workflow (label-gated) that runs the macro on a PR and publishes the HTML
  report + PR comment.
- The custom-report framework (`custom-delta-report/<pipeline>/` as a registered macro path)
  and the **Fangraph** implementation (audience-impact metrics) in `dbt-fes-ae` (DEMI-888).
- Output report tables in Snowflake + an auto-generated self-contained HTML artifact.
- Manual, developer-triggered fork teardown (`clean_dbfork`); forks + report tables persist
  until then.
- Any `dbfork`/`auto-delta` enhancements required to make the above composable.

**Out of Scope (deferred / handled elsewhere)**
- **Hard, Ponzu-enforced approval gates** — V1 is an *optional, engineer-triggered* tool;
  enforced stakeholder sign-off is a fast-follow (tracked under DEMI-646). See Risks.
- **Automatic fork reaping / TTL** — V1 teardown is manual only. Forks accumulating until a
  developer cleans them is an **accepted tradeoff** for V1 (see Risks); an automatic reaper is
  deferred.
- FBG and FMX pipeline rollouts — the design is generic, but only Fangraph/FES ships in V1.
- Automatic derivation of "who is a stakeholder" from Mesh lineage — V1 uses a simple
  per-pipeline stakeholder registry.
- Non-table materializations and non-PK-keyed models beyond what `dbfork`/`auto-delta`
  already support.

## Owner & Stakeholders

| Role | Name |
| --- | --- |
| Owner | Alex Sotis |
| Stakeholders | FES Analytics Engineering (builds/owns the capability); Ads team (first approving stakeholder, Fangraph audiences); FBG & FMX Data (future adopters); Core Data Platform (GitHub Actions / CI, Ponzu) |

## Risks / Open Questions

- **Cross-package macro dispatch.** A shared-package macro calling a project-local custom
  macro by name is idiomatic dbt but relies on a single, flat macro namespace — custom macros
  **must** be uniquely prefixed (`custom_delta__<pipeline>`) to avoid collisions. *Mitigation:*
  enforce the naming convention in the framework and validate it in CI.
- **From local-only to CI.** `dbfork` runs only on an engineer's laptop today. This proposal
  moves it into CI by having GitHub Actions trigger a **dbt Cloud job** — the same
  GitHub → dbt Cloud pattern we already use for other CI jobs — so the fork, build, diffs,
  and render all run in dbt Cloud. *Risk:* the current `dbfork`/`auto-delta` flow assumes an
  interactive local run (env files, `--target test`); adapting it to run unattended in a
  Cloud job is part of the net-new work.
- **Enforcement vs. option (V1 decision).** Ponzu can require a stakeholder *group* to approve
  a PR touching Fangraph (low-effort config), but it gates on GitHub PR approvals, **not** on
  whether the HTML report was actually reviewed, and it requires stakeholders to exist as
  GitHub reviewers. V1 therefore ships the report as an *optional* tool and captures approval
  out-of-band; enforcement is sequenced later.
- **Cost of isolated builds / fork accumulation (accepted tradeoff for V1).** Clones are
  cheap (zero-copy) but the `--target test` build consumes warehouse compute per run, and
  because teardown is manual by design — stakeholders keep the tables for post-review
  drill-down — forks accumulate until a developer runs `clean_dbfork`. **For V1 this is an
  accepted tradeoff:** no automatic reaper. *Partial mitigation:* label-gate the workflow so
  forks are only created on opt-in PRs. If accumulation becomes a cost problem in practice, a
  TTL/reaper is the fast-follow (deferred, not V1).
- **Stakeholder routing.** V1 hard-codes Fangraph → Ads via a small registry; generalizing
  "affected stakeholders" is deferred.
- **Scope-detection accuracy.** `state:modified` must reliably map a PR to the right models
  (and their downstream) for the fork to be meaningful.

## Next Steps

1. **Adapt `dbfork`/`auto-delta` to run unattended in a dbt Cloud job** (triggered from
   GitHub Actions, our existing pattern) rather than an interactive local run.
2. **Land the generic layer in `dbt-shared-utils`** — the `fork_and_review` parent macro +
   the custom-diff dispatch framework; cut a new pinned tag.
3. **Build the Fangraph custom diff** (audience-impact metrics) in `dbt-fes-ae` under
   `custom-delta-report/fangraph/`, registered as a macro path (DEMI-888).
4. **Add the GitHub Actions workflow** (label-gated) and the HTML renderer; wire up PR-comment
   delivery and a developer-invoked `clean_dbfork` teardown command (not auto-on-close).
5. **Pilot on real Fangraph PRs with the Ads team**; iterate on the report content until the
   audience-impact metrics are the ones Ads actually need to approve.
6. **Decide on enforcement** (optional vs. Ponzu-required stakeholder approval) based on the
   pilot (DEMI-646).
7. **Document the onboarding path** for the next pipeline / P&L (FBG, FMX).
