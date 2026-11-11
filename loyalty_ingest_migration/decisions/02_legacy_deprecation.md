# Decision 02 — Handling of journal / entry / idempotency_keys

**Date:** 2026-06-25
**Status:** Decided (subject to user/team review; nothing destructive happens at cutover)

## The situation

Per schema doc migration 000011:
- `journal` (PG): **dropped**. Legacy `load_journal` task will fail post-cutover unless removed.
- `entry` (PG): **dropped**. Legacy `load_entry` task will fail post-cutover unless removed.
- `idempotency_keys.updated_at` (PG): **removed**. Legacy `load_idempotency_keys` task will fail post-cutover (incremental filter dies) unless removed.

The materialized Snowflake tables `LOYALTY.SOURCE.journal`, `LOYALTY.SOURCE.entry`, `LOYALTY.SOURCE.idempotency_keys` hold OneCredits historical ledger data — needed by the analytics engineer for backfill of the rewritten ledger until they confirm otherwise.

## Decision (revised 2026-06-25 after code review)

**Only the ingest config side is gated in this PR. dbt staging models stay un-gated.** The legacy staging models keep running on historical data forever (or until Phase 2 cleanup). Reason: gating the legacy dbt staging models would break dbt compile in either dev or prod because the OneCredits ledger SQL still refs them (the AE rewrite isn't in this PR; it's a follow-up).

### Phase 1 — in the cutover PR (this PR, deploys before prod cutover)

1. **Gate at the ingest level only**: `POSTGRES_TABLE_CONFIGS_ACTIVE` in `configs.py` filters out `journal`/`entry`/`idempotency_keys` whenever `OC_INGEST_LIVE` is True (dev now, prod at cutover). In prod pre-cutover the filter is inactive so the legacy ingest is unchanged.
2. **Do NOT add `enabled` gates to the legacy dbt staging models.** They're consumed by `models/loyalty/one_credits/one_credits_loyalty_analytics_ledger.sql` which is also un-gated (AE rewrite is a follow-up PR). Gating either side would compile-fail.
3. Materialization continues against historical S3 data. Dev sees no new rows after PR-deploy (because the ingest is skipped); prod sees new rows until cutover, then no new rows.
4. **Leave the dbt source declarations** for `journal_ext`, `entry_ext`, `idempotency_keys_ext` in `models/sources/loyalty.yml`.
5. **Leave the ext tables** (`JOURNAL_EXT`, etc.) and their DDL files.

### Phase 1.5 — AE rewrite (folded into this PR, 2026-06-25)

AE's PR #2126 rewrote `one_credits_loyalty_analytics_ledger.sql` and `loyalty_one_credits_balance_daily_snapshot.sql` to use the new schema. Folded into this branch with two adjustments:
- Refs swapped from `source('loyalty__source', 'test_<table>_ext')` to `ref('<staging>')` so we go through our materialized staging models, not the external tables directly.
- Both files wrapped in a `{% if var('oc_ingest_live', false) or target.name == 'dev' %}` block with the original SQL kept as the `{% else %}` branch. Both branches produce the same column schema so downstream consumers compile identically in either world. Cutover flips the dbt `oc_ingest_live` var and the compiled manifest picks the new branch — no cascade gating needed.

### Phase 2 — 2-4 weeks post-cutover

Calendar reminder set for ~2026-07-22 (3 weeks after cutover, assuming 2026-07-01 cutover). Before dropping, confirm with the analytics engineer that they no longer need historical access.

Then:
1. Delete the gated dbt staging model files: `journal.sql`, `entry.sql`, `journal_normalized.sql`, `idempotency_keys.sql`.
2. Remove dbt source declarations for `journal_ext`, `entry_ext`, `idempotency_keys_ext` from `models/sources/loyalty.yml`.
3. Drop materialized tables: `DROP TABLE LOYALTY.SOURCE.journal`, `entry`, `idempotency_keys`.
4. Drop ext tables: `DROP EXTERNAL TABLE LOYALTY.SOURCE.journal_ext`, `entry_ext`, `idempotency_keys_ext`.
5. Delete the ext-table DDL files: `create_journal_ext.sql`, `create_entry_ext.sql`, `create_idempotency_keys_ext.sql`.
6. Optionally archive the S3 parquet files to a cold-storage path (if storage cost matters; otherwise leave).

## Why not rename to `*_deprecated`

Considered. Cleaner signaling, but adds:
- A Snowflake rename DDL.
- Object naming inconsistency for the grace period.
- Risk of breaking any forgotten downstream ref (arguably good, but unnecessary if dbt removal already removes the obvious references).

Stopping ingest + removing dbt sources/staging models is enough signal for the team — the tables no longer appear in dbt's model graph, so any new model trying to ref them will fail at compile time.

## Why not drop at cutover

Snowflake Time Travel (1-7 days depending on edition) is a narrow recovery window. If the analytics engineer discovers a need 10 days post-cutover, dropped-without-recovery is bad. The grace period is cheap insurance.

## Edge case: dbt graph dependency

The legacy `journal_normalized.sql` is ephemeral and ref'd by `one_credits_loyalty_analytics_ledger.sql`. If the AE's rewrite of `one_credits_loyalty_analytics_ledger.sql` doesn't land at cutover, removing `journal_normalized` breaks the build. Coordination:
- AE's rewrite should land **before or with** our cutover PR.
- If timing slips: defer Phase 1 step 2 (dbt model deletion) and let the legacy staging models continue to materialize on historical data. Only remove the PG ingest config (Phase 1 step 1).
