# Progress

## 2026-10-21 — Phase 0 setup

- Created `projects/rfc_ai_pr_review_bot/` with flat stubs (`_index.md`, `findings.md`,
  `plan.md`, `decisions.md`, `progress.md`).
- Captured framing: RFC for an automated AI PR review bot — survey existing bots
  (Alfredo/Ponzu) + limits, repo coverage gap, proposal (trigger on PR, review against a
  best-practices `.md`, post GitHub comments), on-call value framing.
- No external doc/code links provided → stayed in Phase 0. Seeded `findings.md` from the
  `pr-policy-onboarder` skill description (Alfredo/Ponzu) — **marked for verification.**

## 2026-10-21 — framing refined (user)

- Added **GitHub Copilot** to current-state bots: per-user, inconsistent (gated by a user
  setting), not pointed at our standards → a limitation to highlight.
- Noted this repo's **built-in review commands** (`/code-review --comment`, `/review`,
  `/security-review`) as working prior art for "Claude → inline PR comments."
- Recorded a **dbt best-practices Confluence doc** exists (page ID TBD).
- **Design decision locked:** standard per-repo `.md` holding review instructions +
  **BARDS builds the automated trigger** that calls Claude, pulls the `.md`, posts
  comments → per-repo rubrics, BARDS owns automation. (decisions.md)

## 2026-10-21 — Phase 1 discovery done (big reframe)

- **This is NOT greenfield.** Discovered **EddyBot** — a rule-based LLM PR-review system
  already in `fanatics-gaming/envy` (`check_llm_pr.yml`, Bedrock/Claude Haiku, pluggable
  rules incl. `dbt_review` + `pr_audit_nonempty_check`, posts/updates PR comments,
  CloudWatch metrics, OIDC role `eddy_bot_ci`). Supporting envy skills:
  `eddybot-rule-manager`, `repo-standards-manager`. Governing policy = Confluence
  **DATA/2118942973** (DSEA Change Management & PR Review Policy).
- Surveyed Alfredo/Ponzu coverage across 11 data repos via `gh`: all have both **except
  fanapp-terraform** (uses `github_jira.yaml`). Full table + rule details in findings.md.
- The **LLM code-review** rule is **dbt-only** today; no general best-practices review for
  Airflow/Python, Terraform, streaming. That's the real gap.
- dbt best-practices Confluence candidates identified (DATA/3101687873 most likely canonical).

### Reframed proposal (per user)
EddyBot plumbing already exists → RFC's net-new ask = (a) **standard per-repo `.md` rubric**
convention, (b) broaden review beyond dbt to all repos/languages, (c) point at our
best-practices docs. **BARDS builds the trigger (left vague — requirements doc, not a design).**

### Open / next
- [ ] Decide framing: "new bot" vs. **"evolve/extend EddyBot"** (recommend the latter — need user call).
- [ ] (Optional) precise per-repo EddyBot rule matrix.
- [ ] Confirm canonical dbt best-practices doc with AE/BARDS.
- [x] Draft the RFC via `rfc-writer` skill — `rfc_draft.md` written (8 sections, two
      options A/B with pros/cons per user). Awaiting user review before creating Confluence page.

- [x] **PUBLISHED** to Confluence DATA space (user said "go for it"):
      https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3654353123
      Owner = Alex Sotis. Created at space top-level (no parent) — may need moving under an
      RFC folder.

- [x] **Revised page (v2)** per user: centered title + subtitle (`<h1 style="text-align:center">`,
      confirmed retained in storage format), removed all em-dashes and filler/AI-slop phrasing,
      converted Problem (bot survey), Expected Impact, Scope, and Risks to tables. Published
      via storage format. Local `rfc_draft.md` is now the pre-edit version (published page is
      source of truth).

- [x] **v3 (shortened)** per user: removed Alfredo/Ponzu entirely (not code-review tools);
      added human review as the baseline (costly labor + rubber-stamp risk); cut ~2/3 of
      length; current-state = 3-row table (human/EddyBot/Copilot); Options A/B collapsed to
      one 3-col table; dropped Next Steps + long Risks; reframed as a "request for change".

### Still open (follow-ups, non-blocking)
- [ ] Move page under the right RFC parent folder if one exists.
- [ ] Confirm canonical dbt best-practices doc (used DATA/3101687873) + `.md` path convention
      (used `.github/code-review.md` as the example) — both still framed as open questions in RFC.
- [ ] Circulate to BARDS + stakeholders for the A-vs-B decision.
