# Progress Log

## 2026-09-28 — Phase 0 setup + Phase 1 ingest of source files

- Created project workspace `projects/cassandra_identity_speedup/` with flat `.md` files.
- Read `dags/identity/cassandra_extract.py` and `dags/identity/cassandra_schema_discovery.py`
  on `main`; summarized current-state facts into [findings.md](findings.md).
- Confirmed worktree `~/repos/fes-airflow-token-range` is on branch
  `fix/cassandra-token-range-extract` (scaffolded, mirrors main content).
- Logged D-1 (token-range fix) and D-2 (size-before-coding, scan-free) in [decisions.md](decisions.md).

## 2026-09-28 — M1 sizing DONE (from prod-run screenshots, ground truth)

User supplied `discover_tables` log + `extract_table` Mapped Tasks durations for prod run
2026-09-22. Mapped map_index→table (order is deterministic) and ranked. **Verdict: NOT one hog —
7 medium tables (27–39 min) + 2 at 6–7 min = ~99% of a ~3.9h sequential run.** Recorded full table
in [findings.md](findings.md); logged **D-3** (concurrency is the dominant lever, token-range
secondary/conditional) and **D-4** (target the reader DC) in [decisions.md](decisions.md).

## 2026-09-28 — PIVOT to CDC materialization (investigation + user decision)

Investigated whether the platform team's new Cassandra CDC can replace the batch snapshot. Vault
had nothing specific; found the answer in Slack + Confluence + Jira. **CDC is live in prod
(~2026-09-09)** for `id`+`profile`, covering exactly the batch hog tables. Anna Smith's validated
S3→Snowflake materialization SQL is in **BARDSPLAT-31**. Full writeup →
[cdc_investigation.md](cdc_investigation.md) (docs, stage names, S3 commands, Anna's pattern, caveats).

**User decision:** build the **CDC materialization** as the new daily driver (D-6). Token-range
PARKED. **Hemanth has NOT started** any CDC work → this project owns the build. Rewrote
[plan.md](plan.md) around the CDC architecture.

**In flight:** Explore agent mapping (A) the existing `data_transformations/.../debezium_cdc/` dbt
pattern for reuse, and (B) the current `tag:identity` models + their cassandra S3 source contract +
per-table PKs. All 4 repos (fes-airflow, data-transformations, dbt-fes-ae, fanapp-terraform) are
cloned locally.

## 2026-09-28 — M1+M2 done: contract mapped, prod CDC confirmed, design written

- **M1 (reuse+contract):** Explore mapped the `data-transformations/.../debezium_cdc/` dbt pattern
  (3-layer raw→parsed→SCD/current, but **Postgres-LSN + `before` based → NOT directly reusable** for
  Cassandra) and the `dbt-fes-ae` `tag:identity` contract (current-state, one-row-per-entity; PKs
  confirmed per table; sources in `models/sources/identity.yml`, models in `models/identity/`).
  → D-7, D-8.
- **M2 (prod confirm):** read-only DIRECTORY probe → **CDC live, 256k files/78.8GB, 19 tables,
  current to the minute, tenant_fanid now covered** (findings.md). → D-9.
- Wrote [design.md](design.md): layers, Cassandra-specific dedup macro, seed+union, Snowpipe landing,
  lag alerting, and the **`id.loyalty` pilot** + repo/PR split.

## 2026-09-28 — design finalized (D-10) + prod parse/dedup VALIDATED

- User settled the 3 forks: **current-state only**; **land like data-transformations** (stage →
  native RAW VARIANT via file-based COPY, NOT Snowpipe Streaming — our events pre-land in S3); **one-time
  union** against existing batch data in `IDENTITY.SOURCE` (no re-extract). → D-10.
- Mapped landing mechanism (Explore): FBG uses stage(TF) + `COPY INTO` native `*_RAW` + dbt on top.
- Read `dbt-fes-ae` conventions: source `identity__source` (DB IDENTITY, schema SOURCE, `*_ext`,
  `loaded_at_field: UPLOAD_DATE`); models under `models/identity/{source,unified_profile,orchestration}`;
  **reuse macros** `fanapp_recs_copy_into.sql`, `cassandra_timeuuid_to_timestamp.sql`,
  `add_incremental_timestamps.sql`, `assert_unique_key.sql`, `materializations/`.
- **VALIDATED on prod (read-only):** confirmed the real Debezium 2.0.1 envelope + ran the dedup on a
  1-hour loyalty slice → 4,403 raw → 861 logical, **5.11× dup**, PK=loyalty_id, all inserts. Anna's
  pattern reproduces. FF = `FDE.FDE_STAGE.JSON_FF`. (findings.md)

## 2026-09-28 — M3 BUILD DONE (all 5 tables) on branch dbt-fes-ae `identity/cdc-source-migration`

Confirmed prod envelope shapes for all 5 tables (read-only) and pinned the exact column map + type
reconciliations (see [dbt_integration.md](dbt_integration.md) table). Built the full migration:

**New files (dbt-fes-ae):**
- `macros/cassandra_uuid_bytes_to_string.sql` — base64 TimeUUID bytes → hyphenated string (matches batch).
- `macros/identity_cdc_landing.sql` — `create_identity_cdc_landing` + `load_identity_cdc` run-ops
  (COPY stage → native `IDENTITY.CDC_RAW.*_cdc_raw`; prod-guarded; dedupes loaded files).
- `models/identity/cdc/{loyalty,martech,core,preferences,favorites}_cdc_current.sql` — drop-in
  current-state models: parse + latest-per-PK + drop op='d' + one-time seed UNION; env-aware
  (prod=CDC+seed, non-prod=batch fallback).
- `models/identity/cdc/_identity_cdc__sources.yml` (native landing source + freshness on `_loaded_ts`),
  `_identity_cdc__models.yml` (unique/not_null tests), `README.md` (activation runbook).

**Repointed consumers (source→ref, snapshot idiom removed, output identical):**
loyalty_private_fan_id_map(_latest), martech_private_fan_id_map, unified_profile_{core,preferences,favorites}.

**Validated:**
- Read-only vs PROD: loyalty dedup (1-day: 11,149 rows == 11,149 PKs, 0 deletes leaking); base64
  TimeUUID→ts chain (2026-09-28 15:00:08); preferences map `[[100004,false]]`→`{"100004":false}`;
  `modified` base64→hyphenated. All correct.
- `dbt parse` + `dbt compile` (dev target): **10 models + 29 tests, 39/39 success.** (Dev compiles the
  batch-fallback branch; prod CDC branch is simple source()+macro jinja, each SQL fragment validated live.)
- Fixed en route: `TO_BINARY` needs `::string`; correlated `LATERAL FLATTEN` subquery unsupported →
  reworked preferences map as flatten+GROUP BY+join; Fusion test-arg format (`arguments:`).

Parity harness → [parity.md](parity.md).

## 2026-09-28 — testability: CDC branch made switchable; DEV-against-prod-S3 test path

- Gated CDC branch on `var('identity_cdc_enabled', target.name=='prod')`; CDC source + landing macros
  env-aware (IDENTITY_DEV off-prod); added `path_suffix` to `load_identity_cdc` for bounded test loads.
  `dbt compile --vars '{identity_cdc_enabled: true}'` green → the prod-only CDC branch now compiles locally too.
- **Chosen test approach (user):** land REAL prod CDC S3 into the DEV Snowflake DB. Dev target =
  same account/role (`FES_DATA_DEVELOPER`, proven to read the prod FDE stage), writes to dev. Runbook
  in [testing.md](testing.md) Stage 1b (create dev landing → bounded COPY from prod stage → dbt build
  → assert). **Brock cannot auto-run the CREATE/COPY (team deny list) → user runs the provided commands.**
- Branch amended → `9356df6` (unsigned, not pushed).

## 2026-09-28 — auth_id added to the PR (6th table)

Coverage check found `auth_id` was the only OTHER consumed Cassandra table (all 14 remaining
DAG-only tables have ZERO dbt consumers). auth_id is in the `fde` group: source
`fde__source.auth_id_ext` (DB FDE.SOURCE) → `models/fde/auth_id.sql` (incremental, `tag:daily`,
FDE.FDE_INFO, unique_key auth_id). Migrated it:
- CDC envelope (probed): plain uuid strings + `created` epoch-ms (no base64) → simplest case.
- Added `auth_id_cdc_raw` to landing list + CDC source; new `auth_id_cdc_current` model tagged
  **['daily','cdc']** (builds with its consumer's daily job, NOT the identity job); repointed
  `models/fde/auth_id.sql` source→ref.
- Validated read-only vs prod (1-day: 14,198 rows == 14,198 auth_id PKs, 0 deletes). parse+compile green.
- **Wiring caveat (in README):** `load_identity_cdc` (loads all 6 incl auth_id) must run in BOTH the
  identity pipeline AND the daily-fde pipeline before their builds — COPY is idempotent so safe.
Branch amended → `e592913`. Now 6/6 consumed Cassandra tables migrated.

**Next / handoff (state-changing — needs the user):**
1. In prod: `dbt run-operation create_identity_cdc_landing` + `load_identity_cdc`; wire the load into
   the identity DAG before `dbt build --select tag:identity`.
2. `dbt build`, run parity.md per table (loyalty first), parallel-run, then cut over + stand down batch.
3. Push branch + open labeled PR (NOT done yet — awaiting user OK). Commit is local-only.
4. Optional follow-ups: incremental/dynamic-table optimization; `MAX(source:ts_ms)` lag alert.
