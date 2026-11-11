# Draft PR description — fanapp-terraform

Use this as the body of the eventual `fanapp-terraform` PR. Mirrors `pii-masking.tf` added to `root/fes-data/snowflake-v2/`.

---

## Summary

Adds Snowflake masking-policy infrastructure for the FES PII strategy. Three policies (`FES_PII_MASK_STRING`, `_NUMBER`, `_DATE`) live in a new `GOVERNANCE.MASKING` schema, plus a new `FES_PII_READER` account role used as a secondary role to unmask. Required by the fes-airflow on-run-end macro that attaches these policies to tagged columns.

This is the **only** account-level piece. The application logic — YAML tags, the `apply_pii_masking_policies` macro, the `SYSTEM$CLASSIFY` → YAML tagging script — all lives in fes-airflow.

## Why

FES data classification audit requires PII columns to be masked at the warehouse layer. The FAN Data Classification Catalog (Confluence 1575781375) names what counts as PII; this PR is the Snowflake foundation that the dbt-layer machinery binds to.

Design rationale, decision log, and rollout plan: [`brock-bot/pii_strategy/`](https://github.com/fanatics-gaming/dsea-dataops-oncall-AI/tree/main/pii_strategy).

## What this PR creates

| Object | Purpose |
|---|---|
| `GOVERNANCE` database + `MASKING` schema | Home for the policy objects. New top-level governance database. |
| `FES_PII_READER` account role | Secondary role. Holders see unmasked PII via `IS_ROLE_IN_SESSION()` in the policy body. |
| `FES_PII_MASK_STRING` policy | `STRING` PII → `'*** MASKED ***'` |
| `FES_PII_MASK_NUMBER` policy | `NUMBER` PII → `-1` |
| `FES_PII_MASK_DATE` policy | `DATE` PII → `DATE '1900-01-01'` |
| `APPLY` grant on each policy → MWAA service role | Lets the dbt on-run-end macro attach policies via `ALTER TABLE`. |
| `FES_PII_READER` granted to MWAA service user | dbt tests run unmasked so they can compare exact PII values. |

## Why these three types only

Lazy expansion. Every PII column observed in `fangraph_dev` is one of STRING, NUMBER, or DATE. The macro returns empty for unmapped types and logs a clear message — no crash. When a FLOAT or TIMESTAMP PII column surfaces, we add one entry in `locals.pii_masking_policies` and one mapping line in `get_masking_policy_for_type.sql`. Single PR.

Decision: D12 in the design docs.

## Why a secondary role + `IS_ROLE_IN_SESSION`

Avoids doubling the role hierarchy. A user can be granted `FES_PII_READER` as a secondary role (`USE SECONDARY ROLES ALL`) without changing their primary role. The masking policies check `IS_ROLE_IN_SESSION('FES_PII_READER')`, which evaluates true for primary or secondary roles.

Benchmarked against `CURRENT_ROLE()` and hash-based masking in `brock-bot/snowflake_masking_tax/` — confirmed acceptable performance.

Decision: D2 in the design docs.

## What does NOT change

- No existing roles modified
- No existing database/schema modified
- No existing masking or tagging touched (we're greenfield)
- No data is modified at any point

## Test plan

Test plan does not depend on this PR landing — the design is already validated end-to-end against prototype objects in `FES_USERS.ALEX_SOTIS` (created manually outside terraform). Once this PR is applied:

1. `terraform apply` succeeds → governance objects exist
2. In the fes-airflow PR, flip the dbt vars from prototype location to governance location (the default values in `dbt_project.yml`)
3. Re-run `dbt run-operation apply_pii_masking_policies` with the production defaults → masks reattach to fangraph_resolver_pii at the new location
4. Cleanup the FES_USERS.ALEX_SOTIS prototype objects (manual `DROP MASKING POLICY` + `DROP ROLE`)

See cleanup checklist in [`brock-bot:pii_strategy/08_prototype_tracker.md`](https://github.com/fanatics-gaming/dsea-dataops-oncall-AI/blob/main/pii_strategy/08_prototype_tracker.md).

## Open question for reviewers

- **Database home**: this PR creates a new top-level `GOVERNANCE` database. Alternative: a `MASKING` schema inside an existing platform DB (e.g. `FDE`). Preference?
- **`FES_PII_READER` grant to admin roles**: should `ACCOUNTADMIN` or `SECURITYADMIN` automatically receive the role, or stay opt-in per user? (Current: opt-in.)

## Related

- fes-airflow companion PR: <link when opened>
- Design docs: brock-bot/pii_strategy/
- Prototype was hand-built in `FES_USERS.ALEX_SOTIS` (Alex's user schema, will be cleaned up post-cutover)
