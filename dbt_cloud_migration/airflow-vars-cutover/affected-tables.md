# Affected Tables — Code Change + Manual-Action Tracker

Two workstreams per table:
- **Code fix**: swap the broken var reference for the self-healing window pattern.
- **Manual action**: investigate whether a backfill / gap-fill / watermark reset is
  needed to recover from the silent-0-row period. Immediate mitigation in a parallel
  session is doing catch-up ingestion manually — verify this covers each table below,
  or scope any remaining gap.

Legend:
- `[ ]` not started · `[~]` in progress · `[x]` done · `n/a` not applicable

---

## Directly affected — running the broken window logic

### 1. `fes_enriched` (dbt-fes-ae, fanflow raw bronze)

- Model path: `models/fanflow/bronze_events/fes_enriched.sql`
- Ingests from: `@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT`, topic prefix `fes_enriched/`
- Warehouse: FDE_DEVELOPER_3XL_WH (per memory: fanflow tables need 3XL)
- **Code fix**: `[ ]` — landed via `fanflow_unparsed_files` rewrite in PR 1 (no per-model
  edit needed).
- **Manual action**: `[ ]` — after PR 1 lands, first incremental run will self-heal from
  `MAX(_file_modified_ts)` in target. Investigate:
  - Is the current `MAX(_file_modified_ts)` recent enough (post the manual mitigation) to
    span the gap without a `--full-refresh`?
  - If mitigation session dropped/refilled the table, watermark should be fresh. If it
    only patched forward-arriving files, we may need to widen the first-run window via
    `--vars '{window_start_ts: "<gap-start>"}'`.
  - **Owner**: needs alignment with the parallel mitigation session.

### 2. `fes_enriched_fanapp` (dbt-fes-ae, fanflow raw bronze)

- Model path: `models/fanflow/bronze_events/fes_enriched_fanapp.sql`
- Topic prefix: `fes_enriched_fanapp/`
- **Code fix**: `[ ]` — via macro rewrite.
- **Manual action**: `[ ]` — same investigation as above.

### 3. `fcore_fes_enriched` (dbt-fes-ae, fanflow raw bronze)

- Model path: `models/fanflow/bronze_events/fcore_fes_enriched.sql`
- Topic prefix: `fcore_fes_enriched/`
- **Code fix**: `[ ]` — via macro rewrite.
- **Manual action**: `[ ]` — same investigation as above.

### 4. `fcore_fes_enriched_fanapp` (dbt-fes-ae, fanflow raw bronze)

- Model path: `models/fanflow/bronze_events/fcore_fes_enriched_fanapp.sql`
- Topic prefix: `fcore_fes_enriched_fanapp/`
- **Code fix**: `[ ]` — via macro rewrite.
- **Manual action**: `[ ]` — same investigation as above.

### 5. `fes_fanflow_enriched` (dbt-fes-ae, fanflow raw bronze)

- Model path: `models/fanflow/bronze_events/fes_fanflow_enriched.sql`
- Topic prefix: `fes_fanflow_enriched/`
- **Code fix**: `[ ]` — via macro rewrite.
- **Manual action**: `[ ]` — same investigation as above.

### 6. `mention_me__referrals` (dbt-fes-ae, fes_integrations)

- Model path: `models/fes_integrations/mentionme/referrals.sql`
- Ingests from: `source('fes_integrations__mention_me', 'referrals_ext')`
- **Code fix**: `[ ]` — direct model edit in PR 1 (`source_file_name` high-water pattern).
- **Manual action**: `[ ]` — after fix lands, first incremental run picks up from
  `MAX(source_file_name)`. Investigate:
  - What's the current `MAX(source_file_name)` in target? If `<= CRMFeedV2_20250925.csv`,
    the fix alone will catch up. If someone manually inserted rows during mitigation and
    advanced the watermark past the true gap, we need a targeted backfill.
  - Ext table + underlying S3 bucket — verify the files exist for every day in the gap
    (if a source stopped producing, no code fix can recover it).

### 7. `bets_total_stake_validity_check` (dbt-governance, DQ)

- Model path: `models/dq_controls/staging/bets_total_stake_validity_check.sql`
- What it does: daily DQ count of bets with `total_stake > 0` for `dw_creation_date =
  yesterday`.
- **Code fix**: `[ ]` — direct model edit in PR 2 (swap `var("data_interval_end")` for
  `run_started_at` expression).
- **Manual action**: `[ ]` — investigate:
  - This is a **snapshot per day** table. Was any day missed while the placeholder
    default was in effect?
  - Because dbt-governance's placeholder was raw string `CURRENT_TIMESTAMP` (evaluated at
    query time), yesterday's snapshot may actually have been landing correctly under dbt
    Cloud. Worth confirming with `SELECT DISTINCT snapshot_date FROM
    dbt_governance.dq_controls.bets_total_stake_validity_check ORDER BY snapshot_date`.
  - If gaps exist, backfill by running the model with `--vars '{window_end_ts: "<date+1>"}'`
    per missing day (or add a small backfill loop in the mitigation session).

---

## Frozen downstream — ~47 event bronze models under `models/fanflow/bronze_events/`

These `ref()` the 5 raw bronzes above via `fanflow_bronze_with_backfill`. They don't
touch the broken macro — they'll self-recover as soon as the raw bronzes catch up. No
per-model code fix needed.

**Manual action**: `[ ]` — after raw bronzes catch up:
- Trigger a dbt run for the event bronzes (they're incremental — the run will pick up
  the newly-landed raw rows).
- Spot-check a sample of downstream event bronzes for expected row counts vs the pre-
  freeze baseline.

Full list (from `gh api repos/fanatics-gaming/dbt-fes-ae/contents/models/fanflow/bronze_events`):

```
carrier_notified__item__bronze          out_for_delivery__item__bronze
complete_kyc__account__bronze           password_reset_error__account__bronze
completed_tenant__dsr__bronze           password_reset_requested__account__bronze
created__account__bronze                password_reset_successful__account__bronze
created__order__bronze                  password_score__account__bronze
deliver__item__bronze                   phone_change_confirm__account__bronze
email_change_confirm__account__bronze   phone_change_notify__account__bronze
email_change_revert__account__bronze    place__bet__bronze
favorited__fanapp_favorite__bronze      place__order__bronze
fraudstatus_reject__order__bronze       place_order_success__new_product_launch__bronze
linked_loyalty_to_site__account__bronze qualify__experiment__bronze
locked__account__bronze                 register__account__bronze
lookup__account__bronze                 register_error__account__bronze
loyalty_transaction_successful__account__bronze  register_submit__account__bronze
one_time_code_email__account__bronze    remind_abandon__cart__bronze
one_time_code_sms__account__bronze      response__risk_api__bronze
returned_to_sender__item__bronze        reveal__game__bronze
select__button__bronze                  select__link__bronze
session_factor_verify__account__bronze  session_factor_verify_error__account__bronze
shipment_delayed__item__bronze          shipment_exception__item__bronze
shipment_lost__item__bronze             shipment_scanned__item__bronze
shipment_undelivered__item__bronze      signin__account__bronze
signin_error__account__bronze           signin_factor_completed__account__bronze
signin_factor_start__account__bronze    signin_factor_verify_error__account__bronze
signin_name__account__bronze            signin_start__account__bronze
signout__account__bronze                start_kyc__account__bronze
submission_result__new_product_launch__bronze  submit__game__bronze
submit_entry__new_product_launch__bronze tasks_created__dsr__bronze
tenant_acquired__account__bronze        updated__account__bronze
updated_error__account__bronze          verified__account__bronze
view__module__bronze                    view__page__bronze
```

(Count: 47. Confirmed by `gh search code fanflow_bronze_with_backfill --repo dbt-fes-ae`.)

---

## Frozen further downstream

Silver / gold / marts that consume the event bronzes will also naturally recover once
the bronzes catch up. Not tracking individually here — if any specific downstream is
called out by a stakeholder as still stale after PR 1 lands, add it to this file.

---

## Dead-code cleanup (no runtime impact — no manual action needed)

### dbt-fes-analytics duplicate macros

- `macros/fanflow/fanflow_unparsed_files.sql`
- `macros/fanflow/fanflow_ingest_topic.sql`

Delete in PR 3. No models call them here.
