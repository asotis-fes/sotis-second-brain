# Tier Points Cutover — Playbook

**Status:** Draft — deploy-then-flip
**Feature branch:** `tp/schema_discovery` (single PR bundles ingest wiring + discovery DAG)
**Cutover-flip PR:** created later, at prod cutover time — one-line flips only

Follows the same shape as `../loyalty_ingest_migration/plans/0_cutover_pr.md` (OneCredits pattern).

## Deploy PR contents

### Data-eng (this PR)

1. **`dags/loyalty/configs.py`**
   - Added `TP_INGEST_LIVE = get_value_for_env(dev=True, prod=False)`.
   - Added `TP_TABLE_PREFIX = get_value_for_env(dev="test_", prod="")`.
   - Added `TP_POSTGRES_TABLE_CONFIGS` with 5 entries: `tier`, `tier_override_configuration`, `tier_account_override` (5% tolerance, extra_data jsonb→TEXT cast), `tier_account_override_trial` (5% tolerance), `tier_invite_approval`.

2. **`dags/loyalty/loyalty_postgres_to_s3_ingest.py`**
   - Imports the new symbols.
   - New TP loop after the OC loop: builds one `load_<table>` task per TP config. PG source name gets the prefix (`test_tier` in dev, `tier` in prod). S3 path is always un-prefixed so ext tables don't change between envs.
   - `compare_row_counts` extended to iterate TP configs when `TP_INGEST_LIVE`, applying the prefix to the PG-side count query while keeping the SF-side query un-prefixed.

3. **`dags/create_tables/sql/loyalty/`** — 5 new ext DDLs:
   - `create_tier_ext.sql`
   - `create_tier_override_configuration_ext.sql`
   - `create_tier_account_override_ext.sql` (includes `extra_data` VARIANT + undocumented `rollover_tierpoints`)
   - `create_tier_account_override_trial_ext.sql`
   - `create_tier_invite_approval_ext.sql`

4. **`dags/create_tables/sql/loyalty/create_account_balance_ext.sql`** — added `lifetime NUMBER(18, 6)` projection.

5. **`dags/dbt/models/loyalty/source/`** — 5 new staging models + `account_balance.sql` amended:
   - `tier.sql`, `tier_override_configuration.sql`, `tier_account_override.sql`, `tier_account_override_trial.sql`, `tier_invite_approval.sql`
   - `account_balance.sql` — added `lifetime` to SELECT list

6. **`dags/dbt/models/loyalty/source/source.yaml`** — 5 new model configs, each gated by `enabled: "{{ target.name == 'dev' or var('tp_ingest_live', false) }}"`.

7. **`dags/dbt/models/sources/loyalty.yml`** — 5 new source table entries under `loyalty__source`.

8. **`dags/dbt/dbt_project.yml`** — added `tp_ingest_live: false` var.

## Dev-validation period

Two independent toggles. Dev is fully active from PR deploy day; prod is dormant until cutover.

| env | `TP_INGEST_LIVE` | `TP_TABLE_PREFIX` | new ingest | staging models |
|-----|------------------|-------------------|------------|----------------|
| **dev (PR deploy)** | True | `test_` | YES (test_-prefixed source) | enabled |
| dev (after loyalty un-prefixes dev PG) | True | `""` | YES (un-prefixed source) | enabled |
| **prod (PR deploy)** | False | `""` (unused) | NO (dormant) | disabled |
| prod (cutover) | True | `""` | YES | enabled |

Cutover-day flip: `TP_INGEST_LIVE` prod False → True + dbt var `tp_ingest_live: false → true`. Two lines.

## Post-deploy steps in dev

Once PR merges and dev deploy syncs:

1. Manually trigger `create_tables` DAG to create the 5 new ext tables + refresh `account_balance_ext` (now with `lifetime`).
2. Manually trigger `loyalty_postgres_to_s3_ingest` **with `{"loyalty_postgres_backfill": true}`** so the initial run picks up all existing test_-prefixed tier rows regardless of when they were created.
3. Confirm the 5 new tables materialize in `LOYALTY_DEV.SOURCE.tier`, `tier_override_configuration`, `tier_account_override`, `tier_account_override_trial`, `tier_invite_approval`.
4. Confirm `LOYALTY_DEV.SOURCE.account_balance.lifetime` populates (existing rows will show `0` for non-TP programs; TP rows carry the actual cumulative).
5. Verify `compare_row_counts` passes for all TP tables on the next scheduled run.

## Cutover-day procedure (prod)

Assumes loyalty team has applied the tier migration in prod PG and un-prefixed the tier tables in dev PG (or not — dev un-prefix is independent).

1. **Loyalty team**: apply tier migration in prod PG. Un-prefixed tier tables exist in prod.
2. **Us**: open cutover PR with two-line change:
   - `dags/loyalty/configs.py`: `TP_INGEST_LIVE = get_value_for_env(dev=True, prod=True)`
   - `dags/dbt/dbt_project.yml`: `tp_ingest_live: true`
3. Merge + deploy to prod.
4. Manually trigger prod `create_tables` DAG — templated DDLs resolve to prod stage, creating the 5 tier ext tables + refreshing `account_balance_ext`.
5. Manually trigger prod `loyalty_postgres_to_s3_ingest` with `{"loyalty_postgres_backfill": true}` — first backfill run picks up historical tier rows (if loyalty team backfilled from Loyalty Cloud) or an empty set (if tier tables start empty at cutover; see Q6 in `questions_to_ask.md`).
6. Watch next 2-3 hourly scheduled runs succeed end-to-end.
7. Spot-check row counts: `SELECT COUNT(*) FROM LOYALTY.SOURCE.tier` etc.
8. Confirm `compare_row_counts` succeeds on next scheduled run.

## Backfill flow

`loyalty_postgres_to_s3_ingest.py` already supports the `dag_run.conf {"loyalty_postgres_backfill": true}` mechanism via `get_backfill_flag`. When true, the incremental WHERE clause in `loyalty_postgres_incremental.sql` is skipped, so the SELECT reads the entire source table.

Trigger backfill:
- Airflow UI → `loyalty_postgres_to_s3_ingest` DAG → Trigger DAG w/config → paste `{"loyalty_postgres_backfill": true}`

The backfill flag propagates to all `load_<table>` tasks in that run — legacy, OC, and TP tables all get a full-refresh SELECT. Subsequent scheduled runs revert to incremental.

**When backfill is needed for TP:**
- First dev run after PR deploy (populate historical test_ data).
- First prod run after cutover (populate whatever tier data exists in prod PG at that moment).

## dbt staging refresh at cutover

The TP staging models are gated by `enabled: dev or var(tp_ingest_live)`. In prod pre-cutover: disabled (absent from manifest). At cutover the var flips → they come online.

On first prod run post-cutover, the staging models are cold (no prior state). The incremental `WHERE updated_at >= (SELECT MAX(updated_at) FROM {{ this }})` clause returns the whole table on the first materialization (empty target). No manual dbt full-refresh needed — but it doesn't hurt.

Optional full-refresh to be safe: `dbt run --full-refresh --select tag:fesloyalty` via the `dbt_full_refresh` utility DAG.

## Rollback

If cutover-day reveals a blocker:
- Revert the cutover-flip PR. `TP_INGEST_LIVE` returns to `prod=False`, tp ingest tasks stop firing in prod, staging models re-disable in prod.
- Historical TP data already in `LOYALTY.SOURCE.tier*` stays there (harmless).
- OC ingest is unaffected — separate toggle.

## Post-cutover housekeeping (Phase 2)

- If dev PG gets un-prefixed later, flip `TP_TABLE_PREFIX = get_value_for_env(dev="", prod="")` in a one-line PR.
- Once TP has run cleanly in prod for ~2 weeks, consider removing the `TP_TABLE_PREFIX` mechanism entirely (mirroring the post-OC-cutover cleanup commit `4b8a5a54 no longer need test_ prefix`).

## Coordination

- **Loyalty engineer (Suneel)**: needed for prod PG tier migration timing + optional dev un-prefix. Also outstanding Q4b — `rollover_tierpoints` semantics vs `tier_points_on_rollover` on `tier_account_override`; whether `tier_override_configuration.expires_at` is coming.
- **Analytics engineer (AE)**: parallel work stream for downstream `tier_points_loyalty_analytics_ledger` (or similar) that reads from the new staging models. Coordinate branching — either share this feature branch or merge this ingest PR first and let AE branch off main afterward.

## Cross-references

- Discovery findings: `../analysis/dev_pg_discovery.md`
- Schema doc (main branch snapshot): `../context/schema_docs/SCHEMA_DATA_main.md`
- OneCredits playbook (pattern reference): `../../loyalty_ingest_migration/plans/0_cutover_pr.md`
- Open questions: `../questions_to_ask.md`
