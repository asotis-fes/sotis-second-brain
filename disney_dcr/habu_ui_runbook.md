# Habu / LiveRamp UI Runbook — Disney DCR (Issue #2)

Steps to finish the Fanatics side in the LiveRamp/Habu Clean Room. Based on Disney's
In-Platform Success Guide + our Snowflake diagnostics. Fanatics = client; clean room = "Disney
x Fanatics". Contact: Jade Lopez (jade.a.lopez@disney.com).

## Why the current state is broken (recap)
- Registered dataset in Habu has **stale columns** (OPCO_TRANSACTED/TEAM_AFFINITY) vs current
  tables (`DISNEY_IDENTIFIERS(ID)`, `DISNEY_SEGMENTS(ID, LEAGUE_AFFINITY)`). Columns can't be
  edited on an existing dataset → **create a NEW dataset**.
- `IDENTITY_TYPE = None` / `IS_IDENTITY_COLUMN = None` → the ID column was **never declared as a
  User Identifier**. This is the key reason Disney can't match/see data. **Must fix.**
- Dataset was likely never configured at clean-room level nor assigned to Disney's 4 questions.

## Step 1 — Create a NEW dataset (Org level)  [Clean Room → Data Connections]
1. **+ Create Data Connection** (top right).
2. "Before you begin": **Data Source = Snowflake Data Connection**, **Dataset Type = Generic** → Start.
3. "Configure Datasource":
   - **Credentials** = the Snowflake account credential
   - **Job Name** = `FES_INTEGRATIONS.DISNEY_HABU.DISNEY_SEGMENTS`
   - **Category** = DB
   - **Database Name** = `FES_INTEGRATIONS`  (exactly as in Snowflake)
   - **Schema Name** = `DISNEY_HABU`
   - **Table/View Name** = `DISNEY_SEGMENTS`
   - Next → Save.
4. Wait for status **Pending → Mapping Required** (a few min), then open **Mapping**.
5. **Map Fields (the critical step):**
   - **`ID`**: Data Type = **String**; toggle **User Identifier ON**; identifier = **hashed
     email → SHA256 Hashing Algorithm**. (Our hash is **base64**-encoded SHA256 — if Habu offers
     an encoding choice, pick **base64**.) Save.
   - **`LEAGUE_AFFINITY`**: this is the audience/segment column. ⚠️ **It's an ARRAY** — see
     Decision points below; may need Disney/Habu confirmation or a flattened string version.
6. Wait for status → **Complete**; use **View Details** to sanity-check.
7. (Optional) repeat for `DISNEY_IDENTIFIERS` if Disney wants a separate id-only dataset — confirm.

## Step 2 — Configure the dataset at Clean Room level  [Clean Rooms → Disney x Fanatics → Details]
1. Left menu → **Datasets** → find the new dataset → **Configure**.
2. Filter to audiences if desired (`AUDIENCE In …`), else **Complete Configuration**.
3. Wait Pending → In Progress → **Complete**.

## Step 3 — Assign the dataset to Disney's 4 questions
For each question — **Pre-DXP Activation by ID Type**, **DXP Activation**, **Disney Audience
Index**, **Match Report** — Manage Datasets → **Save & Proceed** → select the dataset →
Save/Save & Proceed. For activation questions (**Map Fields**), pick the column with the
audience segment names = **`LEAGUE_AFFINITY`** → Save.
- If **no dropdown** appears at the assign step → notify Disney; they must assign the dataset to
  the client first.

## Step 4 — Notify Disney
Reply to Jade Lopez that the dataset is created and assigned to the 4 questions; Disney runs the
questions and returns results. Verify **Match Report** shows real overlap.

## ⚠️ Decision points to raise on the call
1. **ARRAY audience column** — `LEAGUE_AFFINITY` is an ARRAY; the guide expects a column of
   audience segment names (string). Most likely blocker at mapping. Ask Jade/Habu whether ARRAY
   is accepted or if we must expose a flattened/delimited string column (would be a small dbt change).
2. **Which dataset(s)** the 4 questions need — segments (id + audience) vs identifiers (id only).
   Segments covers activation + audience index; Match Report needs ids. Confirm with Jade.
3. **Identity encoding** — our id is base64 SHA256; choose base64 if Habu asks.
4. **Old stale connections** — leave them for now (don't delete mid-call); clean up after the
   new dataset works.

## Note on the dbt side
`disney_base` now sources from `gl_fangraph` (PR merged/run). Ensure the **tables**
`DISNEY_IDENTIFIERS`/`DISNEY_SEGMENTS` were actually rebuilt (`dbt run -s disney_base+`), not
just the view — though population is identical today, so not blocking the UI work.
