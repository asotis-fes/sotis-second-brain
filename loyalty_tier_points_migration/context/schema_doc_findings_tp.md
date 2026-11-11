# Schema Doc Cross-Reference — Tier Points (2026-07-13)

Source: `main` branch of `fanatics-gaming/fes-loyalty` at `docs/SCHEMA_DATA.md`
Local copies: `schema_docs/SCHEMA_DATA_main.md` (authoritative), `SCHEMA_DATA_schema2.md` (referenced during OneCredits), `SCHEMA_DATA_tp-lu.md` (branch, less complete).

Main was last modified 2026-07-13 — very fresh, definitive source of truth.

## TP-1 — `account_balance.lifetime` exists (RESOLVED)

Schema doc (line 542):
> `lifetime` | `NUMERIC(18,6)` | Cumulative total earned (TierPoints only; NULL for other programs).

**Action:** add `lifetime NUMERIC(18,6)` to:
- `dags/create_tables/sql/loyalty/create_account_balance_ext.sql`
- `OC_POSTGRES_TABLE_CONFIGS.account_balance.cols` in `configs.py` (if the list enumerates columns)
- `dags/dbt/models/loyalty/source/account_balance.sql` staging SELECT

Sidenote from the doc: "**Note:** `lifetime` column exists on `program_account_balance` (migration 000009), not on `account_balance`." This appears to contradict line 542 that lists `lifetime` in the `account_balance` table. **Verify against actual PG** — the schema doc has an internal inconsistency here.

## TP-2 — `tier_account_override_trial` (RESOLVED, needed)

Suneel's list omits it, but the schema doc lists it in the full Tier Tables section (lines 695-712) as a proper table with a full column set. It stores trial-tracking data for STATUS_MATCH overrides and is FK-referenced from `tier_account_override.trial_id`.

Interpretation: Suneel's list is likely the **"tier configuration tables"** — the 4 tables that were parameterized in migration 000014 to default `program_id = 2`. `tier_account_override_trial` doesn't have a `program_id` column (it's trial-state, not config), which is why it's outside that migration's scope but still part of the tier model.

**Recommendation:** ingest `tier_account_override_trial` too. It's small, FK'd from `tier_account_override`, and downstream STATUS_MATCH analytics will need it to reconstruct trial outcomes.

**Ask Suneel** to confirm whether `test_tier_account_override_trial` exists in dev PG (per the migration doc, the `test_` counterpart should exist).

## TP-3 — `account_metadata` NEW TABLE (needs decision)

The main-branch schema doc introduces `account_metadata` (lines 550-565), NOT in Suneel's list.

- **Not tier-specific** — it's a per-`(loyalty_id, program_id)` JSONB metadata store, described as "durable per-loyalty, per-program metadata".
- **Credits example given** in the doc (`credit_tier_points`, `current_period_tier` in JSONB) — so Credits uses it too.
- Was `account_metadata` in the OneCredits ingest? — **NO** (verified: our current `OC_POSTGRES_TABLE_CONFIGS` doesn't list it, and no `create_account_metadata_ext.sql` exists).

**Question:** did OneCredits skip this because it wasn't yet in scope, or because the AE decided the metadata JSONB wasn't needed downstream? For tier points, do we need `account_metadata`?

Adds a new open question — see Q11 in `questions_to_ask.md`.

## TP-4 — Full tier table list (confirmed vs Suneel)

| Table | In Suneel's list? | In schema doc? | PG dev name (best guess) |
|---|---|---|---|
| `tier` | ✅ (`test_tier`) | ✅ (line 651) | `test_tier` |
| `tier_override_configuration` | ✅ (`test_override_configuration`)? | ✅ (line 671) | `test_tier_override_configuration` — **name mismatch, confirm** |
| `tier_account_override` | ✅ (`test_tier_account_override`) | ✅ (line 716) | `test_tier_account_override` |
| `tier_account_override_trial` | ❌ omitted | ✅ (line 695) | `test_tier_account_override_trial` — **confirm existence + ingest need** |
| `tier_invite_approval` | ✅ (`test_invite_approval`)? | ✅ (line 752) | `test_tier_invite_approval` — **name mismatch, confirm** |

## TP-5 — Migration 000014 introduced `CHECK (program_id = 2)` on tier tables

The "Tier Points configuration tables" section (line 771) explains that `program_id` is now enforced-and-defaulted to 2 on the tier config tables via migration 000014. It's omitted from the API but still exists as a column.

Implications:
- Column `program_id` still exists on the tier config tables (with default 2). Our ext-table DDL should project it for completeness.
- No filter needed downstream — all rows in these tables are program_id=2 by definition.

## TP-6 — `tier` table schema (definitive column list from main)

From lines 655-664, plus the migration 000014 note:

| Column | Type | Notes |
|---|---|---|
| `tier_id` | UUID PK | app-supplied UUIDv7 |
| `program_id` | BIGINT | CHECK = 2, default 2 (from migration 000014) |
| `name` | TEXT | unique per program |
| `minimum_eligible_balance` | BIGINT | |
| `invite_only` | BOOLEAN | default `false` |
| `description` | TEXT | nullable |
| `created_at` | TIMESTAMPTZ | |
| `updated_at` | TIMESTAMPTZ | |

Unique constraints: `(program_id, name)`, `(program_id, tier_id)`
Partial index: `idx_tier_min_balance (minimum_eligible_balance) WHERE program_id = 2`

## TP-7 — Enum types needed for staging

Tier tables reference these enums:
- `tier_override_type` (`PLACEMENT`, `ROLLOVER`, `STATUS_MATCH`)
- `tier_override_reason` (`COMPETITOR_MATCH`, `NEAR_THRESHOLD_TRIAL`, `NEW_YEAR_ADJUSTMENT`, plus others — check full list)
- `tier_invite_status` (`APPROVED`, `REVOKED`)

Parquet ingest will serialize these as strings. Staging models should cast them to `VARCHAR` (no domain enforcement in Snowflake).

## Comparison: what schema2 (OneCredits era) said vs main today

Deltas since 2026-06-24 (schema2 → main):
- `account_metadata` added as new mapper table
- Migration 000014 added `CHECK (program_id = 2)` to tier config tables + default
- Migration 000012 seeds `tier` and `tier_override_configuration` rows
- `tier` gained `description` column (not in schema2's `tier` DDL)
- Otherwise the tier tables are structurally the same as schema2's version

## Recommended path forward

1. **Ask Suneel** (Q1 in questions_to_ask.md) to run `\d test_tier*` and `\d test_account_metadata` in dev PG. This confirms literal names AND surfaces any test tables we don't know about.
2. **Deploy a schema-discovery DAG** if Suneel is slow to respond — see next-action section below.
3. Once names are confirmed, draft the ingest wiring and reuse the OneCredits pattern with a new `TP_INGEST_LIVE` toggle.
