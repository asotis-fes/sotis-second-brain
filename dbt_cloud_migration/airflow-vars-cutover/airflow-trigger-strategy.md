# Revised Plan — Airflow-Trigger Everything (Bridge State)

**Decision date**: 2026-07-23
**Supersedes**: `plan.md` (Wave 2 per-model dbt rewrites)

## Why we pivoted

Five parallel adversarial reviews of PR 24 (Wave 2 dbt-side sweep) surfaced
too many correctness concerns — semantic drift from Airflow-slot timestamps,
downstream DAG filters we hadn't accounted for (SFMC in addition to XP), a
missed `schema.yml` post_hook that would have caused unbounded xtremepush
table growth, redeem_matching cross-family clock drift, and more. Even after
applying the safe fixes we could verify, we're modifying 24 files across
5 patterns in the middle of an active incident, with unknown downstream
impact.

The safer alternative: **keep the dbt code exactly as it was pre-migration,
and have fes-airflow trigger every dbt Cloud job with the right `--vars`.**
Zero semantic drift. Same behavior as pre-cutover. Downstream Airflow
consumers keep working with no changes to their filters. Later, one model
at a time, with proper testing, we can decouple individual models from
`data_interval_*` and move their jobs back to native dbt Cloud scheduling.

## What stays

- **PR #22 (dbt-fes-ae) — merged**. Fanflow bronzes + mention_me referrals.
  Different failure mode from Wave 2 (no downstream coordination trap),
  actively fixing the P1 incident, works via `run_started_at` +
  target-table high-water. Don't revert.
- **All other dbt-fes-ae code as it stands on `main`**. Original var-based
  filters work correctly once Airflow supplies the vars.

## What closes

- **PR #24 (dbt-fes-ae) — Wave 2 sweep**. Close without merging. Body
  should link to this plan and cite the review findings as the reason.

## What builds — fes-airflow PR

### Step 1: extend the `create_dbt_cloud_task_group` utility

**File**: `dags/utils/dbt_cloud.py`

Add auto-injection of `data_interval_*` / `ds_nodash` `--vars` into the
`steps_override` of the `DbtCloudRunJobOperator`, unless the caller
provides its own `steps_override`.

Pseudocode:

```python
def create_dbt_cloud_task_group(
    group_id, job_id, poke_interval=60, timeout_seconds=60*90,
    steps_override=None,
    inject_data_interval_vars=True,  # NEW default
    dbt_selector=None,               # NEW — required if inject_data_interval_vars and no steps_override
):
    if steps_override is None and inject_data_interval_vars:
        assert dbt_selector, "dbt_selector required to auto-inject vars"
        steps_override = [
            f"dbt build --select {dbt_selector} --vars "
            "'{"
              '"data_interval_start": "{{ data_interval_start | ts }}", '
              '"data_interval_end": "{{ data_interval_end | ts }}", '
              '"ds_nodash": "{{ data_interval_start | ds_nodash }}"'
            "}'"
        ]
    ...
```

**Backward-compat**: the 3 DAGs that already pass explicit `steps_override`
(`cassandra_extract`, `sfmc_optin_preferences_import`,
`xtremepush_tier_change_events`) keep working — `inject_data_interval_vars`
only fires when `steps_override is None`. They can eventually migrate to
the default-injection pattern; not required.

### Step 2: update every existing consumer

Existing DAGs that call `create_dbt_cloud_task_group` without
`steps_override` — they'll each need `dbt_selector` added so the utility
knows what tag to build. The known callers (from earlier grep, all in
`fes-airflow/dags/`):

| File | Job called | Selector to add |
|---|---|---|
| `google_ad_manager/google_ad_manager.py` | `DBT_CLOUD_GOOGLE_AD_MANAGER_JOB_ID` | (verify in dbt Cloud UI) |
| `fanapp/fanapp_mdm.py` | `DBT_CLOUD_FANAPP_MDM_JOB_ID` | (verify) |
| `loyalty/loyalty_bonus_postgres_to_s3_ingest.py` | `DBT_CLOUD_FESBONUS_JOB_ID` | `tag:fesbonus` (verify) |
| `magnite/magnite_dag.py` | `DBT_CLOUD_MAGNITE_JOB_ID` | (verify) |
| `loyalty/loyalty_postgres_to_s3_ingest.py` | `DBT_CLOUD_FESLOYALTY_JOB_ID` | `tag:fesloyalty` (verify) |
| `loyalty/dbt_loyalty_6hours.py` | `DBT_CLOUD_LOYALTY_6HOURS_JOB_ID` | (verify) |
| `impact/impact.py` | `DBT_CLOUD_IMPACT_JOB_ID` | (verify) |

To find each job's selector, hit the dbt Cloud API's `execute_steps`:
```bash
source /Users/alex.sotis/repos/fes-airflow/.env
curl -s -H "Authorization: Token $DBT_CLOUD_TOKEN" \
  "https://$DBT_CLOUD_HOST/api/v2/accounts/$DBT_CLOUD_ACCOUNT_ID/jobs/<job_id>/" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['execute_steps'])"
```

### Step 3: add new DAGs for jobs with NO current Airflow trigger

The dbt Cloud jobs that currently run only via internal cron. Each needs a
new fes-airflow DAG that fires on the same cadence and calls
`create_dbt_cloud_task_group` with the auto-injected vars.

Priority order (customer impact first):

| Job (PROD env 974) | Cron | Selector | Priority | Rationale |
|---|---|---|---|---|
| `dbt_fanatics_one` (70437463791518) | `*/30 * * * *` | `tag:fanaticsone` | **P0** | Restores XP + SFMC tier-change delivery |
| `dbt_loyalty` (70437463791501) | (currently completion-triggered) | `tag:loyalty` | **P0** | Fancash ledger + redeem_matching stop stamping 2023-01-02 |
| `dbt_loyalty_metrics` (70437463791503) | `0 14 * * *` | `tag:loyalty_metrics` | P1 | Un-freezes 13 metric snapshots at 2026-07-21 14:00 |
| `dbt_daily` (70437463791507) | (verify cron) | `tag:daily` | P1 | Includes mention_me — but that's already fixed via PR 22 |
| `dbt_daily_9am` (70437463791508) | (verify cron) | `tag:daily_9am` | P1 | |
| `dbt_hourly` (70437463791506) | (verify cron) | `tag:hourly` | P1 | |
| `dbt_every_3hours` (70437463791509) | (verify cron) | `tag:every_3hours` | P2 | |
| `dbt_every_6hours` (70437463791510) | (verify cron) | `tag:every_6hours` | P2 | |
| `dbt_weekly` (70437463791511) | (verify cron) | `tag:weekly` | P2 | |
| `dbt_loyalty_monthly_snapshot` (70437463791504) | (verify cron) | `tag:loyalty_monthly_snapshot` | P2 | |
| `dbt_meta_ads` (70437463791512) | (verify cron) | `tag:meta_ads` | P2 | |
| `dbt_ltv` (70437463791513) | (verify cron) | `tag:ltv` | P2 | |
| `dbt_mde` (70437463791514) | (verify cron) | `tag:mde` | P2 | |
| `dbt_fanapp_recs` (70437463791515) | (verify cron) | `tag:fanapp_recs` | P2 | |
| `dbt_enterprise_metrics` (70437463791516) | (verify cron) | `tag:enterprise_metrics` | P2 | |
| `dbt_enterprise_metrics_daily` (70437463791517) | (verify cron) | `tag:enterprise_metrics_daily` | P2 | |
| `dbt_users` (70437463791520) | (verify cron) | `tag:users` | P2 | |
| `dbt_sources` (70437463791521) | (verify cron) | `tag:sources` | P2 | |
| `dbt_fangraph` (70437463791522) | (verify cron) | `tag:fangraph` | P2 | |
| `dbt_xtremepush` (70437463791519) | (verify cron) | `tag:xtremepush` | P2 | Contains the Pattern C models |
| `dbt_fanflow` (70437463791505) | `*/30 * * * *` | `tag:fanflow` | **OPTIONAL** | Doesn't need vars (PR 22 removed the dependency). Can stay on dbt Cloud cron OR move to Airflow for consistency. |

## Coordinated cutover checklist

Once fes-airflow PR is merged + deployed:

- [ ] Remove the `dbt_fanflow → dbt_loyalty` completion trigger in dbt Cloud
  (job `70437463791501`, unset `job_completion_trigger_condition`)
- [ ] Pause dbt Cloud schedules on every job in the P0/P1/P2 list above (in
  PROD env `70437463672974`). Airflow drives them now.
- [ ] Consider pausing `dbt_fanflow` schedule too (or leave; see optional
  entry above)
- [ ] Do NOT delete the dbt Cloud jobs — they still get invoked via the
  API from Airflow; just their internal schedule is off

## Post-cutover monitoring

- [ ] Verify `dbt_fanatics_one` is firing every 30 min from Airflow with
  `--vars` in `steps_override`. Check a recent run's `execute_steps`.
- [ ] Verify tier changes appear in `LOYALTY.LOYALTY_INFO.TIER_CHANGES_ALL`
  with real `update_ts` values (NOT `'2023-01-02'`) going forward
- [ ] Verify XtremePush tier-change events start flowing (check XP dashboard
  or the DAG's PythonOperator log for `sent N events successfully`)
- [ ] Verify SFMC tier-change email export starts producing rows
- [ ] Verify `dbt_loyalty` fancash models (`loyalty_redeem`,
  redeem_matching quad) advance `_insert_ts` past the pause
- [ ] Verify `dbt_loyalty_metrics` produces a new snapshot at 14:00 UTC
  next day
- [ ] Spot-check other jobs — sample compiled SQL from a dbt Cloud run to
  confirm real `data_interval_*` values appear in place of the placeholders

## Cleanup work (defer — not blocking)

- **79,210 + 359 rows stamped `'2023-01-02'`** in
  `TIER_POINTS_MARKETING_TRIGGERS` + `TIER_CHANGES_ALL`. Do NOT
  `--full-refresh` — that would mass-replay every tier change ever
  recorded once the DAGs are firing. Use a targeted `UPDATE ... SET
  update_ts = transaction_timestamp WHERE update_ts::DATE = '2023-01-02'`
  OR just leave them and accept the data loss for that window (XP/SFMC
  DAG filters never matched them regardless).
- **Pattern C xtremepush push_last_opened + optin_preferences 6-week
  freeze**. Orchestration issue, likely the `sfmc_optin_preferences_import`
  DAG's `end_date=2026-06-09` (Salesforce sunset per reviewer). Separate
  investigation.
- **Pattern D `ledger.yaml` post_hook + date_filter** — 4 `var()` hits
  that pass through `loyalty_insert_row_count`. Once Airflow is passing
  real vars, these work correctly (they pass to a macro that already
  handles the value). No code change needed after Airflow-trigger.

## Per-model dbt-side decoupling — the long-term end state

After Airflow-trigger is stable and everything is caught up, we can
decouple models from `data_interval_*` one at a time. For each model:

1. Build test coverage (row-count sanity, watermark advance, downstream
   contract).
2. Rewrite the model to use `run_started_at` / `CURRENT_TIMESTAMP` /
   target-table high-water — matching PR 22's fanflow pattern for its
   category.
3. PR + review + merge.
4. Job can move back to native dbt Cloud schedule (if desired) OR stay
   Airflow-triggered (Airflow-triggering an already-decoupled model is
   harmless).

Fanflow (PR 22) is the reference. Everything else follows one at a time.
No urgency; the incident is fixed by Airflow-triggering.
