# YOLO PR Tracker

Cross-repo PRs opened as part of the YOLO migration. Update statuses as PRs move.

**D40 mode (2026-07-12+):** All fes-airflow migration work lives on the long-lived branch **`dbt-cloud-migration`** and merges into that branch, never to main until the single cutover PR. dbt-fes-ae and fanapp-terraform prerequisites merge to their respective main branches normally — they don't touch fes-airflow prod DAG behavior.

## Long-lived branch — fes-airflow `dbt-cloud-migration`

Created 2026-07-12 from `origin/main`. Everything below either lives on this branch or is a PR into it.

**Current branch contents** (commits from previously-open PRs #2250 and #2251, cherry-picked and consolidated):
- `dags/utils/dbt_cloud.py` — helper module extracting the smoke DAG's trigger+sensor+log_run pattern into `create_dbt_cloud_task_group()` per D34. Includes D-11 fix (`dbt_run_id`).
- `dags/airflow_ops/dbt_cloud_coupling_test.py` — happy-path coupling test: `ExternalTaskSensor(commerce_data_export)` → helper → mock export.
- `dags/airflow_ops/dbt_cloud_coupling_test_failure.py` — failure-path: `steps_override` forces dbt parse failure, downstream `AssertionError` guard.

## Open — into `dbt-cloud-migration` (or in prerequisite repos)

| Repo | PR / Branch | Title | Status | Blocks |
|---|---|---|---|---|
| dbt-fes-ae | [#4](https://github.com/fanatics-gaming/dbt-fes-ae/pull/4) | Fusion parse-check + runtime verification + loyalty ledger diff proven | **Ready to merge to dbt-fes-ae main.** Parse+compile clean; loyalty ledgers proven byte-identical to dbt-core. Doesn't touch fes-airflow prod. | Parallel-run scaffolding PR (dbt-fes-ae) |
| fes-airflow | branch `dbt-cloud-migration` | Long-lived migration branch | **Active 2026-07-12.** Helper + coupling test DAGs committed. Dev testable via PRs into this branch triggering `deploy_dev.yml`. | Single cutover PR at end of migration |
| fes-airflow | [#2249](https://github.com/fanatics-gaming/fes-airflow/pull/2249) | Add dbt Cloud smoke-test DAG | End-to-end passed on dev 2026-07-11. **Dev-only reference — NOT merging to main.** Source-of-truth pattern for `utils.dbt_cloud` helper extraction. | Nothing — validation complete |

## Closed / consolidated

| Repo | PR | Reason |
|---|---|---|
| fes-airflow | [#2250](https://github.com/fanatics-gaming/fes-airflow/pull/2250) | Consolidated into `dbt-cloud-migration` on 2026-07-12 (per D40). Commits cherry-picked to the long-lived branch. |
| fes-airflow | [#2251](https://github.com/fanatics-gaming/fes-airflow/pull/2251) | Consolidated into `dbt-cloud-migration` on 2026-07-12 (per D40). Commit cherry-picked to the long-lived branch. |

## Merged (prerequisites — didn't touch fes-airflow prod)

| Repo | PR | Merged | What it did |
|---|---|---|---|
| fanapp-terraform | [#2873](https://github.com/fanatics-gaming/fanapp-terraform/pull/2873) | 2026-07-11 | Added `/airflow/connections/dbt_cloud_ae` SSM placeholder for MWAA (dev + prod). Dev value populated via Datadog Self Service post-merge; prod stays `change me` until cutover moment. |
| dbt-fes-ae | [#1](https://github.com/fanatics-gaming/dbt-fes-ae/pull/1) | 2026-07-11 | Scaffold dbt project (dbt_project.yml with legacy flags, packages, smoke model, generate_*_name macros). |
| dbt-fes-ae | [#2](https://github.com/fanatics-gaming/dbt-fes-ae/pull/2) | 2026-07-11 | Import full fes-airflow dbt tree. Initial `dbt parse` on Fusion surfaced 196 errors — cleaned up in #4. |
| dbt-fes-ae | [#3](https://github.com/fanatics-gaming/dbt-fes-ae/pull/3) | 2026-07-11 | Fusion housekeeping: package-lock.yml commit, gitignore dbt_internal_packages/, remove target-path/packages-install-path from dbt_project.yml. |

## Referenced but not opened by us

| Repo | PR | Title | Relevance |
|---|---|---|---|
| fanapp-terraform | [#2830](https://github.com/fanatics-gaming/fanapp-terraform/pull/2830) | dbt service user created — FES_ADS grants | Established the `DBT_CLOUD` Snowflake user + `SVC_DBT_CLOUD_ROLE` we're building on |

## Follow-up work

**Prerequisite PRs to open** (merge to their respective mains — don't touch fes-airflow prod):

- **fanapp-terraform: Monday TF PR** — warehouse USAGE + source-DB SELECT grants to `SVC_DBT_CLOUD_ROLE` per `fusion-migration/monday-terraform-pr-spec.md`.
- **dbt-fes-ae: parallel-run scaffolding** — `parallel_run` target + `generate_schema_name` `_SHADOW` override + `parallel_run_verify.sql` macro. Per D40 §5.
- **fanapp-terraform: `admin_roles` parity** — extend to the ~19 target DBs beyond `FES_ADS` (D22).

**On `dbt-cloud-migration` branch** (PRs into the branch — never to main):

- **DAG-by-DAG rewrites** in dev-first order per playbook §2. Superseded by D41 — pure-dbt DAGs deleted entirely from Airflow rather than rewritten. Only `dbt_loyalty_6hours` remains (has ingest sensors).
- **Cross-DAG dbt-to-dbt sensors** — no Airflow updates needed. Under D41 those chains move to dbt Cloud via `job_completion_trigger_condition` (already configured on the 22 prod jobs). Airflow's `ExternalTaskSensor` on sibling dbt DAGs is removed along with the deleted sibling DAGs.
- **Cleanup commits** — delete `dags/utils/dbt.py`, `dags/dbt/models/`, `dags/dbt/macros/`, drop `dbt-core` from `requirements/requirements.txt`.
- **SQL scripts on branch** — `sql/cutover_ownership_transfer.sql` and `sql/cutover_rollback.sql` (drafted, not executed until merge moment).

**Fusion cleanup track** (dbt-fes-ae, not blocking):

- **`merge_exclude_columns` deliberate migration** if team wants column exclusion behavior in google_ads / magnite / meta_ads models (see `fusion-migration/dbt1060-unused-config-keys.md` Sub-case C).
- **fes-airflow (on `dbt-cloud-migration`):** mirror the `dbt_snowflake_query_tags` removal from dbt-fes-ae PR #4 — drop package from `packages.yml`, remove `dispatch:` and `query-comment:` blocks from `dbt_project.yml`. Ends up in the cutover PR alongside other cleanup.
- **dbt-fes-ae** — audit legacy flags in `dbt_project.yml` and remove ones no longer load-bearing.

**The single cutover PR** (opened only when all DAGs are dev-validated):

- `dbt-cloud-migration` → `main`. Body includes rollback SQL, ownership-transfer SQL, migrated-DAG list, dev-validation summary (per-DAG parallel-run diff results + coupling-test matrix outcome + latency profile). Per playbook §9.

**Post-cutover follow-ups** (separate small PRs after cutover proves stable):

- Revoke role hierarchy safety net: `REVOKE ROLE SVC_DBT_CLOUD_ROLE FROM ROLE SVC_MWAA_ROLE`
- Wire explicit MWAA read grants in Terraform for any non-dbt Airflow tasks that still need to read migrated tables.
- TF-ify dbt Cloud deploy jobs via `dbtcloud_job` provider (deferred per D19).
