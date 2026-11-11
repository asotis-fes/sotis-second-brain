# Parity harness — run in prod after building the `*_cdc_current` models

Compares each `*_cdc_current` model against the batch `*_ext` latest snapshot it replaces.
Expectation once CDC has run a while: `cdc_current` ⊇ the seed (same PKs, minus CDC-deletes, plus
post-cutover new rows), and overlapping rows are equal-or-newer. Run on ≥ MEDIUM warehouse.

## Loyalty (worked example)

```sql
-- 1. Row counts + PK uniqueness
SELECT 'cdc_current' AS src, COUNT(*) n, COUNT(DISTINCT loyalty_id) pks FROM {{db}}.identity.loyalty_cdc_current
UNION ALL
SELECT 'ext_latest', COUNT(*), COUNT(DISTINCT loyalty_id)
FROM identity.source.loyalty_private_fan_id_map_ext
WHERE upload_date = (SELECT MAX(upload_date) FROM identity.source.loyalty_private_fan_id_map_ext);

-- 2. PKs in the batch snapshot MISSING from cdc_current (should be ~0; any = CDC-deleted or a gap)
WITH ext AS (
  SELECT loyalty_id FROM identity.source.loyalty_private_fan_id_map_ext
  WHERE upload_date = (SELECT MAX(upload_date) FROM identity.source.loyalty_private_fan_id_map_ext)
)
SELECT COUNT(*) AS missing_from_cdc
FROM ext e LEFT JOIN {{db}}.identity.loyalty_cdc_current c ON e.loyalty_id = c.loyalty_id
WHERE c.loyalty_id IS NULL;

-- 3. Value drift on overlapping PKs (private_fanid / created differ = CDC applied a newer value)
SELECT COUNT(*) AS changed_rows
FROM {{db}}.identity.loyalty_cdc_current c
JOIN (
  SELECT loyalty_id, private_fanid, created FROM identity.source.loyalty_private_fan_id_map_ext
  WHERE upload_date = (SELECT MAX(upload_date) FROM identity.source.loyalty_private_fan_id_map_ext)
) e ON c.loyalty_id = e.loyalty_id
WHERE c.private_fanid IS DISTINCT FROM e.private_fanid
   OR c.created       IS DISTINCT FROM e.created;
```

## Generic template (per table)
Replace `<t>`, `<ext>`, `<pk>`, and the value columns:
- **core** (`core_ext`, pk `profile_id`): check `first_name,last_name,dob_day,dob_month,age_range,
  test_account,modified`; verify `cassandra_timeuuid_to_timestamp(modified)` yields the same
  `modified_ts` on both sides (the base64→string normalization is the risk).
- **preferences** (`preferences_ext`, pk `profile_id`): check the scalar cols + that
  `fanatics_one_opt_in_by_tenant` renders the SAME JSON object shape (`{"100002":true}`) on both.
- **favorites** (`favorites_ext`, pk `profile_id,entity_id`): verify
  `cassandra_timeuuid_to_timestamp(favorite_id)` matches; favorites emits deletes → expect some
  batch PKs legitimately absent from cdc_current.
- **martech** (`martech_private_fan_id_map_ext`, pk `martech_id`): like loyalty.

## Consumer-level parity (end-to-end)
Before/after the source repoint, snapshot the 6 consumer models on `main` vs. this branch and diff
row counts + a sampled column hash. Output columns must be byte-identical (dbt-Mesh `public` models).

## Notes
- `{{db}}` = the target db the models build into (identity build schema), not necessarily `IDENTITY`.
- Small legitimate diffs are expected: cdc_current reflects changes since the last batch snapshot.
  Investigate only large/structural diffs (type mismatches, missing columns, PK explosions).
