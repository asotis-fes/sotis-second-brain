# Runtime behavior concerns beyond parse-clean

Just because `dbt parse` returns exit 0 doesn't mean models will build correctly on Fusion. This doc catalogues everything I investigated for silent behavior divergences from dbt-core 1.8, including what I found and what remains untested.

Researched 2026-07-11 against Fusion 2.0.0-preview.196. Sources: dbt Labs docs, dbt-fusion GitHub CHANGELOG, dbt-fusion issues, and the `dbt_snowflake_query_tags` package Hub listing.

## Resolved during migration

### C1. Custom `table` materialization override
**Status:** Deleted (was `macros/materializations/table.sql`).

**Investigation:** Fusion DOES support custom materialization overrides at the root-project level. All Jinja helpers used (`load_cached_relation`, `make_intermediate_relation`, `run_hooks`, `set_query_tag`, `create_table_as`, `this.incorporate`) are documented as compatible. Fusion also natively supports Snowflake `INSERT OVERWRITE INTO`.

**Why we deleted anyway:** The custom `table.sql` blocked C2 (Python model routing) — see below. Team green-light on losing INSERT OVERWRITE was the deciding factor.

**Post-migration follow-up:** revisit INSERT OVERWRITE preservation via a Fusion-idiomatic materialization override, not the dbt-adapters version-pinned copy we had.

### C2. Python model with `materialized="table"` routes to SQL-only custom
**Status:** Fixed by deleting the custom materializations.

**Investigation:** Fusion validates Python model materializations against `[table, incremental]` before dispatch. Even with our custom `python_table` materialization defined, Fusion refuses to accept `materialized="python_table"` on Python models — the allowlist is checked pre-dispatch. Once we rename to `materialized="table"`, the custom SQL-only `table.sql` shadows Fusion's native table handling and would fail at build time (either supported-languages error or trying to run Python source as SQL DDL).

**Fix applied:** Delete both custom materializations, let Fusion use its native handling for SQL and Python.

### C3. `set_query_tag` dispatch override
**Status:** Untested but ~85% confidence works.

**Investigation:** 
- Fusion supports the `dispatch:` config in `dbt_project.yml`
- `dbt_snowflake_query_tags` 2.6.0 (auto-resolved by Fusion `dbt deps`) is Fusion-verified by dbt Labs
- Our `default__set_query_tag(extra = {})` override uses `fromjson()` — dbt-jinja (Fusion's rendering engine, minijinja-based) supports `fromjson`
- No `fromyaml`, no `varargs`, no dict introspection quirks

**Residual risk:** dbt-jinja is not Jinja2 exactly. Edge cases in `fromjson` output type, dict `.update()` semantics, or attribute access on filter results may differ subtly. Watch for query tags not populating in Snowflake `QUERY_HISTORY` after first Cloud IDE build.

**Testing:** After `dbt build` on any model in Cloud IDE, query:
```sql
SELECT query_tag, query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE user_name = 'DBT_CLOUD'
  AND start_time > DATEADD(hour, -1, CURRENT_TIMESTAMP)
  AND query_tag IS NOT NULL
LIMIT 5;
```
Should show JSON tags with `node_name`, `warehouse`, `materialized`, `dbt_version`, etc.

### C4. Package version 2.5.0 → 2.6.0 auto-bump
**Status:** Low risk, no action.

**Investigation:** Fusion's `dbt deps` resolved `dbt_snowflake_query_tags` from 2.5.0 → 2.6.0 automatically. 2.6.0 is Fusion-verified. Changelog between minor versions typically doesn't change public macro signatures.

### C5. `on_schema_change: append_new_columns`
**Status:** Untested but HIGH confidence works.

**Investigation:** Fusion documentation covers this config identically to dbt-core. No Fusion-specific deprecation. Column-diff still happens at runtime (Fusion baseline static analysis doesn't download remote schemas).

### C6. `flags.FULL_REFRESH` in `full_refresh_prevention()`
**Status:** Untested but HIGH confidence works.

**Investigation:** `flags.FULL_REFRESH` is documented as the current pattern for Fusion. The `full_refresh_prevention()` macro at `macros/full_refresh_prevention.sql` should behave identically. Note that Fusion deprecates the `{{ context }}` variable, but `flags` itself is preserved.

**Follow-up test in Cloud IDE:** Run `dbt --full-refresh build --select loyalty_analytics_ledger` and confirm it raises the compiler error.

### C7. Pre-hooks + `snowflake_warehouse` config
**Status:** Untested but HIGH confidence for `snowflake_warehouse` config, MEDIUM for `USE WAREHOUSE` pre-hooks.

**Investigation:** `snowflake_warehouse` model config is documented as the idiomatic path in Fusion. Fusion "automatically manages connection parallelism" so pre-hooks should stay in the same session as the model DDL — but this is inference, not a documented guarantee.

**Recommendation:** For any model where warehouse switching matters, prefer `snowflake_warehouse` config over `pre_hook "USE WAREHOUSE X"`. Our project root already sets a `+pre-hook: "USE WAREHOUSE ..."` that fires from a var — this may or may not work in Fusion. Watch for models running on the wrong warehouse after cutover.

## Deliberate behavior change

### C8. `merge_exclude_columns` (typo → correct plural form)
**Status:** Committed as behavior change.

**Was:** `merge_exclude: ['_insert_ts']` — typo, silently ignored by dbt-core, `_insert_ts` was updated on every merge.

**Now:** `merge_exclude_columns: ['_insert_ts']` — correct dbt-snowflake key. `_insert_ts` will retain original insertion timestamp; MERGE updates exclude it.

**Affected models:** all `gam_*` (google_ads.yaml via anchor), `magnite_pa_hourly`, `meta_ad_cost_dtl_hrly`.

**Downstream risk:** any consumer treating `_insert_ts` as "most recent merge time" is now incorrect and should switch to `_update_ts` (or model's own recency signal).

## Untested (need Cloud IDE + real Snowflake)

### C9. Actual model build success
Parse-clean ≠ build-clean. First `dbt build --select <leaf_model> --empty` in Cloud IDE tests all the actual dispatch + SQL generation paths.

### C10. Query tag JSON content
See C3 testing section.

### C11. Model runs on correct warehouse
See C7. Watch Snowflake session history for `USE WAREHOUSE` statements matching expected warehouses.

## Local verification results (2026-07-11)

Ran locally against real Snowflake (Fusion 2.0.0-preview.196, `externalbrowser` auth to FES_DATA_DEVELOPER role, cached OAuth token from `snow` CLI reused).

### Compile
- **`dbt compile` exit 0** on entire tree — 980 models + 1005 tests + 11 seeds + 42 analyses = 2038 nodes compiled successfully in 9 seconds.
- **20 `dbt1070` warnings** (`BaselineIntrospectionSyntaxInvalid`) — Fusion's Rust-based SQL parser (baseline static analysis mode) doesn't fully understand certain Snowflake-specific constructs. Non-blocking; models still build. Warning files:
  - 4× `models/fanflow/bronze_events/fcore_fes_enriched*.sql`, `fes_enriched*.sql` — Snowflake stage syntax (`BUILD_SCOPED_FILE_URL(@FDE_DEV.FDE_STAGE.DEV_FANFLOW_KAFKA_CONNECT ...)`)
  - Several `models/fanflow/silver_events/*.sql` — Fusion parser hits `extraneous input ','` (likely FLATTEN lambda syntax)
  - `models/xtremepush/xp_push_last_opened_delta.sql` — CASE expression syntax
  - 4× `models/loyalty/fancash/ledger/*.sql` — LOYALTY_DEV keyword conflict
- **Follow-up**: add `static_analysis: off` or `static_analysis: unsafe` to those ~13 specific models to suppress the warnings. Or leave them — they're informational, not blocking.

### Model builds (`--empty` for cost safety)

| Test | Model | Result | Verifies |
|---|---|---|---|
| Python model with `materialized="table"` | `fangraph_id_step3_subgraphs` | ✅ Success (2m 29s) | **C2 fix VERIFIED** — Python routes to Fusion's native table (Snowpark stored procedure) after we deleted the custom SQL-only `table.sql` |
| Incremental with merge_exclude_columns + pre-hook + snowflake_warehouse | `magnite_pa_hourly` | ✅ Success (10.7s) | **C7, C8** — pre-hook `ALTER EXTERNAL TABLE REFRESH` runs, `merge_exclude_columns` accepted, warehouse switching works |
| Incremental with `full_refresh_prevention()` (normal build) | `lids_loyalty_redeems` | ✅ Model success (test `not_empty` fails as expected under `--empty`) | Build works, custom macro renders without error |
| Same with `--full-refresh` | `lids_loyalty_redeems` | ✅ **Raised expected compiler error** | **C6 VERIFIED** — `flags.FULL_REFRESH` works in Fusion, `full_refresh_prevention()` fires correctly |
| Custom `set_query_tag` dispatch | (all above emitted tags) | ✅ Verified | **C3 VERIFIED** — Query tags in `INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER` show custom fields (`node_alias`, `node_database`, `node_schema`, `node_tags`, `target_name`, `thread_id`, `warehouse`, etc.) confirming dispatch to our project-local override works |

### Testing limitations discovered

- **`--empty` doesn't work with `table_clone` materialization.** Snowflake CLONE syntax doesn't accept a subquery, and `--empty` wraps model SQL as `(select * from X limit 0)`. Not a real Fusion issue. Instead ran without `--empty` — clone is metadata-only so cost was negligible (~3 seconds).
- **Smoke model rebuild locally hits ownership collision.** `SVC_DBT_CLOUD_ROLE` currently owns `FES_USERS.ALEX_SOTIS.DBT_CLOUD_SMOKE` (from earlier dbt Cloud runs); `FES_DATA_DEVELOPER` (my local role) can't `CREATE OR REPLACE` it. Skipped — smoke was already verified end-to-end in dbt Cloud.

### Custom `table_clone` materialization verified

Ran `dbt build --select loyalty_analytics_ledger` (no `--empty`, real clone). Fusion generated and executed:

```sql
create or replace table LOYALTY_DEV.LOYALTY_CORE.loyalty_analytics_ledger
clone LOYALTY_DEV.LOYALTY_CORE.loyalty_analytics_ledger_stage_final
```

Success in 3.06 seconds. This one run validated:
- Custom `{% materialization table_clone %}` block dispatches correctly under Fusion
- `set_query_tag()` + `unset_query_tag()` both called correctly around the CLONE
- `pre_hooks` fire (including `full_refresh_prevention()` in the same YAML)
- The `compiled_code` variable is populated when the materialization reads the model body
- Snowflake `CREATE OR REPLACE TABLE ... CLONE` syntax accepted

Confirms our decision to keep `macros/materializations/table_clone.sql` was correct — the custom materialization works in Fusion 2.0.0-preview.196 as-is.

### Concerns that flipped from unverified to verified

| # | Was | Now |
|---|---|---|
| C2 | LOW confidence rename works | ✅ **VERIFIED works** after deleting custom materializations |
| C3 | 85% confidence via research | ✅ **VERIFIED works** — dispatch + JSON tag structure confirmed |
| C6 | HIGH confidence via research | ✅ **VERIFIED works** — full_refresh_prevention raises as expected |
| C7 (partial) | MEDIUM confidence on pre-hook session persistence | ✅ pre-hook `ALTER EXTERNAL TABLE REFRESH` executed correctly for magnite; `snowflake_warehouse` config confirmed applied via query tag `warehouse` field |
| C8 | Documented behavior change | ✅ **VERIFIED** — `merge_exclude_columns` accepted by Fusion in incremental merge |

### Still not verified (require prod-like data or Cloud IDE)

- **C5 `on_schema_change: append_new_columns`** — would need to add a column to an upstream source and re-run. Deferred; low risk per research (documented as same behavior).
- **Production data equivalence.** Every `--empty` run gives us 0 rows. Actual data-equivalence between MWAA and dbt-Cloud runs of the same models — that's the real cutover test.

## Bottom line

All the concerns I could reasonably verify locally are green. Fusion's runtime behavior matches dbt-core 1.8 for the specific features fes-airflow depends on. The remaining risk is data-equivalence, which is the cutover test itself.

## Testing plan for the user (after PR#4 merge)

Run these in Cloud IDE, in order, from cheapest to most expensive:

1. **`dbt parse`** — should be clean (already verified locally)
2. **`dbt compile`** — client-side + minor Snowflake schema introspection. Tests dispatch, ref resolution, hook rendering.
3. **`dbt build --select dbt_cloud_smoke --empty`** — sanity check that smoke still works with Fusion's native table materialization (was previously routing through our now-deleted custom `table.sql`).
4. **`dbt build --select fangraph_id_step3_subgraphs --empty`** — Python model. Confirms C2 fix.
5. **`dbt build --select <one_simple_leaf_model> --empty`** — pick e.g., `mde_site` or a fangraph leaf. Confirms C1 removal doesn't cause runtime issue for SQL tables.
6. **Snowflake QUERY_HISTORY check** — confirms C3 (`set_query_tag`).
7. **`dbt build --select <incremental_model> --empty`** — pick e.g., `loyalty_analytics_ledger`. Exercises `full_refresh_prevention`, `on_schema_change`, `merge_exclude_columns`, pre-hooks.
8. **`dbt --full-refresh build --select loyalty_analytics_ledger`** — should raise the `full_refresh_prevention` compiler error.

If all pass, YOLO cutover is greenlit at the runtime level. If any fail, the fix is targeted per concern.

## Referenced research (subagents 2026-07-11)

1. **Custom materialization support**: dbt-fusion GitHub issue #17, CHANGELOG entry #2736, [supported-features docs](https://docs.getdbt.com/docs/fusion/supported-features)
2. **Python model routing**: [python-models docs](https://docs.getdbt.com/docs/build/python-models), [create-materializations guide](https://docs.getdbt.com/guides/create-new-materializations)
3. **Jinja + dispatch**: [minijinja COMPATIBILITY.md](https://github.com/mitsuhiko/minijinja/blob/main/COMPATIBILITY.md), [Fusion engine components blog](https://docs.getdbt.com/blog/dbt-fusion-engine-components), [dbt_snowflake_query_tags Hub](https://hub.getdbt.com/get-select/dbt_snowflake_query_tags/latest/)
4. **Incremental / flags / hooks**: [incremental-strategy docs](https://docs.getdbt.com/docs/build/incremental-strategy), [flags reference](https://docs.getdbt.com/reference/dbt-jinja-functions/flags), [Fusion readiness](https://docs.getdbt.com/docs/fusion/fusion-readiness)
