# progress.md — session log

## 2026-10-21 — Phase 0 setup + Phase 1 macro scout

- Created `projects/rfc_data_forking/` with `_index.md`, `plan.md`, `findings.md`,
  `decisions.md`, `progress.md`.
- Scouted the local `dbt-fes-ae` clone → grounded `findings.md` on how `dbfork` and
  `auto_delta` actually work (file paths, signatures, invocation, naming, CI state).
  Key takeaway: the two macros exist, are documented, and **compose only manually today**;
  there is **no `custom-delta-report/` folder and no CI automation** — those are net-new in
  this RFC.

### Done
- Project scaffold + grounded findings on the two macros.

### Open / next
- **Capture the Jira FEAT key + scope** from the user (Q-1) — blocks the RFC References +
  scope sections.
- Decide folder location (Q-2) + orchestration home (Q-3) with the user.
- Draft the RFC sections against the Project Proposal template (via `rfc-writer`).
- Optional: confirm fangraph PK + downstream consumers for the worked example.

## 2026-10-21 (cont.) — Design settled + RFC draft written

- Ingested **FEAT-10458** + 3 epics (DEMI-646 fork env, DEMI-676 this RFC, DEMI-888 Fangraph
  report). Added Ads/audiences worked example.
- Settled design with user:
  - **Scope:** generic across FES/FBG/FMX; **V1 = Fangraph on FES** (D-6).
  - **Code split:** generic → `fanatics-gaming/dbt-shared-utils` (confirmed: the shared
    package, imported by dbt-fes-ae `packages.yml` @ v1.0.0); custom → owning project repo
    (D-7).
  - **One parent macro** `fork_and_review` composes dbfork + build + auto-delta + custom
    diff (D-8); custom layer = `custom-delta-report/<pipeline>/` folder registered as a
    macro path (Q-2 resolved, hybrid).
  - **Orchestration:** GitHub Actions, label-gated (D-9).
  - **Delivery:** Snowflake report tables + auto-gen self-contained HTML (D-10).
  - **Approval:** optional AE-run tool in V1, Ponzu enforcement deferred (D-11).
- **Wrote `rfc_draft.md`** — full 8-section FBG Project Proposal/RFC (Summary, Problem,
  Proposal, Expected Impact, Scope, Owner & Stakeholders, Risks, Next Steps).

### Resolved + PUBLISHED (2026-10-22)
- CI execution path RESOLVED (D-9): current = `dbfork` local-only; future/this-RFC = GitHub
  Actions → **dbt Cloud job** (team already runs this pattern). Baked into Proposal/Risks/
  Next Steps.
- Added explicit **"Where the new files live"** file-tree (3 repos) to the Proposal.
- Teardown = manual only; accumulation = accepted V1 tradeoff (D-12/D-13).
- **PUBLISHED** to Confluence DATA space under **DEMI Project Proposals** (parent 3120365775):
  **RFC: Data Forking and Review** → https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3658350707
  (page id 3658350707, Owner = Alex Sotis). Storage format; file-tree via code macro.

### 2026-10-22 — Visual restructure (page v2)
- Rebuilt the published page for readability (user: "looks terrible"): added a 6-step
  color-coded **panel flow diagram** + arrows, a **2-col architecture diagram** (generic
  dbt-shared-utils ↔ custom project repos), status lozenge + info header. Converted prose
  blocks to tables (building blocks, per-step mechanics, Expected Impact, Scope In/Out,
  Owner, Risks↔mitigation). Cut redundant prose (8-item flow list, 2 split paragraphs)
  without losing specifics. Verified stored storage format is valid (panels/tables/code
  macro all real elements, not text). NOTE: local `rfc_draft.md` is the older prose version
  — **published page (v2) is now source of truth.**

### 2026-10-22 — Em-dashes removed (v3) + Lucid diagram (v4)
- Removed ALL em-dashes from the published page (replaced with colons/periods/commas; kept
  flow arrows). User flagged em-dash as an AI tell.
- Built a 2-page **Lucid** diagram (doc 46b8fad6-cf7e-4a84-8efd-e024d21cbf87): Page 1 =
  end-to-end flow (color-coded, approve/request-changes decision + dashed re-fork/rebuild
  loop); Page 2 = code architecture (dbt-shared-utils GENERIC → dbt-fes-ae/finance/fmx
  CUSTOM). Verified both via PNG export (clean, no overlaps). Account-restricted view share
  link added to the Confluence page header (info panel).
  Lucid view: https://lucid.app/lucidchart/46b8fad6-cf7e-4a84-8efd-e024d21cbf87/view
- Added an **architecture** Lucid diagram (user wanted environments + forking, not a
  flowchart): GitHub (PR + Actions) → triggers dbt Cloud job → zero-copy CLONE of Prod into
  an isolated per-PR fork inside Snowflake → writes report tables → posts HTML to the PR →
  Ads approves. Real brand icons via `github.com/<org>.png` (github, dbt-labs, snowflakedb).
  Doc a17fc2ee-0349-4767-bd10-931dc4b2b48e; Confluence header now links Architecture (primary)
  + End-to-end flow. Icon gotcha: numeric avatar IDs were wrong; `github.com/<login>.png`
  resolves to correct logos.

### 2026-10-22 — POC PR opened (dbt-fes-ae #660, DRAFT)
- Built the POC in **dbt-fes-ae** (branch `fork-review/poc`, commit 72fb35c0, unsigned — no
  sig rule). Composes existing `dbfork` + `auto_delta`; no changes to either.
  - `macros/fork_and_review/fork_and_review.sql` — run-operation: `dbfork(clone_prod)` →
    per-model generic `auto_delta` diff (prod snapshot vs branch build, by dbfork naming
    convention) → `dispatch_custom_delta`.
  - `macros/fork_and_review/dispatch_custom_delta.sql` — `context.get('custom_delta__'~pipeline)`.
  - `custom-delta-report/fangraph/custom_delta__fangraph.sql` — audience-impact summary over
    `node → fangraph_id` (reassigned/added/removed, cluster counts). Grounded in the real
    `fangraph_id_final` grain.
  - `dbt_project.yml` — `macro-paths: ["macros","custom-delta-report"]`.
  - Validated with `dbt parse` (exit 0, dbt-fusion). NOT executed (needs warehouse). PR:
    https://github.com/fanatics-gaming/dbt-fes-ae/pull/660 (draft, label enhancement, +120/5 files).
  - POC scope note: built in-repo (dbfork/auto_delta live here today), not yet extracted to
    dbt-shared-utils. CI trigger + HTML renderer deferred per RFC.

### 2026-10-22 — POC tested live against FES_USERS.ALEX_SOTIS
- Ran the report-generating code (auto_delta inner macros + dispatch_custom_delta +
  custom_delta__fangraph) via a throwaway driver run-operation (dev target, SSO cached).
  Profile has only dev/test targets (both → FES_USERS.alex_sotis, FES_DATA_DEVELOPER,
  externalbrowser); no prod target, so rebuilding real fangraph was skipped. Used two
  synthetic (node, fangraph_id) tables with a known change (drop 100 / add 50 / reassign 200).
- Results (all matched expected): metrics row_count 10000→9950, pk_count_not_in_other 100/50,
  pk_not_null_unique true/true; conflicting_column_count FANGRAPH_ID=200; conflicting_rows=200;
  audience_impact nodes 10000/9950, added 50, removed 100, reassigned 200, fangraph_ids 1000/1000.
- Report tables left in FES_USERS.ALEX_SOTIS.fork_review__fangraph__fangraph_id_final_{metrics,
  conflicting_rows,conflicting_column_count,audience_impact} for inspection. Synthetic seeds
  dropped; throwaway macros removed; PR branch unchanged (72fb35c0).
- NOT covered by this test: fork_and_review's dbfork clone + naming glue and the real
  `dbt build --target test` (needs prod access + full fangraph rebuild) — still a Next Step.

### 2026-10-22 — Production slice built + validated (PR #660, commit e420d93a)
- Addressed my own critique. Added to the PR:
  - **custom_delta__fangraph rewritten to PARTITION STABILITY** (plurality-map prod cluster →
    branch cluster, count members that left the plurality). Label-independent, so a wholesale
    fangraph_id relabel reads as ~0 movement. This was the real semantic flaw.
  - **render_report.py** — report tables → one self-contained HTML (audience-impact card up
    top; raw column diff contextualized). Structured: build_html(payload) + fetch_report(conn).
  - **data-fork-review.yml** — label-gated GH Actions → dbt Cloud job → render → attach report.
    registry.yml (pipelines/models/PK/stakeholders) moved to scripts/fork_review/ (NOT under a
    macro-path — dbt tries to parse yaml in macro-paths; caused a fatal dbt1060, fixed).
- **Validated live** vs FES_USERS.ALEX_SOTIS with synthetic data (relabel-all + 1 split + 1
  merge + 5 add/5 drop): raw auto_delta = 9995/9995 "changed" (misleading); custom = 12 moved
  (0.12%), 3 splits, 1 merge. Renderer produced HTML; verified via Playwright a11y snapshot.
  Numbers re-derived by hand and match (Snowflake ::int rounds, so cluster boundaries differ
  from a floor estimate but metric is exactly right). Seeds + stale id-equality table dropped;
  temp macros removed; connector via `uv run --with snowflake-connector-python`, SSO cached.
- PR retitled "Data forking + delta review (fork_and_review)", still DRAFT (+466/9 files).
  Honest "team must wire" list in body: dbt Cloud job + service schema, workflow secrets
  (dbt Cloud API, Snowflake key-pair, FORK_REVIEW_SCHEMA), and the Ads pilot.

### 2026-11-09 — Corrected: CI runs dbt directly, NO dbt Cloud (user)
- User: "This will not be run through dbt cloud, just CI and locally." Reversed the earlier
  dbt-Cloud-job plan. Updated everywhere:
  - **Code** (commit 4814f786, pushed): ci_run.py now runs dbt via subprocess (build +
    run-operation) instead of the dbt Cloud API; workflow installs dbt-snowflake + writes a
    key-pair profiles.yml and runs dbt in the runner; README + local example (`--target test`)
    fixed. PR #660 body updated (secrets now = Snowflake key-pair + FORK_REVIEW_SCHEMA).
  - **RFC Confluence page → v7**: Proposal, step 1, mechanics, scope (added "dbt Cloud: out"),
    risk, next steps all de-dbt-Clouded.
  - **Lucid architecture → v3** (doc 73cec5eb; relinked in RFC): middle box "dbt Cloud" →
    "CI runner (GitHub Actions) / local", arrow "triggers dbt Cloud job" → "runs dbt".
  - decisions.md D-9 corrected.

### Still open
- Link the Confluence page from FEAT-10458 / DEMI-676 (Jira remote link) — offered, not yet done.
- Stakeholder review; then flip status Draft → In Review.
- (Optional) If Lucid's Confluence app is enabled, embed the diagram inline instead of linking.

### Notes
- Nothing under `projects/` is committed.
- RFC authoring will use the `rfc-writer` skill; publish to Confluence only after the user
  approves the local draft.
