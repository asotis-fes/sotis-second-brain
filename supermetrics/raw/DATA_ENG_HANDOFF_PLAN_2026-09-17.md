# FBG paid-spend landing schema — plan for Data Engineering

For: FBG Analytics Engineering (Koushik and team). From: Antoine (FMX Growth). Date: Sep 17, 2026.
Purpose: what is about to land in `FBG_SOURCE.SUPERMETRICS_FBG`, how it is named and documented, and the dbt work that turns it into the canonical daily paid-spend model. Detailed field lists are in `FMX_SUPERMETRICS_SPEC_AND_BACKFILL_PLAN.md` (§2) and `sources_supermetrics_fbg.yml` (already drafted); this document is the map.

## 1. What lands, and when

**Schema:** `FBG_SOURCE.SUPERMETRICS_FBG` (Phase 1 — Terraform, Koushik, target Sep 21). Written only by Supermetrics as `SVC_SUPERMETRICS` / `SNOWFLAKE-SVC_SUPERMETRICS_ROLE`; read by dbt and analysts. 30-day Time Travel. No manual DML ever.

**Tables:** one Supermetrics transfer per data source, one physical table per grain. Naming is `PLATFORM_CONTENT_GRAIN` with the plain platform name, so anyone can read it:

| Platform | Spend fact (joins the union) | Allocation / analysis tables (never summed into spend) |
|---|---|---|
| Meta | `META_AD_DAILY` | `META_AD_STATE_DAILY`, `META_AD_ACTION_DAILY`, `META_AD_CREATIVE_DAILY` |
| Google Ads | `GOOGLEADS_ADGROUP_DAILY` | `GOOGLEADS_ADGROUP_STATE_DAILY`, `GOOGLEADS_CAMPAIGN_CONV_DAILY` (installs come from here: conversion category DOWNLOAD) |
| TikTok | `TIKTOK_AD_DAILY` | `TIKTOK_AD_STATE_DAILY`, `TIKTOK_AD_DMA_DAILY` |
| Snapchat | `SNAPCHAT_AD_DAILY` | `SNAPCHAT_AD_STATE_DAILY`, `SNAPCHAT_AD_DMA_DAILY` |
| Reddit | `REDDIT_ADGROUP_AD_DAILY` | `REDDIT_CAMPAIGN_ADGROUP_DAILY`, `REDDIT_ACCOUNT_CAMPAIGN_DAILY` (hierarchy pairs — Reddit's API allows 2 breakdown groups with spend), `REDDIT_AD_STATE_DAILY` |
| X | `XADS_ADGROUP_DAILY` | `XADS_ADGROUP_DMA_DAILY`, `XADS_AD_DAILY` |
| Amazon DSP | `AMAZONDSP_LINEITEM_DAILY` | — |
| Apple Ads | `APPLEADS_ADGROUP_DAILY` | `APPLEADS_ADGROUP_STATE_DAILY` |
| DV360 | `DV360_LINEITEM_DAILY` | `DV360_YOUTUBE_AD_DAILY` |
| Moloco | `MOLOCO_ADGROUP_DAILY` | — |
| Liftoff | `LIFTOFF_CAMPAIGN_DAILY` | — |
| Impact | `IMPACT_PARTNER_DAILY` | — |
| Manual (Google Sheet) | `MANUAL_SPEND_DAILY` | — |

Conventions every table shares: `DATE` (UTC day; the dedup key — Supermetrics "Append and deduplicate by Date" replaces whole date partitions on each run), account ID + account name, campaign ID + name, additive metrics only (no stored rates), one currency (USD). Refresh windows: 7 days (14 Google, 30 Impact); Apple Ads and Amazon DSP APIs expose ~90 days, so those two tables hold banked history that must never be overwritten by a wide backfill — hence Time Travel and the clone-before-backfill rule.

**Timeline:** transfers created as soon as the schema exists; Apple Ads and Amazon DSP backfilled (bounded) the same day; all others backfilled to Dec 1, 2025 immediately (contract allows two years). Sportsbook/Casino accounts join the same transfers when their owners decide; their history can go back to Oct 2024.

## 2. Descriptions — written for agents as much as for people

Every landing table carries a Snowflake **COMMENT**, set from the Table Manager "Description" field before the first run. They follow one structure so that Horizon Catalog, Cortex agents and Claude (via the Snowflake or Supermetrics connectors) can answer "what is this table and how do I use it" without a human:

`[FBG · platform]` tag · one-sentence grain ("One row per Meta ad per day") · which accounts/brands land here and how brand is derived · metric definitions where the name is ambiguous (e.g. Amazon `TOTAL_COST` = billed spend incl. fees; Apple `TAPS` = clicks; Agentio spend = committed cost on publish day) · time basis (UTC) · refresh method and window · API caveats (Apple/Amazon 90-day window, TikTok state tables carry no installs) · **"allocation view — never sum with the parent"** on every state/DMA/action table · and the spec section to read.

The full text per table is in `TABLE_DESCRIPTIONS_SUPERMETRICS_FBG.md`; the same text is the `description:` of each source in `sources_supermetrics_fbg.yml`. Please keep `persist_docs: {relation: true, columns: true}` on for the dbt models built on top, so descriptions flow through to the staging views and marts and the catalog stays self-describing end to end. If you add a model, write its description in the same shape.

## 3. dbt work (in the FBG analytics-engineering project)

### 3.1 Sources
`sources_supermetrics_fbg.yml` — drafted, one entry per landing table with column descriptions. Freshness: `warn_after 36h / error_after 60h` on `DATE` (Apple Ads and Amazon DSP: `warn_after 48h`). The legacy `SUPERMETRICS` schema is **not** a source of this model.

### 3.2 Staging — one view per landing table, `stg_supermetrics_fbg__<table>` (e.g. `stg_supermetrics_fbg__meta_ad_daily`)
Rename to the canonical columns and nothing else:
`spend_date, platform, account_id, account_name, campaign_id, campaign_name, adgroup_id, adgroup_name, state, impressions, clicks, spend, installs, conversions, source_table, segment ('native' / 'manual'), tz ('utc')`.
Platform-specific mappings are in spec §2.13 (parity matrix). Notable ones:
- `platform` is a constant per source except Google Ads (`ADVERTISING_CHANNEL_TYPE`: 'Multi Channel' → `google_uac`, 'Search' → `google_search`) and DV360 (`LINE_ITEM_TYPE` distinguishes YouTube from audio/display).
- clicks: Meta `ACTION_LINK_CLICK` (keep `CLICKS` as `clicks_all`), Snapchat `SWIPES`, Apple `TAPS`, Amazon `CLICK_THROUGHS`.
- spend: Amazon `TOTAL_COST`, DV360 `REVENUE_USD` (top-line cost), Impact `TOTAL_COST`, others `COST`/`SPEND`.
- installs: Meta `ACTION_MOBILE_APP_INSTALL`, TikTok `APP_INSTALL`, Snapchat `TOTAL_INSTALLS`, Apple `INSTALLS`, X `MOBILE_CONVERSION_INSTALLS`, Amazon `MOBILE_APP_FIRST_STARTS_14D`; Google installs are joined from `GOOGLEADS_CAMPAIGN_CONV_DAILY` where `CONVERSION_CATEGORY = 'DOWNLOAD'`; NULL for Reddit, DV360, Liftoff-without-installs.
- Reddit: the campaign/account keys are joined onto `REDDIT_ADGROUP_AD_DAILY` from the two pair tables on `AD_GROUP_ID` → `CAMPAIGN_ID`.
- Apple Ads state: `regexp_substr(adgroup_name, '^asa_([a-z]{2})_', 1, 1, 'e', 1)` upper-cased, applied identically to native and manual rows (one macro).
- `stg_supermetrics_fbg__manual_spend_daily`: `segment = 'manual'`, `brand` taken from the sheet's own `BRAND` column, `platform` from the sheet (`apple_search_ads`, `amazon_dsp`, `agentio`, `smadex`, `adaction`, `brand_partnership`, …), `granularity` / `period_end` carried for non-daily rows.

### 3.3 Seeds
- `brand_account_map.csv` — `ds_id, account_id, brand, sub_brand` for every account in the spec (FMX accounts incl. Predictstreet as `sub_brand = predictstreet`; SBK/Casino accounts as their owners confirm).
- `brand_campaign_rules.csv` — `ds_id, account_id, match_field, pattern, brand, priority` for shared accounts only: Amazon DSP order/line-item names and DV360 insertion-order names (`(?i)markets|fmx|predict` → FMX; `(?i)sportsbook|sbk|osb` → SBK; `(?i)casino` → CASINO); Google Ads and Apple Ads shared accounts by campaign name.

### 3.4 Intermediate
- `int_fbg_paid_spend_daily` — `UNION ALL` of the spend-fact staging views + the manual view; brand resolution: seed first, rules second, else NULL (fails the build, see tests). One row per `spend_date × platform × account_id × campaign_id × adgroup_id × segment`.
- `int_fbg_paid_spend_by_state_daily` — the `*_STATE_DAILY` / `*_DMA_DAILY` allocation tables, kept **out** of the primary union so state cuts can never double-count spend.
- `int_fbg_paid_actions_daily` — Meta `META_AD_ACTION_DAILY` and Google conversion table, for CAC by event.

### 3.5 Marts
- `fct_fbg_paid_spend_daily` (all brands) and `int_fmx_combined_media_spend_v2` = `WHERE brand = 'FMX'`, exposing the current FMX consumer contract (`SPEND_DATE, STATE, PLATFORM, CAMPAIGN_NAME, MEDIA_SPEND, IMPRESSIONS, CLICKS, PLATFORM_INSTALLS, SPEND_SOURCE, SPEND_SURFACE`) so the weekly note, Sugarbee and dashboards repoint by renaming one reference. At cutover the `_v2` replaces `INT_FMX_COMBINED_MEDIA_SPEND`.

### 3.6 Tests (severity error unless noted)
- `unique` on the intermediate key above; `not_null: brand` (the "every row maps to exactly one brand" guarantee) plus a singular test for rule collisions at equal priority; `accepted_values: platform`.
- Seams: for Apple Ads, per account, `max(manual spend_date) < min(native spend_date with spend > 0)` and no `(account_id, spend_date)` in both segments; same for Amazon DSP; generic "no `(platform, account_id, spend_date)` in both segments".
- Reddit hierarchy: the three pair tables total identically per day (warn).
- Granularity: `period_end IS NOT NULL` iff `granularity <> 'DAILY'`.
- Recon (warn): monthly spend by platform within 1% of the legacy `INT_FMX_COMBINED_MEDIA_SPEND` for Mar–Aug 2026, and of the reference totals in the runbook §9 (read live from the connectors on Sep 15–16).
- Source freshness as above.

### 3.7 Schedule
dbt after 08:00 UTC — every transfer has finished by then (Apple Ads at 07:00 UTC is the last).

## 4. Things to know that are not obvious from the tables
- **Brand lives in dbt, not in schemas.** The same schema and the same tables serve FMX, Sportsbook and Casino; the live FMX Twitch flight runs under the Sportsbook DSP advertiser and the FMX YouTube IO under the shared DV360 advertiser, so account ≠ brand for two sources.
- **Two sources have irreplaceable history.** Apple Ads and Amazon DSP APIs give ~90 days. Their tables hold banked history; pre-native history arrives through `MANUAL_SPEND_DAILY` (console exports). Never run a wide backfill on them; clone before any backfill.
- **`MANUAL_SPEND_DAILY` is hand-maintained** (a Google Sheet Antoine owns): Apple Ads console exports for the pre-native window, the Amazon DSP Twitch flight, Smadex, AdAction, Agentio (committed cost on publish day, appended weekly), and four brand partnerships booked as even daily spreads of monthly estimates (Schultz, Jomboy, Complex, Dodgers Nation — $1.83M YTD, trued-up monthly). It is reloaded in full every morning (Full refresh).
- **Legacy stays until cutover.** `FMX Data Transfer` → `BLEND_FMX_DATA`, `FMX_META_AD_DAILY`, `Impact FMX` keep running until consumers are repointed; the other 24 legacy tables belong to Jonathan/David and retire when they move their accounts onto the shared transfers (`PHASE2_PARITY_EDITS_AND_DEPRECATION_MAP.md`). Consumer inventory before cutover: dbt lineage + `ACCOUNT_USAGE.ACCESS_HISTORY` on the legacy schema + the non-dbt readers (Creative Agent, weekly-note SQL, Sugarbee, dashboards).

## 5. Asks
1. Phase 1 Terraform (schema, grants incl. future grants to the service role and read for dbt + `SNOWFLAKE-CUSTOMER_ANALYST_PII`).
2. Confirm the dbt project/location and the role dbt reads `FBG_SOURCE` with (the `<DBT_ROLE>` placeholder).
3. Review `sources_supermetrics_fbg.yml` once the first transfers have run (column names are Supermetrics field IDs upper-cased; a handful may differ slightly from the draft).
4. Build order suggestion: sources → staging → `int_fbg_paid_spend_daily` + brand seeds + tests → FMX mart → allocation/actions models → cutover.
