# Coupling Test Plan

Test plan for exercising the `utils.dbt_cloud.create_dbt_cloud_task_group` helper against the ingest → dbt → export coupling on **dev MWAA**. This is the PRIMARY TEST TARGET per `cutover-playbook.md` §1 — the surface not covered by the isolated smoke DAG (fes-airflow #2249).

**Both test DAGs are `schedule_interval=None`** — fes-airflow convention is manual/mocked dev testing, not scheduled. Every scenario below is a manual trigger. Trigger via Airflow UI OR the CLI snippets in [§Trigger helpers](#trigger-helpers) below.

## Test DAGs

Both dev-only, on the long-lived `dbt-cloud-migration` branch (per D40):

| DAG | Purpose |
|---|---|
| `dbt_cloud_coupling_test` | Happy path: upstream `ExternalTaskSensor(dbt_cloud_coupling_test_upstream_mock)` → helper → mock export |
| `dbt_cloud_coupling_test_failure` | Sad path: known-to-fail dbt Cloud run → downstream must not fire (assertion guard) |

## Upstream choice — mock DAG, not a real ingestion DAG

The coupling test's job is to verify one thing: does the sensor + helper + sensor + downstream task chain wire together correctly. Whether the upstream is a real DAG or a mock, the coupling contract is identical.

Using a real DAG (originally `commerce_data_export`) introduced problems unrelated to the coupling:
- **Side effects**: real ingestion writes to dev S3, reads dev Snowflake
- **Non-determinism**: real DAGs sometimes fail for environmental reasons — that noise gets attributed to the coupling test
- **`start_date` coupling**: real DAG start_dates constrain logical_date choices in ways tangled with the real DAG's own behavior

**Design:** trivial dev-only DAG `dbt_cloud_coupling_test_upstream_mock.py` — one task, sleeps 5 seconds, done. Never fails. `start_date: 2025-01-01`. Its sole reason for existing is to be an ExternalTaskSensor target.

**What we're NOT losing by mocking**: the "real-DAG handshake works end-to-end" question is answered naturally by the surviving `dbt_loyalty_6hours` DAG in Airflow, which has real ingest sensors (`SqlSensor` on `transaction_raw_replication_handshake_sensor.sql` + `ExternalTaskSensor` on `loyalty_bonus_fancash_incremental`) → triggers ONE dbt Cloud job → waits on it. That's the actual post-D41 production pattern for DAGs that survive: ingest signals gate the one dbt Cloud trigger; dbt Cloud runs; DAG completes. The isolated coupling test doesn't need to also simulate it.

**Note on post-D41 scope**: under D41, dbt-to-dbt job chains (e.g. dbt Cloud loyalty job depends on dbt Cloud fanflow job) do NOT live in Airflow. They run inside dbt Cloud via `job_completion_trigger_condition`. The Airflow "coupling test" here validates only the **Airflow↔dbt Cloud handshake** (ingest sensor → trigger → wait → downstream task). The dbt Cloud ↔ dbt Cloud chain is a separate mechanism, validated in test 7a of `test/README.md`. Airflow never orchestrates between multiple dbt Cloud jobs — that would violate D41.

## Prep

Before triggering scenarios, verify dev deploy has landed the latest branch code:

```bash
# Push a new commit to `dbt-cloud-migration` (or trigger a PR sync). Wait for
# `PR: Deploy` workflow to complete (~5 min dags sync, ~20 min if MWAA env
# sync ran for a requirements change).
gh run list --workflow=deploy_dev.yml --branch=dbt-cloud-migration --limit 3

# Confirm DAGs appear in dev Airflow UI:
#   dbt_cloud_coupling_test         (dev-only, coupling-test tag)
#   dbt_cloud_coupling_test_failure (dev-only, coupling-test tag)
```

## Trigger helpers

MWAA doesn't accept direct `airflow` CLI over stdin, so use `aws mwaa create-cli-token` and POST to the MWAA CLI endpoint.

```bash
# One-time setup — token expires after ~60s, so run this inside each command.
create_cli_token() {
    aws mwaa create-cli-token \
        --name fes-data-compute-dev-1 \
        --profile fes-data-compute-dev \
        --output json
}

mwaa_cli() {
    # $1 = airflow CLI command string, e.g. "dags trigger dbt_cloud_coupling_test"
    local tok=$(create_cli_token)
    local endpoint=$(echo "$tok" | jq -r '.WebServerHostname')
    local cli_token=$(echo "$tok" | jq -r '.CliToken')

    curl --request POST \
        "https://${endpoint}/aws_mwaa/cli" \
        --header "Authorization: Bearer ${cli_token}" \
        --header "Content-Type: text/plain" \
        --data-raw "$1" \
        | jq -r '.stdout' | base64 --decode
}

# H2 — happy path via manual trigger
LOGICAL_DATE=$(date -u -v-1d '+%Y-%m-%dT08:00:00Z')  # yesterday 8am UTC

# Step 1: trigger dbt_cloud_coupling_test_upstream_mock in dev (populates the sensor target)
mwaa_cli "dags trigger dbt_cloud_coupling_test_upstream_mock --logical-date ${LOGICAL_DATE}"

# Step 2: wait for it to finish (~2-5 min for the 3 export tasks)
mwaa_cli "dags list-runs -d dbt_cloud_coupling_test_upstream_mock --limit 5"

# Step 3: trigger the coupling test with the SAME logical_date
mwaa_cli "dags trigger dbt_cloud_coupling_test --logical-date ${LOGICAL_DATE}"

# Step 4: observe the test DAG's task graph in the Airflow UI. Expected end
# state: wait_for_commerce=SUCCESS, run_dbt.*=SUCCESS, simulate_export=SUCCESS.
```

**Alternative — Airflow UI trigger:**
1. Go to dev MWAA URL, log in via SSO
2. Find `dbt_cloud_coupling_test_upstream_mock` DAG → "Trigger DAG w/ config" → set `logical_date` in the trigger form
3. Wait for it to succeed
4. Find `dbt_cloud_coupling_test` DAG → "Trigger DAG w/ config" → set the SAME `logical_date`

## Test matrix

Task states shown are the terminal state expected in Airflow UI after the DagRun settles.

### `dbt_cloud_coupling_test` (happy path)

| # | Scenario | Setup | `wait_for_commerce` | `run_dbt.trigger` | `run_dbt.wait` | `run_dbt.log_run` | `simulate_export` |
|---|---|---|---|---|---|---|---|
| **H1** | Happy path — matched logical_date | Trigger `dbt_cloud_coupling_test_upstream_mock` at `T`, wait for SUCCESS, then trigger test DAG at same `T` | `SUCCESS` | `SUCCESS` | `SUCCESS` | `SUCCESS` | `SUCCESS` |
| **H2** | Upstream never fires | Trigger test DAG with `logical_date=T` for which `dbt_cloud_coupling_test_upstream_mock` has NOT run | `UP_FOR_RESCHEDULE` → `FAILED` (1h timeout) | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` |
| **H3** | Upstream failed | Manually mark a `dbt_cloud_coupling_test_upstream_mock` DagRun for `T` as `failed` in UI, then trigger test DAG at same `T` | `FAILED` (via `failed_states=[DagRunState.FAILED]`) | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` |

### `dbt_cloud_coupling_test_failure` (sad path)

| # | Scenario | Setup | `run_failing_dbt.trigger` | `run_failing_dbt.wait` | `run_failing_dbt.log_run` | `simulate_export` |
|---|---|---|---|---|---|---|
| **F1** | dbt Cloud job fails at parse | Trigger the failure DAG; `steps_override` selects a nonexistent tag → dbt errors at parse time → dbt Cloud reports `Error` | `SUCCESS` (POST returned a run_id) | `FAILED` (sensor detected `Error`) | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` (**must NOT execute**) |
| **F2** | Sensor timeout | Edit the failure DAG on the branch to set `timeout_seconds=30` and remove `steps_override` (job runs successfully but longer than 30s), push, dev-deploy, then trigger | `SUCCESS` | `FAILED` (timeout) | `UPSTREAM_FAILED` | `UPSTREAM_FAILED` |

**F1 assertion:** `simulate_export` raises `AssertionError` if it executes. If the coupling contract breaks, the DAG fails loudly — not silently.

## Sequencing

Run in this order:

1. **F1** — failure path first. No upstream dependency, fastest iteration, proves the sad-path contract before H1 depends on the happy path.
2. **H1** — happy path with matched logical_date. Trigger commerce first, then the test.
3. **H2** — upstream never fires. Just trigger the test DAG at a random logical_date not covered by commerce.
4. **F2** — sensor timeout. Optional; requires a branch commit + dev deploy roundtrip.
5. **H3** — upstream failed. Optional; requires manually forcing a `dbt_cloud_coupling_test_upstream_mock` failure.

## Instrumentation — latency profile

`simulate_export` logs `logical_date` and `released_at`. Combine with Airflow UI task history:

- **T1** = `wait_for_commerce.end_date` (upstream complete detection)
- **T2** = `run_dbt.trigger.end_date` (dbt Cloud POST complete)
- **T3** = `run_dbt.wait.end_date` (dbt Cloud run complete detection)
- **T4** = `simulate_export.start_date` (downstream release)

Latency budget informs:
- **Dev parallel-run diff cadence** (`cutover-playbook.md` §5)
- **Poke interval tuning** — helper defaults to 60s; if T3-T2 is regularly <30s, tighten

## What "pass" means

- ✅ H1 shows clean SUCCESS chain end-to-end
- ✅ F1 shows `simulate_export` in `UPSTREAM_FAILED` (proves dbt failure propagates)
- ✅ F2 shows `simulate_export` in `UPSTREAM_FAILED` (proves sensor timeout also propagates)
- ✅ Latency fits comfortably inside the migration's tightest scheduled cadence (loyalty hourly → dbt Cloud + trigger + sensor + downstream release well under 60 minutes)

If any of the above fails, append findings to `discoveries.md` and consider whether the helper signature needs adjustment (per D34's iteration clause).

## What this test does NOT cover

- **Real Snowflake table writes** — smoke_job writes to `FES_USERS.ALEX_SOTIS`. Parallel-run scaffolding (playbook §5) is what exercises real target-schema writes on dev.
- **`steps_override` with Airflow context vars** — happens naturally when the real `dbt_loyalty` DAG runs its parallel-run against dev (its rewritten form passes context vars via `steps_override`).
- **Cross-DAG chain via `<group_id>.log_run`** — D37 pattern for dbt-to-dbt deps. Exercised naturally by `dbt_loyalty`'s `wait_for_fanflow` sensor on `dbt_fanflow.log_run` once both DAGs are running via dbt Cloud on dev.
- **Prod behavior** — dev only. Prod SSM `dbt_cloud_ae` value stays `change me` until cutover moment (per D31).

## Test 9 — Ingest-DAG handshake class (added 2026-07-19)

Not a separate mock DAG; verified by running each of the 8 migrated ingest DAGs on dev MWAA per [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md) §3.3.

The class-under-test:

```
<ingest upstream tasks/sensors>
      ↓
<new task-group> = create_dbt_cloud_task_group(group_id, job_id[, steps_override])
      ↓
<downstream tasks: compare_row_counts / SQL extracts>
```

Same underlying helper shape as H1 / F1 / F2. What Test 9 adds is coverage that:

1. **8 different DAG shapes all pass** (fan-out downstream, sequential upstream chain, single-op linear, hourly with catchup, temporary DAG, dynamic-mapping upstream, param-driven backfill DAG, single-op terminal-dbt) — proving the helper generalizes.
2. **`steps_override=[...]` rendering under real Airflow templating** — 2 of the 8 (`cassandra_extract`, `sfmc_optin_preferences_import`) pass a `--vars '{...}'` payload with Jinja for `data_interval_start | ts`, `data_interval_end | ts`, `ds_nodash`. Verified out-of-band 2026-07-19 by a direct API POST with a pre-rendered `steps_override` — dbt Cloud run 70437511080045 (dev `dbt_identity`) executed step `dbt build --select tag:identity --vars '{"data_interval_start": "2026-07-19T00:00:00", "data_interval_end": "2026-07-19T01:00:00", "ds_nodash": "20260719"}'`. Airflow-side templating verified when each DAG runs on dev MWAA in §3.3.
3. **`group_id` preservation** — every migrated DAG kept its MWAA-side TaskGroup name (`dbt_mdm_sdp`, `dbt_google_ad_manager`, `identity_dbt`, `dbt_impact`, `bonus_dbt`, `loyalty_dbt`, `dbt_magnite`, `dbt_optin_preferences_group`). No downstream `ExternalTaskSensor` breakage anywhere in `dags/` (confirmed 2026-07-19 via exhaustive `grep external_dag_id` + task-group-name search; zero hits).

### Pass criteria for Test 9

Per migrated DAG on dev MWAA:

- ✅ Upstream half runs unchanged (ingest / SFTP / API extract tasks)
- ✅ `<group_id>.trigger` POSTs `run_id`; run appears in dbt Cloud UI
- ✅ `<group_id>.wait` releases on `status_humanized=Success`
- ✅ `<group_id>.log_run` logs the run URL + duration
- ✅ Downstream tasks (if any) fire successfully (`compare_row_counts()` PASS for `loyalty_bonus`, `loyalty_postgres`; 3× SQL fanout for `fanapp_mdm`)

### Fast-path smoke (§3.2 canary, 2026-07-19)

Three dev Cloud runs POSTed via direct API to validate the pattern ahead of dev-MWAA deploy:

| Job | Run ID | Purpose | Result |
|---|---|---|---|
| `dbt_magnite` (70437463793540) | 70437511080039 | Auth + selector (1 model, no vars) | **Error at step 4** — `SVC_DBT_CLOUD_ROLE` needs `MODIFY` on `FES_INTEGRATIONS_DEV.MAGNITE.MAGNITE_PA_HOURLY_EXT`. Selector + compilation OK; **fails on missing dev grant.** |
| `dbt_impact` (70437463793537) | 70437511080041 | Same, second single-model | **Error at step 4** — `SVC_DBT_CLOUD_ROLE` needs `MODIFY` on `FES_INTEGRATIONS_DEV.IMPACT.TICKETMASTER_ORDER_LISTING`. Same class of failure. |
| `dbt_identity` (70437463793536) | 70437511080045 | `steps_override` rendering + `var('data_interval_start')` resolution | **Error at step 4** — step verified as `dbt build --select tag:identity --vars '{"data_interval_start": "2026-07-19T00:00:00", ...}'` (steps_override mechanism ✅ works). Fails on `OWNERSHIP` needed for `IDENTITY_DEV.UNIFIED_PROFILE.PREFERENCES`, `IDENTITY_DEV.UNIFIED_PROFILE.FAVORITES` and `MODIFY` on `IDENTITY_DEV.ORCHESTRATION.MARTECH_PRIVATE_FAN_ID_MAP`, `LOYALTY_PRIVATE_FAN_ID_MAP`. |

### What §3.2 proved

- ✅ 8 new dbt Cloud jobs are correctly provisioned in dev + prod (auth, project, environment, selector all valid).
- ✅ `steps_override` mechanism works — Airflow-side `--vars '{...}'` payload reaches the dbt CLI intact.
- ✅ Tag selection is accurate — each `dbt build --select tag:X` compiles the expected model set (per Phase 0 §0.2 model-lists).
- ❌ `SVC_DBT_CLOUD_ROLE` lacks `MODIFY` / `OWNERSHIP` on ~several tables in the 4 dev DBs the 8 ingest tags touch — same class of grants gap as prior Test 6 (dbt_sources) failure that the terraform grants PR (branch `dbt-cloud-grants-full-scope`, expanded from #2877) addresses.

### What §3.2 did NOT prove — deferred to §3.3

- Full run to `Success` — gated on dev grants + `IDENTITY_DEV.UNIFIED_PROFILE.{PREFERENCES,FAVORITES}` OWNERSHIP transfer.
- Airflow-side templating of `steps_override` — the raw templates render into full JSON at DAG trigger time; verified indirectly (the canary used a hand-rendered payload; the DAG's Jinja will render the same shape). Deploying the DAGs to dev MWAA and triggering from the UI closes this gap.
- End-to-end DAG success (upstream ingest → dbt Cloud → downstream `compare_row_counts` / SQL fanout) — that's the actual §3.3 test.

### Grants gap discovered — action items before §3.3 can pass

**Classification rule** (per user 2026-07-19): *ingested tables* (populated by MWAA — SqlToS3+COPY, SnowflakeOperator, or Snowflake external-table auto-refresh from S3) must NOT be ownership-transferred to `SVC_DBT_CLOUD_ROLE`. That would break MWAA-side writes. Only **dbt-materialized targets** — tables the dbt model itself writes to — get OWNERSHIP transferred. Ingested tables get SELECT only.

Verified target/source classification for all 8 ingest tags (audited 2026-07-19 against dbt-fes-ae `fix/fusion-parse-cleanup` via `dbt ls --output json` + `source()` grep + MWAA writer sweep):

| Tag | dbt-materialized targets (`SVC_DBT_CLOUD_ROLE` OWNS) | Ingested sources (MWAA OWNS; `SVC_DBT_CLOUD_ROLE` gets SELECT only) |
|---|---|---|
| `mdm_sdp` (3 models, all `materialized: table`) | `MDE_DEV.MDE_INFO.{MDM_TO_SDP_LEAGUES, MDM_TO_SDP_PLAYERS, MDM_TO_SDP_TEAMS}` | Reads from `fbg_fde__fbg_sdp.*` (FBG data-share, external ownership — SELECT via share grant, no ingest of ours), `commerce_mde__mde_info.actor_lkp_v` (view), `mde__mde_core.v_organization_properties` (view). **No `_ext` tables we own** — all upstream is Snowflake shares/views. |
| `google_ad_manager` (9 models, all `materialized: incremental` merge) | `FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_{ADVERTISER_SPEND_SUMMARY, DAILY_FILLED, EXECUTIVE_REVENUE_SUMMARY, FILL_RATE_BY_AD_UNIT, INVENTORY_FILL_RATE_BY_AD_UNIT, INVENTORY_SELL_THROUGH_FORECASTING, LINE_ITEM_PACING_DELIVERY, UNIFIED_IMPRESSIONS_ANALYSIS, VIEWABILITY_BY_PLACEMENT}` | `FES_INTEGRATIONS_DEV.GOOGLE_ADS.GAM_REPORT_RAW_EXT` (S3 auto-refresh external table, MWAA-uploaded parquet via `google_ad_manager` DAG). *(source referenced via `gam_report()` macro, not direct `source()` in the .sql — source declared in `models/sources/fes_integrations.yml`.)* |
| `identity` (5 models: 3 `table` + 2 `incremental`) | `IDENTITY_DEV.UNIFIED_PROFILE.{PREFERENCES, FAVORITES, CORE}` (table) + `IDENTITY_DEV.ORCHESTRATION.{LOYALTY_PRIVATE_FAN_ID_MAP, MARTECH_PRIVATE_FAN_ID_MAP}` (incremental) | `IDENTITY_DEV.IDENTITY__SOURCE.{preferences_ext, favorites_ext, loyalty_private_fan_id_map_ext, martech_private_fan_id_map_ext}` (Cassandra→S3→external table via `cassandra_extract` DAG) |
| `impact` (1 model, `incremental` merge) | `FES_INTEGRATIONS_DEV.IMPACT.TICKETMASTER_ORDER_LISTING` | `FES_INTEGRATIONS_DEV.IMPACT.TICKETMASTER_ORDER_LISTING_RAW` (Airflow COPY landing from impact API CSV) |
| `fesbonus` (8 models, all `materialized: incremental`) | `LOYALTY_DEV.SOURCE.{bonus, bonus_reward, bonus_step, user_bonus, user_bonus_reward, user_bonus_step, user_bonus_step_event, user_event}` | `LOYALTY_DEV.SOURCE.{bonus_ext, bonus_reward_ext, bonus_step_ext, user_bonus_ext, user_bonus_reward_ext, user_bonus_step_ext, user_bonus_step_event_ext, user_event_ext}` (Airflow SqlToS3+COPY via `loyalty_bonus_postgres_to_s3_ingest` DAG) |
| `fesloyalty` (25 models: 22 `incremental` + 1 `table` + 2 `view` + 1 `ephemeral`) | **22 incremental** in `LOYALTY_DEV.SOURCE`: `account_balance, allocation, allocation_remaining, auth_bucket_hold, auth_hold, bucket, bucket_type, capture_event, entry, idempotency_keys, journal, loyalty_account` (alias of `loyalty_account_postgres`), `opco_program_account, operating_company, program, program_account_balance, system_loyalty_account, transaction, transfer_restriction, void_auth_event, void_remaining`. **1 table + 2 views** in `LOYALTY_DEV.ONE_CREDITS`: `ONE_CREDITS_LOYALTY_ANALYTICS_LEDGER` (table), `ONE_CREDITS_LOYALTY_ANALYTICS_LEDGER_FBG` (view), `ONE_CREDITS_LOYALTY_ANALYTICS_LEDGER_NO_AUTH` (view). **ephemeral** `journal_normalized` — compiled inline; no target, no ownership needed. | `LOYALTY_DEV.SOURCE.{account_balance_ext, allocation_ext, ..., void_remaining_ext}` (21 external tables, Airflow SqlToS3+COPY via `loyalty_postgres_to_s3_ingest` DAG) |
| `magnite` (1 model, `incremental`) | `FES_INTEGRATIONS_DEV.MAGNITE.MAGNITE_PA_HOURLY` | `FES_INTEGRATIONS_DEV.MAGNITE.MAGNITE_PA_HOURLY_EXT` (S3 auto-refresh external table, MWAA-uploaded parquet via `magnite_curate` DAG) |
| `optin_preferences` (6 models: 2 `table` + 4 `incremental`) | **table**: `XP_DEV.STAGE.{XP_OPTIN_PREFERENCES, XP_PUSH_LAST_OPENED}`. **incremental**: `XP_DEV.STAGE.{XP_OPTIN_PREFERENCES_SNAPSHOT, XP_PUSH_LAST_OPENED_SNAPSHOT}` + `XP_DEV.XP.{XP_OPTIN_PREFERENCES_DELTA, XP_PUSH_LAST_OPENED_DELTA}` | `FES_INTEGRATIONS_DEV.SALESFORCE.OPTIN_AND_PREFERENCES` (Airflow COPY landing from SFMC SFTP via `sfmc_optin_preferences_import` DAG). *(Note: `xp_push_last_opened*` models don't declare an explicit `source()` — verify upstream reference during Phase 3 §3.3.)* |

**MWAA writer sweep** (2026-07-19): grepped every proposed OWNERSHIP-transfer target against `dags/` in fes-airflow. **Zero MWAA-side writers** on any of these tables (only hit was a dbt-side `auto_delta.env` config file that names a table for a diff comparison — not a writer). Ownership transfer is safe.

**Canary error post-mortem** — the "MODIFY needed on MAGNITE_PA_HOURLY_EXT" was misleading:
- The `_EXT` target IS an ingested external table (MWAA-populated). Correct grant is **SELECT**, not MODIFY.
- Snowflake's error surface for external-table SELECT sometimes reports MODIFY-flavor messaging when a role lacks the specific external-table SELECT + USAGE + REFERENCES combination. Fix is a plain `GRANT SELECT ON EXTERNAL TABLE MAGNITE_PA_HOURLY_EXT TO ROLE SVC_DBT_CLOUD_ROLE`.

**Corrected action items**:
1. **SELECT grants** on all `_EXT` / `_raw` / source-landing tables in the 4 dev source DBs (`FES_INTEGRATIONS_DEV`, `IDENTITY_DEV`, `LOYALTY_DEV`, `MDE_DEV`) to `SVC_DBT_CLOUD_ROLE`. Extend `dbt-cloud-grants-full-scope` TF branch (task #71 — this is the durable path used for both dev and prod cutover).
2. **OWNERSHIP transfer** on ONLY the dbt-materialized targets. Same script pattern as `sql/cutover_ownership_transfer.sql` but scoped to dev.
3. **Never transfer ownership** on `_EXT`, `_raw`, or source-landing tables — MWAA writes/refreshes them; transferring ownership breaks the ingest.

**Bespoke dev unblock script** (task #75): `projects/dbt_cloud_migration/sql/dev_pre_walkthrough_grants_and_ownership.sql`. Applies items 1+2 above in one shot on dev, via a hardcoded classification list (55 materialized + ~37 sources + 5 DB USAGE + 12 schema USAGE/CREATE). Non-authoritative — TF is still the durable source — but self-contained enough that the dev walkthrough (§3.3) can proceed without waiting for the TF PR to land. Dry-run default; flip `is_dry_run := FALSE` for real execution.
