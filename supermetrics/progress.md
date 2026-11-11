# Progress — Supermetrics Rollout

Compact changelog. Current state + decisions live in `_index.md` / `decisions.md`.

## Current state (2026-10-02)
Architecture + policies decided (D-1…D-20); vendor research done. Not yet started: the rollout
Confluence doc (task A1) and the open items in `confluence_todo.md`. FBG is live in prod
(`SUPERMETRICS_FBG`); FanApp in prod since Aug 2026.

## Log (newest first)
- **2026-10-16 — Vendor feedback consumed.** Moved PDF to `feedback/`, wrote
  `feedback/feedback_analysis_2026-10-15.md`. Supermetrics approves the direction. All 4 open
  questions answered: destination lock YES (workspaces), role split YES (Viewer vs Editor),
  schema_id clone YES (identical cols; Meta/Google API-clone bug), FMX shared accounts → route
  in staging. Two reframes now need Alex's call: **role model** (Viewer/Editor split) and **OBT
  grain** (one OBT + geo_grain vs two OBTs). Build constraints added to `confluence_todo.md`;
  decision impacts logged in `decisions.md`. Confluence page NOT yet updated (pending the two
  decisions).
- **2026-10-05 — Task A1: full RFC draft written.** Checked rfc-writer skill template → found
  the skill's bundled template drifted AND the canonical FAN template is superseded. Alex
  pointed to the **new DATA-space template** ("Template: Project Proposals/RFC", page
  3147891094): Summary / Problem / Proposal / Expected Impact / Scope / Owner & Stakeholders /
  Risks & Open Questions / Next Steps. Rewrote `rollout_doc_draft.md` as a full draft on that
  template (not a skeleton). Awaiting Alex review, then publish to Confluence space DATA.
  NOTE: rfc-writer skill still points at the old FAN template (2098561033) — stale.
- **2026-10-02 — Hygiene pass.** Merged Antoine's 2 files → `antoine_handoff.md` and the 2
  research files → `research.md`; trimmed stale sections from `findings.md` (data-model +
  open-threads now point to vision/decisions/todo); marked `decisions.md` the source of truth;
  tiered `_index.md` (Core/Reference/Archive); deduped `confluence_todo.md`; condensed this log.
- **2026-10-02 — Policies + research.** D-15…D-20 (Snowflake-only, grain, COMMENTs, CI, Sugarbee
  +dbt alerting, marketer+DE share license). Confirmed: no DE-only role (Editor all-or-nothing);
  destination confinement = Snowflake grants, not a Supermetrics feature; pipeline health = the
  Transfer Runs API; connector cloning = same `schema_id`, different `accounts`. PII out of
  scope. Schema-drift owner = AE.
- **2026-10-02 — Vision supersedes Antoine (D-9).** Alex's per-opco-schema + shared-dbt-repo +
  medallion vision (D-7/D-8) is source of truth; Antoine's FBG doc kept as reference.
- **2026-10-02 — Ingested Antoine's FBG handoff doc** (`raw/`), plus Alex's vision diagrams
  (`images/`). Recorded D-10…D-14 (governance/approvals/build-vs-buy/deprecation/monitoring).
- **2026-09-30 → 10-02 — Scaffold + ingest.** Created project; pulled Mona's scope doc, the
  #dsea-leads thread, RFP sheets, Fivetran-OSS dbt starting point. D-1…D-6.

## Next
Work `confluence_todo.md` open items; attach diagrams + polish the Confluence draft; publish
when ready (remove DRAFT markers).

## Confluence
- Draft page created 2026-10-05 (status DRAFT, title-flagged, live-but-not-for-review):
  https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3615391778 — id `3615391778`,
  space DATA, parent "DEMI Knowledge Articles" (3120595141).
- TODO on the page: attach the 2 diagrams (`images/`); fix `**Access & governance.**` bold
  run-in; add Review-Until date + epic; remove DRAFT markers to publish.
