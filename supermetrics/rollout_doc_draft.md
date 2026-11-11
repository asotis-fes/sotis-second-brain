# Project Proposal: Supermetrics Rollout (FBG, FMX, FES)

> **DRAFT** (task A1). Template = DATA-space "Template: Project Proposals/RFC" (page 3147891094).
> Decisions authoritative in `decisions.md`; open items in `confluence_todo.md`.
> **Live copy = the Confluence page** (v2, rewritten 2026-10-05 in plain voice, no em-dashes):
> https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3615391778 (id 3615391778, space
> DATA, parent "DEMI Knowledge Articles"). Live-but-flagged DRAFT, not for review yet.
> Pending on the page: attach `images/*.png` diagrams; add Review-Until date + epic; remove
> DRAFT markers to publish. This file mirrors the page; treat the page as source.

---

> **Status: DRAFT, not for review.** Still a work in progress. Decisions and open items aren't final yet.

## Summary

We're putting all three opcos (FBG, FMX, FES) on Supermetrics for marketing and ads ingestion.
Supermetrics lands the raw data into a separate Snowflake schema per opco. A shared dbt repo
then models each source the same way for everyone, ending in one unified marketing metrics
table that looks the same across all three opcos.

## Problem

Today each opco ingests marketing data with its own one-off pipelines. That's expensive to
maintain, inconsistent between opcos, and every new ad source needs data engineering to build it.

Marketers across FBG, FMX, and FES care about the same metrics (spend, impressions, clicks,
ROAS). There's no real reason the models should differ between opcos, but today they do, so we
get divergence and duplicated work.

We're already using Supermetrics, we just don't have a standard for it yet:
- POC started June 2026, driven by FMX Growth.
- FanApp has run Facebook and Google spend in prod since August 2026.
- FBG went live Sep 21, 2026 with the `SUPERMETRICS_FBG` schema (~30 tables).
- Several P&Ls depend on it now, but there's no documented architecture, ownership, or process.
  This doc sets that.

## Proposal

**Landing**
- Supermetrics pulls each source once and drops the raw data into a separate schema per opco
  (FBG, FMX, FES).
- FBG and FMX share the FBG Snowflake account. FES is on its own Snowflake account.
- The diagrams only show Google and Meta, but this applies to any source we pull from Supermetrics.

**Transformations**
- One shared dbt repo (`dbt-shared-repo`) holds the standard transformations for each source.
- We start from Fivetran's open source dbt models and convert them to run on the Supermetrics
  schema instead of Fivetran's.
- Three opco dbt projects (`dbt-ae`, `dbt-ae/fmx`, `dbt-fes-ae`) pull in that shared repo, so
  every source is modeled the same way everywhere.

**Layers (medallion)**

| Layer | What it is |
| --- | --- |
| Source | Raw Supermetrics landing tables |
| Entity | One cleaned table per source |
| OBT | One unified marketing metrics table, same shape for every opco. Grain is one row per ad, per DMA, per day |

Opcos can also have their own sources. The FES Glassdoor/G2 reviews box in the diagram is just
an example of that. We have no plan to actually use it.

**Governance and access**
- Open adoption. Anyone with access can add sources. We don't gate it, we monitor it.
- An opco's data only lands in its own schema. We enforce that with Snowflake grants (each
  opco's Supermetrics service role can only write to its own database and schema), not inside
  Supermetrics.
- Marketers and data engineers share the same license (Editor). Supermetrics has no role that
  lets you manage connections without also being able to add pipelines.
- Everything is set up through Terraform/SSM. No ad hoc SQL.

**Monitoring and alerting**
- Alerts: Sugarbee for source freshness, dbt tests for model failures.
- A weekly Airflow job pulls three things together: unused sources (from Snowflake query
  history), who's adding what (Supermetrics API), and pipeline health (Supermetrics Transfer
  Runs API).

**Catalog**
- Every landing table and model column gets a comment (`persist_docs`), so the catalog
  documents itself.

> [Diagram: data flow, to attach] upstream sources into Supermetrics, out to per-opco landing
> schemas, then entity tables, then the unified metrics OBT. FES also shows its own reviews OBT.
> [Diagram: shared transformations, to attach] `dbt-shared-repo` feeding `dbt-ae`, `dbt-ae/fmx`,
> and `dbt-fes-ae`.

## Expected Impact

| Area | What changes |
| --- | --- |
| Business | Same metrics across all three opcos. Marketers self serve faster. Cost is predictable: flat annual, no per row charges, about $40k/yr to start. We picked it over Funnel, which was consumption priced. |
| Operational | A lot less one-off pipeline maintenance. Supermetrics maintains the connectors when a source API changes. One onboarding and monitoring process, one owner. |
| Technical | One shared transformation layer instead of a model per opco. Snowflake only. A catalog that documents itself. |

## Scope

**In scope**
- Generic marketing sources (Google, Meta, anything with an out of the box connector that meets
  our needs) across FBG, FMX, FES.
- The shared dbt repo and the three opco projects.
- The unified metrics OBT and the per source entity tables.
- The governance, approvals, build vs buy, deprecation, provisioning, and monitoring process.

**Out of scope**
- PII and CRM user level data (XtremePush). That's a separate project.
- Custom Supermetrics connectors. If there's no out of the box connector, we build it in Airflow.
- Any non Snowflake destination (Sheets, Excel, Looker, Power BI).
- Forcing stable existing pipelines onto Supermetrics. We only move one if it gets painful to maintain.

## Owner and Stakeholders

| Role | Name |
| --- | --- |
| Owner | Alex Sotis, single POC across FBG, FES, FMX |
| dbt modeling | Alex Sotis, Ryan Knapp |
| Analytics Engineering (owns schema drift) | Bhumika Kansal and AE team |
| Data Engineering | Brett Pendleton |
| FMX Growth (requestors) | Mona Thiele, Antoine Lamy |
| FBG Analytics Engineering | Koushik and team |
| DSEA leads | Maddy Want |

## Risks and Open Questions

- We can't lock an opco to one destination inside Supermetrics (workspaces only isolate assets,
  not destinations). We handle it with Snowflake grants instead. Still want to ask the vendor if
  they have any guardrail on their side.
- No Supermetrics role manages connections without also being able to add pipelines, so
  marketers and DEs share the Editor role for now. We'll ask the vendor about a finer split.
- Some FMX flights run under the Sportsbook and DV360 advertiser accounts, so splitting by opco
  schema doesn't catch those on its own. We need a transfer level split or a small routing step.
- Cloning a connector to another opco reuses the same `schema_id` with a different account list.
  Need to confirm that actually gives us identical columns.
- Still open: how the three projects pull in the shared repo (dbt package vs Mesh), the OBT
  column list, naming across opcos, and the two Snowflake account setup.
- Cost: flat annual with a 100M rows per month soft cap (no seat cap). We need to watch volume
  and confirm who owns the bill.
- Mona's five vendor questions are still open: granularity past daily/DMA/ad, email only
  sources, attribution writeback, pricing for scope 1 vs everything, and adding sources later.
  We'll work them one at a time.

## Next Steps

- Lock down the open design items (OBT columns, how we share the repo, naming).
- Get the vendor questions answered.
- Build `dbt-shared-repo` from the Fivetran models. Per opco order: sources, then staging and
  entity, then OBT, then cut over the legacy pipelines (inventory the consumers first).
- Build the weekly monitoring job and wire up the Sugarbee and dbt test alerts.
- Clean up this page (attach the diagrams, add a review date and the epic) and publish it.
