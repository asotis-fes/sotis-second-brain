# Local Development — dbt Cloud IDE + future local Fusion

Notes on the developer workflow for `dbt-fes-ae` and (per D42) `dbt-fes-analytics`. Personal scratch for now; grows into team-facing docs once patterns are validated.

---

## Day 1 (cutover): dbt Cloud IDE

**Decision (2026-07-19)**: fes_users analysts use the browser-based dbt Cloud IDE, matching FBG's Analytics Engineering team pattern. Local Fusion is a post-cutover follow-up. Confirmed as D42 posture.

**Why the IDE for day 1:**
- **FBG-wide precedent.** The AE team's `dbt_analytics_engineering` project (in `analytics-engineering` repo) is already on dbt Mesh and uses the dbt Cloud IDE for day-to-day work — see Confluence [How to Use dbt Cloud](https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3099689383) (Brett Pendleton, Jun 2026). fes_users analysts move onto the same rails.
- **De-risks cutover.** Zero new local-tooling work in the 5 days before 2026-07-23. Analysts already have dbt Cloud accounts.
- **Cross-project refs "just work" in the IDE.** dbt Cloud's IDE resolves `{{ ref('fes_data', 'X') }}` via the metadata service transparently, using the environment the IDE is launched against.
- **Matches existing dev workflow shape.** Analysts today write dbt against `FES_USERS.<ANALYST>` schemas from fes-airflow's local dev pattern; the IDE workflow is the same shape (write model → preview → `dbt run --select <model>` → check `FES_USERS.<ANALYST>.<model_dev>` in Snowflake) minus the local tooling.

**Team-facing usage guide to point analysts at:** [How to Use dbt Cloud](https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3099689383). Everything they need for day 1 — IDE navigation, Preview vs Run, git workflow, running jobs manually. We can fork this into a fes_users-specific variant later, or just link to it as-is.

**IDE workflow at a glance:**
1. Open the `dbt-fes-analytics` project in dbt Cloud → land in the IDE against your development environment.
2. Edit `.sql` files in `models/fes_users/<your-folder>/`.
3. Preview (Cmd+Enter) to spot-check query results — reads from live tables, no write.
4. `dbt run --select <model>` in the command bar to materialize into `FES_USERS.<YOUR_SCHEMA>.<model>_dev`.
5. Commit + push via the IDE's built-in git client. PR into `main`. Prod runs pick up on next scheduled fire.

**Cross-project refs in the IDE:** `{{ ref('fes_data', 'tier_points_ledger_v2') }}` works out of the box because the analytics dev env is configured to defer to AE's prod deployment env (see D42 §Phase 2 configuration). The IDE resolves the ref against AE's prod manifest at compile time; the SELECT hits `FANGRAPH.LOYALTY.tier_points_ledger_v2` in prod.

---

## The wider FBG Mesh landscape (as of 2026-07-19)

**Ten projects on dbt Mesh already. We're the 11th.**

Confirmed via repo scan on 2026-07-19: nine FBG sibling projects (`dbt-casino`, `dbt-customer`, `dbt-finance`, `dbt-governance`, `dbt-operations`, `dbt-product`, `dbt-regulatory`, `dbt-trading`, `dbt-vip`) all declare each other in `dependencies.yml` with a uniform pattern. `dbt_analytics_engineering` (in `analytics-engineering` repo) acts as the shared hub — everyone imports it. Live cross-project refs are in production use:

```sql
-- dbt-vip/models/...
select * from {{ ref('dbt_customer', 'daily_segmentation_historical') }}

-- dbt-regulatory/models/...
select * from {{ ref('dbt_finance', 'fct_fmx_transactions') }}
select * from {{ ref('dbt_analytics_engineering', 'regulatory_transactions_mart') }}
```

**Uniform pattern across the 9 siblings:**
- `dependencies.yml` at repo root, listing all sibling projects as upstreams (no versions/pins, just `- name: dbt_<project>`)
- `+access: public` default under `models.<project>:` in `dbt_project.yml`
- Two-argument `ref('dbt_<project>', 'model_name')` for cross-project reads
- `.github/profiles/profiles.yml` committed for local dev
- Snowflake+dbt-core CLI locally, dbt Cloud for scheduled production runs

**Our situation is slightly different from the sibling pattern:**
- Our upstream is `fes_data` (from `dbt-fes-ae`), NOT the FBG-wide `dbt_analytics_engineering` hub. We're a separate two-project Mesh subgraph.
- Whether to also wire `dbt_analytics_engineering` (or any sibling) as an upstream for fes_users is a post-cutover design question — current fes_users models don't ref FBG-hub models, they ref AE-side models. Nothing to add for day 1.

## Post-cutover follow-up: local dbt-core CLI (NOT local Fusion CLI)

The FBG standard for local dev is **dbt-core CLI**, not Fusion CLI. dbt-finance's README is canonical; dbt-fmx's says it directly: *"You work with dbt CLI locally — we only use dbt Cloud for automated production runs."* No FBG team is running Fusion CLI locally today.

**Why dbt-core CLI and not Fusion CLI:**
- Matches all 9 sibling repos — well-paved internal road, existing local-dev docs to copy.
- No first-at-FBG risk during a migration window.
- Fusion CLI's speed win doesn't materially help fes_users analyst workflows (small models, per-analyst schemas).
- Fusion CLI is a plausible future upgrade — if we ever want it, do it once as an org-wide move.

**Adoption pattern (post-cutover, when analysts want local editing):**

1. **Copy dbt-finance's local-dev setup.** Their README is the reference:
   ```bash
   pip install dbt-core==1.8.6 dbt-snowflake==1.8.3 pre-commit
   dbt deps
   dbt parse --no-version-check --profiles-dir .github/profiles
   ```
2. **Commit `.github/profiles/profiles.yml`** at the analytics repo root, mirroring dbt-finance's shape. Per-user overrides via env vars or personal `profiles.yml` (gitignored).
3. **Pre-commit hooks**: pre-commit + dbt-checkpoint + SQLFluff (Snowflake dialect). Matches sibling convention.
4. **Cross-project ref resolution in local parse** — open question with two candidate patterns:
    - **Stubs** (hypothesis, from FBG Data Architecture Confluence 3080028236): analytics-engineering has "CI helpers + mesh stubs" that generate placeholder upstream models so `dbt parse` succeeds without hitting dbt Cloud's live metadata service. Inspect `fanatics-gaming/analytics-engineering/scripts/` to confirm mechanism; port to `dbt-fes-analytics/scripts/` if adopted.
    - **dbt Cloud CLI auth** (`dbt-cloud-cli login` → live metadata service on every parse). Simpler but has downsides listed in the reference section below.
   Neither is proven for our case; investigation blocks adoption but doesn't block cutover.

**Reference reading:**
- [dbt Project dependencies](https://docs.getdbt.com/docs/mesh/govern/project-dependencies)
- [dbt Model access](https://docs.getdbt.com/docs/mesh/govern/model-access)
- FBG Data Architecture — [Confluence 3080028236](https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3080028236)
- How to Use dbt Cloud (IDE) — [Confluence 3099689383](https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3099689383) — the alternative workflow for analysts who prefer browser-only

---

## Reference: what live metadata resolution would look like (skipped for cutover)

Kept here so we don't re-derive it later. This is the "authenticated Fusion → dbt Cloud API on every compile" pattern; **not** what we're using.

**Mechanism.** `dbt-cloud-cli login` authenticates Fusion. Every `dbt parse`/`compile`/`build` in the downstream repo hits dbt Cloud's "metadata service" to resolve `{{ ref('fes_data', 'X') }}` against the upstream env's manifest. Environment-scoped: `--target dev` reads upstream dev manifest; `--target prod` reads upstream prod.

**Where staleness comes from — the only real lever:** upstream's most recent successful job run in the matching env. If AE added a model or an `access:` field but hasn't rerun, downstream can't see it.

**Two config levers (both single UI settings on the downstream dev env):**

| Lever 1 — READ source (upstream env to defer to) | Refs resolve to |
|---|---|
| AE prod deployment env (recommended if we adopt live resolution) | `FANGRAPH.LOYALTY.tier_points_ledger_v2` etc. |
| AE dev deployment env | `FANGRAPH_DEV.LOYALTY.tier_points_ledger_v2_dev` etc. |

Lever 2 — WRITE target: analytics dev credential writes to `FES_USERS.<ANALYST>.<model>_dev` (per-model `alias` env-switch, unchanged from today).

**Downsides that pushed us to stubs instead:**
1. Network dependency at compile time — Cloud API blip → local `dbt parse` hangs or fails.
2. Requires an upstream successful run since the change — no green run = downstream compile fails.
3. No snapshot pinning — upstream breaking changes propagate to downstream compiles instantly.
4. Env matching enforced — analytics dev can only defer to one upstream env at a time.
5. No offline dev.
6. Requires dbt Cloud seat with upstream project read access.

**Non-automatic alternatives we're also NOT using:**
- **`dbt-loom`** — OSS package for manifest fetching from S3/GCS/GHA artifacts. Skipped: we're going the AE stub route instead.
- **`--defer --state <path>`** — native dbt flag against a hand-downloaded manifest. Escape hatch for offline work; not a default.

---

## Notes for the analytics-project setup (per D42)

- All AE models are `access: public` from day one (D42 posture — set via folder-level `+access: public` in `dbt-fes-ae/dbt_project.yml`). Analytics can ref any AE model.
- Analytics's dev deployment env in dbt Cloud is provisioned per D42 §Phase 2. IDE developers land in that env by default when they open the analytics project.
