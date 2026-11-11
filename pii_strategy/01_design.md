# Design

Locked design for FES PII masking. If you're changing scope or approach, update [`02_decisions.md`](02_decisions.md) first.

## Goal

Apply Snowflake masking policies to PII-classified columns across the FES dbt project so that:

- Engineers, analysts, and service roles without explicit PII access see a non-revealing constant
- A single secondary role grant unlocks the real values for authorized users
- The set of masked columns is **declared in dbt YAML** (where data lives, where docs already live)
- Policy attachment is **automatically applied** every dbt run — no manual `ALTER TABLE` drift

## Architecture

```
Snowflake SYSTEM$CLASSIFY()      Engineer review
        │                              │
        ▼                              ▼
classify_runs/*.json  ──script──▶  schema.yml (columns[].meta.classification, .pii_category)
                                            │
                                            ▼
                                  dbt run finishes models
                                            │
                                            ▼
                                  on-run-end macro scans manifest:
                                    for each tagged column,
                                      ALTER TABLE … SET MASKING POLICY … FORCE
                                            │
                                            ▼
                                  Snowflake column references account-level policy
                                            │
                                            ▼
                                  IS_ROLE_IN_SESSION('FES_PII_READER')
                                    ├── true  → return real value
                                    └── false → return type-aware sentinel
```

Two repos are affected:
- **`fanapp-terraform`** — defines the secondary role and the account-level masking policy objects (one per Snowflake data type)
- **`fes-airflow/dags/dbt`** — YAML tags + on-run-end macro + dbt-side support

This brock-bot repo holds the docs and the `SYSTEM$CLASSIFY()` → YAML helper script.

## Locked decisions

These are the seven decisions confirmed on 2026-06-10. Detailed reasoning lives in [`02_decisions.md`](02_decisions.md).

### 1. Mask value: type-aware non-null sentinels

| Snowflake type | Sentinel |
|---|---|
| STRING / VARCHAR / TEXT / CHAR | `'*** MASKED ***'` |
| NUMBER / INT / BIGINT / DECIMAL / NUMERIC | `-1` |
| DATE | `DATE '1900-01-01'` |

Snowflake masking policies are strictly typed, so we need **one policy per data type**, named uniformly: `FES_PII_MASK_<TYPE>`.

V1 ships **only** these three policies — covering every PII column observed in fangraph_dev. Other types (FLOAT, BOOLEAN, TIMESTAMP_*, VARIANT) are added **lazily** when a PII column of that type surfaces. The macro logs and skips columns whose type has no mapping, so unmapped types degrade gracefully instead of crashing the dbt run. See D12 in [`02_decisions.md`](02_decisions.md).

### 2. One role, not tiered

- **Role**: `FES_PII_READER` (account-level role, in `fanapp-terraform`)
- **Granted to**: MWAA service user (so dbt runs unmasked → tests work), specific human users on request
- **Use as secondary role**: `USE SECONDARY ROLES ALL` or explicit `USE SECONDARY ROLES <role>` in user session — this is why we use `IS_ROLE_IN_SESSION()` not `CURRENT_ROLE()` in the policy
- **Future**: split into tier-specific readers (`FES_PII_READER_CRITICAL`, `FES_PII_READER_HC`) when a use case requires it

### 3. YAML tag convention: categorical, dual-key

Per-column meta:

```yaml
columns:
  - name: email
    description: Customer email address
    meta:
      classification: critical          # critical | highly_confidential | confidential | public
      pii_category: email               # see 03_classification_catalog.md for enum
```

- `classification` — drives the masking policy decision (Phase 1: mask if `critical` or `highly_confidential`)
- `pii_category` — informational, drives future tiered-role splits, used for audit reporting

Columns with `classification: confidential` or `public` (or absent) are **not masked**.

### 4. Pilot scope: `fangraph_dev` database

- Pilot in `fangraph_dev` (the dev sandbox), **not** the prod `fangraph` database
- Once stable in dev, promote to prod
- After fangraph: expand to other model dirs (loyalty, fanapp, etc.) per [`07_rollout.md`](07_rollout.md)

### 5. on-run-end, not post-hook

- The orchestrator is a single `on-run-end` hook calling a macro that scans the manifest
- Macro emits one `ALTER TABLE … MODIFY COLUMN … SET MASKING POLICY … FORCE` per tagged column on every dbt run
- `FORCE` makes the ALTER idempotent — works whether or not a policy is already attached (handles both `create or replace` table mat and incremental)
- **Skip behavior**: models with zero tagged columns produce zero ALTERs (this is the "intelligent skip")
- **Race window**: between a model's `create or replace` and the on-run-end re-apply, the table is briefly unmasked. Acceptable since dbt runs in MWAA service context with no external query traffic. Documented but not mitigated.
- **Future**: skip ALTER for incremental models since the policy persists across runs (cost: one redundant metadata op per run per column; benefit: skip = simpler. Punted to a future ticket.)

### 6. MWAA service user gets `FES_PII_READER`

- Granted as a regular role (not secondary-only) so dbt sees real data
- dbt tests that compare exact PII values will work
- CI/test logs may contain real PII — flagged as a known constraint, not blocking
- Documented as a follow-up: harden test-output redaction if/when it becomes a concern

### 7. Greenfield

No existing masking policies, classification tags, or `pii_*` columns to migrate from. We start clean.

## Non-goals

- Per-row masking (no `USING (col, cond_col, …)` arguments — Phase 1 is column-only)
- Dynamic masking based on data values (e.g., "mask emails matching `@internal.com` differently")
- Column-level encryption at rest
- Cross-database masking (we apply per database; the policy object lives once at account level but each database gets its own ALTERs)
- View-level masking policies (Phase 1 targets tables only; view masking adds a layer we don't need yet)

## Key references

- [Snowflake masking policy docs](https://docs.snowflake.com/en/user-guide/security-column-ddm-use)
- [`snowflake_masking_tax/`](../snowflake_masking_tax/) — Phase 1 benchmark, validated the `IS_ROLE_IN_SESSION()` variant
- [`03_classification_catalog.md`](03_classification_catalog.md) — operational digest of the FAN classification catalog
