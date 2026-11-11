# Per-Model Verification of the High-Water-Mark Fix

For each of the 7 directly-affected models, walk through:
1. **Materialization + config** — confirmed from the repo.
2. **Watermark column** — does one exist, and is it monotonic?
3. **Anti-join / dedup behavior** — does the fix preserve correctness?
4. **First-run and gap-fill behavior** — what happens the first time this runs post-fix?
5. **Edge cases + open questions**.
6. **Verdict** — is Option 2 the right fix as-designed, or does this model need a tweak?

---

## Models 1–5: fanflow raw bronzes (all identical)

| Model | Topic |
|---|---|
| `fes_enriched` | `fes_enriched/` |
| `fes_enriched_fanapp` | `fes_enriched_fanapp/` |
| `fcore_fes_enriched` | `fcore_fes_enriched/` |
| `fcore_fes_enriched_fanapp` | `fcore_fes_enriched_fanapp/` |
| `fes_fanflow_enriched` | `fes_fanflow_enriched/` |

All 5 model files are one-liners: `{{ fanflow_ingest_topic('<topic>') }}`. Config is a
shared YAML anchor.

### Materialization + config

```yaml
materialized: incremental
unique_key: pk
merge_exclude_columns: ['_insert_ts']
tags: ['fanflow']
database: FANFLOW  (prod)
schema: SOURCE
snowflake_warehouse: FDE_MWAA_WH  (prod)
pre_hook: "{{ full_refresh_prevention() }}"
```

### `full_refresh_prevention` — critical constraint

The pre-hook raises a compiler error if `flags.FULL_REFRESH` is set:

```jinja
{% macro full_refresh_prevention() %}
  {% if execute %}
    {% if flags.FULL_REFRESH %}
      {{ exceptions.raise_compiler_error("Full refresh is not allowed for this model...") }}
    {% endif %}
  {% endif %}
{% endmacro %}
```

**Consequences**:
- The `{% else %}` non-incremental branch in the proposed macro is dead code in prod.
  Leave it in — cheap insurance for dev-target one-time builds — but it will never fire
  against `FANFLOW.SOURCE`.
- Post-fix gap-fill **cannot** use `--full-refresh`. Only path is
  `--vars '{window_start_ts: "<gap-start>"}'`.
- If the target table were ever accidentally truncated / dropped, we would need to
  temporarily edit the `pre_hook` to allow a single full-refresh rebuild. Not planned.

### Watermark column: `_file_modified_ts`

Emitted by `fanflow_ingest_topic` as:

```sql
src.last_modified_ts AS _file_modified_ts   -- from DIRECTORY(@stage).last_modified
```

I.e., the S3 object's `last_modified` timestamp, cast to `TIMESTAMP_NTZ(9)`. This is the
same value Snowflake returns from `DIRECTORY()` — the time the file was PUT to S3.

**Monotonicity**: for a given Kafka partition, files land in write order, so
`last_modified` grows monotonically within a partition. Across partitions there can be
minor skew (a flush on partition A at 10:00:15 can be followed by a flush on partition B
at 10:00:03 hitting S3 later, if you get unlucky). The `safety_lookback_minutes` param
exists precisely to absorb this skew.

### Anti-join behavior with the new pattern

```sql
parsed_files AS (
    SELECT DISTINCT _filename
    FROM {{ this }}
    WHERE _file_modified_ts >= (SELECT start_ts FROM window_bounds)
)
```

- `parsed_files` = files already ingested with `_file_modified_ts` in
  `[MAX(_file_modified_ts) - 15m, now)`.
- LEFT JOIN + `n._filename IS NULL` excludes files already ingested inside that same
  window.
- Files whose `_file_modified_ts` is BEFORE `start_ts` in target are irrelevant — they
  can't satisfy `p.last_modified >= start_ts` either. No re-ingestion risk.

### First-run behavior post-fix (largest risk area)

**Current state of these 5 tables** (per user's context — under investigation with the
manual-mitigation session): they have been silently loading 0 rows since dbt Cloud
cutover. `MAX(_file_modified_ts)` is stuck at whatever the last successful
Airflow-orchestrated run left behind.

Three sub-cases at PR 1 merge time:

- **A. Mitigation caught them up to ~now** — `MAX(_file_modified_ts)` is recent
  (within hours). First self-healed run window is small; fine.
- **B. Mitigation only patched forward-arriving files** — target has recent rows for
  post-mitigation-start files, but a gap in the middle. `MAX(_file_modified_ts)` is
  recent, but old files in the gap were never ingested. **Naive fix would miss them.**
  Recovery: one-time run with `--vars '{window_start_ts: "<gap-start>"}'` to reprocess
  the gap; anti-join dedups anything already there.
- **C. Nothing was mitigated yet** — `MAX(_file_modified_ts)` is old (weeks or
  months). Auto-window is huge; `DIRECTORY()` returns tens of thousands of files;
  first run is very expensive but correct. Alternative: `--vars '{window_start_ts:
  "<recent>"}'` for a cheap first run + follow-up runs with widening windows to
  backfill.

**Coordination point**: needs alignment with the mitigation session BEFORE PR 1 merges.
Task #6 in the task list.

### `safety_lookback_minutes` default choice

Original macro used `lookback_hours_interval_start=2` — a **2-hour** lookback below
`data_interval_end`. My draft used **15 minutes** below `MAX(_file_modified_ts)`.

These are meaningfully different tolerance profiles for out-of-order S3 arrivals. To
preserve original behavior with zero regression risk, **change the default to 120
minutes** (`safety_lookback_minutes=120`). The anti-join dedups any re-scan, so the
larger lookback costs nothing except a slightly larger `DIRECTORY()` scan overlap.

**Change to `fix-design.md`**: default `safety_lookback_minutes=120` (was 15).

### Verdict

**Option 2 works.** Two tweaks vs the initial draft:
- Default `safety_lookback_minutes=120` (match current 2-hour behavior).
- Leave the `{% else %}` bootstrap branch in the macro for dev target, even though
  it's dead code in prod (`full_refresh_prevention` blocks it).

### Manual-action decision per topic

| Table | Decision | Trigger |
|---|---|---|
| `fes_enriched` | TBD | State of `MAX(_file_modified_ts)` after mitigation |
| `fes_enriched_fanapp` | TBD | Same |
| `fcore_fes_enriched` | TBD | Same |
| `fcore_fes_enriched_fanapp` | TBD | Same |
| `fes_fanflow_enriched` | TBD | Same |

Query to run before merge:

```sql
SELECT
    'fes_enriched' AS model, MIN(_file_modified_ts), MAX(_file_modified_ts), COUNT(DISTINCT _filename) AS files
FROM FANFLOW.SOURCE.FES_ENRICHED
UNION ALL SELECT 'fes_enriched_fanapp', MIN(_file_modified_ts), MAX(_file_modified_ts), COUNT(DISTINCT _filename)
FROM FANFLOW.SOURCE.FES_ENRICHED_FANAPP
UNION ALL SELECT 'fcore_fes_enriched', MIN(_file_modified_ts), MAX(_file_modified_ts), COUNT(DISTINCT _filename)
FROM FANFLOW.SOURCE.FCORE_FES_ENRICHED
UNION ALL SELECT 'fcore_fes_enriched_fanapp', MIN(_file_modified_ts), MAX(_file_modified_ts), COUNT(DISTINCT _filename)
FROM FANFLOW.SOURCE.FCORE_FES_ENRICHED_FANAPP
UNION ALL SELECT 'fes_fanflow_enriched', MIN(_file_modified_ts), MAX(_file_modified_ts), COUNT(DISTINCT _filename)
FROM FANFLOW.SOURCE.FES_FANFLOW_ENRICHED;
```

---

## Model 6: `mention_me__referrals`

### Materialization + config

```yaml
materialized: incremental
unique_key: customer_email
database: FES_INTEGRATIONS  (prod)
schema: MENTION_ME
tags: ['daily']
pre_hook: "ALTER EXTERNAL TABLE FES_INTEGRATIONS.MENTION_ME.REFERRALS_EXT REFRESH"
```

- **No `full_refresh_prevention`** → `--full-refresh` is allowed here.
- Pre-hook refreshes the S3-backed external table before every run (ensures Snowflake's
  metadata catalog reflects any files added since last run).

### Watermark column: `source_file_name`

Populated from the ext table's `source_file_name` column (mapped from
`metadata$filename` at ext table definition). Format:

```
mention_me/referrals/CRMFeedV2_YYYYMMDD.csv
```

**Monotonicity**: filenames are date-stamped in the format above, so **lexical order ==
chronological order**. `MAX(source_file_name)` is a valid high-water. No skew concern —
mention_me drops one file per day.

### Dedup / correctness

Current model:

```sql
WHERE source_file_name >= 'mention_me/referrals/CRMFeedV2_{{ ds_nodash }}.csv'
QUALIFY row_number() OVER (PARTITION BY customer_email ORDER BY source_file_name DESC) = 1
```

- **QUALIFY**: within the FILTERED (post-`WHERE`) row set, keeps the latest
  `source_file_name` per `customer_email`.
- **Model-level `unique_key: customer_email`**: dbt MERGEs on `customer_email`. Existing
  rows for a customer get UPDATED by newer rows; new customers get INSERTED.

**Post-fix behavior with `MAX(source_file_name)` watermark**:

- If target has customer X at `CRMFeedV2_20250925.csv` and a new run brings X at
  `CRMFeedV2_20260722.csv`, the MERGE overwrites X's row. ✓
- If a customer only appears in files older than `MAX(source_file_name)`, they were
  already ingested previously — no action needed. ✓
- If a customer appears in a file DROPPED by mention_me AFTER we advanced past that
  file's date (e.g., they backfill 2025-10-15 after we're already on 2025-10-20), we
  **miss** them until the next `--full-refresh`. Same as the current design's behavior.
  Acceptable — mention_me does not backfill.

### First-run behavior post-fix

- Target's current `MAX(source_file_name)` is either `CRMFeedV2_20250925.csv`
  (unchanged since dbt Cloud cutover — placeholder default value pinned it there) or
  something recent (if the mitigation session touched this table too).
- On first run, filter = `source_file_name >= <that value>`. All files from that date
  forward get scanned, deduped via QUALIFY, MERGEd. Self-heals cleanly.
- **No coordination needed with mitigation session** unless they've been manually
  advancing `source_file_name` in the target — worth confirming, but this model isn't
  fanflow-critical, so likely they haven't touched it.

### Verdict

**Option 2 works as-designed. No tweaks.** The pattern:

```sql
WHERE source_file_name >= (
    SELECT COALESCE(MAX(source_file_name),
                    'mention_me/referrals/CRMFeedV2_20240101.csv')
    FROM {{ this }}
)
```

is exactly right. Bootstrap default `CRMFeedV2_20240101.csv` seeds the filter on the
first-ever-run / `--full-refresh` path — matches "safe wide default" decision (D3).

### Manual-action decision

Query to run:

```sql
SELECT
    COUNT(*) AS row_count,
    MAX(source_file_name) AS max_filename,
    MAX(customer_recognised_date) AS max_recognised_date
FROM FES_INTEGRATIONS.MENTION_ME.REFERRALS;
```

If `max_filename <= CRMFeedV2_20250925.csv`, the fix alone catches up (all missed daily
files get picked up on the next run). If it's newer (mitigation touched it), no gap.

---

## Model 7: `bets_total_stake_validity_check` (dbt-governance)

### Materialization + config — DIFFERENT FROM EVERYTHING ELSE

```yaml
materialized: view  ← this changes the fix
database: FBG_GOVERNANCE
schema: STAGING
tags: ['dq_metrics', 'validity', 'staging']
```

**This is a view.** No `is_incremental()`, no target-table state, no watermark to
draw from. The compiled SQL becomes a `CREATE OR REPLACE VIEW`. All expressions inside
the view are evaluated by Snowflake at **query time**, not dbt compile time — unless
they're baked as literals at compile time.

### Why my initial `run_started_at` proposal was wrong

Draft in `fix-design.md` §Fix 4:

```sql
where dw_creation_date::date = DATEADD('day', -1,
    COALESCE(
        TRY_CAST('{{ var("window_end_ts", "") }}' AS TIMESTAMP_NTZ),
        '{{ run_started_at.astimezone(modules.pytz.utc).strftime("%Y-%m-%d %H:%M:%S") }}'::TIMESTAMP_NTZ
    )::DATE)
```

`{{ run_started_at }}` interpolates as a compile-time string literal. For a view, that
literal becomes part of the view definition. Result: the view is permanently pinned to
"yesterday relative to when the view was last built" — which is exactly the trap
we're trying to escape.

### Correct fix — use Snowflake's `CURRENT_DATE`

Push the "yesterday" computation into Snowflake, evaluated at query time:

```sql
{% set end_override = var('window_end_ts', none) %}
where dw_creation_date::date =
    {% if end_override %}
        DATEADD('day', -1, '{{ end_override }}'::TIMESTAMP_NTZ)::DATE
    {% else %}
        DATEADD('day', -1, CURRENT_DATE)   -- evaluated by Snowflake at query time
    {% endif %}
```

This is **semantically identical** to what the current `CURRENT_TIMESTAMP` string
placeholder in `dbt-governance/dbt_project.yml` compiles into. So this model has
actually been working correctly under dbt Cloud (the placeholder is doing something
useful, unlike dbt-fes-ae's placeholder). The fix is just:
- Remove the `var("data_interval_end")` reference — replace with the SQL expression above.
- Remove the misleading `CURRENT_TIMESTAMP` string default from `dbt_project.yml` (it
  was compensating for the var reference; once the reference is gone, the default is
  vestigial).

### The `window_end_ts` override — what it's actually for

Because the model is a view, a `--vars '{window_end_ts: ...}'` override doesn't
"backfill a specific day" the way it does for incrementals. It just re-materializes the
view with the date literal baked in — the view then returns rows for that specific day
until it's rebuilt without the override. Value is limited.

**Recommendation**: drop the override entirely for this model. If someone needs to
inspect a specific historical day, they can query the underlying source directly.
Keeping the override adds confusion without value. Simplifies the model.

Final fix:

```sql
where dw_creation_date::date = DATEADD('day', -1, CURRENT_DATE)
```

That's it. Zero Jinja, zero vars, zero orchestrator dependency. Snowflake evaluates
`CURRENT_DATE` at query time, so consumers always get "yesterday relative to now."

### Verdict

**Option 2 does NOT apply here** (no target table, no watermark). Correct fix is
`CURRENT_DATE - 1` — Snowflake-native, evaluated at query time. `run_started_at` was
the wrong instinct because it's a compile-time Python datetime.

### Manual-action decision

None needed. The current placeholder (`CURRENT_TIMESTAMP` string) already produces
"query-time yesterday" behavior — no data has been lost, no snapshots missed. The fix
is a code-clarity change, not a recovery.

### Update `fix-design.md`

The §Fix 4 draft needs to be replaced with the `CURRENT_DATE - 1` version above.

---

## The ~47 downstream event bronzes (frozen by consequence, not by broken code)

Models under `dbt-fes-ae/models/fanflow/bronze_events/*__bronze.sql`. All use
`fanflow_bronze_with_backfill`, which delegates to `fanflow_parse_event_table` — verified
to have **no** `var("<airflow-name>")` references.

**Config** (shared YAML anchor `ff-bronze-config` with the same
`full_refresh_prevention` pre-hook):

```yaml
materialized: incremental
unique_key: pk
pre_hook: "{{ full_refresh_prevention() }}"
```

**Behavior post-PR-1**: they `ref()` the 5 raw bronzes above. Once the raw bronzes
resume advancing, the event bronzes will pick up new rows on their next incremental
run. They too are `full_refresh`-blocked, so gap-fill via `--full-refresh` is
unavailable — but no gap-fill should be needed. As new raw-bronze rows land, the event
bronzes' native incremental filter (based on `MAX(_upstream_update_ts)` inside
`fanflow_parse_event_table`) pulls them forward.

**Verdict**: no code change, no manual action beyond a triggered run to un-freeze once
raw bronzes catch up.
