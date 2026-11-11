# Supermetrics Team Feedback — Analysis (2026-10-15)

Source: `feedback/betfanatics-fcore-proposal-feedback-2026-10-15.pdf` (from the Supermetrics
team). Verdict: **"The overall shape is right and we'd approve it as the direction."** Most
notes tighten claims; four of our open questions are answered (two overturn our prior writing).

## Validated — keep as is
- **Thin / "intentionally dumb EL"** with logic in the dbt repo. (Can still use their custom
  fields later for a quick marketer need, but not the default.)
- **Snowflake grants as the isolation boundary** — matches their recommendation.
- **Not forcing stable pipelines over** — good, "takes the politics out of it."
- **Apple example in Problem** — and better: Apple Search Ads is **already connected** in our
  team for both Sportsbook and Markets, so frame it as **solved, not hypothetical**.

## Open questions — now answered
1. **Role split (Q1): our claim was WRONG, in our favor.** Viewers CAN add/reconnect/share
   **their own data-source connections** but can't create/edit transfers; Editors do both. So a
   clean split exists: **Marketers = Viewer** (own the platform auth, reconnect on token
   expiry), **DE/AE = Editor** (own transfers, destinations, backfills). Custom roles still not
   available (finer than this = product request). They'll confirm against our current role setup
   before we lock it. → **Overturns D-20** ("marketer+DE share Editor") and **conflicts with the
   open-adoption framing** (our Expected Impact says marketers add transfers). **DECISION NEEDED
   (below).** Their rec: marketers own connections + request transfers, DE owns transfers.
2. **Clone / schema_id (Q2): YES, identical columns.** Clone/duplicate transfer is supported in
   UI and Management API (since the Sept release); table group + `schema_id` stay fixed so the
   column set is identical, only the account list changes. Caveats: (a) the **API clone endpoint
   currently errors for Meta + Google Ads** transfers → use Hub clone, or create via API with
   the same `schema_id`; (b) **account-specific config** (e.g. Meta custom conversions) won't
   line up across opcos → keep out of shared tables or handle per opco. → **Resolves our open
   item.**
3. **Lock an opco to one destination (Q3): YES, via workspaces.** Each workspace has its own
   destinations/transfers/table groups; a transfer in one workspace **can't** write to another
   workspace's destination. **Workspace-per-opco + Snowflake grants = two layers.** Plan for:
   connections aren't shared across workspaces; within a workspace any Editor can use any
   destination there (fine if each workspace holds only its opco's destination). → **Overturns
   our research finding** (we'd concluded destination confinement was NOT native; it IS, via
   workspaces). Now a belt-and-suspenders control.
4. **FMX shared accounts (Q4): confirmed; solve in staging, not transfers.** Three accounts mix
   SBK/Casino/Markets: **Google Ads `7826216690`** (campaign names carry a sportsbook/casino/fmx
   token), **Apple Search Ads `7708200`** (`_sportsbook`/`_fmx` suffix), **DV360 `1224948634`**
   (free-text names → a small campaign-ID lookup is safer). **Don't split at the transfer level**
   (doubles API calls, still needs a rule) — do a **small routing step in staging keyed on
   campaign naming**, which keeps the dumb-EL principle. → **Resolves our open item**; this is
   why we need a Staging layer (see below).

## Changes / tightenings to apply
- **OBT grain — their hardest push.** `one row per ad, per DMA, per day` is **not achievable for
  every source**:
  | Source | DMA at ad level? | Note |
  |---|---|---|
  | Meta | Yes, but **Comscore market**, not Nielsen DMA | needs Comscore→DMA mapping |
  | Google Ads | **No** | metro only from geo report (no ad ID); **ad group** is finest |
  | TikTok | Yes | audience report |
  | Snapchat | Yes | DMA report |
  | X Ads | **Ad group** confirmed | ad-level supported but slow → long backfills |
  | Reddit | Yes, once Reddit enables | needs unlock + re-auth after API change |
  Options: **(a)** one OBT, DMA nullable + a `geo_grain` column (ad/ad_group/campaign/none); or
  **(b)** split into an **ad×day OBT** and a **geo×day OBT** at each source's finest grain. They
  **lean (b)** — cleaner for geolift, avoids summing ad-group Google against ad-level Meta. →
  **Modifies D-16 (grain) and D-8 (single OBT). DECISION NEEDED (below).**
- **Landing/dbt behaviors to design around when converting Fivetran models:**
  1. Each run **deletes + re-inserts** rows for the dates in the refresh window → dbt
     incrementals should be **delete+insert on date**, lookback ≥ the refresh window.
  2. **No load-timestamp column** (no `_fivetran_synced`) → **Sugarbee freshness keys on
     `max(date)`** or the Transfer Runs API (refines D-19).
  3. **Never remove the `Date` field** from a transfer, or refresh flips to overwrite and
     history is lost.
  4. **Landing tables get rebuilt on schema change** → table-level grants + comments reset. Use
     **future grants** on each landing schema; keep **`persist_docs` on the dbt models, not the
     raw tables** (refines D-17).
  5. **Google Ads installs need their own transfer/table** (adding app-install conversions to a
     campaign/ad-group query distorts other metrics incl. cost) → pull installs separately, join
     in dbt. (Antoine's FBG handoff already does exactly this.)
- **Destinations = one per opco schema.** Each Snowflake schema needs its own Supermetrics
  destination ("one destination per opco schema"); FES gets its own regardless. Since FBG+FMX
  share a Snowflake account, **each destination gets its own Snowflake user + role, granted only
  on its own schema, key-pair auth.** Say this in Landing. (Fits our key-pair service-user
  runbook.)
- **Medallion table fix.** "Consumption" appears twice and there's no Staging layer, but Next
  Steps references staging → make it **Source → Staging → Entity → OBT**. (Staging is also where
  the FMX account-routing lives.)
- **"Everything via Terraform/SSM" is only half true.** Holds for **Snowflake**. Supermetrics
  has **no Terraform provider** — config is via the **Management API** (batch transfer create,
  clone, table-group edits, destination secret rotation) + SDK/CLI. Reword to: *"Snowflake via
  Terraform/SSM; Supermetrics config via Management API scripts in the repo."* → **Modifies D-5.**
- **Monitoring "who's adding what" has a gap.** Transfer Runs API gives status/error/rows/data-
  date per run (weekly job is fine). But the API **lists transfers/destinations without who
  created them** → we get **"what changed" via a weekly transfer-list diff, not "who."**
  Attribution would be a product request. → **Modifies D-13 signal #2.**
- **Custom connectors (out of scope) — leave a door open.** Fine to default to Airflow, but note
  **Connector Builder + documented API** as an option: often faster than a new DAG, lands in the
  same schema pattern; we still own the connector config on vendor API changes. → **Softens D-11.**

## Decisions you now need to make
1. **Role model.** Adopt the **Viewer/Editor split** (marketers = Viewer own connections + request
   transfers; DE/AE = Editor own transfers/destinations/backfills)? This resolves D-20 and
   tightens governance (no one but DE can point data at a destination), but it **changes the
   "marketers self-serve / anyone adds sources" message** in Expected Impact + Governance. Vendor
   recommends it; Brock recommends adopting it.
2. **OBT grain.** Option **(a)** one OBT, DMA nullable + `geo_grain`; or **(b)** two OBTs (ad×day
   + geo×day). Vendor + Brock lean **(b)**.

## Net
Nothing in the feedback blocks the plan or changes the architecture. It **validates the shape**,
**resolves all four open questions** (two in our favor: the role split and native workspace
destination locking), and adds a set of concrete build-time constraints. The only real reframes
are the **role model** and the **OBT grain**, both of which are decisions, not redesigns.
