# Plan — RFC outline + evaluation design

The deliverable is a Confluence RFC using the FBG Project Proposal/RFC template
(`rfc-writer` skill). This file drafts its structure and the two things the user
explicitly wants nailed: **what to pressure-test** and **what to measure**.

## RFC document outline (map to the template; finalize with rfc-writer)

1. **Summary / Problem** — Snowflake compute is our transform-layer cost driver; dbt
   Lake Compute offers Iceberg-in/Iceberg-out transforms on dbt's compute, potentially
   bypassing that cost. Propose a time-boxed evaluation.
2. **Background / Context** — our Iceberg-on-S3 + Snowflake + dbt Mesh architecture;
   what dbt Labs announced.
3. **Motivation** — why evaluate now (cost, Iceberg momentum, strategic optionality).
4. **Proposed evaluation** — scope, candidate workloads, success criteria.
5. **What we must pressure-test** (see below).
6. **What we must measure** (see below).
7. **Risks & non-goals** — what would make us walk away.
8. **Recommendation / next steps** — go/no-go gates.
9. **References.**

## What to pressure-test (viability questions)

- **Feature/SQL parity** — do our models compile and run on Lake Compute's engine
  without Snowflake-specific functions, UDFs, or cross-database joins?
- **Iceberg catalog compatibility** — does it read/write our catalog (Glue/Polaris/
  Unity) and partition/snapshot layout?
- **Correctness/parity** — bit-for-bit (or tolerance-bounded) equivalence vs. the
  Snowflake-built table: row counts, column values, types/precision, NULL handling.
- **Downstream reachability** — can Snowflake, BI, and outbound shares still consume an
  Iceberg output, or does it strand consumers?
- **Mesh/lineage integration** — does it fit dbt Mesh, lineage, and our deploy jobs?
- **Orchestration** — dbt Cloud vs. Airflow scheduling; retries, backfills, incremental.
- **Access control** — Iceberg/S3 RBAC vs. Snowflake grants; PII handling.
- **Operational maturity** — GA vs. preview, SLAs, failure modes, observability.

## What to measure (the benchmark plan)

- **Cost per model** — Lake Compute $ vs. Snowflake warehouse credits for the same build,
  including S3/egress/catalog/dual-storage costs.
- **Runtime** — wall-clock per model and per pipeline vs. Snowflake baseline.
- **Scale behavior** — small vs. large tables; full-refresh vs. incremental.
- **Correctness** — parity pass rate across the candidate set.
- **TCO at projected volume** — extrapolate to monthly spend if N models move.
- **Operational cost** — engineering effort to migrate + maintain a dual pattern.

## Evaluation scope (refined after 2026-10-21 research)

- **Join the private beta** (offered to us) behind the dbt-v2 experimental flag; pick a
  catalog path first — **Snowflake Horizon** (our own account, least new surface) vs.
  **Fivetran MDLS/Polaris** (new dependency). Glue (what we use today) is NOT a beta
  option — call this out.
- **Candidate set = small/mid, append-style, no-merge, no-UDF, no-RBAC-dependency
  models** that are already/easily Iceberg — e.g. CRM email-engagement (adobe/ses
  clicks/opens), simple staging/consumption transforms. **Deliberately exclude** fanflow
  silver 3XL and fangraph identity joins from the first benchmark (single-node + large-
  join non-goal) — but note them as the real prize if scaling ever proves out.
- Run **Snowflake-vs-Lake-Compute head-to-head** on the candidate set; measure the plan
  metrics above; prove parity; report against pre-set go/no-go thresholds.
- **Decision framing:** go/no-go is per-workload-class, not all-or-nothing. Likely
  outcome space: "fits for cheap append-style staging" vs. "doesn't yet fit our
  cost-dominant heavy models."

## Go/no-go gate candidates (set thresholds with reviewers)

- Cost delta ≥ X% real savings (net of S3/catalog/dual-storage/egress) at our volume.
- 100% correctness parity on the candidate set.
- Runtime within YSec/pipeline SLA; no single-node OOM/scaling failures on candidates.
- Operational: fits Mesh/lineage + our orchestration without a dual-maintenance burden
  we won't accept.
