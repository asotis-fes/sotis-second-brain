# Plan

## RFC outline (FBG Data Project Proposal/RFC template — via `rfc-writer` skill)

1. **Summary / Problem** — PR review today is manual + uneven across repos; existing bots
   (Alfredo, Ponzu) handle descriptions and approval gating but not standards review.
2. **Current state** — what we have: Alfredo (AI descriptions + Jira), Ponzu (approval
   gate), and **per-user GitHub Copilot reviews** (inconsistent — gated by a user setting,
   not pointed at our standards). What each covers; the explicit limitation (no
   standardized, repo-level best-practices code review).
3. **Coverage gap** — table of repos with/without any review automation.
4. **Proposal** — automated AI PR review bot, **per-repo `.md` + BARDS-owned trigger**:
   - A **standard `.md` path in every repo** holds that repo's code-review instructions.
   - **BARDS builds the trigger** (GitHub Action on `pull_request`) that calls Claude,
     pulls in the repo's review `.md`, and reviews the diff against it.
   - Post **inline + summary review comments** on the PR in GitHub.
5. **Why it's valuable (on-call load)** — shift-left: catch standards violations and
   common bugs before a human/on-call engineer does; cut review latency; standardize quality.
6. **Scope / rollout** — pilot repos first, then expand; opt-in vs. default.
7. **Risks & open questions** — false positives/noise, model cost, comment spam, signed-commit
   repos, keeping the rubric current.
8. **Recommendation** — scoped pilot with success metrics.

## Phase 1 discovery steps

- [ ] Read the `pr-policy-onboarder` skill body → precise Alfredo/Ponzu behavior + limits.
- [ ] Survey repo coverage (which repos have Alfredo/Ponzu workflows + whether Copilot is
      on). Use `gh` across the `fanatics-gaming` org data repos.
- [ ] Locate the **dbt best-practices Confluence doc** (page ID) and the standards skills
      → what the per-repo `.md` references.
- [ ] Define the **standard per-repo `.md` path/filename** convention (align with BARDS).
- [ ] Confirm with **BARDS** the trigger + comment-posting mechanics (GitHub Action + gh
      API; `/review`, `/code-review --comment` as prior art).
- [ ] Gather any on-call / review-latency baseline (even qualitative).

## Draft step

- [ ] Draft the RFC in Confluence via `rfc-writer` once findings are solid.
