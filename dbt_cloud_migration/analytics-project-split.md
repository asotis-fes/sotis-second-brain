# Analytics Project Split — dbt Mesh Setup (pre-cutover)

Detailed substeps for the pre-cutover step: **carve `models/fes_users/` out of `dbt-fes-ae` into a NEW dbt Cloud project pointing at the existing (currently empty) `fanatics-gaming/dbt-fes-analytics` repo, wired via one-way dbt Mesh.**

Referenced from [`remaining-steps.md`](remaining-steps.md) → Before cutover → "Analytics project split." Decision anchor: [`decisions.md`](decisions.md) → D42.

**Target completion**: before main cutover (~2026-07-23). Timeline risk is real (5 days) — see §Timeline & fallback.

---

## Overview

**What.** Two dbt Cloud projects instead of one after cutover:

| Project | dbt project `name:` | Repo | Owner | Models |
|---|---|---|---|---|
| Analytics Engineering (existing) | `fes_data` (per D32, locked) | `fanatics-gaming/dbt-fes-ae` | AE team | Everything **plus 12 fes_users residuals** (see §1 must-stay closure) |
| Analytics (new) | `fes_analytics` (proposed) | `fanatics-gaming/dbt-fes-analytics` | FES Commercial Analytics team | 116 fes_users models (split from 128 = 12 stay + 116 move) |

**Why now.** User directive 2026-07-18: repo ownership boundary belongs at the repo layer, not just at a subdirectory in dbt-fes-ae. Deferring to post-cutover would make the split a second migration risk on top of a stabilizing prod project — the split is a `git mv` today, an incident tomorrow.

**Why one-way Mesh is enough** (via leave-in-place variant, 2026-07-19):
- `fes_users/` → other AE dirs: HIGH (every sampled `fes_users` SQL refs `loyalty_balance`, `tier_points_ledger_v2`, `weekly_trading`, `f1_attributes`, etc.)
- Other AE dirs → `fes_users/`: 10 hits across 6 models found by §1. Those 6 (plus 6 transitive upstreams = **12 total**) stay in `dbt-fes-ae/models/fes_users/` unchanged. Only the other 116 fes_users models move to `dbt-fes-analytics`. Post-cutover cleanup relocates the 12 into AE-native domains (§1a — deferred).

Downstream (`dbt-fes-analytics`) declares upstream (`dbt-fes-ae`) via `dependencies.yml`. Upstream declares nothing about downstream. Only upstream models need `access: public` — downstream models can stay `protected` (default).

**What stays the same.**
- Same `SVC_DBT_CLOUD_ROLE` Snowflake service role (user directive — no separate role for now).
- Same account (`70437463654557`).
- Same `FES_USERS` database + per-analyst schemas.
- Same warehouse routing (`FDE_MWAA_*_WH` prod / `FDE_DEVELOPER_*_WH` dev in each model's per-model config).
- Ownership transfer script scope (`cutover_ownership_transfer.sql`) — **unchanged**. `FES_USERS` DB already in the target list; both projects will land there under the same role.

---

## Key facts from research (2026-07-18)

Provenance for the plan below — if any of these are wrong, revisit the affected substeps.

**Repo state (via `gh api`):**
- `dbt-fes-analytics` — exists. Default branch `main` (protected: requires `DSEA PR Policy` check). Top-level contents: `.alfredo.yml`, `.ponzu.yml`, `.github/`, `README.md` (72 bytes). **No dbt code.** Three feature branches present (Alfredo/Ponzu smoke).
- `dbt-fes-ae` — dbt project at repo root (no `dbt/` subdir). `dbt_project.yml`: `name: fes_data`, `profile: fes_data`, Fusion Stable, dbt-core 1.8 shims. `packages.yml`: `dbt-labs/dbt_utils 1.3.0`. **No `dependencies.yml`** — Mesh not yet configured.
- `models/fes_users/` in `dbt-fes-ae`: 149 paths, 128 `.sql`, 10 schema YAMLs. Per-analyst folders: `caroline_wylie/`, `dylan_tuch/`, `hajime_alabanza/`, `kelsey_carrier/`, `kevin_bokor/`, `mitchell_mann/`, `natalie_cutter/`, `rmcspedon/`, `rohan_gulati/`, `stacy_lin/`. Plus top-level `fes_users.yaml` covering `rmcspedon_amplitude_metrics`, `loyalty_account_tenant_map_time_travel`, `loyalty_fifo_violation`.
- Config pattern: every model has explicit per-model `config:` with `alias` env-switch, `tags: ['users']`, `database: FES_USERS`, `schema: <ANALYST>` (uppercase). **No `access:` declared anywhere.**

**dbt Mesh mechanics (docs.getdbt.com):**
- `dependencies.yml` at downstream repo root. Syntax: `projects: - name: <upstream project name>`. Case-sensitive match against upstream's `dbt_project.yml name:`.
- `access:` levels: `private` / `protected` (default) / `public`. Only `public` is cross-project-refable. Declared per-model in schema YAML OR at directory level in `dbt_project.yml` via `+access:`.
- Cross-ref syntax: `{{ ref('fes_data', 'model_name') }}` — two-argument form. First arg = upstream project name; second arg = model.
- **Requires**: dbt Enterprise plan tier. Upstream must have a **successful prod job run** after adding `access:` (populates `manifest.json` used for cross-project resolution).
- Cloud project setup: one dbt Cloud project per repo (own git connection, env, credential, job set).

---

## Substeps

Ownership legend: 🤖 = current Claude session, 👤 = Alex, 🧑‍💻 = other engineer, ⚙️ = automation/CI.

### Phase 1 — Verify + local scaffolding

**1. Definitive grep: does any AE model outside `fes_users/` reference a `fes_users/` model?** 🤖 ✅ DONE 2026-07-19
```bash
# Executed against origin/main of dbt-fes-ae (commit 04a14df):
git grep -nE "ref\(\s*['\"]" origin/main -- 'models/*.sql' ':(exclude)models/fes_users/'
# Then cross-referenced against the 128 fes_users model names.
```
**Result: 10 hits across 6 fes_users models.**

| fes_users model | Owner folder | Consumed by (AE side) |
|---|---|---|
| `hashed_email_eco_profit` | rohan_gulati | `fanapp/installs/processed/install_enrichment` |
| `fanapp_cohort_labels` | rohan_gulati | `fangraph/ltv_processed/elc_fanapp_cohort_labels`, `elc_fanapp_session_analytics` |
| `fancash_site_tenant_mapping` | caroline_wylie | `fangraph/ltv_processed/elc_fanapp_loyalty_{burn,earn}{,_opco}` (4 callers) |
| `amplitude_session_performance` | dylan_tuch | `fangraph/ltv_processed/elc_fanapp_session_analytics` |
| `fanapp_install_attributes` | rohan_gulati | `fangraph/ltv_processed/elc_ltv_user_timeline` |
| `fangraph_ecosystem_daily_activity_v2` | rmcspedon | `fde_imprint/imprint_fg_us_customers` |

All 6 are functionally AE-owned infrastructure (ecosystem/gross-profit joins, cohort labels, dim tables, session aggregates) that drifted into analyst folders — they're consumed by AE prod paths (`elc_*`, `install_enrichment`, `imprint_*`).

**Transitive closure (2026-07-19).** The 6 seed models transitively pull in 6 more via intra-fes_users refs, for a **must-stay-in-AE set of 12** models:

| Model | Analyst folder | Pulled in by |
|---|---|---|
| `hashed_email_eco_profit` | rohan_gulati | (seed — ref'd by `install_enrichment`) |
| `fanapp_cohort_labels` | rohan_gulati | (seed — ref'd by 2× `elc_*`) |
| `fancash_site_tenant_mapping` | caroline_wylie | (seed — ref'd by 4× `elc_*`) |
| `amplitude_session_performance` | dylan_tuch | (seed — ref'd by `elc_fanapp_session_analytics`) |
| `fanapp_install_attributes` | rohan_gulati | (seed — ref'd by `elc_ltv_user_timeline`) |
| `fangraph_ecosystem_daily_activity_v2` | rmcspedon | (seed — ref'd by `imprint_fg_us_customers`) |
| `hashed_email_ftu` | rohan_gulati | fanapp_cohort_labels |
| `fanapp_install_identity_map` | rohan_gulati | fanapp_install_attributes |
| `fanapp_potential_fraud` | rohan_gulati | amplitude_session_performance, fanapp_install_identity_map |
| `fraudulent_ips` | dylan_tuch | amplitude_session_performance |
| `dim_appsflyer_campaign_mapping` | mitchell_mann | fanapp_install_identity_map |
| `dim_appsflyer_creative_mapping` | mitchell_mann | dim_appsflyer_campaign_mapping |

**Split summary (2026-07-19):**
- **12 models stay in dbt-fes-ae** (in `models/fes_users/` untouched — same schemas, same config) — spanning 5 analyst folders (caroline_wylie, dylan_tuch, mitchell_mann, rmcspedon, rohan_gulati)
- **116 models move to dbt-fes-analytics** — including all 5 clean analyst folders (hajime_alabanza, kelsey_carrier, kevin_bokor, natalie_cutter, stacy_lin) plus the non-must-stay files from the 5 split folders
- **78 analytics-side refs** need rewriting from `ref('X')` to `ref('fes_data', 'X')` across 37 files (see §7)
- **AE keeps a `dbt_users` job** (renamed to avoid collision — see §16) that builds the 12 residuals under `tag:users`
- **Post-cutover cleanup**: hoist the 12 to AE-native domains (this is what §1a used to describe — deferred). Tracked in `remaining-steps.md` under Post-cutover items.

**Why leave-in-place beats hoist-first** (decided 2026-07-19 after weighing both):
- Zero data-shape changes in the cutover window. The 12 keep writing to `FES_USERS.<ANALYST>` schemas — no re-materialization, no downstream-consumer risk from schema moves.
- No AE-owner coordination needed on target directories during a 4-day window.
- Rollback is trivial: revert the analytics-side PR; AE is untouched.
- Cost accepted: AE keeps a small `dbt_users` job (12 models); `models/fes_users/` residue remains in AE across 5 subfolders until post-cutover cleanup.

**Transitive-check assurance**: no model in the "moving 116" is ref'd by any model in the "staying 12" (guaranteed by closure construction). One-way Mesh (analytics → AE only) is preserved.

**1a. Post-cutover cleanup: hoist the 12 AE residuals to AE-native domains** 🧑‍💻 **DEFERRED to post-cutover**

Not blocking cutover. Tracked in `remaining-steps.md` under Post-cutover items. Recommended target directories (revisit with AE owner post-cutover):

| Model | Suggested target | Consumer domain |
|---|---|---|
| `hashed_email_eco_profit` | `models/fanapp/installs/` | fanapp/installs |
| `fanapp_cohort_labels` | `models/fangraph/ltv_processed/` | fangraph/ltv_processed |
| `fancash_site_tenant_mapping` | `models/fangraph/ltv_processed/` | fangraph/ltv_processed |
| `amplitude_session_performance` | `models/fangraph/ltv_processed/` | fangraph/ltv_processed |
| `fanapp_install_attributes` | `models/fanapp/installs/` | fanapp/installs |
| `fangraph_ecosystem_daily_activity_v2` | `models/fangraph/aggregates/` or `models/fde_imprint/` | fde_imprint |
| `hashed_email_ftu` | `models/fanapp/installs/` (transitive of `fanapp_cohort_labels`) | (upstream of cohort labels) |
| `fanapp_install_identity_map` | `models/fanapp/installs/` | (upstream of install_attributes) |
| `fanapp_potential_fraud` | `models/fanapp/installs/` | (upstream of session_perf + identity_map) |
| `fraudulent_ips` | `models/fanapp/installs/` | (upstream of session_perf) |
| `dim_appsflyer_campaign_mapping` | `models/dimensions/` or `models/fanapp/installs/` | (dim table) |
| `dim_appsflyer_creative_mapping` | `models/dimensions/` or `models/fanapp/installs/` | (dim table) |

Cleanup PR pattern: `git mv` + update `config.database`/`schema` to domain-native target + verify downstream refs still resolve. AE-only, no cross-project impact (all refs stay within `dbt_project name: fes_data`).

**2. Confirm dbt Cloud plan tier is Enterprise** 👤
Cross-project `ref()` is Enterprise-gated. Verify in dbt Cloud account settings before touching anything else.

**3. (informational) List upstream AE models that fes_users currently refs** 🤖 ✅ DONE 2026-07-19
Not gating a PR — informational for the migration. Read every fes_users `.sql` file, extract `ref('X')` where X is NOT another fes_users model, deduplicate. Full result in [`analytics-project-split-access-public-models.md`](analytics-project-split-access-public-models.md) — 277-line ref surface catalog with 5 buckets (intra-analytics 22/69, mover→residual 11/78, mover→AE-proper 58/329, mover→source 50/119, unrecognized 3/6). Total cross-project refs to rewrite in §7 = 407 across 116 movers.

**4. AE PR: expose ALL AE models as `access: public` via folder-level default** 🧑‍💻
Per D42 posture (2026-07-19): start with everything public rather than enumerating. Add to `dbt-fes-ae/dbt_project.yml` under the top-level `models.fes_data:` block:

```yaml
models:
  fes_data:
    +access: public
    +group: analytics_engineering
    # ... existing config unchanged
```

Also add a `groups.yml` at repo root (or under `models/`) declaring the group + owner:

```yaml
version: 2
groups:
  - name: analytics_engineering
    owner:
      email: fes-analytics-engineering@betfanatics.com
```

Trade-off accepted: any future downstream project can ref any AE model — the ownership boundary lives at the repo/group layer, not at per-model access. If an AE model later needs to be private (e.g., contains PII the analytics side shouldn't consume), the folder-level default can be overridden per-model with `config.access: protected`.

Target branch: `dbt-fes-ae` main. PR title: `Expose all AE models as access: public + group: analytics_engineering for dbt Mesh`.

**5. Create dbt project skeleton in `dbt-fes-analytics`** 🤖
On a new branch off `main`:
- `dbt_project.yml` — copy from dbt-fes-ae, then change:
  - `name: fes_analytics` (must differ from `fes_data` for Mesh to distinguish projects)
  - `profile: fes_analytics` (or reuse `fes_data` — either works if the profile is only referenced inside this repo)
  - Keep Fusion Stable + 1.8 shim flags identical to AE
  - Trim `models:` block to just `fes_analytics:` defaults (drop the `smoke:` block from AE)
- `packages.yml` — copy AE's version (dbt_utils 1.3.0)
- `dependencies.yml` (NEW):
  ```yaml
  projects:
    - name: fes_data
  ```
- `.gitignore` — copy AE's
- `README.md` — replace 72-byte stub with brief project purpose + owner
- Leave `.alfredo.yml`, `.ponzu.yml`, `.github/` untouched — governance wiring stays.

**6. Copy the 116 movable fes_users models from dbt-fes-ae to dbt-fes-analytics** 🤖
```bash
# From dbt-fes-analytics working tree:
git checkout -b split/fes-users-mesh
mkdir -p models/fes_users

# The 12 "must stay in AE" residuals (do NOT copy these):
MUST_STAY=(
  hashed_email_eco_profit fanapp_cohort_labels fancash_site_tenant_mapping
  amplitude_session_performance fanapp_install_attributes fangraph_ecosystem_daily_activity_v2
  hashed_email_ftu fanapp_install_identity_map fanapp_potential_fraud fraudulent_ips
  dim_appsflyer_campaign_mapping dim_appsflyer_creative_mapping
)

# Copy everything from AE's fes_users/, then delete the 12 residuals from the analytics-side copy
cp -R ~/repos/dbt-fes-ae/models/fes_users/* models/fes_users/
for m in "${MUST_STAY[@]}"; do
  find models/fes_users -type f -name "${m}.sql" -delete
done

# Also prune the 12 from schema YAMLs (models/fes_users/<analyst>.yml or top-level fes_users.yaml)
# Hand-review each YAML; delete just the entries for the 12 residuals.
```
Preserve directory structure exactly for the 116 that DO move (5 clean analyst folders + parts of the other 5). Add `models/fes_users/README.md` documenting: "Analyst models moved from dbt-fes-ae per D42 (2026-07-19). The 12 models that remained in dbt-fes-ae are consumed by AE prod paths; see D42 §1 in `dbt_cloud_migration/analytics-project-split.md`. Cross-project refs to those 12 (and to any other AE model) use `{{ ref('fes_data', 'model_name') }}` — see `dependencies.yml`."

**7. Rewrite cross-project refs in the 116 moved models** 🤖

For every `ref('X')` in a moved SQL file where X is NOT one of the other 115 movers, rewrite to `ref('fes_data', 'X')`. This covers refs to AE-side models AND refs to the 12 residuals staying in AE.

Confirmed scope from §3 recon (2026-07-19, full report in [`analytics-project-split-access-public-models.md`](analytics-project-split-access-public-models.md)):

| Bucket | Distinct targets | Refs to rewrite |
|---|---:|---:|
| B. Movers → 12 residuals | 11 | 78 |
| C. Movers → AE-proper (non-fes_users) | 58 | 329 |
| **Total to rewrite as `ref('fes_data', 'X')`** | **69** | **407** |
| A. Intra-movers (stay as `ref('X')`) | 22 | 69 |

Semi-automated:
```bash
# Build the movers set (116 models that landed in models/fes_users/ in analytics)
find models/fes_users -name '*.sql' | xargs -I {} basename {} .sql | sort -u > /tmp/analytics_movers.txt
# Then per-file: parse each ref(), if arg not in analytics_movers → rewrite to ref('fes_data', 'X')
```
Do this as a scripted pass, then hand-review the diff. Commit as a single "Rewrite cross-project refs to fes_data project" commit.

**7a. Declare analytics-side sources** 🤖

§3 recon also surfaced **119 `source()` calls across 50 distinct (source, table) pairs**. Sources are NOT covered by dbt Mesh's `access: public` — each project needs its own `sources.yml` declarations.

Simplest approach for cutover: copy `dbt-fes-ae/models/sources/*.yml` to `dbt-fes-analytics/models/sources/` wholesale. Trim post-cutover if analytics doesn't use some. Notable sources include external partner data (`fes_integrations__sheetzu`, `fbg_fde__fbg_transactions`, `salesforce__schema_fanjourney_loyalty_promotion_shares`, `launch_darkly__public`, `live_fde__data_views_fanatics`) and analyst-owned seed data (`fes_users__rohan_gulati`, `fes_users__caroline_wylie`, `fes_users__kevin_bokor`, `fes_users__mitchell_mann`, `FES_USERS__DYLAN_TUCH` — note caps drift). Full list in the recon report.

**7b. Resolve 3 UNKNOWN refs before Phase 3 validation** 👤 (needs analyst input)

§3 recon identified 3 refs that don't resolve to any model in `dbt-fes-ae/origin/main` — likely renamed/deleted since the analyst SQL was last touched. These will fail `dbt parse` in analytics unless fixed:

| Caller | Ref target | Likely status |
|---|---|---|
| `mitchell_mann/fanapp_paid_marketing_reporting.sql:34,69` | `ref('fanapp_paid_campaign_mapping')` | Renamed? Possibly → `dim_appsflyer_campaign_mapping` (a residual) |
| `rohan_gulati/fanapp_paid_spend.sql:45` | `ref('fanapp_paid_campaign_mapping')` | Same |
| `mitchell_mann/fanapp_paid_marketing_march_madness_pacing_dashboard.sql:507` | `ref('fanapp_paid_marketing_march_madness_forecast')` | Seasonal — deleted? |
| `mitchell_mann/pfi_fanapp_crm_user_segments.sql:57` | `ref('pfi_app_engagement')` | Renamed? |

Fix options: (a) analyst updates the ref to the current model name, (b) analyst removes the dead SQL block, (c) leave broken and rely on `dbt parse --skip-invalid` (NOT recommended — fails the cutover-day smoke). Recommend routing to the 4 analysts (mitchell, rohan) for a same-day fix before §8.

**8. Local dbt-core parse in each repo** 🤖 or 👤
- In `dbt-fes-ae`: `dbt parse` on a branch where the 116 movers have been deleted (§23) — verify no orphan refs. The 12 residuals still resolve, since their upstreams are all in AE (either non-fes_users AE models or other residuals).
- In `dbt-fes-analytics`: `dbt parse` — will FAIL until AE's prod job runs successfully with the new `access:` fields (Mesh needs the upstream manifest.json). Substep §14 unblocks this. Also FAILS until 7b resolves the 3 unknown refs.

### Phase 2 — dbt Cloud provisioning

**9. Create dbt Cloud project via Admin API** 🤖
```bash
# POST /api/v3/accounts/70437463654557/projects/
# Body includes: name=fes_analytics, dbt_project_subdirectory=null
```
Capture the new `project_id`. Add to `deploy-jobs.md` and to `remaining-steps.md` → Key IDs.

**10. Attach GitHub connection to `dbt-fes-analytics`** 👤 (UI)
dbt Cloud GitHub App may already have `fanatics-gaming/dbt-fes-analytics` in its install scope from prior AE work — verify at github.com/apps/dbt-cloud/installations. If not, extend the install to include the repo. Then in dbt Cloud UI, link the new project to the repo, `main` branch.

**11. Create prod credential** 🤖
```bash
# POST /api/v3/accounts/.../projects/<new_id>/credentials/
# Reuse SVC_DBT_CLOUD_ROLE keypair (same private key material as AE credential 70437463679983)
# target_name=prod, warehouse=FDE_DBT_CLOUD_WH (or whatever AE prod credential uses)
```

**12. Create prod environment** 🤖
Mirror AE prod env `70437463672974`:
- Name: `Production`
- Type: deployment / `deployment_type=production`
- Release track: `fusion-stable`
- Credential from §11

**13. Create dev credential + dev environment** 🤖 (optional but recommended)
Mirror AE dev env `70437463672950` for smoke testing before prod runs.

**14. Trigger one-off AE prod job to publish manifest with `access:` fields** 👤
After AE PR §4 merges, run any AE prod job (any tag) once so the prod env's `manifest.json` gets the new `access: public` annotations. `dbt_sources` (`70437463791521`) is cheap and read-only — good candidate. **Without this step, the downstream project cannot resolve cross-project refs.**

**15. Create prod job `analytics_users` in new project** 🤖
```bash
# POST /api/v3/accounts/.../jobs/
# project_id=<new>, environment_id=<from §12>
# name: "analytics_users"  (NOT "dbt_users" — avoid name collision with AE's retained job for the 12 residuals)
# execute_steps: ["dbt build --select tag:users"]
# schedule.cron: "35 13 * * *"  (5-min offset from AE dbt_users' "30 13 * * *" — see below)
# triggers.schedule: false  (cron populated but inactive until cutover — same pattern as AE per D40)
```

**Timing offset rationale.** AE `dbt_users` (12 residuals) is upstream of analytics `analytics_users` (116 models) via cross-project refs — 78 known cross-project ref hits from §1 analysis. To reduce compile-time freshness lag, schedule analytics 5 minutes after AE. Analytics compilation still reads AE's LATEST successful prod manifest (env-scoped, per D42 freshness rules), so a same-minute schedule would work too but the 5-min offset means analytics gets today's build of the 12 residuals rather than yesterday's.

Alternative: use `job_completion_trigger_condition` on AE's `dbt_users` job (like `dbt_loyalty` chains from `dbt_fanflow`). Cleaner, but adds a coupling between the two `dbt_users` jobs — recommend deferring to post-cutover once the split is proven stable.

Capture the new prod job ID. Add to `deploy-jobs.md` and `post-cutover-architecture.md`.

**16. AE `dbt_users` job (`70437463791520`) — keep + adjust selector to residuals-only** 🤖
Under the leave-in-place variant (2026-07-19), the AE `dbt_users` job stays active — it now builds only the 12 residuals. No PATCH needed if `tag:users` still selects them (all 12 originated in `models/fes_users/` so they inherit `tags: ['users']` — verify).

If a subset of the 12 have lost the `users` tag through hoist-config edits, add explicit include patterns to the selector, e.g. `dbt build --select tag:users`. Selector remains `tag:users` if intact.

Add to `post-cutover-watch-list.md` §3 as "AE `dbt_users` job now builds 12 residuals; deprecated when §1a post-cutover hoist completes."

### Phase 3 — Cross-project validation via dbt Cloud IDE

**Local Fusion is NOT the day-1 validation surface** (updated 2026-07-19 based on FBG-wide recon). Validation happens through the dbt Cloud IDE and dbt Cloud job triggers — the same tools the fes_users analysts will use day-1. Local dbt-core CLI is a post-cutover adoption; see [`local-development.md`](local-development.md).

**17. IDE smoke: open analytics dev env in dbt Cloud IDE** 🤖 + 👤
- Confirm the IDE loads the analytics project against its dev env with `SVC_DBT_CLOUD_ROLE` credential.
- Preview one representative fes_users model (e.g., `dylan_tuch/ticketmaster_loyalty.sql`) — confirms `{{ ref('fes_data', 'X') }}` resolves against AE prod's manifest and returns rows.
- `dbt parse` from IDE command bar — confirms every fes_users model compiles clean against the AE upstream.

**18. Trigger analytics dev smoke job via API** 🤖
```bash
# POST /api/v2/accounts/.../jobs/<dev_job_id>/run/
```
Runs `dbt build --select tag:users` in the dev env. Expect success once §14 has published the AE prod manifest with `access: public` fields.

**19. Trigger analytics prod job manually (schedule still false)** 🤖
```bash
# POST /api/v2/accounts/.../jobs/<prod_job_id>/run/
```
Should build into `FES_USERS.<ANALYST>` schemas with `SVC_DBT_CLOUD_ROLE` as owner. Verify with:
```sql
SHOW TABLES IN SCHEMA FES_USERS.ROHAN_GULATI;
-- owner column should be SVC_DBT_CLOUD_ROLE for anything the analytics job just built
```

**20. Parallel-run diff (optional if timeline allows)** 🤖
Same shadow-schema pattern as the main cutover:
- dev MWAA (via legacy `dbt_users` DAG in fes-airflow) writes to `FES_USERS.<ANALYST>_DEV_MWAA`
- dev analytics-project writes to `FES_USERS.<ANALYST>_DEV`
- Run `parallel_run_verify.sql` HASH_AGG diff over each analyst schema
- If timeline is tight, skip — the models are analyst outputs, not core prod data; risk of divergence has low blast radius.

**21. Document Mesh + IDE gotchas learned** 🤖
Append to this file's `## Learnings` section (created at time of completion) as substeps execute. Feed anything reusable back into `local-development.md`.

### Phase 4 — fes-airflow DAG cleanup

**22. Verify `dbt_users.py` deletion is on the cutover branch** 🤖
Per D41, `dbt_users.py` was deleted in the `dbt-cloud-migration` fes-airflow branch. Confirm with:
```bash
git ls-tree -r dbt-cloud-migration --name-only | grep dbt_users
```
Should return empty. If it's still there → add its deletion to PR #2252.

### Phase 5 — dbt-fes-ae PR to remove the 116 moved fes_users models

**23. Open `dbt-fes-ae` PR: delete the 116 moved fes_users models (retain the 12 residuals)** 🤖 or 🧑‍💻
```bash
# From dbt-fes-ae:
git checkout -b split/remove-fes-users-to-analytics

# Build "delete" list: models/fes_users/**/<name>.sql where name is NOT in MUST_STAY (12)
MUST_STAY=(
  hashed_email_eco_profit fanapp_cohort_labels fancash_site_tenant_mapping
  amplitude_session_performance fanapp_install_attributes fangraph_ecosystem_daily_activity_v2
  hashed_email_ftu fanapp_install_identity_map fanapp_potential_fraud fraudulent_ips
  dim_appsflyer_campaign_mapping dim_appsflyer_creative_mapping
)

# Delete every .sql under models/fes_users/ that is NOT one of the 12
find models/fes_users -name '*.sql' | while read f; do
  name=$(basename "$f" .sql)
  keep=false
  for m in "${MUST_STAY[@]}"; do
    [[ "$name" == "$m" ]] && keep=true && break
  done
  $keep || git rm "$f"
done

# Prune schema YAML entries for the deleted models (hand-review each YAML)
# Empty analyst folders (hajime_alabanza, kelsey_carrier, kevin_bokor, natalie_cutter, stacy_lin
# — all now empty after this pass) — git rm -r them.

dbt parse  # confirm no orphan refs among the 12 residuals + AE-proper models
git commit -m "Remove 116 fes_users models moved to dbt-fes-analytics per D42 (retain 12 AE-consumed residuals)"
```
**Merge order matters**: this PR must merge AFTER §4 (access:public), AFTER §14 (manifest published), AFTER §18 (analytics dev smoke passing) and §19 (analytics prod job proved working). Otherwise AE's default `dbt build` runs would try to compile against nothing / the wrong shape.

### Phase 6 — Cutover coordination

**24. At main cutover moment (T0)**: activate analytics prod job schedule alongside AE prod jobs 👤
`scripts/dbt_cloud_activate_schedules.sh` — extend to include the new analytics job ID, or run a separate PATCH for it.

**25. Monitor first analytics prod run** 👤 + 🤖
Verify `{{ ref('fes_data', 'X') }}` resolves in prod. If it fails: symptom will be `Unable to find model` at compile time. Fix: re-run an AE prod job to refresh manifest, then re-trigger analytics.

---

## Implications for existing docs & scripts

### `sql/cutover_ownership_transfer.sql`
**No change.** Both projects use `SVC_DBT_CLOUD_ROLE`; FES_USERS is already in `target_dbs`. Dry-run counted 145 MWAA-owned FES_USERS objects (mostly legacy `dbt_users` DAG output) — those transfer as usual.

### `sql/cutover_rollback.sql`
**No change.** Same reasoning — rollback still restores MWAA ownership on the same set of objects.

### `remaining-steps.md`
- One new item under **Before cutover**: "Analytics project split — see [`analytics-project-split.md`](analytics-project-split.md)."
- **Key IDs** gets a new subsection for the analytics project (project ID, prod env ID, prod credential ID, prod job ID).
- **At cutover moment** step D (schedule activation) extends to cover the new analytics prod job.

### `decisions.md`
- **D42** added (this session): confirms one-way Mesh, distinct project name, same service role.
- **D2, D3, D23, D32** get cross-references — none reversed, but each acknowledged as informing D42.

### `post-cutover-architecture.md`
- New subgraph box in the mermaid diagram for the analytics dbt Cloud project (1 job, cron-triggered, no Airflow interaction).
- Summary table gets a new row for the analytics `analytics_users` job.
- Total prod job count changes: AE stays at 22 (dbt_users retained, now building the 12 residuals); analytics adds 1 (`analytics_users`, 116 models); grand total = 23.

### `post-cutover-watch-list.md`
- **New §2**: cross-project ref resolution failures (symptoms, how-to-check, fix pattern).
- **New §3**: AE `dbt_users` job now builds 12 residuals (was 128). Deprecated when §1a post-cutover hoist completes — track expected job death.
- **New §4** (add): analytics `analytics_users` schedule (`35 13 * * *`) must fire AFTER AE `dbt_users` (`30 13 * * *`). Monitor for schedule drift or same-day failures cascading downstream.

### `test/README.md`
- Add **Test 8**: cross-project Mesh smoke — run analytics dev job, confirm it resolves refs into AE. Status ⏳.

### `coupling-test-plan.md`
- **No change.** Analytics project has zero Airflow coupling — coupling test scope unaffected.

---

## Rollback plan for the analytics split itself

Independent of the main cutover rollback. Two windows:

**Before main cutover (pre-T0):**
1. Delete analytics dbt Cloud project via API (removes the `analytics_users` job with it).
2. Revert `dbt-fes-ae` PR that removed the 116 moved models (§23). Restores AE with all 128 fes_users models.
3. AE `dbt_users` job (`70437463791520`) already active — no restore action needed under leave-in-place variant.
4. Leave `dbt-fes-analytics` repo with new files or revert to empty scaffold — either is fine, doesn't affect prod.

**After main cutover (post-T0):** effectively rolling back cutover. Follow main cutover rollback path (`git revert` on cutover PR, run `cutover_rollback.sql`), AND:
5. Delete analytics dbt Cloud prod job schedule.
6. Do NOT delete the analytics project itself yet — leave it in place for forensics.

---

## Timeline & fallback

**Estimated effort**: 2-3 dev days end-to-end (assuming Enterprise tier confirmed, GitHub App scope extended without friction, no cross-project ref surprises).

**Timeline risk**: main cutover is 2026-07-23. Today is 2026-07-18. 5 calendar days = 3 working days. Phases 1-3 can happen in parallel with existing pre-cutover work; Phases 4-5 depend on AE-team review cadence.

### Fallback: Option B — defer analytics split to post-cutover
If Phase 3 validation isn't clean by end-of-day 2026-07-22:

- Keep all 128 fes_users models in `dbt-fes-ae` for main cutover (skip the 116-model move).
- AE `dbt_users` job (`70437463791520`) runs all 128 fes_users models from dbt-fes-ae, unchanged.
- Analytics split becomes a post-cutover follow-up (new Post-cutover item in `remaining-steps.md`).
- No prod risk added on cutover day.

**Decision gate**: Alex calls Option A vs Option B by EOD 2026-07-22 based on Phase 3 evidence.

---

## Open questions (flagged, not blocking plan drafting)

1. **Dev environment scope**: does the analytics project need a dev env, or is prod-only acceptable given single-job scope + analyst-output blast radius? Recommend dev env for parity with AE and for Phase 3 smoke, but skippable if timeline is tight. Also relevant for local Fusion — see `local-development.md` "Manifest freshness."
2. **`dbt_users` job selector**: current AE selector is `tag:users` (per `deploy-jobs.md`). Once fes_users is the only content in the analytics project, the selector could simplify to `dbt build` (build everything). Cosmetic — keep `tag:users` for now to match cutover-day expectations.
3. **Slack alerting scope**: extend the Slack failure webhook (currently blocked on URL from Alex) to cover the new analytics job? Yes — same account, add job ID to the subscription list once webhook is live.
4. **Group name confirmation**: substep §4 uses `analytics_engineering` — worth a 30-second confirmation with AE team before opening the PR, but low-risk; can rename later without breaking anything downstream (group name isn't in cross-project refs).
