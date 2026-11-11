# DAG Conversion Inventory

> **⚠️ Historical — superseded by D41 (2026-07-13, extended 2026-07-19).** This file was written under the premise "each `dbt_*.py` DAG becomes a thin dbt Cloud wrapper." D41 revised that: pure dbt DAGs (no ingest/export coupling) are **deleted from Airflow entirely**. Their dbt Cloud jobs run on native cron.
>
> **Retained-in-Airflow with dbt Cloud handshake (9 DAGs):**
> - `dbt_loyalty_6hours` (SqlSensor + ExternalTaskSensor on ingest signals — migrated 2026-07-13)
> - 8 ingest-coupled DAGs (`fanapp_mdm`, `google_ad_manager`, `cassandra_extract`, `impact`, `loyalty_bonus_postgres_to_s3_ingest`, `loyalty_postgres_to_s3_ingest`, `magnite_dag`, `sfmc_optin_preferences_import`) — migration plan in [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md), added 2026-07-19 after audit gap identified.
>
> Cross-DAG dbt-to-dbt sensor mappings in this doc are also historical — under D41 those chains now live in dbt Cloud via `job_completion_trigger_condition` between the sibling jobs. See updated `cutover-playbook.md` §3.
>
> **Current source of truth**: `deploy-jobs.md` (22 standalone-DAG jobs + 8 pending ingest-DAG jobs), `decisions.md` (D41), and `dbt-in-airflow-removal.md` (ingest-DAG migration).

## Inventory (historical — pre-D41)

| # | DAG file | Model tag (selector) | Prod schedule | Callback tier | External sensor IN | Needs `steps_override`? (per `data-interval-usage.md`) | Dev-first order |
|---|---|---|---|---|---|---|---|
| 1 | `dbt_loyalty.py` | `loyalty` | `0 * * * *` (hourly) | P2 | ExternalTaskSensor on `dbt_fanflow.model.fes_data.loyalty_transaction_successful__account` (40m timeout, 5m poke) — becomes `dbt_fanflow.dbt_fanflow.log_run` post-cutover per D37 | **YES** — loyalty tag matches models using `data_interval_end` | **1** (ledger diff proven) |
| 2 | `dbt_sources.py` | `sources` (source freshness — special) | ? see file | P3 | none | Source freshness only — no dbt build; TBD if helper applies at all | **2** |
| 3 | `dbt_hourly.py` | `hourly` | ? see file | P2 | none | ? (grep tag:hourly for context-var models) | **3** |
| 4 | `dbt_daily.py` | `daily` | `0 8 * * *` | P3 | none | **YES** — 3 models with `daily` tag use context vars | **4** |
| 5 | `dbt_daily_9am.py` | `daily_9am` | `0 13 * * *` | P3 | none | ? | **4** |
| 6 | `dbt_every_3hours.py` | `3hours` (note: not `every_3hours`) | `0 */3 * * *` | P3 | none | ? | **4** |
| 7 | `dbt_every_6hours.py` | `6hours` (note: not `every_6hours`) | `0 */6 * * *` | P3 | none | ? | **4** |
| 8 | `dbt_weekly.py` | `weekly` | weekly | P3 | none | ? | **4** |
| 9 | `dbt_loyalty_6hours.py` | `loyalty_6hours` | `0 5,11,17,23 * * *` | P2 (DAG) + P1 (task-level for bonus_fancash tasks) | ExternalTaskSensor on `loyalty_bonus_fancash_incremental` DAG | **YES** likely | **5** |
| 10 | `dbt_loyalty_metrics.py` | `loyalty_metrics` | ? see file | **P3** (not P2 as I earlier said) | none | **YES** — 11 metrics models use context vars | **5** |
| 11 | `dbt_loyalty_balance_monthly_snapshot.py` | `loyalty_monthly` (note: not `loyalty_balance_snapshot`) | monthly | P3 | none | ? | **5** |
| 12 | `dbt_enterprise_metrics.py` | `enterprise_metrics` | ? see file | P3 | none | ? (grep tag:enterprise_metrics for context vars) | **5** |
| 13 | `dbt_enterprise_metrics_daily.py` | `enterprise_metrics_daily` | daily | P3 | none | ? | **5** |
| 14 | `dbt_mde.py` | `mde` | ? see file | P3 | none | ? | **5** |
| 15 | `dbt_meta_ads.py` | `meta_ads` | `0 4 * * *` | P3 | none | ? | **5** |
| 16 | `dbt_xtremepush.py` | `xtremepush` | ? see file | P3 | ExternalTaskSensor on `dbt_fangraph.model.fes_data.pfi_fangraph` → becomes `dbt_fangraph.dbt_fangraph.log_run` per D37 (but fangraph is DEFERRED — this sensor may need alternate wiring) | ? — xtremepush models have their own `optin_preferences` tag; verify tag mapping | **5** |
| 17 | `dbt_fanatics_one.py` | `fanaticsone` (note: not `fanatics_one`) | ? see file | **P2** (not P?) | none | **YES** — 2 fanaticsone models use context vars | **5** |
| 18 | `dbt_fanapp_recs.py` | `fanapp_recs` | ? see file | P3 | none | ? | **5** |
| 19 | `dbt_ltv.py` | `ltv` | ? see file | P3 | none | ? | **5** |
| 20 | `dbt_users.py` | `users` | ? see file | P3 (DAG) + custom `dbt_users_failure_slack_callback` per task | none | ? | **5** |
| 21 | `dbt_fanflow.py` | `fanflow` | ? see file | P2 | none | ? — **downstream dependents:** `dbt_loyalty.wait_for_fanflow_loyalty`, `xtremepush_tier_change_events`, `loyalty_fcc_slim_ledger`, `loyalty_kyros_data_transfer`, `salesforce_marketing_cloud_fanatics_one`, `salesforce_marketing_cloud_fancash_export` all sensor on this DAG's models → update to `dbt_fanflow.dbt_fanflow.log_run` per D37 in the same commit | **6** |
| 22 | `dbt_fangraph.py` | `fangraph` (custom_selector in selectors.yml) | ? see file | P2 | 2 ExternalTaskSensors on `dbt_every_6hours.model.fes_data.fan_key_master_pii` and `fan_key_account_map` | ? | **DEFERRED** — separate design |
| 23 | `dbt_full_refresh.py` | one-shot manual | manual only | — | — | — | Skip (manual utility) |

## Cross-DAG sensor update matrix (historical — pre-D41)

> **This table is superseded by D41.** Under the current architecture, the "Becomes" column no longer applies for dbt-to-dbt chains — those chains move to dbt Cloud via `job_completion_trigger_condition`. Export/integration DAGs that used to sensor on dbt DAGs no longer sensor on anything (see `decisions.md` D41: "Export/integration DAGs that used to sensor on deleted DAGs' log_run tasks now have no sensor. Future gating: time-based schedule + retries, OR custom sensor polling dbt Cloud API for latest run status. Each has a `TODO(dbt-cloud-migration)` comment.").
>
> Retained for context only.

| Dependent DAG | Was pointing at | Becomes |
|---|---|---|
| `dbt_loyalty.wait_for_fanflow_loyalty_transaction_successful__account` | `dbt_fanflow.model.fes_data.loyalty_transaction_successful__account` | `dbt_fanflow.dbt_fanflow.log_run` |
| `dbt_loyalty_6hours.<sensor>` | `loyalty_bonus_fancash_incremental.<task>` (not a dbt DAG) | Unchanged — bonus_fancash is a separate DAG, stays as-is |
| `dbt_xtremepush.wait_for_pfi_fangraph` | `dbt_fangraph.model.fes_data.pfi_fangraph` | **BLOCKED** — fangraph is deferred. Options: (a) keep pointing at old task (works because fangraph still runs dbt-core), (b) re-scope xtremepush's dependency, (c) wait to cut over xtremepush until fangraph is migrated. Decision needed. |
| `dbt_fangraph.<2 sensors>` | `dbt_every_6hours.model.fes_data.fan_key_master_pii` + `fan_key_account_map` | `dbt_every_6hours.dbt_every_6hours.log_run` (once dbt_every_6hours is migrated) — but fangraph itself is deferred, so this update only matters if fangraph is later included |
| `lids_loyalty_report.<sensor>` | `dbt_loyalty.dbt_loyalty_group.model.fes_data.lids_loyalty_redeems` | `dbt_loyalty.dbt_loyalty.log_run` |
| `xtremepush_tier_change_events.<sensor>` | `dbt_loyalty.model.fes_data.tier_points_marketing_triggers` | `dbt_loyalty.dbt_loyalty.log_run` |
| `loyalty_fcc_slim_ledger.<3 sensors>` | 3 different `dbt_loyalty` model tasks | `dbt_loyalty.dbt_loyalty.log_run` (single sensor, coarse wait per D37) |
| `loyalty_kyros_data_transfer.<2 sensors>` | 2 `dbt_loyalty` model tasks | `dbt_loyalty.dbt_loyalty.log_run` (single sensor) |
| `salesforce_marketing_cloud_fanatics_one.<sensor>` | `dbt_loyalty.model.fes_data.tier_ledger` | `dbt_loyalty.dbt_loyalty.log_run` |
| `salesforce_marketing_cloud_daily.<sensor>` | `dbt_fanapp.model.fes_data.fanapp_install_sources` — but `dbt_fanapp` doesn't exist in current inventory! Verify | ? |
| `salesforce_marketing_cloud_fancash_export.<sensor>` | `dbt_loyalty.model.fes_data.loyalty_balance_snapshot` | `dbt_loyalty.dbt_loyalty.log_run` (or `dbt_loyalty_balance_monthly_snapshot.dbt_loyalty_balance_monthly_snapshot.log_run` — verify which DAG owns that model) |

## Conversion template

For a DAG with no external sensor + no context vars (e.g. `dbt_daily`):

```python
import pendulum
from airflow.decorators import dag
from utils import args, callbacks, config
from utils.dbt_cloud import create_dbt_cloud_task_group

DOC_MD = """..."""

# TODO: fill in from deploy-jobs.md once dbt Cloud UI job created
DBT_CLOUD_DAILY_JOB_ID = 0

@dag(
    default_args=args.get_default_args(),
    start_date=pendulum.datetime(2024, 10, 1, tz="America/New_York"),
    description="run dbt model via dbt Cloud",
    on_failure_callback=callbacks.dag_failure_callback_p3,
    on_success_callback=callbacks.dag_success_callback_p3,
    schedule_interval=config.get_value_for_env(dev=None, prod="0 8 * * *"),
    catchup=False,
    doc_md=DOC_MD,
    tags=["dbt", "daily"],
)
def dbt_daily():
    create_dbt_cloud_task_group(
        group_id="dbt_daily",
        job_id=DBT_CLOUD_DAILY_JOB_ID,
        steps_override=[
            'dbt build --select tag:daily --vars \''
            '{"data_interval_start": "{{ data_interval_start | ts }}", '
            '"data_interval_end": "{{ data_interval_end | ts }}", '
            '"ds_nodash": "{{ data_interval_start | ds_nodash }}"}\''
        ],
    )

dag = dbt_daily()
```

For a DAG with external sensor (e.g. `dbt_loyalty`), wire the sensor before the group.

## Callback semantics under D40

The existing `dag_failure_callback_p*` and `dag_success_callback_p*` on the DAG-level fire against the DAG's outcome. Post-migration:
- Success = dbt Cloud run success + sensor released + `log_run` fired
- Failure = trigger error, sensor timeout, dbt Cloud job Error state, or `log_run` failure

No callback rewiring required. Task-level callbacks (e.g. `dbt_users_failure_slack_callback`, `dbt_loyalty_6hours` P1 task callbacks) are lost when the per-model BashOperators disappear — replaced by dbt Cloud's own notification system + the coarse DAG-level callback. **Decision needed for these DAGs — do we accept the coarsening or wire per-model notifications differently?**
