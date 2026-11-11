# dbt Cloud Deploy Job Registry

Every fes-airflow DAG referenced below expects a dedicated dbt Cloud deploy job. Per **D35**, one job per DAG, selector = current tag. Job IDs recorded here after creation.

**Naming convention:** dbt Cloud job name = fes-airflow DAG name (e.g. `dbt_loyalty`). Environment = `deployment` (or `deployment_parallel_run` for the parallel-run development on dev).

**Warehouse:** `FDE_DBT_CLOUD_WH` (or whatever Monday's TF PR names). Grant on this warehouse is added by Monday's TF PR.

**Schedule:** none — every job is Airflow-triggered.

## Automated provisioning workflow

Use `fes-airflow/scripts/dbt_cloud.sh` (on the `dbt-cloud-migration` branch) to create all 21 jobs at once.

### Step 1 — Populate `.env` with the concrete IDs

`.env` at fes-airflow root is gitignored. Add these five vars:

```env
# dbt Cloud API — for scripts/dbt_cloud.sh (D40 migration)
DBT_CLOUD_ACCOUNT_ID=<from SSM URI login field>
DBT_CLOUD_TOKEN=<from SSM URI password field>
DBT_CLOUD_HOST=sh023.us1.dbt.com
DBT_CLOUD_PROJECT_ID=<from dbt Cloud UI — see below>
DBT_CLOUD_ENVIRONMENT_ID=<from dbt Cloud UI — see below>
```

**SSM URI parse:** the SSM value is `dbt-cloud://<account_id>:<token>@<host>`. Split on `:` and `@`.

**Project + environment IDs from dbt Cloud UI:**
- Log into `https://sh023.us1.dbt.com/`
- Click into the **dbt-fes-ae** project. URL becomes `.../projects/{project_id}/...` — copy the number
- Inside the project, **Deploy → Environments**, click the target environment (`deployment` per D25). URL becomes `.../environments/{environment_id}` — copy the number

The script auto-sources `.env` at repo root, so no manual `export` needed.

### Step 2 (optional) — Discover / sanity check

Read-only. Lists all projects, plus environments and existing jobs for the configured project. Useful to double-check that `DBT_CLOUD_PROJECT_ID` points at the right project before any writes.

```bash
cd ~/repos/fes-airflow
./scripts/dbt_cloud.sh discover
```

### Step 3 — Dry-run the provision

Prints exactly what would be POSTed, does not create anything. Verify the JSON bodies look right.

```bash
./scripts/dbt_cloud.sh provision-jobs --dry-run
```

At the start of the run, the script prints the resolved project and environment **names** (from GET calls, not from your env vars) and prompts for interactive `yes` confirmation. If those names don't match your expectation, hit Ctrl-C or type anything except `yes`.

### Step 4 — Create the jobs for real

Same as step 3, without the dry-run flag. Prints the confirmation summary, prompts for `yes`, then POSTs one job at a time. Captures the CSV output for step 5.

```bash
./scripts/dbt_cloud.sh provision-jobs > /tmp/dbt-cloud-job-ids.csv
cat /tmp/dbt-cloud-job-ids.csv
```

Jobs land with `state=1` (active) but **all `triggers.*` set to `false`** — dbt Cloud never auto-fires them. They only run when Airflow POSTs to `/jobs/{id}/run/`.

**Why not `state=2` for "paused":** dbt Cloud has no "paused" state. `state=2` = **deleted** (verified 2026-07-12 against dbt-cloud-cli issue #24 and dbt Labs' `dbt-jobs-as-code` source). The correct pattern for a "not auto-firing" job is `state=1` + all triggers off — matches what dbt Labs' own `deactivate-jobs` command does. See discovery D-18.

### Step 5 — Write the IDs into DAG files

Only one Airflow DAG references a job ID after D41 (the 20 pure-dbt DAGs were deleted):
`dags/dbt/dbt_loyalty_6hours.py`. Edit `DBT_CLOUD_LOYALTY_6HOURS_JOB_ID` to point at
`config.get_value_for_env(dev=<dev_id>, prod=<prod_id>)` manually — no batch script needed.

The rest of the job IDs live only in dbt Cloud (schedules/chains) and in
`deploy-jobs.md` for record-keeping.

### Safety guards

The provision script:

1. Requires `DBT_CLOUD_PROJECT_ID` and `DBT_CLOUD_ENVIRONMENT_ID` to be set (via `.env` or exported).
2. Before any POST, does `GET /projects/{id}/` and `GET /environments/{id}/` and prints the **actual names** returned by dbt Cloud — you visually verify.
3. Requires interactive typing of `yes` to proceed (bypass with `--yes` flag for CI/scripted use).
4. Every job created with all `triggers.*` set to `false` — dbt Cloud will never fire them on any automatic schedule/webhook/on-merge event.
5. Fails fast on the first non-2xx response (`set -e`) — a partial run is recoverable via CSV inspection + manual UI delete for any wrong-project jobs.

## Deploy jobs to create

For every DAG below, create a job with:
- Environment: `deployment` (prod-target) — the `parallel_run` counterpart is optional if we skip the parallel-run development pattern
- Steps: as specified (usually `dbt build --select tag:<tag>` unless noted)
- Job name = the value in the "DAG" column
- Once created, paste the numeric job_id into the corresponding constant in the DAG file (search for `DBT_CLOUD_<name>_JOB_ID = 0` on the `dbt-cloud-migration` branch)

> **Time zone (2026-07-22):** All "Prod cron" values below are **UTC** — dbt Cloud evaluates crons in UTC only and has no DST awareness. The former Airflow DAGs used `start_date=pendulum.datetime(..., tz="America/New_York")`, so Airflow interpreted their crons in **ET (DST-aware)**; the crons here are the ET→UTC conversion at the **EDT (+4h)** offset that matches yesterday's firing instant. Consequence: after DST fall-back these jobs fire 1h earlier in ET than they did pre-migration (accepted cost of UTC standardization). On 2026-07-22 four rows were corrected to their true pre-migration UTC time — `dbt_loyalty_monthly_snapshot` (`0 9`→`0 11`, was already UTC and wrongly shifted), `dbt_mde` (`45 11`→`45 15`), `dbt_every_6hours` (`30 0,1,6,12,18`→`30 4,5,10,16,22`), `dbt_every_3hours` (`0 */3`→`0 1,4,7,10,13,16,19,22`); these three had been left un-converted. Dev jobs (env `70437463672950`) carry `triggers.schedule=false` — **never scheduled**; only prod is scheduled.

| DAG | Steps | Dev job ID | **Prod job ID** | Prod cron |
|---|---|---|---|---|
| `dbt_loyalty` | `dbt build --select tag:loyalty` | `70437463791263` | **`70437463791501`** | `0 * * * *` |
| `dbt_loyalty_6hours` | `dbt build --select tag:loyalty_6hours` | `70437463791264` | **`70437463791502`** | *(none — Airflow triggers)* |
| `dbt_loyalty_metrics` | `dbt build --select tag:loyalty_metrics` | `70437463791265` | **`70437463791503`** | `0 14 * * *` |
| `dbt_loyalty_monthly_snapshot` | `dbt build --select tag:loyalty_monthly` | `70437463791266` | **`70437463791504`** | `0 11 2 * *` |
| `dbt_fanflow` | `dbt build --select tag:fanflow` | `70437463791267` | **`70437463791505`** | `0 * * * *` |
| `dbt_hourly` | `dbt build --select tag:hourly` | `70437463791268` | **`70437463791506`** | `0 * * * *` |
| `dbt_daily` | `dbt build --select tag:daily` | `70437463791269` | **`70437463791507`** | `0 12 * * *` |
| `dbt_daily_9am` | `dbt build --select tag:daily_9am` | `70437463791270` | **`70437463791508`** | `15 13 * * *` |
| `dbt_every_3hours` | `dbt build --select tag:3hours` | `70437463791271` | **`70437463791509`** | `0 1,4,7,10,13,16,19,22 * * *` |
| `dbt_every_6hours` | `dbt build --select tag:6hours` | `70437463791272` | **`70437463791510`** | `30 4,5,10,16,22 * * *` |
| `dbt_weekly` | `dbt build --select tag:weekly` **then** `dbt run-operation refresh_eval_ground_truth` | `70437463791273` | **`70437463791511`** | `0 10 * * 1` |
| `dbt_meta_ads` | `dbt build --select tag:meta_ads` | `70437463791274` | **`70437463791512`** | `0 8 * * *` |
| `dbt_ltv` | `dbt build --select tag:ltv` | `70437463791275` | **`70437463791513`** | `0 12 * * *` |
| `dbt_mde` | `dbt build --select tag:mde` | `70437463791276` | **`70437463791514`** | `45 15 * * *` |
| `dbt_fanapp_recs` | `dbt build --select tag:fanapp_recs` | `70437463791277` | **`70437463791515`** | `0 12 * * *` |
| `dbt_enterprise_metrics` | `dbt build --select tag:enterprise_metrics` | `70437463791278` | **`70437463791516`** | *(none — ad-hoc only)* |
| `dbt_enterprise_metrics_daily` | `dbt build --select tag:enterprise_metrics_daily` | `70437463791279` | **`70437463791517`** | `0 12 * * *` |
| `dbt_fanatics_one` | `dbt build --select tag:fanaticsone` | `70437463791280` | **`70437463791518`** | `*/30 * * * *` |
| `dbt_xtremepush` | `dbt build --select tag:xtremepush` | `70437463791281` | **`70437463791519`** | `0 12 * * *` |
| `dbt_users` | `dbt build --select tag:users` | `70437463791282` | **`70437463791520`** | `30 13 * * *` |
| `dbt_sources` | `dbt source freshness` | `70437463791283` | **`70437463791521`** | `0 13 * * 1-5` |
| `dbt_fangraph` | `dbt build --selector fangraph` | `70437463791523` | **`70437463791522`** | `0 10 * * *` |

## Ingest-DAG-triggered jobs (added 2026-07-19)

Per [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md) — 8 additional Airflow-triggered jobs, one per ingest-coupled DAG whose MWAA-embedded `dbt.create_dbt_dag(...)` call is migrated to `create_dbt_cloud_task_group()`. Same shape as `dbt_loyalty_6hours`: `state=1`, `triggers.schedule=false`, no cron.

| DAG (Airflow) | Cloud job name | Steps | Dev job ID | **Prod job ID** | Schedule |
|---|---|---|---|---|---|
| `fanapp_mdm` | `dbt_fanapp_mdm` | `dbt build --select tag:mdm_sdp` | `70437463793534` | **`70437463793542`** | *(none — Airflow triggers)* |
| `google_ad_manager` | `dbt_google_ad_manager` | `dbt build --select tag:google_ad_manager` | `70437463793535` | **`70437463793543`** | *(none — Airflow triggers)* |
| `cassandra_extract` | `dbt_identity` | `dbt build --select tag:identity` | `70437463793536` | **`70437463793544`** | *(none — Airflow triggers, `steps_override` at trigger time)* |
| `impact` | `dbt_impact` | `dbt build --select tag:impact` | `70437463793537` | **`70437463793545`** | *(none — Airflow triggers)* |
| `loyalty_bonus_postgres_to_s3_ingest` | `dbt_fesbonus` | `dbt build --select tag:fesbonus` | `70437463793538` | **`70437463793546`** | *(none — Airflow triggers)* |
| `loyalty_postgres_to_s3_ingest` | `dbt_fesloyalty` | `dbt build --select tag:fesloyalty` | `70437463793539` | **`70437463793547`** | *(none — Airflow triggers)* |
| `magnite_curate` | `dbt_magnite` | `dbt build --select tag:magnite` | `70437463793540` | **`70437463793548`** | *(none — Airflow triggers)* |
| `sfmc_optin_preferences_import` | `dbt_optin_preferences` | `dbt build --select tag:optin_preferences` | `70437463793541` | **`70437463793549`** | *(none — Airflow triggers, `steps_override` at trigger time)* |

Provisioned via `scripts/dbt_cloud.sh provision-jobs --only <name>` (repeatable filter added same day). All 8 dev jobs in env `70437463672950`, all 8 prod jobs in env `70437463672974`.

DAG-file constants populated by Phase 2 of [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md).

---

After D41 + the ingest-DAG cleanup, 9 Airflow DAGs reference a dbt Cloud job ID:
- `dags/dbt/dbt_loyalty_6hours.py` — `config.get_value_for_env(dev=70437463791264, prod=70437463791502)`
- `dags/fanapp/fanapp_mdm.py` — `DBT_CLOUD_FANAPP_MDM_JOB_ID` = `(dev=70437463793534, prod=70437463793542)`
- `dags/google_ad_manager/google_ad_manager.py` — `DBT_CLOUD_GOOGLE_AD_MANAGER_JOB_ID` = `(dev=70437463793535, prod=70437463793543)`
- `dags/identity/cassandra_extract.py` — `DBT_CLOUD_IDENTITY_JOB_ID` = `(dev=70437463793536, prod=70437463793544)`
- `dags/impact/impact.py` — `DBT_CLOUD_IMPACT_JOB_ID` = `(dev=70437463793537, prod=70437463793545)`
- `dags/loyalty/loyalty_bonus_postgres_to_s3_ingest.py` — `DBT_CLOUD_FESBONUS_JOB_ID` = `(dev=70437463793538, prod=70437463793546)`
- `dags/loyalty/loyalty_postgres_to_s3_ingest.py` — `DBT_CLOUD_FESLOYALTY_JOB_ID` = `(dev=70437463793539, prod=70437463793547)`
- `dags/magnite/magnite_dag.py` — `DBT_CLOUD_MAGNITE_JOB_ID` = `(dev=70437463793540, prod=70437463793548)`
- `dags/salesforce/sfmc_optin_preferences_import.py` — `DBT_CLOUD_OPTIN_PREFERENCES_JOB_ID` = `(dev=70437463793541, prod=70437463793549)`

**Environments:**
- Dev jobs 1–21 in env `70437463672950` (Development, type=development, credential 70437463679957 target_name=default). Created 2026-07-12. Dev `dbt_fangraph` (`70437463791523`) added 2026-07-13 via direct API POST. Dev ingest-triggered jobs `70437463793534`–`70437463793541` added 2026-07-19.
- Prod jobs in env **`70437463672974`** (Production, type=deployment/production, credential **`70437463679983`** target_name=prod). Created 2026-07-13. Prod ingest-triggered jobs `70437463793542`–`70437463793549` added 2026-07-19.

**Chain configurations applied:**
- Prod `dbt_loyalty` (`70437463791501`) ← `job_completion_trigger_condition` on prod `dbt_fanflow` (`70437463791505`), project `70437463666576`, statuses `[10]`. Set 2026-07-13. Chain is inert until `triggers.schedule=true` fires on `dbt_fanflow` — no risk of accidental prod activation.

## Existing jobs

| Job name | Job ID | Purpose | Created |
|---|---|---|---|
| `smoke_job` | `70437463791193` | Smoke test — `dbt build --select smoke`. Used by `dbt_cloud_smoke_test.py` (PR #2249) and the two coupling test DAGs on `dbt-cloud-migration`. | 2026-07-11 |

## `parallel_run` variants (optional)

If you want dev parallel-run validation with a separate `_SHADOW` schema target (per playbook §5), create counterpart jobs in the `deployment_parallel_run` environment:

- Environment: `deployment_parallel_run` (dbt-fes-ae `parallel_run` target)
- Steps: same as the prod counterpart
- Naming: append `_parallel_run` (e.g. `dbt_loyalty_parallel_run`)

Not required — you can also just point the prod job at dev sources by running dbt Cloud against dev target with a schema override, but a separate env is cleaner.

## Configuration checklist per job

For every job created:
- [ ] Environment set to `deployment` (prod-target)
- [ ] Warehouse set to `FDE_DBT_CLOUD_WH` (or whatever Monday's TF PR names)
- [ ] Steps set as per table above
- [ ] Trigger: **Custom** (or "Only via API") — no schedule
- [ ] Job ID pasted into corresponding constant in `dbt-cloud-migration` branch
- [ ] Row added to "Existing jobs" table above with created date
