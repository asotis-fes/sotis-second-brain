# Confluence Doc — Open Items

What still needs to be worked before the rollout Confluence doc is sent. Decided stances live
in `rollout_policies.md`; final decisions in `decisions.md`. This file = **what's left**.

## Resolved (for the record — see decisions)
Approvals (D-10), build-vs-buy (D-11), deprecation (D-12), monitoring DAG (D-13),
Snowflake-only destinations (D-15), grain daily×DMA×ad (D-16), column COMMENTs (D-17),
shared-repo CI (D-18), alerting Sugarbee+dbt tests (D-19), marketer+DE share license / no seat
cap (D-20), FMX scope = per-opco schema (D-9), schema-drift owner = AE, connector-cloning
mechanism (same `data_source`+`schema_id`, different `accounts`). **PII/XtremePush = out of
scope (separate project).**

## Answered by vendor feedback 2026-10-15 (feedback/feedback_analysis_2026-10-15.md)
- [x] **Opco destination isolation** — YES via **workspaces** (workspace-per-opco), plus
  Snowflake grants = two layers. (Overturns the earlier "not native" finding.)
- [x] **DE/marketer role split** — YES: **Viewer** (connections only) vs **Editor** (transfers).
  Marketers = Viewer, DE/AE = Editor. Custom roles still not available.
- [x] **`schema_id` reuse** — YES, identical columns. API clone errors for Meta/Google right now
  → use Hub clone or create via API with same `schema_id`. Keep account-specific config (e.g.
  Meta custom conversions) out of shared tables.
- [x] **FMX shared accounts** — route in **staging** by campaign naming (GA `7826216690`, ASA
  `7708200`, DV360 `1224948634`), don't split transfers.

## DECISIONS NEEDED (from vendor feedback)
- [ ] **Role model:** adopt Viewer/Editor split (marketers = Viewer own connections + request
  transfers; DE = Editor create transfers)? Vendor + Brock recommend yes. Changes D-10/D-20 and
  the "marketers self-serve" wording.
- [ ] **OBT grain:** (a) one OBT, DMA nullable + `geo_grain`, or (b) two OBTs (ad×day + geo×day)?
  Vendor + Brock lean (b).

## Build constraints to bake into the doc (from feedback)
- [ ] Landing: **one destination per opco schema**; each gets its own Snowflake user+role+key-
  pair, granted only on its schema. Say explicitly.
- [ ] Medallion: **Source → Staging → Entity → OBT** (add Staging; fix the double "Consumption").
- [ ] dbt incrementals **delete+insert on date**, lookback ≥ refresh window; **never drop the
  transfer `Date` field**.
- [ ] **Future grants** on each landing schema + `persist_docs` on models (landing rebuilds on
  schema change).
- [ ] **Google installs = own transfer**, joined in dbt.
- [ ] Reword provisioning: **Snowflake via Terraform/SSM; Supermetrics via Management API scripts**.
- [ ] Monitoring: "who added what" not available → **weekly transfer-list diff** (what, not who).
- [ ] Apple example: frame as **already-solved** (Apple Search Ads connected for SBK + Markets).
- [ ] Optionally note **Connector Builder** as an alternative to a new Airflow DAG.

## Still OPEN — resolve before sending the doc
- [ ] **Mona's 5 vendor questions** (work one-by-one): (1) granularity beyond daily×DMA×ad;
  (2) email-report-only sources; (3) attribution writeback; (4) pricing Scope-1 vs full;
  (5) onboarding a source 2–3 mo post-launch.
- [ ] **Shared advertiser accounts** — FMX flights under SBK/DV360 advertisers don't auto-split
  by per-opco schema; need a Supermetrics transfer-level split or a thin routing step.
  (`antoine_handoff.md` Part 2, difference #1.)
- [ ] **Shared dbt repo mechanism** — dbt package import vs dbt Mesh cross-project `ref`; how
  the 3 opco projects consume `dbt-shared-repo`.
- [ ] **Canonical OBT column contract** — define the unified-metrics schema once, shared.
- [ ] **Naming conventions** across the 3 opco schemas (+ the existing `SUPERMETRICS_FBG`).
- [ ] **Shared-repo ownership / RACI + environments** — owner, cross-team PR review, dev/prod
  promotion. (Alex POC; Alex + Ryan Knapp on dbt; AE owns schema drift.)
- [ ] **Backfill / irreplaceable-history policy** generalized beyond FBG (Antoine's Apple/Amazon
  ~90-day API + clone-before-backfill).
- [ ] **Two-Snowflake-account grouping** — confirm FBG+FMX in FBG Snowflake, FES separate.
- [ ] **Source-volume vs 100M-rows/mo soft cap** — monitor; who owns the bill.
