# Antoine's FBG Handoff — Summary + How We Differ

> Reference only. Antoine's FBG-scoped handoff plan, **superseded by our vision** (`vision.md`,
> D-7/D-8/D-9) where they conflict. Part 1 = summary of his doc; Part 2 = meeting talking
> points on the differences + what we keep from it.

## Part 1 — Summary of the handoff plan

**Source:** `raw/DATA_ENG_HANDOFF_PLAN_2026-09-17.md` ("FBG paid-spend landing schema — plan
for Data Engineering"). **Author:** Antoine (FMX Growth). **To:** FBG Analytics Engineering
(Koushik & team). **Date:** 2026-09-17.
> Note: Alex referred to this as "Mona's doc" — it is part of the same FMX Supermetrics
> handoff effort (Mona + Antoine drove the POC) but the byline is Antoine. Companion docs it
> references: `FMX_SUPERMETRICS_SPEC_AND_BACKFILL_PLAN.md` (§2 field lists), `TABLE_
> DESCRIPTIONS_SUPERMETRICS_FBG.md`, `sources_supermetrics_fbg.yml`, `PHASE2_PARITY_EDITS_
> AND_DEPRECATION_MAP.md` (we don't have these yet).

## The one-paragraph version
Supermetrics lands FBG paid-spend into a single Snowflake schema **`FBG_SOURCE.SUPERMETRICS_FBG`**
(one transfer per data source, one table per grain). FBG Analytics Engineering then builds a
dbt stack (sources → staging → intermediate → marts) that unions the per-platform **spend
facts** into one canonical **daily paid-spend model**, resolves **brand in dbt** (not in
schemas), and exposes an FMX mart that the existing FMX consumers repoint to by renaming one
reference. Legacy transfers run until consumers are cut over.

## 1. What lands
- **Schema `FBG_SOURCE.SUPERMETRICS_FBG`** — Phase-1 Terraform (Koushik, target **Sep 21**).
  Written only by `SVC_SUPERMETRICS` / `SNOWFLAKE-SVC_SUPERMETRICS_ROLE`; read by dbt +
  analysts. **30-day Time Travel. No manual DML ever.**
- **Naming:** `PLATFORM_CONTENT_GRAIN` with the plain platform name (e.g. `META_AD_DAILY`).
  One **spend fact** per platform joins the union; **state/DMA/action/conv** tables are
  **allocation/analysis tables — never summed into spend**.
- **Platforms (spend fact):** Meta, Google Ads, TikTok, Snapchat, Reddit, X, Amazon DSP,
  Apple Ads, DV360, Moloco, Liftoff, Impact, + **Manual (Google Sheet)** `MANUAL_SPEND_DAILY`.
- **Shared conventions per table:** `DATE` (UTC day, the dedup key — Supermetrics "Append and
  deduplicate by Date" replaces whole date partitions each run), account id+name, campaign
  id+name, **additive metrics only** (no stored rates), **single currency USD**.
- **Refresh windows:** 7 days default (Google 14, Impact 30). **Apple Ads + Amazon DSP APIs
  only expose ~90 days** → those tables **bank irreplaceable history**; never wide-backfill,
  **clone before any backfill** (Time Travel is the safety net).
- **Backfill timeline:** transfers created when schema exists; Apple/Amazon bounded-backfilled
  same day; all others backfilled to **Dec 1 2025** immediately (contract allows 2 yrs).
  SBK/Casino accounts join the same transfers later (history can reach Oct 2024).

## 2. Descriptions (self-describing catalog)
Every landing table gets a Snowflake **COMMENT** (from Table Manager "Description", set before
first run), in one structure so Horizon Catalog / Cortex / Claude can answer "what is this,
how do I use it" without a human: `[FBG · platform]` tag · one-sentence grain · brands +
derivation · ambiguous-metric defs (Amazon `TOTAL_COST`=billed spend incl. fees; Apple
`TAPS`=clicks; Agentio=committed cost on publish day) · UTC · refresh method/window · API
caveats · **"allocation view — never sum with the parent"** on every state/DMA/action table.
Same text = the `description:` in `sources_supermetrics_fbg.yml`. Keep
**`persist_docs {relation: true, columns: true}`** on so docs flow to staging + marts.

## 3. dbt work (FBG analytics-engineering project)
- **Sources:** `sources_supermetrics_fbg.yml` (drafted). Freshness `warn 36h / error 60h` on
  `DATE` (Apple/Amazon `warn 48h`). **Legacy `SUPERMETRICS` schema is NOT a source.**
- **Staging:** one view per landing table `stg_supermetrics_fbg__<table>`, rename-only to
  canonical columns: `spend_date, platform, account_id, account_name, campaign_id,
  campaign_name, adgroup_id, adgroup_name, state, impressions, clicks, spend, installs,
  conversions, source_table, segment('native'/'manual'), tz('utc')`. Platform quirks:
  - `platform` constant per source except **Google Ads** (channel type → `google_uac` /
    `google_search`) and **DV360** (line-item type → YouTube vs audio/display).
  - clicks: Meta `ACTION_LINK_CLICK` (keep `CLICKS` as `clicks_all`), Snapchat `SWIPES`,
    Apple `TAPS`, Amazon `CLICK_THROUGHS`.
  - spend: Amazon `TOTAL_COST`, DV360 `REVENUE_USD`, Impact `TOTAL_COST`, else `COST`/`SPEND`.
  - installs: per-platform action field; **Google installs** joined from
    `GOOGLEADS_CAMPAIGN_CONV_DAILY` where `CONVERSION_CATEGORY='DOWNLOAD'`; NULL for Reddit,
    DV360, Liftoff-without-installs.
  - Reddit: join campaign/account keys onto `REDDIT_ADGROUP_AD_DAILY` via two pair tables.
  - Manual sheet: `segment='manual'`, brand/platform from the sheet, carries
    `granularity`/`period_end` for non-daily rows.
- **Seeds:** `brand_account_map.csv` (ds_id, account_id, brand, sub_brand — incl. FMX
  Predictstreet); `brand_campaign_rules.csv` (regex rules for **shared accounts only** —
  Amazon DSP / DV360 / shared Google+Apple → FMX/SBK/CASINO by name).
- **Intermediate:** `int_fbg_paid_spend_daily` = UNION ALL of spend-fact staging + manual;
  brand = seed→rules→NULL (NULL **fails the build**). Grain = `spend_date × platform ×
  account_id × campaign_id × adgroup_id × segment`. Allocation tables kept **out** of this
  union (`int_fbg_paid_spend_by_state_daily`); actions in `int_fbg_paid_actions_daily`.
- **Marts:** `fct_fbg_paid_spend_daily` (all brands) + **`int_fmx_combined_media_spend_v2`**
  (`WHERE brand='FMX'`) exposing the **current FMX consumer contract** columns so the weekly
  note / Sugarbee / dashboards repoint by renaming one reference. At cutover `_v2` replaces
  `INT_FMX_COMBINED_MEDIA_SPEND`.
- **Tests (error unless noted):** `unique` on intermediate key; `not_null brand` + singular
  rule-collision test; `accepted_values platform`; segment **seam tests** (manual vs native
  don't overlap for Apple/Amazon + generic); Reddit hierarchy totals (warn); granularity
  (`period_end` iff non-daily); **recon (warn)** monthly spend within 1% of legacy
  `INT_FMX_COMBINED_MEDIA_SPEND` Mar–Aug 2026; source freshness.
- **Schedule:** dbt after **08:00 UTC** (Apple Ads transfer at 07:00 UTC is last to finish).

## 4. Non-obvious things
- **Brand lives in dbt, not schemas.** Same tables serve FMX/SBK/Casino; account ≠ brand for
  two sources (FMX Twitch flight runs under the SBK DSP advertiser; FMX YouTube IO under the
  shared DV360 advertiser).
- **Apple Ads + Amazon DSP = irreplaceable history** (~90-day API). Pre-native history comes
  via `MANUAL_SPEND_DAILY`. Never wide-backfill; clone first.
- **`MANUAL_SPEND_DAILY` is hand-maintained** (Antoine's Google Sheet, full-reloaded every
  morning): Apple console exports, Amazon Twitch flight, Smadex, AdAction, Agentio, + 4 brand
  partnerships booked as even daily spreads of monthly estimates (Schultz, Jomboy, Complex,
  Dodgers Nation — $1.83M YTD, trued-up monthly).
- **Legacy stays until cutover:** `FMX Data Transfer`→`BLEND_FMX_DATA`, `FMX_META_AD_DAILY`,
  `Impact FMX` run until consumers repoint; other 24 legacy tables (Jonathan/David) retire as
  accounts move onto shared transfers. Build a consumer inventory first (dbt lineage +
  `ACCESS_HISTORY` + non-dbt readers: Creative Agent, weekly-note SQL, Sugarbee, dashboards).

## 5. Asks of Data Engineering
1. **Phase-1 Terraform** — schema + grants (future grants to the service role; read for dbt +
   `SNOWFLAKE-CUSTOMER_ANALYST_PII`).
2. **Confirm the dbt project/location** + the role dbt reads `FBG_SOURCE` with (`<DBT_ROLE>`).
3. **Review `sources_supermetrics_fbg.yml`** after first transfers run (columns are
   Supermetrics field IDs upper-cased; some may differ from the draft).
4. **Build order:** sources → staging → `int_fbg_paid_spend_daily` + brand seeds + tests →
   FMX mart → allocation/actions models → cutover.

## How this relates to our project / open tensions
- This is a **concrete, FBG-scoped, FMX-first** implementation of the generic-model idea —
  more prescriptive than our `plan.md` (which is org-wide FBG/FMX/FES). It mostly **confirms
  D-1** (per-opco separation) but reframes it: **one shared schema + shared tables**, with
  **brand resolved in dbt**, not separate schemas/tables per opco. ⚠️ Compare against our D-1
  wording ("separate tables per opco") — the doc says the opposite at the storage layer.
- **D-2 (Fivetran OSS start):** this doc does **not** reference Fivetran packages; it specs a
  bespoke canonical model directly on the harmonized landing tables — consistent with the
  "harmonized output → consumption/mart layer" caveat we already noted, but note AE may be
  planning to hand-roll rather than adapt Fivetran.
- Confirms the **Terraform/SSM, no-manual-DML** stance (D-5).
- New specifics worth carrying into the rollout doc: the `SUPERMETRICS_FBG` naming, the
  spend-fact-vs-allocation-table rule, the manual-spend sheet dependency, and the
  catalog-COMMENT convention for agent-readability.


---

## Part 2 — Differences (meeting talking points)

**Status:** Alex's vision (`vision.md`, D-7/D-8) is the **source of truth** and **supersedes**
Antoine's handoff doc (raw at `raw/DATA_ENG_HANDOFF_PLAN_2026-09-17.md`, summarized in Part 1
above) wherever they conflict. This is a **talking-points cheat sheet** for the conversation
with Antoine (FMX Growth) + FBG AE (Koushik) — not a list of open decisions.

Antoine's doc is still useful: it's a detailed, correct, FBG-scoped implementation and most of
its mechanics (naming discipline, spend-fact-vs-allocation rule, catalog COMMENTs, backfill
safety, tests) carry over into our model. The differences are mainly about **where data is
isolated** and **scope**.

---

## Difference 1 — FMX isolation: separate schema vs brand-in-dbt  *(the big one)*
- **Antoine's doc:** FBG, FMX, SBK, Casino all land in **one** `FBG_SOURCE.SUPERMETRICS_FBG`
  schema; **brand is resolved in dbt** via seeds (`brand_account_map.csv`) + regex rules
  (`brand_campaign_rules.csv`).
- **Our direction:** each operating company gets its **own schema** — `FMX Source` is separate
  from `FBG Source` — with FBG+FMX in the **FBG Snowflake** account and **FES** in a separate
  Snowflake account. Isolation happens at the **schema/warehouse + grants** boundary, not in
  dbt brand-mapping.
- **Why ours:** governance — "FMX campaigns only ever live in the FMX schema" is enforced by
  the platform, not by a dbt rule that can silently misclassify. Cleaner per-opco ownership.
- **To discuss with them:** their doc's brand-in-dbt logic exists because **some accounts are
  shared** (e.g. the FMX Twitch flight runs under the **SBK DSP advertiser**, the FMX YouTube
  IO under the **shared DV360 advertiser**). Ask: can Supermetrics split those at the transfer
  level so each opco's spend lands in the right schema, or do we still need a thin
  brand/account-routing step for genuinely shared advertiser accounts? This is the one place
  their shared-account problem doesn't vanish just by having separate schemas.

## Difference 2 — Scope: org-wide (3 opcos) vs FBG-only
- **Antoine's doc:** scoped to **FBG** (FMX/SBK/Casino as brands within it).
- **Our direction:** one consistent pattern across **all three opcos** (FBG, FMX, FES), each
  with the same medallion stack.
- **To discuss:** their doc is the FBG instance of our pattern — align terminology so "FMX"
  means the **opco schema**, and SBK/Casino are handled within the FBG opco as needed.

## Difference 3 — Transformations: shared repo vs per-project bespoke
- **Antoine's doc:** a bespoke dbt model built directly in the FBG AE project; no shared/
  reusable transformation layer mentioned.
- **Our direction:** a **`dbt-shared-repo`** holds the standard per-source transformations
  (Google Ads, Facebook Ads, any generic source), consumed by **three opco projects**
  (`dbt-ae`, `dbt-ae/fmx`, `dbt-fes-ae`) so each source is modeled identically everywhere.
- **Why ours:** maintain the source logic once; consistency across opcos.
- **To discuss:** mechanism for sharing (dbt package import vs dbt Mesh cross-project `ref`);
  we'd lift their staging/mapping logic into the shared repo as the first standard source models.

## Difference 4 — Consumption shape: canonical OBT vs FMX-contract mart
- **Antoine's doc:** `fct_fbg_paid_spend_daily` (all brands) + `int_fmx_combined_media_spend_v2`
  shaped to the **existing FMX consumer contract** so dashboards repoint by renaming one ref.
- **Our direction:** a **Unified Marketing Metrics OBT**, **identical across opcos** (clicks,
  impressions, ROAS, …), because there's no opco-specific business logic and ad data isn't
  tied to customer records + per-source **entity tables**.
- **Reconcilable:** their `_v2` FMX mart can be the **FMX opco's view onto the shared OBT**.
  Keep their repoint-by-rename trick for a smooth cutover.

---

## What we KEEP from Antoine's doc (adopt as-is, not differences)
These are good and should flow into our shared standards:
- **Spend-fact vs allocation rule** — one spend fact per platform in the union; state/DMA/
  action tables **never summed into spend**.
- **Catalog COMMENTs / `persist_docs`** — agent-readable table descriptions end to end.
- **Backfill safety** — Apple Ads + Amazon DSP ~90-day API → bank history, clone before
  backfill, never wide-backfill.
- **`MANUAL_SPEND_DAILY`** — hand-maintained Google Sheet (console exports, brand
  partnerships) is a real dependency to carry forward.
- **Tests** — unique key, `not_null brand`, segment seam tests, recon within 1% of legacy.
- **Terraform-only provisioning, no manual DML, Time Travel** — matches our D-5.
- **Legacy-until-cutover + consumer inventory** (dbt lineage + `ACCESS_HISTORY` + non-dbt
  readers) — reuse for our deprecation process.
