# Fusion Migration Reference

Living reference for every incompatibility between dbt-core 1.8 (fes-airflow's version) and dbt Fusion Stable / 1.10+ (dbt Cloud's version).

Structure: one `.md` per Fusion error code we hit, plus this index. Each error-code doc has:
- What Fusion complains about (with an example error message)
- What the original 1.8 syntax looked like
- What the Fusion-accepted syntax looks like
- Why the change happened (link to dbt docs)
- Migration approach (manual per-file, scriptable, or config-only)

## Errors encountered in the parse-check import

| Error code | Description | Count | Doc |
|---|---|---|---|
| `dbt1005` | Invalid materialization for Python model (`python_table`) | 1 | `dbt1005-invalid-materialization.md` |
| `dbt1041` | Old-format `package-lock.yml` | 1 warning | `dbt1041-package-lock-format.md` |
| `dbt1048` | `DependencyNotFound` (cascades from other errors) | 1 | (resolves when upstream errors fix) |
| `dbt1060` | `UnusedConfigKey` — several sub-classes | ~170 | `dbt1060-unused-config-keys.md` |
| `dbt1159` | `DbtYamlValidationError` — deprecated test arguments at top-level | ~200 | `dbt1159-test-arguments.md` |

## Beyond parse-clean

For runtime-behavior divergences that pass parse but might silently misbehave at build time: see [`runtime-behavior-concerns.md`](runtime-behavior-concerns.md). Covers custom materialization composition, Python model routing, query tag dispatch, `on_schema_change`, `flags.FULL_REFRESH`, pre-hooks + warehouse, and the `merge_exclude_columns` behavior change.

## Cutover validation

- **`loyalty-diff-runbook.md`** — proven byte-identical output between Fusion and dbt-core for the 4 loyalty ledger models via dbfork + HASH_AGG. Full reproduction steps + methodology gotchas.
- **`monday-terraform-pr-spec.md`** — durable grants for `SVC_DBT_CLOUD_ROLE` (warehouse USAGE + source DB SELECT). Weekend manual GRANTs documented; TF resource blocks drafted.

## Diff macros (on dbt-fes-ae `fix/fusion-parse-cleanup` branch)

Under `macros/diff_test/`:

| Macro | When to use | Notes |
|---|---|---|
| `dbfork_final_verify.sql` | **Default choice.** Fusion output vs dbforked stage source, HASH_AGG, windowed. | Immune to PK cardinality issues. Cheap. Definitive. |
| `dbfork_row_hash_diff.sql` | Debugging specific rows that differ. | Requires truly unique PK. Uses FULL OUTER JOIN. |
| `pk_uniqueness_check.sql` | Diagnose if a table's PK candidate is truly unique. | Cheap. Run BEFORE using JOIN-based diff. |

**Note:** All three macros hardcode `FES_USERS.alex_sotis.dbfork___...` paths — they're artifacts of the loyalty pilot verification, not general-purpose tooling. Parameterize (accept `schema` + `model_list` args) when generalizing into `parallel_run_verify.sql` for the cutover-playbook shadow-schema wave. Superseded/one-shot investigation macros (`dbfork_diff`, `dbfork_full_hash`, `dbfork_vs_stage_diff`, `dbfork_stage_sanity`, `investigate_diff`, `loyalty_ledger_diff`, `stage_source_check`) were removed before merging PR #4 — findings from those iterations live in `discoveries.md` D-16.

## Concept cheatsheet

Key differences between dbt-core and Fusion that shape most of these errors:

1. **Fusion is strict about YAML schema.** Unknown keys are errors, not warnings. Any custom top-level YAML keys used as anchor sources (`x-ff-*`, `_bonus_config`, etc.) must move to a Fusion-tolerated location.
2. **Deprecations are hard errors, not warnings.** Flags like `require_generic_test_arguments_property: false` no longer suppress `dbt1159`. Migration is mandatory.
3. **Some `dbt_project.yml` keys are removed entirely.** `target-path` and `packages-install-path` moved to CLI-only.
4. **Source freshness YAML has a specific expected structure** — freshness fields belong at specific nesting levels, not wherever.
5. **Custom incremental strategies** (like `merge_exclude`) had to be registered as dispatch macros. Fusion is stricter about undeclared config keys under `config:`.

## Fixing order

Small ones first (build confidence and reduce noise), scriptable ones last:

1. `dbt1005` — trivial single-file fix
2. `dbt1041` — regenerate `package-lock.yml` via `dbt deps`
3. `dbt1060` config-level (2 `config.tests` moves) — trivial
4. `dbt1060` YAML anchors (~15) — mechanical restructure
5. `dbt1060` merge_exclude (~10) — investigate custom macro, either remove key or migrate
6. `dbt1060` source freshness (~150) — YAML restructure
7. `dbt1159` test arguments (~200) — Python script with `ruamel.yaml`
8. `dbt1048` — should auto-resolve when its upstream error is fixed

## References

- [dbt Deprecations](https://docs.getdbt.com/reference/deprecations)
- [Fusion overview](https://docs.getdbt.com/docs/fusion/about-fusion)
- [Source freshness](https://docs.getdbt.com/reference/resource-properties/freshness)
- [Data tests](https://docs.getdbt.com/reference/resource-properties/data-tests)
