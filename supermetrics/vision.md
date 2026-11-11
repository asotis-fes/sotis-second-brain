# Target Vision — Supermetrics across FBG / FMX / FES

Alex's high-level target architecture, from the two diagrams in `images/` + narrative
(2026-10-02). This is the **north star** the Confluence doc will describe. Diagrams:
`images/supermetrics_data_flow.png`, `images/supermetrics_github_shared_transformation.png`.

## Core idea
Supermetrics ingests marketing/ads data once, then **lands raw data into a separate schema
per operating company** (FBG, FMX, FES). A **shared dbt repo** holds the standard, source-level
transformations (Google Ads, Facebook Ads, … — **any** generic Supermetrics source), and **three
per-opco dbt projects** consume that shared repo to build each opco's models. Output per opco
is a **unified marketing-metrics OBT** plus per-source entity tables.

## Landing / warehouses (source layer)
- Supermetrics drops **raw** data into **per-opco schemas**: `FBG Source`, `FMX Source`,
  `FES Source`.
- **Snowflake-account grouping (per diagram):** `FBG Source` + `FMX Source` live in the **FBG
  Snowflake** account; `FES Source` lives in a **separate FES Snowflake** account. → Two
  Snowflake accounts, three source schemas. *(Confirm this grouping is intended.)*
- The diagram shows only **Google Ads Raw** and **Facebook Raw** as examples — the doc will
  state this pattern applies to **any generic source** ingested from Supermetrics.

## Transformations (shared repo + three projects)
- **`dbt-shared-repo`** — the standard per-source transformations, maintained once, so Google
  Ads / Facebook Ads / etc. are modeled identically everywhere.
- Consumed by **three opco dbt projects**: `dbt-ae` (FBG), `dbt-ae/fmx` (FMX), `dbt-fes-ae`
  (FES). Each runs the shared transformations on its own opco's source data.

## Medallion layering
1. **Source layer** — raw Supermetrics landing tables (per-opco schema).
2. **Entity tables** (consumption) — **one table per source** (e.g. `Google Ads`,
   `Facebook Ads`), cleaned/standardized via the shared transformations.
3. **OBT / "one big table"** (consumption) — a **Unified Marketing Metrics** table per opco.
   Rationale: marketers care about the **same metrics** (clicks, impressions, ROAS, …); there
   is **no opco-specific business logic** and the ad-source data (Google/Facebook) is **not
   tied to individual customer records**, so the metric model **should not diverge across
   opcos**. Same OBT shape for all three.

**Grain (Mona's requirement):** entity tables and the OBT are built at **daily × DMA ×
ad-level** granularity (plus the standard metrics: spend, impressions, clicks, platform KPIs
like installs/registrations). DMA must be preserved, not collapsed to campaign/day. The OBT
can aggregate up from this base grain but the base grain is daily × DMA × ad.

## Per-opco source divergence (the Glassdoor/G2 example)
- Not every Supermetrics source is used by all three opcos. The FES side shows **Glassdoor
  Reviews + G2 Reviews → `FES Reviews OBT`** purely as an **illustrative example** of an
  opco-specific source + a non-marketing OBT.
- **No current plan** to actually use Glassdoor or G2 — example only.

## How this squares with earlier context
- **Reinforces D-1** (per-opco separation) and sharpens it: separation is at the **schema +
  warehouse** level, unified by a **shared transformation repo** — not separate ad-hoc models.
- **⚠️ Diverges from Antoine's FBG handoff plan** (`antoine_handoff.md`): that doc puts
  **FBG, FMX, SBK, Casino all in one `FBG_SOURCE.SUPERMETRICS_FBG` schema** and resolves
  **brand in dbt**. Alex's vision instead gives **FMX its own schema** (separate from FBG).
  These are two different scopings of "FMX" (opco-schema vs brand-in-FBG). **Must be
  reconciled** before the doc is final — see `confluence_todo.md`.
- **D-2 (Fivetran OSS):** vision is agnostic on whether the shared repo starts from Fivetran
  packages or is hand-rolled; the "shared standard transformations" goal is compatible with
  either. Antoine's FBG plan hand-rolls.
