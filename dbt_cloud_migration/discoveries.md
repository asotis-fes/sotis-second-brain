# YOLO Discoveries — Gotchas Encountered

Things that were non-obvious, cost time, or diverged from the runbooks. Log them here so the next person doesn't get bitten by the same issue.

---

## D-24 — dbt Cloud API ignores top-level `schedule.cron` when `date.type` is not `custom_cron`

**What happened:** `scripts/dbt_cloud_populate_prod_schedules.py` initially set:
```python
current["schedule"]["cron"] = cron                                     # e.g. "0 12 * * *"
current["schedule"]["date"] = {"type": "every_day"}
current["schedule"]["time"] = {"type": "every_hour", "interval": 1}
```
POST returned 2xx, script printed `OK   dbt_daily cron='0 12 * * *'`, but a GET immediately after showed `cron: "0 * * * *"` — the custom value was silently ignored.

**Root cause:** dbt Cloud DERIVES the effective cron from `schedule.date.type` + `schedule.time.type` (both structured). The top-level `schedule.cron` string is a rendered *output* of those fields, not an input. `{date: every_day, time: every_hour}` always renders to `0 * * * *` regardless of what you PUT in `cron`.

**Fix:** use `date.type = "custom_cron"` and put the cron inside `date.cron`, and repeat at top-level:
```python
current["schedule"] = {
    "date": {"type": "custom_cron", "cron": cron},
    "time": {"type": "every_hour", "interval": 1},
    "cron": cron,
}
```
This is the same pattern I used earlier to set `analytics_users` (job `70437463793734`) with a `35 13 * * *` cron. On the AE `analytics_users` job it worked first try; when I re-used the older populate script for the 20 AE jobs it silently no-op'd. Bug caught by post-run GET verification.

**Discovered:** 2026-07-21 during pre-cutover cron populate. All 20 activatable AE prod jobs now have their real crons set (verified via GET-round-trip).

---

## D-25 — dbt Cloud service-token scope is per-project, not account-wide

**What happened:** After provisioning the new `dbt-fes-analytics` dbt Cloud project (2026-07-21), the existing `DBT_CLOUD_TOKEN` (which had `Job Admin` on the AE project) returned 404 on every API call against the new project's endpoints.

**Root cause:** dbt Cloud service tokens carry per-project permissions. A token scoped to project A can't see project B — including via `/accounts/<id>/projects/<B>/` endpoints, which return 404 as if the project doesn't exist. Not 403.

**Fix:** Two options: (a) grant the existing token `Job Admin` on the new project too, or (b) create a second token scoped to the new project. We picked (b) — `DBT_CLOUD_ANALYTICS_TOKEN` in `.env` — for cleaner blast-radius separation.

**Discovered:** 2026-07-21 during analytics-project setup.

---

## D-26 — Personal-schema-hardcoded scratch macros can quietly ship to origin/main

**What happened:** Three one-off validation macros (`macros/diff_test/dbfork_final_verify.sql`, `dbfork_row_hash_diff.sql`, `pk_uniqueness_check.sql`) shipped to `dbt-fes-ae/main` during the Fusion parity validation period (2026-07-12 → 2026-07-14). Two of them contained explicit references to my personal `FES_USERS.ALEX_SOTIS` sandbox and hardcoded loyalty ledger table lists. A cleanup commit (`48df903 Remove one-off diff_test/ macros`) existed on the `mesh/expose-all-models-public` branch but was rebased out before PR #8's actual merge — so `main` kept them.

**Similar pattern:** `models/smoke/dbt_cloud_smoke.sql` (dbt Cloud + Airflow round-trip proof, writing to `FES_USERS.ALEX_SOTIS`) also lingered. And the `README.md` still described the initial scaffolding state (pointed at my personal schema, referenced `fes-airflow/dags/dbt/macros/` paths that were deleted in the fes-airflow cleanup).

**Also in `dbt-fes-analytics`:** README had two external links pointing at `fes-data-brock-bot/projects/dbt_cloud_migration/{analytics-project-split,local-development}.md` — but `projects/*` is gitignored in brock-bot, so both links 404 for everyone else.

**Fix:** [dbt-fes-ae#11](https://github.com/fanatics-gaming/dbt-fes-ae/pull/11) + [dbt-fes-analytics#7](https://github.com/fanatics-gaming/dbt-fes-analytics/pull/7).

**Lesson:** After a migration wraps, actively sweep each touched repo for:
1. Any macro/model referencing a personal schema (`FES_USERS.<username>`)
2. Any README or comment referencing the "migration in progress" / "throwaway" state
3. Any doc link pointing at `fes-data-brock-bot/projects/` (gitignored)
4. Any dbt Cloud job created for one-shot smoke tests (stays paused, but clutters the UI)

Better yet: run this sweep BEFORE the migration PR merges, not after.

**Discovered:** 2026-07-21 during post-cleanup audit.

**Lesson:** Never trust dbt Cloud API `POST /jobs/{id}/` success alone. GET the job back and compare the field you changed — the API silently drops fields that aren't in a canonical shape.

---

## D-01 — `SVC_DBT_CLOUD` is a *display name*, not the login

**What happened:** dbt Cloud deployment credentials with Username=`SVC_DBT_CLOUD` returned JWT auth errors — `JWT token is invalid` from Snowflake.

**Root cause:** the `modules/snowflake-v2/service-user` Terraform module maps `service_username = "DBT_CLOUD"` to:
- Snowflake user `name` = **`DBT_CLOUD`** (this is what logs in)
- Snowflake user `login_name` = **`DBT_CLOUD`**
- Snowflake user `display_name` = `SVC_DBT_CLOUD` (cosmetic)
- Snowflake role = `SVC_DBT_CLOUD_ROLE`
- Default warehouse = `FDE_DBT_CLOUD_WH`

**Fix:** Username field in dbt Cloud deployment credentials must be `DBT_CLOUD`. Role stays `SVC_DBT_CLOUD_ROLE`.

**Lesson:** When a service user is created via the shared Terraform module, look up the actual `name`/`login_name` in the module source (`modules/snowflake-v2/service-user/main.tf`) — don't infer it from the display name.

---

## D-02 — SSM parameter must exist in Terraform *before* Datadog Self Service can update it

**What happened:** [Datadog SSM Self Service app](https://app.datadoghq.com/app-builder/apps/0f0cd1e3-34fa-44cc-bf2e-e5ab60f8b6a1) returned `'triggerWorkflow0' failed with error 'we executed the action but it returned an error response'` when trying to create a new parameter.

**Root cause:** The Self Service app only *updates* existing parameters that were pre-provisioned via Terraform with the SSM module's `ssm_placeholder_secure_strings` / `ssm_placeholder_strings`. For MWAA connections specifically, the flow is:

1. Add the connection name to `mwaa_connections` in `terraform/fes-data/compute/<env>/compute/local.tf`
2. Merge that PR → `root/fes-data/compute/mwaa-variables.tf` iterates the map and passes it to `modules/ssm`, creating placeholder with value `change me`
3. Populate the real value via Self Service app

**Fix:** Always PR the Terraform placeholder first. Only *then* use the Self Service app.

**Note:** The `enable_self_service = true` tag mentioned in the Confluence howto is *not* used by any existing fes-data MWAA connection in the repo (as of 2026-07-11). Existing connections update fine via the Self Service app without it — the tag may be documentation drift or a filter that isn't strictly enforced.

**Reference:** [HowTo: Secure Secret Management for Devs Without Direct AWS Access](https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/1030423097)

---

## D-03 — dbt Cloud "Fusion Stable" is what "Core compatible" was renamed to

**What happened:** Confusion about which dbt version to pick — the version dropdown briefly showed `1.7`, `Core compatible`, and now `Fusion Stable` / `Latest`.

**Reality:** dbt Cloud renamed the "Core compatible" release track to "Fusion Stable" in a recent UI update. They're the same track — Fusion engine, latest Core-compatible semantics, stable channel.

**Lesson:** Pick `Fusion Stable`. That's the modern name for what used to be documented as `Core compatible`.

---

## D-04 — `apache-airflow-providers-dbt-cloud` was in `constraints.txt` but not `requirements.txt`

**What happened:** Trying to use `DbtCloudRunJobOperator` in a fes-airflow DAG — provider not installed even though it appeared in the constraints file.

**Reality:** `docker/config/constraints.txt` lists Airflow 2.9.2's *full* dependency solve including every provider Apache pins. That's a resolver constraint, not an install list. `requirements/requirements.txt` is what actually installs into MWAA.

**Fix:** Add `apache-airflow-providers-dbt-cloud==3.8.1` to `requirements/requirements.txt`. Version pinned to match the constraints file's resolved version to avoid resolver churn.

**Lesson:** In fes-airflow, `constraints.txt` is a pin ceiling; `requirements.txt` is the truth. Both need the provider for it to end up installed on MWAA.

---

## D-05 — `deploy_dev.yml` PR trigger handles *both* dags sync AND MWAA env sync

**What happened:** Wondering how to install the new dbt-cloud provider on `fes-data-compute-dev-1` without merging to main.

**Reality:** `deploy_dev.yml` fires on `pull_request`. It calls two sub-workflows:
- `sync_files.yml` — pushes `dags/` to dev S3 with `aws s3 sync --delete` (the destructive one)
- `sync_mwaa_env.yml` — checks if `plugins/` or `requirements/requirements.txt` changed vs main; if so, triggers an MWAA env update on dev (~20–30 min)

**Fix:** Opening a PR is enough — no merge required to test on dev. But note the `--delete` on dags sync clobbers other in-flight dev deploys (see the `fes-airflow-dev-deploy` skill for the workaround for iteration).

**Lesson:** The PR-based dev deploy is the *only* way to install new providers on dev MWAA. The `fes-airflow-dev-deploy` skill only pushes `dags/`, not requirements.

---

## D-06 — MWAA secrets backend uses **URI format**, not JSON

**What happened:** Uncertainty about the SSM parameter value format for Airflow Connections — some Confluence pages show JSON examples.

**Reality:** `terraform/root/fes-data/compute/mwaa.tf:141-144` sets `secrets.backend_kwargs` to `{"connections_prefix": "airflow/connections", "variables_prefix": "airflow/variables"}` — no `full_url_mode: false` override. Default is URI mode.

**Format:** `<scheme>://<login>:<password>@<host>[:<port>][/<schema>][?<extras>]`

Example (dbt Cloud): `dbt-cloud://70437463654557:<TOKEN>@sh023.us1.dbt.com`

**Lesson:** Use the URI format. The JSON example in the SSM Self Service runbook is misleading for fes-data MWAA — that's for setups that override the backend to accept JSON.

---

## D-07 — dbt Cloud regional host is `<cell>.<region>.dbt.com`, not `cloud.getdbt.com`

**What happened:** Uncertainty about the `host` field in the Airflow connection URI. Provider docs default to `cloud.getdbt.com`.

**Reality:** FES's dbt Cloud tenant is `sh023.us1.dbt.com` (per the browser URL). Regional / cell-based dbt Cloud tenants have their own host prefix. The Airflow provider expects the exact host that the UI/API lives on.

**Fix:** URI host = `sh023.us1.dbt.com` (or whatever the URL shows). Not `cloud.getdbt.com`.

**Lesson:** Check the dbt Cloud URL bar. Anything more specific than `cloud.getdbt.com` needs to be preserved in the connection.

---

## D-09 — `sync-mwaa-env` skips silently if requirements change is not in the latest commit

**What happened:** Pushed a follow-up commit to the smoke DAG branch after the initial `requirements.txt` change was already committed. The next `PR: Deploy` run ran `sync-dags` successfully but the `sync-mwaa-env` job was SKIPPED — provider never installed. DAG landed on MWAA but broke with `ModuleNotFoundError: No module named 'airflow.providers.dbt'`.

**Root cause:** `.github/workflows/sync_mwaa_env.yml` uses `tj-actions/changed-files@v34` with `since_last_remote_commit: 'true'`, which diffs against **HEAD~1**, not against `main`. If the requirements change is in commit N-1 and commit N doesn't touch `requirements/requirements.txt` or `plugins/**`, the check reports "no change" and the env sync is skipped.

**Fix:** Push one more commit that touches `requirements.txt` (a comment addition works). That re-triggers the check with the file marked as changed vs HEAD~1.

**Lesson:** When you know the MWAA env needs to sync (new provider install, plugin change), make sure requirements.txt or plugins/ is in the **latest** commit on the branch — not just somewhere in the branch history. Or bundle it into the DAG commit itself.

**Bigger picture:** the `since_last_remote_commit` behavior is arguably a bug in `sync_mwaa_env.yml` — should be `base_sha` compared against main. Worth a follow-up PR to fix once the smoke test round-trip is done.

---

## D-10 — fanapp-terraform apply is gated on environment approval, merge alone isn't enough

**What happened:** Merged fanapp-terraform#2873 to create the `/airflow/connections/dbt_cloud_ae` placeholder. Assumed merge = apply. Tried to populate the value via Datadog Self Service and got the same "workflow returned error" as before. Placeholder didn't actually exist in SSM yet.

**Root cause:** fanapp-terraform's `TF` workflow on `push` to `main` uses GitHub environment protection rules. Post-merge, the apply job sits in `waiting` state until a designated approver clicks "Review deployments" and approves. Same pattern as fes-airflow's `deploy_dev.yml`.

**Fix:** After merge, go to [fanapp-terraform/actions](https://github.com/fanatics-gaming/fanapp-terraform/actions?query=branch%3Amain+event%3Apush), find the newest `TF` runs, and approve them. Only then does terraform actually apply.

**Lesson:** In fanapp-terraform, "merged" is not the same as "applied." Always confirm via GH Actions or by asking whoever the approver is. Applies to fes-airflow too — approval is required for both dags/ sync AND MWAA env sync.

---

## D-11 — `@task`-decorated Python callables cannot use `run_id` as a parameter name

**What happened:** A `@task` function `log_after(run_id: int)` that received `trigger_dbt.output` (the dbt Cloud run_id) via XCom raised `ValueError: The key 'run_id' in args is a part of kwargs and therefore reserved.` at execution.

**Root cause:** Airflow injects DAG-context variables as kwargs when calling `@task`-decorated functions. `run_id` is one of the reserved context keys (the DAG's own run identifier, e.g. `manual__2026-07-11T19:38:20...`). If a task parameter has the same name, `operator_helpers.determine()` refuses to resolve.

**Reserved context keys to avoid as `@task` parameter names:** `run_id`, `task_instance`, `ti`, `dag`, `dag_run`, `execution_date`, `logical_date`, `data_interval_start`, `data_interval_end`, `params`, `conf`, `var`, `ts`, `next_ds`, `prev_ds`, and others. Full list in `airflow.utils.context.Context`.

**Fix:** Rename the parameter — e.g. `dbt_run_id` instead of `run_id`. Downstream calls that expect `run_id=` (like `DbtCloudHook.get_job_run(run_id=...)`) still work because that's the *hook method's* parameter name, not the task's.

**Lesson:** When passing XCom-typed values into `@task` functions, avoid parameter names that overlap with Airflow context. Prefix task-input names with the source domain (`dbt_run_id`, `s3_key`, etc.) rather than using generic names that risk shadowing.

---

## D-12 — Fusion Stable + our legacy flags block parses the full fes_data tree

**What happened:** Copied the entire `fes-airflow/dags/dbt/` tree (1000 models, 64 macros, seeds/tests) into `dbt-fes-ae` and ran `dbt parse` on Fusion Stable. **It passed on the first try.**

**Why this matters:** This was the biggest hidden risk in the YOLO plan — that Fusion (~1.10 semantics) would reject a meaningful fraction of a 1.8-authored project. The 5 legacy compatibility flags in `dbt_project.yml` were speculative shims; we didn't know whether they'd be sufficient.

**Legacy flags currently set (all `false`):**
- `require_explicit_package_overrides_for_builtin_materializations`
- `require_generic_test_arguments_property`
- `require_resource_names_without_spaces`
- `require_yaml_configuration_for_mf_time_spines`
- `source_freshness_run_project_hooks`

**Lesson:** For projects following dbt-labs' 1.8 conventions closely, the standard set of legacy `require_*: false` flags appears sufficient to bridge to Fusion Stable at parse time. `dbt compile` and actual builds may still surface divergences — but the structural risk is gone.

**Follow-up:** As we run compile / build, note which flags are actually load-bearing (which behaviors break when flipped to `true`). Audit + remove unnecessary flags before final cutover.

---

## D-13 — Fusion creates `dbt_internal_packages/`; commit `package-lock.yml`

**What happened:** After the parse-check import merged, the dbt Cloud IDE surfaced two uncommitted changes:
- `.gitignore` modified — new line added: `dbt_internal_packages/`
- `package-lock.yml` — new file

The IDE couldn't pull latest main until these local changes were resolved (revert or commit).

**Root cause:** Fusion behaves slightly differently than dbt-core on the filesystem:
- Fusion downloads compiled package artifacts into `dbt_internal_packages/` (dbt-core doesn't create this dir)
- `dbt deps` writes `package-lock.yml` — dbt's package lockfile — into the project root

**Fix:** Both should be committed (`package-lock.yml`) or ignored (`dbt_internal_packages/`). Per fes-airflow's convention, `package-lock.yml` gets checked into git so all environments use identical resolved package versions. See dbt-fes-ae#3.

**Lesson:** When switching a repo from dbt-core to Fusion, expect at least these two housekeeping additions on the first `dbt deps` run. The lockfile is authoritative — commit it once, then future `dbt deps` runs produce no diff.

---

## D-14 — Fusion removes `target-path` and `packages-install-path` from `dbt_project.yml`

**What happened:** `dbt ls` failed with:
```
Error [InvalidConfig (dbt1005)]: 'target-path' cannot be specified in dbt_project.yml
```

**Root cause:** dbt Fusion removed several project-file config keys that dbt-core 1.8 accepts. Confirmed removed / no longer valid in `dbt_project.yml`:
- `target-path`
- `packages-install-path`

Not caught by our legacy behavior flags — this is a hard config-schema removal, not a behavior toggle.

**Fix:** Remove both keys from `dbt_project.yml`. If a non-default target dir is needed, use `--target-path` CLI flag or `DBT_TARGET_PATH` env var. In dbt Cloud, both directories are managed automatically — the removal is functionally invisible.

**Watch out for:** other config keys that fes-airflow used but Fusion doesn't accept. Rules of thumb — anything documented as "moved to CLI flag" in dbt 1.8+ release notes is a candidate. Grep the fes-airflow `dbt_project.yml` for other legacy patterns as we hit Fusion errors.

**Lesson:** Fusion's strictness on `dbt_project.yml` schema is a wall of small errors — remove and retry, don't fight it. Each error is a small file-edit.

---

## D-15 — Fusion parse recovered cleanly with dbt-autofix + a handful of manual fixes

**What happened:** First `dbt parse` against the full fes-airflow dbt tree on Fusion Stable produced 196 unique errors. After running `dbt-autofix deprecations --all` and making ~5 manual fixes, `dbt parse` returned exit 0.

**Key discoveries (each documented in detail under `fusion-migration/`):**

1. **`dbt-autofix` is the tool.** Fusion literally recommends it via `suggestion: try the autofix script`. One `--all` invocation covered ~180 errors: source freshness YAML restructure, YAML anchor top-level key removal, test argument format migration, `config.tests` moves, and behavior flag flipping. Should be step 1 of any Fusion migration.

2. **`require_generic_test_arguments_property: false` flag doesn't help.** The deprecation graduated to a hard error in Fusion/dbt 1.10+. The flag is ignored — migration is mandatory.

3. **`merge_exclude` was a silent typo for years.** Correct dbt-snowflake key is `merge_exclude_columns` (plural). Singular form was tolerated by 1.8 as unknown-and-ignored. Migrating to the plural form would ACTIVATE previously-broken column-exclusion behavior on 3 fes_integrations models. Chose to remove the typo'd key instead — preserves current production behavior. Follow-up work if the team wants actual exclusion.

4. **`analysis/` should be SQL-only in Fusion.** YAML `models:` declarations in `analysis/` clashed with `models/` declarations. 1.8 tolerated it silently.

5. **Fusion enforces `{{ ref() }}` targets at parse time.** dbt-core deferred to compile. Broken refs in `analysis/` — dead code that hadn't been noticed — surfaced immediately.

6. **Local Fusion install is fast and free.** `~/.local/bin/dbt` after the install script. Iteration loop is milliseconds — beats cloud IDE round-trip by orders of magnitude for the parse fix loop.

**References:** Full per-error-code write-ups in `projects/dbt_cloud_migration/fusion-migration/`.

---

## D-16 — Diff-test methodology gotchas from the loyalty ledger verification

Discovered while trying to prove Fusion output matches dbt-core output byte-identically. Multi-hour iteration; final method is captured in `macros/diff_test/dbfork_final_verify.sql` on the dbt-fes-ae side.

**Three separate methodology traps that produced misleading "diffs":**

1. **`dbfork_prod` contains T_mwaa data, not T_dbfork data.** The dbfork macro's `clone_prod=true` clones `prod.loyalty_state` — but prod.loyalty_state is itself a clone MWAA made from stage_final at an earlier T_mwaa. So dbfork_prod contains data as it existed at T_mwaa, not at T_dbfork. Comparing that against Fusion output (which uses dbforked stage at T_dbfork) produces timing drift.
   - **Correct comparison target:** `dbfork___prod__<STAGE>` (the dbforked source at T_dbfork), not `dbfork___prod__<LEDGER>` (MWAA's older output).

2. **FULL OUTER JOIN diffs are cardinality-sensitive.** If the JOIN key isn't uniquely identifying, duplicates produce cartesian pairings that show up as "matched_diff_hash" even when the underlying data is identical. loyalty_balance has 58,888 duplicate `loyalty_account_id` rows, and no candidate composite key (`+tenant_id`, `+fan_id`) adds any uniqueness. This produced 123,910 spurious "diffs" on a byte-identical clone.
   - **Correct method for non-unique-PK tables:** use `HASH_AGG(*)` fingerprints — PK-independent, join-free, immune to cardinality issues.

3. **Always window the diff query.** `HASH_AGG(*)` on 11B unfiltered rows will hang or blow through warehouse credit. Time-filter to a small recent window on a business-time column (`creation_time`, `fancash_updated_timestamp`, etc.).

**Final verification result (2026-07-12):** All 4 loyalty ledgers produce Fusion output byte-identical to a direct SQL clone of the same source. HASH_AGG matches exactly across billions of rows aggregate (via windowed subsets).

Macros for future use:
- `dbfork_final_verify.sql` — recommended, HASH_AGG + windowed + Fusion-vs-stage comparison
- `dbfork_row_hash_diff.sql` — FULL OUTER JOIN on PK, only works if PK is truly unique
- `pk_uniqueness_check.sql` — sanity-check PK candidates before choosing a diff strategy

---

## D-24 — dbt Cloud supports "cron populated + inactive" via `triggers.schedule=false`

**What:** dbt Cloud's job `schedule` is a spec object (`{cron, date, time}`); `triggers.schedule` is a *separate boolean* controlling whether the schedule actually fires. Setting `schedule.cron` while keeping `triggers.schedule=false` stores the spec without activating it.

**Why it matters:** during cutover prep, all 21 prod jobs get populated with the correct cron via API before cutover moment. At cutover, a single API loop flips `triggers.schedule=true` on each — schedules go from "cocked" to "firing" in one PATCH per job. Reduces cutover moment complexity to a single command.

**Confirmed via dbt Cloud v2 API** — the `PATCH /jobs/{id}/` body accepts both fields independently. Behavior: cron stored, next-run computation happens when triggers.schedule flips to true.

---

## D-23 — `dbt build --select tag:nonexistent` exits 0, not non-zero

**What happened:** F1 coupling test on dev 2026-07-12 was expected to fail — `steps_override=["dbt build --select tag:selector_that_does_not_exist"]` in the failure-path DAG. But dbt Cloud reported **Success**, the sensor never triggered failure state, and `log_run` fired normally. `simulate_export` executed, tripped its `AssertionError` safety guard, and the coupling contract test never actually exercised the failure propagation path.

**Root cause:** dbt's `--select tag:X` when no nodes match the tag emits a warning (`"No nodes selected"`) and exits **0**. It's not an error — it's dbt saying "your selector matched nothing, but I finished cleanly." The dbt-cloud API sees exit 0, marks the run Success.

**Verified behavior**: applies to dbt-core 1.8, dbt-fusion Stable, and every intermediate dbt version I've seen. Not a version-specific quirk.

**Fix:** to force a genuine dbt Cloud Error state, use a command that dbt *itself* rejects at compile/resolve time. Reliable options in order of preference:

1. **`dbt run-operation _nonexistent_macro_xyz_`** — dbt tries to resolve the macro, doesn't find it, exits non-zero. Recommended.
2. **`dbt build --something-invalid`** — unknown CLI flag, exits at arg-parse. Works but noisier.
3. **`dbt garbage_subcommand`** — unknown subcommand. Works but obviously synthetic.

Applied fix in `dbt_cloud_coupling_test_failure.py`: switched `FAILING_STEPS` to `["dbt run-operation _macro_that_definitely_does_not_exist_xyz_"]`. Guaranteed to hit dbt's macro resolver, fail, and propagate as Error.

**Lesson for building "known-to-fail" test scaffolding:** don't assume dbt errors on things it treats as warnings. Empty selectors, missing sources with `dbt source freshness`, and even some model runtime errors can produce exit 0 depending on the `--fail-fast` flag and dbt version. When you *need* a failure, force it at a layer dbt can't skip — command resolution, arg parsing, or macro resolution.

**Bonus lesson from the test-DAG design:** the current `simulate_export` guard raises `AssertionError` unconditionally on execute. That's correct when we can guarantee upstream fails, but ambiguous when upstream succeeds — it can't distinguish "coupling contract broken (dbt failed but downstream still fired)" from "test setup didn't actually cause dbt to fail." Consider revising the guard to check dbt Cloud run status via the Hook and only assert when the run's `status_humanized == "Error"`. Not urgent; the current guard is loud enough.

---

## D-22 — Provider pins from never-merged branches don't inherit to sibling branches

**What happened:** The `dbt-cloud-migration` branch was created off `main`. Its first deploy to dev MWAA "succeeded" — DAGs synced, no errors — but CI's `PR: Test python` failed with `ModuleNotFoundError: No module named 'airflow.providers.dbt'`. Confusing: how can dev MWAA import the module but CI cannot?

**Root cause:** three overlapping surfaces install the provider differently:
- **Dev MWAA**: env-level install, persistent across deploys. The provider was installed once via PR #2249's `sync_mwaa_env.yml` run and stayed. `sync_files.yml` on subsequent branches only pushes `dags/` — doesn't touch the env unless `requirements/requirements.txt` or `plugins/` changed.
- **CI tox environment**: fresh install of `requirements.txt` on every GH Actions run. If the provider isn't pinned there, tests fail.
- **Prod MWAA**: never had the provider installed. Would fail at merge time without the pin.

Since PR #2249 was marked "dev-only, NOT merging to main" (per D40 draft-PR strategy), its `requirements.txt` change never landed on main. Every branch cut from main after that inherits main's `requirements.txt` — without the provider.

**Fix:** always pin new provider dependencies in `requirements/requirements.txt` on the migration branch, not just in the DAG-adding PR. Even if that PR is dev-only, downstream branches from main need the pin.

**Detection heuristic:** if dev MWAA works and CI/tox doesn't, check for install-state divergence — dev MWAA carries persistent state from prior deploys that CI doesn't share.

**Broader implication for D40 strategy:** the "dev-only PRs" pattern (per #2249) means their non-DAG changes (requirements, plugins) don't propagate. Anything the migration needs from a dev-only PR must be re-committed on the long-lived branch. In this case: `apache-airflow-providers-dbt-cloud==3.8.1` re-committed on `dbt-cloud-migration` at commit `88e1db72`.

---

## D-21 — `curl --fail` suppresses response bodies; use `--fail-with-body`

**What happened:** The initial provisioning script used `curl --fail` on POSTs — a common pattern to make curl exit non-zero on 4xx/5xx. But `--fail` also **suppresses the response body**. When dbt Cloud returned 400 on the first job creation, all we got was `curl: (56) The requested URL returned error: 400` — no clue *why*.

**Root cause:** curl's `--fail` was designed for the pre-web-API era when 4xx bodies were often empty error pages. Modern APIs (dbt Cloud, GitHub, most REST services) return actionable JSON error messages in 4xx bodies. `--fail` hides them.

**Fix:** use `--fail-with-body` (curl 7.76+, 2021). Behaves identically to `--fail` — exits non-zero on 4xx/5xx — but **prints the response body first**. dbt Cloud's error `{"data": {"settings": "'target_name' is a required property"}}` immediately told us the fix (see D-20).

**Lesson:** for any curl-based API integration, prefer `--fail-with-body` over `--fail`. The extra characters buy you every future error message dbt Cloud (or GitHub, or any REST API) ever returns.

**How to detect if the fleet uses old curl:** `curl --version | head -1`. If < 7.76, `--fail-with-body` doesn't exist — fall back to `--fail-early` combined with printing `%{http_code}` and body separately, or just drop `--fail` and check the response manually.

---

## D-20 — dbt Cloud `POST /jobs/` requires `settings.target_name`

**What happened:** First provisioning run POST returned:
```
{"data": {"settings": "'target_name' is a required property"}}
HTTP 400
```

The initial script body had `settings: {threads: 4}` — no `target_name`. dbt Cloud's job schema treats `settings.target_name` as required, even though the value gets overridden at run time by the environment's credential and/or `steps_override`.

**Fix:** added `"target_name": "default"` to the body's `settings` object, matching:
- The existing `smoke_job` (which uses `target_name: "default"`)
- The `credentials_id: 70437463679957` credential (which also has `target_name: "default"`)

**Why "default":** dbt Cloud's job settings.target_name is the string that becomes `{{ target.name }}` in dbt Jinja at runtime. FES models use `{{ 'PROD_DB' if target.name == 'prod' else 'DEV_DB' }}` conditionals — anything except literally `"prod"` resolves to the dev branch. `"default"` matches the credential and doesn't trigger prod-branch resolution.

**Lesson:** when creating dbt Cloud resources via API, don't assume required fields from casual reading of the response schema. Test with a minimal body, let the API tell you what's required (via `--fail-with-body`), and iterate. The Postman collection and OpenAPI spec don't consistently mark `settings.target_name` as required.

---

## D-19 — dbt Cloud v3 environment POST is full-replace, not PATCH

**What happened:** Attaching an existing credential (id `70437463679957`) to the Development env (id `70437463672950`) by sending a partial POST body `{"credentials_id": 70437463679957}` to `POST /api/v3/accounts/{id}/projects/{id}/environments/{env_id}/`. The credential was attached, but three other fields got clobbered:
- `name` reset from `"Development"` to `"New Environment"` (dbt Cloud's default for new envs)
- `type` shifted from `"development"` to `"deployment"`
- `dbt_version` demoted from `"fusion-stable"` to `"latest"` (would have violated D25)

**Root cause:** dbt Cloud's v3 environment endpoint treats POST as **full replace with defaults for any missing field**, not as a partial update / PATCH. There's no separate PATCH endpoint documented — POST is used for both create and update, but with idempotent-replace semantics.

**Fix (both immediate and for future work):** always **fetch → modify → POST full body** when updating an env via the v3 API. Never send a body with only the field you want to change.

```bash
# Correct pattern:
CURRENT=$(curl -s -H "Authorization: Token $TOKEN" ".../environments/{id}/")
MODIFIED=$(echo "$CURRENT" | jq '.data | .credentials_id = 70437463679957 | {name, type, dbt_version, credentials_id, connection_id, use_custom_branch}')
curl -s -X POST -H "Content-Type: application/json" -d "$MODIFIED" ".../environments/{id}/"
```

**Lesson:** dbt Cloud's API isn't uniformly RESTful across resource types. Some endpoints support partial updates, others don't. **Always test partial updates against a throwaway resource first before applying to a real one.** For the v3 environment endpoint specifically: full-body replace only.

**Related open question:** does the v2 `POST /jobs/` endpoint have the same behavior for job updates? Our `scripts/dbt_cloud.sh provision-jobs` only CREATEs (POST with no ID in URL), so we haven't hit this. But if we later PATCH jobs (e.g., swap `environment_id` at cutover moment), we need to verify or use fetch-modify-post pattern.

---

## D-18 — dbt Cloud has no "paused" job state; `state: 2` means deleted

**What happened:** While drafting `scripts/dbt_cloud.sh` for API-driven job creation, I assumed `state: 2` on dbt Cloud jobs meant "paused" — an intuition carried from other systems (Airflow DAGs, cron jobs). The provisioning script's POST body initially set `state: 2` as a belt-and-braces measure "so nothing runs even if the trigger config is wrong."

**Root cause:** dbt Cloud's job `state` field is an enum with exactly two meaningful values:
- `state: 1` = **active** (the default and only non-deleted state)
- `state: 2` = **deleted** (soft delete; equivalent to `DELETE /jobs/{id}/`)

There is no "paused" or "disabled" state. The [dbt Community Forum](https://discourse.getdbt.com/t/can-i-disable-a-dbt-job-from-being-run/9143) confirms: "there is no built-in native disable/deactivate feature for dbt Cloud jobs."

**Verified via** dbt-cloud-cli issue #24 ("Delete a job by updating state" — 1 → 2) and dbt Labs' own [`dbt-jobs-as-code`](https://github.com/dbt-labs/dbt-jobs-as-code) source. Its `deactivate-jobs` command implementation modifies **only the `triggers.*` booleans**, never touches `state`:

```python
cloud_job.triggers.github_webhook = False
cloud_job.triggers.git_provider_webhook = False
cloud_job.triggers.schedule = False
cloud_job.triggers.on_merge = False
```

**Fix:** Changed the provisioning script to set `state: 1` (active) with all `triggers.*` set to `false`. Airflow-triggered runs (`POST /jobs/{id}/run/`) work regardless of `triggers.*` — those fields only govern automatic firing (schedule, webhook, on-merge). Manual/API triggers are always allowed on `state: 1` jobs.

**Lesson for dbt Cloud API work:** Don't infer state semantics from other systems. Every dbt Cloud resource enum has its own meaning; verify against the API docs OR dbt Labs' own tooling (`dbt-jobs-as-code`, `dbt-cloud-cli`) before assuming. In particular:
- Job `state`: only `1` and `2`, and `2` means deleted
- Deactivation = all triggers false + state=1 (NOT state=2)

**Broader implication:** When the API's enum documentation is thin (as here), the definitive source of truth is dbt Labs' own tooling code, not intuition or general-purpose docs.

---

## D-17 — Cutover-playbook §1a signature initially had the D-11 reserved-name bug

**What happened:** When drafting the `cutover-playbook.md` §1a helper signature (2026-07-12), the `log_run` `@task`'s parameter was named `run_id: int`. Track 2 (helper implementation, PR #2250) caught this during code writing — the same D-11 bug that the smoke DAG (PR #2249) had already been patched for.

**Root cause:** The playbook was drafted while summarizing the smoke DAG's design, but the D-11 fix (`log_after: rename run_id parameter to dbt_run_id`, smoke DAG commit `4f10b808`) had happened AFTER the initial design was captured. The playbook froze the pre-fix signature.

**Fix:** Updated playbook §1a to use `dbt_run_id`, and added an implementation note to D34 in `decisions.md`. Helper module (`fes-airflow/dags/utils/dbt_cloud.py`, PR #2250) uses `dbt_run_id` correctly.

**Lesson:** When a discovery (D-11) is captured mid-project, apply it retroactively to any design docs that were written before the discovery. Playbook signatures aren't code — they're just as prone to freezing pre-fix designs as code branches are. The check to run: does my design doc's code snippet reflect ALL discoveries below its section header?

**Broader implication for Track 2+:** Whenever writing a design doc that includes runnable-looking code, treat it as if it were the code — grep discoveries.md for reserved-name conflicts, provider-quirk fixes, etc. before pasting the snippet.

---

## D-08 — Deploy env's Snowflake grants must include the specific target schema

**What happened:** The dbt Cloud deploy job ran the smoke model but wouldn't have been able to write anywhere unless the target schema was granted explicitly.

**What was needed:** `SVC_DBT_CLOUD_ROLE` needs, at minimum, on the specific schema where models land:

```sql
GRANT USAGE ON DATABASE FES_USERS TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT USAGE ON SCHEMA FES_USERS.ALEX_SOTIS TO ROLE SVC_DBT_CLOUD_ROLE;
GRANT CREATE TABLE ON SCHEMA FES_USERS.ALEX_SOTIS TO ROLE SVC_DBT_CLOUD_ROLE;
```

**Lesson:** `admin_roles` in Terraform (per PR #2830) covers *some* DBs but not `FES_USERS` (per-user sandbox namespace). Personal-schema targets need manual grants. When we get to real cutover, the ownership transfer script (`permissions.md`) covers the target DBs holistically.
