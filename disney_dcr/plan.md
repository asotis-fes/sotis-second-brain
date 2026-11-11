# Plan — Disney DCR investigation

## Phase 1 — Ingest ✅ (mostly done)
- [x] Read main Slack thread (C0A6X3B3WBT / 1783711805) + related threads
- [x] Read current-driver Bhumika DMs (the two issues; gl=GrowthLoop)
- [x] Pull DCR terraform from `fanapp-terraform` (integrations-habu-dcr.tf)
- [x] Confirm `gl_fangraph` view vs `fangraph` table in `dbt-fes-ae`
- [x] Snowflake/LiveRamp DCR docs → `dcr-reference.md`
- [ ] Locate `disney_base`/`disney_identifiers`/`disney_segments` model lineage (agent running)
- [ ] Ingest the two Slack attachments: `Clean Room In-Platform Success Guide_2026.pdf`
      (F0BSNN9Q072) and `RE- Disney x Fanatics.eml` (F0BSNNA9SAC).
      → **Alex will download them** into `projects/disney_dcr/` (e.g. `attachments/`). Next
      session: check for them there and summarize into `dcr-reference.md` (PDF) and
      `findings.md` §Issue #2 (email).
- [ ] Read Jira ENTDATA-2077 for any extra detail

## Phase 2 — Diagnose
- [ ] **Issue #1 (wrong object):** pin the exact place the raw `fangraph` is used and confirm
      the correct swap to `gl_fangraph` (`GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH`).
- [ ] Live SELECT-only Snowflake diagnostics:
      `SHOW GRANTS TO ROLE HABU_INSTALLER`, grants on the two Disney tables, and the
      `HABU_DATA_CONNECTIONS.DATA_CONNECTIONS.DATA_CONNECTIONS` registered-object rows.
- [ ] **Issue #2 (Disney can't see it):** determine cause from `.eml` + LiveRamp UI
      (analysis rules / mapping / consumer membership). If undetermined → **contact Disney-side
      engineer** (approved fallback). Do NOT guess.

## Phase 3 — Remediate (ONLY after diagnosis + explicit approval)
- [ ] Swap shared object: raw table `fangraph` → GrowthLoop view `gl_fangraph`
      (`GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH`). Ensure the old/wrong object is NOT re-shared.
- [ ] Terraform/dbt change (grants may need to extend to GROWTHLOOP db/schema + WH for view
      resolution). Follow fanapp-terraform two-PR/standard flow as applicable.
- [ ] Fix issue #2 (analysis rules / mapping / membership) per diagnosis.
- [ ] Verify Disney can consume the share; complete mapping to "Completed"; retry connection.
