# Snowflake / LiveRamp(Habu) Data Clean Room — Reference & Best Practices

Distilled from Snowflake + LiveRamp docs (Phase 1 research). Source URLs inline.
Use this to reason about how the Disney DCR *should* work.

## What kind of DCR this is
- **LiveRamp Clean Room, formerly Habu** (LiveRamp acquired Habu), running **on Snowflake**
  ("hybrid clean room"). A software agent is installed into the Fanatics Snowflake account
  via the **`redbeard` CLI** (`habu-snowflake-cli`), provisioning `HABU_CLEAN_ROOM_COMMON`
  and `HABU_DATA_CONNECTIONS` databases. `HABU_DATA_CONNECTIONS.DATA_CONNECTIONS.DATA_CONNECTIONS`
  stores registered-connection metadata.
  - Refs: liveramp.com/…​/faq--liveramp-clean-room-snowflake-cli ; pypi.org/project/habu-snowflake-cli

## Native Snowflake DCR model (background)
- **Provider/consumer** at the account level. Consumer never sees provider raw data — access
  is **only through approved templates/analysis jobs**; no raw data copied. Provider controls
  templates, joinable/output columns, and can layer column/join policies + differential privacy.
  - Ref: docs.snowflake.com/en/user-guide/cleanrooms/getting-started
- **Share SECURE VIEWS, not raw tables.** Snowflake *strongly recommends* sharing secure
  views/UDFs instead of tables: a secure view hides its DDL and unselected columns/rows and
  disables optimizations that could leak filtered-out rows. Bake column selection, hashing,
  and row-access policy into the view.
  - Refs: docs.snowflake.com/en/user-guide/data-sharing-secure-views ; …​/views-secure
- **Onward-grant privilege is real:** to link/share data to the analysis runner, the provider
  role needs `REFERENCE_USAGE … WITH GRANT OPTION` on the underlying data + USAGE on any
  referenced policy objects. (This is the Snowflake-layer reason Habu needed REFERENCES +
  grant option, even though the LiveRamp UI abstracts it.)
  - Ref: docs.snowflake.com/en/user-guide/cleanrooms/manage-access

## How a LiveRamp "Data Connection" works
Register a Snowflake table/view; grant the clean-room service role access:
```sql
GRANT USAGE ON DATABASE <DB> TO ROLE <SVC_ROLE>;
GRANT USAGE ON SCHEMA <DB>.<SCHEMA> TO ROLE <SVC_ROLE>;
GRANT SELECT ON TABLE|VIEW <DB>.<SCHEMA>.<OBJ> TO ROLE <SVC_ROLE>;
-- VIEWS additionally need warehouse privileges to resolve:
GRANT USAGE, OPERATE ON WAREHOUSE <WH> TO ROLE <SVC_ROLE>;
```
The Snowflake credential user should have this role as its **default role** + a **default
warehouse**. Ref: liveramp.com/…​/configure-a-snowflake-data-connection-for-a-hybrid-clean-room

### Data-connection lifecycle / statuses (⭐ relevant to our symptoms)
- **Verifying Access** → **Mapping Required** → (after mapping) **Completed**.
- **Mapping Required / "Edit Mapping":** you set column names, **PII flags**, data types,
  **partition columns**, and **user-identifier fields** (e.g. Raw Email → auto SHA-256).
- **"Waiting For File"** = **CSV/local-upload connections only** — no valid CSV at the upload
  location. **NOT a Snowflake-table state.** (We saw this on Jul 10 for DISNEY_IDENTIFIERS —
  odd for a Snowflake connection; worth understanding.)
- After a fix, **retry** the connection so the schema re-reads.

## Best practice: view vs table (directly on point for issue #1)
Prefer a **governed/secure view** over the raw table: hides base schema/DDL/unselected cols,
lets you bake in column selection + hashing + row-access filtering, and decouples the
clean-room contract from physical table changes. Sharing the raw table exposes the full schema
and all columns and forfeits these controls. Only tradeoff: views need warehouse grants to
resolve. → This is exactly why we must share the filtered GrowthLoop view, not raw `fangraph`.
  - Refs: docs.snowflake.com/en/user-guide/data-sharing-secure-views ; phData secure-vs-nonsecure blog

## Likely failure modes (map to our two issues)
- **"No active warehouse selected"** — WH name mismatch, wrong env, no default WH on the user,
  or role lacks USAGE/OPERATE on the WH (top documented cause; note VIEWS need WH to resolve).
- **Access/verification stuck** — missing SELECT on object or USAGE on db/schema; role not the
  credential user's default role.
- **Data-mapping errors** — columns not populated / wrong types, PII not flagged, **partition
  columns not indicated** (Snowflake requires partition-key indication), identifier fields not
  designated for hashing. Fix → retry. ← matches Anna's Jul-21 "data mapping error."
- **Consumer can't see the data (issue #2 candidate)** — in the Jul-21 screenshot both Disney
  connections showed **"0 Analytical, 0 List"** default analysis rules. Without analysis
  rules / the dataset being added to the clean room's shared/permissioned config, the partner
  (Disney) has nothing they're allowed to query → "cannot see it." (Hypothesis — verify.)

## ⭐ Disney's actual client workflow (from the In-Platform Success Guide PDF)
The single most useful artifact. The client (Fanatics) must do **three** things — the Snowflake
Data Connection is only the first:
1. **Create dataset — Org level** (the Data Connection): point at `DB.Schema.Table|View`; set
   column data types; toggle the **ID column → User Identifier** (hashed email ⇒ **SHA256**;
   maid ⇒ Mobile Device Identifier). Status Pending → **Mapping Required** → Complete. Columns
   can't be added later — a new dataset is required to add fields.
2. **Configure dataset — Clean Room level** (separate!): in the clean room → Datasets →
   Configure; optionally filter to audiences (`AUDIENCE Equals X` / `AUDIENCE In X, Y, Z`).
   Status Pending → In Progress → Complete.
3. **Assign dataset to each Question**: Manage Datasets per question → select dataset; for
   activation questions **Map Fields → column with the audience segment names (the "AUDIENCE"
   column)**. If no dropdown appears, **Disney must assign the dataset to the client** — notify
   them. Then notify Disney, who **runs the questions** and returns results.
- Two permission scopes: Org level and **Clean Room level (Access → Partners & Users)**.
- The 4 questions Disney set up for this clean room: **Pre-DXP Activation by ID Type, DXP
  Activation, Disney Audience Index, Match Report** (Match Report = Disney×client id/household
  overlap).

## Verification gaps (stated honestly, not guessed)
- Public LiveRamp docs did **not** literally name `HABU_INSTALLER` nor explicitly require
  `REFERENCES`/`OWNERSHIP`/`WITH GRANT OPTION` for the data-connection role. Those specifics
  live in gated portal docs or the installed native-app grants. **Confirm against the actual
  install**: `SHOW GRANTS TO ROLE HABU_INSTALLER;` and inspect `HABU_DATA_CONNECTIONS`.
- 📄 A first-party doc — **"Clean Room - In-Platform Success Guide_2026.pdf"** (Bhumika, Slack
  `F0BSNN9Q072`) — should be the authoritative best-practice reference. Ingest it to supersede
  the public-doc gaps above.
