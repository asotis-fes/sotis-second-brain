# dbt1005 — Invalid materialization / duplicate resource definitions

## What the error looks like

```
[error] [InvalidConfig (dbt1005)]: Invalid materialization 'python_table' for Python model.
  Only 'table' or 'incremental' are allowed.
  --> models/fangraph/fangraph_id/fangraph_id_step3_subgraphs.py

[error] [InvalidConfig (dbt1005)]: Found duplicate resource definitions for model named 'fanapp_recs__stg_team_id_mapping'
  in ['analysis/fanapp_recommendation_poc/fanapp_recommendation.yml', 'models/fanapp_recommendation/fanapp_recommendation.yml']
```

## Two sub-cases we hit

### Sub-case A: Invalid materialization for Python model

**1.8 behavior:** Any string could be passed as `materialized=` in a Python model's `dbt.config()`. dbt-snowflake would silently fall back to `table` if the string wasn't recognized. `materialized="python_table"` therefore worked accidentally.

**Fusion behavior:** Fusion enforces a strict allowlist for Python models — only `table` or `incremental`.

**Fix:** In `models/fangraph/fangraph_id/fangraph_id_step3_subgraphs.py`, change:

```python
dbt.config(
    materialized="python_table",   # ← Fusion rejects
    ...
)
```

to:

```python
dbt.config(
    materialized="table",          # ← Fusion accepts, same runtime behavior
    ...
)
```

**Business impact:** None — 1.8 was already treating `python_table` as `table` (silent fallback).

---

### Sub-case B: Duplicate resource definitions across analysis/ and models/

**1.8 behavior:** dbt-core would treat YAML `models:` declarations in the `analysis/` folder as duplicate model definitions of the same name in `models/`. Usually silently ignored or resolved in favor of one.

**Fusion behavior:** Hard error — a model name can be declared in exactly one YAML file.

**Fix:** Delete YAML files in `analysis/` that redeclare production models. In our case, `analysis/fanapp_recommendation_poc/fanapp_recommendation.yml` re-declared 8 models that lived in `models/fanapp_recommendation/fanapp_recommendation.yml`. The POC folder was stale (referenced a model that had been removed from `models/`). We deleted the entire `analysis/fanapp_recommendation_poc/` folder.

**Rule of thumb:** `analysis/` files should be `.sql` only, no YAML `models:` declarations. Analyses are compiled-but-not-materialized ad-hoc queries; they don't need schema declarations.

## Migration approach

Both fixes are one-line/one-file changes. No script needed.

## References

- [dbt Python models](https://docs.getdbt.com/docs/build/python-models)
- [Analysis path](https://docs.getdbt.com/reference/project-configs/analysis-paths)
