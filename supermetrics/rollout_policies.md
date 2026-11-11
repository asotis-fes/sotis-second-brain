# Rollout Policies — Governance, Approvals, Build-vs-Buy, Deprecation, Monitoring

Decided stances (Alex, 2026-10-02) for the Confluence doc sections. These answer the open
items in `confluence_todo.md`. Short decision records are mirrored in `decisions.md` (D-10+).

## Governance — opco isolation  *(STATED GOAL + OPEN)*
- **Goal:** campaigns/data for an opco land **only** in that opco's schema/warehouse (FMX →
  FMX, FBG → FBG, FES → FES).
- **Status:** leave as a **stated goal + open question** — Alex will review the enforcement
  mechanism with the **Supermetrics sales rep + his technical counterpart**. (Candidate
  mechanism = Workspaces per opco with a confined destination — see
  `research.md`; not confirmed natively enforceable yet.)

## Approvals — who can add data sources  *(DECIDED: open adoption, monitor not gate)*
- **Anyone with Supermetrics access can add whatever data sources they want.** No per-source
  approval workflow. Supermetrics is relatively inexpensive and we **want broad adoption**.
- We **do not gate — we monitor.** Two monitoring needs follow:
  1. **Document how we see who is adding what** (and when) via the **Supermetrics API** — in a
     dedicated Confluence section. **Document the endpoints only; do not write the script.**
  2. **Snowflake query** to identify **Supermetrics-ingested sources NOT queried by dbt**
     (unused sources). Point at the Snowflake **query-history** table; **don't write the query
     now**, just identify the source of truth.

## Build vs. Buy — Supermetrics vs. in-house  *(DECIDED)*
- **Use Supermetrics** when there is an **out-of-the-box connector** AND the ingestion **meets
  all our requirements**.
- **Do NOT build custom ingestions via Supermetrics.** We have the **Data Engineering
  resources to build custom ingestion pipelines in Airflow**, so custom/unsupported sources
  stay in Airflow.

## Deprecation — moving existing ingestion to Supermetrics  *(DECIDED)*
- **Default mentality: don't move anything that's stable.** No forced migration.
- **Migrate when** the existing pipeline becomes **difficult to maintain**.
- **Also a trigger:** if the **unified dbt transformations are hard to maintain because the
  Supermetrics schema differs from our custom-ingestion schema**, that friction may motivate
  moving the ingestion over to Supermetrics for consistency. (Schema convergence is a reason,
  not just maintenance pain.)

## Monitoring — unused sources + usage + health  *(DECIDED: weekly Airflow DAG, 3 signals)*
Build a **weekly Airflow DAG** that combines three data points:
1. **Unused sources (Snowflake):** run the query-history-based query to find Supermetrics
   sources ingested but not queried by dbt. (Source: Snowflake query history — don't write the
   query yet.)
2. **Platform usage (Supermetrics API):** who is adding what data sources, and at what times.
   (Document endpoints in Confluence; don't write the script.)
3. **Pipeline health:** transfer run status / failures / lateness. **Confirmed source = the
   Supermetrics Transfer Runs API** (`dts-api.supermetrics.com/v1`, scope `dwh_transfers_read`;
   fields: status {Scheduled/Running/Paused/Success/Error/Cancelled}, rows, duration, date-of-
   data, run-type, error message). **No Snowflake-side health table is confirmed to exist** —
   pull health from the API, not a landing table. See `research.md`.

## Alerting  *(DECIDED, 2026-10-02)*
Separate from the weekly monitoring DAG:
- **Source freshness → Sugarbee** (landing-table staleness alerts).
- **Model failures → dbt tests** (transformation/test failures).
These are the real-time alerting mechanisms; the weekly DAG is the usage/unused-source/health
*review*, not the pager.

## Destinations  *(DECIDED, 2026-10-02)*
**Snowflake only.** Supermetrics will **not** transfer data to any non-Snowflake destination
(no Google Sheets / Excel / Looker Studio / Power BI exports). All consumption is off the
Snowflake warehouse tables.

## Column comments  *(REQUIREMENT for the Confluence doc, 2026-10-02)*
Every landing table **and** every dbt model column carries a description/COMMENT (adopt
Antoine's `persist_docs {relation: true, columns: true}` convention) so the Snowflake catalog
is self-describing end-to-end and agent-readable (Horizon Catalog / Cortex / Claude). **Mark
as a hard requirement** in the doc.

## Licensing — marketer & DE share a license type  *(2026-10-02)*
Because Supermetrics has **no native DE-only role** (see `research.md`),
the **marketer (Builder) and data engineer will use the same license type** for now. There is
**no user-count limit in the contract**, so seat count is not a constraint.
- **Open (under research / for the rep):** can we instead make the **DE** the higher-capability
  profile (add pipelines + manage warehouse connections) and **downgrade the marketer** to only
  modify transfers + add source connectors (no destination-connection management)? Native roles
  may not allow this split — confirming (`research.md`).

## Shared-repo CI  *(DECIDED, 2026-10-02)*
The `dbt-shared-repo` CI job **always reads the PROD source** but **writes to a non-prod
table** to run its checks. We **never duplicate-ingest** the same data across dev and prod —
**for any dbt target, the source reference always points at production.** CI validates
transformations against real prod data while keeping writes isolated to a non-prod location.

## Shared dbt repo starting point — Fivetran OSS models  *(DECIDED — call out in the plan)*
- The **`dbt-shared-repo`** standard transformations **start from Fivetran's open-source dbt
  models**, **converted to run on the Supermetrics schema** instead of the out-of-the-box
  Fivetran schema. This is the explicit starting point for the shared transformation layer.
  (Hub: https://hub.getdbt.com/fivetran/ · example: `fivetran/dbt_facebook_ads`.)
