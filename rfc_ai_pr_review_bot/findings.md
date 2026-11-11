# Findings

Facts gathered for the RFC. Sources cited inline. **Key reframe: this is NOT greenfield —
an LLM PR-review bot (EddyBot) already exists in `fanatics-gaming/envy`.**

## Governing policy

- **DSEA Change Management and PR Review Policy** — Confluence **DATA/2118942973**. The
  `repo-standards-manager` REQUIRED_STANDARDS doc is the technical implementation of it.

## Current-state PR bots (verified 2026-10-21)

All three "bots" live in **`fanatics-gaming/envy`** and deploy to client repos via reusable
workflows. Contact: Slack `#fcore-data-support` / Luke Kranz. (Source: `pr-policy-onboarder`
skill + live `gh` survey.)

### 1. Alfredo — AI PR *description* writer + Jira linker
- **Opt-in** via "Invoke Alfredo" checkbox in PR body; `pull_request_target` trigger.
- Reads diff + PR template, calls Bedrock LLM to fill Summary/Change Type/What Changed/Risk;
  finds or creates a Jira ticket and links it.
- **Not a code reviewer** — writes the description, does not evaluate code quality.
- Config: `.alfredo.yml`; workflow `alfredo.yml` → `envy/.github/workflows/check_pr_description_jira.yml`.

### 2. Ponzu — risk-based *approval gate*
- Always runs on every PR. Checks: one `[R]` change-type label, a Jira key, required checks
  green, ≥1 fresh non-author approval. Path/detector risk policies in `.ponzu.yml` require
  approvals from named teams; `bypass_authors`; P1/P2 incident bypass.
- Posts an audit comment (pass/fail, risk matches, action checklist).
- **Not a code reviewer** — governs *who must approve*, not *whether the code is good*.

### 3. EddyBot — rule-based **LLM PR review system** ⭐ (the big one)
- Reusable workflow `envy/.github/workflows/check_llm_pr.yml` ("PR: EddyBot LLM Rules"),
  orchestrator `actions/eddybot/src/eddybot.py`, runs on AWS **Bedrock** (Claude; dbt_review
  defaults to **Claude Haiku**). IAM role `eddy_bot_ci` (acct 047719637366).
- **Pluggable rule framework** (`src/rules/`, `@register_rule`), mix of LLM + non-LLM rules:
  - `dbt_review` (LLM) — reviews dbt SQL changes
  - `pr_audit_nonempty_check` (LLM) — validates PR template is filled in
  - `pr_label_check`, `dbx_yaml_validation`, `project_config_check` (non-LLM)
- Each rule: `collect_inputs → build_prompt → invoke_bedrock → parse_response`. **Prompts are
  authored in Python inside envy**, not a per-repo `.md`.
- **Posts/updates a PR comment** ("### LLM Feedback", hidden `<!-- EDDYBOT-FEEDBACK:... -->`
  marker, idempotent update-in-place), emits CloudWatch metric `Custom/PRReviews /
  DBT_PR_Reviewed`, logs prompt+reply to CloudWatch `/llm-pr-review/bedrock`.
- Supporting Claude skills live in envy: **`eddybot-rule-manager`** (author/onboard rules),
  **`repo-standards-manager`** (branch protection + required checks + onboarding).
- **Required on all standardized repos:** `PR Audit - Nonempty Check / invoke-model`
  (check_llm_pr.yml) + `enforce-label` are **required status checks** per REQUIRED_STANDARDS.
  `dbt_review` runs where `dbt == true` (e.g. the AE `eddybot-dbt-review` deploy job — see
  THIS repo `docs/runbooks/analytics-engineering/deployment.md`).

### 4. GitHub Copilot PR review
- Some engineers get automated Copilot review comments; **others don't — gated by a per-user
  GitHub setting.** Inconsistent, individual, and reviews against Copilot's generic model,
  **not our standards.** Limitation to call out: review quality depends on *who* opened the PR.

## Repo coverage — Alfredo/Ponzu (live `gh` survey of `.github/workflows`, 2026-10-21)

| Repo | alfredo.yml | ponzu.yml | Notes |
|------|:---:|:---:|------|
| fes-airflow | ✅ | ✅ | |
| data-transformations | ✅ | ✅ | + runbook-sync |
| dbt-fes-ae | ✅ | ✅ | |
| data-lake-services | ✅ | ✅ | |
| data-stream-processing | ✅ | ✅ | |
| data-platform-workloads | ✅ | ✅ | |
| data-platform-infra | ✅ | ✅ | hosts applied-ai OIDC for eddybot |
| data-infrastructure-modules | ✅ | ✅ | |
| data-infrastructure-deploy | ✅ | ✅ | |
| data-airflow-cicd | ✅ | ✅ | |
| **fanapp-terraform** | ❌ | ❌ | **GAP** — uses its own `github_jira.yaml`; no Alfredo/Ponzu |

Also onboarded per the skill's list: dbt-finance, dbt-regulatory, dbt-governance,
analytics-engineering, envy, luke-kranz-sandbox.

## Coverage gap — the real point

- Alfredo (description) + Ponzu (gate) + the EddyBot **pr_audit/label** rules are broadly
  deployed. The **LLM code-review** piece (`dbt_review`) is **dbt-only** and runs mainly where
  `dbt == true`. There is **no general best-practices code review** for Airflow/Python,
  Terraform, streaming, etc.
- `fanapp-terraform` lacks even Alfredo/Ponzu, and no `terraform_review` LLM rule exists.
- **TODO — precise per-repo EddyBot rule matrix** (which repos run which rules). Not yet
  enumerated; caller jobs are often embedded in existing deploy/test workflows, not a
  standalone `eddybot.yml`.

## dbt best-practices Confluence docs (candidates for the rubric)

- **DATA/3101687873** — "DBT Training, Guidelines, and Best Practices" — "Reference these
  guides when building **or reviewing** models." ← most likely canonical.
- **DATA/1986200367** — "dbt Model Best Practices Guide".
- **Analytics/3529375811** — "DBT-Customer Best Practices" (pre-merge testing requirement).
- (Confirm which one BARDS/AE treat as source of truth.)

## The ask, positioned against current state

User's proposed direction = evolve EddyBot's rule model: instead of prompts hardcoded in
envy Python per rule, establish a **standard per-repo `.md`** holding that repo's review
instructions; **BARDS builds the trigger** that calls Claude, pulls that `.md`, and posts
PR comments. The plumbing (Bedrock, comment-posting, metrics, OIDC) **already exists** in
EddyBot — the net-new is: (a) a per-repo `.md` rubric convention, (b) broaden beyond dbt to
all repos/languages, (c) point the review at our best-practices docs.
