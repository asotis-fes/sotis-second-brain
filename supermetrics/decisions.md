# Decisions — Supermetrics Rollout  ·  SOURCE OF TRUTH

**This is the final decision log. Where any other project file disagrees, this file wins.**
Append as D-N with date + rationale; supersede (don't delete) when a decision changes.
Current through D-20 (2026-10-02). D-1 is historical (refined by D-7).

## D-1 — Generic model, per-opco source separation (2026-09-22) — REFINED by D-7
Shared repo for a generic marketing model, **separate tables per opco**, because opco
ingestion must be separated to different sources. New consumption layer for typical metrics
(spend, clicks, …). _Source: Alex, #dsea-leads._ **See D-7 for the sharpened architecture
(separation at schema+warehouse level, unified by a shared dbt repo).**

## D-2 — Start from Fivetran OSS dbt packages (2026-09-22)
Use Fivetran's open-source dbt models (pre dbt-merger) as the starting point for the generic
marketing models, adapting them to the schema Supermetrics provides. Hub:
https://hub.getdbt.com/fivetran/ · example: `fivetran/dbt_facebook_ads`. _Source: Alex._
**Caveat (from RFP answers):** Supermetrics output is already harmonized/denormalized (no raw
source-shaped feed), while Fivetran packages assume source-shaped input — so our dbt is a
**consumption/mart layer**, and Fivetran reuse is partial. Validate landing-table shape first.
**Confirmed (2026-10-02):** the **`dbt-shared-repo` standard transformations START from the
Fivetran OSS models, converted to run on the Supermetrics schema** (not the OOTB Fivetran
schema). Call this out explicitly in the plan/Confluence doc. _Source: Alex._

## D-3 — Don't pause building on POC (2026-09-22)
Even with VMO-2475 pending signature, teams keep building. Contract will go through; data is
real and usable; the POC account rolls into the paid one so data keeps flowing.
_Source: Alex, confirmed by Maddy._

## D-4 — Single POC across opcos (2026-09-22)
Alex is the main point of contact for Supermetrics across FBG, FES, and FMX. DE/AE work still
split within DEMI; **Alex + Ryan Knapp tag-team the dbt model** work; Brett Pendleton
finalizing DE ownership. _Source: Bhumika proposed, Alex accepted._

## D-5 — 100% Terraform/SSM provisioning, no ad-hoc SQL (standing)
The POC account becomes prod, so provision everything via Terraform/SSM from day one — no
ad-hoc SQL setup. _Source: team memory `project_supermetrics_no_poc_shortcuts`._

## D-6 — Supermetrics chosen over Funnel (pre-project, ratified by signing)
Vendor selection was Supermetrics vs Funnel. Supermetrics won on **cost predictability** (flat
annual, 100M rows/mo soft cap, ~$40k/yr baseline) despite being **modeled/denormalized-only**
(Funnel offered raw+modeled and mid-flexibility via Flexpoints but consumption-priced, 12-mo
min, no mid-contract downsize). Contract signed (Mona's thread). _Source: RFP comparison sheet._

## D-7 — Per-opco schemas/warehouses + shared dbt transformation repo (2026-10-02)
Supermetrics lands **raw data into a separate schema per operating company** (FBG, FMX, FES);
a **shared dbt repo** (`dbt-shared-repo`) holds standard per-source transformations, consumed
by **three per-opco dbt projects** (`dbt-ae`, `dbt-ae/fmx`, `dbt-fes-ae`). Pattern applies to
**any** generic Supermetrics source (Google/Facebook are diagram examples only).
_Source: Alex's vision diagrams + narrative. Supersedes the looser D-1 wording._
⚠️ **Divergence to reconcile:** Antoine's FBG handoff plan puts FBG/FMX/SBK/Casino in one
`FBG_SOURCE.SUPERMETRICS_FBG` schema with brand resolved in dbt — the opposite at the storage
layer. See `vision.md` + `confluence_todo.md`.

## D-8 — Medallion: source → per-source entity tables → unified OBT (2026-10-02)
Layering: (1) **source** = Supermetrics raw landing; (2) **entity tables** (consumption) = one
per source; (3) **OBT** (consumption) = a **Unified Marketing Metrics** table. The OBT schema
is **identical across opcos** — marketers care about the same metrics (clicks, impressions,
ROAS), there's no opco-specific business logic, and ad-source data isn't tied to individual
customer records, so it should not diverge. Opco-specific sources are allowed (FES
Glassdoor/G2 → `FES Reviews OBT` as an illustrative, not-currently-planned example).
_Source: Alex._

## D-9 — Alex's vision supersedes Antoine's FBG handoff doc (2026-10-02)
Where the two conflict, **our direction (D-7/D-8, `vision.md`) wins**. Antoine's doc is kept as
reference — its mechanics (spend-fact/allocation rule, catalog COMMENTs, backfill safety,
manual-spend sheet, tests, Terraform-only) are adopted into our shared standards. Conflicts +
meeting talking points live in `antoine_handoff.md` (Part 2).
_Source: Alex, 2026-10-02._ This resolves the FMX-scoping tension previously flagged as open:
**per-opco schema wins** over brand-in-dbt — with one caveat still to raise with Antoine:
genuinely **shared advertiser accounts** (FMX flights under SBK/DV360 advertisers) may still
need a thin routing step. See difference #1.

## D-10 — Approvals: open adoption, monitor not gate (2026-10-02)
Anyone with Supermetrics access can add any data source — **no per-source approval**
(Supermetrics is cheap, we want adoption). We **monitor** instead: (a) Supermetrics API shows
who adds what/when; (b) Snowflake query identifies ingested-but-unused sources. _Source: Alex._
Detail: `rollout_policies.md`.

## D-11 — Build vs buy (2026-10-02)
Use Supermetrics when an **out-of-the-box connector exists AND meets all requirements**.
**No custom Supermetrics connectors** — custom/unsupported ingestion stays in **Airflow** (we
have the DE resources). _Source: Alex._

## D-12 — Deprecation: no forced migration (2026-10-02)
Default: **leave stable pipelines alone.** Migrate to Supermetrics when the existing pipeline
is **hard to maintain**, OR when **schema divergence between our custom ingestion and
Supermetrics makes the unified dbt transformations hard to maintain**. _Source: Alex._

## D-13 — Monitoring: weekly Airflow DAG, 3 signals (2026-10-02)
Weekly Airflow DAG combining: (1) **Snowflake query history** → Supermetrics sources not
queried by dbt; (2) **Supermetrics API** → who added what/when; (3) **pipeline health**
(transfer status/failures, source TBD). Confluence documents **API endpoints + the Snowflake
query-history table** — we **don't write the script/query now**. _Source: Alex._

## D-14 — Governance isolation left OPEN for the vendor (2026-10-02)
Opco isolation (FMX data only in FMX schema, etc.) stays a **stated goal + open question**;
enforcement mechanism to be confirmed with the Supermetrics rep + technical counterpart. See
`research.md` Part 1 (workspace destination confinement not natively confirmed → enforce via
Snowflake grants). _Source: Alex._

## D-15 — Snowflake-only destinations (2026-10-02)
Supermetrics transfers to **Snowflake only** — no Sheets/Excel/Looker/Power BI. _Source: Alex._

## D-16 — Entity + OBT grain = daily × DMA × ad (2026-10-02)
Base grain of entity tables and the OBT is **daily × DMA × ad-level** (Mona's requirement),
with standard metrics (spend, impressions, clicks, installs/registrations). DMA preserved.
_Source: Alex + Mona scope doc._

## D-17 — Column comments required (2026-10-02)
Every landing table + dbt model column carries a description/COMMENT (`persist_docs
{relation:true, columns:true}`) for an agent-readable, self-describing catalog. **Hard
requirement** in the Confluence doc. _Source: Alex (adopting Antoine's convention)._

## D-18 — Shared-repo CI reads prod source, writes non-prod (2026-10-02)
`dbt-shared-repo` CI always **reads the PROD source** and **writes to a non-prod table**; no
duplicate dev/prod ingestion — **for any dbt target the source reference points at production.**
_Source: Alex._

## D-19 — Alerting split: Sugarbee + dbt tests (2026-10-02)
**Source freshness → Sugarbee; model failures → dbt tests.** (Distinct from the weekly
monitoring DAG, which reviews usage/unused-sources/health.) _Source: Alex._

## D-20 — Marketer & DE share a license type (2026-10-02)
No native DE-only role, so **marketer (Builder) and DE use the same license type**. **No
user-count limit** in the contract → seats not a constraint. Possible downgrade of the marketer
profile (transfers + connectors only, no destination mgmt) is **under research / a vendor
question**. _Source: Alex._

## Vendor feedback 2026-10-15 — impact on decisions (see feedback/feedback_analysis_2026-10-15.md)
- **D-14 / research (destination lock): OVERTURNED in our favor.** Locking an opco to one
  destination IS possible natively via **workspaces** (a transfer can't write to another
  workspace's destination). Plan = **workspace-per-opco + Snowflake grants = two layers.**
- **D-20 (marketer+DE share Editor): OVERTURNED.** A finer split exists: **Viewer** can
  add/reconnect its own connections but not create transfers; **Editor** does both. So
  marketers can be **Viewer** (own auth/connections, request transfers), DE/AE = **Editor**
  (own transfers/destinations/backfills). **DECISION PENDING** (role model) — vendor + Brock
  recommend the split. Conflicts with D-10's "marketers add transfers" wording.
- **D-16 (grain daily×DMA×ad) + D-8 (single OBT): MODIFIED.** Ad-level DMA isn't available for
  every source (Google Ads + X Ads = ad-group finest; Meta = Comscore market needing a →DMA
  map). **DECISION PENDING**: (a) one OBT, DMA nullable + `geo_grain` col, or (b) two OBTs
  (ad×day + geo×day). Vendor + Brock lean (b).
- **D-5 (Terraform/SSM): MODIFIED.** True for Snowflake only; Supermetrics has no TF provider →
  config via **Management API scripts in the repo** (batch create/clone/table-group/secret
  rotation) + SDK/CLI. Reword accordingly.
- **D-17 (column COMMENTs): REFINED.** Landing tables rebuild on schema change (grants+comments
  reset) → use **future grants** on the landing schema + keep **`persist_docs` on dbt models,
  not raw tables**.
- **D-19 (alerting): REFINED.** No load-timestamp column → **Sugarbee freshness keys on
  `max(date)`** (or Transfer Runs API).
- **D-13 (monitoring): REFINED.** "Who added what" isn't exposed by the API → weekly **transfer-
  list diff** gives "what changed," not "who" (attribution = product request).
- **D-11 (build vs buy): SOFTENED.** Leave a door open for **Connector Builder + documented
  API** as an alternative to a new Airflow DAG; we still own connector config on vendor changes.
- **New build constraints (confirmed):** clone via same `data_source`+`schema_id` gives
  identical columns (API clone currently errors for Meta/Google → use Hub clone); **one
  destination per opco schema**, each with its own Snowflake user+role+key-pair; dbt
  incrementals **delete+insert on date** with lookback ≥ refresh window; **never drop the
  transfer `Date` field**; **Google installs = own transfer**; FMX shared-account routing done
  in **staging** keyed on campaign naming (GA `7826216690`, ASA `7708200`, DV360 `1224948634`).

## Open (not yet decided)
- All 4 opcos in one mart vs separate marts (Maddy's question).
- Landing-schema naming convention (`SUPERMETRICS_FBG` flagged confusing).
- Document home/format (Confluence RFC vs other).
- Whether XtremePush user-level data comes via Supermetrics or existing Segment/XP path.
