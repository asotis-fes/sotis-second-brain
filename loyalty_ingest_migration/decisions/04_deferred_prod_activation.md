# Decision 04 — Deferred prod activation (dormant deploy, one-flip cutover)

**Date:** 2026-06-25
**Status:** Decided — implementation details to refine

## The idea

Deploy the cutover PR to **both envs** several days before prod cutover. In dev it runs against `test_`-prefixed sandbox tables (already there from PR 291). In prod, the new-backend ingest and staging models are **dormant** — code is deployed but no new tasks fire, no new tables are read. At prod cutover, **flip one (or a few) config lines** to activate.

Benefits:
- Real dev validation against the new-backend code path for days.
- No coordination needed with the loyalty team to un-prefix dev PG (we keep using `test_` there).
- Cutover-day change is small, predictable, reviewable in isolation.

## Mechanism (sketch — revised 2026-06-25)

### Two independent toggles

The original design conflated "cutover happened" with "new ingest active." User correction: dev already has the data (with `test_` prefix), so the new ingest should be **active in dev now**. The prefix is a separate concern that flips when the loyalty team un-prefixes dev PG (could be days/weeks after we deploy).

### Config toggles (`fes-airflow/dags/loyalty/configs.py`)

```python
# Toggle A — whether the new-backend ingest path is active in this env.
# Dev: True from PR deploy day (we already have data, just test_ prefixed).
# Prod: False until cutover. Flip to True at cutover.
OC_INGEST_LIVE = config.get_value_for_env(dev=True, prod=False)

# Toggle B — source-table prefix for the new-backend tables.
# Dev: "test_" until loyalty team un-prefixes dev PG (independent of prod cutover timing).
# Prod: "" (the un-prefixed names that appear at cutover).
OC_TABLE_PREFIX = config.get_value_for_env(dev="test_", prod="")

# Legacy tables to skip when the new backend takes over.
LEGACY_DROPPED = {"journal", "entry", "idempotency_keys"}
POSTGRES_TABLE_CONFIGS_ACTIVE = [
    c for c in POSTGRES_TABLE_CONFIGS
    if not (OC_INGEST_LIVE and c["table"] in LEGACY_DROPPED)
]
```

The two toggles flip independently:
- **Prod cutover day** → change `OC_INGEST_LIVE` to `prod=True`. One line.
- **Dev un-prefix day** (whenever loyalty team migrates dev PG) → change `OC_TABLE_PREFIX` to `dev=""`. One line.

### Revised state table

| env | `OC_INGEST_LIVE` | `OC_TABLE_PREFIX` | new ingest | legacy `journal/entry/idempotency_keys` |
|-----|------------------|-------------------|------------|---------|
| **dev (now, after PR deploy)** | True | `test_` | YES | skipped |
| dev (after loyalty un-prefix) | True | `""` | YES | skipped |
| **prod (now, after PR deploy)** | False | `""` (unused) | NO (dormant) | unchanged (still ingests) |
| prod (at cutover) | True | `""` | YES | skipped |

### DAG (`loyalty_postgres_to_s3_ingest.py`)

```python
# Iterate the *active* legacy set (excludes dropped tables once OC_INGEST_LIVE)
for table_config in POSTGRES_TABLE_CONFIGS_ACTIVE:
    ...

if OC_INGEST_LIVE:
    for table_config in OC_POSTGRES_TABLE_CONFIGS:
        table_name = table_config["table"]
        source_table = f"{OC_TABLE_PREFIX}{table_name}"   # "test_bucket" in dev today; "bucket" in prod post-cutover
        s3_key = f"loyalty_postgres/{source_table}/dt={{{{ ds }}}}/{source_table}_{{{{ ts_nodash }}}}.parquet"
        ...
```

### Ext-table DDLs (`create_tables/sql/loyalty/`)

Use the same prefix in the LOCATION:

```sql
-- create_bucket_ext.sql (single file, works in both envs)
CREATE OR REPLACE EXTERNAL TABLE {{ params.target_db }}.source.bucket_ext (
    ...
)
LOCATION = @{{ params.stage }}/loyalty_postgres/{{ params.oc_prefix }}bucket
FILE_FORMAT = (TYPE = PARQUET)
PATTERN = '.*\\.parquet';
```

And pass `oc_prefix` from `create_tables.py`:
```python
"loyalty": {
    "target_db": loyalty_database,
    "stage": ...,
    "oc_prefix": <same expression as DAG>,
},
```

**Ext table name is the same in both envs** (`bucket_ext`). Only the S3 LOCATION differs by prefix. This means dbt sources and staging models don't need env conditionals — they always ref `bucket_ext`.

Delete the 12 `create_test_*_ext.sql` files (replaced by these new templated ones).

### dbt sources (`models/sources/loyalty.yml`)

Add 12 new entries under `loyalty__source`. No env conditionals — same name in dev and prod (`bucket_ext`, etc.).

### dbt staging models (`models/loyalty/source/*.sql`)

Same template as legacy. No env conditionals at the SQL level.

**But here's the catch:** see "Subtlety: dbt tests on empty tables" below.

## Cutover-day change (prod)

```python
# Before
OC_INGEST_LIVE = config.get_value_for_env(dev=True, prod=False)
# After
OC_INGEST_LIVE = config.get_value_for_env(dev=True, prod=True)
```

One line. PR, review, deploy.

## Separately: dev-PG un-prefix (whenever loyalty team migrates dev PG)

```python
# Before
OC_TABLE_PREFIX = config.get_value_for_env(dev="test_", prod="")
# After
OC_TABLE_PREFIX = config.get_value_for_env(dev="", prod="")
```

Independent timing. Doesn't have to happen before or after prod cutover.

## dbt model gating (locked 2026-06-25, refined after code review and AE-PR integration)

**Only the 12 new bucket-model staging models carry an `enabled` flag.** Legacy staging models stay un-gated. The two OneCredits ledger SQL files stay un-gated too — instead they use a `{% if var('oc_ingest_live', false) or target.name == 'dev' %}` block to switch between the new-staging refs and the legacy-staging refs at compile time. Both branches produce the same column schema so downstream consumers compile cleanly in any env, no cascade gating needed.

Earlier draft of this decision had legacy and ledger models gated via `enabled` — that broke dbt compile (ref-to-disabled is a compile error in dbt). The Jinja-conditional form avoids the ref-to-disabled problem because both branches reference always-enabled models, and only one branch makes it into any given compiled manifest.

CI compiles dbt manifest per-env (`dbt compile --target ${DBT_ENV}`), so target-based `enabled` Jinja flags work cleanly. Each env gets its own manifest baked at deploy time.

### Pattern

**12 new bucket-model staging models** (`bucket_type`, `bucket`, `account_balance`, `transfer_restriction`, `transaction`, `allocation`, `allocation_remaining`, `void_remaining`, `auth_hold`, `capture_event`, `void_auth_event`, `auth_bucket_hold`):

```yaml
config:
  enabled: "{{ target.name == 'dev' or var('oc_ingest_live', false) }}"
```

In dev: always enabled. In prod pre-cutover: disabled (absent from compiled manifest, ext-table data is empty, no compile/test issues). In prod post-cutover: enabled via the var flip.

**Legacy staging models stay un-gated** (per Decision 02 revised) — they're consumed by `one_credits_loyalty_analytics_ledger.sql` which is itself un-gated until the AE follow-up PR replaces the SQL.

### dbt_project.yml addition

```yaml
vars:
  ...existing vars...
  oc_ingest_live: false   # toggle to true at prod cutover
```

### Effective state

| env | `target.name` | `var('oc_ingest_live')` | new models | legacy models |
|-----|---------------|--------------------------|-----------|---------------|
| dev | `dev` | False | enabled | disabled |
| prod (pre-cutover) | `prod` | False | disabled | enabled |
| prod (post-cutover) | `prod` | True | enabled | disabled |

### Cutover-day change

```yaml
# dbt_project.yml: change one line
oc_ingest_live: true   # was false
```

Combined with `OC_INGEST_LIVE` in `configs.py`, the cutover PR is two one-line changes.

## Trade-off: stale OneCredits ledger in prod during validation

The AE's `one_credits_loyalty_analytics_ledger.sql` rewrite refs new staging models. Once the PR merges, the prod manifest excludes the rewrite (gated off), and the OLD ledger SQL is gone (replaced in the file). So between PR-deploy and prod cutover (~5 days), the OneCredits ledger in prod does not refresh. The historical Snowflake table sits there with PR-deploy-day data; consumers see stale data for the validation window.

**This is the simplest design.** Alternatives considered and rejected:
- Keep OLD ledger SQL as a separate `_legacy.sql` file with `alias`-based name swap and mutually exclusive enabled flags — works but adds repo complexity and an extra `ref()` indirection in `_fbg`.
- Wait to merge the AE's rewrite until cutover day — defeats the dev-validation purpose.

If the 5-day staleness in prod is unacceptable for downstream consumers, fall back to the `_legacy.sql` mechanism. Flag for user review before implementing.

## What this changes about the cutover-PR plan

Updates `plans/0_cutover_pr.md`:
- All ext-table DDLs are templated with `oc_prefix`
- Single set of `create_<table>_ext.sql` files (delete the test_ versions)
- All staging models gated by `enabled: ...` flag (Option A) or just omit `not_empty` (Option B)
- AE's ledger rewrite also gated by `enabled` flag (Option A)
- Cutover-day change is the `OC_CUTOVER_LIVE` flip per env

## Coordination

- **PR deploy (dev validation start)**: `OC_INGEST_LIVE=True` for dev from day one. New ingest fires against test_-prefixed dev PG tables. Legacy journal/entry/idempotency_keys ingest tasks stop running in dev (their PG sources may still exist, but we don't need them anymore — the AE ledger rewrite reads from the new staging models).
- **Dev un-prefix (optional, any time)**: loyalty team un-prefixes their dev PG tables. We flip `OC_TABLE_PREFIX` dev="" in a one-line PR. Validates the un-prefixed code path before prod cutover, but not strictly required.
- **Prod cutover (target ~2026-07-01)**: loyalty team applies migration 000011 in prod PG. We flip `OC_INGEST_LIVE` prod=True in a one-line PR. Same code path that's been running in dev.
