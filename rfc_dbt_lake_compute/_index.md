# rfc_dbt_lake_compute — RFC: evaluating dbt Labs "Lake Compute"

> **Standing directive:** Keep these files updated as work progresses; treat them as
> the source of truth across sessions. Nothing under `projects/` is ever committed.

## Goal

Write an **RFC / Project Proposal** (FBG Data Project Proposal/RFC template → see the
`rfc-writer` skill) proposing that the team **evaluate dbt Labs' newly announced
"Lake Compute"** — dbt's first native compute offering for running the transformation
layer.

### What Lake Compute is (as framed)

dbt Lake Compute lets transformations run **on dbt's own compute against data that stays
in S3 as Iceberg tables** — read Iceberg, transform, write back to other Iceberg tables —
**bypassing Snowflake compute cost** for those models. The data never has to move into
Snowflake warehouses to be transformed.

### What this RFC must deliver

The RFC is a **decision-support document**, not an implementation plan. It should:

1. **Motivate the evaluation** — why Lake Compute is worth our time (the Snowflake
   compute-cost angle, Iceberg/S3 architecture fit, where our spend concentrates).
2. **Define what we need to pressure-test** — the concrete questions and risks that
   decide whether this is viable for us.
3. **Define what we need to measure** — the metrics/benchmarks that would tell us
   *where* it can be used vs. *why it should not be used*.
4. Land on a recommendation framing: a scoped evaluation plan, not a commitment to adopt.

## Table of Contents

- `_index.md` — this file (context + TOC)
- `findings.md` — facts gathered: Lake Compute capabilities/limits, our current
  Snowflake/dbt/Iceberg footprint, cost baseline, comparable prior art
- `plan.md` — RFC outline + the pressure-test questions and the measurement plan
- `decisions.md` — scoping decisions, assumptions, open questions for reviewers
- `progress.md` — session log / what's done vs. open

## Key open questions (seed list — refine as we learn)

- **Product reality:** What exactly did dbt Labs announce (GA vs. preview), pricing
  model, supported adapters/engines, Iceberg catalog support (Glue? Polaris? Unity?),
  SQL dialect/feature parity with our current dbt models.
- **Architecture fit:** Our lake already uses Iceberg on S3 (confirm catalog + where).
  Which models could physically run on Iceberg-in / Iceberg-out without a Snowflake
  round-trip? Which can't (Snowflake-only functions, cross-DB joins, shares)?
- **Cost model:** What is our Snowflake transform spend today, and how would Lake
  Compute pricing compare? Egress / dual-storage / catalog costs to account for.
- **Correctness & parity:** How do we prove a Lake-Compute-built table is identical to
  the Snowflake-built one (row/column/precision parity)?
- **Operational fit:** Scheduling (dbt Cloud vs. Airflow), observability, lineage/Mesh
  integration, access control on Iceberg vs. Snowflake RBAC.
- **Downstream reachability:** If a model's output lives as Iceberg in S3, can Snowflake
  (and our shares/BI) still read it, or does it strand consumers?

## Status

Phase 0 (setup) complete. **No doc/code links ingested yet.** Next: Phase 1 discovery —
pull the dbt Labs Lake Compute announcement/docs, and inventory our Iceberg/S3 + Snowflake
transform footprint — once the user provides links or green-lights research.
