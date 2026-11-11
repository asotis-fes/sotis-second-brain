# Plan

Three PRs, one per affected repo. No cross-PR merge order dependency. Each PR is
scoped to be tackled in one working session.

## Pre-flight (before opening PR 1)

- [ ] **dbt Cloud job-var audit** — grep every job config in dbt Cloud (or the
  `dbt-cloud-migration` job spec repo, wherever the source of truth lives) for
  `data_interval_start` / `data_interval_end` / `ds_nodash` as Job Var or env var. Rename
  survivors to `window_start_ts` / `window_end_ts` (fanflow) — or remove entirely (the
  macro self-heals). **Owner**: this is a required precondition for the hard cutover.
- [ ] **External orchestration audit** — grep the org for any `dbt build --vars` or
  `dbt run --vars` calls in shell scripts / Airflow / cronjobs that still pass the legacy
  names.
- [ ] **Align with the manual-mitigation session** — confirm the state of `_file_modified_ts`
  in each raw bronze target, so we know whether a `--full-refresh` or a targeted-window
  first run is needed after PR 1 lands.

## PR 1 — dbt-fes-ae (the only PR; incident-ending) — **DRAFTED**

- **PR**: https://github.com/fanatics-gaming/dbt-fes-ae/pull/22 (draft)
- **Branch**: `fix/airflow-vars-cutover`

- [x] Rewrite `macros/fanflow/fanflow_unparsed_files.sql` per `fix-design.md` §Fix 1.
- [x] Rewrite `macros/fanflow/fanflow_test_unparsed_files.sql` per `fix-design.md` §Fix 2.
- [x] Simplify `macros/fanflow/fanflow_ingest_topic.sql` signature to `(topic_name)`.
- [x] Rewrite `models/fes_integrations/mentionme/referrals.sql` per `fix-design.md` §Fix 3.
- [x] Edit `dbt_project.yml`: remove placeholder vars, add `fanflow_bootstrap_ts`.
- [x] Local verify: `dbt parse` clean; `dbt compile -s fes_enriched referrals` clean.
- [x] Open PR as draft.
- [ ] Complete pre-flight audits above → mark PR ready-for-review.

## PRs de-scoped

- **dbt-governance / `bets_total_stake_validity_check`** — NOT part of this fix.
  The model is `materialized: view`; its `dbt_project.yml` default is the literal
  string `CURRENT_TIMESTAMP`, which Snowflake evaluates at query time. Under dbt
  Cloud it already returns "yesterday relative to now" correctly. Not our repo /
  not our incident. If we ever want to normalize that model to `CURRENT_DATE - 1`,
  hand off to the dbt-governance team as a separate cleanup.
- **dbt-fes-analytics dead-code cleanup** — the duplicate fanflow macros in that
  repo are unused (no models call them). Not part of the fix. Optional low-risk
  hygiene PR if it comes up; not required.
- **CI grep guard** — regression prevention, not incident fixing. Excluded from
  this PR. Would be its own PR if we decide to add it.

## Post-merge (per affected table)

Track in `affected-tables.md`. For each of the 7 directly-affected tables:
- [ ] First post-merge run — confirm dbt Cloud kicks off successfully with no
  var-not-set errors.
- [ ] Verify `MAX(_file_modified_ts)` / `MAX(source_file_name)` in target has advanced.
- [ ] Row-count sanity check vs pre-freeze baseline.
- [ ] If a gap persists after the first self-healed run, decide on backfill approach
  (widen first-run window with `--vars`, or run `--full-refresh`, or hand off to the
  mitigation session).

## Follow-up (not blocking)

- [ ] File separate ticket for the Fusion `dbt1070 BaselineIntrospectionSyntaxInvalid`
  warning on `BUILD_SCOPED_FILE_URL` / `@stage` in the 5 raw bronze models.
