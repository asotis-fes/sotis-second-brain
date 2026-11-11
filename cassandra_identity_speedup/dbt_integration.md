# dbt-fes-ae Integration Plan — repointing the identity source to CDC

Grounded in the actual models (read 2026-09-28). Scope = the **5 external tables** the identity
source exposes: `loyalty_private_fan_id_map_ext`, `martech_private_fan_id_map_ext`, `core_ext`,
`preferences_ext`, `favorites_ext` (Cassandra `id.loyalty`, `id.marketing`, `profile.core`,
`profile.preferences`, `profile.favorites`). `tenant_fanid` etc. are NOT in the dbt source → out of
scope here even though they have CDC.

## The current contract (what every consumer assumes)

All 5 consumers share one idiom:
```sql
WITH latest_partition AS (SELECT MAX(upload_date) FROM {{ source(...) }})
SELECT <cols>, {{ add_incremental_timestamps() }}
FROM {{ source(...) }}
WHERE upload_date = (SELECT max_upload_date ...)      -- pick the newest FULL snapshot
QUALIFY ROW_NUMBER() OVER (PARTITION BY <pk> ORDER BY <recency>) = 1   -- one row per PK
```
- `loyalty_private_fan_id_map` (incremental; filters `created >= data_interval_start - 1d`) + a
  non-incremental `_latest` variant. PK `loyalty_id`→`loyalty_account_id`, `private_fanid`→`private_fan_id`.
- `martech_private_fan_id_map` (incremental; `created >= data_interval_start`). PK `martech_id`.
- `unified_profile_core` (table). PK `profile_id`; `ORDER BY modified_ts DESC`. Uses
  `cassandra_timeuuid_to_timestamp(modified)`. LEFT JOINs `ref('profile_id_private_fan_id_map')`.
- `unified_profile_preferences` (table). PK `profile_id`; `ORDER BY upload_date DESC, modified_ts DESC`.
  Same timeUUID(modified) + profile-id join.
- `unified_profile_favorites` (table). PK `(profile_id, entity_id)`; `created` =
  `cassandra_timeuuid_to_timestamp(favorite_id)`. Same profile-id join.

**Key macros:** `add_incremental_timestamps()` = `CURRENT_TIMESTAMP() AS _insert_ts,_update_ts`;
`cassandra_timeuuid_to_timestamp(col)` extracts the embedded ts from a Type-1 UUID **string**;
`full_refresh_prevention()` raises on `--full-refresh` (our seed guard). No custom
delete-aware materialization exists (`materializations/` only has `table_clone`; `auto_delta/` is a
data-diff QA tool, not a materialization).

**Mesh note:** models are `+access: public`, `+group: analytics_engineering` → downstream Mesh
projects `ref('fes_data', …)` them. So the consumers' **output columns/grain must stay identical**;
we only change what they read FROM.

## Target shape (per table)

```
@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD (JSON_FF)
  → IDENTITY.CDC_RAW.<table>            native VARIANT landing (COPY; retains full CDC history we control)
    → ref: <table>_cdc_current          NEW dbt model — parse + node dedup + latest-per-PK + drop op='d',
                                          UNION one-time batch seed; emits the SAME raw cols+types as *_ext
      → consuming model (repointed)      source(*_ext) → ref(<table>_cdc_current); snapshot idiom removed
```

## What changes in dbt-fes-ae (step by step)

1. **New source** over the native landing tables: `identity__cdc` (DB IDENTITY, schema `CDC_RAW`),
   one entry per table, `loaded_at_field` = the COPY load ts (drives freshness on lag, not daily).
2. **New macro `cassandra_cdc_current(...)`** — the reusable parse+dedup (see design.md / Anna's SQL):
   parse `$1:after:<col>:value`; `node_id` from `CommitLog-7-(\d+)\.log` segment runs (two CTE levels —
   `LAG` can't nest in `SUM() OVER`); `IS_NULL_VALUE()` for VARIANT nulls; latest-per-PK via
   `ROW_NUMBER() … ORDER BY source:ts_ms DESC, <tiebreak> DESC`; **exclude `op='d'`**.
3. **5 new `<table>_cdc_current` models** — call the macro with each table's PK + column list, then
   **normalize column types to match the Parquet seed** (see funky #2), and **UNION the one-time seed**.
4. **Repoint the 5 consumers** — replace `source('identity__source','*_ext')` +
   `latest_partition`/`WHERE upload_date=max`/snapshot-`QUALIFY` with `ref('<table>_cdc_current')`.
   Keep the renames, timeUUID conversions, `profile_id_private_fan_id_map` join, and
   `add_incremental_timestamps()` unchanged so OUTPUT is identical (Mesh-safe).
5. **Retire/relax the old source**: keep `*_ext` defined (dev + seed) but drop it from the daily
   `tag:identity` critical path; move source-freshness onto the CDC source.

## The FUNKY bits (beyond "just union once")

1. **The `MAX(upload_date)` snapshot idiom is incompatible with CDC — this is the big one.**
   CDC is not a daily full snapshot; there is no `upload_date` partition to pick. Every consumer's
   `latest_partition`/`WHERE upload_date = max` must be removed (dedup moves into `_cdc_current`).
   *Two ways to do it:* **(A) minimal-diff** — have `_cdc_current` emit a constant `upload_date` +
   one row per PK, so the existing SQL still "works" untouched (vestigial but low-risk); **(B) clean** —
   rewrite the 5 consumers to read the deduped `_cdc_current` and delete the snapshot logic.
   Recommend **B** (honest, maintainable; output stays identical so Mesh is safe).

2. **Type/representation mismatch between the Parquet seed and the CDC JSON.** Same logical column,
   different encoding on each side — the union must normalize BOTH:
   - `created`: batch Parquet = timestamp/datetime string (consumers compare it to `::TIMESTAMP_NTZ`);
     CDC = **epoch-ms bigint** (`created:value = 1790609995564`) → must `TO_TIMESTAMP_NTZ(value/1000)`.
   - `modified`, `favorite_id`: Type-1 timeUUID **strings** on both sides → the existing
     `cassandra_timeuuid_to_timestamp` macro works IF the CDC parse keeps them as raw UUID strings
     (verify with a probe on core/favorites).
   - map/collection cols (e.g. `preferences.fanatics_one_opt_in_by_tenant`): batch `_convert_value`
     JSON-stringifies maps; CDC nests them under `:value`. Normalize to the same shape.
   → **Column-by-column type reconciliation is required per table** (not optional). This is the single
     most error-prone part; parity tests per column will catch it.

3. **Deletes are no longer free.** The batch snapshot dropped deleted rows implicitly (they just
   vanished from the next full snapshot). CDC emits `op='d'` (Cassandra delete carries only PK).
   `_cdc_current` must exclude the latest-per-PK row when it's a delete. dbt's stock `merge` upserts
   only — so either (a) materialize `_cdc_current` as a **full rebuild** (view/table) that recomputes
   latest-per-PK over seed+all-CDC and filters `op<>'d'` (simplest, correct, re-derivable), or
   (b) incremental merge carrying an `is_deleted` flag + `delete+insert`/predicate handling.

4. **Full-refresh safety.** If `_cdc_current` is a seeded INCREMENTAL, `--full-refresh` wipes the
   seed and rebuilds from CDC only → loses all pre-CDC rows unchanged since cutover. Guard with
   `full_refresh_prevention()` (already in the repo), OR make the seed re-derivable: seed = the frozen
   batch baseline (materialize once into `IDENTITY.SEED.<table>` at cutover) + replay the full CDC
   landing table each build. Full-rebuild `_cdc_current` (funky #3a) is inherently full-refresh-safe.

5. **Late / out-of-order arrivals.** Latency is bimodal (0.94% > 1h, max 2.3h). Never gate the CDC
   read on a wall-clock `source:ts_ms` watermark (the current models' `created >= data_interval_start`
   idiom would silently drop late events). Use the landing **load time** (or a Snowflake STREAM) as the
   incremental boundary, or full-rebuild. Also relax `loyalty`/`martech`'s `created >=` incremental
   filter accordingly.

6. **`op='i'` ≠ insert / upsert-only history.** Cassandra writes are upserts; `loyalty` is all `op='i'`
   even for updates. Fine for current-state (we take latest per PK) — just don't assume `i`=new-row.

7. **`profile_id_private_fan_id_map` is an upstream dependency, NOT one of our 5.** The three
   `unified_profile_*` models LEFT JOIN it for `private_fan_id`. It's built elsewhere (not from these
   external tables) → leave it alone; our change doesn't touch it.

8. **Seed cadence vs. the silent-completeness gap.** Anna: a change missing from all 3 nodes is
   undetectable from CDC alone. One-time union won't self-heal that drift. User chose one-time; note
   that re-running the batch seed periodically is the only reconciliation and is cheap to redo.

## Parity plan (before cutover)
Per table, compare `_cdc_current` vs. today's consumer output: row counts, PK set diff, and
column-value equality on a sample — especially the type-normalized columns (`created`, `modified_ts`,
maps). Parallel-run both sources for a few days; cut over per table (loyalty first).
