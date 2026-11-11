# Rollout Plan

Phased rollout from this folder's planning docs to all FES models running with masking policies in production.

## Phase 0 — Planning (in progress)

**Where**: this folder (`pii_strategy/` in brock-bot repo).
**Output**: design docs in this folder, decisions logged in `02_decisions.md`.

- [x] Fetch FAN Data Classification Catalog
- [x] Lock seven core decisions (D1-D7)
- [x] Draft design (this folder)
- [ ] Receive sample `SYSTEM$CLASSIFY()` output → drop into `classify_runs/`
- [ ] Validate Snowflake classify output structure → finalize parser in [`06_classify_script.md`](06_classify_script.md)

**Exit criteria**: All seven docs in this folder are reviewed and accepted by Alex.

## Phase 1 — Foundation (terraform + dbt skeleton)

**Where**: `fanapp-terraform` and `fes-airflow`.

### Phase 1a — Terraform

- [ ] PR to `fanapp-terraform`:
  - `FES_PII_READER` account role
  - `GOVERNANCE.MASKING.FES_PII_MASK_STRING`, `_NUMBER`, `_DATE` (Phase 1 minimum)
  - Grants per [`04_terraform.md`](04_terraform.md)
- [ ] Apply terraform plan → verify objects exist in Snowflake
- [ ] Manual smoke test: attach `FES_PII_MASK_STRING` to a scratch table, verify role-based behavior

**Exit**: All three masking policies exist; `FES_PII_READER` exists; MWAA service user has the role; smoke test confirms `IS_ROLE_IN_SESSION()` works as expected.

### Phase 1b — dbt macro skeleton

- [ ] PR to `fes-airflow`:
  - `macros/apply_pii_masking_policies.sql`
  - `macros/pii_helpers.sql` (the `get_masking_policy_for_type` macro)
  - `dbt_project.yml` on-run-end entry
- [ ] Tag ONE column in ONE `fangraph_dev` model
- [ ] Run dbt against `fangraph_dev` → verify ALTER fires, policy is attached
- [ ] Run dbt twice → verify idempotency (FORCE handles re-apply)
- [ ] Test as a non-PII-reader role → verify masked value returns

**Exit**: end-to-end works for one column in one model on `fangraph_dev`.

## Phase 2 — Pilot expansion (fangraph_dev only)

- [ ] Run `SYSTEM$CLASSIFY()` against all `fangraph_dev` model tables
- [ ] Use the classify-to-YAML script (per [`06_classify_script.md`](06_classify_script.md)) to bulk-tag
- [ ] Engineer review of generated tags (this is the human-in-the-loop quality gate)
- [ ] Run dbt against `fangraph_dev` → verify all tagged columns get policies
- [ ] Verify dbt tests still pass (MWAA has the role per D6)
- [ ] Run sample analyst queries with and without the secondary role → verify masking behavior

**Exit**: `fangraph_dev` is fully tagged and masked. Stable for at least one week with no incidents.

## Phase 3 — Production fangraph

- [ ] Copy YAML tags from `fangraph_dev` schema yamls → `fangraph` (these are the same files in dbt; the dev/prod split is just target databases)
- [ ] Verify Phase 1a terraform objects exist in prod Snowflake (they should — terraform applies account-wide)
- [ ] First prod dbt run with masking → monitor
- [ ] Notify analyst community: PII columns now masked; how to request `FES_PII_READER`

**Exit**: Production fangraph fully masked. Analyst access workflow documented.

## Phase 4 — Expand to other dbt model directories

Priority order (highest PII concentration first; revisit with classify runs):

1. `loyalty/` — FanCash, customer balances, transaction history
2. `fanapp/` — customer-facing app data
3. `identity/` — identity resolution (likely high PII)
4. `fanflow/` — events tied to customers
5. `enterprise_metrics/`, `experiment/`, `amplitude/`, `appsflyer/`, … — lower PII concentration but worth scanning

For each:
- Run classify
- Bulk-tag via script
- Engineer review
- dbt run → verify
- One week stability watch before moving to next

## Phase 5 — Cleanup and follow-ups

- [ ] F1 — Evaluate tiered roles need
- [ ] F2 — Incremental skip optimization
- [ ] F3 — View masking review
- [ ] F4 — Cross-tenant PII audit
- [ ] F5 — Snapshot masking confirmation
- [ ] F6 — Test log hardening (if needed)

(F1-F6 defined in [`02_decisions.md`](02_decisions.md).)

## Rollback plan

If masking causes production issues at any phase:

```sql
-- Per-column unset
ALTER TABLE <db>.<schema>.<table> MODIFY COLUMN <col> UNSET MASKING POLICY;

-- Per-table unset (all columns)
-- Loop over INFORMATION_SCHEMA.POLICY_REFERENCES results.
```

To stop the on-run-end macro from re-applying:
- Remove the `on-run-end` line from `dbt_project.yml` (single-line revert PR)
- Or comment out the `meta.classification` entries in the affected schema.yml

Recovery is fast. Snowflake masking policies don't move data — they're metadata-only attachments. Removing them is a constant-time operation per column.

## Communication plan

| Phase | Audience | Channel | Message |
|---|---|---|---|
| 1 | data-platform | #fes-data-eng | "Masking policies created in Snowflake; no behavior change yet" |
| 2 | data-platform | #fes-data-eng | "Fangraph dev pilot underway; let me know if you query fangraph_dev" |
| 3 | All analysts | #fes-data-analytics-support | "Fangraph prod now masks PII. To request access: [link]" |
| 4 | All analysts | #fes-data-analytics-support | per dbt model directory as rolled out |

(Refine these messages before sending — this is just a placeholder structure.)
