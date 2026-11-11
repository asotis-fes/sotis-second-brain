# Locked Decisions

Recorded 2026-07-22 during initial design session.

## D1. Do not push Airflow vars into dbt Cloud on each run

**Decision**: Fix the dbt code so it doesn't depend on Airflow context. Do NOT solve the
problem by teaching dbt Cloud to inject `data_interval_*` on every job.

**Why**: Not every dbt job is triggered from Airflow. Some run on dbt Cloud schedules,
some run from CI, some run manually. A dbt code path that requires Airflow context is
brittle by design — it silently fails whenever the orchestrator changes.

**Alternative rejected**: Passing Airflow context through to dbt Cloud via the Airflow
`DbtCloudRunJobOperator` `data_var` field. Would fix Airflow-triggered runs only;
dbt-Cloud-scheduled runs and manual runs still break.

## D2. Hard cutover on legacy var names

**Decision**: Remove `var("data_interval_start")` / `var("data_interval_end")` /
`var("ds_nodash")` fallbacks entirely. Only new names (`window_start_ts` /
`window_end_ts`) are recognized as overrides.

**Why**: Keeping the old names as aliases invites the exact same silent-failure mode to
resurface later — someone adds a new default in `dbt_project.yml`, forgets it's a
placeholder, and we're back where we started. The self-healing window makes explicit
overrides unnecessary for normal operations; keeping them under fresh names makes the
intent (backfill only) obvious.

**Precondition**: Audit dbt Cloud job configs and any external `dbt build --vars` callers
for the old names. Rename or remove before merging PR 1. See `plan.md` §Pre-flight.

## D3. Bootstrap seed = `'2024-01-01T00:00:00'`

**Decision**: Default `fanflow_bootstrap_ts` = `'2024-01-01T00:00:00'`. Used only on
first non-incremental run or `--full-refresh`.

**Why**: Safe wide default — scans everything the S3 stage has back to Jan 2024 on
first run, guaranteeing zero risk of missing history. Slightly more expensive first run,
but that only happens once per model. Matches the spirit of the current 2023-01-02
placeholder without the "silent 0 rows" trap.

**Alternatives considered**:
- Reuse `10x_launch_timestamp: '2026-04-23'` — tighter, but if we ever need to reprocess
  pre-launch backfill files we have to remember to pass a var.
- No default, fail fast on `--full-refresh` without an explicit var — safest, but
  surprising for anyone doing a routine full-refresh.

## D4. Self-healing window instead of fixed lookback

**Decision**: `start_ts = MAX(_file_modified_ts) - 15m` on incremental runs. Not
`run_started_at - 2h` (the old fixed lookback).

**Why**: The failure mode we're fixing is **"a run was missed and files stranded."** A
fixed lookback anchored on `now` guarantees anything stranded before `now - lookback` is
lost forever. A high-water-mark anchor is inherently self-healing — the gap between the
last successful ingest and now is always covered on the next successful run.

**Safety lookback (15 min)**: Catches out-of-order file arrivals (a file whose
`last_modified` is slightly earlier than a file we already ingested). The existing
`_filename` anti-join prevents re-ingestion, so the lookback is free.

## D5. Compute window in SQL, not in Jinja `run_query()`

**Decision**: The high-water lookup happens in a scalar subquery inside the compiled
SQL, not in a Jinja `{% set hw = run_query(...) %}` block at parse time.

**Why**: Keeps dbt parse fast (no per-model warehouse queries during compile). Same
correctness, simpler code, one less Snowflake round-trip per model. Also makes the
compiled SQL fully self-contained — you can copy it into Snowflake console and it
behaves identically.

## D7. `bets_total_stake_validity_check` uses `CURRENT_DATE - 1`, not the high-water pattern

**Decision**: For this one model, don't use Option 2 (target-table high-water-mark).
Use `WHERE dw_creation_date::date = DATEADD('day', -1, CURRENT_DATE)` — a
Snowflake-native expression evaluated at query time.

**Why**: The model is `materialized: view` (per `dq_controls_staging.yml`). For a view,
`run_started_at` interpolates as a compile-time string literal that gets baked into the
view SQL — the view then permanently returns "yesterday relative to when it was built"
until re-materialized. `CURRENT_DATE` is evaluated by Snowflake at query time, so
consumers of the view always see "yesterday relative to now."

Semantically identical to what dbt-governance's `CURRENT_TIMESTAMP` string placeholder
in `dbt_project.yml` has been producing under dbt Cloud — this model has actually been
working correctly. The fix is a code-clarity change (remove the misleading `var(...)`
reference and the vestigial placeholder default), not a data recovery.

**Also**: drop the `window_end_ts` override for this model — a var-based date override
on a view just bakes a literal into the view definition, which has limited value.

## D6. CI grep guard — DEFERRED, not part of this fix

**Original decision** (revised 2026-07-22): the CI grep guard was scoped out of the
incident-fixing PR. Regression prevention is a separate concern from fixing the
0-row bug. If we want a lint step later, it would be its own PR with its own
review — not folded into the incident fix.

**Why revised**: user feedback while drafting PR 1 — "the task here is to fix the
issue, not to add linting."

**Original rationale (kept for future reference)**: shell step that fails if any
file under `models/` / `macros/` / `snapshots/` / `analyses/` / `tests/` matches
`var\(['"](data_interval_(start|end)|ds|ds_nodash|execution_date|logical_date|ts|ts_nodash|prev_ds|next_ds|run_id|dag_run)['"]\)`.
Cheapest possible regression guard.

## D8. Scope reduction — PR 1 is the entire fix

**Decision** (2026-07-22, mid-PR-draft): This work is one PR against dbt-fes-ae,
not three PRs across three repos.

- **dbt-governance / `bets_total_stake_validity_check`**: dropped. Not our repo.
  Its `CURRENT_TIMESTAMP` string default in `dbt_project.yml` is evaluated by
  Snowflake at query time, so the view returns "yesterday relative to now"
  correctly under dbt Cloud. Not an incident. If normalization is wanted later,
  hand off to that team.
- **dbt-fes-analytics dead-code cleanup**: dropped. The duplicate fanflow macros
  are unused there. Removing them is hygiene, not incident-fixing.
- **CI grep guard**: dropped (see D6 above).

**Why**: keep the incident fix focused on the incident. Prevention and hygiene are
their own follow-ups if we want them.
