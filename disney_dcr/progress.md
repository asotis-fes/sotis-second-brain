# Progress Log — Disney DCR

## 2026-08-21 — Session 1 (setup + ingest + initial diagnosis)
- Created project workspace (`projects/disney_dcr/`) + scaffolding.
- **Slack:** read main thread (C0A6X3B3WBT/1783711805) + Bhumika's current-driver DMs.
  Established: LiveRamp/Habu-on-Snowflake DCR; **gl_ = GrowthLoop**; two issues (wrong
  fangraph object; Disney can't see data). Found ENTDATA-2077, PRs #2882/#2885, and two
  high-value attachments (Success Guide PDF, Disney x Fanatics .eml — not yet ingested).
- **fanapp-terraform:** dissected `integrations-habu-dcr.tf`. Habu grants only cover
  `FES_INTEGRATIONS.DISNEY_HABU` tables; no fangraph object referenced. Ownership/dbt breakage
  fixed at HEAD.
- **dbt-fes-ae:** confirmed `fangraph` (table, `FANGRAPH.ADMIN.FANGRAPH`) vs `gl_fangraph`
  (view, `GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH`, alias drops `gl_`; filtered on US +
  marketing-eligible + commerce-fan + non-NFL-only). No Disney refs in this repo.
- **Docs:** wrote `dcr-reference.md` (Snowflake + LiveRamp best practices; share secure views
  not tables; connection lifecycle & failure modes).
- **Lineage pinned (smoking gun):** `dbt-fes-ae/models/fes_integrations/habu/disney_base.sql`
  (view) `ref('fangraph')`s the RAW table and feeds `disney_identifiers`/`disney_segments`
  (the tables the DCR registers). Fix for issue #1 = repoint `disney_base` → `ref('gl_fangraph')`.
  Nuance: disney_base already applies gl_fangraph's exact filter, so verify the swap's real
  impact (governance vs population).

- **Attachments ingested** (`attachments/`): Disney "In-Platform Success Guide" PDF +
  "RE- Disney x Fanatics" email. Success Guide = the 3-step client workflow (create dataset →
  configure at clean-room level → assign to questions). Email (Jade Lopez, Disney, Jun 30) =
  Disney's side complete; waiting on Fanatics to assign the dataset to 4 questions (Pre-DXP
  Activation by ID Type, DXP Activation, Disney Audience Index, Match Report), mapping the
  AUDIENCE column. → reframes Issue #2 as an unfinished in-platform workflow, not a grant.
  Disney contact = Jade Lopez (jade.a.lopez@disney.com), Ernie Spencer, Annie Zhao.

- **Live Snowflake diagnostics run (SELECT-only, findings.md §4):** DCR registers
  DISNEY_IDENTIFIERS + DISNEY_SEGMENTS with **IDENTITY_TYPE=None**; both 92.2M rows; ID =
  **BASE64 SHA256**; **IS_IDENTITY_COLUMN=None** (identity never declared); Habu column set
  (OPCO_TRANSACTED/IS_MULTI_OPCO_TRANSACTOR/TEAM_AFFINITY) is **stale** vs current tables
  (LEAGUE_AFFINITY); GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH confirmed a VIEW. → Issue #2 = a stack
  of incomplete/incorrect in-platform dataset config, NOT a Snowflake grant problem.

- **Issue #1 FIX opened:** [dbt-fes-ae PR #193](https://github.com/fanatics-gaming/dbt-fes-ae/pull/193)
  — `disney_base` repointed raw `fangraph` → `gl_fangraph` (GrowthLoop view), redundant filters
  dropped. Validated with `dbt parse` + `dbt compile -s disney_base+`. Not merged (awaiting review).
  Corrected an earlier note: BASE64 hash is intentional per Disney spec (habu.yaml), not a bug.
- Reconciled schema: prod `DISNEY_SEGMENTS`=`ID, LEAGUE_AFFINITY` matches CURRENT dbt code;
  Habu's registered columns (`OPCO_TRANSACTED/…/TEAM_AFFINITY`) are the STALE side (pre commits
  #156/#180, Aug 19-20). Confirms Habu dataset needs re-registration (Issue #2).

- **Live LiveRamp UI session (2026-08-21):** created new data connections for both tables;
  hit "No Data Available" on mapping (benign — schema read lag, resolved on refresh). Verified
  grants read-only: HABU_INSTALLER has **SELECT + REFERENCES WITH GRANT OPTION** on both tables
  (owner now `SVC_DBT_CLOUD_ROLE`); tables rebuilt from gl_fangraph today 16:18–16:20, 92.2M rows.
  → grant chain is fine; not a permissions problem.
- **Mapping field delimiter:** `ID` → None (single value). `LEAGUE_AFFINITY` was a Snowflake
  ARRAY (serializes to JSON `["League_NBA","League_NFL"]`) → no delimiter splits it cleanly.
  Fix = **[PR #196](https://github.com/fanatics-gaming/dbt-fes-ae/pull/196)**: emit
  `league_affinity` as comma-delimited string via `ARRAY_TO_STRING`. Then map with
  Field Delimiter = **Comma**. `DISNEY_IDENTIFIERS` (ID only) can be completed now, unaffected.

### Two open dbt PRs (both off main, not merged)
- **#193** — disney_base source: raw `fangraph` → `gl_fangraph` (Issue #1).
- **#196** — disney_segments `league_affinity`: ARRAY → comma-delimited string (mapping fix).
- After both merge: `dbt run -s disney_base+` rebuilds all three; then **delete & recreate the
  DISNEY_SEGMENTS Habu connection** (schema change) and re-map (ID=User Identifier/SHA256,
  LEAGUE_AFFINITY delimiter=Comma).

## 2026-08-26→28 — Session 2 (dbt deployed + LiveRamp access blocker)
- **Both dbt PRs merged + deployed.** Verified in Snowflake 2026-08-26: `DISNEY_SEGMENTS.LEAGUE_AFFINITY`
  is now **TEXT / comma-delimited string** (e.g. `League_Golf,League_MLB,League_NBA,...`), table
  rebuilt 2026-08-26 12:40. So #193 (gl_fangraph source) + #196 (ARRAY→string) are live.
  - Zoe reviewed #196 → added `COALESCE(..., '')` (Slack C0BM7PJHJSW/1787337715). Verified via
    Snowflake docs that `ARRAY_AGG` omits NULLs + `ARRAY_TO_STRING` converts NULL/empty → ''; so
    the COALESCE is a harmless explicit guard, not a real bug fix. Pushed to #196.
- **Field-delimiter mapping resolved:** `ID` → None; `LEAGUE_AFFINITY` → **Comma** (now that it's
  a delimited string). The **User Identifier → SHA256** toggle is on the **"Add Metadata"** step
  of Edit Mapping (step 2), NOT the "Map Fields" step (step 1).
- **BLOCKER — LiveRamp clean-room access.** The person driving the UI is **Zoe**, but the
  original Partner Admins on the "Disney x Fanatics" clean room are **Anna Smith** (on vacation
  2+ wks) and **Michael Chun** (left the company). Zoe has **org-level Clean Room Access = Yes**
  and was made an **org admin**, but that does **NOT** grant membership to this specific clean
  room (docs: "a user always acts through the role they are assigned in each clean room").
  As of end of session, the clean room still shows only Anna + Michael as members.
  - **Doc-confirmed:** owners (Disney) can't add partner-org users; each org adds its own users
    from *inside* the clean room (Clean Room → Clean Rooms → open room → Clean Room Access →
    Your Organization → Add Users and Groups → role = Partner Admin). The invitee automatically
    gets Partner Admin.
  - **Deciding question (unresolved):** can Zoe now *open* the Disney x Fanatics clean room? If
    yes → she self-adds via the path above. If no → org-admin didn't grant room membership, and
    the only routes are (a) **Disney/Jade sends a fresh clean-room invite to
    zoe.sarwar@betfanatics.com** (she accepts via Clean Room → Clean Room Requests → Inbound →
    Partner Admin), or (b) reach Anna, or (c) LiveRamp support / Fanatics CSM.

## 2026-09-01 — Session 3 (access resolved + full in-platform workflow completed)
- **ACCESS BLOCKER RESOLVED.** Confirmed via LiveRamp docs (+ empirically) that an **org-level
  Admin cannot self-join a partner clean room** — Zoe was org Admin but clicking "View Clean Room"
  returned **Access Denied**. The accepted clean-room invite was bound to **anna.smith@betfanatics.com**
  (individual), and Disney's attempt to re-add Zoe failed with "already a partner" (the *org* is
  already a partner). Resolution: **Anna (the one active Partner Admin) added Zoe from inside the
  room** — Clean Rooms → Disney x Fanatics → Clean Room Access → Your Organization → Add Users →
  **Partner Admin**. Zoe is now Partner Admin (org "Admin" role shows Anna + Zoe).
  - Doc-confirmed facts logged in `decisions.md`; the "how does Zoe get access" question is closed.
- **Both datasets provisioned + configured at clean-room level** (both show **Completed** in the
  room's Datasets tab). Left **"Partners Can Assign" = OFF** (doc-confirmed: it lets Disney run any
  query against our data — not needed since we assign the datasets ourselves).
  - Dataset **Configure** step: keep `Include` ON for every field, **Operation = None**, no filter
    values (share all rows; no audience filtering requested).
- **All 4 questions assigned** (Questions owned by "Disney - Ad Sales East"; a 5th "Ready" setup
  question left alone). Assign flow per question = Assign Ownership (pre-set, just Next) → Assign
  Datasets (pick our dataset for each macro slot) → Map Fields (for activation/index):
  - **DXP Activation**, **Pre-DXP Activation by ID Type**, **Disney Audience Index** → **DISNEY_SEGMENTS**;
    on the **Map Fields / ATTRIBUTE** (macro `CLIENT_ACTIVATION_LIST`, type STRING) step, chose
    **`LEAGUE_AFFINITY`** as the audience/segment column (per Disney guide: "select the column that
    contains the audience segment name(s)").
  - **Match Report** (CRQ-207089) → **DISNEY_IDENTIFIERS**. Question exposed **3 required CRM slots
    (CRM1/CRM2/CRM3)** + Disney's IDENTITY_GRAPH (already filled). We only have hashed-email ids
    (no MAIDs / raw customer ids), so **assigned DISNEY_IDENTIFIERS (ID) to all three CRM1/2/3**.
    ⚠️ Disney's Success Guide describes only a **single** client dataset per question, so this
    3-slot mapping is **unconfirmed** — flag to Jade for sanity-check.
- **Read the full Disney In-Platform Success Guide** (19 pp, `attachments/`): 3 report families —
  Pre-Planning Insights (Match Report, Disney Audience Index, Inventory Summary), Activation
  (Pre-DXP, DXP → sends audience IDs to Hulu/GAM/D+), Measurement (Reach&Freq, Reach Curves,
  Attribution, Unreached Audience). Guide confirms hashed-email → **SHA256**; assign step is one
  dataset via dropdown (no mention of CRM1/2/3).

### Next session — pick up here
1. **Notify Jade Lopez** (jade.a.lopez@disney.com) that both datasets are created, configured, and
   assigned to all 4 questions (draft email in the chat). **Include the Match Report CRM1/2/3
   question** — we mapped DISNEY_IDENTIFIERS/ID to all three; confirm that's the intended mapping
   (we have no MAIDs/customer ids).
2. **Disney runs the questions** → returns results.
3. **Verify the Match Report shows real overlap** (non-zero matched IDs). That's the proof the DCR
   is fixed (root cause was disney_base reading the wrong `fangraph` object → no matches). If
   overlap looks right, **close ENTDATA-2077**.
- (Optional) Read Jira ENTDATA-2077 for any extra detail.
