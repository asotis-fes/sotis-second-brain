# Project Proposal: Evaluate dbt Lake Compute for FES Data transformations

## Summary

dbt Labs has offered us private-beta access to **Lake Compute** — a dbt-native engine
that runs transformation models directly on Apache Iceberg tables in S3, bypassing
Snowflake compute. This proposal is to run a **time-boxed, narrowly-scoped evaluation**
of Lake Compute on a handful of our models to determine *where* it could reduce our
Snowflake compute cost and, just as importantly, *where it should not be used* — not to
adopt it.

## Problem

Snowflake compute is the single largest and most elastic line in our transformation
cost. Our transform layer is ~1,022 dbt models in `dbt-fes-ae`, and the heaviest of them
run on oversized warehouses — **fanflow silver events on a 3XL** (`FDE_DEVELOPER_3XL_WH`),
and Salesforce / Meta Ads / XtremePush integrations and fangraph identity/LTV pipelines on
XL. Every one of those models pays Snowflake warehouse credits to transform data that, in
many cases, lands in S3 as Parquet/Iceberg before and after the transform anyway.

At the same time, the industry is moving toward open table formats: we already run **11
Iceberg tables in production** (Commerce domain, on an AWS Glue catalog, orchestrated via
Airflow), and we read a large external-table surface directly off S3. The architectural
pieces for "transform on the lake" already exist in our stack — we just pay Snowflake to
do the compute.

dbt Labs announced Lake Compute at dbt Summit 2026 and, verbally at the Summit, stated a
target of roughly **50% of equivalent Snowflake compute cost**. That number is not
published anywhere and should be treated as a vendor aspiration, not a commitment — but
the direction is credible enough, and the private-beta offer cheap enough (free during
beta), that *not* evaluating it is a decision to leave a potential structural cost lever
unexamined. The cost of inaction is low-visibility: we keep paying full Snowflake rates
on lake-shaped workloads without knowing whether a materially cheaper path is viable for
us.

## Proposal

Join the Lake Compute private beta and run a **measured head-to-head evaluation** on a
small, deliberately chosen set of models, against pre-agreed go/no-go gates. The goal is a
clear, evidence-backed answer to "which classes of our workloads can run on Lake Compute,
at what real cost, with what correctness and operational trade-offs — and which cannot."

**What Lake Compute actually is** (confirmed from dbt's docs, not the Summit pitch):
a hosted, serverless, **single-node engine built on DuckDB** that reads and writes
Iceberg with no warehouse pushdown. It is designed as a **per-model "sidecar"** — you tag
individual models to run on Lake Compute while the rest stay on Snowflake, all within one
dbt project, one DAG, and one `ref` graph. dbt explicitly positions it as "transformation
only, not a warehouse replacement."

**The honest tension this evaluation must resolve.** The models where we'd save the most
(fanflow silver on 3XL, fangraph identity joins) are **large, join-heavy workloads — which
is exactly what a single-node DuckDB engine is worst at**; dbt lists large two-sided joins
as an explicit non-goal. So the cost-savings prize and the technical-fit sweet spot point
in opposite directions. The sober hypothesis is that Lake Compute fits **small/mid,
append-style staging and consumption models** well and does **not** (yet) fit our
cost-dominant heavy models. The evaluation exists to confirm or refute that per workload
class, not to bet the transform layer on it.

**Why a scoped beta eval and not a bigger commitment.** The product is private beta — no
SLA, breaking changes expected, AWS-only, and (today) coupled to Fivetran's Managed Data
Lake Storage. It uses the DuckDB SQL dialect with no automatic translation from Snowflake
SQL, supports only `append` / `insert_overwrite` incrementals (no merge/upsert), and has
no grants, hooks, or `view` materialization. These are real constraints that bound the
candidate set and make a narrow, reversible trial the only responsible first step.

## Expected Impact

- **Business impact:** If even the small/mid append-style tier proves out, we establish a
  repeatable pattern for shifting lake-shaped transforms off Snowflake credits — a
  structural cost lever rather than a one-time tuning win. If it doesn't, we've spent a
  bounded amount of beta-free time to retire the question with our own data instead of a
  vendor's slide.
- **Operational impact:** The sidecar model means no big-bang migration — individual
  models move and roll back independently inside the existing dbt project. The eval also
  forces us to understand our Iceberg/catalog posture (Glue today vs. the Polaris/Horizon
  path the product needs), which is useful regardless of the outcome.
- **Technical impact:** Produces a reusable parity-and-cost benchmark harness
  (Snowflake-built vs. Lake-Compute-built table) and a documented map of which model
  shapes are portable (no Snowflake UDFs, no merge, no RBAC dependency) vs. not — feeding
  future open-table-format decisions.

## Scope

### In Scope

- Joining the Lake Compute private beta behind the experimental dbt-v2 multi-adapter flag.
- Choosing and standing up a catalog path for the eval — **Snowflake Horizon** (our own
  account, least new surface) or **Fivetran MDLS / Polaris**.
- A candidate set of **small/mid, append-style, Iceberg-friendly models** with no
  merge/upsert, no Snowflake UDFs, and no grants/RBAC dependency (e.g. CRM
  email-engagement tables such as adobe/ses clicks & opens; simple staging/consumption
  transforms).
- A **head-to-head benchmark**: cost (net of S3/catalog/dual-storage/egress), runtime,
  correctness parity, and operational fit — reported against pre-set go/no-go gates.

### Out of Scope

- Any production cutover or decommissioning of Snowflake warehouses.
- Migrating the cost-dominant heavy models (fanflow silver 3XL, fangraph identity joins) —
  flagged as the real prize *only if* single-node scaling is later shown to hold.
- Re-platforming our existing Glue-catalog Iceberg tables.
- Models relying on merge/upsert, Snowflake-native UDFs/ML functions, secure views, or
  Snowflake RBAC on their outputs.
- A detailed Snowflake cost-baseline study — cost is *measured within the eval*, not
  pre-quantified here.

## Owner & Stakeholders

| Role | Name |
| --- | --- |
| Owner | Alex Sotis |
| Stakeholders | FBG Data — Analytics Engineering (dbt-fes-ae owners), Core Data Platform (Iceberg/Glue, S3), DSEA DataOps (Snowflake cost/observability); dbt Labs + Fivetran (beta sponsor) |

## Risks / Open Questions

- **Catalog mismatch (R-1):** Our Iceberg tables are on **AWS Glue**, which the beta does
  **not** list as supported (Fivetran MDLS/Polaris, Snowflake Horizon, limited Databricks
  Unity only). The eval must first pick a catalog path; Snowflake Horizon is the likely
  least-disruptive bridge. *Open question for reviewers: is standing up a second catalog
  acceptable for a trial?*
- **Single-node scaling ceiling (R-2):** DuckDB on one node is the dominant technical
  risk; it is unproven at our data volumes, and our biggest-cost models are large-join
  workloads dbt flags as non-goals. Mitigation: deliberately keep heavy models out of the
  first benchmark and treat scaling as a separate, later question.
- **Feature-parity gaps (R-3):** No merge/upsert, no grants, no hooks, no `view`
  materialization, DuckDB dialect with no Snowflake-SQL translation. Bounds the candidate
  set; the eval documents exactly what's portable.
- **Preview maturity (R-4):** Private beta — no SLA, breaking changes, AWS-only,
  Fivetran-coupled. Keep the trial reversible and behind an experimental flag; nothing
  production-facing.
- **Unconfirmed economics (R-5):** The ~50%-of-Snowflake figure is vendor-verbal and
  unpublished. Our own benchmark is the only number we'll trust; define the minimum real
  savings threshold *before* running it.
- **Downstream reachability (R-6):** Iceberg outputs must stay readable by Snowflake, BI,
  and outbound shares. RBAC/secure-view and share consumers still need the warehouse —
  confirm no consumer is stranded.

## Next Steps

1. **Align on go/no-go gates** with stakeholders — minimum real cost savings, 100%
   correctness parity, runtime within pipeline SLA, no single-node failures on candidates,
   acceptable operational/dual-maintenance burden.
2. **Join the private beta** and confirm the catalog path (Snowflake Horizon vs. Fivetran
   MDLS) and AWS region fit.
3. **Select the candidate model set** (small/mid, append-style, Iceberg-friendly) from
   `dbt-fes-ae` and stand up the experimental dbt-v2 multi-adapter environment.
4. **Build the benchmark harness** — run each candidate on Snowflake and Lake Compute,
   capture cost/runtime, and prove output parity.
5. **Report against the gates** with a per-workload-class recommendation (fits / doesn't
   fit), and a go/no-go on a wider trial.
