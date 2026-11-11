# Plan — CDC Materialization (supersedes the token-range plan)

**Direction (D-6):** Make the **daily driver an incremental CDC materialization** from the prod
Snowflake stage `@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD`. Retire the 5h full snapshot. Batch survives
only as: one-time historical **seed**, **dev** ingestion, and **`tenant_fanid`** until CDC covers it.
Token-range work is PARKED (D-1/D-6).

See [cdc_investigation.md](cdc_investigation.md) for all source docs, stage names, Anna's SQL, caveats.

## Target architecture (to confirm against repo patterns — see M1)

```
Debezium → CDC Kafka → S3 sink → S3 (identity-cdc-fes-prod, 7-day TTL)
  → Snowflake external stage @FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD (JSON gz)
    → [land] raw CDC events into a Snowflake table   (Snowpipe or scheduled COPY — beat the 7-day TTL)
      → [dbt incremental] parse Debezium envelope + dedup RF3×re-read → per-table CURRENT (+ HISTORY)
        → union with one-time SEED (batch snapshot) for pre-CDC history
          → existing tag:identity consumption contract (match grain/columns)
```

Two big open design choices (M1 resolves via repo patterns):
1. **Land-then-model vs. external-table-in-place.** Raw stage is 28k tiny files → scanning it
   directly needs a Large WH; landing via Snowpipe/COPY into a table is cheaper and dodges the
   7-day TTL. Lean **land-then-model** unless the repo's `debezium_cdc` pattern says otherwise.
2. **Where the transform lives.** Prefer **dbt** (matches the existing `debezium_cdc` pattern in
   data-transformations + the identity dbt Cloud job already in the DAG) over bespoke Airflow SQL.

## Milestones

- **M0 — Setup + sizing** ✅ (found: many-medium-tables, not one hog; D-3).
- **M1 — Reuse + contract mapping** (in progress via Explore)
  - Map the existing `data_transformations/.../debezium_cdc/` dbt pattern (sources, envelope parse,
    dedup macro, incremental strategy, current-vs-history grain, seeding).
  - Map the current `tag:identity` models + their cassandra S3 source definitions → the **contract**
    (columns/grain) the CDC output must satisfy so downstream doesn't change.
  - Extract per-table **primary keys** (dedup logical key) from schema/DDL.
- **M2 — Confirm prod CDC is flowing + parity**
  - Read-only: `DIRECTORY(@FDE.FDE_STAGE.IDENTITY_CDC_FES_PROD)`; distinct `$1:source:table` + counts
    (Large WH). Confirm which of the hog tables are actually present in prod now.
  - Op/row-count parity vs. a batch snapshot for 1-2 tables (start with `id.loyalty`, `profile.core`).
- **M3 — Build**
  - Landing (Snowpipe or scheduled COPY) → raw CDC table(s).
  - dbt: reusable CDC parse+dedup macro (node_id from segment runs; logical key per table;
    `is_current`; `IS_NULL_VALUE()`; two-level `LAG`/`SUM OVER`); per-table incremental models
    (CURRENT grain, HISTORY optional); union with seed.
  - One-time seed from a batch snapshot; repoint `tag:identity` consumers.
  - `tenant_fanid` + dev stay on batch.
- **M4 — Validate & ship**
  - Prod parity check; freshness alerting on **pipeline lag** (not row counts — bimodal latency).
  - Labeled PR(s). (Repo TBD: dbt models likely dbt-fes-ae; stage/Snowpipe TF in fanapp-terraform.)

## Guardrails / constraints
- Snowflake SELECT-only until an explicit change is approved; no prod data mutation.
- CDC has **no backfill** → never drop the seed path; document it.
- Dedup key `(file,pos)` is NOT global — must cluster node_id first (D-6 / Anna).
- PK is inferred (sink writes value only) — confirm per table before trusting the dedup key.
- Alert on lag; 7-day TTL is a hard materialization deadline.

## Open questions
- Landing mechanism: Snowpipe (auto, needs the SNS topic from TF PR #3270) vs. scheduled COPY in the DAG?
- Do we keep HISTORY grain, or CURRENT-only to match today's snapshot semantics?
- Which repo owns the dbt models (dbt-fes-ae vs fes-airflow/dags/dbt)? (M1 answers.)
- Seed cadence: truly one-time, or periodic reconciliation to catch the "missing from all 3 nodes" gap?