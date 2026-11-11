# OneCredits Migration Pattern — Reusable Reference

The OneCredits migration established a repeatable pattern. Tier Points reuses it.

## Files in `../loyalty_ingest_migration/` worth reading

- `README.md` — overall shape
- `decisions/01_naming.md` — same-schema, same-S3-path, test_ prefix in dev only
- `decisions/02_legacy_deprecation.md` — mostly n/a for Tier Points (no legacy tier ingest to phase out)
- `decisions/03_one_credits_dag_move.md` — DAG scheduling/tags
- `decisions/04_deferred_prod_activation.md` — the two-toggle cutover mechanism
- `context/schema_doc_findings.md` — schema doc findings F1-F9 (F8 = program_id enum: 1=FANCASH, 2=TIERPOINTS, 3=CREDITS)
- `context/ext_table_ddl_pattern.md` — ext-table DDL structure + where they live
- `plans/0_cutover_pr.md` — end-to-end cutover PR spec

## Elements to reuse

1. **Toggle mechanism**: OneCredits uses `OC_INGEST_LIVE` (Python) + `oc_ingest_live` (dbt var). For Tier Points: mirror as `TP_INGEST_LIVE` + `tp_ingest_live`, or extend existing OC toggle to cover tier points too. **Design decision needed.**

2. **Jinja-conditional in downstream models**: `{% if var('oc_ingest_live', false) or target.name == 'dev' %} NEW-SCHEMA SQL {% else %} OLD-SCHEMA SQL {% endif %}`. Preserves prod pre-cutover behavior. For Tier Points, only relevant if there's an OLD-schema tier ledger to preserve (there isn't — Tier Points has never been in Postgres, so no OLD branch needed; NEW branch runs directly gated by the toggle).

3. **Ext-table DDL location**: `dags/create_tables/sql/loyalty/create_<table>_ext.sql`. Manually triggered `create_tables` DAG. Template uses `{{ params.target_db }}` and `{{ params.stage }}` — no oc_prefix anymore (removed after OneCredits dev un-prefix).

4. **Staging model template**:
   ```sql
   SELECT
       <columns>,
       {{ add_incremental_timestamps() }}
   FROM {{ source('loyalty__source', '<table>_ext') }}
   {% if is_incremental() %}
       WHERE <incremental_col> >= (SELECT MAX(<incremental_col>) FROM {{ this }})
   {% endif %}
   QUALIFY ROW_NUMBER() OVER (
       PARTITION BY <pk>
       ORDER BY upload_ts DESC
   ) = 1
   ```

5. **Test conventions**: `not_empty` only on tables expected to always have data. For Tier Points, several tables may legitimately be empty at cutover (e.g., `tier_account_override` if no manual overrides yet; `tier_invite_approval` if no invite-only tiers yet). Omit `not_empty` on those.

6. **Row count tolerance**: 5% on `updated_at`-incremental tables. Race condition documented in previous session — updates in flight can drop rows from PG count while SF still has them.

7. **Backfill flow**: Trigger DAG with `{"loyalty_postgres_backfill": true}`. `get_backfill_flag` @task reads from `dag_run.conf`.

8. **Cutover-day playbook** (from `../loyalty_ingest_migration/plans/0_cutover_pr.md`):
   - Merge feature branch to main (deploys dormant)
   - Loyalty team applies PG migration
   - Merge 2-line flip PR
   - Manual `create_tables` trigger for new ext tables
   - Backfill DAG run
   - Full-refresh dbt on relevant tag
   - Verify with `compare_row_counts` and spot-check queries

## Differences for Tier Points

- **No legacy PG path to phase out.** Tier Points was on Loyalty Cloud only. No `journal`/`entry` equivalent for Tier Points. Decision 02 in the OneCredits work is largely n/a here.
- **No OLD-branch SQL to preserve.** Tier Points ledger doesn't exist in `models/loyalty/fanatics_one/` in the un-cutover form (or does it? verify). Downstream tier models likely don't need Jinja conditional — they can just target new schema from day one.
- **Data continuity**: prod Tier Points table will start ~empty at cutover unless loyalty team backfills from Loyalty Cloud. Verify strategy.
- **Shared tables save work**: `transaction` and `account_balance` are already ingested. No new ingest wiring for those. But confirm `account_balance` includes the tier-specific `lifetime` column (schema doc).

## Post-cutover fixes that came up in OneCredits (to be aware of)

- `allocation` `not_empty` test removed post-cutover (legitimately empty until user activity picks up).
- 5% tolerance added to `bucket`, `account_balance`, `allocation_remaining`, `void_remaining` (updated_at race).
- Race issue with `compare_row_counts` for `updated_at`-incremental tables — Option C (2-min buffer on cutoff) was discussed but not implemented; may revisit in dbt Cloud migration.
