# Decisions

Scoping decisions, assumptions, and open questions for reviewers. Log with date + who.

## Decisions

- **2026-10-21 (user):** Architecture = **standard per-repo `.md`** holding the code-review
  instructions (predictable path in every repo) + **BARDS builds the automated trigger**
  that calls Claude, pulls in that `.md`, and posts comments to the PR. → implies
  **per-repo rubrics** (each repo's `.md`), not one shared org rubric. BARDS owns the
  automation; each team owns its repo's review `.md`.
- **2026-10-21 (user):** Present **two options in the RFC**, each with brief pros/cons, and
  let reviewers choose:
  - **Option A — Extend EddyBot:** add the per-repo `.md` rubric convention + broaden rules
    beyond dbt, reusing EddyBot's existing Bedrock/comment/metrics plumbing.
  - **Option B — Deprecate EddyBot + new skill:** stand up a new Claude-based review skill/
    bot driven entirely by the per-repo `.md`, retire EddyBot's rule-in-Python model.
  Do NOT pre-pick a winner in the proposal body (keep it a decision for reviewers/BARDS).
- **2026-10-21 (user):** This RFC is a **requirements doc for BARDS to review** — it states
  *what we need*, not *how BARDS builds it*. **Leave the BARDS trigger/implementation
  deliberately vague.** Do NOT go gather mechanics from BARDS; do NOT document their
  build. Our scope = current state, the gap, the per-repo `.md` convention, and the value.

## Assumptions (to confirm)

- The proposed bot is **net-new** alongside Alfredo/Ponzu (and alongside/replacing the
  inconsistent per-user Copilot reviews), not a replacement for the approval gate.
- The per-repo review `.md` can reference the dbt best-practices Confluence doc and the
  standards skills rather than duplicating them.

## Open questions for reviewers

- **Standard path/filename** for the per-repo review `.md` (e.g. `.github/code-review.md`)?
- Does the per-repo `.md` embed the rubric or link out to the dbt Confluence doc /
  `fbg-tech-guidelines` review contract?
- Relationship to **Copilot**: disable the per-user Copilot reviews once this ships, or
  let them coexist?
- Opt-in per repo or default-on; blocking vs. advisory (comments only, never a required check)?
- Model/runtime + cost ceiling (BARDS to specify).
