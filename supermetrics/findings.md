# Findings — Supermetrics Reference Facts

> Durable reference (read on demand): vendor capabilities, scope, pricing, stakeholders, source
> artifacts. **Architecture lives in `vision.md`; decisions in `decisions.md` (source of
> truth); open items in `confluence_todo.md`.** This file is facts, not decisions.

## What Supermetrics is / why

Marketing & ads **data-ingestion platform** — pulls spend/impressions/clicks + platform KPIs
from ad networks, affiliate, and CRM into Snowflake. Chosen over **Funnel** (an RFP
comparison "Funnel vs Supermetrics" exists in Drive). Replaces/standardizes bespoke per-opco
ingestion of ads data.

## Scope (from Mona Thiele's "Fanatics x Supermertrics" doc)

Day-one granularity requirement: **daily × DMA × ad-level**, metrics = spend, impressions,
clicks, + platform-specific KPIs (installs, registrations, etc.).

### Scope 1 — FMX (immediate / day-one)
- **Paid media:** Apple Search Ads, Google Ads (Search/UAC/Display/YouTube), Meta, Reddit,
  Snapchat, TikTok, Twitter/X
- **Affiliate:** Impact
- **CRM:** XtremePush (ingest email-campaign + user-level data)

### Extended scope (future — for Fanatics-wide rollout planning)
- **FBG additional paid media:** Cognitiv, Genius, Spotify, Google CM360 (ad server)
- **FBG app networks:** Aadikteev, Aarki, Amazon, InMobi, Liftoff, Mobupps, Moloco, Rokt,
  Smadex/Entravision, Taboola, TVScientific, Vibe
- **FanApp:** Google + Meta initially → full list over time

### Open questions raised to Supermetrics (vendor)
1. Granularity beyond daily × DMA × ad — what other breakdowns?
2. Non-API sources — can they ingest app networks that only deliver via **email reports**?
3. Backend attribution — can we send our own attribution data back in for BI reporting?
4. Pricing — Scope 1 only vs full Fanatics-wide rollout; is a 2nd connection to an
   already-integrated platform (e.g. separate Meta account) turnkey?
5. Adding sources later — onboarding a new source 2–3 months post-launch?

## POC → prod state (from #dsea-leads thread, 2026-09-22, Bhumika's summary)

- Started as a **POC in June 2026**, driven by **FMX Growth**.
- **FanApp** has run **Facebook + Google spend in prod since August 2026**.
- **FBG side went live 2026-09-21** with a new **`SUPERMETRICS_FBG`** landing schema —
  ~**30 tables** already loading from Meta, Google, Reddit, Snapchat, Apple, others.
- Naming convention flagged as potentially confusing (esp. for FMX) — `SUPERMETRICS_FBG`.
- FBG marketing + Ads team have accounts; **FMX asking who owns the dbt modeling + by when**.
- Multiple P&Ls now depend on it → Alex made **single POC** across FBG/FES/FMX.
- Contract **VMO-2475 pending signature** as of 2026-09-22 (Blume said DocuSign signed, ticket
  still showed "pending"). Alex's call: **do not pause building** — contract will go through,
  data is real and usable now. POC account rolls into the paid one so data keeps flowing.

> **Data-model approach:** see `vision.md` (per-opco schemas + shared dbt repo + medallion
> source→entity→OBT) and `decisions.md` D-1/D-2/D-7/D-8. Key fact that shaped it: Supermetrics
> output is **harmonized/denormalized** (no raw source-shaped feed; transforms run vendor-side
> before load), so our dbt is a **consumption/mart layer**, and the Fivetran OSS packages
> (built for source-shaped data) are **partially** reusable — adapt to the Supermetrics schema.

## Stakeholders (from Mona's earlier thread #C09QF3QA798 + #dsea-leads)

- **Mona Thiele** — FMX marketing; drove the POC, authored the scope doc; building an
  **interim FMX marketing spend table** to unblock her pipelines until the model lands.
- **Antoine Lamy** — FMX marketing (with Mona).
- **Alex Sotis** — main driver / single POC for all things Supermetrics across FBG/FES/FMX.
- **Ryan Knapp** — tag-teams the **dbt model** work with Alex (per Bhumika).
- **Brett Pendleton** — Data Engineering (finalizing ownership internally).
- **Bhumika Kansal** — Analytics Engineering lead voice in the thread.
- **Maddy Want** — DSEA leads; asking data-model structure questions.

## Vendor capabilities (from "Bet Fanatics - Supermetrics - RFP Answers")

- **Delivery model:** managed pipeline; extraction + harmonization + transformation run
  vendor-side before load. Output is **harmonized/denormalized only** (no raw/normalized
  feed). You can define which schemas load and have multiple schema/delivery methods per
  source. Unified marketing field naming across sources (spend, impressions, clicks,
  conversions) + pre-built cross-source blends.
- **Restatements:** auto re-sync of **configurable lookback windows** (handles platforms
  revising trailing 7–28 days of conversions) — no manual reloads. Handles currency
  conversion, time-zone + date normalization across sources.
- **Reliability:** automatic failed-sync retries with monitoring + notification on ultimate
  failure. Manages source-API rate limits/quotas + OAuth refresh on our behalf; notifies via
  email on quota/auth issues.
- **Alerting channels:** Email, Slack (channel email/hook), Teams (channel email/hook).
- **Multi-team:** workspaces/teams with RBAC; multiple warehouse/destination connections in
  one account; control who connects which sources / exports where. Scales to many ad accounts
  across brands.
- **Destinations:** Snowflake, BigQuery, Redshift, Azure Synapse; BI (Looker Studio, Power
  BI); Sheets/Excel; data/storage API. Same pipeline can feed multiple destinations →
  business users self-serve while engineering gets warehouse tables.
- **AI/NL access:** AI agents + assistant integrations (ChatGPT/Claude) for non-technical
  analysts.
- **Security:** SSO/SAML; SOC 2 Type II (annual, report under NDA); GDPR + CCPA compliant;
  encryption in transit (TLS 1.2) + at rest (AES-256); **data held only transiently** during
  transfer (lives in our warehouse, not permanently stored by vendor); audit logs retained
  6–12 months.
- **Connector maintenance SLA:** vendor maintains connectors + harmonized outputs as a managed
  service — when a source API changes, updating the connector is **on Supermetrics, not us**.

## Pricing / contract (RFP)

- **Fixed annual subscription** — no per-row/usage overages (contrast to row-metered/MAR
  tools). Billing scoped by **sources / accounts / destinations**, with a generous
  **100M rows/month soft cap**.
- **Initial quote:** *Supermetrics for Snowflake — 2 users, up to 10 data sources, 2 yrs
  historical backfill (if source allows), 100M rows/month = **$40,000/year**.* Vendor wants
  final user count, confirmed launch source list, and destination count to sharpen it.
- Ad-hoc resyncs / historical reloads included (not billed separately). Multi-year discounts
  available. Right-sizing down accommodated **at renewal** (mid-term case-by-case). Persistent
  overages may trigger a contract amendment.

## Vendor selection: Funnel vs Supermetrics (comparison sheet)

The alternative evaluated was **Funnel**. Key contrasts:
- **Pricing:** Funnel = consumption-based "**Flexpoints**" (per connection / platform account /
  destination), 12-mo minimum, **no mid-contract right-size down**; Supermetrics = flat annual,
  scoped by sources/accounts/destinations.
- **Output flexibility:** Funnel offers **both raw source-shaped AND modeled** outputs and
  configurable soft/hard deletes; Supermetrics is **modeled/denormalized only**. (Funnel is
  the more flexible on raw access; Supermetrics the more predictable on cost.)
- Both run transforms vendor-side before Snowflake load; both handle restatement lookback
  re-syncs. Supermetrics was selected.

## RFP question bank (topics — full list in "Raw from Supermetrics - Draft…RFP")

Billing, Data Models/Compute/Delivery, Platform, Security, **SLAs** (time-to-fix on API
change, proactive connector migration ahead of deprecation, vendor vs our-DE maintenance
split), **Sources** (per-source endpoints/dimensions/metrics/gaps, custom connector support,
max backfill window, min sync frequency, native vs self-built connectors, app-install / MMP
sources like AppsFlyer/Adjust/Branch, timeline to add a new source), **Implementation**
(dedicated forward-deployed/solutions engineer, kickoff→prod timeline, required internal
resources, cost). Use this bank as the checklist for closing vendor questions (task C1).

## Related artifacts (Google Drive)

- **Mona's scope doc** — "Fanatics x Supermertrics" (Doc, owner mona.thiele): id
  `1nFLUJAu-sSa48XqWqkyqI0h6luSNYynkair8dSWIwA4`
- **RFP answers** — "Bet Fanatics - Supermetrics - RFP Answers" (Sheet, from
  corey.swink@supermetrics.com): id `1jveB4FtbV6TXuErAgd3bL9LicW4hA10k4gW8CZtZTVs`
  (Alex's copy: `1cgbPv2eKXe0vGYcCeCJ2PrF4moCXtDki_EfN8cqo2no`)
- **Vendor comparison** — "RFP Questionnaire - Aligned (Funnel vs Supermetrics)" (Sheet): id
  `1sJP6EYrZ9PbxBlQ0sVzlmij11efjotHJ5HcQHB9yztE`
- **Raw RFP draft** — "Raw from Supermetrics - Draft Ads Ingestion Platform RFP": id
  `1mcp3j96SKiRVcf1mQcnmJUgzkZjq1T6OGa8pD2Rqdzk`
- **Sample data** — "SuperMetrics Sample Data" folder (owner david.nam): id
  `1hcFC_JpQIN8hgQZRN_Thmv5xV6T0J7AS`

> Open items / things to verify now live in **`confluence_todo.md`** (single source).
