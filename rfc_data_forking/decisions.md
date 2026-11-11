# decisions.md

Decisions locked for the RFC, plus assumptions and open questions for reviewers.

## Locked

- **D-1 — This is an RFC, not an implementation.** Deliverable is a Confluence Project
  Proposal/RFC (via `rfc-writer`) that motivates the work and roughly describes the
  mechanism + file layout. No code ships from this project.
- **D-2 — Build on the existing macros, don't reinvent.** `dbfork` (zero-copy clone +
  `dbt run --target test` build path) and `auto_delta` (generic diff → 3 report tables)
  are the primitives. The FEAT is the *automation + composition + custom layer* on top.
- **D-3 — Two-layer delta report.** Every pipeline gets the **generic** `auto_delta` diff;
  each pipeline *may* add **custom** SQL under `custom-delta-report/<pipeline>/`. fangraph
  is the first worked example; loyalty is the "second pipeline" showing genericity.

- **D-7 — Code split: generic → `dbt-shared-utils`, custom → the project repo.** The
  generic layer (the new parent macro + `dbfork` enhancements + `auto-delta` + the
  custom-report *discovery/dispatch framework*) lives in the shared package
  **`fanatics-gaming/dbt-shared-utils`** (`dbt_shared_utils`, README: "shared macros …
  across FBG/FES/FMX projects"; already imported by dbt-fes-ae `packages.yml` @ `v1.0.0`,
  pinned to tag). The **pipeline-specific delta SQL stays in the owning project repo** —
  for V1, Fangraph's custom SQL lives in **dbt-fes-ae**. Onboarding a new pipeline = add
  its custom SQL in that pipeline's repo; no shared-package change.
- **D-8 — FEASIBLE. One parent macro orchestrates everything.** A new parent macro in
  `dbt-shared-utils` (e.g. `fork_and_review(pipeline, models)`) calls, in order:
  `dbfork` (clone) → build new models into the fork (`--target test`) → `auto_delta`
  (generic diff) → the **pipeline-specific** delta. The custom part is reached by
  **dynamic macro dispatch**: the consuming project defines a macro named by convention
  (e.g. `custom_delta__fangraph()`), and the parent resolves it at runtime via dbt's
  `context[...]` lookup. This is idiomatic dbt (package macros can call root-project
  macros; they share one namespace). **Caveat:** single namespace → custom macros must be
  uniquely prefixed (`custom_delta__<pipeline>`) to avoid collisions. Plain `.sql` files
  in a `custom-delta-report/` folder are *not* runtime-readable by a macro — so the custom
  layer is expressed as **project-local macros**, not loose SQL files. (If we want the
  literal `custom-delta-report/<pipeline>/*.sql` folder, those files would instead be run
  by the GitHub Action via `run-operation`, not by the parent macro — decide in Q-2.)
- **D-9 — Orchestration = GitHub Actions running dbt IN THE RUNNER (no dbt Cloud).**
  CORRECTED 2026-11-09 (user): "This will not be run through dbt cloud, just CI and locally."
  Label-gated GHA workflow installs dbt + writes a key-pair profile, runs the same two
  commands a dev runs locally (`dbt build --target test` + `dbt run-operation
  fork_and_review`), then renders + attaches the HTML. Any report is reproducible by hand.
  CI needs a Snowflake **key-pair service user** + `FORK_REVIEW_SCHEMA`. (Supersedes the
  earlier dbt-Cloud-job plan; RFC page v7, Lucid arch v3, workflow/ci_run.py all updated.)
- **D-10 — Delivery = Snowflake output tables + auto-generated self-contained HTML**
  (confirmed, works well). `auto_delta` already writes `_metrics` / `_conflicting_rows` /
  `_conflicting_column_count`; the custom macro writes additional report tables; a renderer
  (pattern: the oncall-writeup `build_*_html.py`) reads those tables → one self-contained
  HTML the Ads team opens directly (no SQL, no Snowflake login). HTML posted as a CI
  artifact + linked in a PR comment. **Decouples delivery from any approval gate.**
- **D-11 — V1 approval = optional AE-run tool, NOT Ponzu-enforced.** See the effort
  analysis in Q-4 below. Enforcement is a fast-follow, and even then Ponzu can only
  *require the stakeholder group as a PR approver* — it cannot verify the data report was
  actually reviewed, and it requires those stakeholders to exist as GitHub reviewers.

- **D-12 — Teardown is MANUAL, never automatic.** The fork + its report tables persist after
  HTML generation and are removed only when a developer explicitly runs `clean_dbfork`.
  Rationale: stakeholders must be able to drill into the forked data / report tables behind
  the HTML *after* review, including after merge. Auto-teardown on merge/close would destroy
  exactly what's being reviewed. (Corrects the earlier draft's "teardown on merge/close.")
- **D-13 — V1 = manual teardown only; fork accumulation is an ACCEPTED tradeoff.** No
  automatic reaper/TTL in V1. Forks pile up until a developer runs `clean_dbfork`; partial
  mitigation is label-gating (forks only on opt-in PRs). A TTL/reaper is an explicit
  fast-follow if accumulation becomes a real cost problem.

## Assumptions (to validate)

- **A-1** — The isolated Snowflake location = the existing dbfork target convention
  (`FES_USERS.[DBT_TEST_SCHEMA]`, `dbfork__...` names). RFC reuses it rather than inventing
  a new isolation scheme.
- **A-2** — Scope detection (PR → affected models) is feasible via dbt `state:modified` /
  Mesh selectors. Confirm before promising "automatic."
- **A-3** — Approval gate can extend the existing **Ponzu** PR gate rather than a brand-new
  system.

- **D-4 — Jira anchor = FEAT-10458, RFC fulfills epic DEMI-676.** The RFC must link from
  the FEAT and cover the three epics: DEMI-646 (isolated-env fork + teardown), DEMI-676
  (this RFC), DEMI-888 (generic+custom delta report, Fangraph first).
- **D-6 — Scope: generic across the 3 Fcore P&Ls (FES, FBG, FMX); V1 = Fangraph on FES
  only.** RFC frames the capability as portable across all three P&Ls' dbt projects, but
  the V1 rollout is a single pipeline (Fangraph, in dbt-fes-ae) with the Ads team as the
  approving stakeholder. Everything else is "designed for, not built in v1."
- **D-5 — The custom layer's first instance is audience-impact, not just a diff.** Per the
  FEAT, the Ads team needs Fangraph diff metrics **plus** metrics on how the change impacts
  their **audiences**, without writing SQL. So `custom-delta-report/fangraph/` =
  audience-impact SQL. This makes the "generic + custom" split concrete in the RFC.

## Open questions for reviewers

- **Q-1 — Jira FEAT:** RESOLVED → FEAT-10458; RFC = DEMI-676. Still confirm acceptance
  criteria beyond "written, reviewed, linked from the feature."
- **Q-2 — Folder location:** `custom-delta-report/` at repo root, or under
  `macros/` / `analysis/`? (dbt only compiles certain paths — if these are run-operation
  SQL they can live anywhere; if they're models they must be under `models/`.)
- **Q-3 — Orchestration home:** dbt `run-operation` wrapper macro, a GitHub Actions
  workflow, or both? Where does the "build the fork" `dbt run --target test` step execute
  in CI (dbt Cloud job vs. Actions runner)?
- **Q-4 — Approval: Ponzu-enforced vs optional AE tool. Effort analysis:**
  - *Optional AE-run tool* — LOW effort. Just the parent macro + the GHA workflow
    (`workflow_dispatch` or label-triggered) + the HTML renderer. AE runs it, hands the
    HTML to Ads, captures approval in Jira/Slack. No gating logic. **= the V1.**
  - *Ponzu-enforced gate* — the "require a group to approve" part is LOW effort (config:
    dbt-governance already has `.ponzu.yml`; add a rule: PRs touching Fangraph model paths
    require the stakeholder group). But the *meaningful* part is HARD/impossible cleanly:
    Ponzu gates on GitHub PR approvals, **not** on "was the HTML report actually reviewed."
    It also needs the Ads stakeholders to be GitHub users in a reviewer group (org/perms
    overhead). So enforcement buys "a required human from group X clicked approve," not a
    verified data review. **Recommendation: optional tool for V1; Ponzu rule as fast-follow
    under DEMI-646.**
- **Q-2 — RESOLVED (hybrid).** Custom SQL lives in a `custom-delta-report/<pipeline>/`
  folder in the owning project repo (honors the folder model), and that folder is
  registered as a dbt **macro path** so each file is a uniquely-named macro
  (`custom_delta__<pipeline>`) the parent macro dispatches to. Keeps the folder *and* the
  single-parent-macro design. (D-8 updated by this.)
- **Q-5 — Cost & cleanup:** zero-copy clones are cheap to create but builds cost compute;
  what's the fork TTL / teardown trigger (`clean_dbfork.sql` on merge/close)?
- **Q-6 — Stakeholder routing:** how do we know *who* the "affected stakeholders" are per
  model? (CODEOWNERS? a per-pipeline owner map? Mesh downstream consumers?)
