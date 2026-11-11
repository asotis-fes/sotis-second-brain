# dbt1048 — DependencyNotFound

Fusion rejects `{{ ref() }}` calls to models that don't exist. dbt-core sometimes surfaced this too, but Fusion consistently treats it as a hard blocker in parse.

## What the error looks like

```
[error] [DependencyNotFound (dbt1048)]: Ref 'X' not found in project.
  Searched for 'fes_data.X, X'
```

## In our migration, this manifested as cascading errors

Three references failed in the imported tree:

### 1. `fangraph_id_step3_subgraphs`
**Cause:** The Python model existed but couldn't register as a resource because its materialization was invalid (`python_table`, see `dbt1005-invalid-materialization.md`). Downstream `fangraph_id_step4_subgraphs_exploded.sql` refs it → cascading failure.

**Fix:** Fix the upstream `python_table` → `table` materialization change; this ref auto-resolves.

### 2. `fanapp_recs__int_fan_live_signals`
**Cause:** POC folder `analysis/fanapp_recommendation_poc/` contained a stale `fanapp_recs__fct_fan_team_signals.sql` that ref-ed a model that had been intentionally removed from production (`# DISABLED: source table removed from codebase` comment in the production YAML).

**Fix:** Deleted the POC folder — the stale SQL was dead code. See `dbt1005-invalid-materialization.md` Sub-case B for the broader story on why the POC folder was problematic (duplicate resource declarations).

### 3. `loyalty_transaction_successful_account`
**Cause:** Typo in `analysis/fes_data_team/loyalty_transaction_pre_seeding_v.sql` — ref-ed single-underscore name (`_successful_account`) but the actual model is double-underscore (`_successful__account`).

**Fix:** One-character fix: `s/loyalty_transaction_successful_account/loyalty_transaction_successful__account/`.

## Migration approach

Manual. Cascades usually resolve automatically once the root cause is fixed. Grep for the missing name across `models/`, `analysis/`, `macros/` to find refs.

## Lesson

Fusion catches broken refs that dbt-core would have caught eventually at compile time — Fusion just surfaces them earlier and enforces them at parse. Broken refs in `analysis/` (which don't get run) had been going unnoticed.
