# Decisions & open questions

Log scoping decisions (with date + who) and assumptions. Unverified claims live here
until confirmed into `findings.md`.

## Decisions

- **D-0 (2026-10-21):** Deliverable is an RFC / Project Proposal in Confluence, authored
  via the `rfc-writer` skill against the current FBG template. The RFC proposes an
  *evaluation*, not adoption.
- **D-3 (2026-10-21, user):** Intent = **write the NEED in the RFC and hand the work off
  to a different team to execute.** Alex is the *proposer/author*, not the team that runs
  the eval. Keep the doc as a motivation/handoff artifact — do NOT turn it into an
  execution plan Alex owns. (User asked NOT to change the doc text for this — framing note
  only. If Owner/Next-Steps are revisited later, reflect proposer-vs-executor split.)
- **D-2 (2026-10-21, user):** The RFC is the **motivation to do the evaluation work**,
  NOT a detailed metrics doc. **Do not** gather a Snowflake cost baseline for it; cite
  the cost angle qualitatively (3XL fanflow, XL integrations) and leave measurement as
  part of the proposed eval. Draft the **full RFC** via `rfc-writer` now.
- **D-1 (2026-10-21):** RFC's central thesis must honestly present the **tension**: the
  product targets ~50% Snowflake-compute savings and we're offered private-beta access,
  BUT its single-node DuckDB design, DuckDB dialect, no-merge, and Glue-catalog gap mean
  the **big-cost models are the worst fit**. So the proposal is a **narrow, measured
  beta eval** on small/mid append-style Iceberg models with explicit go/no-go gates —
  not a Snowflake-displacement bet.

## Assumptions (status after 2026-10-21 research)

- A-1 ✅ partly: We DO run Iceberg on S3 today — but only **11 Commerce tables, on AWS
  Glue, via Airflow (not dbt)**. Glue is **not** a listed beta catalog. Confirmed.
- A-2 ⏳: Snowflake compute as a reducible transform cost — **not yet quantified**; need
  the cost baseline query. (Heaviest = fanflow silver 3XL, Salesforce/Meta/XP XL.)
- A-3 ⚠️: Lake Compute writes Iceberg; our Snowflake can read Iceberg back, BUT RBAC/
  secure-view consumers and shares need the warehouse — open risk for PII/shared models.

## Material risks surfaced by research (feed into RFC "Risks")

- **R-1 Catalog mismatch:** our Iceberg is on **Glue**; beta needs **Fivetran MDLS/
  Polaris** or **Snowflake Horizon**. Evaluating = either adopt Fivetran MDLS (new
  dependency) or route through our own Snowflake Horizon catalog. Must pick a path.
- **R-2 Single-node DuckDB ceiling:** our biggest-cost models (fanflow silver 3XL,
  fangraph identity joins) are exactly the large / two-sided-join workloads dbt lists as
  **non-goals**. Cost-saving sweet spot ⟂ technical fit. Central tension of the RFC.
- **R-3 No merge/upsert:** incremental limited to append/insert_overwrite — many of our
  incrementals are merge-keyed. Limits the candidate set.
- **R-4 Preview risk:** private beta, no SLA, breaking changes, Fivetran-coupled,
  AWS-only. Evaluation only, behind an experimental dbt-v2 flag.
- **R-5 Unconfirmed economics:** the ~50%-of-Snowflake figure is vendor-verbal only; no
  public pricing. Our own benchmark is the only trustworthy number.

## Open questions for reviewers

- What's the acceptable cost/runtime delta to call Lake Compute a "win"?
- Is strategic optionality (less Snowflake lock-in) a goal on its own, or cost-only?
- Who owns the benchmark, and against which candidate models?

## Reference conventions (team memory)

- Team operates **FES + FBG Snowflake accounts only**; others are external share
  providers. (memory: reference_snowflake_accounts_fes_fbg_only)
- FBG medallion schemas = SOURCE/PROCESSED/CONSUMPTION/REPORTING.
- RFCs: cite other teams' patterns in References only; reason from FES's own context.
  (memory: feedback_rfc_other_teams_as_reference_only)
