# Fix Design

## Design principle

**Self-healing window driven by the target-table high-water mark**, with `run_started_at`
as the natural end anchor. Explicit var overrides retained **only** for manual backfills,
under fresh var names (`window_start_ts` / `window_end_ts`).

The window is computed inside the SQL via a scalar subquery against `{{ this }}` — no
compile-time `run_query()`, so dbt parse stays fast, and behavior is identical whether
run from Airflow, dbt Cloud, dbt Core CLI, or a manual `dbt build`.

## Locked decisions

See `decisions.md` for rationale.

1. **Hard cutover on legacy var names** — `data_interval_start` / `data_interval_end` /
   `ds_nodash` are no longer recognized as override names. Only `window_start_ts` /
   `window_end_ts` (fanflow) and `mention_me_bootstrap_filename` (mention_me).
2. **Bootstrap seed** — `fanflow_bootstrap_ts: '2024-01-01T00:00:00'`. Safe wide default;
   first non-incremental run or `--full-refresh` scans everything back to Jan 2024.
3. **Safety lookback** — 15 minutes below the high-water mark on incremental runs, to
   catch out-of-order file arrivals. The existing `_filename` anti-join prevents
   re-ingestion.

## Fix 1: `fanflow_unparsed_files` (the incident-ending change)

**File**: `dbt-fes-ae/macros/fanflow/fanflow_unparsed_files.sql`

**Default `safety_lookback_minutes=120`** — matches the current 2-hour lookback
behavior (previously `lookback_hours_interval_start=2`) so we don't tighten tolerance
for out-of-order S3 arrivals. The anti-join dedups any re-scanned files, so the larger
window costs nothing except a slightly larger `DIRECTORY()` scan overlap. See
[`per-model-verification.md`](per-model-verification.md#models-1-5-fanflow-raw-bronzes-all-identical)
for the rationale.

```jinja
{% macro fanflow_unparsed_files(topic, safety_lookback_minutes=120) %}
    {%- set bootstrap_ts   = var('fanflow_bootstrap_ts', '2024-01-01T00:00:00') -%}
    {%- set start_override = var('window_start_ts', none) -%}
    {%- set end_override   = var('window_end_ts',   none) -%}
    {%- set end_anchor     = run_started_at.astimezone(modules.pytz.utc).strftime('%Y-%m-%d %H:%M:%S') -%}

WITH window_bounds AS (
    SELECT
        {% if start_override %}
            '{{ start_override }}'::TIMESTAMP_NTZ
        {% elif is_incremental() %}
            (SELECT COALESCE(MAX(_file_modified_ts), '{{ bootstrap_ts }}'::TIMESTAMP_NTZ)
                    - INTERVAL '{{ safety_lookback_minutes }} minutes'
             FROM {{ this }})
        {% else %}
            '{{ bootstrap_ts }}'::TIMESTAMP_NTZ
        {% endif %} AS start_ts,

        {% if end_override %}
            '{{ end_override }}'::TIMESTAMP_NTZ
        {% else %}
            '{{ end_anchor }}'::TIMESTAMP_NTZ
        {% endif %} AS end_ts
),
{% if is_incremental() %}
parsed_files AS (
    SELECT DISTINCT _filename
    FROM {{ this }}
    WHERE _file_modified_ts >= (SELECT start_ts FROM window_bounds)
),
{% endif %}
SELECT p.relative_path AS _filename, p.last_modified AS _file_modified_ts
FROM DIRECTORY({{ var("prod_fanflow_kafka_stage") if target.name == 'prod' else var("dev_fanflow_kafka_stage") }}) AS p
CROSS JOIN window_bounds AS w
{% if is_incremental() %}
LEFT JOIN parsed_files AS n ON p.relative_path = n._filename
{% endif %}
WHERE STARTSWITH(p.relative_path, '{{ topic }}' || '/')
  AND p.last_modified >= w.start_ts
  AND p.last_modified <  w.end_ts
  {% if is_incremental() %}AND n._filename IS NULL{% endif %}
{% endmacro %}
```

### Signature change (safe)

`fanflow_ingest_topic` currently exposes `(topic_name, lookback_hours_interval_start=2,
lookback_hours_interval_end=0)`. All 5 caller models call it with just a topic name — the
lookback params were never overridden. Drop them:

```jinja
{% macro fanflow_ingest_topic(topic_name) %}
```

The `fanflow_unparsed_files` params (`safety_lookback_minutes=15`) are similarly optional
with a working default.

### Why this handles every failure mode

- **Missed/failed/late run** — next run's `start_ts = MAX(existing _file_modified_ts) - 15m`,
  window auto-spans the gap. No permanent stranding.
- **dbt Cloud, no Airflow vars** — `end_anchor = run_started_at` (dbt-native, tz-aware,
  UTC).
- **Manual backfill** — pass `--vars '{window_start_ts: "...", window_end_ts: "..."}'`.
- **First non-incremental / `--full-refresh`** — seeded from `fanflow_bootstrap_ts`
  (single project var, easy to bump).
- **Anti-join on `_filename`** — unchanged; window is only a perf bound on the
  `DIRECTORY()` scan.

## Fix 2: `fanflow_test_unparsed_files`

Same macro shape, applied to `dbt-fes-ae/macros/fanflow/fanflow_test_unparsed_files.sql`.
Test/audit variant — mirrors the primary macro.

## Fix 3: `mention_me__referrals`

**File**: `dbt-fes-ae/models/fes_integrations/mentionme/referrals.sql`

Current incremental filter:
```sql
WHERE source_file_name >= 'mention_me/referrals/CRMFeedV2_{{ var("ds_nodash") }}.csv'
```

Replace with target-table high-water on `source_file_name`. Filenames are dated as
`CRMFeedV2_YYYYMMDD.csv` — lexical ordering == chronological, so `MAX(source_file_name)`
is a valid high-water:

```sql
WHERE source_file_name > COALESCE(
    (SELECT MAX(source_file_name) FROM {{ this }}),
    ''
)
```

**Why `>` (strict), not `>=`**: `>=` would re-include the current MAX filename on every
intraday run; QUALIFY + MERGE would then re-upsert every customer row for no data
benefit. `>` means "give me files strictly newer than what I've already ingested."
Missed-run recovery still works because any file lexically greater than the last
ingested filename gets picked up — one catch-up run pulls multiple stranded days at
once, and QUALIFY dedups per customer across them.

**Rejected alternative**: reconstruct `CRMFeedV2_{today_ymd}.csv` from
`run_started_at`. Matches the ORIGINAL semantic exactly, but reintroduces the exact
failure mode this PR is fixing — yesterday's file gets stranded when today's run
enforces "today or newer" as the floor.

**Fallback semantics**: on the edge case where `is_incremental()` returns True but the
target has no rows (manual truncate, restore-from-empty-backup), `MAX()` returns NULL
and `COALESCE` returns `''`. Every real filename is lexically `> ''`, so the filter
matches all files — the model recovers on next run. No hardcoded date floor to
accidentally strand old files.

**Not needed**: a `mention_me_bootstrap_filename` var. `--full-refresh` is available
on this model (no `full_refresh_prevention`) and does a full ext-table read.

## Fix 4: `bets_total_stake_validity_check` (dbt-governance)

**File**: `dbt-governance/models/dq_controls/staging/bets_total_stake_validity_check.sql`

**Materialization**: `view` (verified in `dq_controls_staging.yml`). See
[`per-model-verification.md`](per-model-verification.md#model-7) for why this changes
the fix from the initial `run_started_at` draft.

Current:
```sql
where dw_creation_date::date = DATEADD('day', -1, DATE({{ var("data_interval_end") }}))
```

Replace with Snowflake-native `CURRENT_DATE - 1` (evaluated at query time — which is
what a view needs, since `run_started_at` would bake a compile-time literal into the
view definition and freeze it):

```sql
where dw_creation_date::date = DATEADD('day', -1, CURRENT_DATE)
```

No Jinja, no vars, no orchestrator dependency. Semantically identical to what the
`CURRENT_TIMESTAMP` string placeholder in `dbt_project.yml` was already producing at
query time — this model has actually been working correctly under dbt Cloud (unlike
the other affected models). The fix is a code-clarity change, not a recovery.

Drop the `window_end_ts` override for this model — for a view, an override just bakes
a date literal into the view until it's rebuilt without the override, which has limited
value. If someone needs a historical day, they can query the underlying source directly.

## Fix 5: dbt-fes-analytics dead-code cleanup

- Delete `macros/fanflow/fanflow_unparsed_files.sql` and `macros/fanflow/fanflow_ingest_topic.sql`
  (unused — no models call them here).
- Delete the three placeholder vars from `dbt_project.yml`.

## Prevention

Each of the three affected repos gets a CI grep guard added to its existing PR checks —
a shell step in the dbt CI workflow that non-zero exits if any file under `models/` or
`macros/` grep-matches:

```
var\(['"](data_interval_(start|end)|ds|ds_nodash|execution_date|logical_date|ts|ts_nodash|prev_ds|next_ds|run_id|dag_run)['"]\)
```

## Rollout order

Three independent PRs — no merge order dependency, all safe to land in parallel:

1. **dbt-fes-ae** — the incident-ending PR. Ends the fanflow silent-0-row bleeding.
2. **dbt-governance** — small model + `dbt_project.yml` cleanup.
3. **dbt-fes-analytics** — dead-code cleanup.

## Pre-flight before merging PR 1

Because we chose hard cutover: **audit every dbt Cloud job config for any job passing
`data_interval_start` or `data_interval_end` as a Job Var or env var**. Rename to
`window_start_ts` / `window_end_ts`, or remove entirely (the macro self-heals).

Also check any external orchestration or backfill scripts that still call `dbt build
--vars '{data_interval_end: ...}'` — same treatment.
