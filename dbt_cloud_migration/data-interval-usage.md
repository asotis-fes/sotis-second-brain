# Airflow Context Vars Referenced in dbt Models

Per **D39**, any dbt DAG whose selector matches a model that references `data_interval_start`, `data_interval_end`, or `ds_nodash` via `{{ var(...) }}` MUST pass `steps_override` when calling `dbt_cloud.create_dbt_cloud_task_group`. Otherwise the dbt Cloud job runs without those vars and models fail (or worse: silently pull stale defaults).

Enumeration date: **2026-07-12**. Regenerate with:

```bash
grep -rl "var(['\"]\(data_interval_start\|data_interval_end\|ds_nodash\)" \
  dags/dbt/models/
```

## Models found (31)

Tag column populated from adjacent `*.yaml` / `schema.yml` config blocks. Rows where tag is `?` require the engineer to confirm via `dbt ls --resource-type model --output name <model>` and then check which DAG's tag selector matches.

| Model | Tag | DAG (inferred) |
|---|---|---|
| `cde/loyalty/metrics/cde_loyalty_analytics_ledger_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `cde/loyalty/metrics/cde_loyalty_balance_metrics.sql` | `daily` | `dbt_daily` |
| `cde/loyalty/metrics/cde_loyalty_earn_burn_mapper_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `cde/loyalty/metrics/cde_loyalty_state_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `cde/loyalty/metrics/cde_tier_points_ledger_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `cde/loyalty/metrics/cde_tier_points_overrides_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `cde/loyalty/metrics/fancash_balance_collectibles_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `commerce/stage/fan_id_register_dtl.sql` | `daily` | `dbt_daily` |
| `fde_fbg/metrics/fbg_loyalty_analytics_ledger_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `fde_fbg/metrics/fbg_loyalty_balance_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `fde_fbg/metrics/fbg_loyalty_earn_burn_mapper_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `fde_fbg/metrics/fbg_loyalty_state_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `fes_integrations/mentionme/referrals.sql` | `daily` | `dbt_daily` |
| `growthloop/gl_new_to_x_registration_events.sql` | ? | ? |
| `identity/orchestration/loyalty_private_fan_id_map.sql` | `identity` | ? (no `dbt_identity` DAG — likely `dbt_daily` or embedded in another tag) |
| `identity/orchestration/martech_private_fan_id_map.sql` | `identity` | ? |
| `loyalty/fanatics_one/metrics/tier_points_ledger_fbg_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `loyalty/fanatics_one/metrics/tier_points_overrides_fbg_metrics.sql` | `loyalty_metrics` | `dbt_loyalty_metrics` |
| `loyalty/fanatics_one/tier_changes_all.sql` | `fanaticsone` | `dbt_fanatics_one` |
| `loyalty/fanatics_one/tier_points_marketing_triggers.sql` | `fanaticsone` | `dbt_fanatics_one` |
| `loyalty/fancash/ledger_upstream/loyalty_redeem.sql` | `loyalty` | `dbt_loyalty` |
| `loyalty/fancash/redeem_matching/new_ledger_txn.sql` | `loyalty` | `dbt_loyalty` |
| `loyalty/fancash/redeem_matching/redeem_matches.sql` | `loyalty` | `dbt_loyalty` |
| `loyalty/fancash/redeem_matching/unconnected_earn.sql` | `loyalty` | `dbt_loyalty` |
| `xtremepush/xp_optin_preferences_delta.sql` | `optin_preferences` | ? (possibly bundled under `dbt_xtremepush`) |
| `xtremepush/xp_optin_preferences_snapshot.sql` | `optin_preferences` | ? |
| `xtremepush/xp_push_last_opened_delta.sql` | ? | ? |
| `xtremepush/xp_push_last_opened_snapshot.sql` | ? | ? |
| `xtremepush/xp_user_attributes_delta.sql` | ? | ? |
| `xtremepush/xp_user_attributes_snapshot.sql` | ? | ? |
| `loyalty/fancash/ledger/ledger.yaml` (multiple models within) | `loyalty` (some `loyalty_analytics_ledger_stage_final` refs `data_interval_end` in post_hook + tests) | `dbt_loyalty` |

## DAGs confirmed to need `steps_override`

Based on the mapping above:

- **`dbt_loyalty`** — `loyalty` tag matches 4+ models referencing `data_interval_end` (loyalty_analytics_ledger_stage_final post_hook, redeem_matching models, loyalty_redeem)
- **`dbt_loyalty_metrics`** — `loyalty_metrics` tag matches 11 models (all CDE + FBG + FanaticsOne metrics models)
- **`dbt_daily`** — `daily` tag matches `cde_loyalty_balance_metrics`, `commerce/stage/fan_id_register_dtl`, `fes_integrations/mentionme/referrals`
- **`dbt_fanatics_one`** — `fanaticsone` tag matches 2 tier-change models

## DAGs likely needing confirmation

- **`dbt_xtremepush`** — xtremepush models have their own `optin_preferences` tag; DAG might use `xtremepush` tag which doesn't match these. Verify with `dbt ls --select tag:xtremepush` and check what actually runs during `dbt_xtremepush` DAG.
- **Growthloop model** — `gl_new_to_x_registration_events` has no visible tag; check `dbt_project.yml` folder defaults or find owning DAG.
- **Identity models** — tag `identity` doesn't map to any `dbt_*` DAG in the inventory; either bundled into another tag or run out of a different DAG.

## `steps_override` pattern

Per `cutover-playbook.md` §4:

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

Airflow renders the Jinja at trigger time; dbt Cloud receives the concrete values.
