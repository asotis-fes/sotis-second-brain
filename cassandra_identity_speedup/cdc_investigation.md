# CDC Investigation — can we retire the 5h batch snapshot?

**TL;DR:** The FES Platform team (Jobin Muthalaly) stood up **Cassandra CDC** (Debezium →
dedicated CDC Kafka → S3 sink → S3) for the `id` + `profile` keyspaces. It's **live in prod**
(deployed ~2026-09-09, more tables 2026-09-15). Anna Smith validated it end-to-end in TEST and
**wrote the canonical S3→Snowflake materialization SQL** (below). Moving the daily snapshot to CDC
is viable and is the strategically-endorsed direction — **but CDC is changes-forward-only with no
backfill**, so a one-time ETL seed + a few hard caveats apply.

---

## Where the docs live

**Confluence**
- **"Enabling CDC for Cassandra"** — FAN / `2826207791` (author Jobin Muthalaly, epic
  **FANDEVX-2127**). Full design: Debezium sidecar per Cassandra node → dedicated CDC Kafka +
  Kafka Connect → S3 sink. Change-event structure, IAM, VPC peering, caveats.

**Jira**
- **BARDSPLAT-31** "Confirm CDC data flowing into data compute S3: Dev/test" (**Done**) — Anna's
  validation writeup + **the canonical materialization SQL** in comment `1146212`. This is the SQL
  the user was referring to.
- **BARDSPLAT-3** — BARDS plan to materialize CDC in the **dbx data lake → Snowflake via Spark**
  (the "proper" long-term path; ~M33, gated on the FES Databricks workspace build-out).
- **FESFEAT-252** — platform feature ticket for the CDC enablement.

**Slack**
- `#fcore-data-mgrs` 2026-08-13 (thread ts `1786634186.143689`) — Anna's summary to Alex/Bhumika/
  Brett: CDC test-validated, going to prod; "use the SQL in BARDSPLAT-31 comments"; **CDC has no
  history → union with an ETL snapshot**; `tenant_fanid` not covered yet.
- `#fcore-data-internal` 2026-09-04 (thread ts `1788550075.331449`) — "**FES Cassandra CDC sources
  moving to prod Tuesday**"; pasted the stage names + peek SQL; **7-day TTL on the bucket**; stage
  may need manual refresh (SNS topic added later to fix).
- `#bards-platform-support` 2026-07-30 (ts `1785444847.960049`) — table-scoping thread: **`id` +
  `profile` in, `auth` excluded**; Jimmy Jorge confirmed `id` is PII-free, `profile` is PII (but
  we already batch-ingest it, so CDC is fine).
- `#bards-platform-support` 2026-09-08 (ts `1788898452.972949`) — **Decision: CDC in test + prod
  only, NOT dev.** Lower envs keep batch ingestion. (Two-way door; Alex agreed.)
- `#fcore-team` 2026-09-08 / 2026-09-15 — Jobin's enablement announcements.
- DM Jobin↔Alex 2026-08-26 (`D0BSNTV067L`) — external-stage / IAM-role mechanics; Alex's
  Terraform-location writeup.
- DM Hemanth↔Alex 2026-09-23 (`D09A3AHM6R4`) — **Alex handed Hemanth Janyavula the task** of
  getting prod CDC S3 → a Snowflake table "in a repeatable way" after he closes the Identity
  migration. ⚠️ Coordinate — this may already be in flight.

**Terraform (fanapp-terraform)**
- `root/fes-data/snowflake-v2/integrations-fes_instaclustr.tf` — storage integration + external
  stages per env, reading the `*-fanflow-kafka-connect/` + `identity-cdc-*` S3 buckets.
- PR **#3082** — builds the stage (was a placeholder to revert once prod data flowed).
- PR **#3248** — prod Snowflake integration for FES Cassandra CDC.
- PR **#3270** — SNS topic on the staged CDC bucket to **auto-refresh the stage** (no manual refresh).
- Connector: `modules/instaclustr/kafka-connect-cdc-s3/lambda_function.py`.
- Prod IAM (currently shared w/ fanflow): `arn:aws:iam::596671416667:role/prod-fanflow-s3-consumer-role`
  (dev `023095479468:role/dev-fanflow-s3-consumer-role`). Jobin planned a dedicated CDC role.

---

## Where the data is / how to find it

**Snowflake external stages** (this is the practical access path — the S3 bucket lives in the
Instaclustr AWS account, so direct `aws s3 ls` needs cross-account assume):

| Env | Stage | File format |
|-----|-------|-------------|
| prod | `@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD` | `FDE.FDE_STAGE.FF_JSON_GZ` |
| test | `@FDE_DEV.FDE_STAGE.IDENTITY_CDC_FES_TEST` | `FDE_DEV.FDE_STAGE.FF_JSON_GZ` |
| dev | `@FDE_DEV.FDE_STAGE.IDENTITY_CDC_FES_DEV` | `FDE_DEV.FDE_STAGE.FF_JSON_GZ` |

- S3 buckets: `identity-cdc-fes-{env}` (Instaclustr account).
- Object layout: `topics/identity_cdc.<keyspace>.<table>/…` (JSON, gzip). Filter with
  `metadata$filename LIKE 'topics/identity_cdc.id.loyalty/%'` or `$1:source:table::STRING = '<t>'`.
- ⚠️ **Warehouse size:** ~28.5k files / 102 MB (avg 3.5 KB) over one week in test — an **X-Small
  times out** listing/scanning the stage; Anna used a **Large**. `rotate.schedule.interval.ms` is
  still `300000` (5-min test value; should be `5400000`/90-min for prod) so files over-fragment.
  Prefer Snowpipe-into-a-table over repeatedly scanning the raw stage.

### Commands to find / peek at the data

List files in the stage:
```sql
SELECT * FROM DIRECTORY(@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD) AS p LIMIT 10;
```

Which tables are actually present (and volume) in prod:
```sql
SELECT $1:source:table::string AS tbl, COUNT(*) AS events
FROM @FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD (FILE_FORMAT => 'FDE.FDE_STAGE.FF_JSON_GZ')
GROUP BY 1 ORDER BY 2 DESC;   -- run on a LARGE warehouse
```

Peek at one table's events (Anna's validation query):
```sql
SELECT
    $1:source:pos       AS s_pos,
    $1:source:file::string AS s_file,
    $1:source:ts_ms     AS s_ts_ms,
    $1:ts_ms            AS e_ts_ms,
    $1                  AS value,
    metadata$filename
FROM @FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD (FILE_FORMAT => 'FDE.FDE_STAGE.FF_JSON_GZ')
WHERE $1:source:table::STRING = 'marketing_lkp'
ORDER BY s_pos
LIMIT 10;
```

---

## Anna's canonical materialization pattern (the "SQL that looks funny but works")

From BARDSPLAT-31 comment `1146212`. Two grains, built in `FES_USERS.ANNA_SMITH`:
`LOYALTY_CDC_HISTORY` (one row per logical change) + `LOYALTY_CURRENT` (latest per `loyalty_id`).

Key ideas the pattern encodes (these are the reusable rules for ANY CDC table):
1. **Parse the Debezium envelope:** `$1:after:<col>:value`, `$1:op`, `$1:source:{table,file,pos,ts_ms}`,
   `$1:ts_ms`. Column values are nested `{value, set}` Avro unions — read `:value`.
2. **Dedup the 5–8× duplication.** Two stacked causes: **RF=3** (3 nodes each run a Debezium agent,
   each emits every change) × **Debezium re-read** (~1.75×, re-scans the live commit-log segment;
   `commitlog_sync_period` ~10 s). `(source.file, source.pos)` is **NOT** a global dedup key — it
   only dedups within one node. Derive `node_id` by clustering `segment_id` runs
   (`REGEXP_SUBSTR(...'CommitLog-7-(\d+)\.log'...)`), then GROUP BY the logical key.
3. **Pick a real logical key.** For `id.loyalty` it's `(loyalty_id, source.ts_ms, private_fanid,
   created)` — `(loyalty_id, ts_ms)` alone is insufficient. **PK is inferred**, because the S3 sink
   writes only the Kafka *value*, not the *key* — confirm PKs vs. Cassandra schema (or enable key
   writing in the sink) to be exact.
4. **`is_current`** via `ROW_NUMBER() OVER (PARTITION BY pk ORDER BY src_ts_ms DESC, created_ms DESC,
   ...) = 1`; drop `op='d'` for the current view. Tie-break `created_ms DESC` matches Cassandra
   same-timestamp conflict resolution.
5. **Two Snowflake traps:** inner VARIANT nulls match `IS NULL` for every row → use
   `IS_NULL_VALUE()`; and `LAG` can't nest inside `SUM() OVER` → split into two CTE levels.

(Full DDL for `LOYALTY_CDC_HISTORY` / `LOYALTY_CURRENT` is in the ticket comment — copy verbatim as
the template; generalize the key per table.)

---

## Caveats that shape the migration (do not skip)

1. **No history / no backfill.** Instaclustr won't backfill; CDC only carries changes *after*
   enablement per table. **Initial state must come from a one-time ETL/batch snapshot**, unioned
   with CDC. → The batch DAG can't simply be deleted; it becomes a **seed** (one-time or occasional
   reconciliation), not a daily job.
2. **`tenant_fanid` not CDC-covered yet.** Needs batch until platform adds it (Anna: "big unlock").
3. **`auth` keyspace excluded** from CDC — irrelevant here (our extract only does `id`+`profile`).
4. **Dev has NO CDC** (decommissioned by design). Lower-env pipelines keep batch → the DAG stays
   for dev regardless.
5. **7-day bucket TTL.** Must materialize within 7 days or lose events. Snowpipe/scheduled merge.
6. **Bimodal latency.** p50 2.7 s, p90 7 s, but **0.94% > 1 h, max 2.3 h**. Alert on pipeline lag,
   not row counts (counts look normal during a stall).
7. **File explosion** (see warehouse note above) — raise `rotate.schedule.interval.ms` before prod
   or land via Snowpipe so consumers never scan the raw stage.
8. **`op='i'` ≠ true insert** (Cassandra upserts; `i` = write carried a row marker). Deletes carry
   only PK columns in `after`; tombstones on collections dropped (`behavior.on.null.values=ignore`).
9. **Prod validated only lightly.** BARDSPLAT-31's deep validation was on TEST; confirm prod parity
   (row/op counts vs. a batch snapshot) before cutting over.

---

## Reference RFC: "CDC Approach" (Sandstorm, John Diaz) — Confluence 3467313616

FBG-side analysis of Debezium-CDC→Snowflake landing + transform. Not Cassandra, but the landing/
transform menu maps directly. **What carries over to our Cassandra case:**

**Landing.** The RFC recommends *Snowpipe Streaming via the Snowflake Kafka Connector* for the FBG
Postgres case — but that requires controlling MSK Connect + a connector plugin bump. **Our Cassandra
events already arrive in S3** (Instaclustr's own S3 sink), so Streaming is N/A. Our fit is the RFC's
**Solution B: classic Snowpipe auto-ingest from S3** — storage integration + external stage + `PIPE`
with SQS/SNS notification → `COPY INTO` a native RAW `VARIANT` landing table. The SNS topic already
exists (TF PR #3270). Caveat the RFC flags and we share: **per-file overhead dominates with many
tiny files** (we have 256k) — consider raising the S3-sink rotate interval, but Snowpipe is still
the right shape (land once, never re-scan the stage).

**Transform.** RFC's thesis: stop materializing the parsed layer; two layers (RAW → current-state);
put a cost dial on refresh. Two options:
- *Dynamic tables* (TARGET_LAG, skip-on-idle) — **but `ROW_NUMBER()`/`QUALIFY` is NOT incrementally
  refreshable**; Snowflake silently degrades to FULL refresh. You must express latest-per-key as
  `MAX(order_key) GROUP BY pk` + self-join.
- *Stream + Task MERGE* (recommended for high-churn) — **window functions ARE fine** (they run on the
  stream's change-set, not full history); 2 layers; `record_lsn >` makes it idempotent.

→ **For us, Stream + Task MERGE fits best**, because our dedup inherently needs window functions over
node_id/logical-key, which the dynamic-table path can't do incrementally. (Confirm against how
data-transformations actually does it — Explore in progress.)

**Caveats that transfer (RFC section C/D):**
- **Freshness alert = `MAX(source:ts_ms)` vs `now()`** — RFC calls it "the most valuable alert";
  matches our bimodal-latency concern. Page on it.
- **Deletes:** carry a soft-delete flag through parse, filter in current layer (Cassandra `op='d'`
  carries only PK).
- **Landing-table retention ≥ 1 day** or streams/change-tracking break.
- **Ordering:** Postgres uses `record_lsn = coalesce(source.sequence[1], source.lsn)`. **Cassandra has
  NO lsn** → order by `source:ts_ms` + the node_id/segment dedup (our macro). This is the core
  Cassandra-vs-Postgres divergence, again.
- TOASTed-column caveat is **Postgres-only** — N/A to Cassandra.
- Snowpipe file-based ingest = at-least-once (dupes possible, 14-day filename dedupe) — our RF3 dedup
  absorbs this anyway.

## Parity to the current batch (from durations)

The CDC-covered tables (BARDSPLAT-31 op table) line up almost exactly with the batch **hog list**:
`id.loyalty(_lkp)`, `id.marketing(_lkp)`, `profile.core`, `profile.email(_lkp)`,
`profile.preferences`, `profile.favorites`, `id.partnership(s|_intent)`. i.e. the ~9 tables that
eat the 3.9h are the ones CDC covers — so **CDC directly attacks the exact cost center**, and the
trivial long tail is irrelevant either way.
