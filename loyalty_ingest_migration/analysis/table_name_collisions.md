# Table Name Collisions: Legacy vs. New Backend

## TL;DR

Two tables exist in **both** ingest config lists: `loyalty_account` and `program`. Today this is masked because the new-backend path is dev-only and uses `test_` prefixes for both source-table names and S3 keys. The moment we strip `test_` for prod cutover, the two ingests will fight over the same S3 path and the same Snowflake destination (`LOYALTY.SOURCE.loyalty_account`, `LOYALTY.SOURCE.program`).

**Decision needed before cutover** (target 2026-07-01). Until OQ-1 and OQ-2 are answered, design for **coexistence** (safer assumption) and simplify if legacy retires.

## The Two Configs

### Legacy (`POSTGRES_TABLE_CONFIGS`) — runs in prod today

Source: Loyalty Cloud-shape (journal/entry ledger model). Tables:
- `entry`
- `idempotency_keys`
- `journal`
- **`loyalty_account`** ← collides
- `opco_program_account`
- `operating_company`
- **`program`** ← collides
- `program_account_balance`
- `system_loyalty_account`

Lands at: `s3://fes-integrations-{env}/loyalty_postgres/<table>/dt=<ds>/<table>_<ts>.parquet`
→ `LOYALTY.SOURCE.<table>` in Snowflake.

### New backend (`OC_POSTGRES_TABLE_CONFIGS`) — dev-only today, `test_` prefixed

Source: bucket-model schema, OneCredits program only at cutover (Tier Points + FanCash later via `program_id` filter — same physical tables). Tables:
- **`loyalty_account`** ← collides
- **`program`** ← collides
- `bucket_type`
- `bucket`
- `account_balance`
- `transfer_restriction`
- `transaction`
- `allocation`
- `allocation_remaining`
- `void_remaining`
- `auth_hold`
- `capture_event`
- `void_auth_event`
- `auth_bucket_hold`

Lands at: `s3://fes-integrations-dev/loyalty_postgres/test_<table>/dt=<ds>/test_<table>_<ts>.parquet`
→ no native Snowflake table yet; external table over S3.

## The Two Scenarios from OQ-2

The loyalty team has to resolve the collision **inside their own Postgres** at cutover. Two ways they might do it:

### Scenario A — Unified physical table

Single physical `loyalty_account` / `program` row set in prod PG, serving both legacy code paths and the new bucket-model code paths. Schema reconciliation done on their side (probably an additive superset).

**Implications for us:**
- The legacy ingest task for `loyalty_account` and the new ingest task for `loyalty_account` are **reading the same physical table**. Running both is wasteful but not catastrophic — they'd race on writes to the same S3 key and same Snowflake destination.
- Right answer: **dedupe at the config level** — only one ingest path owns `loyalty_account` and `program`. The legacy task drops them; the new task picks them up (or vice versa, depending on which downstream dbt models we want to keep working through cutover).

### Scenario B — Separate physical tables

Loyalty team uses different names on their side (`loyalty_account_v2`, separate schema, etc.).

**Implications for us:**
- New ingest config's `table: "loyalty_account"` won't match what's in PG; we have to update the config to whatever they name it.
- Now there's no collision in PG, but we still have to decide whether we ingest both into Snowflake under the same name (no — also collides) or disambiguate the new one's S3/Snowflake landing path.

## ⚠️ Updated 2026-06-24 after reading dbt repo

See `full_pipeline_pattern.md` — the legacy ingest is a 4-layer pipeline (S3 → ext table → dbt staging model → downstream), and the **dbt source schema is named `SOURCE`** (declared as `loyalty__source` source group in `models/sources/loyalty.yml`). Existing native staging tables sit at `LOYALTY.SOURCE.<table>` (lowercase) and ext tables at `LOYALTY.SOURCE.<TABLE>_EXT` (uppercase).

**This strengthens the recommendation below** — using a separate Snowflake schema for the new backend cleanly mirrors the precedent already set by `LOYALTY_STAGE` and `LOYALTY_CORE` (each a separate schema for a distinct logical source/purpose). The naming pattern would land on something like `LOYALTY.SOURCE_V2` or `LOYALTY.LOYALTY_BACKEND`, with a parallel dbt source group `loyalty__source_v2` (or similar).

## Options for Disambiguating in S3 + Snowflake (applies to both scenarios)

Even after the PG-side collision is resolved, we have to decide how the new-backend tables present in S3 and Snowflake. Four candidates:

| # | Strategy | S3 path | Snowflake destination | Pros | Cons |
|---|----------|---------|------------------------|------|------|
| 1 | **Separate Snowflake schema** | `loyalty_postgres/<table>/...` (same prefix) | `LOYALTY.SOURCE_V2.<table>` (or `LOYALTY.NEW_BACKEND.<table>`) | Clean separation; new dbt sources live in a new schema; legacy keeps `SOURCE.` untouched | Requires new schema + grants; needs an S3 prefix change anyway to avoid S3 collision |
| 2 | **Separate S3 prefix + separate schema** | `loyalty_postgres_v2/<table>/...` | `LOYALTY.SOURCE_V2.<table>` | Strongest isolation; clear "v2 = new backend" mental model; cheap to operate two parallel ingests during cutover transition | Two parallel S3 layouts to manage; new external/native table definitions needed regardless |
| 3 | **Rename new tables (`_v2` suffix)** | `loyalty_postgres/<table>_v2/...` | `LOYALTY.SOURCE.<table>_v2` | Single schema; obvious which is new; no schema/grant work | `_v2` suffix is awkward and sticky; analytics engineer's dbt models inherit ugly names |
| 4 | **Drop legacy in same PR; new takes the bare names** | `loyalty_postgres/<table>/...` | `LOYALTY.SOURCE.<table>` (overwriting) | Cleanest end state; no renaming debt | Requires OQ-1 to be "legacy retires"; no graceful rollback if new ingest is broken |

**Recommended default (pending OQ-1 / OQ-2 answers):** **Option 2**.
- Separate S3 prefix (`loyalty_postgres_v2/`) and separate Snowflake schema (`LOYALTY.SOURCE_V2`, or whatever naming the team prefers).
- Lets legacy keep running for the cutover window (revert is just "stop deploying the new ingest").
- Analytics engineer's new dbt models reference `source('loyalty_v2', '<table>')` cleanly; no collision with the existing `source('loyalty', '<table>')` they may already use.
- If OQ-1 resolves to "legacy retires," we can later migrate `SOURCE_V2` → `SOURCE` in a follow-up; that's a rename, not a re-ingest.

## Concrete Cutover Implications (for Option 2)

1. **DAG changes:**
   - Remove the `test_` prefix in the new-backend loop.
   - Remove (or invert) the `if config.get_value_for_env(dev=True, prod=False)` gate so the loop runs in prod.
   - Update the new-backend `s3_key` to use `loyalty_postgres_v2/<table>/...`.
   - Feed new-backend load tasks into the dbt TaskGroup.
   - Extend `compare_row_counts` (or fork it) to iterate the new config and query `LOYALTY.SOURCE_V2.<table>`.

2. **Snowflake-side prerequisites:**
   - Create `LOYALTY.SOURCE_V2` schema in dev + prod.
   - Grants for the service user / dbt role.
   - External table (or native tables via dbt staging models) declared in the new schema, pointing at the new S3 prefix.

3. **dbt-side prerequisites (analytics engineer):**
   - `sources.yml` entry for the new schema/tables.
   - Staging models materialize the native tables `compare_row_counts` will query.

4. **No coordination needed on names:** legacy `LOYALTY.SOURCE.loyalty_account` is untouched. Future folks know "v2 = new backend."

## What To Pin Down Next

- [ ] OQ-2 answer: what literal table names appear in prod PG after cutover? (Scenario A vs. B determines whether the new-backend config's `table:` values need to change at all.)
- [ ] Confirm `LOYALTY.SOURCE_V2` (or alternative name) is acceptable to the team and the analytics engineer.
- [ ] Confirm S3 prefix `loyalty_postgres_v2/` is acceptable, or pick alternative.
- [ ] Verify external-table definitions for the dev `test_`-prefixed paths — if they exist, they'll need re-creation against the new prod path. Check Snowflake / look in `loyalty_new_service/` or the dbt repo.

## Related

- DAG: `fes-airflow/dags/loyalty/loyalty_postgres_to_s3_ingest.py`
- Config: `fes-airflow/dags/loyalty/configs.py`
- Open questions: `../open_questions.md`
- Ledger reconstruction work (other engineer): `../../loyalty_new_service/`
