# Airflow Vars in dbt — Cutover

**Parent project**: [`../README.md`](../README.md) (dbt Cloud Migration)
**Related sibling file**: [`../data-interval-usage.md`](../data-interval-usage.md) — the
2026-07-12 enumeration of 31 fes-airflow dbt models that referenced Airflow context vars.
That list was for the migration-time `steps_override` treatment (D39). This subfolder
covers what's LEFT in the destination Mesh repos (`dbt-fes-ae`, `dbt-governance`,
`dbt-fes-analytics`) after the cutover, discovered 2026-07-22 via a fresh org-wide
audit. Fanflow is a new addition — not in the original 31-model list.

**Status**: design locked, awaiting go-ahead on PRs
**Created**: 2026-07-22
**Owner**: alex.sotis

> **Standing directive**: Keep the files in this folder updated as work progresses.
> Treat them as the source of truth across sessions — do not hold state in the context
> window. Before `/compact` or `/clear`, refresh `progress.md` and the TOC below.

---

## Problem in one sentence

Airflow-native template variables (`data_interval_end`, `ds_nodash`) are referenced inside
dbt models and macros, but under dbt Cloud they aren't injected — they silently fall back
to placeholder defaults declared in `dbt_project.yml`, so incremental models load 0 rows
and only surface via downstream `dbt_utils.recency` test failures.

**Primary victim**: fanflow S3-stage ingestion. 5 raw bronze models silently frozen since
dbt Cloud cutover; ~47 event bronzes downstream freeze naturally because their sources
never advance.

## Fix in one sentence

Replace `var("data_interval_end")` / `var("ds_nodash")` with self-healing target-table
high-water-mark windows anchored by `run_started_at`; hard cutover on the legacy var
names; project-var bootstrap default `2024-01-01`.

## Table of contents

- **[issue.md](issue.md)** — What's broken, why, how it went silent, blast radius.
- **[findings.md](findings.md)** — Full audit: every instance of Airflow-var usage across
  every dbt repo in the FBG org, plus placeholder-default inventory.
- **[airflow-trigger-strategy.md](airflow-trigger-strategy.md)** — **CURRENT PLAN**
  (2026-07-23). Wave 2 pivoted from per-model dbt rewrites to Airflow-trigger
  everything as a bridge state. Supersedes `plan.md`.
- **[fix-design.md](fix-design.md)** — Macro rewrite + per-model fixes + locked decisions
  + prevention. (Historical — PR 22 fanflow design is still valid; Wave 2 sections
  superseded by airflow-trigger-strategy.md.)
- **[per-model-verification.md](per-model-verification.md)** — Deep-dive per each of the
  7 affected models: does Option 2 (target-table high-water-mark) actually work here,
  edge cases, tweaks vs the initial draft.
- **[wave-2-diagnostic.md](wave-2-diagnostic.md)** — Post-merge audit of the ~30 OTHER
  models in dbt-fes-ae that reference Airflow context vars. Prod Snowflake diagnostic
  results; three separate ops-level problems identified (xtremepush 6-week freeze,
  loyalty metrics 2-day freeze, gl_new_to_x never materialized).
- **[affected-tables.md](affected-tables.md)** — Per-table checklist: code change status +
  manual-action investigation (backfill, gap-fill, watermark reset).
- **[plan.md](plan.md)** — Three PRs broken into discrete session-sized tasks.
- **[decisions.md](decisions.md)** — Locked-in design decisions with rationale.
- **[progress.md](progress.md)** — Running log of work completed.

## Scope

**In scope** (this project):
- dbt-fes-ae — primary fix (macros + one model + `dbt_project.yml`)
- dbt-governance — one model + `dbt_project.yml`
- dbt-fes-analytics — dead-code cleanup
- CI grep guards to prevent regression

**Out of scope** (tracked separately):
- Fusion `dbt1070 BaselineIntrospectionSyntaxInvalid` warning on `BUILD_SCOPED_FILE_URL` /
  `@stage` — same 5 bronze models, but unrelated to the ingestion window bug.
- Airflow-orchestrated SQL under `fes-airflow/dags/**/sql/` — still Airflow-templated,
  correctly uses `data_interval_*`. The `dags/dbt/` subdir was deleted on 2026-07-22 as
  part of the dbt Cloud migration.
