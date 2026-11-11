# Reference — Context, Map, De-collide, Buckets, Data Model

> Exact SQL = `export_tp_migration.py` (v4). This is the conceptual reference.

## The three datasets

S3 layout under `tp_migration/` (one file per chunk):
```
tp_migration/
├── fmti/fmti.csv.gz                          ← single file (account/balance snapshot, 39 cols)
├── override_cdc/overrides.csv.gz             ← single file (override CDC history, 20 cols)
└── ledger/chunk_00000/chunk_00000.csv.gz     ← chunked by effective_loyalty_id, 1 file/chunk (24 cols)
    chunk_00001/chunk_00001.csv.gz ...
```

| Dataset | Source | Cols | Key / cohort logic |
|---------|--------|------|--------------------|
| **FMTI** | Salesforce `FanMemberTierInformation_…__dll` ⋈ de-collide | 39 | one row per **fan-id**; `loyalty_id = effective_loyalty_id`; cohort = source loyalty id has any fan-id with ledger activity (non-`NON_TRANSACTOR`) **or** an override tier-name/invite (`active_source_loyalty`). +`source_loyalty_id`/`is_primary`/`dup_group`. Balances → `DECIMAL(38,2)`. Not time-filtered. |
| **Overrides** | `TIER_POINTS_OVERRIDES_V2` ⋈ de-collide | 20 | `LOYALTY_ACCOUNT_ID = effective_loyalty_id`; keep rows with override data **or** that follow one (`had_previous_override` CDC). Not time-filtered. |
| **Ledger** | `TIER_POINTS_LEDGER_V2` ⋈ de-collide | 24 | `LOYALTY_ACCOUNT_ID = effective_loyalty_id`; `DERIVED_TIER_POINTS_AMOUNT<>0` OR `NOTES='EOY-Rollover'`; exclude `OVERRIDE`/`NON_TRANSACTOR`/10x-notes; not a test txn; `TRANSACTION_TIMESTAMP < cutover`. Chunked. |

**Cutover applies to the ledger only** — FMTI + overrides are current-state snapshots.

## The 3-tier identity map (new in v4)
`fan-id → loyalty-id` resolved by UNION-with-priority (first tier that resolves wins):
1. **tier-1 identity** — `identity.orchestration.loyalty_private_fan_id_map` (dedup by fan-id).
2. **tier-2 email-chain** — `commerce_dev.source.scylla_tenant_fanid_ext` → `fde.fde_info.auth_id`
   → `fde.fde_info.account_internal_id_lkp` → `fde.fde_info.account_user_service_id` (pick
   `DATA:"1094"`, latest by MODIFIED) → `commerce.fan_key.customer_account_map` (hashed email) →
   `cde.cde_core.loyalty_account` (prefer directory 2 / site 510005). The tier-2 entry point
   `commerce_dev.source.scylla_tenant_fanid_ext` lives in a `_dev` DB but is **intentional** — a
   loyalty-team paid→loyalty-id table, consulted only when tier-1 identity misses (Suneel, 2026-08-07).
   Tier-1 identity was backfilled by Mohit 2026-08-06, so tier-2's contribution is shrinking.
3. **tier-3 legacy** — `LOYALTY.LOYALTY_INFO.LOYALTY_ACCOUNT_ID_FAN_ID_TENANT_MAP` (prefer directory 2).

> v3.1 used **only** tier-3 and joined on loyalty-id. v4 uses all three and keys per fan-id. All 8
> source tables verified readable 2026-08-07.

## De-collide (why the key is now per-fan-id)
Multiple fan-ids can map to one loyalty-id. They are **not merged** — each migrates as its own account:
- Within a colliding loyalty-id, rank fan-ids by active balance (`TPMigration`, tie → LastModified →
  lifetime → sm → Id). Rank 1 = **primary** → keeps the original loyalty id. Others = **secondary** →
  new **deterministic v1-shaped UUID**: `UUID_STRING('e5567350-…-45f9bcbe4047', pfid:source_loyalty_id)`
  then flip the version nibble (15th char) `5→1` (Cassandra `timeuuid` rejects v5). **Namespace is
  fixed — never change it** (breaks re-export determinism + `account_metadata` correlation).
- `effective_loyalty_id` is **1:1 with fan-id** → chunking by it keeps each account whole in one chunk.
- FMTI's `source_loyalty_id`/`is_primary`/`dup_group` drive the loader's `account_metadata(program_id=2)`
  write for both sides of every dup group.

## Single-snapshot pinning
`gen.py setup` materializes three transient tables in `FES_USERS.ALEX_SOTIS` **once**:
- `TP_MAP_SNAPSHOT` — the raw 3-tier union (fan-id → loyalty-id).
- `TP_EFFECTIVE_SNAPSHOT` — the de-collide (fan-id → effective_loyalty_id, is_primary, dup_group),
  built from `TP_MAP_SNAPSHOT ⋈ FMTI` (fb dedups FMTI to one row/fan-id so the map is a clean 1:1).
- `TP_LEDGER_SNAPSHOT` — ledger export + a stable `chunk_num`
  (`FLOOR((DENSE_RANK() OVER (ORDER BY effective_loyalty_id)-1)/200000)`).

FMTI/overrides/ledger then JOIN the pinned de-collide → the expensive 6-DB map runs once and there's
no cross-statement drift.

## Coverage / gates (`gen.py verify`)
- **§P2 cohort integrity (HARD, must be 0):** `ledger_missing_account`, `overrides_missing_account` —
  every exported effective loyalty id has an FMTI row. 0 by construction (de-collide is built from
  FMTI); verify proves it.
- **§P1 data-loss surface:** `unresolved_active_fanids` / `unresolved_points_at_stake` — fan-ids with
  points-bearing ledger activity that resolve in **none** of the 3 tiers → their tx have no account
  and are dropped. Captured in `FES_USERS.ALEX_SOTIS.TP_MIGRATION_UNRESOLVED`; escalate if points are
  material before prod.
- Informational: `decollide_secondary_or_dup` (fan-ids in a dup group).

## Deleted accounts
**Migrated** (go stale in the new ledger) — no deleted filter. Detection query (reference only):
```sql
SELECT "MembershipNumber__c", "FirstName_c__c", "EnrollmentDate__c"
FROM SALESFORCE."schema_FanJourney_Loyalty_Promotion_Shares"."LoyaltyProgramMember_00DHs000003WzIz__dll"
WHERE "FirstName_c__c" = 'deleted';
```

## Format
- Timestamps (`TIMESTAMP_LTZ`): UTC `YYYY-MM-DD HH24:MI:SS.FF3 Z` via `TO_CHAR(CONVERT_TIMEZONE('UTC',
  col),…) || ' Z'` (`TS_SUFFIX`). Suneel's repo queries return raw ts (UI-download); we keep the
  COPY-INTO `… Z` format — **confirmed good by Suneel 2026-08-10** against the full perf export.
- `NULL_IF=()` → SQL NULL unloads as **bare empty** (not `""`). `FIELD_OPTIONALLY_ENCLOSED_BY='"'`
  still quotes text with commas.
- Booleans unload lowercase `true/false` (incl. `is_primary`/`dup_group`; loader casts from text).
- Every chunk file has a header (`COPY … HEADER=TRUE SINGLE=TRUE`).

## Buckets & AWS accounts
- Target buckets are **Loyalty-owned**, in **per-env accounts**: perf `fes-loyalty-fanapp-perf-1`
  (acct `354089337614`), prod `fes-loyalty-fanapp-prod-1` (acct `851474972090`).
- Snowflake's IAM user (from the integration): `arn:aws:iam::685689791302:user/13b00000-s`.
- Do **not** use the CI/backend accounts (`767397958296` perf-CI, `975050193047` prod-CI) in the role ARN.

## Suneel's kit (reference only)
`fanatics-gaming/fes-loyalty-tp-migration-ws/snowflake` — `fmti.sql`/`overrides.sql`/`ledger.sql`
(self-contained, inline the map + de-collide, designed for UI download), `preflight.sql` (§P1–§P5
gates + de-collide reports), `split_ledger.py` (DuckDB post-split of a downloaded `ledger.csv`). We
implement the same logic as Snowflake `COPY INTO` with pinned snapshots instead.
