# Full pre-prod test plan

**The obstacle:** there is no CDC feed in dev/test (platform decommissioned it — D-10), so a plain
dev run only exercises the batch-fallback branch. To test the CDC path we (1) made the branch
switchable with `--vars '{identity_cdc_enabled: true}'`, and (2) test it two ways: synthetic data in
dev (logic + edge cases) and real prod CDC in an isolated prod sandbox (shape + volume). No prod PII
is ever copied into dev.

Enabler already shipped on the branch: every `*_cdc_current` model + the landing macros gate on
`var('identity_cdc_enabled', target.name == 'prod')`. Forcing it true in dev makes them read
`IDENTITY_DEV.CDC_RAW.*_cdc_raw`. `dbt compile --vars '{identity_cdc_enabled: true}'` is already green.

---

## Stage 0 — static (done)
`dbt parse` + `dbt compile` both branches green (10 models / 29 tests). Transforms validated
read-only vs prod (base64 TimeUUID, map rebuild, loyalty dedup 11,149 rows == PKs, 0 deletes).

## Stage 1 — synthetic data in DEV (deterministic logic + edge cases)
Exercises what's hard to find in prod: RF3 duplicate collapse, multi-version update, hard delete,
seed-only row, base64 uuid, map rebuild — with known-correct expected output.

```sql
-- one-time: create dev landing tables
-- dbt run-operation create_identity_cdc_landing --vars '{identity_cdc_enabled: true}'

-- Seed a controlled batch baseline so seed-union is deterministic (fake UUIDs, no PII):
CREATE OR REPLACE TABLE IDENTITY_DEV.SOURCE.loyalty_private_fan_id_map_ext AS  -- if not a real dev ext; else use a scratch view
SELECT * FROM VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001'::string, 'pf-seed-A'::string, '2024-01-01'::timestamp, '2026-09-01'::timestamp)
  AS t(loyalty_id, private_fanid, created, upload_date);  -- 'A' also arrives via CDC (newer wins)

-- Synthetic Debezium envelopes into the dev landing table:
INSERT INTO IDENTITY_DEV.CDC_RAW.loyalty_cdc_raw (value, source_file_name, _loaded_ts)
SELECT PARSE_JSON(col), 'synthetic', CURRENT_TIMESTAMP() FROM VALUES
  -- id A: THREE RF3-identical copies of the latest change (must collapse to 1, newer than seed)
  ('{"op":"i","ts_ms":1790000002000,"source":{"table":"loyalty","ts_ms":1790000001000,"file":"CommitLog-7-100.log","pos":10},"after":{"loyalty_id":{"value":"aaaaaaaa-0000-0000-0000-000000000001"},"private_fanid":{"value":"pf-CDC-A"},"created":{"value":1790000000000}}}'),
  ('{"op":"i","ts_ms":1790000002050,"source":{"table":"loyalty","ts_ms":1790000001000,"file":"CommitLog-7-200.log","pos":20},"after":{"loyalty_id":{"value":"aaaaaaaa-0000-0000-0000-000000000001"},"private_fanid":{"value":"pf-CDC-A"},"created":{"value":1790000000000}}}'),
  ('{"op":"i","ts_ms":1790000002090,"source":{"table":"loyalty","ts_ms":1790000001000,"file":"CommitLog-7-300.log","pos":30},"after":{"loyalty_id":{"value":"aaaaaaaa-0000-0000-0000-000000000001"},"private_fanid":{"value":"pf-CDC-A"},"created":{"value":1790000000000}}}'),
  -- id B: two versions; the LATER src_ts_ms must win
  ('{"op":"i","ts_ms":1790000010000,"source":{"table":"loyalty","ts_ms":1790000010000,"file":"CommitLog-7-100.log","pos":40},"after":{"loyalty_id":{"value":"bbbbbbbb-0000-0000-0000-000000000002"},"private_fanid":{"value":"pf-B-OLD"},"created":{"value":1790000000000}}}'),
  ('{"op":"i","ts_ms":1790000020000,"source":{"table":"loyalty","ts_ms":1790000020000,"file":"CommitLog-7-100.log","pos":50},"after":{"loyalty_id":{"value":"bbbbbbbb-0000-0000-0000-000000000002"},"private_fanid":{"value":"pf-B-NEW"},"created":{"value":1790000000000}}}')
  AS t(col);
-- (id 'aaaa…0001' seed-vs-CDC: CDC wins; a seed-only id like cccc…0003 with no CDC row → comes from seed)

-- Build + assert
-- dbt build --select loyalty_cdc_current --vars '{identity_cdc_enabled: true}'
SELECT loyalty_id, private_fanid FROM IDENTITY_DEV.<schema>.loyalty_cdc_current
WHERE loyalty_id IN ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002');
-- EXPECT: A → pf-CDC-A (CDC beat seed, 3 copies collapsed to 1 row); B → pf-B-NEW (later ts won).
```

**Edge cases to add the same way:**
- **favorites delete:** insert an `op:"d"` envelope for a `(profile_id, entity_id)` that also exists
  in the seed → assert the row is ABSENT from `favorites_cdc_current` (delete suppresses seed).
- **core base64 modified:** envelope with `modified.value` = a base64 TimeUUID → assert
  `cassandra_timeuuid_to_timestamp(modified)` gives the expected second.
- **preferences map:** `fanatics_one_opt_in_by_tenant.value = [[100002,true],[100004,false]]` → assert
  the model column renders `{"100002":true,"100004":false}`; and an unset map → NULL.
- **unset columns:** omit a column from `after` → assert NULL (not error).

Automate as a `.sh` with assertions via the **mock-data-tester** skill (it generates exactly this
shape of fixture+assert script).

## Stage 1b — REAL prod CDC landed into the DEV database (chosen approach)
Dev has no CDC feed, but the prod stage is readable, so land real prod CDC into `IDENTITY_DEV` and
build the dev models off it. Same account/role as prod (`FES_DATA_DEVELOPER`), output stays in dev.
`load_identity_cdc` always reads the PROD stage; `path_suffix` bounds the load so a test isn't 78 GB.
(Brock can't auto-run CREATE/COPY — team deny list — so run these yourself; loyalty is PII-free, do it first.)

```bash
# on branch identity/cdc-source-migration, dbt-fusion
# 1. create dev landing tables IDENTITY_DEV.CDC_RAW.*  (macro, or the raw DDL below)
dbt run-operation create_identity_cdc_landing --target dev --vars '{identity_cdc_enabled: true}'

# 2. load ONE day from the PROD stage into dev (all 5 tables; drop tables from the loop or use raw
#    COPY to keep it loyalty-only / PII-free first)
dbt run-operation load_identity_cdc --target dev \
  --vars '{identity_cdc_enabled: true}' --args '{path_suffix: "dt=2026-09-28/"}'

# 3. build the CDC models in dev (materialize into your FES_USERS dev schema)
dbt build --select tag:cdc --target dev --vars '{identity_cdc_enabled: true}'
```

Raw-SQL equivalents (role FES_DATA_DEVELOPER, via snow/snowsight) if you prefer not to use the macros:
```sql
CREATE SCHEMA IF NOT EXISTS IDENTITY_DEV.CDC_RAW;
CREATE TABLE IF NOT EXISTS IDENTITY_DEV.CDC_RAW.loyalty_cdc_raw
  (value VARIANT, source_file_name STRING, _loaded_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
-- repeat for marketing_cdc_raw, core_cdc_raw, preferences_cdc_raw, favorites_cdc_raw

COPY INTO IDENTITY_DEV.CDC_RAW.loyalty_cdc_raw (value, source_file_name, _loaded_ts)
FROM (SELECT $1, metadata$filename, CURRENT_TIMESTAMP()
      FROM @FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD/topics/identity_cdc.id.loyalty/dt=2026-09-28/)
FILE_FORMAT = (FORMAT_NAME = 'FDE.FDE_STAGE.JSON_FF')
PATTERN = '.*[.]json[.]gz' ON_ERROR = ABORT_STATEMENT;
```

Assertions on the dev-built model (now reflecting REAL prod CDC):
```sql
-- one row per PK, no null PKs, no op='d' leaked (it's dropped in the model)
SELECT COUNT(*) AS rows, COUNT(DISTINCT loyalty_id) AS pks,
       SUM(IFF(loyalty_id IS NULL,1,0)) AS null_pks
FROM FES_USERS.<your_schema>.loyalty_cdc_current;   -- expect rows == pks, null_pks = 0
```
Then extend to core/preferences/favorites (⚠️ these carry PII → lands prod PII in IDENTITY_DEV;
acceptable per your call, or keep the dev test to loyalty+marketing which are ID-only) to exercise
base64 `modified`/`favorite_id`, the tenant map, and deletes on real data.

## Stage 2 — real prod CDC in an ISOLATED prod sandbox (shape + volume + seed-union at scale)
Dev has no real CDC, so validate real data in prod WITHOUT touching the production identity models:
build the `*_cdc_current` models into a **scratch schema** (e.g. a custom schema override to
`FES_USERS.<you>` or `IDENTITY.CDC_VALIDATION`), reading the real prod CDC stage + real prod seed.
The production consumers are NOT repointed here.
1. `dbt run-operation create_identity_cdc_landing --target prod` + `load_identity_cdc --target prod`
   (into the sandbox schema).
2. `dbt build --select tag:cdc --target prod` with a schema override to the sandbox.
3. Run `parity.md` per table: sandbox `*_cdc_current` vs the live `*_ext` latest snapshot.
   loyalty first. Investigate only large/structural diffs.

## Stage 3 — consumer parity (branch vs main)
Build the 6 repointed consumers into the sandbox and diff vs their current production tables:
row counts + a sampled column hash (e.g. `HASH_AGG(*)` over shared columns). Output must be
byte-identical (they're dbt-Mesh `public`). This is the real "does the swap change anything" test.

## Stage 4 — dev fallback smoke
Plain `dbt build --select tag:identity` on dev (no var) → confirms lower envs still build off the
batch snapshot unchanged. (Parse/compile already green.)

## Go / no-go for prod cutover
All of: Stage 1 assertions pass; Stage 2 parity within expected drift (only genuine post-seed
changes); Stage 3 consumer output identical. Then parallel-run in prod a few days before standing
down the batch DAG.
