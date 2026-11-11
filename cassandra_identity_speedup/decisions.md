# Decisions

Design decisions log. Newest at bottom. Format: `D-N — <title>` + rationale.

## D-1 — Token-range parallel scans as the primary fix (given by framing)
**Decision:** Attack the single-coordinator `SELECT *` scan with token-range chunking:
split Murmur3 token space into N ranges, query `token(pk) > ? AND token(pk) <= ?`
concurrently with `TokenAwarePolicy`. Airflow shape: `discover → compute chunks →
extract_range.expand(...)`. Also raise concurrency + fetch_size and write fewer/larger files.
**Rationale:** A single coordinator streaming an entire table is the fundamental throughput
cap; token-range scans let every replica serve its own slice in parallel. Set at project kickoff.

## D-2 — Size before coding, scan-free only
**Decision:** Rank tables via last prod-run durations + `system.size_estimates`; never
`SELECT COUNT(*)`.
**Rationale:** COUNT(*) is a full scan that times out. `size_estimates` is coordinator-local
and approximate but free, and prod durations are ground truth. Sizing decides how many token
ranges each table needs and whether the 5h is one hog or many tables.

## D-3 — Sizing verdict: MANY medium tables, not one hog → concurrency is the dominant lever
**Decision:** Ship **both** levers but treat **table-level concurrency as the primary win** and
**token-range as the secondary lever** (targeted at the top ~7 tables only).
**Evidence (findings.md, prod run 2026-09-22):** 33 tables; ~99% of the ~3.9h is 7 tables in the
27–39 min band + 2 at 6–7 min; the biggest (profile.core) is only ~17%. Sequential Σ ≈ wall clock,
confirming `max_active_tis_per_dagrun=1` is the first-order bottleneck.
**Rationale:** With this distribution, parallelizing tables alone takes wall-clock from ~3.9h toward
max-single-table ≈ 39 min (~6× ceiling). Token-range then breaks that 39-min floor on the big
tables. Applying token-range to the 24 trivial tables would add scheduling overhead for no gain, so
chunking is **conditional on table size** (only split tables above a threshold; single-range the rest).

## D-10 — Landing = stage → native RAW VARIANT table (mirror FBG); transform = dbt incremental MERGE
**Evidence:** data-transformations/FBG CDC lands via **stage + `COPY INTO` a native `*_RAW` VARIANT
table** (stages/storage-integration in `data-infrastructure-deploy/modules/snowflake/
cdc-migration-stages.tf`), and dbt `*_parsed`/`*_scd` models build off that native table — file-based,
NOT Snowpipe Streaming. The Sandstorm "CDC Approach" RFC (3467313616) confirms this is today's shape
and recommends collapsing 4 layers → 2.
**Decision (user: "do it like data-transformations"):**
- **Land:** our external stage `@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD` (already built) → **scheduled
  `COPY INTO` a native `IDENTITY.CDC_RAW.<table>`** (VARIANT + `metadata$filename` + load ts), driven
  by the existing identity Airflow DAG. Matches FBG's file-based COPY; no new Terraform pipe needed.
  (Snowpipe auto-ingest via the existing SNS topic is a later upgrade, not required for v1.)
- **Transform:** in **dbt-fes-ae**, a `cassandra_cdc_*` macro → per-table `_cdc_current` model,
  `incremental_strategy: merge`, `unique_key=<pk>`, parse inline + node_id/segment dedup + latest-per-PK,
  `op='d'`→delete. This is the RFC's 2-layer / "Airflow-orchestrated MERGE" (Solution 3), which fits
  because the identity pipeline already runs dbt via the DAG. Window-function dedup is fine in a dbt
  incremental (not a dynamic table, so no incremental-refresh restriction).
- **Seed:** one-time UNION against the existing batch data already in `IDENTITY.SOURCE` (no re-extract).

## D-9 — Prod CDC confirmed flowing + broad; tenant_fanid now covered
**Evidence:** read-only DIRECTORY probe 2026-09-28 — 256k files/78.8GB, 19 tables, current to the
minute, incl. `id.tenant_fanid` (findings.md). **Removes the tenant_fanid caveat** and confirms CDC
can carry the full daily workload. 7-day TTL not currently pruning (17d present) — confirm intent.

## D-8 — Reuse the debezium_cdc LAYER SHAPE, not its internals; land-then-model
**Decision:** Adopt the 3-layer shape from `data-transformations/.../debezium_cdc/`
(raw → parsed → current) but write a **new Cassandra-specific `cassandra_cdc_*` macro** for
parse+dedup (Anna's node_id/segment logic), because the existing macros are Postgres-LSN + `before`
based and don't apply to Cassandra Debezium (no before; `(file,pos)` not a global key; `{value,set}`
unions). **Land via Snowpipe/COPY into `IDENTITY.CDC_RAW.<table>`** rather than scanning the 256k-file
stage repeatedly. See [design.md](design.md).

## D-7 — dbt in dbt-fes-ae; preserve the contract via source repoint; current-state grain
**Decision:** Build the CDC models in **dbt-fes-ae** (where identity sources+models live), produce
per-table **current-state** objects with identical columns/PK to today's `*_ext`, and **repoint the
`identity.yml` source** so `unified_profile_*` / `*_private_fan_id_map` need no logic change. PKs:
loyalty→loyalty_id, marketing→martech_id, core/preferences→profile_id, favorites→(profile_id,entity_id).
History/SCD grain deferred unless the user wants it now.

## D-6 — RESOLVED: build CDC materialization; this project owns it
**Decision (user, 2026-09-28):** Go with **CDC materialization as the daily driver** (option
"Build CDC materialization"). Retire the 5h daily snapshot; keep batch only as (a) one-time
historical seed, (b) dev ingestion, (c) `tenant_fanid` until covered. **Hemanth has NOT started**
any CDC→Snowflake work, so this project owns the build end-to-end (no handoff).
**Token-range (D-1) status:** PARKED. Not the daily fix anymore. Revisit only if the one-time
historical seed proves too slow to run once on the existing sequential DAG.

## D-5 — STRATEGIC PIVOT: evaluate CDC before optimizing the batch (RESOLVED → see D-6)
**Context:** Investigation (see [cdc_investigation.md](cdc_investigation.md)) found the FES Platform
team already stood up **Cassandra CDC** (Debezium → CDC Kafka → S3) for `id`+`profile`, **live in
prod since ~2026-09-09**, with Anna Smith's validated S3→Snowflake materialization SQL in
BARDSPLAT-31. The CDC-covered tables are exactly the batch hog list (D-3).
**Decision (proposed, pending user):** Retarget the effort from "make the 5h snapshot faster" to
"**move the daily driver to incremental CDC materialization**," keeping batch as (a) a **one-time
historical seed** (CDC has no backfill) + occasional reconciliation, (b) **dev** ingestion (no CDC
there), and (c) **`tenant_fanid`** until CDC covers it.
**Consequence for token-range (D-1):** It's no longer the daily-runtime fix. It may still be worth
building to make the **one-time historical seed** fast (a 3.9h→~40min seed is nice), but it is
optional and lower priority than the CDC materialization. Decide with the user before coding either.
**Watch-out:** Alex already tasked **Hemanth** (2026-09-23) with prod CDC→Snowflake "in a repeatable
way" — coordinate to avoid duplicate work.

## D-4 — Target the Cassandra reader DC
**Decision:** Route extract reads at the `...-cassandra-reader-dc` (seen in the prod log:
`10.68.x` reader hosts alongside `10.58.x` primary), via a DC-aware + token-aware load-balancing
policy pinned to the reader DC, keeping `LOCAL_ONE`.
**Rationale:** This is a bulk full-snapshot scan; keeping it off the write-path DC protects prod
latency. Confirm the connection's contact points / LB DC before finalizing.
