# Remove ALL dbt-in-Airflow — the true D41 completion

**Status**: 🔥 **CRITICAL pre-cutover step.** Not option-3-deferrable. Nothing else in the migration ships until this is done.

**Phase 0 audit result (2026-07-19)**: All 5 substeps complete. All 6 pre-existing open questions resolved. Two new findings: (a) `identity` and `optin_preferences` DAGs require `steps_override=[...]` because 6 of their models consume `data_interval_*` vars; the other 6 don't. (b) Zero external ExternalTaskSensor targets on any of the 8 DAGs or their internal dbt task-groups — migration is fully contained; no downstream sensor updates needed. See `dbt-in-airflow-removal-migration-diffs.md` for the per-DAG blueprint used in Phase 2.

**Phase 1 result (2026-07-19)**: §1.1 script extended (`_JOB_ROWS` 22 → 30) + `--only <name>` filter added. §1.2 provisioned 8 dev jobs (`70437463793534`–`70437463793541`) + 8 prod jobs (`70437463793542`–`70437463793549`) via `scripts/dbt_cloud.sh provision-jobs --only <name>`. All 16 provisioned with `state=1`, `triggers.schedule=false`, no cron — Airflow-only. §1.3 updated `deploy-jobs.md` with new "Ingest-DAG-triggered jobs" subsection listing all 16 IDs.

**Phase 2 result (2026-07-19)**: All 8 DAG files edited on branch `dbt-cloud-migration`. Each file: removed `from utils import ..., dbt` and `DBT_PATH`, added `from utils.dbt_cloud import create_dbt_cloud_task_group` + `DBT_CLOUD_<UPPER>_JOB_ID = config.get_value_for_env(dev=..., prod=...)`, replaced `with TaskGroup("X") as var: dbt.create_dbt_dag(...)` with `var = create_dbt_cloud_task_group(group_id="X", job_id=...)`. `identity` and `optin_preferences` pass `steps_override=[...]` mirroring MWAA's `dags/utils/dbt.py:111-113` injection. `loyalty_postgres_to_s3_ingest` — `build_flag=True` dropped (Cloud default step is `dbt build`, matches). All 8 files `ast.parse`-clean. Legacy `utils.dbt` calls: zero remaining across the DAG tree — Phase 4 cleanup safe as far as consumers.

**Phase 3 §3.2 canary (2026-07-19)**: 3 direct-API POSTs on dev — `dbt_magnite` (run 70437511080039), `dbt_impact` (run 70437511080041), `dbt_identity` (run 70437511080045 with pre-rendered `steps_override`). **All 3 error**, but on the SAME downstream issue: `SVC_DBT_CLOUD_ROLE` missing `MODIFY`/`OWNERSHIP` on tables in dev DBs the ingest tags touch. The dbt Cloud plumbing (auth, project, env, selector, `steps_override` rendering) is proven correct — step 4 of the identity run reads `dbt build --select tag:identity --vars '{"data_interval_start": "2026-07-19T00:00:00", ...}'` as expected. Blocker gap detailed in `coupling-test-plan.md` §Test 9 → grants gap section. Same class as Test 6 dbt_sources failure — resolves after the `dbt-cloud-grants-full-scope` TF PR is extended to cover the 4 dev DBs the 8 ingest tags target.

**Rule (from D41, restated for clarity)**: no `dbt` command runs under MWAA post-cutover. Every dbt build in prod goes through a dbt Cloud job. The Airflow side of the boundary uses `DbtCloudRunJobOperator` / `create_dbt_cloud_task_group()` and nothing else. `dags/dbt/`, `dags/utils/dbt.py`, and all MWAA-side dbt CI vanish at cutover.

D41's earlier enumeration of "22 DAGs to delete" listed only the standalone `dbt_*.py` DAGs. It missed the **8 ingest-coupled DAGs that embed a `dbt.create_dbt_dag(...)` task group inside a larger data-ingest pipeline.** This document is the plan for closing that gap.

---

## Scope: 8 ingest DAGs still on MWAA dbt pattern

Confirmed 2026-07-19 via exhaustive scan of `origin/dbt-cloud-migration`:

| # | fes-airflow DAG | Current dbt tag selector | Models in dbt-fes-ae | Downstream Airflow deps |
|---|---|---|---|---|
| 1 | `dags/fanapp/fanapp_mdm.py` | `mdm_sdp` | `models/mde/mdm_sdp/` | verify |
| 2 | `dags/google_ad_manager/google_ad_manager.py` | `google_ad_manager` | 1 schema in AE | verify |
| 3 | `dags/identity/cassandra_extract.py` | `identity` | `models/identity/orchestration/`, `models/identity/unified_profile/` | verify |
| 4 | `dags/impact/impact.py` | `impact` | `models/fes_integrations/impact/` | verify |
| 5 | `dags/loyalty/loyalty_bonus_postgres_to_s3_ingest.py` | `fesbonus` | 1 schema in AE | `compare_row_counts()` post-task |
| 6 | `dags/loyalty/loyalty_postgres_to_s3_ingest.py` | `fesloyalty` | 2 schemas in AE | `compare_row_counts()` post-task |
| 7 | `dags/magnite/magnite_dag.py` | `magnite` | `models/fes_integrations/magnite/` | verify |
| 8 | `dags/salesforce/sfmc_optin_preferences_import.py` | `optin_preferences` | 1 schema in AE | verify |

All 8 pass `tags=["<selector>"]` to `dbt.create_dbt_dag()` — the internal helper expands that to `dbt run --select tag:<selector>` in MWAA. The migration path is: **new dbt Cloud job with the same `--select tag:<selector>` selector, then swap the DAG's `dbt.create_dbt_dag(...)` call for `create_dbt_cloud_task_group(job_id=...)`.**

Reference implementation: `dags/dbt/dbt_loyalty_6hours.py` (D41-canonical) — one Airflow trigger, one dbt Cloud job, no MWAA-side dbt.

---

## Substeps

Ownership legend: 🤖 = Claude session, 👤 = Alex, 🧑‍💻 = other engineer, ⚙️ = automation.

### Phase 0 — Per-DAG audit (before we touch anything)

**§0.1. Verify tagged models exist in `dbt-fes-ae` for each of the 8 tags** 🤖 ✅ DONE 2026-07-19
Confirmed via fixed-string search: all 8 tags have at least one model YAML tagged in dbt-fes-ae `origin/main`. No model migration needed — models were imported during the earlier Fusion parse-cleanup, just never wired to dbt Cloud jobs.

**§0.2. Per-tag: enumerate the exact model set that each new dbt Cloud job will build** 🤖 ✅ DONE 2026-07-19
Ran `dbt ls --resource-type model --output json` against dbt-fes-ae `fix/fusion-parse-cleanup` (4-commits ahead of origin/main; delta is CI-only, tag map identical). Bucketed all 980 models by tag. Model counts per ingest tag: `mdm_sdp` 3, `google_ad_manager` 9, `identity` 5, `impact` 1, `fesbonus` 8, `fesloyalty` 25, `magnite` 1, `optin_preferences` 6. **Zero tag collisions** with the 22 existing standalone-DAG selectors (loyalty_6hours, loyalty, fanflow, hourly, daily, xtremepush, users, sources, fangraph, etc.). Resolves open Q1 (collisions), Q2 (`optin_preferences` vs `dbt_xtremepush` — no overlap), Q3 (`fesloyalty` vs `dbt_loyalty` — no overlap). Full output: [`dbt-in-airflow-removal-model-lists.md`](dbt-in-airflow-removal-model-lists.md).

**§0.3. Per-DAG: identify seed dependencies** 🤖 ✅ DONE 2026-07-19
Scanned each tag's model set for `depends_on.nodes` starting with `seed.fes_data.`. **Zero seed dependencies** across all 8 tags. Resolves open Q6 (seed loading). No pre-load ceremony needed for cutover. Seed handling remains FBG zero-CI pattern (manual load via Cloud IDE when a CSV changes) — same as post-cutover-architecture.md and analytics-project-split.md prescribe.

**§0.4. Per-DAG: identify data-interval / context-var usage** 🤖 ✅ DONE 2026-07-19
Grepped every model file in each tag's set for `{{ var(...) }}`, `{{ env_var(...) }}`, and bare Jinja interval keywords. Two tags **require** `steps_override=[...]`:
- **`identity`**: 2 models — `loyalty_private_fan_id_map` + `martech_private_fan_id_map` — use `var('data_interval_start')`.
- **`optin_preferences`**: 4 models — `xp_optin_preferences_delta`, `xp_optin_preferences_snapshot`, `xp_push_last_opened_delta`, `xp_push_last_opened_snapshot` — use `var('data_interval_end')`.

The other 6 tags don't reference runtime intervals — no `steps_override` needed. Note: `mdm_sdp` uses 12 static `var(mdm_*, sdp_*)` refs and `optin_preferences` has 1 static `var(tenant_id_fanapp)` — all declared at project scope in `dbt_project.yml`, resolved at parse time. Full scan: [`dbt-in-airflow-removal-context-var-scan.md`](dbt-in-airflow-removal-context-var-scan.md).

**Implication for §2.3 and §2.8**: those two per-DAG substeps must pass `steps_override=[...]` mirroring the MWAA-side helper (`data_interval_start | ts`, `data_interval_end | ts`, `ds_nodash`) — see [`dbt-in-airflow-removal-migration-diffs.md`](dbt-in-airflow-removal-migration-diffs.md) §2.3 and §2.8 for the exact payload.

**§0.5. Per-DAG: identify upstream sensors and downstream tasks that must be preserved** 🤖 ✅ DONE 2026-07-19
Read all 8 DAGs in full. Cataloged the exact upstream/downstream shape per DAG. **Zero** external DAGs `ExternalTaskSensor` on any of the 8 DAGs or their internal dbt task-groups (confirmed via `grep external_dag_id` + task-group name grep over `dags/`). Migration is fully contained. All 8 current TaskGroup names (`dbt_mdm_sdp`, `dbt_google_ad_manager`, `identity_dbt`, `dbt_impact`, `bonus_dbt`, `loyalty_dbt`, `dbt_magnite`, `dbt_optin_preferences_group`) will be preserved as `group_id=` on the new `create_dbt_cloud_task_group()` — no downstream wiring changes anywhere. Also caught: `loyalty_postgres_to_s3_ingest.py` is the only DAG with `build_flag=True` (Q4); `catchup=True` (unique to this DAG among the 8); `sfmc_optin_preferences_import.py` has `end_date=2026-06-09` (TEMPORARY). Full per-DAG blueprint (before/after Python): [`dbt-in-airflow-removal-migration-diffs.md`](dbt-in-airflow-removal-migration-diffs.md).

### Phase 1 — Provision 8 new dbt Cloud prod + dev jobs

**§1.1. Extend `scripts/dbt_cloud.sh` provision list from 21 → 29 jobs** 🤖 ✅ DONE 2026-07-19  (30 rows total — added `--only <name>` filter flag for safe re-provisioning of only new entries)
The provisioning script (in `fes-airflow` on `dbt-cloud-migration` branch) currently enumerates the 21 standalone-DAG selectors. Add 8 entries — one per ingest DAG:

```
dbt_fanapp_mdm            mdm_sdp
dbt_google_ad_manager     google_ad_manager
dbt_identity              identity
dbt_impact                impact
dbt_fesbonus              fesbonus
dbt_fesloyalty            fesloyalty
dbt_magnite               magnite
dbt_optin_preferences     optin_preferences
```

Naming: `dbt_<ingest_dag_short_name>` for clarity in the dbt Cloud UI. Selectors match the current MWAA-side `tags=[...]` values exactly. All 8 get `triggers.schedule=false` and NO cron populated (Airflow-triggered, same shape as `dbt_loyalty_6hours` job `70437463791502`).

**§1.2. Provision the 8 new dev + prod jobs via `scripts/dbt_cloud.sh provision-jobs`** 🤖 ✅ DONE 2026-07-19  (dev IDs `70437463793534`–`70437463793541`, prod IDs `70437463793542`–`70437463793549` — see `deploy-jobs.md`)
Run the extended script. Captures 8 new dev + 8 new prod job IDs into `/tmp/dbt-cloud-job-ids.csv`. Paste into `deploy-jobs.md` under a new "Ingest-triggered jobs" subsection.

**§1.3. Update `deploy-jobs.md`** 🤖 ✅ DONE 2026-07-19  (new "Ingest-DAG-triggered jobs" subsection added with all 16 IDs)
Add a new subsection for the 8 ingest-triggered jobs. Table rows: `Job name | Selector | Dev ID | Prod ID | Schedule (all "Airflow-triggered")`.

### Phase 2 — Migrate each of the 8 DAGs (bulk of the work)

**Per-DAG template** (applied identically to all 8):

1. Add job-ID constant at top of file:
   ```python
   DBT_CLOUD_<UPPER>_JOB_ID = config.get_value_for_env(
       dev=<from §1.2>,
       prod=<from §1.2>,
   )
   ```
2. Replace the `from utils import dbt` import with (or add) `from utils.dbt_cloud import create_dbt_cloud_task_group`.
3. Delete `DBT_PATH = "/usr/local/airflow/dags/dbt/"`.
4. Replace the `dbt.create_dbt_dag(...)` block with a `create_dbt_cloud_task_group(group_id=..., job_id=...)` call. Keep the same `group_id` name as the current TaskGroup so downstream sensors keep resolving.
5. Delete `auth_env={...}` — dbt Cloud handles credentials at the project level via SVC_DBT_CLOUD_ROLE keypair.
6. Delete `skip_tests`, `allow_empty_upstream`, `namespace`, `build_flag` — none of these have Cloud analogs; `dbt build` includes tests by default; empty selectors would fail at job creation time (not at DAG parse).
7. Preserve the >> wiring (upstream sensors → new task group → downstream tasks).
8. Run local `python -c "import <dag>"` to verify parseability.

**§2.1. `dags/fanapp/fanapp_mdm.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_fanapp_mdm` (tag `mdm_sdp`)
- Constant: `DBT_CLOUD_FANAPP_MDM_JOB_ID`
- Watch for: mdm helpers (extract_mdm_sdp_team_mapping SQLExecuteQueryOperator) — those stay MWAA (they're pure Snowflake SQL, not dbt).

**§2.2. `dags/google_ad_manager/google_ad_manager.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_google_ad_manager` (tag `google_ad_manager`)
- Constant: `DBT_CLOUD_GOOGLE_AD_MANAGER_JOB_ID`
- Wiring: `previous_tg >> dbt_gam` → `previous_tg >> run_dbt_gam`.

**§2.3. `dags/identity/cassandra_extract.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_identity` (tag `identity`)
- Constant: `DBT_CLOUD_IDENTITY_JOB_ID`
- Wiring: `summarize_results(...) >> identity_dbt` — group_id preserved.
- 🔴 **Must pass `steps_override=[...]`** per Phase 0 §0.4 finding — 2 models under this tag use `var('data_interval_start')`. See [`dbt-in-airflow-removal-migration-diffs.md`](dbt-in-airflow-removal-migration-diffs.md) §2.3 for exact payload.
- Tag collision check (Phase 0 §0.2): none.

**§2.4. `dags/impact/impact.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_impact` (tag `impact`)
- Constant: `DBT_CLOUD_IMPACT_JOB_ID`
- Wiring: `export_to_s3 >> s3_to_snowflake_sql >> dbt_impact` → `... >> run_dbt_impact`.

**§2.5. `dags/loyalty/loyalty_bonus_postgres_to_s3_ingest.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_fesbonus` (tag `fesbonus`)
- Constant: `DBT_CLOUD_FESBONUS_JOB_ID`
- Wiring: `load_tasks >> bonus_dbt` + `bonus_dbt >> compare_task`. Preserve `compare_task = compare_row_counts()` after.

**§2.6. `dags/loyalty/loyalty_postgres_to_s3_ingest.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_fesloyalty` (tag `fesloyalty`)
- Constant: `DBT_CLOUD_FESLOYALTY_JOB_ID`
- Wiring: `load_tasks >> loyalty_dbt` + `loyalty_dbt >> compare_task`. Preserve `compare_row_counts()`.
- **Note**: current MWAA call passes `build_flag=True` (uses `dbt build` instead of `dbt run`). Under Cloud, `dbt build` is the job's default. No change needed.

**§2.7. `dags/magnite/magnite_dag.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_magnite` (tag `magnite`)
- Constant: `DBT_CLOUD_MAGNITE_JOB_ID`
- Wiring: `export >> dbt_magnite` → `export >> run_dbt_magnite`.

**§2.8. `dags/salesforce/sfmc_optin_preferences_import.py`** 🤖 ✅ DONE 2026-07-19
- Job: `dbt_optin_preferences` (tag `optin_preferences`)
- Constant: `DBT_CLOUD_OPTIN_PREFERENCES_JOB_ID`
- Wiring: `copy_from_sfmc_sftp >> check_for_file >> load_to_snowflake >> dbt_group` — group_id `dbt_optin_preferences_group` preserved.
- 🔴 **Must pass `steps_override=[...]`** per Phase 0 §0.4 finding — 4 models under this tag use `var('data_interval_end')`. See [`dbt-in-airflow-removal-migration-diffs.md`](dbt-in-airflow-removal-migration-diffs.md) §2.8 for exact payload.
- Tag collision check (Phase 0 §0.2): resolves Q2 (dbt_xtremepush overlap) — **no collision**. `dbt_xtremepush` selects `tag:xtremepush`; all 6 `optin_preferences`-tagged models are exclusive to `optin_preferences`.
- **TEMPORARY DAG**: `end_date=2026-06-09`. Cloud job still needed through then; can be state=2'd afterward.

### Phase 3 — Verification on dev

**§3.1. Parse-check all 8 migrated DAGs locally + on dev MWAA** 🤖 ✅ LOCAL DONE 2026-07-19  (all 8 `ast.parse`-clean; on-MWAA parse verified when branch redeploys to dev)
Run `python -c "from dags.<path> import dag"` for each (or use dbt Cloud CLI's Airflow validation script if present). Ensures no `utils.dbt` imports linger.

**§3.2. Trigger each of the 8 dev jobs via API to smoke-test model selection** 🤖 🟡 PARTIAL 2026-07-19  (3 canaries triggered on dev — `dbt_magnite` `dbt_impact` `dbt_identity`; each errored on `SVC_DBT_CLOUD_ROLE` missing `MODIFY`/`OWNERSHIP` grants on dev source/orchestration tables. Migration plumbing proven correct — steps_override applied, selector matches. Full 8-run smoke gated on dev grants extension — see `coupling-test-plan.md` §Test 9)
```bash
# For each of the 8 dev job IDs:
curl -H "Authorization: Token $DBT_CLOUD_TOKEN" \
  -X POST "https://sh023.us1.dbt.com/api/v2/accounts/70437463654557/jobs/<dev_job_id>/run/"
```
Expected: all 8 dev runs succeed. Failing runs surface tag-mismatch or model-configuration issues we didn't catch in §0.2.

**§3.3. Trigger each of the 8 migrated DAGs on dev MWAA** 👤 (BLOCKED on §3.2a)

**§3.2a. Grant dev SVC_DBT_CLOUD_ROLE the required USAGE + CREATE + OWNERSHIP + SELECT** 🤖 ⏳ AWAITING USER RUN 2026-07-19
Run `projects/dbt_cloud_migration/sql/dev_pre_walkthrough_grants_and_ownership.sql` — bespoke dev variant of `sql/cutover_ownership_transfer.sql`. Iterates a hardcoded classification list (55 dbt-materialized targets → OWNERSHIP; ~37 ingested `_EXT`/landing tables → SELECT; 5 dev DBs → USAGE; 12 schemas → USAGE+CREATE), because dev tables are owned by heterogeneous admin roles (not filterable by `owner = SVC_MWAA_ROLE` like the prod script). Dry-run first (`is_dry_run := TRUE` default), inspect `FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG` DRY_RUN rows, then flip `is_dry_run := FALSE`. Idempotent. Note: this unblocks §3.3 without waiting for the `dbt-cloud-grants-full-scope` TF PR (which is the durable source for prod cutover — task #71).
```bash
snow sql -c FAN_DATA_EXCHANGE_DEV \
  -f projects/dbt_cloud_migration/sql/dev_pre_walkthrough_grants_and_ownership.sql \
  --enable-templating NONE
```

Then deploy dbt-cloud-migration branch to dev MWAA (already happens automatically via `deploy_dev.yml` on PR pushes). Manually trigger each of the 8 DAGs from Airflow UI. Verify:
- Ingest half runs unchanged (still MWAA-side SQL, Snowflake operators, sensors).
- New `run_dbt_*` task group triggers the dev dbt Cloud job.
- Job runs to completion; sensor releases; `log_run` logs the metadata.
- Downstream tasks (`compare_row_counts()` for loyalty ingests, export tasks for others) fire correctly.

**§3.4. Parallel-run diff for the 8 tag groups** 🤖
For each of the 8 tags, use the same shadow-schema pattern as the main cutover:
- MWAA-dev writes to `<DB>.<SCHEMA>_MWAA_SHADOW`
- Cloud-dev writes to `<DB>.<SCHEMA>` (default alias)
- Run `parallel_run_verify.sql` HASH_AGG diff for each `--select tag:<tag>` model set

Timeline note: parallel-run for all 8 in one dev window is expensive. Prioritize by data blast-radius: `fesloyalty` + `fesbonus` first (touch prod loyalty state), then `magnite`, `impact`, `google_ad_manager` (revenue/ads), then `identity`, `mdm_sdp`, `optin_preferences` (identity + segments). Accept scoped-parallel-run if timeline is tight.

**§3.5. Extend `coupling-test-plan.md`** 🤖 ✅ DONE 2026-07-19  (added §Test 9 — Ingest-DAG handshake class + Fast-path smoke section with canary results + grants gap action items)
Current coupling test (H1, F1) proves the single `dbt_loyalty_6hours` handshake. Add a **§Test 9** that proves the same trigger-sensor mechanism works for each of the 8 new ingest DAGs. Not 8 separate tests — one that verifies the class of handshake generically.

### Phase 4 — Cleanup on `fes-airflow` branch `dbt-cloud-migration`

Only run these AFTER Phase 3 is green.

**§4.1. Delete `dags/utils/dbt.py`** 🤖
The MWAA dbt helper. No `dags/` callers remain after Phase 2. Verify:
```bash
git grep -l "from utils import.*\bdbt\b\|from utils.dbt \|utils\.dbt\." origin/dbt-cloud-migration -- 'dags/' | \
  grep -v 'dags/utils/dbt.py'
# Expected: (empty)
```

**Also update tests that import `utils.dbt`** — 9 files (broader than initial audit, revised 2026-07-19):

**Keep + strip the utils.dbt mock** (test surface is still relevant):
- `tests/test_no_import_errors.py` — remove `from utils import dbt`, the `BASE_TEST_MANIFEST` fixture, the `fake_load_manifest` function, and the `@patch.object(dbt, "load_manifest", ...)` decorator. Keep the `DagBag` load assertion — it's the actual "all DAGs still parse" check.
- `tests/dags/test_magnite_curate.py` — remove `from utils import dbt`, `FAKE_MANIFEST`, `_fake_load_manifest`, and the `with patch.object(dbt, ...)` wrapper. Keep everything else — the DAG structure assertions (`test_dag_has_dbt_task_group` checks `dbt_magnite` group_id which still exists post-migration) and the `fetch_to_s3` behavioral tests are still valid.

**Delete outright** — these test dead helpers (`create_dbt_dag`, `create_dbt_sources_dag`, `create_dbt_task`) that leave with `utils/dbt.py`:
- `tests/dags/test_run_dbt.py`
- `tests/dags/test_run_dbt_allow_empty.py`
- `tests/dags/test_run_dbt_full_refresh.py`
- `tests/dags/test_run_dbt_build.py`
- `tests/dags/test_run_dbt_tags.py`
- `tests/dags/test_run_dbt_skip_tests.py`
- `tests/dags/test_run_source_dbt.py`
- `tests/utils/test_dbt.py`

Coverage of the new `utils.dbt_cloud` helper already exists in `tests/utils/test_dbt_cloud.py` (committed prior sessions per `679c684a`).

**§4.2. Delete `dags/dbt/` entirely** 🤖
```bash
git rm -r dags/dbt/
```
~3,780 paths at time of writing (dbt project tree + `packages/` + `ARCHIVE/` + `target/` + `logs/` + `dbt_project.yml` + `Makefile`).

**Precursor moves DONE 2026-07-19 (commits `f21c1406` + `ff8ea685`)**: `dbt_loyalty_6hours.py` moved to `dags/loyalty/dbt_loyalty_6hours.py`, its SqlSensor SQL moved to `dags/loyalty/sql/transaction_raw_replication_handshake_sensor.sql`, `template_searchpath` updated. Nothing else under `dags/dbt/` is referenced by any active DAG or test (verified by adversarial audit — see below).

**Workflow update DONE 2026-07-19** (precursor commit landed before Phase 4):

`.github/workflows/sync_files.yml` — the `Set up dbt Snowflake provider` + `Generate dbt artifacts` steps have been stripped. The deploy path is now checkout → github token → AWS creds → `aws s3 sync dags s3://... --delete` → notify. See fes-airflow commit for details. Left in place: the `DBT_ENV_USER / DBT_ENV_ACCOUNT / DBT_ENV_PRIVATE_KEY / DBT_ENV` GitHub secrets (still referenced by `generate_dbt_catalog.yml`, which §4.3 deletes — secrets can be removed from GitHub after §4.3 lands).

**§4.3. Delete obsolete CI workflows** 🤖
```bash
git rm .github/workflows/dbt_syntax_check.yml
git rm .github/workflows/deploy_dbt_seeds_dev.yml
git rm .github/workflows/deploy_dbt_seeds_prod.yml
git rm .github/workflows/push_dbt_seeds.yml
git rm .github/workflows/generate_dbt_catalog.yml
git rm .github/workflows/secure_view_dependency_check.yml
git rm .github/scripts/ci_check_secure_view_deps.py
git rm .github/scripts/ci_validate_syntax.py
```
Kept: `sqlfluff_fix.yml` (per user directive 2026-07-19).

**§4.3a. Delete one-time cutover migration scripts** 🤖 ✅ MOSTLY DONE 2026-07-19

Three of the four moved to brock-bot workspace and removed from `fes-airflow/scripts/` in commit `0950bec2`:
- `scripts/dbt_cloud.sh` → `projects/dbt_cloud_migration/scripts/dbt_cloud.sh`
- `scripts/dbt_cloud_populate_prod_schedules.py` → `projects/dbt_cloud_migration/scripts/`
- `scripts/dbt_cloud_activate_schedules.sh` → `projects/dbt_cloud_migration/scripts/`

Their `.env`-sourcing was rewritten to absolute `$HOME/repos/fes-airflow/.env` at move time so they still work from the new location. Full session edits (8 new job entries in provisioner, 8-name exclusion lists) preserved in `fes-airflow` git history at commit `f0b19a25`.

Remaining Phase 4 delete:
```bash
git rm scripts/dbt_cloud_populate_schedules.sh   # stale shell variant (dev IDs, superseded by .py version)
```
Kept in `fes-airflow/scripts/`: `mwaa_trigger.sh` (ongoing ops helper, unrelated to migration).

**§4.4. Verify no leftover dbt references** 🤖
```bash
# should ONLY match sqlfluff_fix.yml + dags/utils/dbt_cloud.py + dbt_loyalty_6hours.py (moved) + a few docstrings
git grep -lE "dags/dbt|from utils import.*\bdbt\b|utils\.dbt\.|DBT_PATH|create_dbt_dag|create_dbt_task" origin/dbt-cloud-migration
```
Any remaining hit is a bug — investigate.

**§4.5. Update `tox.ini` and any other repo-root config** 🤖
Search `tox.ini`, `.gitignore`, `.sqlfluffignore`, `README.md` for `dags/dbt` path references. Remove stale ones.

### Phase 5 — LAST substep: update the mermaid diagram

**§5.1. Update `post-cutover-architecture.md` mermaid diagram** 🤖 (LAST substep per user directive 2026-07-19)

The current diagram (line 25) shows ONLY `dbt_loyalty_6hours` triggering dbt Cloud from Airflow, with 5 cross-system edges. Post-migration, there are **9 Airflow→dbt Cloud trigger relationships** (loyalty_6hours + 8 ingest DAGs).

Diagram updates:
- Add 8 new Airflow ingest DAGs to the `AF` subgraph (each represented as a compact node; ingest-detail suppressed since only the dbt handshake matters at the cross-system level).
- Add 8 new dbt Cloud jobs to the `DC` subgraph.
- Add 8 new `dag <==> job` (trigger + poll) edges.
- Keep the existing 5 edges for `dbt_loyalty_6hours` unchanged (its coupling shape is unique: pre-dbt sensor + post-dbt export sensors).

Also update the doc's "Rules this diagram exists to enforce (D41)" section — Rule 1 currently states "One and only one dbt Cloud job is triggered by Airflow (`dbt_loyalty_6hours`)". Correct to: "Airflow triggers a dbt Cloud job iff there is ingest→dbt or dbt→export coupling that Airflow needs to gate on. Currently: 9 such couplings (dbt_loyalty_6hours + 8 ingest DAGs). Every other dbt Cloud job runs on its own cron with no Airflow involvement."

Also update the "dbt Cloud job trigger sources" table: add 8 new rows with `Triggered by: **Airflow** ingest DAG (no cron)`.

Update summary counts: `1 job Airflow-triggered` → `9 jobs Airflow-triggered`.

Update `diagrams.md` and any other diagrams that show the Airflow↔dbt-Cloud relationship — spot-check each.

---

## Timeline & risk

Realistic effort per DAG (Phase 2 core work): 20-40 minutes each × 8 = 3-5 hours of DAG editing. Phase 3 dev verification is the bulk of wall-clock — likely 1-2 days if we're serial (recommend running parallel-run diffs in parallel).

Cutover date impact: this work MUST complete before cutover. If it can't be done cleanly in the current 4-day window (target 2026-07-23), **cutover moves.** No option-3-style split-brain. The migration is done when this is done.

## Rollback plan

Independent of main cutover rollback. Two windows:

**Before cutover PR merges**:
- Revert Phase 2 DAG edits, revert Phase 4 deletions. `dbt-cloud-migration` branch returns to pre-Phase-1 state. New dbt Cloud jobs stay provisioned but idle (no cron, no trigger) — leave for next attempt.

**After cutover PR merges (T0+)**:
- Follow main cutover rollback (revert cutover PR → MWAA syncs old DAGs back → all 8 ingest DAGs return to MWAA-embedded dbt).
- No additional analytics-side rollback needed — this work is orthogonal to D42.
- 8 new dbt Cloud jobs stay provisioned; they simply stop being triggered.

## References

- **D41** (`decisions.md`) — the parent architectural rule. This document is the completion of D41 for the ingest-coupled DAG class.
- **`dbt_loyalty_6hours.py`** — the canonical D41-compliant DAG shape. Every migrated DAG in Phase 2 mirrors this pattern.
- **`utils/dbt_cloud.py`** — the `create_dbt_cloud_task_group()` helper. Zero changes needed; all 8 migrations consume its existing interface.
- **`deploy-jobs.md`** — the dbt Cloud job registry. Extended in §1.3.
- **`coupling-test-plan.md`** — extended in §3.5.
- **`post-cutover-architecture.md`** — mermaid diagram + rules updated in §5.1 (LAST substep).

## Open questions — all resolved by Phase 0 audit (2026-07-19)

1. **Tag collisions** — ✅ **None.** §0.2 verified all 8 ingest tags exclusive to their intended job. See [`dbt-in-airflow-removal-model-lists.md`](dbt-in-airflow-removal-model-lists.md).
2. **`optin_preferences` overlap with `dbt_xtremepush`** — ✅ **No overlap.** `dbt_xtremepush` selects `tag:xtremepush`; the 6 `optin_preferences`-tagged models are exclusive.
3. **`fesloyalty` overlap with `dbt_loyalty`** — ✅ **No overlap.** All 25 `fesloyalty`-tagged models are exclusive.
4. **`build_flag=True` semantics on `fesloyalty`** — ✅ Cloud job default is `dbt build --select tag:fesloyalty`; matches. **Delete the flag** in §2.6; no override needed.
5. **`compare_row_counts()` in loyalty ingests** — ✅ Queries Postgres + Snowflake source models (populated by the SqlToS3 ingest, not by dbt outputs). Sequenced after dbt to gate visibility of stale/missing rows. Preserved by `bonus_dbt >> compare_task` and `loyalty_dbt >> compare_task`.
6. **Seed loading** — ✅ **None.** §0.3 confirmed zero seed dependencies across all 8 tags.
7. *(new)* **External sensor targets on the 8 DAGs** — ✅ **None.** §0.5 grep confirmed no `ExternalTaskSensor` and no xcom_pull cross-references. Migration is contained; no downstream sensor updates.
8. *(new)* **`data_interval_*` var references in the 8 tag model sets** — ⚠ **2 of 8 tags require `steps_override`**: `identity` (2 models) and `optin_preferences` (4 models). Payload template: mirror `dags/utils/dbt.py:111-113` MWAA-side injection. See §2.3 / §2.8 for exact code.
