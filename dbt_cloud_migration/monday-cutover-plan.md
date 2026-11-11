# Monday Cutover Plan

Canonical checklist for the dbt Cloud cutover. Target: **Monday 2026-07-13 morning** send out PRs and wrap up final testing; go live once team approves.

## Current state (2026-07-13)

**Done:**
- `dbt-cloud-migration` branch on fes-airflow — 20 pure-dbt DAGs deleted, `dbt_loyalty_6hours` kept (has ingest coupling), coupling test infrastructure (utils/dbt_cloud.py + 3 dev-only DAGs)
- 6 export/integration DAGs' dead sensors removed (with TODO comments)
- 21 dbt Cloud jobs in Development env (state=1, all triggers false — safe idle)
- SVC_DBT_CLOUD keypair credential attached to Development env via D-19
- H1 coupling test **PASSED** on dev — trigger/sensor mechanism proven
- Draft PR #2252 open (dbt-cloud-migration → main), Test python + Deploy green on latest commit
- `requirements/requirements.txt` includes `apache-airflow-providers-dbt-cloud==3.8.1`

**Core rule:** after cutover, **NO dbt commands run under MWAA**. Airflow's role vis-a-vis dbt is limited to (a) triggering dbt Cloud jobs, and (b) being triggered by dbt Cloud job completions. Any DAG that shells out to `dbt` (`create_dbt_dag`, `create_dbt_task`) is deleted from the branch at cutover.

**Every dbt model outside `ARCHIVE/` and `analysis/` has a dbt Cloud job.** Jobs are provisioned with cron populated + `triggers.schedule=false` (paused). At main cutover, `dbt_cloud_activate_schedules.sh` flips `triggers.schedule=true` on the validated subset. Fangraph stays paused past main cutover (see below).

**Job count**: **22 jobs** — the 21 originally identified plus `dbt_fangraph` (added on user correction). The old `dbt_full_refresh` DAG is not converted — its workflow moves to dbt Cloud's UI "Run job with full refresh" toggle.

**Delayed activation (job exists in dbt Cloud, but schedule stays paused at main cutover):**
- `dbt_fangraph` — 236 fangraph-related models. Job provisioned + cron populated (`0 10 * * *` UTC, was `0 6 * * *` ET); `triggers.schedule` flipped to `true` in a follow-up once fangraph is validated on Fusion (source() defer issues per `fusion-migration/loyalty-diff-runbook.md`). Fangraph tables ARE included in the cutover ownership transfer.
- `dbt_xtremepush` — depends on `pfi_fangraph`. Activated at main cutover; reads stale `pfi_fangraph` until fangraph is validated and its schedule flipped on.

**Deferred entirely (not converted to dbt Cloud):**
- Mesh, TF-ified jobs, tiered alerting, cost monitoring, Discovery API dashboards — all deferred post-cutover per D40

## What is left — in dependency order

### Parallel-safe (kick off simultaneously as subagents)

1. **Monday TF PR (fanapp-terraform)** — Extend fanapp-terraform#2830's pattern to all target databases. Grants `SVC_DBT_CLOUD_ROLE`: `USAGE` on target DBs, `USAGE` on schemas, `SELECT` on source tables, `CREATE TABLE` on target schemas, `USAGE` on `FDE_DBT_CLOUD_WH`. Target DBs: `LOYALTY`, `LOYALTY_DEV`, `FANFLOW`, `FDE`, `FDE_DEV`, `FES_ADS` (done), `FES_INTEGRATIONS`, `FANAPP`, `FANAPP_DEV`, `IDENTITY`, `COMMERCE`, `COMMERCE_DEV`, `AMPLITUDE`, `FANATICS_LIVE`, plus others in `dbt-fes-ae/dbt_project.yml` model configs. Spec: `projects/dbt_cloud_migration/fusion-migration/monday-terraform-pr-spec.md`.

2. **Snowflake ownership-transfer SQL** — Generate the full model list. Regenerate via reading `dbt-fes-ae/dbt/models/**/*.yaml|*.sql` schema configs (or `dbt ls --resource-type model --output json` if dbt Cloud is set up locally). Output to **brock-bot** at `projects/dbt_cloud_migration/sql/cutover_ownership_transfer.sql` and `cutover_rollback.sql`. Exclude fangraph models. Include both prod (`LOYALTY.LOYALTY_CORE.*`) and dev (`LOYALTY_DEV.LOYALTY_CORE.*`) equivalents — separate sections. Delete the stubs at `fes-airflow/sql/cutover_*.sql` (they're superseded).

3. **Prod env + prod jobs in dbt Cloud** — Requires the user first creating a prod-scoped Snowflake credential in dbt Cloud UI (target_name="prod", role=SVC_DBT_CLOUD_ROLE, warehouse=FDE_DBT_CLOUD_WH, database=<TBD>, schema=<TBD>) because credential creation requires the raw private key material which shouldn't move through automation. Once credential exists, subagent creates: (a) prod env pointing at the credential, dbt_version=fusion-stable; (b) 21 jobs in prod env via existing provisioning script targeting the new env ID; (c) records the new job IDs. Chain configurations (`job_completion_trigger_condition`) also applied where dbt→dbt chains exist — see chain map below.

4. **fes-airflow PR code review** — Review the entire `dbt-cloud-migration` branch diff vs main for: quality, bugs, security, AI slop (overly defensive code, chatty non-human comments, marketing prose in docstrings, unused imports, dead code). Report findings.

### Sequential (do after subagents 1-4 finish)

5. **Update DAG file constants for env-scoped job IDs** — Each `DBT_CLOUD_*_JOB_ID` becomes `config.get_value_for_env(dev=<dev_id>, prod=<prod_id>)`. Only 3 constants remain in the code (since 20 DAGs were deleted): `DBT_CLOUD_LOYALTY_6HOURS_JOB_ID` (`dbt_loyalty_6hours.py`), `DBT_CLOUD_SMOKE_JOB_ID` (used by 2 coupling test DAGs, dev-only so `prod` value doesn't matter). Wait actually only 1: `DBT_CLOUD_LOYALTY_6HOURS_JOB_ID`. Other job IDs live only in dbt Cloud UI now.

6. **Pre-populate schedules on prod jobs** — `schedule.cron` per DAG (see table below), `triggers.schedule=false`. At cutover moment, one script call flips all to true. Script drafted: `fes-airflow/scripts/dbt_cloud_populate_schedules.sh`.

7. **Draft dbt Cloud `activate schedules` script** — `scripts/dbt_cloud_activate_schedules.sh` that PATCHes `triggers.schedule=true` on all 21 prod jobs.

8. **Wire dbt Cloud failure notifications (missing from YOLO — from big-bang §17/§22).** Zero alerts on dbt Cloud jobs today. If `dbt_fanflow` fails at 3am post-cutover, no one knows until data staleness gets noticed. Minimum viable fix: `POST /api/v3/accounts/{id}/notifications/` for one Slack webhook subscribed to failure state on all 22 prod jobs. FireHydrant tiered P1/P2/P3 mapping stays deferred (matches YOLO's alerting deferral).

9. **Smoke the dbt Cloud → dbt Cloud chain (missing from YOLO — from big-bang §15).** Coupling test validated Airflow ↔ dbt Cloud in both directions, but the `job_completion_trigger_condition` mechanism itself has not been exercised end-to-end. Post-TF-merge, manually trigger prod `dbt_fanflow` (`70437463791505`) via dbt Cloud UI "Run now"; observe prod `dbt_loyalty` (`70437463791501`) auto-fire within ~30s of fanflow success. Same 2 min as the credential smoke; run them back-to-back.

### At cutover moment (Monday morning)

8. **You**: populate prod SSM `/airflow/connections/dbt_cloud_ae` via Datadog Self Service with the new prod-scoped token URI.
9. **You**: apply role hierarchy grant: `GRANT ROLE SVC_DBT_CLOUD_ROLE TO ROLE SVC_MWAA_ROLE;` (safety net per D21).
10. **You**: execute `sql/cutover_ownership_transfer.sql` via `snow sql` (transfers ownership of all migrated tables from SVC_MWAA_ROLE to SVC_DBT_CLOUD_ROLE with `COPY CURRENT GRANTS`).
11. **You**: mark draft PR #2252 as Ready for Review, get team approval.
12. **You**: merge PR to main → deploy_prod.yml syncs new DAGs to prod MWAA.
13. **You** (or subagent): run `scripts/dbt_cloud_activate_schedules.sh` → all 21 prod jobs start firing on their crons.
14. **You**: watch first hourly run of `dbt_loyalty_6hours` (7am/1pm/5pm/11pm UTC) + first `dbt_fanflow` (hourly) → confirm dbt Cloud runs go green.

### Rollback (if needed within 24h of cutover)

- `git revert` the cutover PR merge commit on main → push → MWAA syncs old DAGs back
- `snow sql -f sql/cutover_rollback.sql` reverses ownership transfer
- `scripts/dbt_cloud_activate_schedules.sh --deactivate` sets all triggers.schedule=false

## Schedule table (prod cron per job)

Extracted from the deleted dbt_*.py DAGs. Timezone: fes-airflow used mostly `America/New_York` (EDT/EST); dbt Cloud stores UTC. Converted below.

| DAG name (old) | Prod cron (original) | UTC equivalent | Notes |
|---|---|---|---|
| `dbt_loyalty` | `0 * * * *` (UTC) | `0 * * * *` | Hourly. Chain-triggered by `dbt_fanflow` completion via `job_completion_trigger_condition` (no independent schedule needed — but set anyway as fallback). |
| `dbt_loyalty_6hours` | `0 5,11,17,23 * * *` (UTC) | `0 5,11,17,23 * * *` | Still triggered from **Airflow** (kept as DAG for ingest coupling). NO cron on dbt Cloud side. |
| `dbt_loyalty_metrics` | `0 14 * * *` (UTC) | `0 14 * * *` | |
| `dbt_loyalty_balance_monthly_snapshot` | `0 11 2 * *` (UTC — was original) | `0 9 2 * *` | **Shifted 2h earlier** to avoid race with `loyalty_kyros_data_transfer` (Airflow, `0 11 2 * *`) which exports the snapshot table. |
| `dbt_fanflow` | `0 * * * *` (UTC) | `0 * * * *` | Hourly. Chain root — triggers `dbt_loyalty` on completion. |
| `dbt_hourly` | `0 * * * *` (UTC) | `0 * * * *` | |
| `dbt_daily` | `0 8 * * *` (EDT/EST) | `0 12 * * *` (EDT) / `0 13 * * *` (EST) | Set UTC `0 12 * * *` (EDT majority); confirm if timezone-adjust is preferred. |
| `dbt_daily_9am` | `15 9 * * *` (EDT/EST) | `15 13 * * *` (EDT) / `15 14 * * *` (EST) | Set UTC `15 13 * * *`. |
| `dbt_every_3hours` | `0 */3 * * *` (EDT/EST) | `0 */3 * * *` | Every 3h — timezone-independent for regular intervals. |
| `dbt_every_6hours` | `30 0,1,6,12,18 * * *` (EDT/EST) | `30 0,1,6,12,18 * * *` | Fixed hours — leaving as-is but note this is TZ-ambiguous. |
| `dbt_weekly` | `0 6 * * 1` (EDT/EST — Mon 6am) | `0 10 * * 1` (EDT) / `0 11 * * 1` (EST) | Set UTC `0 10 * * 1`. Includes `dbt run-operation refresh_eval_ground_truth` as 2nd step. |
| `dbt_meta_ads` | `0 4 * * *` (EDT/EST) | `0 8 * * *` (EDT) / `0 9 * * *` (EST) | Set UTC `0 8 * * *`. |
| `dbt_ltv` | `0 8 * * *` (EDT/EST) | `0 12 * * *` (EDT) | Set UTC `0 12 * * *`. |
| `dbt_mde` | `45 11 * * *` (UTC — see file) | `45 11 * * *` | Already UTC. |
| `dbt_fanapp_recs` | `0 8 * * *` (EDT/EST) | `0 12 * * *` (EDT) | Set UTC `0 12 * * *`. |
| `dbt_enterprise_metrics` | `None` (no schedule) | none | Manual/ad-hoc only. |
| `dbt_enterprise_metrics_daily` | `0 8 * * *` (EDT/EST) | `0 12 * * *` (EDT) | Set UTC `0 12 * * *`. |
| `dbt_fanatics_one` | `*/30 * * * *` (EDT/EST) | `*/30 * * * *` | Every 30m — TZ-independent. |
| `dbt_xtremepush` | `0 8 * * *` (EDT/EST) | `0 12 * * *` (EDT) | Set UTC `0 12 * * *`. Depends on `pfi_fangraph` which is DEFERRED — xtremepush will read STALE fangraph data until fangraph migrates. Runs unconditionally on schedule (no cross-DB gating). |
| `dbt_users` | `30 9 * * *` (EDT/EST) | `30 13 * * *` (EDT) | Set UTC `30 13 * * *`. |
| `dbt_sources` | `0 9 * * 1-5` (EDT/EST) | `0 13 * * 1-5` (EDT) | Set UTC `0 13 * * 1-5`. Steps: `dbt source freshness`. |
| `dbt_fangraph` | `0 6 * * *` (EDT/EST) | `0 10 * * *` (EDT) | Job provisioned with cron populated, but **`triggers.schedule` stays `false` at main cutover**. Activated separately once fangraph is validated on Fusion. Selector: `dbt build --selector fangraph`. |

**DST caveat:** the crons above hardcode EDT (UTC-4). During EST (UTC-5, roughly Nov-Mar), these will fire 1h earlier in local time. If that's undesirable, use dbt Cloud's timezone-aware scheduling (set `schedule.time.timezone = "America/New_York"`) instead of raw UTC crons. Discuss before Monday.

## dbt Cloud chain map

Chains to configure via `job_completion_trigger_condition` on the *downstream* job:

| Downstream job | Chained from | Reason |
|---|---|---|
| `dbt_loyalty` | `dbt_fanflow` | loyalty models depend on `loyalty_transaction_successful__account` from fanflow — was the ExternalTaskSensor we removed |

Only 1 chain to configure at cutover (fanflow → loyalty). Rest of the 21 jobs run on their own schedules (or manual trigger). Fangraph chain (`dbt_xtremepush` ← `dbt_fangraph`) is deferred with fangraph itself; xtremepush will read stale fangraph tables until the fangraph migration PR lands.

## Contacts for cutover morning

Verify before cutover:
- Team review approval on draft PR #2252
- fanapp-terraform TF PR merged (grants live)
- Prod SVC_DBT_CLOUD credential exists in dbt Cloud
- Prod env exists in dbt Cloud with 21 jobs, cron populated, triggers.schedule=false
- `airflow-mwaa-prod` service token generated (dbt Cloud UI)
- Prod SSM URI populated in Datadog Self Service

## Open items — nice-to-have before cutover

### dbt-fes-ae repo guardrails parity with fes-airflow

**Ask:** bring `dbt-fes-ae` in line with `fes-airflow`'s repo-level guardrails so the same review/merge protections apply to dbt models as they do to Airflow DAGs. Not blocking cutover — but valuable because once dbt Cloud is the sole runtime, the dbt-fes-ae repo becomes the highest-blast-radius surface for data changes.

**What fes-airflow has that dbt-fes-ae doesn't (verify + close each gap):**
- Repo settings (branch protection, required reviewers, required checks, auto-merge policy) managed via `~/repos/fanapp-github-terraform` — the `deploy-repos.yaml` / `modules/deploy-repo` shape used for fes-airflow should be applied to dbt-fes-ae the same way.
- Okta team → GitHub team mappings for reviewer routing. See the `teams.tf` pattern in fanapp-github-terraform and the `fes-data` GitHub team's membership → confirm dbt-fes-ae uses the same team as CODEOWNER for the paths that matter (`models/**`, `dbt_project.yml`, `packages.yml`, `selectors.yml`, `macros/**`).
- CI: SQLFluff + `dbt parse` on PR, matching `fes-airflow` `Lint SQL` / `Test / test_python` gates. dbt-fes-ae likely has partial coverage — inventory what exists in `.github/workflows/` vs what fes-airflow enforces.

**Action for a future session:**
1. Compare `~/repos/dbt-fes-ae/.github/` vs `~/repos/fes-airflow/.github/` — enumerate workflow deltas.
2. Compare `dbt-fes-ae` CODEOWNERS vs fes-airflow CODEOWNERS.
3. Check fanapp-github-terraform: does dbt-fes-ae have a `deploy-repos.yaml` entry with the same settings as fes-airflow?
4. Draft a PR into fanapp-github-terraform bringing the two in line + any missing `.github/workflows/` files into dbt-fes-ae. Small, self-contained.

Skip this entirely if Monday cutover timing is tight — it's independently useful and can land any time.

Rollback contract: `git revert` + optional SQL. See §Rollback above.
