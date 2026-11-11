# dbt Cloud Cutover Playbook

Playbook for cutting `fes-airflow`'s dbt orchestration from MWAA-executed dbt-core to dbt Cloud — as a **single cutover** validated on dev end-to-end, per **D40**.

**Post-D41 shape** (locked 2026-07-13):
- **No dbt commands run under MWAA post-cutover.** Any Airflow DAG that only triggered dbt Cloud and waited for it is **deleted**, not rewritten.
- **Zero dbt-Cloud-to-dbt-Cloud coordination in Airflow.** Airflow never waits on one dbt Cloud job to trigger another. Those dependencies belong entirely inside dbt Cloud via `job_completion_trigger_condition`.
- **What survives in Airflow**: DAGs whose sole purpose is *ingest→trigger* or *poll→export*. Only `dbt_loyalty_6hours` has any dbt Cloud interaction, and it triggers exactly ONE dbt Cloud job after ingest sensors clear (Snowflake handshake + one Airflow-native SQL DAG that refreshes an external table and snapshots it). It never chains to another dbt Cloud job.
- **All other dbt work**: scheduled inside dbt Cloud via `schedule.cron` + `triggers.schedule=false` (activated at cutover via one PATCH).
- **dbt-to-dbt cross-job chains**: handled by dbt Cloud's `job_completion_trigger_condition` between sibling jobs (e.g. prod `dbt_loyalty` chains from prod `dbt_fanflow`). Never `ExternalTaskSensor` in Airflow.
- **Airflow's role, distilled**: `ingest signal → DbtCloudRunJobOperator → DbtCloudJobRunSensor → export`. No dbt Cloud job runs another dbt Cloud job through Airflow.

## Relationship to prior decisions

Read alongside:

- **`decisions.md`** — original 5-week plan decisions D1–D18 (many revised later).
- **`decisions.md`** — YOLO decisions D19–D40. **D40 governs shape:** single long-lived branch `dbt-cloud-migration`, zero merges to main until validated on dev, one final cutover PR. D33 (waves), D36 (per-DAG parallel-run split), D38 (per-DAG ownership) SUPERSEDED by D40.
- **`discoveries.md`** — gotchas: D-01 (SVC user login name), D-06 (URI format), D-09 (sync-mwaa-env HEAD~1 quirk), D-11 (`run_id` reserved), D-16 (diff methodology), D-17 (design docs freeze pre-fix designs).
- **`permissions.md`** — Snowflake ownership + role-hierarchy model. Ownership transfer applies to ALL migrated tables at the cutover moment (per D40, restoring D20's original shape).
- **`fusion-migration/loyalty-diff-runbook.md`** — proven byte-identical output for the 4 loyalty ledgers. First dev proof point.
- **`fusion-migration/monday-terraform-pr-spec.md`** — warehouse USAGE + source-DB SELECT grants prerequisite.
- **`coupling-test-plan.md`** — dev-only validation of the trigger + sensor coupling before any DAG rewrites.

**Do not re-litigate** locked decisions in this playbook. If a change is needed, add a new decision to `decisions.md` and reference it here.

## Architectural premise

The pre-D41 premise — "every `dbt_*.py` DAG becomes a thin dbt Cloud wrapper via `create_dbt_cloud_task_group`" — was replaced by D41: those DAGs are deleted entirely. Pure dbt orchestration lives in dbt Cloud (native cron + `job_completion_trigger_condition`). Airflow only survives where an ingest signal or export leg makes it structurally necessary (`dbt_loyalty_6hours`).

The cutover pattern is therefore two-fold:
1. **Delete** the pure-dbt DAGs (21 of 22, including fangraph and full_refresh) — one atomic PR
2. **Rewrite** the surviving DAG (`dbt_loyalty_6hours`) to trigger its dbt Cloud job via `create_dbt_cloud_task_group` instead of shelling to dbt-core

## Table of contents

1. [Cutover pattern](#1-cutover-pattern)
2. [DAG inventory](#2-dag-inventory)
3. [Cross-DAG dependencies](#3-cross-dag-dependencies)
4. [Data-interval vars & Airflow context](#4-data-interval-vars--airflow-context)
5. [Dev-only parallel-run validation](#5-dev-only-parallel-run-validation)
6. [Deploy job conventions](#6-deploy-job-conventions)
7. [Sequencing on the long-lived branch](#7-sequencing-on-the-long-lived-branch)
8. [Prerequisites checklist](#8-prerequisites-checklist)
9. [The single cutover PR](#9-the-single-cutover-pr)
10. [Rollback](#10-rollback)

---

## 1. Cutover pattern

### PRIMARY TEST TARGET: ingest→trigger→poll→export handshake

Before rolling any DAG to production, the highest-risk mechanism is not dbt Cloud itself (proven byte-identical via loyalty diff) — it's **the Airflow↔dbt Cloud handshake** at the two boundaries:

- **Upstream** (ingest-side): ingest DAG completes → dbt DAG's `DbtCloudRunJobOperator` triggers **one** dbt Cloud job
- **Downstream** (export-side): dbt Cloud job completes → `DbtCloudJobRunSensor` releases → downstream export task fires

These are the ONLY places Airflow talks to dbt Cloud post-D41. Airflow never coordinates between two dbt Cloud jobs. dbt-to-dbt chaining lives inside dbt Cloud via `job_completion_trigger_condition`.

**`utils.dbt_cloud.create_dbt_cloud_task_group` is the primary abstraction for this handshake.** Under D41 the only surviving Airflow DAG with dbt Cloud interaction is `dbt_loyalty_6hours`, which exemplifies the full pattern:
1. Upstream sensors clear ingest: `SqlSensor` (on `transaction_raw_replication_handshake_sensor.sql`, the Postgres→Snowflake replication handshake) + `ExternalTaskSensor` on `loyalty_bonus_fancash_incremental` (an Airflow-native SQL DAG that refreshes an external table and snapshots it — treated as ingest for our purposes)
2. Trigger the ONE dbt Cloud job (`dbt_loyalty_6hours`) via the helper's `trigger` task
3. The helper's `wait` sensor blocks `log_run` until dbt Cloud finishes
4. Failure semantics: if dbt Cloud fails, `log_run` records the failed run and the DAG fails cleanly; if ingest sensors fail, the trigger never fires

Note: `dbt_loyalty_6hours` triggers exactly ONE dbt Cloud job. It does not, and must not, coordinate between multiple dbt Cloud jobs.

Any export DAG that used to `ExternalTaskSensor` on a deleted `dbt_*` DAG's `log_run` task now either: (a) uses time-based schedule + retries, or (b) polls dbt Cloud API for latest run status. Each has a `TODO(dbt-cloud-migration)` comment in the source.

### 1a. Build `utils.dbt_cloud` helper (one-time)

New sibling to `utils.dbt`. Purpose: shrink per-DAG diffs to essentially one line, keep trigger + sensor + logging out of DAG files.

```python
# fes-airflow/dags/utils/dbt_cloud.py
import logging
import pendulum
from airflow.providers.dbt.cloud.hooks.dbt import DbtCloudHook
from airflow.providers.dbt.cloud.operators.dbt import DbtCloudRunJobOperator
from airflow.providers.dbt.cloud.sensors.dbt import DbtCloudJobRunSensor
from airflow.utils.task_group import TaskGroup

logger = logging.getLogger(__name__)

DBT_CLOUD_CONN_ID = "dbt_cloud_ae"

def create_dbt_cloud_task_group(
    group_id: str,
    job_id: int,
    poke_interval: int = 60,
    timeout_seconds: int = 60 * 90,
    steps_override: list[str] | None = None,
) -> TaskGroup:
    """
    Wrap trigger + sensor + metadata-log as a TaskGroup. Returns the group;
    caller wires upstream/downstream to it.

    steps_override: pass full `dbt build --select ...` string(s) if you need
    Airflow context vars threaded to dbt (data_interval_start, etc.). Omit
    to run the job's default steps.
    """
    with TaskGroup(group_id=group_id) as tg:
        trigger = DbtCloudRunJobOperator(
            task_id="trigger",
            dbt_cloud_conn_id=DBT_CLOUD_CONN_ID,
            job_id=job_id,
            wait_for_termination=False,
            trigger_reason="Airflow: {{ dag.dag_id }} / {{ run_id }}",
            steps_override=steps_override,
        )

        wait = DbtCloudJobRunSensor(
            task_id="wait",
            dbt_cloud_conn_id=DBT_CLOUD_CONN_ID,
            run_id=trigger.output,
            poke_interval=poke_interval,
            timeout=timeout_seconds,
            mode="reschedule",
        )

        @task(task_id="log_run")
        def log_run(dbt_run_id: int) -> None:
            # Parameter named `dbt_run_id` (not `run_id`) because `run_id` is a
            # reserved Airflow context key on @task-decorated functions — see
            # discoveries.md D-11. The DbtCloudHook.get_job_run() call still
            # uses `run_id=` because that's the hook's parameter name.
            hook = DbtCloudHook(dbt_cloud_conn_id=DBT_CLOUD_CONN_ID)
            run = hook.get_job_run(run_id=dbt_run_id).json()["data"]
            logger.info(
                "dbt Cloud run finished. run_id=%s status=%s duration=%s href=%s",
                run.get("id"),
                run.get("status_humanized"),
                run.get("duration_humanized"),
                run.get("href"),
            )

        trigger >> wait >> log_run(trigger.output)

    return tg
```

Design notes:
- **TaskGroup**, not three top-level tasks. Keeps DAG UI clean and gives us a single downstream anchor (`<group_id>.log_run`) for `ExternalTaskSensor` to depend on.
- **`steps_override` is optional** and only used when the DAG needs Airflow context threaded to dbt. Most DAGs don't.
- **Runbook logging** happens in every DAG for free — no per-DAG boilerplate.

### 1b. Per-DAG rewrite (average diff)

Before:
```python
def dbt_daily():
    dbt.create_dbt_dag(DBT_PATH, tags=["daily"], ...)
```

After:
```python
def dbt_daily():
    dbt_cloud.create_dbt_cloud_task_group(
        group_id="dbt_daily",
        job_id=DBT_CLOUD_DAILY_JOB_ID,
    )
```

That's the entire body. Job IDs live at the top of each DAG file as module-level constants (as with the smoke DAG). No SSM param, no Airflow Variable — job IDs are stable-once-created and not secret.

### 1c. DAGs with cross-DAG sensors

Pre-D41 there were several Airflow-to-Airflow dbt-to-dbt sensor chains:
```python
wait_for_fanflow_loyalty = ExternalTaskSensor(
    external_dag_id="dbt_fanflow",
    external_task_id="model.fes_data.loyalty_transaction_successful__account",
    ...
)
```

**Post-D41 these are eliminated**: both `dbt_loyalty` and `dbt_fanflow` DAGs are deleted from Airflow. Their dbt Cloud jobs (`70437463791501` and `70437463791505`) chain via `job_completion_trigger_condition` inside dbt Cloud. See [§3](#3-cross-dag-dependencies) for the full mapping of pre-D41 sensor chains → post-D41 equivalents.

---

## 2. DAG inventory

Every `dbt_*.py` DAG in `fes-airflow/dags/dbt/`. All except `dbt_fangraph` and `dbt_full_refresh` cut over in the single migration. Order shown is **dev-development order** (start where confidence is highest), not a deployment cadence.

| # | DAG | Tag(s) selector | Callback tier | External sensors | Schedule (prod) | Dev-first order |
|---|---|---|---|---|---|---|
| 1 | `dbt_loyalty` | `loyalty` | P2 | 1 (dbt_fanflow) | hourly | 1 — HASH_AGG-diff-verified 2026-07-12 |
| 2 | `dbt_sources` | source freshness | P3 | 0 | weekdays 9am | 2 — low complexity |
| 3 | `dbt_hourly` | `hourly` | P2 | 0 | hourly | 3 |
| 4 | `dbt_daily` | `daily` | P3 | 0 | daily 8am | 4 |
| 5 | `dbt_daily_9am` | `daily_9am` | P3 | 0 | daily 9am | 4 |
| 6 | `dbt_every_3hours` | `every_3hours` | P3 | 0 | every 3h | 4 |
| 7 | `dbt_every_6hours` | `every_6hours` | P3 | 0 | every 6h | 4 |
| 8 | `dbt_weekly` | `weekly` | P3 | 0 | weekly | 4 |
| 9 | `dbt_loyalty_6hours` | `loyalty_6hours` | P2 | 1 (bonus_fancash) | every 6h | 5 |
| 10 | `dbt_loyalty_metrics` | `loyalty_metrics` | P2 | 0 | see file | 5 |
| 11 | `dbt_loyalty_balance_monthly_snapshot` | `loyalty_balance_snapshot` | P2 | 0 | monthly | 5 |
| 12 | `dbt_enterprise_metrics` | `enterprise_metrics` | P? | 0 | see file | 5 |
| 13 | `dbt_enterprise_metrics_daily` | `enterprise_metrics_daily` | P? | 0 | daily | 5 |
| 14 | `dbt_mde` | `mde` | P? | 0 | see file | 5 |
| 15 | `dbt_meta_ads` | `meta_ads` | P3 | 0 | daily 4am | 5 |
| 16 | `dbt_xtremepush` | `xtremepush` | P? | 1 (dbt_fangraph) | see file | 5 |
| 17 | `dbt_fanatics_one` | `fanatics_one` | P? | 0 | see file | 5 |
| 18 | `dbt_fanapp_recs` | `fanapp_recs` | P? | 0 | see file | 5 |
| 19 | `dbt_ltv` | `ltv` | P? | 0 | see file | 5 |
| 20 | `dbt_users` | `users` | P? | 0 | see file | 5 |
| 21 | `dbt_fanflow` | `fanflow` | P? | 0 | see file | 6 — has downstream external sensors, save for last |
| 22 | `dbt_fangraph` | `fangraph` custom_selector | P? | 2 (fan_key ...) | see file | **DEFERRED** — 211 models, source() defer issues |
| 23 | `dbt_full_refresh` | one-shot backfill utility | — | — | manual only | Migrate after cutover (or skip) |

**Post-D41 status**: the table above is a snapshot of the pre-D41 world where each dbt tag had its own `dbt_*.py` Airflow DAG. Under D41 all pure-dbt DAGs (no ingest/export coupling) are **deleted**. Only `dbt_loyalty_6hours` remains in Airflow. Every tag still runs — but as a dbt Cloud job (`triggers.schedule` populated with cron, activated at cutover). See `deploy-jobs.md` for the 22 prod job IDs and their cron schedules.

**Dev-first ordering rationale (historical — before D41):**
1. **loyalty** first because 4 ledger models are already HASH_AGG-diff-verified byte-identical to dbt-core (see `fusion-migration/loyalty-diff-runbook.md`).
2. **dbt_sources** next because source-freshness is a distinct execution mode worth exercising once end-to-end.
3. **P2 hourly** next — hourly cadence surfaces coupling issues fastest.
4. **P3 batch DAGs** — all sensor-free, easy to compose on dev.
5. **Rest of P2** including remaining loyalty family + enterprise + third-party.
6. **dbt_fanflow last** because it had downstream cross-DAG sensors (irrelevant post-D41 since those DAGs are deleted).

For DAGs with `P?` fill in `callbacks.dag_failure_callback_p*` from the file — omitted here to keep this table honest about what's verified.

---

## 3. Cross-DAG dependencies

**Post-D41: cross-DAG dbt-to-dbt dependencies stay in dbt Cloud, not Airflow.** D37 (ExternalTaskSensor on sibling `log_run`) is superseded.

Historically the fes-airflow tree had four dbt-to-dbt cross-DAG sensor patterns:

- `dbt_loyalty` → `dbt_fanflow.model.fes_data.loyalty_transaction_successful__account`
- `dbt_loyalty_6hours` → `loyalty_bonus_fancash_incremental` (this one stays — ingest-side coupling)
- `dbt_xtremepush` → some pfi_fangraph task
- `dbt_fangraph` → 2 external sensors (fan_key_master_pii, fan_key_account_map)

**How each is handled post-cutover (per D41):**

| Cross-DAG dep | Handling |
|---|---|
| `dbt_loyalty` waits on `dbt_fanflow` | Both DAGs deleted from Airflow. Prod dbt Cloud job `dbt_loyalty` (`70437463791501`) has `job_completion_trigger_condition` on prod job `dbt_fanflow` (`70437463791505`, status=10). Chain fires natively inside dbt Cloud. |
| `dbt_loyalty_6hours` ingest sensor | KEPT in Airflow (has `SqlSensor` + `ExternalTaskSensor` on ingest signals). Its dbt work triggers dbt Cloud job `dbt_loyalty_6hours`. |
| `dbt_xtremepush` waits on pfi_fangraph | Both DAGs deleted from Airflow. If a chain is needed, add `job_completion_trigger_condition` between their dbt Cloud jobs. |
| `dbt_fangraph` waits on fan_key_master_pii, fan_key_account_map | `dbt_fangraph` deleted. If fan_key models need to complete first, add `job_completion_trigger_condition` in dbt Cloud pointing at the job that builds those (typically `dbt_every_6hours`). |

**What survives in Airflow (D41 rule)**: DAGs with ingest OR export coupling. The only surviving example: `dbt_loyalty_6hours` (ingest sensors). Any DAG that only triggered dbt Cloud and waited for it is deleted — its dbt Cloud job runs on its own schedule inside dbt Cloud (cron + `triggers.schedule=true` post-cutover).

**Airflow's post-cutover pattern**: `ingest_sensor → DbtCloudRunJobOperator → DbtCloudJobRunSensor → export_task`. No more `ExternalTaskSensor` on sibling dbt DAGs — those siblings no longer exist.

---

## 4. Data-interval vars & Airflow context

Some incremental models reference Airflow-injected `--vars`:

```sql
'{{ var("data_interval_start") }}'::TIMESTAMP AS snapshot_ts
```

These appear in `cde_loyalty_analytics_ledger_metrics.sql`, `cde_tier_points_overrides_metrics.sql`, `cde_loyalty_balance_metrics.sql`, and probably a handful of others. Grep required:

```bash
grep -rln "data_interval_start\|data_interval_end\|ds_nodash" \
  ~/repos/fes-airflow/dags/dbt/models/
```

For any DAG whose selector includes such models, use `steps_override` to thread the Airflow context into dbt Cloud's run:

```python
dbt_cloud.create_dbt_cloud_task_group(
    group_id="dbt_loyalty_metrics",
    job_id=DBT_CLOUD_LOYALTY_METRICS_JOB_ID,
    steps_override=[
        'dbt build --select tag:loyalty_metrics --vars \''
        '{"data_interval_start": "{{ data_interval_start | ts }}", '
        '"data_interval_end": "{{ data_interval_end | ts }}", '
        '"ds_nodash": "{{ data_interval_start | ds_nodash }}"}\''
    ],
)
```

`steps_override` is a list of shell commands the dbt Cloud run executes in place of the job's default steps. Jinja templating in Airflow renders the vars at trigger time. Reference: [dbt Cloud API docs](https://docs.getdbt.com/dbt-cloud/api-v2#/operations/Trigger%20Job%20Run) `steps_override`.

DAGs where `data_interval_*` doesn't matter (which is most — check via grep before deciding) can leave `steps_override=None` and run the job's baked-in steps.

---

## 5. Dev-only parallel-run validation

Runs entirely on **dev MWAA** and **dev Snowflake** against real dev source data. No prod behavior change until the cutover PR merges.

### 5a. Shadow-schema mechanic

On dev:
- MWAA (dbt-core) keeps writing to the base dev schemas (unchanged).
- dbt Cloud (Fusion) writes to sibling **`<schema>_SHADOW`** schemas via a `generate_schema_name` override in dbt-fes-ae (or the equivalent Fusion config).
- Both draw from the same dev sources at roughly the same time.

Ownership of `_SHADOW` schemas: `SVC_DBT_CLOUD_ROLE` from creation. No conflict with MWAA since MWAA doesn't touch them.

**NOT** the same as D26 (smoke model to `FES_USERS.ALEX_SOTIS`). Parallel-run writes to the **real dev target databases** (LOYALTY_DEV, FANAPP_DEV, etc.) with a `_SHADOW` schema suffix.

### 5b. Diff mechanic

`macros/diff_test/parallel_run_verify.sql` in dbt-fes-ae — takes a model or model list as arg. HASH_AGG-compares `<DB>.<SCHEMA>.<MODEL>` vs `<DB>.<SCHEMA>_SHADOW.<MODEL>` on a business-time window. Same methodology as `dbfork_final_verify.sql` (see `discoveries.md` D-16). Returns per-model match/mismatch + row counts.

### 5c. Cadence

- Loyalty (already diff-verified via dbfork per `loyalty-diff-runbook.md`) — parallel-run confirmation on dev is a smoke test, not a discovery exercise.
- Every other DAG — run parallel-run on dev for enough cycles to cover the DAG's schedule footprint (hourly → 24 runs; daily → 3-5 days; weekly → 2-3 cycles).
- Failure at any diff → back to the branch, fix, re-diff. No prod impact because nothing has merged.

### 5d. What "dev validation passed" means

Every DAG's dev parallel-run has passed `parallel_run_verify.sql` HASH_AGG match on its most-recent expected-scheduled runs, at which point the DAG's branch commit is considered dev-validated. The cutover PR ships only after *all* DAGs are dev-validated.

### 5e. Cost

Doubles dev compute + storage for the migration's dbt models. Bounded (dev warehouse credits are already fractional vs prod) and time-bounded (torn down when the cutover PR merges and `_SHADOW` schemas are dropped).

### 5f. Prod parallel-run — not required by D40

The single-cutover approach skips prod parallel-run entirely. Dev shadow diff is the equivalence proof; prod cutover is the flip. If dev-vs-prod source drift is a concern for any specific model, add a note in the cutover PR body and mitigate via a quick post-cutover diff query using Snowflake time travel.

---

## 6. Deploy job conventions

**One deploy job per fes-airflow DAG** (new **D35** in `decisions.md`). Naming: `<dag_name>` (e.g. `dbt_loyalty`, `dbt_daily`). Environment: `deployment` (or a new `deployment_parallel_run` for shadow-schema wave).

Steps per job (default): `dbt build --select tag:<tag>` where `<tag>` matches the current `tags=[...]` selector.

Custom-selector case: `dbt_fangraph` uses `selectors.yml` `custom_selector`. Job steps become `dbt build --selector custom_selector`. This works today with the `selectors.yml` already checked into `dbt-fes-ae` from PR #2.

Warehouse: `FDE_DBT_CLOUD_WH` (confirm exact name from Monday's TF PR — see `fusion-migration/monday-terraform-pr-spec.md`; the smoke model already ran on this warehouse per `discoveries.md` D-01). Grant on this warehouse is what the Monday TF PR adds.

Job triggers: **no schedule.** Every job is Airflow-triggered. dbt Cloud's UI shows "manually triggered" for every run; the `trigger_reason` field carries `dag_id / run_id` for traceability.

Job IDs land as module-level constants in each DAG file (per **D30** locked). We accumulate them in `projects/dbt_cloud_migration/deploy-jobs.md` as we create them, so the whole set is greppable.

**Job creation method: UI first, Terraform later.** D19 (from original decisions) proposed Terraform via `dbtcloud_job` provider — deferred in YOLO per `README.md` "Deferred until after prod cutover". YOLO creates jobs in the UI, records job IDs in `deploy-jobs.md`, and TF-ifies them post-cutover.

---

## 7. Sequencing on the long-lived branch

All work on `dbt-cloud-migration` (created 2026-07-12 from `main`). Every commit is dev-testable via `deploy_dev.yml` firing on PRs into the branch.

**Prerequisites merging to main separately** (these don't touch fes-airflow production DAG behavior):
1. **Monday TF PR merges** ([`monday-terraform-pr-spec.md`](fusion-migration/monday-terraform-pr-spec.md)). SVC_DBT_CLOUD_ROLE has warehouse USAGE + source-DB SELECT everywhere.
2. **dbt-fes-ae PR #4 merges** — parse-clean tree.

**On `dbt-cloud-migration` (all merge into the branch, never to main):**

3. **Helper module** — `dags/utils/dbt_cloud.py` (already committed 2026-07-12).
4. **Coupling test DAGs** — `dbt_cloud_coupling_test*.py` (already committed 2026-07-12). Execute test matrix on dev per `coupling-test-plan.md`.
5. **dbt-fes-ae parallel-run scaffolding** — `parallel_run` target + `generate_schema_name` shadow override + `parallel_run_verify.sql` macro. Merges to dbt-fes-ae main (that repo's changes don't affect fes-airflow prod).
6. **dbt Cloud deploy jobs created in UI** — one per DAG; job IDs recorded in `deploy-jobs.md`.
7. **Loyalty as first dev proof point** ([§9](#9-the-single-cutover-pr)) — rewrite `dbt_loyalty.py` on the branch to use the helper, run dev shadow-schema diff on the 4 ledgers, confirm HASH_AGG match. This is the smallest dev-validated slice.
8. **Rest of the DAGs in dev-first order (§2)** — each DAG rewritten on the branch, parallel-run diff validated on dev, latency profile logged.
9. **`dbt_fanflow` last** — includes cross-DAG sensor updates in the same commit (D37).
10. **Cleanup commits** — remove `dags/utils/dbt.py`, `dags/dbt/models/`, `dags/dbt/macros/`, drop `dbt-core` from `requirements/requirements.txt`, delete stale connection references.
11. **Ownership-transfer SQL** — drafted as `sql/cutover_ownership_transfer.sql` on the branch (per `permissions.md`). NOT run during branch development — only executed at cutover moment.
12. **Rollback SQL** — drafted as `sql/cutover_rollback.sql` on the branch. Reverse ownership transfer + role-hierarchy revocation.
13. **Cutover PR** — `dbt-cloud-migration` → `main`. See §9.

**No mid-development merges to main.** Zero exceptions until dev validation is fully green.

---

## 8. Prerequisites checklist

Before opening the cutover PR (§9):

- [ ] Monday TF PR merged (warehouse USAGE + source-DB SELECT to SVC_DBT_CLOUD_ROLE)
- [ ] dbt-fes-ae PR #4 merged (Fusion parse-clean tree)
- [ ] `apache-airflow-providers-dbt-cloud==3.8.1` in `requirements/requirements.txt` on the `dbt-cloud-migration` branch (branch will land it on prod MWAA at cutover)
- [ ] SSM `/airflow/connections/dbt_cloud_ae` populated for prod (currently `change me` — populate via Datadog Self Service in the same window as cutover PR merge)
- [ ] dbt-fes-ae `parallel_run` target + shadow schema macro + `parallel_run_verify.sql` all in main
- [ ] All dbt Cloud deploy jobs created (one per DAG per D35). Job IDs recorded in `deploy-jobs.md`.
- [ ] Every migrated DAG rewritten on `dbt-cloud-migration` and dev-validated (HASH_AGG diff green over the DAG's expected schedule footprint)
- [ ] Coupling test matrix executed on dev (per `coupling-test-plan.md`) — H1 or H2 SUCCESS, F1 fails-loudly-and-cleanly
- [ ] `sql/cutover_ownership_transfer.sql` present on branch, syntactically validated via `EXPLAIN`
- [ ] `sql/cutover_rollback.sql` present on branch, syntactically validated
- [ ] Comms sent to #fes-data-analytics-support with cutover window
- [ ] Rollback rehearsal on dev — revert a mock cutover commit, confirm MWAA resumes writing prod schemas without conflict (role hierarchy safety net working as designed per D21)

---

## 9. The single cutover PR

The cutover is one PR from `dbt-cloud-migration` → `main`. When it merges, every migrated DAG stops running on MWAA-dbt-core and starts running on Airflow-triggered dbt Cloud.

### 9a. PR contents

The branch already carries everything (per §7). At merge moment the diff shows:
- All `dbt_*.py` DAGs (except deferred `dbt_fangraph` and `dbt_full_refresh`) rewritten to call `dbt_cloud.create_dbt_cloud_task_group`
- `dags/utils/dbt_cloud.py` helper module
- `dags/airflow_ops/dbt_cloud_coupling_test*.py` — if kept, they merge to prod harmlessly (dev-only tags but no scheduled runs in prod). Alternatively strip them before merging if reviewer prefers clean prod tree.
- `dags/utils/dbt.py` deleted (or nearly-empty stub if any un-migrated DAGs still reference it)
- `dags/dbt/models/`, `dags/dbt/macros/`, `dags/dbt/packages/` deleted
- `requirements/requirements.txt` — `dbt-core` removed, `apache-airflow-providers-dbt-cloud==3.8.1` present
- Deletion of pure-dbt Airflow DAGs (`dbt_loyalty`, `dbt_fanflow`, `dbt_xtremepush`, `dbt_fangraph`, `dbt_full_refresh`, and the ~16 other tag-only DAGs listed in D41). `dbt_loyalty_6hours` KEPT — it has ingest sensors.
- Cross-DAG dbt-to-dbt chains configured in dbt Cloud via `job_completion_trigger_condition` (per D41 — see `deploy-jobs.md` for job IDs; e.g. prod `dbt_loyalty` job `70437463791501` chains from prod `dbt_fanflow` job `70437463791505`, status=10)

### 9b. PR body must include

- **Rollback SQL** — verbatim `sql/cutover_rollback.sql` from the branch
- **Ownership-transfer SQL** — verbatim `sql/cutover_ownership_transfer.sql`, run manually before merge
- **List of migrated DAGs** with their dbt Cloud job IDs (copied from `deploy-jobs.md`)
- **Dev validation summary** — per-DAG parallel-run diff result, coupling-test matrix outcome, latency profile
- **Prod cutover checklist** — SSM prod value populated, prod MWAA env sync confirmed, role hierarchy grant applied, `#fes-data-analytics-support` comms sent

### 9c. Cutover-moment SQL sequence

Execute via `snow sql` in this order:

**Step 1 — Role hierarchy safety net** (per D21):
```sql
GRANT ROLE SVC_DBT_CLOUD_ROLE TO ROLE SVC_MWAA_ROLE;
```

**Step 2 — Ownership transfer** (`sql/cutover_ownership_transfer.sql`, per D20/D40):
```sql
USE ROLE ACCOUNTADMIN;

-- Loyalty family
GRANT OWNERSHIP ON TABLE LOYALTY.LOYALTY_CORE.LOYALTY_STATE
    TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER
    TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE LOYALTY.LOYALTY_CORE.LOYALTY_EARN_BURN_MAPPER
    TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE LOYALTY.LOYALTY_CORE.LOYALTY_BALANCE
    TO ROLE SVC_DBT_CLOUD_ROLE COPY CURRENT GRANTS;

-- ... every other migrated table, generated from `dbt ls --resource-type model`
-- against the migration's selector coverage. Complete list on the branch.
```

MWAA retains SELECT on all migrated tables via the role-hierarchy grant, so any non-dbt Airflow tasks that read from these tables keep working.

**Step 3 — Merge the PR to main.** This lands the DAG changes on prod MWAA via `deploy_prod.yml`.

**Step 4 — Populate prod SSM value** — Datadog Self Service updates `/airflow/connections/dbt_cloud_ae` from `change me` to the prod-scoped token (per D27).

**Step 5 — Watch the first hourly runs** in dbt Cloud + Airflow UI.

### 9d. Rollback

Full rollback SQL is in `sql/cutover_rollback.sql` on the branch. Reverses step 2 (transfers ownership back to `SVC_MWAA_ROLE COPY CURRENT GRANTS`) and, if desired, revokes step 1's role hierarchy.

Then: `git revert <cutover-commit>` on main and push → MWAA resumes dbt-core execution on the next scheduled tick.

---

## 10. Rollback

Single-PR rollback contract, in priority order:

1. **Revert the cutover PR** on main (`git revert <cutover-commit>`, push). Restores MWAA-run dbt-core for every migrated DAG. Takes effect on the next MWAA sync (deploy_prod.yml re-syncs dags/ on push to main).
2. **Optional: revert ownership** via `sql/cutover_rollback.sql` on the branch. Only strictly necessary if the role hierarchy grant is ALSO revoked. As long as `SVC_MWAA_ROLE` has `SVC_DBT_CLOUD_ROLE` granted to it (per D21 safety net), MWAA can `CREATE OR REPLACE` the tables via inherited ownership without ownership reversal.
3. **Leave deploy jobs in place.** They do nothing if Airflow isn't triggering them.
4. **Leave dbt-fes-ae parse cleanups and helpers in place.** They cause no harm.
5. **Post-rollback investigation** — re-open a follow-up PR on `dbt-cloud-migration` (or a new branch) to fix whatever failed, re-run dev validation, then re-attempt cutover.

Total rollback: single PR revert + optional SQL execution = ~15 minutes to restore prior state.

---

## Appendix: what's NOT in this playbook

- `dbt_fangraph` cutover. 211 models, source() refs that don't defer cleanly in Fusion. Separate design session (deferred per `README.md`).
- **Terraform-ifying dbt Cloud deploy jobs.** Post-cutover work (per D19 recommendation + yolo defer). `dbtcloud_job` provider exists but not adopted here.
- **CI on PRs** (dbt Cloud "CI job"). Post-cutover (per D40/README).
- **Deletion of `utils.dbt.py` and `dags/dbt/models/`** in fes-airflow. Bundled into the single cutover PR per D40 §7.
- **Alerting migration** to FireHydrant tiers (per **D24** — single Slack channel initially). Keep the existing `callbacks.dag_failure_callback_p*` on the new DAGs — they still work because they fire on the Airflow DAG's outcome, which now = dbt Cloud run's outcome via the sensor.
- **Mesh split** (per **D23** — deferred to Q4).
- **`analytics` repo extraction** (per D2 + D23 — deferred). Everything stays in `dbt-fes-ae` for now.
