# Export SQL — summary (code is the source of truth)

The exact, current SQL lives in **`export_tp_migration.py`** (v4, de-collide model). Do **not**
hand-maintain full SQL here — inspect it directly:

```bash
python3 export_tp_migration.py setup '2026-08-07 12:00:00'   # 3-tier map + de-collide + ledger snap + §P1
python3 export_tp_migration.py effective                     # just the de-collide snapshot DDL
python3 export_tp_migration.py fmti perf                     # FMTI COPY INTO (39 cols)
python3 export_tp_migration.py overrides perf                # overrides COPY INTO (20 cols)
python3 export_tp_migration.py chunk perf 0                  # one ledger-chunk COPY INTO (24 cols)
python3 export_tp_migration.py verify                        # §P1/§P2 gate query
```
Full run is orchestrated by `gen.py` (see [README.md](README.md) → Run procedure).

## The three datasets (per Suneel's repo, adapted to COPY INTO + pinned snapshots)
| # | S3 path | Source | Cols | Key / notes |
|---|---------|--------|------|-------|
| ① FMTI | `fmti/fmti.csv.gz` | Salesforce FMTI ⋈ de-collide | 39 | one row per **fan-id**; `loyalty_id = effective_loyalty_id`; cohort `active_source_loyalty`; +`source_loyalty_id`/`is_primary`/`dup_group`; balances → `DECIMAL(38,2)`. Single file. |
| ② Overrides | `override_cdc/overrides.csv.gz` | `TIER_POINTS_OVERRIDES_V2` ⋈ de-collide | 20 | keyed on `effective_loyalty_id`; keep rows with data **or** following one (CDC). Single file. |
| ③ Ledger | `ledger/chunk_NNNNN/` | `TIER_POINTS_LEDGER_V2` ⋈ de-collide | 24 | keyed on `effective_loyalty_id`; filters below; chunked, one file/chunk. |

## Ledger filters (type-adapted to our schema)
```sql
JOIN TP_EFFECTIVE_SNAPSHOT e ON e.private_fan_id = l.PRIVATE_FAN_ID   -- de-collide (per fan-id)
WHERE (COALESCE(l.DERIVED_TIER_POINTS_AMOUNT,0) <> 0 OR l.NOTES = 'EOY-Rollover')
  AND COALESCE(l.EXTERNAL_ID_TYPE,'') NOT IN ('OVERRIDE','NON_TRANSACTOR')
  AND COALESCE(l.NOTES,'') <> 'TierPoints 10x Loyalty Program'
  AND l.TRANSACTION_TIMESTAMP IS NOT NULL                       -- (adapts Suneel's TRIM; col is LTZ)
  AND COALESCE(l.IS_TEST_TRANSACTION, FALSE) <> TRUE             -- (adapts his UPPER/COALESCE; col is BOOLEAN)
  AND l.TRANSACTION_TIMESTAMP < '<cutover>'::TIMESTAMP_LTZ       -- ledger only
```

## Type adaptations of Suneel's SQL (his literals assume TEXT; our schema differs)
- `IS_TEST_TRANSACTION` is **BOOLEAN** → `COALESCE(...,FALSE) <> TRUE` (his `UPPER(COALESCE(...,''))` would error).
- `TRANSACTION_TIMESTAMP` is **TIMESTAMP_LTZ** → `IS NOT NULL` + direct `< ts::TIMESTAMP_LTZ`.
- FMTI year cols → `TRY_TO_NUMBER(NULLIF(TRIM(..::VARCHAR),''))::INT`; balances → `TRY_TO_DECIMAL(..::VARCHAR,38,2)`.
- **Timestamp formatting:** Suneel returns raw ts (UI-download); we keep the validated COPY-INTO UTC `… Z` format.
- **De-collide is pinned:** the map + de-collide are materialized once in `setup` (not re-inlined per dataset).

## File format
`TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=() COMPRESSION=GZIP`, `HEADER=TRUE`, `SINGLE=TRUE`.
`NULL_IF=()` → NULLs are bare empty, not `""`. Booleans (incl. `is_primary`/`dup_group`) → lowercase.
