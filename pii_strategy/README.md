# PII Strategy

Snowflake masking-policy rollout for FES data. This folder is the durable state for the work — designed so any session (post-`/clear`, post-`/compact`, new engineer) can pick up by reading these docs.

**Status**: Phase 0 — planning and scaffolding
**Last updated**: 2026-06-10
**Owner**: Alex Sotis

## Where we are

- All eleven core decisions are locked (D1-D11 in [`02_decisions.md`](02_decisions.md)).
- `SYSTEM$CLASSIFY()` sample analyzed (`classify_runs/sample_fangraph.json`); parser spec + Snowflake→FES mapping locked in [`06_classify_script.md`](06_classify_script.md).
- Two override cases identified: DOB and partial-address fragments (CITY/STATE/COUNTRY/ZIP) — FAN catalog is stricter than Snowflake's classifier.
- Hashed-PII detection is a known classifier limitation, accepted as V1 scope. Lineage-based detection tracked as F7.
- **Prototype live in `FES_USERS.ALEX_SOTIS`** (2026-06-10): role `FES_PII_READER` + 3 masking policies + smoke test passed (role-switching unmasks correctly). See [`08_prototype_tracker.md`](08_prototype_tracker.md).
- **dbt macro live and validated** in `fes-airflow` (2026-06-10): one hand-tagged column (`fangraph_resolver_pii.fangraph_email`) gets the masking policy attached via `dbt run-operation apply_pii_masking_policies`. Role-switching behaves correctly in both directions. `on-run-end` not yet wired (waiting on terraform).
- **Classify-to-YAML script built** at `fes-airflow/dags/dbt/python_scripts/pii_classify/` (16 unit tests pass). 100% pure Python (no LLM). Runs via `tox -e pii-classify` (env added to `fes-airflow/tox.ini`). End-to-end run pending.
- `fanapp-terraform` not touched yet.

## How to resume after /clear or /compact

1. Read this README.
2. Read [`01_design.md`](01_design.md) for the locked design.
3. Read [`02_decisions.md`](02_decisions.md) for the decision log and any open questions.
4. Read the topic doc relevant to the work you're picking up (04 terraform, 05 dbt, 06 classify script).
5. Read the "Next steps" section below.

## Documents

| File | Purpose |
|---|---|
| [`01_design.md`](01_design.md) | Locked design: scope, goals, non-goals, architecture |
| [`02_decisions.md`](02_decisions.md) | Decision log (resolved + open). Add to this as decisions are made. |
| [`03_classification_catalog.md`](03_classification_catalog.md) | Operational digest of the FAN Data Classification Catalog (Confluence 1575781375) |
| [`04_terraform.md`](04_terraform.md) | `fanapp-terraform` changes: secondary role, masking policies, grants |
| [`05_dbt.md`](05_dbt.md) | `fes-airflow/dags/dbt` changes: YAML conventions, on-run-end macro |
| [`06_classify_script.md`](06_classify_script.md) | Spec for the `SYSTEM$CLASSIFY()` → YAML automation script |
| [`07_rollout.md`](07_rollout.md) | Phased rollout plan: pilot → expand |
| [`08_prototype_tracker.md`](08_prototype_tracker.md) | Things manually created in `FES_USERS.ALEX_SOTIS` for prototyping. **Has cleanup checklist.** |
| `classify_runs/` | Sample classify outputs from `SYSTEM$CLASSIFY()` runs |
| `examples/` | Before/after YAML, generated SQL examples |

## Related work

- **`snowflake_masking_tax/`** (this repo) — Phase 1 benchmark that picked the policy shape we're productionizing. `P_COND_ISR` (uses `IS_ROLE_IN_SESSION()`) is the variant we landed on.
- **FAN Data Classification Catalog** — [Confluence 1575781375](https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/1575781375)

## Next steps

Order optimized for fast iteration: prototype everything in Alex's user schema first (Alex is Snowflake admin), validate end-to-end, then a single terraform PR promotes the working design to its proper home.

- [x] Phase 0 design and decisions locked (D1-D11)
- [x] `SYSTEM$CLASSIFY()` output parsed and mapping table locked
- [x] **Prototype**: role + 3 policies live in `FES_USERS.ALEX_SOTIS`; smoke test passed (2026-06-10)
- [x] **dbt macro**: built `apply_pii_masking_policies` + `get_masking_policy_for_type` in `fes-airflow/dags/dbt/macros/pii/`; validated via hand-tagged column on `fangraph_resolver_pii.fangraph_email` (2026-06-10) — masking behavior confirmed in both directions
- [ ] **on-run-end wiring**: hold until terraform creates `GOVERNANCE.MASKING.*` (otherwise default-config runs would fail looking for non-existent policies)
- [x] **Script**: classify-to-YAML script built at `fes-airflow/dags/dbt/python_scripts/pii_classify/` (16 unit tests pass) — spec in [`06_classify_script.md`](06_classify_script.md)
- [ ] **Run script** against `fangraph_resolver_pii` to validate end-to-end
- [ ] **Terraform PR**: promote role + policies to governance schema — spec in [`04_terraform.md`](04_terraform.md)
- [ ] **Cutover**: re-run macro (FORCE re-attaches with governance location), drop prototype objects (checkboxes in [`08_prototype_tracker.md`](08_prototype_tracker.md))

## V1 known limitations (accepted, not blocking)

These are documented gaps that V1 intentionally does not solve. Engineer review catches them during rollout.

- **Hashed PII is not auto-detected** (D10). `SYSTEM$CLASSIFY()` can't see PII through MD5/SHA hashes. Columns like `MD5(email)` need to be tagged manually until F7 (lineage propagation) ships.
- **Column-name signals are not used**. We trust value-based classification only. Tables where columns are named obviously (e.g. `customer_email_hash`) but values defeat the classifier won't be auto-tagged.
- **No tier-specific roles** (D2). Phase 1 is one role (`FES_PII_READER`) unlocks everything. F1 tracks the migration to tiered roles.

## What this is not

- Not a deletion strategy (GDPR right-to-be-forgotten is out of scope here)
- Not a logging-redaction strategy (the Security Event Logging Standard governs that — see Confluence 1575782116)
- Not a tokenization or encryption-at-rest strategy
