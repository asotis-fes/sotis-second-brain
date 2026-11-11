# Resume Instructions — Phase 3 Redo + Phase 5

**Status as of 2026-06-11 16:40 UTC:** snow CLI session expired (SSO popup needed). User stepped away before approving. Two pending experiments staged but not run.

## Step 0: Re-auth

```bash
snow sql -q "SELECT CURRENT_USER() AS u, CURRENT_TIMESTAMP() AS ts"
```

Approve the SSO popup. If `u = ALEX.SOTIS@BETFANATICS.COM` and `ts` is current, you're good.

---

## Phase 3 Redo (plaintext-branch fangraph rebuild)

**Why:** Phase 3's original measurement was the *masked* branch (pipeline-not-allowlisted scenario). The realistic production scenario is the *plaintext* branch — Airflow service role allowlisted, reads PII directly, projects forward. The earlier run of this was killed by a network blip and produced no QUERY_HISTORY rows.

**What runs:** 3 fangraph CTASes on `FDE_DEVELOPER_3XL_WH` (3X-Large, prod size):
- BASELINE (no policy) — calibration
- HASH × READER (plaintext branch)
- CONST × READER (plaintext branch)

Wall-clock: ~5 min × 3 = ~15 min. Cost: ~$36.

**Setup is partially done** — the clones, roles, and policies were re-created when I ran step 1 before snow died. Verify they're still there:

```bash
snow sql -q "SHOW TABLES LIKE 'MTAX_FG_%_20260611A' IN SCHEMA FES_USERS.ALEX_SOTIS"
snow sql -q "SHOW MASKING POLICIES LIKE 'P3_%_20260611A' IN SCHEMA FES_USERS.ALEX_SOTIS"
snow sql -q "SHOW ROLES LIKE 'TEST_PII_READER_20260611A'"
```

If anything is missing, re-run setup:
```bash
snow sql -f snowflake_masking_tax/run_20260611a_p3_redo_setup.sql
```

Then kick off the 3-cell run:
```bash
snow sql -f snowflake_masking_tax/run_20260611a_p3_redo_runs.sql > /tmp/p3_redo_runs.out 2> /tmp/p3_redo_runs.err
```

**Pull results when done:**
```sql
SELECT
    SPLIT_PART(SPLIT_PART(query_tag, '|', 3), '=', 2) AS variant,
    SPLIT_PART(SPLIT_PART(query_tag, '|', 5), '=', 2) AS role,
    ROUND(total_elapsed_time/1000.0, 1) AS sec,
    ROUND((execution_time/1000.0/3600.0) * 64, 3) AS credits_3xl,
    ROUND(bytes_scanned/1024/1024/1024, 1) AS gb
FROM TABLE(FES_USERS.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
    USER_NAME => CURRENT_USER(),
    RESULT_LIMIT => 10000,
    END_TIME_RANGE_START => DATEADD('hour', -3, CURRENT_TIMESTAMP())
))
WHERE query_tag LIKE 'mtax|phase=p3|%role=READER%'
  AND query_type = 'CREATE_TABLE_AS_SELECT'
  AND execution_status = 'SUCCESS'
ORDER BY start_time;
```

Plug numbers into `report_v2.html` Phase 3 quadrant cells: `HASH × HAS PII` and `CONST × HAS PII`.

---

## Phase 5 (XS warehouse model — `fan_key_fan_id_map`)

**Goal:** test whether masking imposes meaningful tax on a real production model that runs on an XS warehouse. Phase 1/2 microbenchmarks suggested XS may show large tax (+50% to +200%); Phase 3 (3XL) and Phase 4 (Large) showed near-zero. XS is the missing data point.

**Target model:**
```yaml
- name: fan_key_fan_id_map
  config:
    database: COMMERCE          # in prod
    schema:   FAN_KEY
    snowflake_warehouse: FDE_MWAA_XS_WH   # prod
  model_sql: SELECT * FROM COMMERCE.source.fan_key_fan_id_map_iceberg
```

**🚨 DESIGN PROBLEM — needs user decision before running:**

The model is `SELECT * FROM commerce__source.fan_key_fan_id_map_iceberg`. The source naming convention in `models/sources/commerce.yml` separates PII tables (e.g. `fan_key_master_pii_iceberg`, `fan_key_account_map_pii_iceberg`, `unified_fanid_pii_iceberg`) from non-PII tables. `fan_key_fan_id_map_iceberg` does **not** have `_pii_` in its name, strongly suggesting it's an ID-mapping table — likely `(fan_key, fan_id, ...timestamps)` with no actual PII columns.

If that's the case, applying masking policies to nonexistent PII columns has **no effect** — baseline and "masked" runs would be identical. The test wouldn't measure the XS hypothesis.

**Confirm column schema first:**
```bash
snow sql -q "DESCRIBE TABLE COMMERCE.source.fan_key_fan_id_map_iceberg"
```

Then pick one of these paths:

### Path A — fan_key_fan_id_map has actual PII columns
Proceed with the test as the user described. Build a runner that:
1. Clones `COMMERCE.source.fan_key_fan_id_map_iceberg` → `FES_USERS.ALEX_SOTIS.MTAX_FK_FG_SRC_20260611A`
2. Creates per-type policies (reuse `P3_MASK_*` / `P3_CONST_*` from 20260611A — already exist if Phase 3 redo setup ran)
3. Runs `CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.MTAX_FK_RESULT_<variant>_<role> AS SELECT * FROM <clone>` on `FDE_DEVELOPER_XS_WH`
4. Five cells: BASELINE / HASH×READER / HASH×EXCLUDED / CONST×READER / CONST×EXCLUDED
5. ~$3–5 cost on XS.

### Path B — fan_key_fan_id_map has no PII columns
Pick a different XS-warehouse model that **does** project PII. Search `models/**/yaml` for `snowflake_warehouse.*XS_WH` AND project columns in our PII list. Candidates likely live in `models/commerce/*pii*/` or `models/fangraph/opco_*/`. Adapt the Phase 4 runner pattern for that model.

### Path C — confirm null-effect on XS, no real PII test
Run the model as-is with masking on synthetic policies attached to columns it doesn't project. Confirms the obvious null result. Not very informative.

**My recommendation: do (A) only if confirmed, else (B). (C) is a waste.**

---

## Cleanup After Both Phases Finish

```sql
-- Drop Phase 3 redo + Phase 5 (if it ran) infrastructure
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_BASE_20260611A;
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_SNAPSHOTS_20260611A;
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_20260611A_BASELINE_ADMIN;
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_20260611A_HASH_READER;
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_20260611A_CONST_READER;
-- + any MTAX_FK_* tables if Phase 5 ran
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P3_MASK_STR_20260611A;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P3_MASK_NUM_20260611A;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P3_MASK_DATE_20260611A;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P3_CONST_STR_20260611A;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P3_CONST_NUM_20260611A;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P3_CONST_DATE_20260611A;
DROP ROLE IF EXISTS TEST_PII_READER_20260611A;
```

For tables with foreign-role ownership (`_READER` suffix), grant ownership to ACCOUNTADMIN first:
```sql
GRANT OWNERSHIP ON TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_20260611A_HASH_READER  TO ROLE ACCOUNTADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_20260611A_CONST_READER TO ROLE ACCOUNTADMIN COPY CURRENT GRANTS;
```
