# Phase 0 §0.5 — Per-DAG migration blueprint (before / after)

Companion to [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md). This is the exact Phase 2 blueprint the engineer follows when editing each of the 8 DAGs.

**Repo state audited**: `~/repos/fes-airflow` @ branch `dbt-cloud-migration`. **All 8 DAGs read in full 2026-07-19.**

## Cross-cutting findings (open questions from `dbt-in-airflow-removal.md` — resolved)

| # | Question | Resolution |
|---|---|---|
| Q1 | Tag collisions between ingest and standalone tags? | **None.** `dbt ls` for each of the 8 ingest tags returned zero models tagged with any other job's selector. See [`dbt-in-airflow-removal-model-lists.md`](dbt-in-airflow-removal-model-lists.md). |
| Q2 | `optin_preferences` overlap with `dbt_xtremepush` (job `70437463791519`)? | **False alarm.** `dbt_xtremepush` selects `tag:xtremepush`. All 6 `optin_preferences`-tagged models (`xp_optin_preferences*`, `xp_push_last_opened*`) are tagged ONLY `optin_preferences`, not `xtremepush`. |
| Q3 | `fesloyalty` overlap with `dbt_loyalty` (job `70437463791501`)? | **False alarm.** No `fesloyalty`-tagged model also carries `loyalty`. 25 models exclusive to `fesloyalty`. |
| Q4 | `build_flag=True` semantics on `fesloyalty`? | Correct — MWAA maps this to `dbt build`. Cloud's default step for a new job is `dbt build --select tag:<tag>`. **Delete the flag; no override needed.** |
| Q5 | `compare_row_counts()` in loyalty ingests — runs before or after dbt? | Runs **after** (`bonus_dbt >> compare_task`, `loyalty_dbt >> compare_task`). Preserved by the new `run_dbt_* >> compare_task` wiring. |
| Q6 | Seed dependencies? | **None.** All 8 tag model sets have zero seed refs. No pre-load ceremony. |
| **Q7 (new)** | Any external ExternalTaskSensor targets on these 8 DAGs or their internal dbt task-groups? | **None.** `grep external_dag_id` over `dags/` finds zero hits for any of the 8 dag_ids and zero hits on the 8 dbt-task-group names. Migration is contained. |
| **Q8 (new)** | Do any of the 8 tag model sets consume `data_interval_*` at build time? | **YES — for 2 of the 8**: `identity` (2 models: `loyalty_private_fan_id_map`, `martech_private_fan_id_map` use `var('data_interval_start')`) and `optin_preferences` (4 models: `xp_optin_preferences_delta/snapshot`, `xp_push_last_opened_delta/snapshot` use `var('data_interval_end')`). Both DAGs MUST pass `steps_override=[...]` to `create_dbt_cloud_task_group`. The other 6 DAGs don't need it. See [`dbt-in-airflow-removal-context-var-scan.md`](dbt-in-airflow-removal-context-var-scan.md). |

## Summary table (all 8 DAGs at a glance)

| # | DAG file | dag_id | Current schedule (prod) | tag | Cur. task-group name | build_flag | needs steps_override? | Downstream tasks | Post-cutover callback tier |
|---|---|---|---|---|---|---|---|---|---|
| §2.1 | `fanapp/fanapp_mdm.py` | `fanapp_mdm` | `0 8 * * *` | `mdm_sdp` | `dbt_mdm_sdp` | (default `False`) | no | 3× `SQLExecuteQueryOperator` (fanout) | p3 |
| §2.2 | `google_ad_manager/google_ad_manager.py` | `google_ad_manager` | `0 8 * * *` | `google_ad_manager` | `dbt_google_ad_manager` | (default `False`) | no | — (dbt is terminal) | p3 |
| §2.3 | `identity/cassandra_extract.py` | `cassandra_extract` (implicit from fn name) | `0 6 * * *` | `identity` | `identity_dbt` | (default `False`) | **YES** | — | p2 |
| §2.4 | `impact/impact.py` | `impact` | `0 8 * * *` | `impact` | `dbt_impact` | (default `False`) | — | — | p3 |
| §2.5 | `loyalty/loyalty_bonus_postgres_to_s3_ingest.py` | `loyalty_bonus_postgres_to_s3_ingest` | `5 * * * *` (hourly) | `fesbonus` | `bonus_dbt` | (default `False`) | no | `compare_row_counts` @task | p2 |
| §2.6 | `loyalty/loyalty_postgres_to_s3_ingest.py` | `loyalty_postgres_to_s3_ingest` | `5 * * * *` (hourly) | `fesloyalty` | `loyalty_dbt` | **`True`** — delete under Cloud | no | `compare_row_counts` @task | p2 |
| §2.7 | `magnite/magnite_dag.py` | `magnite_curate` | `0 8 * * *` | `magnite` | `dbt_magnite` | (default `False`) | no | — | p3 |
| §2.8 | `salesforce/sfmc_optin_preferences_import.py` | `sfmc_optin_preferences_import` | `30 10 * * *` (has `end_date=2026-06-09` — **TEMPORARY DAG**) | `optin_preferences` | `dbt_optin_preferences_group` | (default `False`) | **YES** | — | p3 |

**Total**: 8 dbt Cloud jobs to provision. 2 require `steps_override`. 1 has a `build_flag=True` to remove. **No** namespace shifts (all use `namespace="fes-airflow"` which is a MWAA-only concept). **No** external ExternalTaskSensor updates needed.

## Migration template (applied identically to all 8)

```python
# ── imports ──────────────────────────────
# DELETE:
#   from utils import ..., dbt
# ADD:
#   from utils import ..., config     # if config not already imported
#   from utils.dbt_cloud import create_dbt_cloud_task_group

# ── constants (top of file) ──────────────
DBT_CLOUD_<UPPER>_JOB_ID = config.get_value_for_env(
    dev=<from §1.2 output>,
    prod=<from §1.2 output>,
)

# DELETE:
#   DBT_PATH = "/usr/local/airflow/dags/dbt/"

# ── in the DAG body, replace ────────────
# BEFORE:
#   with TaskGroup("<group_name>") as <var>:
#       dbt.create_dbt_dag(
#           dbt.DBT_PATH,              # or DBT_PATH,
#           namespace="fes-airflow",
#           allow_empty_upstream=True,
#           tags=["<tag>"],
#           auth_env={...},            # only some DAGs
#           skip_tests=False,
#           build_flag=True,           # only loyalty_postgres_to_s3_ingest
#       )
#
# AFTER:
#   <var> = create_dbt_cloud_task_group(
#       group_id="<group_name>",       # PRESERVE — same as MWAA TaskGroup name
#       job_id=DBT_CLOUD_<UPPER>_JOB_ID,
#       # steps_override=[...]         # ONLY for identity + optin_preferences (see §2.3 / §2.8)
#   )
```

**What each removed kwarg maps to under Cloud** (memoize for consistency across all 8):

| Removed | Why |
|---|---|
| `dbt.DBT_PATH` / `DBT_PATH` | Cloud manages the project dir. No path. |
| `namespace="fes-airflow"` | MWAA task-group namespace. Not modeled by Cloud. `group_id=` replaces it. |
| `allow_empty_upstream=True` | Cloud validates selectors at job creation; nothing to guard at runtime. |
| `tags=["<tag>"]` | The selector is baked into the Cloud job's `execute_steps` (`dbt build --select tag:<tag>`). Not passed at trigger time. |
| `auth_env={...}` | Cloud handles credentials at the project level via `SVC_DBT_CLOUD_ROLE` keypair. |
| `skip_tests=False` | Cloud's `dbt build` includes tests by default; if we ever wanted to skip we'd override the step, not pass a flag. |
| `build_flag=True` (§2.6 only) | Cloud default step is `dbt build`. `build_flag` in MWAA was `dbt build` vs `dbt run` — matches Cloud default. |
| Outer `with TaskGroup(...) as x:` wrapper | `create_dbt_cloud_task_group()` IS the TaskGroup — it returns one. No wrapper needed. |

---

## §2.1 fanapp_mdm.py

**Path**: `dags/fanapp/fanapp_mdm.py`  •  **dag_id**: `fanapp_mdm`  •  **tag**: `mdm_sdp`  •  **models**: 3 (`mdm_to_sdp_leagues`, `mdm_to_sdp_players`, `mdm_to_sdp_teams`)  •  **prod schedule**: `0 8 * * *`  •  **callback tier**: p3  •  **DAG-level tags**: `["snowflake", "fangraph"]` (Airflow UI tagging — unchanged; not related to dbt selectors)

### Before (relevant fragments)

```python
from utils import args, callbacks, config, dbt

@dag(...)
def fanapp_mdm():
    fde_database = config.get_value_for_env(...)   # kept
    mde_database = config.get_value_for_env(...)   # kept
    xl_warehouse = config.get_value_for_env(...)   # kept
    stage = config.get_value_for_env(...)          # kept

    with TaskGroup("dbt_mdm_sdp") as dbt_mdm_sdp:
        dbt.create_dbt_dag(
            dbt.DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["mdm_sdp"],
            auth_env={...snowflake_service_user...},
            skip_tests=False,
        )

    extract_mdm_sdp_team_mapping = SQLExecuteQueryOperator(...)
    extract_mdm_sdp_league_mapping = SQLExecuteQueryOperator(...)
    extract_mdm_sdp_player_mapping = SQLExecuteQueryOperator(...)

    dbt_mdm_sdp >> [
        extract_mdm_sdp_team_mapping,
        extract_mdm_sdp_league_mapping,
        extract_mdm_sdp_player_mapping,
    ]
```

### After

```python
from utils import args, callbacks, config
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_FANAPP_MDM_JOB_ID = config.get_value_for_env(
    dev=<TBD from §1.2>,
    prod=<TBD from §1.2>,
)

@dag(...)
def fanapp_mdm():
    fde_database = config.get_value_for_env(...)   # unchanged
    mde_database = config.get_value_for_env(...)   # unchanged
    xl_warehouse = config.get_value_for_env(...)   # unchanged
    stage = config.get_value_for_env(...)          # unchanged

    dbt_mdm_sdp = create_dbt_cloud_task_group(
        group_id="dbt_mdm_sdp",
        job_id=DBT_CLOUD_FANAPP_MDM_JOB_ID,
    )

    extract_mdm_sdp_team_mapping = SQLExecuteQueryOperator(...)   # unchanged
    extract_mdm_sdp_league_mapping = SQLExecuteQueryOperator(...) # unchanged
    extract_mdm_sdp_player_mapping = SQLExecuteQueryOperator(...) # unchanged

    dbt_mdm_sdp >> [
        extract_mdm_sdp_team_mapping,
        extract_mdm_sdp_league_mapping,
        extract_mdm_sdp_player_mapping,
    ]
```

### Notes

- **Wiring is verbatim** — `dbt_mdm_sdp` still refers to a TaskGroup, and the 3 extract tasks still fan out after it.
- The `SQLExecuteQueryOperator` downstream tasks read Snowflake tables the dbt models just built. They stay in MWAA (they're pure Snowflake SQL, not dbt).
- All 3 dbt-fes-ae models reference `{{ var(...) }}` for static config vars (team/league IDs, e.g. `mdm_cd_tenerife_team_id`). These are declared in `dbt_project.yml` — **project-scoped**, resolved at parse time, no `steps_override` needed.

---

## §2.2 google_ad_manager.py

**Path**: `dags/google_ad_manager/google_ad_manager.py`  •  **dag_id**: `google_ad_manager`  •  **tag**: `google_ad_manager`  •  **models**: 9  •  **prod schedule**: `0 8 * * *`  •  **callback tier**: p3

### Before

```python
from utils import args, callbacks, config, constants, dbt

DBT_PATH = "/usr/local/airflow/dags/dbt/"

# Reports are chained sequentially (GAM API can't handle concurrent report requests).
with DAG(dag_id="google_ad_manager", ...) as dag:
    previous_tg = None
    for report in REPORTS:
        with TaskGroup(group_id=f"report_{report['name']}") as tg:
            extract_to_s3 = PythonOperator(...)
        if previous_tg is not None:
            previous_tg >> tg
        previous_tg = tg

    with TaskGroup(group_id="dbt_google_ad_manager") as dbt_gam:
        dbt.create_dbt_dag(
            DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["google_ad_manager"],
            skip_tests=False,
        )

    previous_tg >> dbt_gam
```

### After

```python
from utils import args, callbacks, config, constants
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_GOOGLE_AD_MANAGER_JOB_ID = config.get_value_for_env(
    dev=<TBD>,
    prod=<TBD>,
)

# DELETE: DBT_PATH constant

with DAG(dag_id="google_ad_manager", ...) as dag:
    previous_tg = None
    for report in REPORTS:
        with TaskGroup(group_id=f"report_{report['name']}") as tg:
            extract_to_s3 = PythonOperator(...)
        if previous_tg is not None:
            previous_tg >> tg
        previous_tg = tg

    dbt_gam = create_dbt_cloud_task_group(
        group_id="dbt_google_ad_manager",
        job_id=DBT_CLOUD_GOOGLE_AD_MANAGER_JOB_ID,
    )

    previous_tg >> dbt_gam
```

### Notes

- 9 report task-groups chain sequentially. Terminal TaskGroup is `previous_tg`; dbt runs after.
- No downstream export tasks — dbt is terminal.
- `google_ad_manager` tag models don't use `var(...)` — clean, no `steps_override`.

---

## §2.3 cassandra_extract.py  ⚠ needs steps_override

**Path**: `dags/identity/cassandra_extract.py`  •  **dag_id**: `cassandra_extract`  •  **tag**: `identity`  •  **models**: 5 (2 of which use `var('data_interval_start')`)  •  **prod schedule**: `0 6 * * *`  •  **callback tier**: p2

### Before

```python
from utils import args, callbacks, config, dbt

DBT_PATH = "/usr/local/airflow/dags/dbt/"

@dag(...)
def cassandra_extract():
    tables = discover_tables()
    extraction_results = extract_table.expand(table_info=tables)
    summarize_results(extraction_results)  # call 1 (result-binding)

    with TaskGroup("identity_dbt") as identity_dbt:
        dbt.create_dbt_dag(
            DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["identity"],
            auth_env={...},
            skip_tests=False,
        )

    summarize_results(extraction_results) >> identity_dbt   # call 2 (wiring)
```

### After

```python
from utils import args, callbacks, config
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_IDENTITY_JOB_ID = config.get_value_for_env(
    dev=<TBD>,
    prod=<TBD>,
)

# DELETE: DBT_PATH constant

@dag(...)
def cassandra_extract():
    tables = discover_tables()
    extraction_results = extract_table.expand(table_info=tables)
    summarize_results(extraction_results)  # call 1 preserved

    identity_dbt = create_dbt_cloud_task_group(
        group_id="identity_dbt",
        job_id=DBT_CLOUD_IDENTITY_JOB_ID,
        steps_override=[
            'dbt build --select tag:identity --vars \''
            '{"data_interval_start": "{{ data_interval_start | ts }}", '
            '"data_interval_end": "{{ data_interval_end | ts }}", '
            '"ds_nodash": "{{ data_interval_start | ds_nodash }}"}\''
        ],
    )

    summarize_results(extraction_results) >> identity_dbt
```

### Notes

- ⚠ **MUST pass `steps_override`** — `models/identity/orchestration/loyalty_private_fan_id_map.sql` and `martech_private_fan_id_map.sql` both call `{{ var('data_interval_start') }}`. Without `--vars`, they'll fail at compile time (missing var).
- `steps_override` payload mirrors the exact MWAA-side injection from `dags/utils/dbt.py:111-113` (`data_interval_start | ts`, `data_interval_end | ts`, `ds_nodash`) — preserves runtime behavior 1:1.
- Note: the DAG has a redundant duplicate call to `summarize_results(extraction_results)` on the wiring line. This is a **pre-existing quirk** (calls the @task decorator twice, generating two operator instances with the same task_id → Airflow deduplicates). Leaving as-is under the migration scope; do not conflate with cleanup.
- The 3 `@task` operators (`discover_tables`, `extract_table.expand(...)`, `summarize_results(extraction_results)`) all stay unchanged. `extract_table` uses `data_interval_end` internally for S3 path formatting — that's Airflow context in Python, unrelated to dbt vars, unaffected by the migration.

---

## §2.4 impact.py

**Path**: `dags/impact/impact.py`  •  **dag_id**: `impact`  •  **tag**: `impact`  •  **models**: 1  •  **prod schedule**: `0 8 * * *`  •  **callback tier**: p3

### Before

```python
from utils import args, callbacks, config, constants, dbt

DBT_PATH = "/usr/local/airflow/dags/dbt/"

with DAG(dag_id="impact", ...) as dag:
    export_to_s3 = PythonOperator(...)
    s3_to_snowflake_sql = SQLExecuteQueryOperator(...)

    with TaskGroup("dbt_impact") as dbt_impact:
        dbt.create_dbt_dag(
            DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["impact"],
            auth_env={...},
            skip_tests=False,
        )

    export_to_s3 >> s3_to_snowflake_sql >> dbt_impact
```

### After

```python
from utils import args, callbacks, config, constants
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_IMPACT_JOB_ID = config.get_value_for_env(
    dev=<TBD>,
    prod=<TBD>,
)

# DELETE: DBT_PATH constant

with DAG(dag_id="impact", ...) as dag:
    export_to_s3 = PythonOperator(...)
    s3_to_snowflake_sql = SQLExecuteQueryOperator(...)

    dbt_impact = create_dbt_cloud_task_group(
        group_id="dbt_impact",
        job_id=DBT_CLOUD_IMPACT_JOB_ID,
    )

    export_to_s3 >> s3_to_snowflake_sql >> dbt_impact
```

### Notes

- Linear chain — 2 upstream operators, dbt terminal.
- Single-model tag — Cloud job takes 1 model.

---

## §2.5 loyalty_bonus_postgres_to_s3_ingest.py

**Path**: `dags/loyalty/loyalty_bonus_postgres_to_s3_ingest.py`  •  **dag_id**: `loyalty_bonus_postgres_to_s3_ingest`  •  **tag**: `fesbonus`  •  **models**: 8  •  **prod schedule**: `5 * * * *` (hourly)  •  **callback tier**: p2  •  **notes**: has `Param(use_test_connection)` for dev-only PG cluster toggle — unchanged

### Before

```python
from utils import args, callbacks, config, dbt

@dag(...)
def loyalty_bonus_postgres_to_s3_ingest():
    get_backfill_flag_task = get_backfill_flag(...)
    load_tasks = []
    for table_config in BONUS_POSTGRES_TABLE_CONFIGS:
        load_task = SqlToS3Operator(...)
        get_backfill_flag_task >> load_task
        load_tasks.append(load_task)

    with TaskGroup("bonus_dbt") as bonus_dbt:
        dbt.create_dbt_dag(
            dbt.DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["fesbonus"],
            auth_env={...},
            skip_tests=False,
        )

    load_tasks >> bonus_dbt
    compare_task = compare_row_counts()
    bonus_dbt >> compare_task
```

### After

```python
from utils import args, callbacks, config
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_FESBONUS_JOB_ID = config.get_value_for_env(
    dev=<TBD>,
    prod=<TBD>,
)

@dag(...)
def loyalty_bonus_postgres_to_s3_ingest():
    get_backfill_flag_task = get_backfill_flag(...)
    load_tasks = []
    for table_config in BONUS_POSTGRES_TABLE_CONFIGS:
        load_task = SqlToS3Operator(...)
        get_backfill_flag_task >> load_task
        load_tasks.append(load_task)

    bonus_dbt = create_dbt_cloud_task_group(
        group_id="bonus_dbt",
        job_id=DBT_CLOUD_FESBONUS_JOB_ID,
    )

    load_tasks >> bonus_dbt
    compare_task = compare_row_counts()
    bonus_dbt >> compare_task
```

### Notes

- `compare_row_counts()` @task must run AFTER dbt (it validates counts against the just-built Snowflake source models). Preserved by `bonus_dbt >> compare_task`.
- `compare_row_counts` runs on the DAG-run scheduler pod, hits Postgres + Snowflake directly. **Not affected by migration.**
- 8 dbt models, none use `data_interval_*` vars — no `steps_override`.
- **Hourly** DAG — 24×/day. Cloud job needs a reasonable timeout budget (default 90 min in the helper is fine — bonus_dbt should complete in single-digit minutes).

---

## §2.6 loyalty_postgres_to_s3_ingest.py

**Path**: `dags/loyalty/loyalty_postgres_to_s3_ingest.py`  •  **dag_id**: `loyalty_postgres_to_s3_ingest`  •  **tag**: `fesloyalty`  •  **models**: 25  •  **prod schedule**: `5 * * * *` (hourly)  •  **callback tier**: p2  •  **notes**: `catchup=True` (only one of the 8 with catchup on), `max_active_runs=1`

### Before

```python
from utils import args, callbacks, config, dbt

@dag(catchup=True, ...)
def loyalty_postgres_to_s3_ingest():
    # ... backfill flag + POSTGRES_TABLE_CONFIGS_ACTIVE loop ...
    # ... conditional OC_INGEST_LIVE loop (OneCredits) ...

    with TaskGroup("loyalty_dbt") as loyalty_dbt:
        dbt.create_dbt_dag(
            dbt.DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["fesloyalty"],
            auth_env={...},
            skip_tests=False,
            build_flag=True,          # ← DELETE — Cloud default is already `dbt build`
        )

    load_tasks >> loyalty_dbt
    compare_task = compare_row_counts()
    loyalty_dbt >> compare_task
```

### After

```python
from utils import args, callbacks, config
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_FESLOYALTY_JOB_ID = config.get_value_for_env(
    dev=<TBD>,
    prod=<TBD>,
)

@dag(catchup=True, ...)
def loyalty_postgres_to_s3_ingest():
    # ... same backfill + load loops ...

    loyalty_dbt = create_dbt_cloud_task_group(
        group_id="loyalty_dbt",
        job_id=DBT_CLOUD_FESLOYALTY_JOB_ID,
    )

    load_tasks >> loyalty_dbt
    compare_task = compare_row_counts()
    loyalty_dbt >> compare_task
```

### Notes

- **Only DAG with `build_flag=True`** — delete the flag under Cloud; the provisioned Cloud job step is already `dbt build --select tag:fesloyalty`.
- **Largest tag set** (25 models) — job runtime will be the longest of the 8. `create_dbt_cloud_task_group` default `timeout_seconds=60*90` (90 min) should be reviewed against dev-run wall-clocks in Phase 3.
- `catchup=True` + `max_active_runs=1` means missed intervals backfill sequentially. Each backfill run triggers its own Cloud job — Cloud queues them per the account's concurrent-run limit (independent from Airflow's).
- No `data_interval_*` refs in any of the 25 models — no `steps_override`.

---

## §2.7 magnite_dag.py

**Path**: `dags/magnite/magnite_dag.py`  •  **dag_id**: `magnite_curate` (⚠ note: file name is `magnite_dag.py` but dag_id is `magnite_curate`)  •  **tag**: `magnite`  •  **models**: 1  •  **prod schedule**: `0 8 * * *`  •  **callback tier**: p3  •  **notes**: has manual-backfill `Param(backfill_start, backfill_end)` — Python code loops over date range internally

### Before

```python
from utils import args, callbacks, config, constants, dbt

DBT_PATH = "/usr/local/airflow/dags/dbt/"

with DAG(dag_id="magnite_curate", ...) as dag:
    export = PythonOperator(
        task_id="fetch_to_s3",
        python_callable=fetch_to_s3,
        op_kwargs={...},
    )

    with TaskGroup(group_id="dbt_magnite") as dbt_magnite:
        dbt.create_dbt_dag(
            DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["magnite"],
            skip_tests=False,
        )

    export >> dbt_magnite
```

### After

```python
from utils import args, callbacks, config, constants
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_MAGNITE_JOB_ID = config.get_value_for_env(
    dev=<TBD>,
    prod=<TBD>,
)

# DELETE: DBT_PATH constant

with DAG(dag_id="magnite_curate", ...) as dag:
    export = PythonOperator(
        task_id="fetch_to_s3",
        python_callable=fetch_to_s3,
        op_kwargs={...},
    )

    dbt_magnite = create_dbt_cloud_task_group(
        group_id="dbt_magnite",
        job_id=DBT_CLOUD_MAGNITE_JOB_ID,
    )

    export >> dbt_magnite
```

### Notes

- Single-model tag. Cloud job = 1 model build.
- Backfill mode fetches N dates in one PythonOperator run, then triggers 1 Cloud job. **The Cloud job builds against the current warehouse state** — after multiple dates land in S3, one dbt run picks them all up (matches MWAA behavior).

---

## §2.8 sfmc_optin_preferences_import.py  ⚠ needs steps_override — TEMPORARY DAG

**Path**: `dags/salesforce/sfmc_optin_preferences_import.py`  •  **dag_id**: `sfmc_optin_preferences_import`  •  **tag**: `optin_preferences`  •  **models**: 6 (4 use `var('data_interval_end')`)  •  **prod schedule**: `30 10 * * *`  •  **callback tier**: p3  •  **notes**: `end_date=pendulum.datetime(2026, 6, 9, tz="America/New_York")` — DAG is documented "TEMPORARY" and stops itself. **Cloud job still needs to be provisioned** (DAG runs through 2026-06-09 which is >45 days after cutover).

### Before

```python
from utils import args, callbacks, config, constants, dbt

DBT_PATH = "/usr/local/airflow/dags/dbt/"

@dag(..., end_date=pendulum.datetime(2026, 6, 9, ...))
def sfmc_optin_preferences_import():
    # ... db + warehouse + stage config ...

    sfmc_filename = "Optin_and_Preferences_{{ data_interval_end.format('YYYYMMDD') }}.csv"

    copy_from_sfmc_sftp = SFTPToS3Operator(...)
    check_for_file = S3KeySensor(...)
    load_to_snowflake = SQLExecuteQueryOperator(...)

    with TaskGroup(group_id="dbt_optin_preferences_group") as dbt_group:
        dbt.create_dbt_dag(
            DBT_PATH,
            namespace="fes-airflow",
            allow_empty_upstream=True,
            tags=["optin_preferences"],
            auth_env={...},
            skip_tests=False,
        )

    copy_from_sfmc_sftp >> check_for_file >> load_to_snowflake >> dbt_group
```

### After

```python
from utils import args, callbacks, config, constants
from utils.dbt_cloud import create_dbt_cloud_task_group

DBT_CLOUD_OPTIN_PREFERENCES_JOB_ID = config.get_value_for_env(
    dev=<TBD>,
    prod=<TBD>,
)

# DELETE: DBT_PATH constant

@dag(..., end_date=pendulum.datetime(2026, 6, 9, ...))
def sfmc_optin_preferences_import():
    # ... same config ...

    sfmc_filename = "Optin_and_Preferences_{{ data_interval_end.format('YYYYMMDD') }}.csv"

    copy_from_sfmc_sftp = SFTPToS3Operator(...)
    check_for_file = S3KeySensor(...)
    load_to_snowflake = SQLExecuteQueryOperator(...)

    dbt_group = create_dbt_cloud_task_group(
        group_id="dbt_optin_preferences_group",
        job_id=DBT_CLOUD_OPTIN_PREFERENCES_JOB_ID,
        steps_override=[
            'dbt build --select tag:optin_preferences --vars \''
            '{"data_interval_start": "{{ data_interval_start | ts }}", '
            '"data_interval_end": "{{ data_interval_end | ts }}", '
            '"ds_nodash": "{{ data_interval_start | ds_nodash }}"}\''
        ],
    )

    copy_from_sfmc_sftp >> check_for_file >> load_to_snowflake >> dbt_group
```

### Notes

- ⚠ **MUST pass `steps_override`** — 4 of the 6 models (`xp_optin_preferences_delta`, `xp_optin_preferences_snapshot`, `xp_push_last_opened_delta`, `xp_push_last_opened_snapshot`) reference `{{ var('data_interval_end') }}`. Without `--vars`, dbt build fails at compile.
- The `sfmc_filename` Jinja uses `data_interval_end.format('YYYYMMDD')` — that's Airflow-side templating in the `SFTPToS3Operator`, unrelated to dbt vars. Unchanged.
- Also has one static `var('tenant_id_fanapp')` (`xp_optin_preferences.sql`) — declared at project level in `dbt_project.yml`, unaffected by `steps_override`.
- **DAG stops at 2026-06-09** — so its Cloud job needs to exist through that date, then can be deleted (state=2) as post-Sunset cleanup.

---

## Order of execution (Phase 2)

Recommended per-DAG order (lowest blast radius first, allowing quick rollback if the pattern reveals unexpected issues):

1. **§2.7 magnite_dag.py** — 1 model, terminal dbt, p3, no `steps_override` — smallest surface area, fastest to sanity-check the migration pattern end-to-end.
2. **§2.4 impact.py** — 1 model, terminal dbt, p3 — mirrors magnite exactly.
3. **§2.1 fanapp_mdm.py** — 3 models, has downstream SQL fanout, p3 — verifies the downstream-preservation pattern.
4. **§2.2 google_ad_manager.py** — 9 models, chained upstream reports, p3 — verifies the sequential-chain pattern.
5. **§2.5 loyalty_bonus_postgres_to_s3_ingest.py** — 8 models, p2, hourly — first p2, first hourly, first with `compare_row_counts`.
6. **§2.8 sfmc_optin_preferences_import.py** — 6 models, p3, needs `steps_override` — first steps_override case.
7. **§2.3 cassandra_extract.py** — 5 models, p2, needs `steps_override` — second steps_override; p2 loyalty-domain-adjacent.
8. **§2.6 loyalty_postgres_to_s3_ingest.py** — 25 models, p2, hourly, `catchup=True`, `build_flag=True` — largest tag, biggest risk surface; save for last.

## Ready-for-Phase-1 checklist

- [x] All 8 tags verified as building the intended model sets (§0.1 + §0.2, [`dbt-in-airflow-removal-model-lists.md`](dbt-in-airflow-removal-model-lists.md))
- [x] Zero tag collisions with the existing 22 standalone-DAG jobs (§0.2)
- [x] Zero seed dependencies (§0.3)
- [x] Context-var scan identifies 2/8 DAGs needing `steps_override` (§0.4, [`dbt-in-airflow-removal-context-var-scan.md`](dbt-in-airflow-removal-context-var-scan.md))
- [x] Per-DAG before/after sketch drafted for all 8 (this doc)
- [x] Zero external ExternalTaskSensor targets on any of these 8 DAGs or their internal dbt task-groups — migration is contained
- [ ] Phase 1: extend `scripts/dbt_cloud.sh` provisioning list with the 8 new jobs (see §1.1 in [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md))
- [ ] Phase 1: run `dbt_cloud.sh provision-jobs` → capture dev + prod IDs (§1.2)
- [ ] Phase 1: populate the 8 `DBT_CLOUD_<UPPER>_JOB_ID` constants in Phase 2 edits
