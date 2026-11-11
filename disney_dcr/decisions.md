# Decisions & Open Questions — Disney DCR

## Established facts (from Phase 1 ingest)
- It's a **LiveRamp/Habu clean room on Snowflake** (not native Snowflake DCR). Fanatics =
  provider; Disney = partner/consumer.
- **`gl_` = GrowthLoop.** The correct object to share is the GrowthLoop **view**
  `GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH` (dbt model `gl_fangraph`, a filtered view), NOT the raw
  table `FANGRAPH.ADMIN.FANGRAPH` (dbt model `fangraph`). Both are physically named `FANGRAPH`.
- Two distinct problems: (#1) wrong fangraph object; (#2) Disney can't see the shared dataset.
- Ticket: **ENTDATA-2077**. Terraform: `fanapp-terraform` →
  `root/fes-data/snowflake-v2/integrations-habu-dcr.tf`. dbt fangraph: `dbt-fes-ae`.
- The earlier ownership/dbt breakage (PRs #2882/#2885) is **fixed at terraform HEAD**.

## Decisions
- Investigate/document first (this project). **No changes** to the DCR/terraform/dbt without
  explicit approval. Do **not** re-share the originally (wrong) shared object.
- **Issue #1 fix — [dbt-fes-ae PR #193](https://github.com/fanatics-gaming/dbt-fes-ae/pull/193)**
  (`disney_base` → `ref('gl_fangraph')`). **MERGED + deployed** (confirmed 8/26).
- **Mapping fix — [dbt-fes-ae PR #196](https://github.com/fanatics-gaming/dbt-fes-ae/pull/196)**
  (`disney_segments.league_affinity` ARRAY → comma-delimited string via `ARRAY_TO_STRING`, +
  Zoe's `COALESCE(...,'')`). **MERGED + deployed** — verified `LEAGUE_AFFINITY` is now TEXT.
- **Hash encoding decision:** LEAVE as SHA256→BASE64. `habu.yaml` documents it as intentional
  "per Disney DCR spec." Do not change without a Disney/Habu-reported match failure.
- **Field delimiter:** `ID` = None; `LEAGUE_AFFINITY` = **Comma**. **User Identifier → SHA256**
  is set on the **"Add Metadata"** step of Edit Mapping (not "Map Fields").

## LiveRamp access model (doc-confirmed) — RESOLVED 2026-09-01
- **Org-level "Clean Room Access = Yes" / org "Admin" role ≠ membership in a specific clean room.**
  A user "always acts through the role they are assigned in each clean room, constrained by their
  org-level role." **Proven empirically:** Zoe (org Admin) clicking "View Clean Room" got
  **Access Denied**. There is **no documented path for an org Admin to self-join a partner room.**
- **Owners (Disney) cannot add partner-org users.** The accepted invite was bound to
  anna.smith@betfanatics.com; Disney re-adding Zoe failed with "already a partner" (the *org* is
  already a partner). Each org adds its own users from *inside* the room: Clean Rooms → open room →
  Clean Room Access → Your Organization → Add Users and Groups → Role = **Partner Admin**.
- **What actually worked:** **Anna** (the one active Partner Admin left) added Zoe from inside the
  room → Partner Admin. Recovery alternatives if no admin had been reachable: Disney re-invite to
  the user's email (accept via Clean Room Requests → Inbound), or LiveRamp support / Fanatics CSM.
- Docs: managing-users, managing-user-roles, invite-a-partner, announcement-clean-room-access-in-connect
  (docs.liveramp.com/connect/en/).

## In-platform assignment (done 2026-09-01)
- **"Partners Can Assign" = OFF.** Doc-confirmed it gives the partner authority to run *any* query
  against our data; not needed since we assign our own datasets. Only flip it on if the assign
  dropdown is empty (then Disney must assign to us first).
- **Dataset Configure step:** `Include` ON for all fields, **Operation = None**, no filter values
  (share all rows — no audience filtering was requested by Disney).
- **Question → dataset → field mapping:**
  - DXP Activation / Pre-DXP Activation by ID Type / Disney Audience Index → **DISNEY_SEGMENTS**;
    Map Fields ATTRIBUTE (`CLIENT_ACTIVATION_LIST`, STRING) = **`LEAGUE_AFFINITY`**.
  - Match Report → **DISNEY_IDENTIFIERS**; 3 required CRM slots → assigned **ID to all of CRM1/2/3**
    (we have no MAIDs/customer ids). **Unconfirmed vs Disney guide (which shows one dataset/question)
    → flag to Jade.**

## Open questions (to resolve)
1. 🟡 **Match Report CRM1/2/3 mapping — confirm with Jade.** We assigned DISNEY_IDENTIFIERS/ID to
   all three required CRM slots (no MAIDs/customer ids on our side); Disney's guide only describes
   one client dataset per question. Verify this is the intended mapping before relying on results.
2. ⏳ **Notify Jade → Disney runs the 4 questions → verify Match Report overlap** (non-zero matched
   ids = DCR fixed). Then close ENTDATA-2077.

### Resolved
- ✅ **Clean-room access** — Anna (active Partner Admin) added Zoe as Partner Admin from inside the
  room. Org Admin can't self-join a partner room (confirmed by docs + Access Denied).
- ✅ **In-platform workflow complete** — both datasets provisioned, configured (clean-room level),
  and assigned to all 4 questions with `LEAGUE_AFFINITY` as the audience field.
- ✅ fangraph→Disney link = `disney_base.sql` `ref('fangraph')`; fixed via PR #193 (merged).
- ✅ ARRAY delimiter problem fixed via PR #196 (merged) — `LEAGUE_AFFINITY` now comma string.
- ✅ Disney-side contact: **Jade Lopez** `jade.a.lopez@disney.com`, Ernie Spencer, Annie Zhao.
- ✅ Both attachments ingested (Success Guide PDF, Disney×Fanatics email).
- ✅ Grants fine: HABU_INSTALLER has SELECT+REFERENCES WITH GRANT OPTION on both tables.
- ✅ Identity was never declared (`IDENTITY_TYPE=None`) — fixed by setting User Identifier→SHA256
  on the Add Metadata mapping step. Hashing stays BASE64 (intentional).

## Notes
- DM from Alvin Chai called `data-infrastructure-deploy` "our terraform repo" — but the DCR
  code is in `fanapp-terraform`. Don't confuse the two.
