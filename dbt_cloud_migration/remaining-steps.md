# Remaining Steps — Live Tracker

Working checklist for the final push to cutover. **Update in place** as items complete or reshuffle. Cutover target: **~2026-07-23**.

The full narrative plan lives in [`monday-cutover-plan.md`](monday-cutover-plan.md); this file is the running checklist. Watch items to monitor after cutover live in [`post-cutover-watch-list.md`](post-cutover-watch-list.md).

**Ownership legend:** 👤 = you (human), 🤖 = current Claude session, 🧑‍💻 = other engineer, ⚙️ = automation/CI.

## Architecture invariant (do not violate)

Airflow interacts with dbt Cloud in exactly TWO ways: (a) trigger ONE dbt Cloud job after ingest sensors clear, (b) poll ONE dbt Cloud job to release a downstream export task. **Airflow never coordinates between multiple dbt Cloud jobs.** dbt-to-dbt chains live in dbt Cloud via `job_completion_trigger_condition`. Analytics `analytics_users` job is dbt-Cloud-cron-driven — never touched by Airflow (see D42 § one-way Mesh).

---

## Before cutover (still open)

- [ ] **1. Coordinate merge freeze / announce cutover window** 👤 — no other merges to `fes-airflow`, `dbt-fes-ae`, `dbt-fes-analytics` during cutover.
- [ ] **2. Post-code-freeze dbt model sync** 🤖 — after fes-airflow code freeze **2026-07-21 19:00**, port any dbt model changes that landed on `fes-airflow/main` (in `dags/dbt/**`) between the `dbt-cloud-migration` branch point and code-freeze cutoff into their new homes:
  - **Baseline commit**: `dbt-cloud-migration` branched from `main` at the last common ancestor. Diff: `git log <merge-base> origin/main -- dags/dbt/ dags/utils/dbt.py` in fes-airflow. Anything touched needs to be forward-ported.
  - **Routing** (per D42): models under `dags/dbt/models/fes_users/<one of the 5 mover subfolders>/` → **`dbt-fes-analytics`** repo; everything else under `dags/dbt/models/` → **`dbt-fes-ae`** repo (same relative path).
  - **Watch for**: (a) new `ref('X')` calls in analytics-repo files → rewrite to `ref('fes_data', 'X')` if X is an AE model; (b) new seed refs → rewrite to `source('fes_integrations_dbt_seeds', 'X')`; (c) new sources / macros / schema.yml entries → carry over verbatim.
  - **Verify**: `dbt parse` + `dbt compile` clean on both repos before cutover step A.

## At cutover moment

**Permissions fallback (Airflow → dbt Cloud only)**: if any `run_dbt.trigger` or `run_dbt.wait` task in the first prod run 403s against dbt Cloud, regenerate the prod service token as **Job Admin** (broader role, guaranteed to work), repopulate `/airflow/connections/dbt_cloud_ae` via Datadog Self-Service, and retry the failed task. **This only applies to dbt Cloud API 403s** — Snowflake permission errors on the dbt Cloud side (dbt models failing to write to a warehouse/schema) are a different animal, handled by the grants PR #2916 + ownership transfer SQL.

- [ ] **A. Merge fes-airflow branch `dbt-cloud-migration` → main** 👤 → `deploy_prod.yml` syncs new DAGs to prod MWAA. HEAD at `a88f0b10`.
- [ ] **B. Verify prod MWAA S3 sync succeeded** 🤖 — `gh run list --workflow=deploy_prod.yml --branch=main`.
- [ ] **C. `GRANT ROLE SVC_DBT_CLOUD_ROLE TO ROLE SVC_MWAA_ROLE`** 👤 (D21 safety net — so MWAA-owned service can still read anything dbt-Cloud now owns).
- [ ] **D. Run** [`sql/cutover_ownership_transfer.sql`](sql/cutover_ownership_transfer.sql) 🤖 with `is_dry_run := FALSE`. Command: `snow sql -c FAN_DATA_EXCHANGE_PROD --enable-templating NONE -f projects/dbt_cloud_migration/sql/cutover_ownership_transfer.sql`. Expect ~1,347 SUCCESS rows.
- [ ] **E. Activate schedules** 🤖 — `scripts/dbt_cloud_activate_schedules.sh <prod-job-ids.csv>`. PATCHes `triggers.schedule=true` on 20 AE jobs (30 minus 10 in EXCLUDED). `dbt_fangraph` is NOW INCLUDED (2026-07-21 removed from exclusion — Fusion validation passed).
- [ ] **F. Activate analytics job** 🤖 — separate one-line PATCH: `analytics_users` (`70437463793734`) `triggers.schedule=true`. Uses `DBT_CLOUD_ANALYTICS_TOKEN`.
- [ ] **G. Monitor** first `dbt_fanflow` (hourly) → `dbt_loyalty` (chain) → `dbt_fangraph` (10am UTC) → analytics `analytics_users` (13:35 UTC) runs in dbt Cloud UI. Watch [`post-cutover-watch-list.md`](post-cutover-watch-list.md).

## Post-cutover

- [ ] Migrate this project's dev credential + jobs into Terraform (currently created via dbt Cloud UI per D19).
- [ ] **D42 §1a — hoist the 12 fes_users residuals to AE-native domains** 🧑‍💻 (deferred per leave-in-place variant). AE-internal PR: `git mv` the 12 out of `models/fes_users/<analyst>/` into AE-native domains (`models/fangraph/ltv_processed/`, `models/fanapp/installs/`, `models/dimensions/`, etc. — see `analytics-project-split.md` §1a table for suggested targets). Update each model's `config.database`/`schema` from `FES_USERS.<ANALYST>` to domain-native (e.g. `FANGRAPH.LTV_PROCESSED`). Downstream refs resolve automatically via `ref()`. When complete: AE `dbt_users` job becomes redundant → deprecate it.
- [ ] **Consider `job_completion_trigger_condition` from AE `dbt_users` → analytics `analytics_users`** (deferred per D42 leave-in-place variant). Cleaner than cron-offset. Only worth wiring once the split is proven stable in prod.
- [ ] **Refine ownership-transfer filter** — current filter is `owner = SVC_MWAA_ROLE` only, doesn't cross-check dbt model list. Any table MWAA created for non-dbt purposes in a target DB would transfer incorrectly. Watch list §1.
- [ ] **Fix stale doc typo**: `coupling-test-plan.md` §Test 9 references `IDENTITY_DEV.IDENTITY__SOURCE` — actual schema is `SOURCE` (both dev and prod).
- [ ] **Delete 3 stale dbt Cloud smoke jobs** in the AE project (all `state=1` but paused, no schedule):
  - `70437463791193` `smoke_job`
  - `70437463792298` `smoke_chain_test_A`
  - `70437463792299` `smoke_chain_test_B`
  Delete via API. Only referenced by the 3 fes-airflow coupling-test DAGs below.
- [ ] **Delete 3 dev-only coupling-test DAGs from `fes-airflow`** — they exist only to prove the dbt Cloud handshake works and reference `smoke_job` (deleted per AE cleanup PR):
  - `dags/airflow_ops/dbt_cloud_coupling_test.py`
  - `dags/airflow_ops/dbt_cloud_coupling_test_failure.py`
  - `dags/airflow_ops/dbt_cloud_coupling_test_upstream_mock.py`
  All 3 tagged `dev-only`, `schedule=None`, manual-trigger only. Deploy to prod MWAA via S3 sync but never run there. Safe to delete post-cutover along with their tests (`tests/utils/test_dbt_cloud.py` stays — that tests the helper itself, not the DAGs).
- **Watch list**: monitor items in [`post-cutover-watch-list.md`](post-cutover-watch-list.md) — currently tracking ownership-drift on non-dbt tables incorrectly transferred to `SVC_DBT_CLOUD_ROLE`.

## Rollback (only if needed within 24h)

1. `git revert` the fes-airflow cutover merge on main → MWAA syncs old DAGs back.
2. `snow sql -f projects/dbt_cloud_migration/sql/cutover_rollback.sql` — auto-selects most recent SUCCESS transfer batch and reverses ownership. Drift-safe: skips anything not currently owned by `SVC_DBT_CLOUD_ROLE`.
3. `scripts/dbt_cloud_activate_schedules.sh --deactivate <prod-job-ids.csv>` sets all `triggers.schedule=false`.
4. Analytics `analytics_users`: separate PATCH to flip `triggers.schedule=false` (activation script is scoped to AE csv).

## Completed pre-cutover work

- [x] **Populate prod job crons** (2026-07-21) — ran `dbt_cloud_populate_prod_schedules.py`. All 20 activatable AE prod jobs now have their real crons set (dbt_daily 0 12 * * *, dbt_users 30 13 * * *, dbt_fangraph 0 10 * * *, etc.). 10 NO_CRON jobs skipped correctly. All 30 still `triggers.schedule=false` (dormant). Analytics `analytics_users` untouched (cron already `35 13 * * *`). **Script bug fixed**: original POST body ignored the cron string; use `date.type: "custom_cron"` per D-24.
- [x] **Ownership-transfer dry-run** — 2026-07-16, 1,347 rows, 0 errors. Confirmed with user 2026-07-21 that re-verification isn't needed (state stable).
- [x] **PR #2252 fes-airflow `dbt-cloud-migration` branch** — 8 ingest DAGs migrated + `dags/dbt/` deleted + `dags/utils/dbt.py` deleted + 6 obsolete CI workflows deleted + sync_files.yml stripped + tests cleaned. HEAD `a88f0b10`. Merge is cutover step A.
- [x] **D42 analytics-project-split (dbt Mesh)** — 3 PRs shipped:
  - `dbt-fes-ae#8` — folder-level `+access: public` + `groups.yml` (merged 2026-07-20)
  - `dbt-fes-analytics#4` — scaffold + 116 movers + 65 macros + 31 sources (merged 2026-07-20)
  - `dbt-fes-ae#9` — delete 116 mover SQL files + trim 5 subfolder yamls (merged 2026-07-21)
  - `dbt-fes-analytics#5` — 5 seed refs converted to `source()` (Mesh doesn't cross-project ref seeds; merged 2026-07-21)
- [x] **dbt Cloud FES Analytics project provisioned** (2026-07-21). Project `70437463666643`, prod env `70437463673099`, prod credential `70437463680264` (keypair, DBT_CLOUD user, SVC_DBT_CLOUD_ROLE, FES_USERS.SANDBOX), job `analytics_users` `70437463793734` cron `35 13 * * *`, `triggers.schedule=false`. Repository `70437463662581` attached. dbt debug + parse + compile all Success on main (124/124 models).
- [x] **`dbt_fangraph` removed from activation exclusion list** (2026-07-21) — Fusion validation passed 2026-07-14.
- [x] **fanapp-terraform PR #2916** — Grants for SVC_DBT_CLOUD_ROLE on all 12 needed schemas across FES_INTEGRATIONS/IDENTITY/LOYALTY/MDE/XP (both dev + prod). Merged 2026-07-16.
- [x] **Populate prod SSM `/airflow/connections/dbt_cloud_ae`** (2026-07-18). Validated end-to-end via `scripts/run-ssm-uri-test.sh`.
- [x] **Slack failure webhook** configured on prod jobs (2026-07-21).
- [x] **Ownership-transfer dry-run detail** (2026-07-16) — 1,347 rows (1208 TABLE + 139 VIEW), 0 errors. SQL script bugs fixed. Warehouse: `FDE_DEVELOPER_WH` (Medium). See `sql/cutover_ownership_transfer.sql`.
- [x] Ownership transfer + rollback SQL rewritten as dynamic MWAA-owner-guarded scripts (2026-07-17).
- [x] Folder moved from `dbt_cloud_migration/` (tracked) → `projects/dbt_cloud_migration/` (gitignored, personal workspace).
- [x] **Migration-scratch cleanup PRs opened** (2026-07-21):
  - **`dbt-fes-ae#11`** — deletes `macros/diff_test/{dbfork_final_verify,dbfork_row_hash_diff,pk_uniqueness_check}.sql` (one-shot Fusion parity tools hardcoded to loyalty ledgers + personal `FES_USERS.ALEX_SOTIS` sandbox), deletes `models/smoke/` (throwaway smoke model writing to personal schema) + its `dbt_project.yml` override, rewrites `README.md` to describe current reality. `dbt parse` clean with zero warnings after changes. +26 / −248.
  - **`dbt-fes-analytics#7`** — fixes README that linked to `fes-data-brock-bot/projects/dbt_cloud_migration/{analytics-project-split,local-development}.md` (both paths are in the gitignored personal workspace, 404 for everyone else). Also documents the `source('fes_integrations_dbt_seeds', ...)` pattern from #5. +14 / −4.
- [x] **fes-airflow PR #2252 AI-slop comment cleanup** (2026-07-21) — removed multi-line `TODO(dbt-cloud-migration)` planning notes from 6 export/integration DAGs, `# Post-migration (D37)` archaeology comments from 2 files, specific model-count comments that would rot ("2 of the 5 identity-tagged models..." → "Some identity models consume `var(...)` — pass through."), and trimmed the `dbt_loyalty_6hours` + coupling-test DOC_MDs. All 14 edited files ast.parse-clean, `black --check` unchanged, `flake8` count 0.

## Key IDs

### Analytics Engineering project — `dbt-fes-ae`
- dbt Cloud **account**: `70437463654557` (host `sh023.us1.dbt.com`)
- dbt Cloud **project**: `70437463666576` (dbt project name: `fes_data`, per D32)
- dbt Cloud **prod env**: `70437463672974` (Production, `fusion-stable`)
- dbt Cloud **prod credential**: `70437463679983` (SVC_DBT_CLOUD_ROLE, target=prod)
- dbt Cloud **prod jobs**: `70437463791501`–`70437463791522` + 8 ingest-DAG jobs `70437463793542`–`70437463793549`
  - `dbt_loyalty`: `70437463791501` (chains from `dbt_fanflow` via `job_completion_trigger_condition`)
  - `dbt_loyalty_6hours`: `70437463791502` (triggered from Airflow — permanent NO_CRON)
  - `dbt_fanflow`: `70437463791505` (hourly, chain root)
  - `dbt_sources`: `70437463791521`
  - `dbt_fangraph`: `70437463791522` — **activated at cutover** (Fusion validation done 2026-07-14)
  - `dbt_users`: `70437463791520` — retained under D42 leave-in-place variant (builds 12 fes_users residuals)
- dbt Cloud **dev env**: `70437463672950`

### Analytics project — `dbt-fes-analytics`
- dbt Cloud **account**: `70437463654557` (shared with AE project)
- dbt Cloud **project**: `70437463666643` (dbt project name: `fes_analytics`)
- dbt Cloud **prod env**: `70437463673099` (Production, `fusion-stable`, deployment_type=production)
- dbt Cloud **prod credential**: `70437463680264` (SVC_DBT_CLOUD_ROLE, keypair, target=default, db=FES_USERS, schema=SANDBOX, threads=4)
- dbt Cloud **prod job**: `analytics_users` `70437463793734` (cron `35 13 * * *`, 5-min offset from AE `dbt_users` `30 13 * * *`)
- dbt Cloud **dev env**: `70437463673098` (fusion-stable, no cred wired yet — dev not needed for cutover)
- dbt Cloud **repository**: `70437463662581` (`fanatics-gaming/dbt-fes-analytics`)
- Model scope: 116 of 128 fes_users models (12 residuals stay in AE `dbt_users`)
- Mesh: `dependencies.yml` declares `fes_data` upstream; 414 cross-project `ref('fes_data', X)` calls + 5 `source('fes_integrations_dbt_seeds', X)` calls

### Airflow (post-cutover)

- SSM connection: `/airflow/connections/dbt_cloud_ae` — populated in prod (2026-07-18)
- 9 Airflow-triggered dbt Cloud handshakes (all resolve through the SSM connection):
  - `dbt_loyalty_6hours` DAG → `70437463791502`
  - `fanapp_mdm` DAG → `70437463793542` (dbt_fanapp_mdm)
  - `google_ad_manager` DAG → `70437463793543`
  - `cassandra_extract` DAG → `70437463793544` (dbt_identity)
  - `impact` DAG → `70437463793545`
  - `loyalty_bonus_postgres_to_s3_ingest` DAG → `70437463793546` (dbt_fesbonus)
  - `loyalty_postgres_to_s3_ingest` DAG → `70437463793547` (dbt_fesloyalty)
  - `magnite_dag` DAG → `70437463793548` (dbt_magnite)
  - `sfmc_optin_preferences_import` DAG → `70437463793549` (dbt_optin_preferences)
