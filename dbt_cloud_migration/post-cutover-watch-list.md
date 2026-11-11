# Post-Cutover Watch List

Things to actively monitor for in the first days/weeks after the dbt Cloud cutover. Distinct from [`remaining-steps.md`](remaining-steps.md) → *Post-cutover* (which tracks planned followup **actions**), and from [`post-cutover-architecture.md`](post-cutover-architecture.md) (which documents target-state architecture).

Each item lists: **the concern**, **how it would show up**, **how to check**, and **fix pattern**.

---

## 1. Incorrect ownership transfers to `SVC_DBT_CLOUD_ROLE`

**Concern.** `sql/cutover_ownership_transfer.sql` filters purely by `owner = 'SVC_MWAA_ROLE'` in each target DB. It does NOT cross-reference the dbt-fes-ae model list or the fes-airflow repo. Any table MWAA created for a non-dbt purpose (e.g., a `SnowflakeOperator` ingest DAG landing table that happens to live in one of the target DBs) would be transferred to `SVC_DBT_CLOUD_ROLE` even though MWAA still needs to write to it.

**How it would show up.**
- A previously-working MWAA ingest DAG task fails with a permission error on `INSERT` / `MERGE` / `TRUNCATE` / `CREATE OR REPLACE`.
- Error text will mention `SVC_MWAA_ROLE` lacking a privilege on a specific FQN.
- Most likely candidates: tables in `FES_INTEGRATIONS`, `FDE`, `FANAPP` — DBs where both dbt and Airflow-native operators write.

**How to check.**
1. When an ingest DAG fails after cutover, capture the FQN from the error.
2. `SHOW GRANTS ON TABLE <fqn>;` — confirm `SVC_DBT_CLOUD_ROLE` is now the OWNER.
3. Cross-reference: is this FQN produced by any dbt model in `dbt-fes-ae`? `rg -w 'table_name' ~/repos/dbt-fes-ae/dbt/models/` — if no hit, the table was ingest-only and shouldn't have transferred.
4. Look up the transfer entry: `SELECT * FROM FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG WHERE object_name = '<name>' AND status = 'SUCCESS';`

**Fix pattern.**
- Option A (single table, fast): re-grant back to MWAA. `USE ROLE ACCOUNTADMIN; GRANT OWNERSHIP ON TABLE <fqn> TO ROLE SVC_MWAA_ROLE COPY CURRENT GRANTS;`
- Option B (grant, not ownership): if the task only needs DML, grant `INSERT, UPDATE, DELETE, TRUNCATE` to `SVC_MWAA_ROLE` and leave dbt Cloud as owner. This is cleaner if the table is dbt-materialized but Airflow also writes to it (uncommon).
- Log the fix in `FES_USERS.DBT_CLOUD_MIGRATION.OWNERSHIP_TRANSFER_LOG` manually with `status = 'REVERSED_POST_CUTOVER'` for traceability.

**Nice-to-have prevention (see `remaining-steps.md` Nice-to-haves).** Refine `cutover_ownership_transfer.sql` to filter by MWAA-owner AND presence in the dbt-fes-ae model set (e.g., pre-populate a `_dbt_model_fqns` temp table from a `dbt ls` export). Skipped for cutover speed; fall-forward with the fix pattern above.

---

## 2. Cross-project dbt Mesh ref resolution failures

**Applies only if D42 (analytics project split) completes pre-cutover.** See [`analytics-project-split.md`](analytics-project-split.md) for the setup this depends on.

**Concern.** The analytics project's models use `{{ ref('fes_data', 'model_name') }}` to reach upstream AE models. Cross-project resolution reads the AE prod environment's `manifest.json`, which is only rebuilt after a successful prod job run. Any of the following breaks resolution:
- An AE model that analytics refs has its `access:` field reverted from `public` to `protected`/`private`.
- The AE model gets renamed or deleted without a coordinated update in analytics.
- The AE prod environment's most recent job run failed → manifest.json is stale.
- Someone modifies `dbt-fes-ae/dbt_project.yml` `name:` field away from `fes_data` (should never happen per D32, but check).

**How it would show up.**
- Analytics prod job (`dbt_users`, cron `30 13 * * *`) fails at compile time with `Unable to find model 'X' in project 'fes_data'`.
- Or: succeeds but resolves to stale/wrong table if the upstream was renamed and both names briefly coexist.

**How to check.**
1. Analytics job compile failure → read the failed model's `ref('fes_data', 'X')` calls, cross-reference each `X` against AE's `manifest.json` (dbt Cloud UI → analytics project → Documentation → search for X in the AE project scope).
2. `SHOW GRANTS ON TABLE FES_DATA_DB.SCHEMA.X` (or whatever the AE-project target is) — confirm the model exists at the FQN dbt expects.
3. Check AE's most recent prod job status — if failed, its manifest may not reflect current `access:` values.

**Fix pattern.**
- **Missing `access: public`**: open a small AE PR adding `access: public` (with `group:` + `owner:`) to the offending model's schema YAML. Merge, then trigger any AE prod job (cheap: `dbt_sources` `70437463791521`) to refresh the manifest. Re-run analytics job.
- **Renamed/deleted upstream**: coordinate — either restore the AE model name (fast fix), or update the analytics-side `ref()` to the new name in a follow-up PR to dbt-fes-analytics.
- **Stale manifest from failed AE run**: fix whatever broke AE, get one green prod run, then re-trigger analytics.

**Prevention.** Add a lightweight CI check in `dbt-fes-analytics` that runs `dbt parse` against a downloaded copy of AE prod's manifest — surfaces missing `access:` or renamed models at PR review time instead of at 13:30 UTC when the cron fires. Deferred until post-cutover if timeline is tight.

---

## 3. Retained-but-soft-deleted AE `dbt_users` job (`70437463791520`)

**Applies only if D42 completes pre-cutover.** Analytics project takes over `dbt_users`; the AE-side job is soft-deleted (`state=2`) per `analytics-project-split.md` §16 rather than hard-deleted, for one-week audit retention.

**Concern.** A stray API call, UI action, or Terraform apply could flip `state` back to `1` (active), causing two jobs (AE + analytics) to build `tag:users` — but AE would fail because the models are gone from the AE repo.

**How it would show up.**
- Job `70437463791520` shows up as active in dbt Cloud UI job list.
- Next scheduled fire (`30 13 * * *`) errors immediately: `No models matched selector tag:users` from AE repo.
- OR: the failure notification duplicates the analytics-project notification (both fire at 13:30 UTC).

**How to check.**
- Once daily during watch window: `curl .../api/v3/accounts/70437463654557/jobs/70437463791520/ | jq .data.state` — must equal `2` (soft-deleted).
- If value is `1`: someone reactivated it.

**Fix pattern.**
- Immediately PATCH `state=2` back to soft-deleted.
- Check dbt Cloud audit log for who/what reactivated it.
- If timeline permits (1 week post-cutover), hard-delete the job entirely to eliminate the risk.

**Retention timeline.** Hard-delete AE job `70437463791520` two weeks post-cutover, once analytics-project `dbt_users` has run cleanly for 14 consecutive daily fires. Log the deletion in the OWNERSHIP_TRANSFER_LOG or a dedicated audit table.

---
