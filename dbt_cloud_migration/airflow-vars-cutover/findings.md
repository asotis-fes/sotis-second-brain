# Audit Findings

Audit performed 2026-07-22 across every dbt-flavored repo in the `fanatics-gaming`
GitHub org. Searched for `var('X')` / `var("X")` patterns for every Airflow context
variable Airflow can inject: `data_interval_start`, `data_interval_end`, `ds`,
`ds_nodash`, `execution_date`, `logical_date`, `ts`, `ts_nodash`, `prev_ds`, `next_ds`,
`run_id`, `dag_run`.

> **Relationship to `../data-interval-usage.md`**: that file enumerated 31 dbt models
> inside `fes-airflow/dags/dbt/models/` on 2026-07-12 that needed `steps_override` per
> **D39**. `fes-airflow/dags/dbt` was deleted on 2026-07-22 during the migration
> cutover; those models moved to the destination Mesh repos. Of the 31, only
> `fes_integrations/mentionme/referrals.sql` still contains a live `var("ds_nodash")`
> reference in dbt-fes-ae — the others either had their references removed during
> migration or landed in Mesh repos we scanned and cleared. **Fanflow (5 raw + 47 event
> bronzes) was not in the original 31-model list** — the fanflow ingestion macros were
> already in dbt-fes-ae before migration, and their `data_interval_end` dependency was
> surfaced by this fresh audit rather than by D39.

## Repos scanned

dbt-fes-ae, dbt-fes-analytics, dbt-finance, dbt-customer, dbt-vip, dbt-trading,
dbt-governance, dbt-casino, dbt-hris, dbt-fmx, dbt-operations, dbt-product, dbt-fes-ads,
dbt-regulatory, dbt_data_catalog, dbt-sandbox, dbt-internal-nonfinancial-audit,
fes-airflow (dbt subtree — deleted 2026-07-22).

## Confirmed hits — dbt code actually calling `var("<airflow-name>")`

### dbt-fes-ae (5 hits, 3 files — all in the active FES AE project)

| File | Var | Uses | Blast radius |
|---|---|---|---|
| `macros/fanflow/fanflow_unparsed_files.sql` | `data_interval_end` | 4× | Called by `fanflow_ingest_topic` → **5 raw bronze models**. |
| `macros/fanflow/fanflow_test_unparsed_files.sql` | `data_interval_end` | 4× | Test / audit variant of the ingestion macro. Same shape. |
| `models/fes_integrations/mentionme/referrals.sql` | `ds_nodash` | 1× | Filename filter `CRMFeedV2_{{ ds_nodash }}.csv`. |

Source: [dbt-fes-ae/macros/fanflow/fanflow_unparsed_files.sql](https://github.com/fanatics-gaming/dbt-fes-ae/blob/main/macros/fanflow/fanflow_unparsed_files.sql)

### dbt-governance (1 hit, 1 file)

| File | Var | Uses | Blast radius |
|---|---|---|---|
| `models/dq_controls/staging/bets_total_stake_validity_check.sql` | `data_interval_end` | 1× | `DATEADD('day', -1, DATE(var("data_interval_end")))` as the snapshot-date filter. |

Different failure mode: dbt-governance's `dbt_project.yml` default is the raw string
`CURRENT_TIMESTAMP`, which Snowflake evaluates at query time — so under dbt Cloud it
happens to render as "yesterday's date." Not producing 0 rows, but semantically pinned
and no backfill safety.

### dbt-fes-analytics (dead code — no runtime bug, but clean up)

| File | Var | Status |
|---|---|---|
| `macros/fanflow/fanflow_unparsed_files.sql` | `data_interval_end` × 4 | Duplicate of dbt-fes-ae copy, but **no models call it** here. `models/` contains only `fes_users` and `sources` — no fanflow bronzes. Dead code. |
| `macros/fanflow/fanflow_ingest_topic.sql` | — | Also dead here. |

## `dbt_project.yml` placeholder defaults (masking failures as "success, 0 rows")

| Repo | Vars set | Impact |
|---|---|---|
| dbt-fes-ae | `data_interval_start: '2023-01-01T00:00:00.0000000+00:00'`, `data_interval_end: '2023-01-02T00:00:00.0000000+00:00'`, `ds_nodash: '20250925'` | Actively masking. Remove. |
| dbt-fes-analytics | Same three vars as above. | Dead-code duplicate. Remove. |
| dbt-governance | `data_interval_start: CURRENT_TIMESTAMP`, `data_interval_end: CURRENT_TIMESTAMP` | Raw-string SQL literal — Snowflake evaluates at run time. Fragile. Normalize. |

## Confirmed clean (verified, no `var("<airflow-name>")` calls)

- dbt-fes-ae `macros/gam_report.sql` — only a docstring reference to `data_interval_start`,
  no actual `var()` call.
- dbt-finance — `execution_date` matches turned out to be column names
  (`report_execution_date`), not the Airflow variable.
- dbt-customer, dbt-vip, dbt-trading, dbt-casino, dbt-hris, dbt-fmx, dbt-operations,
  dbt-product, dbt-fes-ads, dbt-regulatory, dbt_data_catalog, dbt-sandbox,
  dbt-internal-nonfinancial-audit — no `dbt_project.yml` placeholders, no
  `var("data_interval_*")` calls in `models/` or `macros/`.
- fes-airflow — SQL under `dags/**/sql/` is Airflow-templated at run time (correctly uses
  Airflow context). `dags/dbt/` subdir was deleted 2026-07-22 as part of the dbt Cloud
  migration cutover.

## Airflow context vars with **zero** hits in dbt code

Verified across every dbt repo: no `var("...")` calls for any of
`execution_date`, `logical_date`, `ds`, `ts`, `ts_nodash`, `prev_ds`, `next_ds`,
`run_id`, `dag_run`. Only `data_interval_start`, `data_interval_end`, and `ds_nodash`
appear in actual dbt code.

## Method notes

- Used `gh search code` with the `--owner fanatics-gaming` filter and JSON output, then
  filtered results client-side to dbt paths only (`models/`, `macros/`, `snapshots/`,
  `analyses/`) and excluded DAG paths.
- Confirmed each hit by reading the referenced file — search matches on docstrings and
  column names were manually filtered out.
- `dbt_project.yml` `vars:` blocks read from every repo in the list above.
