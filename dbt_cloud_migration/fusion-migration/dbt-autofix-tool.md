# dbt-autofix — the tool that did most of the work

## What it is

Official dbt Labs CLI (`pip install dbt-autofix`) that "automatically scans your dbt project for deprecated configurations and updates them to align with the latest best practices." Fusion CLI's error output literally recommends it in the header line:

```
suggestion: Run 'dbt deps' to see the latest fusion compatible packages.
For compatibility errors, try the autofix script: https://github.com/dbt-labs/dbt-autofix
```

## What it fixed in our migration

Out of ~200 unique parse errors:
- ~150 source freshness YAML restructuring (`loaded_at_field` / `freshness` moved under `config:`)
- ~15 YAML anchor key removals (`x-*` and `_*` top-level keys)
- ~200 test argument format migrations (moved args under `arguments:`)
- 2 `config.tests` moves
- Flipped 2 behavior flags in `dbt_project.yml` to their new defaults

## What it doesn't fix

- `merge_exclude` typo (business decision on migrate vs remove)
- `python_table` → `table` materialization for Python models
- Duplicate resource definitions between `analysis/` and `models/`
- Broken `{{ ref() }}` calls to removed / renamed models

## Install + run

```bash
python3.11 -m venv .venv-scripts
.venv-scripts/bin/pip install dbt-autofix

# Preview first
.venv-scripts/bin/dbt-autofix deprecations --dry-run

# Apply all (including behavior changes)
.venv-scripts/bin/dbt-autofix deprecations --all
```

Requires Python 3.11 or 3.12 — its dependency `mashumaro` doesn't yet support Python 3.14 (as of 2026-07).

## Available subcommands

- `deprecations` — the one we used
- `packages` — package hygiene (probably useful for the `dbt1041` lockfile format issue)
- `jobs` — dbt Cloud job cleanup
- `list-yaml-duplicates` — could have surfaced `dbt1005` sub-case B upfront

## Lesson

**When starting a Fusion migration, run `dbt-autofix deprecations --dry-run` first.** It surfaces the mechanical migrations in one pass and shows you the file-level diff. Then apply, then hand-fix the remaining specific errors. This is much faster than trying to write custom YAML transformation scripts.
