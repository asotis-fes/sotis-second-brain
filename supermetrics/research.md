# Research — Supermetrics Capabilities

> Vendor-capability research (read on demand). Part 1 = licensing/roles/workspaces; Part 2 =
> pipeline health + API connector cloning.

## Part 1 — Licensing / Roles / Workspaces

Question (Alex, 2026-10-02): can we provision **differentiated profiles** —
(a) a **DE** profile that can change warehouse connections + see pipeline health but **not add
pipelines**; (b) a **Builder/marketer** profile that adds pipelines; (c) an **Admin** profile
that sets up teams dictating which Snowflake DB/schema an opco's users can land data into
(so a marketer has **no choice** but to ingest into their opco's designated warehouse/schema)?

**Researched 2026-10-02 from Supermetrics docs. Bottom line: partially — with two gaps to
confirm with the rep.**

## Native team roles (5)
| Role | Create/modify transfers (pipelines)? | Manage destination connections? | View transfers/health? | Team/billing |
|---|---|---|---|---|
| **Owner** | ✅ | ✅ (others' too) | ✅ | full |
| **Admin** | ✅ | ✅ (others' too) | ✅ | manage team/subs (not Owner) |
| **Editor** | ✅ | own only | ✅ | ❌ |
| **Viewer** | ❌ | own only | ✅ (view only) | ❌ |
| **Finance** | ❌ | ❌ | ❌ | billing only (no extra seat) |

Roles govern what you can do **on the Hub**; they **don't by themselves grant the right to use
a subscription at a destination** (that's the subscription layer) — and role does **not**
restrict which destination you use.

## Mapping to the 3 desired personas
- **Builder / marketer (add pipelines)** → ✅ **Editor** fits cleanly (create/modify transfers
  + transformations; manages own connections; no team/billing).
- **Admin (set up teams/structure)** → ✅ **Owner/Admin** fits (user + team management).
- **DE (manage warehouse connections + see health, but NOT add pipelines)** → ❌ **NOT
  achievable with native roles.** Editor is the lowest role that can manage destination
  connections, and Editor can **also create transfers** — it's all-or-nothing. Viewer can see
  transfer status but can only manage **its own** connections and cannot modify destinations.
  **There is no role that separates "manage destinations + view health" from "create
  transfers."** → **Raise with the rep** (custom role? feature request? or accept Editor for
  DEs).

## Destination confinement (the "marketer has no choice" requirement)
- Mechanism = **Workspaces**: hierarchical, **"data and assets are not shared across
  workspaces,"** per-workspace RBAC + subscription allocation. A workspace-per-opco is the
  natural container.
- **BUT:** the docs **do not explicitly confirm** a workspace can **hard-restrict** its members
  to a specific warehouse **destination/schema**. Role does not restrict destination; workspace
  isolation is about assets not being shared, not proven to be a destination allow-list.
- Related lever: **shared vs private connections** (a shared connection per workspace) can
  standardize which source logins/destinations members use.
- → **This is the key governance question to confirm with the rep:** "Can a Workspace force
  all of its members' transfers to a single designated Snowflake database/schema, with no
  option to pick another destination?" If yes, workspace-per-opco enforces D-7 isolation
  technically. If no, isolation is **convention + monitoring**, not hard-enforced.

## CONFIRMATION (2nd pass, 2026-10-02) — answering Alex's "downgrade the marketer" idea
Alex asked: could the **DE** be the higher profile (add pipelines + manage warehouse
connections) and the **marketer downgraded** to only modify transfers + add source connectors
(no destination-connection management)? **Confirmed NOT possible with documented features:**
- There is **no custom-role capability** and no toggle that splits **source-connector** access
  from **destination-connection** access. Editor governs *all* platform-asset work as one
  bundle ("work on all platform assets… set up data transformations and transfers and modify
  them").
- Supermetrics' own storage/destination setup guide: you must be **"editor, admin, or owner"**
  to activate a warehouse destination — i.e. **anyone who can create transfers can also
  create/manage destinations.** Destination management is **not separable** from transfer
  creation.
- → **Marketer and DE must share the same license type (Editor).** Record as such; raise the
  split with the rep only as a feature request (docs say no today).

## CONFIRMATION — destination confinement is a SNOWFLAKE control, not a Supermetrics one
- **NOT enforceable in Supermetrics.** Workspaces give **asset isolation** ("connections,
  transformations, and any content created in one workspace are not accessible to users in
  other workspaces") but do **not** lock members to a single destination — an Editor in a
  workspace could still create another destination. Supermetrics explicitly says: **"to
  restrict access to a data destination, you can do it in the data destination itself."**
- → **Enforcement path = Snowflake grants** (ties to D-5 / Antoine's service-role model): each
  opco's Supermetrics **service user/role can only write to that opco's DB/schema**, so even if
  a marketer misconfigures a transfer, Snowflake rejects writes outside their opco's schema.
  This is how we technically deliver the D-7 isolation goal — document it in the governance
  section. **Still worth confirming with the rep** whether there's any Supermetrics-side guard,
  but we are **not blocked**: Snowflake-side enforcement works.

_Sources added:_ `.../docs/workspaces`, storage-destination get-started + connect guides,
`.../docs/how-to-create-a-transfer` (see Sources list below).

## Implication for our governance section
- Achievable today: Builder=Editor, Admin=Owner/Admin, workspace-per-opco for separation.
- **Two confirmations needed from Supermetrics rep/technical counterpart:**
  1. A **DE role** that manages connections + views health but can't create transfers (likely
     not native).
  2. **Hard destination confinement** per workspace (so an opco's users can only land in their
     opco's Snowflake DB/schema).

## Sources
- https://docs.supermetrics.com/docs/about-supermetrics-teams-and-user-roles
- https://docs.supermetrics.com/docs/how-to-use-the-workspace-management-feature
- https://supermetrics.com/blog/introducing-supermetrics-workspaces
- https://docs.supermetrics.com/docs/about-shared-and-private-connections
- https://docs.supermetrics.com/docs/about-supermetrics-team-and-subscription


---

## Part 2 — Pipeline Health + API (connector cloning)

Researched 2026-10-02 from Supermetrics docs/apidocs + the public Python SDK. Confirmed facts
only; unconfirmed items flagged. Feeds monitoring signal #3 (`rollout_policies.md`) and the
AE-owned schema-drift question.

## A. Pipeline-health observability
- **Snowflake metadata/log table: NOT CONFIRMED.** No official doc shows Supermetrics writing
  a run-status/log/metadata table into the Snowflake destination. **Transfer-run history lives
  in the Supermetrics Hub**, not in a destination table. → Do **not** assume a Snowflake-side
  health table exists; plan to pull health from the **API**.
- **Per-run fields (confirmed, exposed on the Hub):** transfer-run created date, **duration**,
  **rows** fetched, **date of data** (which days), **run type** (Recurring / Backfill), and
  **status** ∈ {Scheduled, Running, Paused, Success, Error, Cancelled}; failed runs carry a
  **Message** (error detail).
- **API (confirmed):** dedicated **Data Transfers / Transfer Runs** API at
  `dts-api.supermetrics.com/v1`; API-key scopes `dwh_transfers_read` / `dwh_transfers_write`.
  SDK methods: `transfers.list_runs(...)` (runs for a transfer) and
  `transfer_runs.get(team_id, transfer_run_id)` (single run) — return status, rows, timestamps,
  error/message. **Exact REST paths/response schemas NOT CONFIRMED** (SDK confirms methods +
  host; raw apidocs endpoint spec not retrieved).
- **Implication for monitoring signal #3:** pull pipeline health from the **Supermetrics
  Transfer Runs API** (status/rows/timestamps/error message), not from a Snowflake table.
  Document these endpoints in the Confluence "how we monitor" section; don't write the script.

## B. Programmatically cloning a connector across opcos  *(answers Alex's schema-drift Q)*
Alex's question: can we add a connector for opco B that mirrors opco A's existing one (same
schema), where the marketer just picks which **accounts** are included?
- **Yes, effectively — same schema, differ only by accounts.** `transfers.create(...)` takes
  `data_source`, `destination_id`, **`schema_id`** (the table group / schema), name, `schedule`,
  and an **`accounts` array** of `{login_id, account_id}`. Create a new transfer with the
  **same `data_source` + `schema_id`** (→ identical schema) and a **different `accounts`
  list** → opco B gets opco A's exact structure, pulling B's accounts.
- **Account selection (confirmed):** accounts set via `ds_accounts` (comma-list/array of IDs,
  `list.all_accounts`, or regex `filter_id`/`filter_name`); a "Get accounts" endpoint lists
  available accounts; `POST /teams/{team_id}/data-source-connections` (`data_source_id`,
  `destination_type` e.g. `DWH_SNOWFLAKE`) creates the connection first.
- **No first-class clone/template: NOT CONFIRMED to exist.** No "duplicate transfer" API. The
  practical pattern = **`transfers.get` an existing transfer → re-`create` with a modified
  `accounts` array** (`update()` is whole-object replacement, no PATCH).
- **Takeaway for AE (schema-drift owner):** reusing a shared `schema_id` across opco transfers
  is the lever that keeps schemas identical, so the shared dbt repo's staging stays uniform.
  A thin internal helper (get→modify-accounts→create) gives us "clone a connector for a new
  opco, marketer just selects accounts" even without a native clone. **Confirm `schema_id`
  reuse semantics with the rep** (does reusing it guarantee identical columns across transfers?).

## Sources
- https://docs.supermetrics.com/docs/how-to-monitor-your-data-warehouse-transfers-on-the-supermetrics-hub
- https://docs.supermetrics.com/docs/how-to-create-a-transfer
- https://docs.supermetrics.com/apidocs
- https://docs.supermetrics.com/apidocs/accounts
- https://docs.supermetrics.com/apidocs/create-data-source-connection
- https://github.com/supermetrics-public/supermetrics-python-sdk/pull/61
