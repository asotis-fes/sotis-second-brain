# Fangraph diff runbook

Byte-identical validation of Fusion vs dbt-core for the fangraph model tree, following the loyalty-diff pattern. Structurally more complex than loyalty because fangraph reads from 28 sources (loyalty read from `_stage_final` refs only).

## Selector

**Correct**: `tag:fangraph,+path:models/fangraph/fangraph/fangraph.sql`

Bare `+fangraph` matches the folder `models/fangraph/` (512 nodes) — too broad. Path-based selector pins to the `fangraph.sql` leaf. Intersection with `tag:fangraph` yields **103 models** (the leaf + 102 tagged upstream ancestors).

## Setup performed

### 1. Manifest for defer

`.defer-state/manifest.json` is target=prod compiled. Under `--target test --defer`, non-selected upstream `ref()`s resolve to prod locations.

### 2. Source YAML rewrite

The 10 source declarations feeding the fangraph tree (28 tables across 9 YAML files) have been rewritten to point at dbfork clones:

- `database: FES_USERS`
- `schema: alex_sotis`
- per-table `identifier: dbfork___prod__<db>__<schema>__<name>`

Backups saved as `<file>.bak`. To restore: `git restore models/sources/` or `rm models/sources/*.bak && git checkout models/sources/`.

Affected YAMLs:
```
models/sources/aaia.yml
models/sources/collectibles_fde.yml
models/sources/commerce.yml
models/sources/commerce_cde.yml
models/sources/commerce_mde.yml
models/sources/fangraph.yml
models/sources/fbg_fde.yml
models/sources/fes_integrations.yml
models/sources/live_fde.yml
```

Non-fangraph-tree tables within these YAMLs (e.g. `aaia__sig.ctv`, `commerce__source.*`) are **unchanged** — untouched by rewrite.

### 3. Source clones

All 28 source tables cloned to `FES_USERS.alex_sotis.dbfork___prod__<db>__<schema>__<table>`.

**Time Travel constraint discovered**: 15 sources are secure views (aaia.sig.*, commerce_cde.cde_cust_info.fan_addresses_v, most fbg_fde.*, live_fde.data_views_fanatics.*). Snowflake blocks Time Travel on their underlying tables. Cannot freeze these at T_mwaa.

**Resolution**: clone at CURRENT time (no `AT (TIMESTAMP)` clause). 10 tables → CLONE (metadata-only). 18 views → CTAS (materialize). All 28 landed successfully.

Macros: `macros/dbfork/dbfork_sources.sql` (dbt run-operation). Raw SQL: `/tmp/dbfork_clones_current.sql`.

## Comparison baseline

**Constraint discovered**: dbt-core 1.8.7 CANNOT parse the current `fix/fusion-parse-cleanup` branch — Fusion-specific test syntax (`arguments:` keyword) was applied to seed tests, which dbt-core 1.8 rejects with `dbt_macro__test_accepted_values takes no keyword argument 'arguments'`. So we cannot run a local dbt-core baseline against the clones — only Fusion runs locally.

Therefore the baseline is MWAA's production `fangraph.admin.fangraph` table.

**Actual timestamps**:
- **T_mwaa**: 2026-07-13 13:38:58 UTC — MWAA's last fangraph completion
- **T_clone_start**: 2026-07-13 16:03:59 UTC — source clones started (~2.5h after T_mwaa)
- **T_clone_end**: 2026-07-13 16:23:15 UTC — source clones done

Fusion builds from clones at ~T_clone. MWAA built prod fangraph from live sources at ~T_mwaa. The 2.5-hour source drift is a KNOWN CONFOUNDER — any diff in Fusion output vs MWAA output = (Fusion behavior) + (2.5h of source drift).

**To reduce drift** (recommended before Fusion build):

1. **Trigger MWAA fangraph on-demand** via Airflow prod UI. Wait for completion, note new T_mwaa'.
2. **Immediately re-clone the 28 sources** via `/tmp/dbfork_clones_current.sql` — new T_clone' will be within minutes of T_mwaa'.
3. **Then** run Fusion build. Drift shrinks from 2.5h → minutes.

If MWAA re-trigger is not feasible, proceed with existing clones and accept 2.5h drift in interpretation.

## Build command for the engineer to run

```bash
cd ~/repos/dbt-fes-ae

# Verify Fusion sees dbfork paths
DBT_TEST_SCHEMA=alex_sotis DBT_FEATURE_BRANCH=fusion_diff \
  ~/.local/bin/dbt compile --select "fangraph_resolver_address" --target dev 2>&1 | tail -5
grep FES_USERS target/compiled/fes_data/models/fangraph/fangraph/fangraph_resolver_address.sql

# Full build (this is the ~1hr step)
DBT_TEST_SCHEMA=alex_sotis DBT_FEATURE_BRANCH=fusion_diff \
  ~/.local/bin/dbt build \
  --select "tag:fangraph,+path:models/fangraph/fangraph/fangraph.sql" \
  --target test --defer --state .defer-state
```

Expected: writes to `FES_USERS.alex_sotis.dbfork___fusion_diff__fangraph__admin__<model>` for each of 102 tagged models (the leaf `fangraph` writes to `dbfork___fusion_diff__fangraph__admin__fangraph`).

## Diff macro to run after build completes

```bash
~/.local/bin/dbt run-operation dbfork_final_verify --target test \
  --args '{window_days: 1, warehouse: "FDE_DEVELOPER_2XL_WH", models: ["fangraph"]}'
```

Compares HASH_AGG of `FES_USERS.alex_sotis.dbfork___fusion_diff__fangraph__admin__fangraph` (Fusion) vs `fangraph.admin.fangraph` (MWAA baseline, at whichever timestamp we align to).

## Cleanup

```bash
cd ~/repos/dbt-fes-ae
git restore models/sources/     # revert YAML rewrite
rm -f models/sources/*.bak      # (optional) remove backup files
# The dbfork_source_clones tables in FES_USERS.alex_sotis can stay or be dropped
```
