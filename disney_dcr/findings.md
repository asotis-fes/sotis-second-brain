# Findings — Disney DCR

Evidence gathered during Phase 1 ingest. Distilled summaries + source links only.

## 1. Slack — main thread & related discussion

### What the DCR actually is
- It is a **LiveRamp / Habu Data Clean Room running on Snowflake** (Habu was acquired by
  LiveRamp; the UI is branded "LiveRamp → Clean Room → Data Connections"). Not native
  Snowflake DCR — it's the Habu-on-Snowflake product.
- Snowflake account: **Fanatics**. Provider side (Fanatics) registers Snowflake tables/views
  as **"Data Connections"** in the LiveRamp UI; Disney is the partner/consumer.
- Habu control table: `HABU_DATA_CONNECTIONS.DATA_CONNECTIONS.DATA_CONNECTIONS`
  (cols incl. `DATABASE_NAME`, `DB_SCHEMA_NAME`, `DB_TABLE_NAME`, `DATASET_TYPE`,
  `IDENTITY_TYPE`) — this is where a registered connection points at a Snowflake object.
- Installer role: **`HABU_INSTALLER`** (Habu-owned). It needs privileges on any object
  shared into the clean room.

### The Disney objects involved
- Schema created for this: `FES_INTEGRATIONS.DISNEY_HABU` (dev + prod) — requested by Zoe
  via #fes-data-snowflake-admin-requests (2026-07-04, ts 1783453099).
- Disney-side datasets registered as Data Connections:
  `FES_INTEGRATIONS.DISNEY_HABU.DISNEY_IDENTIFIERS` and `…​.DISNEY_SEGMENTS` (both tables).
- dbt manages/populates the DISNEY_HABU tables (a `disney_base` model + ephemeral shared-ID
  logic — see #fes-data-tech-ic thread 1783518258).

### Timeline of the original build (main thread C0A6X3B3WBT / 1783711805, Jul 10–21 2026)
Participants: **Zoe Sarwar** (built the terraform), **Anna Smith** (ACCOUNTADMIN, original
DCR builder), **Brett Pendleton** (stakeholder), **Bhumika Kansal** (manager).
- Terraform failing to create grants on `HABU_DATA_CONNECTIONS…` with "object does not
  exist or not authorized" — root cause: the terraform role can't see Habu-installer-owned
  objects; also a block referenced **`FAN_DATA_EXCHANGE_PROD` which is not a role** (Anna:
  "this is why terraform is failing").
- Data connection failing with **"Grant not executed: Insufficient privileges."** Habu docs:
  **`HABU_INSTALLER` needs OWNERSHIP or at least SELECT + REFERENCES** on the shared tables.
  Zoe had granted only SELECT → adding **REFERENCES** advanced it.
- Deeper issue: HABU_INSTALLER must be able to **grant privileges onward to clean-room
  participants**. Two options debated: (1) transfer OWNERSHIP to HABU_INSTALLER, or
  (2) keep ownership + **WITH GRANT OPTION**. 
- **PR #2882** — grant OWNERSHIP on Disney tables to HABU_INSTALLER.
- **PR #2885** — ownership transfer; this **broke dbt** (all privileges revoked, dbt could
  no longer manage the Disney tables). Anna manually restored: granted OWNERSHIP back to
  `SVC_MWAA_ROLE` (dbt's role) + re-granted SELECT/REFERENCES to the
  `FES_INTEGRATIONS_DISNEY_HABU_ADMIN`/`_READ_ONLY` database roles. Tables restored.
  ⚠️ Was this fixed **in terraform code** or only patched in Snowflake? (Bhumika asked;
  needs verification — risk it re-breaks on next apply.)
- By **2026-07-21**, both DISNEY_SEGMENTS & DISNEY_IDENTIFIERS Data Connections showed
  **Completed / Active** in LiveRamp. But Anna then hit a **"data mapping error"** and
  said she needed to sync with Zoe. Thread goes quiet after that.
- Jira: **ENTDATA-2077** (Disney DCR).

### CURRENT state of "what's broken" — Bhumika DM (2026-08-20/21), the driver for this project
Bhumika stated **two issues** explicitly:
1. **Wrong object shared.** "We used **regular fangraph** vs what's in **GrowthLoop**. It's
   not fixed." → **`gl_` = GrowthLoop.** We shared the raw `fangraph` table instead of the
   **GrowthLoop view `gl_fangraph`**. Must reshare `gl_fangraph`, and **not** re-share the
   original wrong object.
2. **Disney cannot see the shared data.** "We shared the old dataset, but Disney came back
   saying they cannot see it." → a consumer-side visibility/access problem in the clean room
   (separate from the wrong-object issue).
- Alex (user) + Bhumika agree there may be **no further written detail** on issue #2 —
  contacting a **Disney-side engineer** is explicitly on the table if we can't determine it.
- **Do NOT guess / do NOT re-share the originally shared object.**

### High-value attachments to ingest (posted by Bhumika in group DM 2026-08-21, C0BRMM0GPQB)
- 📄 **`Clean Room - In-Platform Success Guide_2026.pdf`** (Slack file `F0BSNN9Q072`, 1.2 MB)
  — LiveRamp/Habu clean-room success/best-practice guide. **Not yet ingested** (binary PDF,
  too large to auto-extract inline — download from Slack or open manually to review).
- 📧 **`RE- Disney x Fanatics.eml`** (Slack file `F0BSNNA9SAC`, 2.0 MB) — the Disney↔Fanatics
  email thread; likely contains Disney's "cannot see it" detail (issue #2). **Not yet
  ingested** (binary .eml). Prime source for the Disney-side symptom.

### Other related Slack references
- #fes-data-tech-ic 1783960636 — "Granting OWNERSHIP on Disney tables to HABU_INSTALLER"
  (PR #2882).
- #fes-data-tech-ic 1783518258 — `disney_base` dbt model, ephemeral shared-ID logic.
- #fes-data-alerts 1783524481 — `disney_segments` dbt dup test failed (data-quality).
- #fes-data-snowflake-admin-requests 1786550006 — a later Zoe admin request (unread; may be
  follow-up).
- #fes-data-leads 1781796783 — Anna posted ENTDATA-2077 as the Disney DCR ticket.
- DM Alvin Chai 1783431694 — points at `data-infrastructure-deploy` as "our terraform repo"
  (note: DCR terraform is actually in **fanapp-terraform**; data-infrastructure-deploy may be
  a red herring or a different layer — verify).

## 2. fanapp-terraform — DCR infrastructure code

File: `root/fes-data/snowflake-v2/integrations-habu-dcr.tf` (repo `fanatics-gaming/fanapp-terraform`, HEAD of `main`).

- The Habu DCR terraform is intentionally narrow. Habu's own framework self-mutates (via a
  `redbeard` CLI); terraform only manages the `HABU_INSTALLER` role, account-level privileges,
  a setup warehouse, and **per-connection source grants**.
- Grants at HEAD (integrations-habu-dcr.tf:152-206):
  - `HABU_INSTALLER`: USAGE on DB `FES_INTEGRATIONS` + schema `DISNEY_HABU`;
    **SELECT + REFERENCES WITH GRANT OPTION** on **ALL TABLES** and **FUTURE TABLES** in
    `FES_INTEGRATIONS.DISNEY_HABU`. Tables stay **owned by `SVC_MWAA_ROLE` (dbt)** so dbt
    full-refresh doesn't break; WITH GRANT OPTION lets Habu delegate onward to participants.
  - `FES_DATA_DEVELOPER`: SELECT on `HABU_DATA_CONNECTIONS.DATA_CONNECTIONS.DATA_CONNECTIONS`
    and `…​.DATA_CONNECTION_COLUMNS` (observability).
  - Account privs to HABU_INSTALLER: CREATE DATABASE/WAREHOUSE/SHARE, IMPORT SHARE,
    EXECUTE TASK/MANAGED TASK.
- **PR #2882** (merged): swapped SELECT+REFERENCES → **OWNERSHIP** on `DISNEY_IDENTIFIERS`/
  `DISNEY_SEGMENTS` to satisfy Habu's "Insufficient privileges."
- **PR #2885** (merged): added `outbound_privileges = "REVOKE"` (= GRANT OWNERSHIP … REVOKE
  CURRENT GRANTS). This is what **broke dbt**. Ownership was manually reverted to
  `SVC_MWAA_ROLE` on 2026-07-13, and the two `snowflake_grant_ownership` resources were
  **removed at HEAD** — file now settles on SELECT+REFERENCES WITH GRANT OPTION
  (documented in a comment at integrations-habu-dcr.tf:172-181). ✅ So the dbt-breakage was
  fixed in code, not just patched in Snowflake — resolves Bhumika's re-break worry.
- Other files: `db-fes_integrations.tf` defines the `DISNEY_HABU` schema (admin roles = MWAA/
  dbt_cloud). `outbound_shares-fangraph_secure_views.tf` + `db-fangraph.tf` define FANGRAPH
  secure views (e.g. `FANGRAPH_NON_PII_V`) — these are a **separate outbound-share mechanism,
  not wired to Habu.**

> **Key point:** The Habu DCR terraform contains **no reference to any fangraph object**. It
> only grants Habu access to the `FES_INTEGRATIONS.DISNEY_HABU` tables. The fangraph→Disney
> linkage is in **dbt**: `disney_base` (in `dbt-fes-ae`) reads raw `fangraph` and feeds the
> `DISNEY_IDENTIFIERS`/`DISNEY_SEGMENTS` tables the DCR registers. → **Issue #1 is fixed in dbt
> (`disney_base.sql`), not in terraform.** (See §3 and the Issue #1 hypothesis below.)
> Terraform grants are on FUTURE/ALL tables in DISNEY_HABU, so they'd still cover the tables
> after the source swap — but if the view resolution needs GROWTHLOOP warehouse/db grants for
> Habu, that could require a terraform touch. Verify.

## 3. dbt-fes-ae — gl_fangraph view vs fangraph model/table

- **`fangraph` (raw TABLE):** model `models/fangraph/fangraph/fangraph.sql`,
  `materialized: table`, → prod relation **`FANGRAPH.ADMIN.FANGRAPH`** (dev
  `FANGRAPH_DEV.ADMIN.FANGRAPH`). Warehouse `FDE_FANGRAPH_3XL_WH`.
- **`gl_fangraph` (GrowthLoop VIEW):** model `models/growthloop/gl_fangraph.sql`,
  `materialized: view`, config in `models/growthloop/growthloop.yaml` — **`alias: fangraph`**,
  database `GROWTHLOOP` (prod) / `GROWTHLOOP_DEV`, schema `FLYWHEEL_SYSTEM`.
  → prod relation **`GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH`** (the `gl_` prefix is the dbt model
  name only; the physical view is named `FANGRAPH`).
- **Relationship:** `gl_fangraph` is a **filtered view over the `fangraph` table**:
  ```sql
  FROM {{ ref('fangraph') }}
  WHERE fangraph_country = 'US'
    AND fangraph_account_access_available = TRUE
    AND commerce_fan_indicator = 1
    AND commerce_nfl_only = 0
  ```
  i.e. US + marketing-eligible + commerce-fan + non-NFL-only, curated column list. `gl_` =
  the **GrowthLoop** consumption layer (`models/growthloop/`, all views in
  `GROWTHLOOP.FLYWHEEL_SYSTEM`). (Whether it's formally a "governed/PII-safe" layer is
  **not documented** — it does select PII columns; treat "gl_ = governed" as unconfirmed. But
  it is clearly the **filtered/eligible population**, which is why it's the correct object.)
- **The Disney models ARE in `dbt-fes-ae`** under **`models/fes_integrations/habu/`**:
  `disney_base.sql` (view), `disney_identifiers.sql` (table), `disney_segments.sql` (table),
  config in `habu.yaml` (prod db `FES_INTEGRATIONS`, schema `DISNEY_HABU`). (A first term-search
  missed them; a targeted follow-up confirmed they exist here.) `disney_base` currently
  `ref()`s the raw `fangraph` — see the Issue #1 hypothesis for the exact SQL and the fix.

> **Naming trap to carry into remediation:** both the correct view and the wrong table are
> physically named `FANGRAPH`. They differ only by database.schema:
> - ✅ Correct (share this): **`GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH`** (view, filtered/eligible)
> - ❌ Wrong (currently used): **`FANGRAPH.ADMIN.FANGRAPH`** (raw table, full population)

## 3b. Ingested attachments (Bhumika, Slack, downloaded to `attachments/`)

### 📄 `Clean Room - In-Platform Success Guide_2026.pdf` — Disney's official Habu guide
Disney Advertising's step-by-step guide (last updated 8/2024). Confirms the **end-to-end
workflow has THREE client-side steps**, and the Data Connection (what we've been fighting over)
is only step 1:
1. **Create a dataset — Organizational level** = a "Data Connection" pointing at a Snowflake
   object (`Job Name = Database.Schema.Table`, enter DB/schema/table/**view** exactly as in
   Snowflake). Set data types; **toggle the ID column to "User Identifier"** and pick the
   identifier type (**hashed email → SHA256**; maid → Mobile Device Identifier). Status goes
   Pending → **Mapping Required** → Complete. NOTE: updates in Snowflake auto-refresh into
   Habu; **you cannot add columns to an existing dataset — a new dataset is required.**
2. **Configure the dataset — Clean Room level** (separate step!): in the clean room → Datasets
   → Configure; optionally **filter to specific audiences** (AUDIENCE Equals/In …). Status
   Pending → In Progress → Complete. Only then can it be assigned to questions.
3. **Assign the dataset to each Question**: Manage Datasets on each question → pick the dataset.
   For activation questions you **Map Fields → select the column holding the audience segment
   names**. **"If client does not see a dropdown at this step, notify Disney — they must assign
   the dataset to the client."** Then notify Disney; **Disney runs the questions.**
- Permissions have an Org level and a **Clean Room level (Access → Partners & Users)**. A user
  who can see the Habu UI but has a grey "Details" button **hasn't been added to the clean room.**
- Report types = Pre-Planning Insights (**Match Report** = overlap of Disney × client ids/
  households; **Disney Audience Index**), **Activation**, **Measurement**.

### 📧 `RE- Disney x Fanatics.eml` — the Disney↔Fanatics thread (Mar–Jun 2026)
Thread from **Jade Lopez (Disney, Data Activation Analyst)**. Technical content is in the
top ~1/3; the rest (Mar–Apr) is legal/MSA redlines + scheduling (not technical).
- **Timeline:** MSA signed ~May 1 → clean-room invite sent to Michael Chun (May 15) → Fanatics
  set up DCR + CLI install (with Habu's "Jonah and Medina") → invite finally accepted by Anna
  (late June) → **June 30: Disney says setup is COMPLETE on their side and the ball is in
  Fanatics' court.**
- **⭐ The pivotal June 30 message (Jade → Anna):** *"The setup is now complete and ready for you
  to **upload and assign the Fanatics dataset.** During the dataset assignment process you'll be
  prompted to select a Field Value for certain questions — select the column that contains the
  audience segment names, likely labeled 'AUDIENCE.' … please confirm once the data assignment
  is complete and we can proceed."* Disney listed the **4 questions the Fanatics dataset must be
  assigned to**:
  1. Snowflake Pattern – **Pre-DXP Activation by ID Type** (Generic)
  2. Snowflake Pattern – **DXP Activation** (Generic)
  3. Snowflake Pattern – **Disney Audience Index** (Generic)
  4. Snowflake Pattern – **Match Report** (Generic)
- **Initial dataset intended** (Michael Chun, Jun 10): "Customer IDs and their sports affinity
  (e.g. Leagues)." Fanatics Snowflake region: **aws-us-east-1**.
- **Contacts (answers "who's the Disney-side contact"):**
  - Disney: **Jade Lopez** `jade.a.lopez@disney.com` (Data Activation Analyst — the hands-on
    technical/ops contact), **Ernie Spencer** `ernie.spencer@disney.com` (Sr Mgr, Data
    Activation & Solutions), **Annie Zhao** `annie.zhao@disney.com`, Christine Chung / Nicholas
    Winfrey (commercial/legal).
  - Fanatics: Michael Chun (Sr Dir Data), Anna Smith, Somebi Eleh; Andrew Jarvie, Ryan Gordon,
    Kevin Klasila, Kevin Longo (commercial).

## 4. Snowflake / LiveRamp DCR mechanics (from docs — see `dcr-reference.md`)

- LiveRamp(Habu)-on-Snowflake "hybrid" clean room. `redbeard` CLI installs
  `HABU_CLEAN_ROOM_COMMON` + `HABU_DATA_CONNECTIONS`. A "Data Connection" registers one
  Snowflake table/view; the service role needs USAGE(db/schema)+SELECT(object), and **views
  additionally need warehouse USAGE/OPERATE to resolve**.
- Snowflake **strongly recommends sharing SECURE VIEWS, not raw tables** — the view hides
  base schema/DDL/unselected columns/rows and lets you bake in filtering/hashing/row-access.
  → independent confirmation that sharing `gl_fangraph` (view) over `fangraph` (table) is
  the correct, best-practice choice, not just a preference.
- Connection lifecycle: **Verifying Access → Mapping Required → Completed**. "Mapping" =
  set columns, PII flags, types, partition columns, identifier fields (email→SHA-256).
  "**Waiting For File**" is a **CSV-upload-only** status (odd that we saw it for a Snowflake
  connection on Jul 10 — flag).
### ✅ Live Snowflake diagnostics (run 2026-08-21, conn FAN_DATA_EXCHANGE_PROD, role
FES_DATA_DEVELOPER, wh FDE_DEVELOPER_WH — all SELECT-only)

1. **Registered data connections** (`HABU_DATA_CONNECTIONS.DATA_CONNECTIONS.DATA_CONNECTIONS`):
   | DATABASE | SCHEMA | TABLE | DATASET_TYPE | IDENTITY_TYPE |
   |---|---|---|---|---|
   | FES_INTEGRATIONS | DISNEY_HABU | DISNEY_IDENTIFIERS | Generic | **None** |
   | FES_INTEGRATIONS | DISNEY_HABU | DISNEY_SEGMENTS | Generic | **None** |
   → confirms the DCR shares the two derived Disney tables (built from raw `fangraph`).
   **`IDENTITY_TYPE = None` on both** = the identity/identifier type was never set.
2. **Row counts:** both `DISNEY_IDENTIFIERS` and `DISNEY_SEGMENTS` = **92,199,939 rows**
   (populated — not an empty-data problem).
3. **ID hash format:** sample `ID` = `CRkCRsLtcpcw1o87/JZtXPQm55Eoaov7VHLZILUNENc=` →
   **BASE64-encoded SHA256** (matches `disney_base`'s `TO_CHAR(TO_BINARY(SHA2(email),'HEX'),
   'BASE64')`). **This is INTENTIONAL** — `habu.yaml` documents the id column as "Base64-encoded
   SHA256 hash of lowercased email address … per Disney DCR spec." So base64 is by design; the
   earlier hex-vs-base64 concern is **downgraded** (only revisit if Disney reports match failures).
4. **Column mapping metadata** (`…​.DATA_CONNECTION_COLUMNS`): **`IS_IDENTITY_COLUMN = None`** on
   the `ID` column (and all columns) → the "User Identifier" toggle / SHA256 identifier
   declaration was **never done in Habu**. Also **schema drift**: Habu has registered columns
   `ID, OPCO_TRANSACTED (ARRAY), IS_MULTI_OPCO_TRANSACTOR (BOOLEAN), TEAM_AFFINITY (ARRAY)`,
   but the **current** Snowflake tables are `DISNEY_IDENTIFIERS(ID)` and
   `DISNEY_SEGMENTS(ID, LEAGUE_AFFINITY ARRAY)` → the registered dataset is **stale** relative
   to what dbt produces now (and per Disney's guide, you can't add columns to an existing
   dataset — a **new dataset** is required).
5. **`GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH` exists and is a VIEW** → the Issue #1 target is real.
6. Segment column is **`LEAGUE_AFFINITY` (ARRAY)** — not a clean string "AUDIENCE" column of
   segment names that Disney's activation questions expect to map. (Michael Chun's email: the
   dataset = "Customer IDs and their sports affinity (e.g. Leagues)".)

_Not yet run (need higher privs / next session):_ `SHOW GRANTS TO ROLE HABU_INSTALLER` and
grants on the two tables (FES_DATA_DEVELOPER may not see them).

## Root-cause hypotheses (evidence-backed — flagged where unconfirmed)

There are **two separate problems** (per Bhumika, 2026-08-20):

### Issue #1 — Wrong object shared (raw `fangraph` table instead of GrowthLoop `gl_fangraph` view)
- **Evidence:** Bhumika: "We used regular fangraph vs what's in GrowthLoop. It's not fixed."
  `gl_` = GrowthLoop.
- **✅ FIX LOCATION PINNED — the dbt lineage (all in `dbt-fes-ae`, `models/fes_integrations/habu/`):**
  - `disney_base.sql` (materialized **view**) ← **reads `{{ ref('fangraph') }}` = the RAW table
    `FANGRAPH.ADMIN.FANGRAPH`.** This is the wrong source.
  - `disney_identifiers.sql` (table) = `SELECT DISTINCT id FROM {{ ref('disney_base') }}`.
  - `disney_segments.sql` (table) = builds off `{{ ref('disney_base') }}` joined to
    `source('seek_insights__seek_insights_info','growthloop_audiences_v')`.
  - These two tables (`FES_INTEGRATIONS.DISNEY_HABU.DISNEY_IDENTIFIERS`/`DISNEY_SEGMENTS`) are
    what the LiveRamp Data Connections register → what Disney receives.
  ```sql
  -- disney_base.sql (current — WRONG source)
  SELECT fangraph_id,
         TO_CHAR(TO_BINARY(SHA2(LOWER(fangraph_email),256),'HEX'),'BASE64') AS id
  FROM {{ ref('fangraph') }}                       -- FANGRAPH.ADMIN.FANGRAPH (raw table)
  WHERE fangraph_email IS NOT NULL
    AND fangraph_country = 'US'
    AND fangraph_account_access_available = TRUE
    AND commerce_fan_indicator = 1
    AND commerce_nfl_only = 0
  ```
- **The fix:** point `disney_base` at `{{ ref('gl_fangraph') }}`
  (`GROWTHLOOP.FLYWHEEL_SYSTEM.FANGRAPH`, the GrowthLoop view) instead of raw `fangraph`.
- **⚠️ IMPORTANT NUANCE TO VERIFY (don't over-conclude):** `disney_base`'s WHERE clause is
  **byte-for-byte the same filter** `gl_fangraph` applies over `fangraph` (US + acct-access +
  commerce-fan + non-NFL-only), plus `fangraph_email IS NOT NULL`. So *right now the row
  population is effectively identical* whether it reads raw `fangraph` (with these predicates)
  or `gl_fangraph`. That means switching to `gl_fangraph` is primarily a **source-of-truth /
  governance** change (GrowthLoop owns the eligible-population definition; future filter
  changes propagate) rather than an obvious population change. **Open question:** is the real
  concern (a) governance/single-source, or (b) does `gl_fangraph` actually differ (extra
  columns, additional GrowthLoop logic, or a filter that has since diverged), or (c) was the
  **"old dataset" already shared to Disney built before these predicates existed** (broader
  population)? Confirm before assuming the swap changes what Disney sees.
- Snowflake best practice independently supports sharing the (secure) **view**, not the table.
- Confidence: **HIGH** the wrong source is raw `fangraph` and the intended source is
  `gl_fangraph`; **the functional impact of the swap needs confirming** (see nuance above).

### Issue #2 — Disney (consumer) cannot see the shared dataset
- **Evidence:** Bhumika: "we shared the old dataset, but Disney came back saying they cannot
  see it." + the Disney email (June 30) + the Success Guide workflow.
- **CONFIRMED root causes (from live Snowflake diagnostics + docs) — not a Snowflake grant
  problem:**
  1. **Identity never declared in Habu.** `IDENTITY_TYPE = None` on both connections and
     `IS_IDENTITY_COLUMN = None` on the `ID` column. The "User Identifier → SHA256" step Disney
     asked for (June 30 email) and the guide requires was **never completed**. Without a
     declared identifier, Habu can't match Fanatics ids to Disney's → Disney sees no overlap.
  2. **Registered dataset is stale / schema-drifted.** Habu has columns `ID, OPCO_TRANSACTED,
     IS_MULTI_OPCO_TRANSACTOR, TEAM_AFFINITY`; current Snowflake tables are `ID` and
     `ID, LEAGUE_AFFINITY`. The dataset in Habu no longer matches the Snowflake tables, and per
     the guide you **can't add columns to an existing dataset — a new dataset is required.**
  3. ~~ID encoding wrong~~ — **RULED OUT.** BASE64 SHA256 is intentional per Disney DCR spec
     (documented in `habu.yaml`). Not a defect.
  4. **Segment column shape.** `LEAGUE_AFFINITY` is an ARRAY, not a clean string "AUDIENCE"
     column of segment names that the activation questions map to. (Verify Habu accepts the
     ARRAY, or whether it must be flattened.)
- **Also still to confirm in the LiveRamp UI:** whether the dataset was ever **configured at
  the clean-room level** and **assigned to the 4 questions** (Pre-DXP Activation by ID Type,
  DXP Activation, Disney Audience Index, Match Report). The "0 Analytical, 0 List" Jul-21
  screenshot suggests not.
- **Disney-side contact (known):** **Jade Lopez** `jade.a.lopez@disney.com` (Data Activation
  Analyst), Ernie Spencer, Annie Zhao.
- Confidence: **HIGH** that Issue #2 is a stack of incomplete/incorrect in-platform dataset
  configuration (identity mapping + stale schema + encoding), fixable by rebuilding the dataset
  correctly and completing the configure→assign workflow — **not** a Snowflake permissions gap.

### What is NOT the problem (resolved earlier)
- The dbt-breakage from the ownership transfer (PR #2885) was **fixed in terraform code** at
  HEAD (ownership back to SVC_MWAA_ROLE; SELECT+REFERENCES WITH GRANT OPTION). Won't re-break
  on next apply. The DISNEY_HABU tables exist and both connections reached "Completed/Active."
