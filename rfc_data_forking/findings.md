# findings.md — grounded facts

Source: scout of the local clone `/Users/alex.sotis/repos/dbt-fes-ae` (2026-10-21) +
Jira (FEAT-10458 and its epics).

## Jira anchor — FEAT-10458 "Data Forking and Review"

- **Project/type:** FEAT (Features), status **Idea**. Reporter+assignee Alex Sotis,
  created 2026-09-25. Labels: `analytics-engineering`, `demi-initiative`, `fcore-data`,
  `snowflake`.
- **FEAT description (verbatim intent):** key datasets need "a branch of data corresponding
  to a branch of code, so that developers and stakeholders understand the impact of merging
  code on the data prior to the code being pushed to production. A script called **DBFork**
  already exists and gets us most of the way there. This FEAT is to increase some of the
  functionality of DBFork itself, plus a way to automate particular impact reports per
  pipeline."
- **Worked example in the FEAT:** the **Ads team relies on Fangraph for their audiences**
  and must approve Fangraph-affecting code that could impact current audiences. They should
  **not have to write SQL** — so generate an automated report with **basic Fangraph diff
  metrics PLUS metrics on how the change impacts audiences.** → This is exactly the
  `custom-delta-report/fangraph/` content: audience-impact SQL on top of the generic diff.

### Epics under FEAT-10458 (3)

| Epic | Summary | Status | Scope |
|------|---------|--------|-------|
| **DEMI-646** | DE: Data Forking and Review — isolated data environments for PR review | To Do | The fork mechanism: a PR spins up an isolated data env, reviewers validate against real data, it **tears down on merge/close**. (= extend DBFork + lifecycle) |
| **DEMI-676** | Documentation and RFC for Data Forking and Review | **In Progress** | **This RFC.** Done when the RFC is written, reviewed, and **linked from the FEAT**. |
| **DEMI-888** | Generate automated Fangraph delta report | To Do | The report: `auto-delta` generic metrics **plus custom reporting metrics** for the dataset; built abstractly to extend to future datasets; **this epic = the Fangraph implementation specifically.** |

**RFC implication:** the RFC (DEMI-676) must cover all three threads — (1) DBFork
enhancements + isolated-env lifecycle (DEMI-646), (2) the generic+custom delta report
framework with Fangraph/audiences as the first concrete case (DEMI-888), (3) the
stakeholder (Ads team) approval flow. The custom layer's first instance =
**audience-impact metrics for Fangraph**, not just a generic row/column diff.

---


## `dbfork` — Snowflake zero-copy clone for isolated feature testing

- **Source:** `macros/dbfork/dbfork.sql` (~74 lines) + `macros/dbfork/clean_dbfork.sql`
  (teardown) + `macros/dbfork/README.md`.
- **What it does:** `CREATE ... CLONE` (zero-copy) of materialized tables into the
  developer's isolated schema `FES_USERS.[DBT_TEST_SCHEMA]`. Only clones materializations
  in `('table','incremental','table_clone','python_table')`.
- **Signature:** `{% macro dbfork(clone_prod=False, clone_branch=False, models=None) %}`
  - `clone_prod` → clone prod table into `dbfork___prod__[DB]__[SCHEMA]__[MODEL]`
  - `clone_branch` → clone prod snapshot into `dbfork___[feature_branch]__[DB]__[SCHEMA]__[MODEL]`
  - `models` (required) → comma-separated model names, resolved via `dbt ls` selectors.
- **Invocation:** `dbt run-operation dbfork --target prod --args '{clone_prod: True, clone_branch: True, models: "m1,m2"}'`.
- **Naming:** `dbfork__[branch]__[db]__[schema]__[model]`; branch name sanitized (`. / -`
  → `_`) from env var `DBT_FEATURE_BRANCH`.
- **Seamless build path:** `macros/generate_alias_name.sql` (lines 17–22) routes any model
  built with `target.name == 'test'` to dbfork naming → so `dbt run --target test` builds
  the new version *into* the forked location automatically.

## `auto-delta` — automated diff report between two tables

- **Source:** `macros/auto_delta/auto_delta.sql` (~32 lines) + 3 submacros + `.env.example`.
- **What it does:** compares two Snowflake tables A and B on a primary key, writing **three
  report tables**:
  1. `_metrics` — row counts, PK uniqueness/null checks, PK cardinality diffs (A-not-in-B,
     B-not-in-A).
  2. `_conflicting_rows` — full outer join on PK; per non-PK column emits `a_[col]`,
     `b_[col]`, `[col]_is_delta` (1 differ / 0 match).
  3. `_conflicting_column_count` — `SUM([col]_is_delta)` per column → which columns differ
     most.
- **Signature:** `{% macro auto_delta() %}` — **env-var driven, no CLI args:**
  `AD_TABLE_A`, `AD_TABLE_B` (fully-qualified `db.schema.table`), `AD_PRIMARY_KEY` (single
  or composite comma-list; composite auto-hashed), `AD_OUTPUT_DATABASE`,
  `AD_OUTPUT_SCHEMA`, `AD_OUTPUT_TABLE_PREFIX`.
- **Invocation:** `source ./macros/auto_delta/auto_delta.env` then
  `dbt run-operation auto_delta`.
- **Submacros:** `auto_delta_metrics()`, `auto_delta_conflicting_rows()`,
  `auto_delta_conflicting_column_count()`.

## How they compose TODAY

- **Sequential & manual, not integrated.** Per `macros/dbfork/README.md` (~line 79): after
  `dbfork`, the user manually runs `auto_delta` with two env files pointing at the dbfork
  clones (prod snapshot vs. feature-branch build).
- **No per-model/per-pipeline override exists.** `auto_delta` is purely generic (any two
  tables + PK). **No `custom-delta-report/` folder exists today** → it's net-new in this RFC.

## Repo layout relevant to the RFC

- **Models:** `models/` has `fangraph/`, `cde/`, `enterprise_metrics/`, `commerce/`,
  `challenges/`, … (fangraph is a real model dir — good first worked example).
- **Macros:** all under `macros/` (52 files); `dbfork/` and `auto_delta/` are
  subdirectories there.
- **CI:** `.github/workflows/alfredo.yml` (PR descriptions) + `ponzu.yml` (approval gate)
  exist but **do NOT invoke dbfork/auto_delta**. dbt Cloud runs prod/dev; dbfork is
  developer-initiated via `run-operation`. → No existing CI automation to hook into; the
  RFC's orchestration/trigger is net-new.

## Implications for the RFC (the "delta" this project adds)

The two macros are the stable building blocks. The **new work** this FEAT proposes:
1. **Compose** `dbfork` + `auto_delta` into one PR-driven flow (today it's two manual
   steps with hand-written env files).
2. **Scope detection** — map a PR to affected models/pipeline (none today; candidates:
   dbt `state:modified`, Mesh selectors, PR label).
3. **Custom report layer** — new `custom-delta-report/<pipeline>/*.sql` for
   pipeline-specific diffs on top of the generic `auto_delta` output.
4. **Publish + approval gate** — surface the report to stakeholders (PR comment /
   Confluence / Slack); possibly extend Ponzu for a blocking approval.
5. **Lifecycle** — fork TTL / teardown (`clean_dbfork.sql` already exists → reuse).

## Still to capture

- **Jira FEAT key + exact scope** (ask user).
- Whether `custom-delta-report/` sits at repo root vs. under `macros/`/`analysis/`.
- Whether orchestration is a dbt `run-operation` wrapper vs. a GitHub Actions workflow
  vs. both.
- fangraph's PK(s) and blast radius (downstream consumers) for the worked example.
