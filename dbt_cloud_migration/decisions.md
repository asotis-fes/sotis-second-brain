# dbt Core → Cloud Migration: Decisions Log

Full chronological log. Working document for FES Data team review. Each entry captures what's been decided, what was considered, why, and current status.

**Status legend:**
- 🔒 **Locked** — explicitly affirmed by Alex
- ⏳ **Proposed** — recommendation pending team review
- ❓ **Open** — flagged but not yet decided
- ⚠️ **Superseded** — previously locked, later replaced (see the newer decision that references it)

D1–D18 were locked during initial 5–6 week phased planning (June 2026). D19–D41 followed as YOLO/big-bang execution accelerated the timeline (July 2026). Nothing in this repo distinguishes YOLO from big-bang anymore — they collapsed into a single plan.

---

## D1 — Migration approach: big-bang cutover with one-PR-revert rollback 🔒

**Decision:** Cut all ~22 dbt DAGs over to dbt Cloud in a single Saturday window. Rollback path is a one-PR revert in `fes-airflow` + renaming `.py.disabled` → `.py` to re-enable Airflow's dbt DAGs. The legacy `fes-airflow/dags/dbt/` directory is NOT deleted at cutover — it stays as a frozen restore point until Cloud is fully stable (~weeks post-cutover).

**Considered:** Wave-based incremental migration of 3-5 DAGs per wave over ~4-5 months.

**Why:**
- The rollback design (rename + PR revert) makes big-bang reversible in minutes — inverts the usual big-bang risk profile
- Removes the multi-week shadow-schema bake-in and the source()/ref() cross-boundary gymnastics that came with the wave plan
- ~5-6 weeks calendar vs ~4-5 months for waves; engineers stop maintaining two source-of-truth locations instantly
- Quality bar / curation can happen progressively after cutover

**Implications:**
- D6 changes: shadow-schema becomes a Saturday-morning smoke test instead of multi-week per-DAG bake
- D2 partially defers: everything lands in `analytics_eng` initially; `analytics` repo extraction happens gradually post-stabilization
- Saturday cutover requires more pre-work consolidated (all jobs, all alerts, all Snowflake grants) but tighter overall calendar

---

## D2 — dbt Mesh: deferred to post-cutover gradual extraction 🔒

**Decision:** At Saturday cutover, the entire dbt project lands in `analytics_eng`. The `analytics` repo is created empty and stays empty initially. Analyst-owned models are extracted gradually from `analytics_eng` into `analytics` over weeks/months post-stabilization. Mesh contract (`dependencies.yml`, `access:`, `contract:`) gets established at extraction time, not at cutover.

**Considered:**
- Pre-cutover Mesh split into two repos from day 1 (previous version of D2)
- Single Cloud project, never split (Mesh not adopted)

**Why:** Big-bang cutover (D1) is already cognitively expensive. Layering a Mesh restructure on top inflates scope and Saturday risk. The Mesh split is a code-organization refactor that doesn't require the dbt Cloud migration to be in progress — better as a follow-on.

**Implications:**
- Day-1 PR ownership in `analytics_eng` is muddied — both AE and analyst PRs land there
- Foundation models won't have `access: public` + `contract: enforced` discipline until extraction
- **Mitigation:** organize `analytics_eng/models/` into `analytics_eng/` and `analytics/` subdirectories from day 1. Tag-based ownership + CODEOWNERS by subdirectory gives most of the team-boundary benefit. Subsequent extraction becomes `git mv` + repo split, not a code reorganization.

---

## D3 — Repo structure: two empty new repos, migrate models in as they cut over 🔒

**Decision:** Create two **empty** new repos, one per Mesh project: `analytics_eng` and `analytics`. Models are copied from `fes-airflow/dags/dbt/` into the appropriate new repo at the moment they migrate to Cloud, with quality-bar updates applied (column descriptions, required tests, FBG-style YAML standards, 1.10 syntax). Once migrated, the model is **deleted from `fes-airflow/dags/dbt/`** in the same change.

**Considered:**
- Extract existing project with full git history via `git filter-repo`, then vendor into `fes-airflow` at deploy time (previous version of D3/D4)
- Keep dbt nested in `fes-airflow` with path filter on the dbt Cloud GitHub App

**Why:**
- Forces a curation moment per model — tech debt doesn't carry forward by default
- Two repos preserve the AE/analyst ownership boundary at the repo level
- No vendoring infrastructure needed — `fes-airflow/dags/dbt/` shrinks as models leave; engineers edit the new repos for migrated models, the old path for un-migrated ones
- Avoids the "we'll clean it up later" failure mode

**Implications:**
- Lost git history for migrated files (file history starts at copy date)
- Engineer workflow during transition: edit new repo for migrated models, edit `fes-airflow/dags/dbt/` for un-migrated ones. Each model lives in exactly one place at any moment.
- Need a clear "minimum quality bar" definition (see D16) so the curation gate is consistent

---

## D4 — REMOVED (vendoring no longer needed) 🔒

**Original decision:** MWAA vendors locked SHAs of new repos into `fes-airflow/dags/dbt/` at deploy time.

**Why removed:** Under D3-revised, each model lives in exactly one repo at any moment. `fes-airflow/dags/dbt/` continues to hold un-migrated models natively; the new repos hold migrated models. No code is shared between repos, so no sync mechanism is needed.

---

## D5 — dbt version: current Airflow project stays on 1.8 🔒

**Decision:** Do not upgrade the existing Airflow-orchestrated dbt project to 1.10. The new Mesh repos run on Cloud's "Latest" release track (1.10+) natively. The Airflow-orchestrated path stays on dbt-core 1.8.7; as models migrate out of `fes-airflow/dags/dbt/`, the legacy codebase shrinks naturally until empty.

**Considered:** In-place upgrade of `fes-airflow/dags/dbt/` to 1.10 as a prerequisite.

**Why:** D3 (empty new repos) cleanly separates the two version worlds — no behavior-flag gymnastics needed. Each repo has whatever syntax fits its dbt version. Migration copies the model, updates syntax to 1.10, applies new standards.

---

## D6 — Validation pattern: Saturday-morning smoke test, not multi-week shadow bake 🔒

**Decision:** Saturday morning (a few hours before the cutover window), run all Cloud jobs against a shadow schema via `DATABASE_OUTPUT_OVERRIDE`. Verify every job builds successfully — exercises auth, grants, parse, warehouse access, materialization, env var resolution. If all green, proceed with cutover. If anything fails, abort and reschedule.

**Considered:** Per-DAG shadow bake over weeks (previous version of D6); no validation at all (skip straight to prod writes).

**Why:** Big-bang plan (D1) requires upfront confidence that everything will work. A 2-hour smoke test is the insurance policy. Multi-week per-DAG shadow bake is unnecessary given the one-PR-revert rollback path.

**Open:** define explicit pass criteria for the smoke test. Suggestion: every job exits 0; every target table exists in the shadow schema; row counts are within sanity bounds (not necessarily exact match to prod since refresh windows differ).

---

## D7 — Cross-DAG dependencies: replace ExternalTaskSensor with Cloud-native primitives 🔒

**Decision:**
- **dbt-to-dbt chains** (today's `dbt_xtremepush` waits on `dbt_fangraph`, etc.) → Cloud's **job completion triggers** (`dbtcloud_job` resource supports this natively)
- **Airflow export DAGs waiting on dbt** → Airflow's `DbtCloudJobRunSensor` (from `apache-airflow-providers-dbt-cloud`) polls Cloud API for job completion

**Considered:** Custom Lambda webhook listener to translate Cloud events into Airflow triggers.

**Why:** Built-in primitives exist on both sides. No new service to maintain. `DbtCloudJobRunSensor` is the same shape as `ExternalTaskSensor`, just polling a different endpoint.

---

## D8 — Alerting: native Cloud notifications + FireHydrant email signals 🔒

**Decision:**
- **FireHydrant P1/P2/P3** — 3 Cloud notification subscriptions, each filtered by `job_ids`, each emits to the corresponding FireHydrant email signal endpoint
- **Slack** — native account-level Slack OAuth in Cloud; per-job channel subscriptions
- All subscriptions managed via Terraform (`dbtcloud_notification` + `dbtcloud_partial_notification`)

**Considered:** Custom Lambda webhook listener for routing.

**Why:** Native notifications + FireHydrant email integration cover the use case without new infrastructure.

**Open sub-question:** How to handle today's "first-attempt success suppression" (avoid noise when a job retries and succeeds)? Cloud has no native dedup. May need to live without it or add a thin listener later if noise becomes a problem.

---

## D9 — Sequencing: foundation work before Saturday cutover 🔒

**Decision:**
1. Lock decisions (this doc + team review)
2. Provision dbt Cloud account (D10)
3. Create `analytics_eng` repo with full dbt project copy + 1.10-compatibility fixes + `analytics/` subdirectory shell for future AE/analyst split; create `analytics` repo empty
4. Terraform foundation: project, Snowflake credential, environments, env vars, `dbtcloud_job` for every existing `dbt_*` DAG selector
5. Snowflake `SVC_DBT_CLOUD_ROLE` grants audit + apply
6. Single-source freshness test (1 source, validates end-to-end freshness path)
7. Two-dummy-model chain test (validates Cloud job triggers)
8. Airflow `DbtCloudJobRunSensor` POC against a dummy Cloud job (validates the export-DAG mechanism)
9. Alerting + notifications test: FireHydrant P1/P2/P3 + Slack subscriptions, synthetic failure end-to-end
10. Write + dry-run the Admin API kill-switch script
11. Pre-stage the fes-airflow export-DAG-swap PR with Cloud job IDs from step 4
12. Pre-stage the fes-airflow rename script (`dbt_*.py` → `dbt_*.py.disabled`)
13. Source freshness Cloud jobs created (4 domain-grouped, see Source Freshness doc)
14. **Saturday cutover** per D17
15. Stabilization watch (week 1 post-cutover)
16. Begin gradual `analytics_eng` → `analytics` extraction per D2 (ongoing)

**Considered:** Wave-based incremental migration (prior version of D9).

**Why:** Big-bang plan (D1) — front-loads foundation work, single cutover event, post-cutover extraction is decoupled from migration risk.

---

## D10 — Cloud tier, region, auth ⏳

| Aspect | Recommendation | Rationale |
|---|---|---|
| Tier | **Enterprise** | Required for: audit logs, Notification Manager role, dbt Mesh, advanced CI concurrency |
| Region | **US multi-tenant** | Default; revisit if FBG compliance requires single-tenant or non-US |
| Snowflake auth | **Keypair** | Matches today's pattern, supported by `dbtcloud_snowflake_credential` |
| Service user | **New `SVC_DBT_CLOUD_ROLE`** | Don't reuse `SVC_MWAA_ROLE`; grants mirrored 1:1 |
| Env naming | **`dev` + `prod`** | Must match existing `target.name == 'prod'` Jinja conditional in models |

**Status:** Open for team review. Enterprise tier is the only decision with material cost impact.

---

## D11 — Canary DAG selection ❓

**Original proposal:** `dbt_users` (no downstream exports, isolated blast radius).

**Now complicated by D2:** the canary lives in only one of the two Mesh projects. Need to decide:
- Is `users` foundation or analytics?
- Should the canary be a foundation model (more critical, better test of contracts) or an analytics model (lower risk)?

**Decision needed:** Pick one canary per Mesh project, or share a single canary across both?

---

## D12 — Refresh cadence standards (cost discipline) ❓

**Borrowed from FBG migration doc:** 4-hour refresh standard, exceptions need Director/VP approval, exception cost charged back to requesting team.

**Status:** Open. FES has no current cadence policy. Worth establishing pre-migration to avoid cost surprise when Cloud run-minutes are added on top of Snowflake credits.

**Questions for team:**
- Are there any models that must run more frequently than 4 hours for business reasons?
- Who owns "approval authority" for exceptions on the FES side?

---

## D13 — Per-model warehouse routing under Cloud env model ❓

Today: `target.name == 'prod' ? FDE_MWAA_3XL_WH : FDE_DEVELOPER_3XL_WH` in model configs.

**Open:** Confirm that Cloud's `target.name` matches our env naming (D10 says `prod` — should be fine) so existing model configs work without refactor. Sanity check needed before mass migration.

---

## D17 — Cutover sequence (Saturday) 🔒

**Decision:** Saturday cutover sequence (all times relative to T0 = chosen cutover hour):

| Time | Action |
|---|---|
| T-3h | Smoke-test all Cloud jobs into shadow schema; verify all green |
| T-30m | Confirm last Airflow `dbt_*` runs completed cleanly; on-call paged in |
| **T0** | **Rename all `dbt_*.py` → `dbt_*.py.disabled` in fes-airflow; merge MWAA deploy** |
| T0+15m | Confirm MWAA picked up the rename; no `dbt_*` DAGs visible |
| T0+30m | Terraform apply: enable Cloud jobs (flip `paused: false`) |
| T0+45m | Merge the pre-approved fes-airflow export-DAG-swap PR (`DbtCloudJobRunSensor` replacing `ExternalTaskSensor`) |
| T0+1h | Trigger one Cloud job manually as smoke test on real prod |
| T0+1.5h | Let scheduled runs fire normally; watch for failures + alerts |
| T0+6h | First milestone check-in; decide whether to step away |
| Sunday | Spot-check via Cloud Explorer + Discovery API dashboard |
| Mon AM | Wave kickoff: stabilization watch begins |

**Kill switch:** scripted Admin API call paging all Cloud jobs (~10 sec). Documented, dry-run before Saturday. UI per-job pause as fallback. If kill switch fires + Airflow rename reversed + export PR reverted, system is back to pre-cutover state within 15 minutes.

---

## D18 — Export-DAG sensor granularity: wait on Cloud job, not on individual model ⏳

**Decision (proposed, team can overrule):** Export DAGs (the 6 identified previously) replace `ExternalTaskSensor` on a dbt task with `DbtCloudJobRunSensor` on the Cloud job that **contains** the upstream model. Coarser wait than today (waits for entire `tag:` job, not just the specific upstream model).

**Considered:** Create extra per-export Cloud jobs scoped tightly to `+upstream_model` so the wait is granular.

**Why for now:** Big-bang prioritizes simplicity. Coarse wait adds at most minutes of latency for export DAGs vs today's per-task `ExternalTaskSensor`. Acceptable trade for the migration window.

**Future-state pattern (proposed for post-cutover optimization):**
Split each existing tag-level Cloud job into **two chained jobs** at the boundary of the model an export needs:
- **Job A** — builds everything up through and including the export-feeding model (selector: `+upstream_model`)
- **Job B** — builds the remainder of the tag (selector: `tag:foo,exclude:+upstream_model` or equivalent), chained via `job_completion_trigger_condition` to fire on Job A success

Airflow's `DbtCloudJobRunSensor` then waits on **Job A** only. The rest of the tag (Job B) completes asynchronously. Export DAG no longer blocks on models it doesn't care about. Restores today's latency without adding net infrastructure complexity (same models, same compute, just split into 2 chained Cloud jobs).

**Status:** Coarse wait is the day-1 cutover state. Future-state split is a deliberate post-stabilization optimization, applied per-export-DAG where the latency actually hurts.

**Job ID handling:** Cloud job IDs are available as soon as the jobs exist (regardless of creation method — see D19). Export PR is written with hardcoded job IDs once jobs are created (1-2 weeks before Saturday). PR sits in `approved` state until cutover.

---

## D19 — Cloud job creation method ❓

**Open:** how do we actually create the ~22 `dbt_*` Cloud jobs (plus freshness jobs, CI jobs, merge jobs)?

**Options:**

| Option | Pros | Cons |
|---|---|---|
| **Terraform `dbtcloud_*` provider** | IaC, version-controlled, code-reviewed, repeatable, drift-detectable, integrates with existing `fanapp-terraform` patterns. FBG's own dbt Cloud migration uses this. | Requires Terraform expertise + provider state management. More upfront work to author the resources. |
| **dbt Cloud UI** | Fastest to bootstrap; click-and-configure; good for prototyping single jobs | No audit trail, drift risk, every change is manual. Bad for 22+ jobs. |
| **Admin API scripts** | Programmatic, scriptable, no provider state to manage | Ad-hoc — easy to lose track of what's deployed where. No drift detection. |
| **dbt Cloud CLI (`dbt cloud job create`)** | Native dbt tooling | Newer, less battle-tested; thin docs at the time of writing |
| **Hybrid: UI bootstrap then import to Terraform** | Quick wins via UI while building Terraform | Two systems of record during transition; import is fiddly |

**Default recommendation:** Terraform — matches FBG team patterns ([their Terraform migration page](https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/1200652868) is the reference), integrates with our `fanapp-terraform` repo, gives audit + drift detection for free.

**Action:** Alex to ask other FBG teams (Casino, Customer, Finance) what they're using. If consensus is Terraform → lock in. If a team has good reason for a different pattern → reconsider.

**Impact if we change later:** Cloud job IDs (D18) are stable regardless of creation method, so the export-swap PR isn't affected. Migration to Terraform after the fact is supported via `terraform import` blocks but adds friction.

---

## D15 — Migration ordering: handling `ref()` across the migration boundary 🔒

**Obsolete under D1 big-bang.** Entire project moves in one Saturday — no cross-boundary refs exist during the cutover. Re-opens later when models extract from `analytics_eng` → `analytics`; at that point the standard Mesh `dependencies.yml` + `access: public` pattern applies.

---

## D16 — Quality bar for migration ⏳

**Defers to post-cutover.** Big-bang plan moves models as-is into `analytics_eng` on Saturday; quality bar applies only when models extract into `analytics` later (D2). Candidate bar items (column descriptions, PK tests, tags) carry over for that future workstream — not gating the cutover.

---

## D14 — Audit logging, data residency, compliance ❓

**Open:**
- Audit logs are Enterprise-tier — does FBG compliance require them?
- Data residency — does US multi-tenant region meet compliance constraints for prod FanCash / PII data?
- Cloud SLA — acceptable risk that prod jobs depend on Cloud uptime?

**Status:** Need answers from compliance/security stakeholders before final tier + region lock.

---

## Items explicitly out of scope (per Alex)

- Team training plans / enablement (not a technical decision)
- In-place upgrade of existing fes-airflow dbt project to 1.10 (per D5)
- Custom Lambda webhook listener for alerting (per D8) or dependencies (per D7)

---

## Open questions for the team

1. **Cloud tier** — Enterprise vs Team (D10). Cost vs feature gate.
2. **Refresh cadence policy** — D12. Optional pre-cutover; can be enforced post-stabilization.
3. **Smoke-test pass criteria** — D6. What "all green" means precisely on Saturday morning.
4. **Compliance / data residency** — D14.
5. **First-attempt success suppression** — D8 sub-question. Probably acceptable to live without on day 1.
6. **Saturday cutover date** — pick the target Saturday + on-call coverage.
7. **Export-sensor granularity** — D18. Confirm coarse wait now, future-state split later, or push for the split upfront.
8. **Cloud job creation method** — D19. What do other FBG teams use? Default recommendation is Terraform.

---

## Change log

| Date | Change |
|---|---|
| 2026-06-19 | Initial draft. D1-D8 locked. D9-D14 proposed/open. |
| 2026-06-19 | D2 repo names changed to `analytics_eng` and `analytics`. D3 flipped from extract-and-vendor to empty new repos + migrate-as-you-go. D4 removed (vendoring no longer needed). D5 clarified (separate version worlds, no behavior flags). D9 sequencing updated. Added D15 (migration ordering across ref boundary) and D16 (quality bar definition) as open. |
| 2026-06-20 | **D1 flipped from waves to big-bang Saturday cutover** with one-PR-revert rollback. D2 defers Mesh repo extraction to post-cutover; everything lands in `analytics_eng` Saturday with `analytics/` subdirectory for AE/analyst boundary. D6 changed from multi-week per-DAG shadow bake to Saturday-morning smoke test. Added D17 (cutover sequence) and D18 (export-DAG sensor granularity). D15 marked obsolete under big-bang. D16 deferred to post-cutover extraction. |
| 2026-06-20 | D18 reframed as proposed (overrulable); added future-state pattern (split tag-level Cloud jobs into 2 chained jobs at the export-feeding boundary, so Airflow waits only on the relevant Job A). Added D19 (Cloud job creation method) as open — default recommendation Terraform, Alex to confirm with other FBG teams. Updated open questions list accordingly. |

---

## D19 🔒 — Aggressive weekend cutover instead of 5-week phased rollout

**Original:** D1 locked big-bang cutover after ~5–6 weeks of foundation work.
**Revised:** Skip most foundation. Weekend build → Monday afternoon Airflow dev smoke test. Prod cutover in a subsequent window once dev is validated.

**Why:**
- Rollback is cheap (single PR revert restores dbt-core execution)
- Snowflake state doesn't change during migration
- Foundation items (Mesh split, TF-ified jobs, tiered alerting, cost monitoring) don't have to precede cutover — they can follow it
- Value of early cutover > value of polish

**How to apply:** Weekend timeline in `README.md`. Anything not in the essentials table is deferred.

---

## D20 🔒 — Transfer table ownership to `SVC_DBT_CLOUD_ROLE` upfront

Rather than run dbt Cloud as `SVC_MWAA_ROLE` (alternative that was considered), transfer ownership of existing dbt-managed tables from `SVC_MWAA_ROLE` → `SVC_DBT_CLOUD_ROLE` before cutover.

**Why:**
- Clean end-state on day 1 — dbt Cloud is a first-class Snowflake identity, not proxying MWAA
- `CREATE OR REPLACE TABLE` requires ownership match — this is the only real fix
- Alternative (proxy MWAA) would require the same ownership migration eventually, delayed and awkward

**How to apply:** Ownership transfer script per `permissions.md`. Runs Saturday evening in dev, later window for prod.

---

## D21 🔒 — Role hierarchy as temporary safety net

`GRANT ROLE SVC_DBT_CLOUD_ROLE TO ROLE SVC_MWAA_ROLE` during transition. MWAA inherits every privilege DBT_CLOUD has.

**Why:**
- MWAA-run Airflow tasks (exports, downstream Python) still need to read/write dbt tables during transition
- `COPY CURRENT GRANTS` preserves non-ownership grants but MWAA's access was implicit through ownership — nothing to preserve for MWAA
- Role hierarchy is a one-liner that avoids explicit re-grants for every table

**How to apply:** Grant Saturday evening. Revoke post-cutover once explicit MWAA grants are in Terraform.

---

## D22 🔒 — Terraform PRs for `admin_roles` parity across all target DBs

Existing [fanapp-terraform#2830](https://github.com/fanatics-gaming/fanapp-terraform/pull/2830) covers `FES_ADS` only. Follow-up PRs (or one bundled PR) needed for the other ~19 target databases before cutover, adding `SVC_DBT_CLOUD_ROLE` alongside MWAA in `admin_roles`.

**Why:**
- Terraform is the source of truth for admin grants
- Adding DBT_CLOUD as parallel admin doesn't remove MWAA — additive change
- Enables per-schema FUTURE grants to hit new tables that dbt Cloud creates

**How to apply:** Draft Saturday evening. Doesn't need to merge before the ownership transfer script — script sets ownership directly regardless of `admin_roles`.

---

## D23 ⏳ — Defer Mesh split entirely, revisit Q4

Original D2 was "Mesh split before cutover" → later revised to "Mesh split after cutover." YOLO extends: don't schedule Mesh split until an explicit Q4 planning conversation.

**Why:**
- Everything works fine as a flat project in `analytics_eng`
- Mesh split adds complexity (dependencies.yml, contracts, cross-project deferrals) without solving a current problem
- Only worth the cost if analytics team is spinning up their own dbt Cloud project

---

## D24 ⏳ — Single Slack channel for all dbt Cloud notifications initially

Original decision proposed tiered FireHydrant P1/P2/P3 mapping.

**Revised:** One Slack channel gets every failure. Tier later.

**Why:**
- Initial cutover window benefits from high signal — nothing filtered out
- Volume of failures pre-cutover is unknown; tiered thresholds without data are guesses
- Post-cutover, wire FireHydrant paging based on observed failure patterns

---

## D25 🔒 — dbt Cloud release track: Fusion Stable

dbt Cloud's UI no longer offers `1.8` (or `1.9`) as a pinnable version. Options are `1.7` (deprecated), the `Core compatible` / `Fusion Stable` release track (currently ~1.10+ semantics, tracked automatically), or `Latest` (bleeding-edge).

**Choice:** Fusion Stable, with legacy `require_*: false` flags in `dbt_project.yml` to preserve 1.8 semantics during migration.

**Why:**
- YOLO commits us to running on dbt Cloud's current dbt long-term; pinning to an ancient version is a stalling tactic
- Fusion Stable is dbt Cloud's *production-recommended* channel — Latest is not
- Legacy flags are temporary shims; audit + remove as migration issues surface

**How to apply:** Set `Fusion Stable` on every dbt Cloud environment (dev + prod). Keep the flags block in `dbt_project.yml` until we've confirmed the full fes-airflow tree parses without them.

---

## D26 🔒 — Smoke-test model routed at `FES_USERS.ALEX_SOTIS` (personal dev)

To validate end-to-end connectivity before any real-shared infrastructure exists, the throwaway `smoke/dbt_cloud_smoke.sql` model writes to `FES_USERS.ALEX_SOTIS.DBT_CLOUD_SMOKE` via `+database` / `+schema` project-level overrides.

**Why:**
- No new DB / schema to provision, no terraform PR, no cross-team grants
- `FES_USERS.<user>` schemas are per-engineer sandboxes; owning the space
- Removes provisioning latency from the "does the plumbing work?" test

**How to apply:** Overrides live in `dbt-fes-ae/dbt_project.yml` and get replaced with real schema/database targets when real models arrive.

---

## D27 🔒 — Two separate service tokens (one per MWAA env)

> **Correction (2026-07-18):** the "per-environment scoping" claim below was **wrong** — dbt Cloud's **Job Admin** role does not offer an environment selector; it's account-wide. Both tokens can technically see both envs. The decision to have two tokens (one per MWAA env) still stands for rotation + audit reasons; the isolation rationale is corrected below. See [`ssm-prod-populate.md`](ssm-prod-populate.md) → "Note on scoping" for the current story.

Two dbt Cloud Service Tokens instead of one shared token:

- `airflow-mwaa-dev` — Job Admin; lives in dev MWAA SSM
- `airflow-mwaa-prod` — Job Admin; lives in prod MWAA SSM

**Why (corrected):**
- Rotation isolation — one token can be revoked without breaking the other env
- Audit clarity — dbt Cloud logs show which MWAA fired a run via token identity
- ~~dbt Cloud Service Tokens support per-environment scoping natively~~ **FALSE for Job Admin. See correction above.**

**Actual isolation** (what keeps prod safe from dev misfires):
- Different AWS accounts host the two SSM parameters (`fes-data-compute-dev` vs `fes-data-compute-prod`); MWAA in each env only reads its own account's SSM
- DAG code branches job IDs per-env via `config.get_value_for_env(dev=..., prod=...)` — the right job ID reaches the right MWAA

**Not enforced by the token** — if a DAG has the wrong job ID hardcoded, either token can trigger the wrong env's job. Post-cutover, worth checking whether **Job Runner** or a custom permission set is env-scopeable; if so, downgrade both tokens for defense in depth.

**How to apply:** Generate `airflow-mwaa-dev` first, populate dev SSM via Self Service. Generate `airflow-mwaa-prod` at prod cutover, populate prod SSM.

---

## D28 🔒 — Airflow connection naming: `dbt_cloud_ae` (by dbt Cloud project)

Airflow provider convention defaults to `dbt_cloud_default`, but every existing fes-data MWAA connection in `mwaa_connections` uses descriptive names (`salesforce_loyalty_cloud`, `http_magnite_curate_api`, `loyalty_postgres_dev`, etc.). Chose repo convention over provider convention.

**Choice:** `dbt_cloud_ae` — one connection per dbt Cloud project that Airflow orchestrates.

**Why:**
- Consistent with existing fes-airflow SSM naming
- Explicit intent: this token gets you `dbt-fes-ae` orchestration
- Scales cleanly — future projects get `dbt_cloud_<project>` alongside
- Cost: every operator/hook needs an explicit `dbt_cloud_conn_id="dbt_cloud_ae"` — trivial

**How to apply:** SSM path `/airflow/connections/dbt_cloud_ae` in both dev and prod. Airflow provider default (`dbt_cloud_default`) is *not* used anywhere.

---

## D29 🔒 — One Airflow connection covers the full dbt Cloud lifecycle

Trigger, sensor-poll, and hook-based metadata reads all authenticate through the same `DbtCloudHook`. No separate connections for read vs. write, or for different API operations.

**Why:**
- Airflow's dbt-cloud provider design — the connection is *credentials*, not a use-case
- `Job Admin` covers both write (POST run) and read (GET run status)
- Adding more connections just to distinguish operations is over-engineering

**How to apply:** All operators / sensors / hooks in fes-airflow use `dbt_cloud_conn_id="dbt_cloud_ae"`.

---

## D30 🔒 — Job IDs hardcoded in DAG code, not stored in SSM/Variables

The dbt Cloud smoke job ID (`70437463791193`) — and future job IDs — live as Python constants in the DAG, not as Airflow Variables or SSM parameters.

**Why:**
- Not sensitive (numeric identifier)
- SSM Self-Service round-trip is more friction than a code push
- Airflow UI Variables aren't used in fes-airflow (per team convention — SSM only, and only for secrets)

**How to apply:** All dbt Cloud job IDs as module-level constants in the relevant DAG file(s). Change management is a normal PR review.

---

## D31 🔒 — SSM placeholder in both dev AND prod up front

Terraform PR that adds the `dbt_cloud_ae` placeholder creates it in *both* `fes-data-compute-dev-1` and `fes-data-compute-prod-1` — even though prod won't have a real value until production cutover.

**Why:**
- Provisioning cost: zero (value stays `change me`)
- Blast radius: none (no prod DAG references the connection yet)
- Saves a follow-up terraform PR when we're ready to cut over prod
- Makes the naming precedent explicit for prod before any prod work is scheduled

**How to apply:** `mwaa_connections` map gets the entry in both `terraform/fes-data/compute/dev/compute/local.tf` and `terraform/fes-data/compute/prod/compute/local.tf`. Prod SSM populated via Self Service at cutover.

---

## D32 🔒 — dbt project name stays `fes_data` (not `fes_ae`)

The `dbt-fes-ae` repo hosts a dbt project whose `name:` in `dbt_project.yml` is **`fes_data`** — the same name it had inside `fes-airflow/dags/dbt/`.

**Why:**
- Preserves compatibility with every existing model config that references `fes_data:` (in `dbt_project.yml`, `schema.yml`, dispatch entries)
- Preserves compatibility with dbt Cloud Mesh cross-project `ref('fes_data', 'model_name')` calls if we ever add downstream projects
- Repo name (`dbt-fes-ae`) and dbt project name (`fes_data`) don't need to match — the repo name describes ownership (Analytics Engineering team), the project name describes the dbt package identity

**Trade-off:** minor cognitive dissonance — `dbt-fes-ae/dbt_project.yml` says `name: fes_data`. Documented here to head off confusion.

**How to apply:** Never rename to `fes_ae` — even during cleanup work. The scaffold PR (#1) will change name from `fes_ae` back to `fes_data` when it rebases on top of #2.

---

## D33 ❌ SUPERSEDED by D40 — Cutover proceeds in waves within prod, not a single big-bang

**Status:** Superseded 2026-07-12. See D40.

**Why superseded:** This decision was written by a prior session and diverged from both D1 (locked big-bang) and D19 (YOLO's Monday cutover-in-a-subsequent-window). The engineer clarified 2026-07-12 that single-cutover-with-rollback-plan is the intended shape — testing everything on dev before ANY prod change, then one atomic merge to main. Waves added complexity (per-wave PR review cycles, per-wave ownership transfers, cross-DAG-cutover-ordering constraints) without matching stated intent.

**Original decision (kept below as historical record):**
- Wave 1 — loyalty pilot (4 diff-verified ledger models, one DAG).
- Wave 2 — P3 low-blast DAGs (no external sensors, mostly cosmetic outputs).
- Wave 3 — bulk of remaining P2/P3 DAGs.
- Wave 4 — DAGs that other DAGs depend on (needed coordinated cutover with dependent-DAG sensor updates).
- Deferred — `dbt_fangraph` (source() defer issues, separate design conversation).

---

## D34 🔒 — `utils.dbt_cloud.create_dbt_cloud_task_group` helper

New sibling module to `utils.dbt` (which stays for un-migrated DAGs). Exports one helper that returns a TaskGroup wrapping the standard trigger+sensor+log_run trio.

**Why:**
- Every cutover DAG's diff becomes ~5 lines instead of ~30
- TaskGroup gives ingest/export DAGs a stable anchor for gating logic (originally D37's use case; under D41 only relevant for the surviving Airflow DAGs with ingest/export coupling)
- Consolidates operator/sensor/hook boilerplate — future changes (e.g. timeout tuning, additional metadata capture) happen in one place

**How to apply:** New file `fes-airflow/dags/utils/dbt_cloud.py`. Merges before any cutover PR. See `cutover-playbook.md` §1a for signature.

**Implementation note (2026-07-12):** `log_run` `@task`'s parameter is named `dbt_run_id` (not `run_id`) to avoid the D-11 reserved-context-name collision. Initial draft of §1a had `run_id` which would have failed at runtime; fixed once helper implementation exercised the code path.

---

## D35 🔒 — One dbt Cloud deploy job per fes-airflow DAG, selector = current tag

**Naming:** `<dag_name>` (e.g. `dbt_loyalty`, `dbt_daily`). Environment: `deployment` for prod; `deployment_parallel_run` for parallel-run wave.

**Steps:** `dbt build --select tag:<tag>` where `<tag>` matches the current `tags=[...]` argument.

**Why:**
- Mirrors current DAG shape 1:1 — no re-partitioning of models
- Selector already tested via `dbt ls` from PR #4
- Cutover surface = swap Airflow's per-model expansion for one Cloud job trigger; no dbt-side changes

**How to apply:** UI creation (per D19 recommendation — Terraform-ify post-cutover). Job IDs land in DAG-file constants (per D30). Job ID registry: `projects/dbt_cloud_migration/deploy-jobs.md`.

---

## D36 ❌ SUPERSEDED by D40 — Parallel-run validation strategy per-DAG (shadow schema for P2, direct cutover for P3)

**Status:** Superseded 2026-07-12. See D40. The per-DAG P2-vs-P3 split disappears under single-cutover — parallel-run validation happens once, on dev, across ALL DAGs at once.

**Under D40, parallel-run still uses the same technique** (dev shadow schemas via `<schema>_SHADOW` + `parallel_run_verify.sql` HASH_AGG diff macro), but:
- All DAGs run in parallel-run mode on dev (not just P2)
- No "direct cutover for P3" — everything gets diffed on dev
- Ownership transfer happens once at cutover, not per-DAG
- One `parallel_run_verify.sql` invocation covers every model in the migration

**Original decision (kept below as historical record):**
- Shadow schema for P2 DAGs — dbt Cloud writes to `<schema>_SHADOW` alongside MWAA's prod writes; nightly HASH_AGG diff.
- Direct cutover for P3 — skip parallel run when blast radius is low.

---

## D37 ❌ SUPERSEDED by D41 — Cross-DAG dbt-to-dbt deps stay in Airflow via ExternalTaskSensor on sibling `log_run`

**Status:** Superseded 2026-07-13 by D41.

**What D37 said:** Use `ExternalTaskSensor` in a dependent Airflow DAG pointing at its sibling's `<group_id>.log_run` for dbt→dbt chains. Coarse wait.

**Why superseded:** D41 restructured the migration around a stricter rule: "no dbt commands run under MWAA post-cutover". Any Airflow DAG that only triggers dbt Cloud and waits for it has no reason to exist — those DAGs are DELETED. What remains in Airflow: only DAGs with ingest or export coupling (e.g. `dbt_loyalty_6hours` waits on `transaction_raw_replication_handshake_sensor.sql`). Pure dbt→dbt orchestration moves entirely inside dbt Cloud via `job_completion_trigger_condition` (restoring the original D7 intent). The `dbt_loyalty` DAG that D37 was written to preserve doesn't exist post-cutover — the chain to fanflow is now `job_completion_trigger_condition` between prod dbt Cloud jobs `dbt_fanflow` (`70437463791505`) and `dbt_loyalty` (`70437463791501`).

**Current correct pattern (per D41):**
- **Airflow's role**: ingest signal → trigger dbt Cloud job → poll to completion → export (only when a DAG has an ingest or export leg)
- **dbt Cloud's role**: dbt-to-dbt chaining via `job_completion_trigger_condition` (D7 restored); dbt job scheduling via native `schedule.cron`
- **Cutover mechanic**: 22 prod jobs already have cron + `triggers.schedule=false`; single PATCH flips `triggers.schedule=true` at cutover, activating both the schedules and the chain

---

## D38 ❌ SUPERSEDED by D40 — Ownership transfer per-DAG at cutover moment, not upfront

**Status:** Superseded 2026-07-12. See D40. Under single-cutover, ownership transfer happens once, alongside the cutover PR merge — same shape as D20 originally described, applied via `snow sql` at the merge moment for ALL migrated tables.

**Why superseded:** Per-DAG timing was invented to solve a per-wave problem. With no waves, there's no per-DAG timing — the single cutover moment is the single ownership-transfer moment.

**What still applies from D38:**
- `COPY CURRENT GRANTS` on every `GRANT OWNERSHIP` (unchanged)
- Role-hierarchy safety net (D21) covers any table not explicitly transferred
- Rollback SQL prepared in the cutover PR (single script, not per-DAG)

---

## D39 🔒 — Airflow context vars threaded to dbt Cloud via `steps_override`

Some incremental models reference Airflow's `data_interval_start` / `data_interval_end` / `ds_nodash` via `{{ var(...) }}`. Examples: `cde_loyalty_analytics_ledger_metrics.sql`, `cde_tier_points_overrides_metrics.sql`, `cde_loyalty_balance_metrics.sql`, and others (grep required per-DAG).

**Decision:** For DAGs whose selector includes such models, `DbtCloudRunJobOperator.steps_override` overrides the job's default steps with a `dbt build --select ... --vars '...'` command that Jinja-renders Airflow context at trigger time.

**Why:**
- dbt Cloud's job runs don't automatically inherit trigger-time context — `steps_override` is the official mechanism per dbt Cloud API v2
- Alternative (setting env vars per-run) is clunkier
- Airflow's Jinja renders `{{ data_interval_start | ts }}` inside `steps_override` — same rendering as today's BashOperator env vars

**How to apply:** `cutover-playbook.md` §4 has the example invocation. Grep required before writing each DAG's PR:

```bash
grep -rln "data_interval_start\|data_interval_end\|ds_nodash" \
  ~/repos/fes-airflow/dags/dbt/models/
```

For DAGs where no included model references these vars, omit `steps_override` and let the job's baked-in step run.

---

## D41 🔒 — Delete any dbt_*.py Airflow DAG that has no ingest/export coupling; also convert every embedded dbt call in ingest DAGs to a dbt Cloud API trigger

Restructures which DAGs live in Airflow at all, AND how remaining DAGs interact with dbt.

**Rule (two parts):**
1. **Standalone-dbt DAGs**: an Airflow DAG that only triggers dbt Cloud and waits for it has no reason to exist. dbt→dbt chaining moves to dbt Cloud (`job_completion_trigger_condition`). Pure dbt jobs get scheduled in dbt Cloud.
2. **Ingest/export-coupled DAGs**: every embedded `dbt.create_dbt_dag(...)` call in an ingest or export DAG becomes a `create_dbt_cloud_task_group(job_id=<new dbt Cloud job>)` call. The DAG still exists (the ingest half still needs Airflow), but its dbt half is a dbt Cloud API trigger, not a MWAA-embedded dbt run.

**Kept in Airflow with dbt Cloud handshake:**
- `dbt_loyalty_6hours` (canonical example, done 2026-07-13) — `SqlSensor` on `transaction_raw_replication_handshake_sensor.sql` + `ExternalTaskSensor` on `loyalty_bonus_fancash_incremental` gate the dbt Cloud trigger.
- 8 ingest-coupled DAGs added to scope 2026-07-19 (see [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md)): `fanapp_mdm`, `google_ad_manager`, `cassandra_extract`, `impact`, `loyalty_bonus_postgres_to_s3_ingest`, `loyalty_postgres_to_s3_ingest`, `magnite_dag`, `sfmc_optin_preferences_import`. Each gets a dedicated new dbt Cloud job.

**Deleted (22 standalone-dbt DAGs):**
- All 20 originally identified.
- `dbt_fangraph` — deleted 2026-07-13 on user correction: "no dbt models still run under MWAA". Fangraph gets its own dbt Cloud job (`--selector fangraph`), provisioned + cron-populated but `triggers.schedule=false` at main cutover; activated separately once fangraph is validated on Fusion.
- `dbt_full_refresh` — deleted 2026-07-13 on same user correction. The full-refresh workflow moves to dbt Cloud's UI "Run job with full refresh" toggle — no dedicated dbt Cloud job needed.

**Core rule:** no `dbt` command runs under MWAA post-cutover. Every dbt model in prod is built by a dbt Cloud job. `dags/dbt/`, `dags/utils/dbt.py`, and dbt-specific CI workflows (`dbt_syntax_check.yml`, `deploy_dbt_seeds_*.yml`, `push_dbt_seeds.yml`, `generate_dbt_catalog.yml`, `secure_view_dependency_check.yml`) are deleted from `fes-airflow` at cutover.

**Reverses D37** — cross-DAG `ExternalTaskSensor` on `<sibling>.log_run` was the wrong pattern. dbt Cloud handles dbt→dbt chains natively.

**Export/integration DAGs** that used to sensor on deleted DAGs' log_run tasks now have no sensor. Future gating: time-based schedule + retries, OR custom sensor polling dbt Cloud API for latest run status. Each has a `TODO(dbt-cloud-migration)` comment.

**Trade-off:** the migration is now closer to **big-bang** than YOLO — one atomic cutover PR, no wave-based rollout. YOLO's "aggressive timeline + defer non-critical polish" aspects preserved.

---

## D40 🔒 — Single cutover PR from long-lived `dbt-cloud-migration` branch, zero interim merges to main

**Restores original D1 shape** and honors D19's "clear cutover with rollback plan" framing. Supersedes D33 (waves), D36 (per-DAG parallel run split), and D38 (per-DAG ownership transfer).

**The shape:**

1. All migration work — helper, dbt Cloud job wiring, DAG rewrites, tests, `utils.dbt.py` deletion, role-hierarchy revoke SQL — accumulates on **one long-lived feature branch: `dbt-cloud-migration`** (created off `main` 2026-07-12).
2. Zero merges to `main` during the entire migration development window.
3. Continuous dev validation via `deploy_dev.yml` firing on PRs into `dbt-cloud-migration` (dev MWAA deploys from feature branches — validated pattern per PR #2249 and by D-05).
4. **Parallel-run validation happens on dev** using shadow schemas (`_SHADOW` suffix). Dev's dbt Cloud writes to `_SHADOW`, dev's MWAA writes to the base schema. `parallel_run_verify.sql` HASH_AGG diff proves equivalence across every migrated model.
5. **One cutover PR** at the end: `dbt-cloud-migration` → `main`. Includes every DAG change, helper, cleanups, ownership-transfer SQL as PR description, and rollback SQL as PR description.
6. **Rollback contract:** single `git revert` on the cutover PR restores MWAA-run dbt-core execution. Rollback SQL (reverse ownership transfer) applied via `snow sql` in the same window.

**Why (vs the wave approach in D33):**
- Waves duplicated review overhead — each wave PR needed team review, rollback SQL, parallel-run window, cross-DAG-sensor-ordering constraint. All that friction removed by testing once on dev.
- Waves left MWAA and dbt Cloud in a mixed-state for weeks per D33. That's what D40 rejects: MWAA stays as-is until the atomic cutover moment.
- Single-cutover means the coupling test (per `coupling-test-plan.md`) and the parallel-run diff both validate the *same* code that ships to prod — no drift between "wave 1 tested" and "wave 3 shipped."
- Simpler rollback surface: revert one PR + rollback SQL = restored prior state. No per-DAG unwinding.

**Why (vs original D1 big-bang):**
- Original D1 assumed cutover happens in a single weekend window with the same PR being both "build" and "cut over." D40 splits those: development happens continuously on the branch, cutover happens when everything on the branch is proven on dev.
- No calendar pressure. Branch stays green as long as needed until dev validation passes every gate.

**How to apply:**
- Branch: `dbt-cloud-migration` (created 2026-07-12, empty aside from Track 2 commits)
- All future PRs target `dbt-cloud-migration` as base, not `main`
- Every PR into the branch documents what dev testing it added or unblocked
- Cutover PR body includes: (a) rollback SQL, (b) ownership-transfer SQL as executed pre-merge, (c) list of migrated DAGs, (d) dev-validation evidence (parallel-run diff results, coupling-test results, latency profile)

**What's kept from prior decisions:**
- D34 (utils.dbt_cloud helper) — helper still needed; just lives on the branch
- D35 (one dbt Cloud job per DAG, selector = current tag) — unchanged
- ~~D37 (cross-DAG deps via ExternalTaskSensor on sibling `log_run`)~~ — SUPERSEDED by D41 on 2026-07-13. Cross-DAG dbt→dbt chains now live in dbt Cloud via `job_completion_trigger_condition`.
- D39 (steps_override for Airflow context vars) — unchanged
- D20 (ownership transfer to `SVC_DBT_CLOUD_ROLE`) — timing shifts back to "at cutover moment" (upfront-relative-to-merge) for ALL tables at once
- D21 (role-hierarchy safety net) — still applied at cutover moment; revoked in a follow-up PR post-cutover

**Trade-off:**
- Long-lived branch means periodic rebasing against main to absorb concurrent DAG changes from other engineers. Manageable — the fes-airflow rate of change is not extreme.
- Reviewer of the final cutover PR sees a large diff. Mitigated by: (a) PR body documents each subsystem separately, (b) the underlying commits are already reviewable individually via GitHub's commit view, (c) dev-validation evidence stands in for reviewer's need to reason through correctness from first principles.

---

## D42 🔒 — Second dbt Cloud project for fes_users via one-way dbt Mesh (pre-cutover)

Split `models/fes_users/` (~128 models across 10 analyst subfolders) out of `dbt-fes-ae` into a NEW dbt Cloud project pointing at the existing (currently empty) `fanatics-gaming/dbt-fes-analytics` repo. Both projects share the same `SVC_DBT_CLOUD_ROLE` service role, same Snowflake account, same warehouse routing.

**Naming (locked):**
- Existing AE project: dbt project `name: fes_data` (per D32).
- New Analytics project: dbt project `name: fes_analytics` (must differ for Mesh to distinguish projects).
- Cross-project ref syntax from downstream: `{{ ref('fes_data', 'model_name') }}`.

**Direction: one-way, downstream-declares-upstream.**
- `dbt-fes-analytics` gets a `dependencies.yml` at repo root:
  ```yaml
  projects:
    - name: fes_data
  ```
- `dbt-fes-ae` does NOT declare `fes_analytics` as a dep. Substep §1 (executed 2026-07-19) found **10 hits across 6 fes_users models being ref'd by AE-side code** (all in `fangraph/ltv_processed/`, `fanapp/installs/`, and `fde_imprint/`). Analysis: all 6 are functionally AE-owned infrastructure sitting in analyst folders — they drifted into `fes_users/` organically. Transitive closure pulls in 6 more upstreams via intra-fes_users refs (`fanapp_install_identity_map`, `fanapp_potential_fraud`, `fraudulent_ips`, `hashed_email_ftu`, `dim_appsflyer_campaign_mapping`, `dim_appsflyer_creative_mapping`), for a **must-stay set of 12 fes_users models**.

- **Decision (2026-07-19): leave-in-place variant.** The 12 residuals stay in `dbt-fes-ae/models/fes_users/` untouched (same schemas `FES_USERS.<ANALYST>`, same config). Only the other 116 fes_users models move to `dbt-fes-analytics`. AE keeps a smaller `dbt_users` job that now builds just the 12 residuals under `tag:users`. **Post-cutover cleanup (deferred §1a)**: hoist the 12 to AE-native domains (e.g. `models/fangraph/ltv_processed/`, `models/fanapp/installs/`) — this becomes an AE-internal PR with schema/database config changes, but is no longer on the cutover critical path.
- **Why leave-in-place beats pre-cutover hoist**: zero data-shape changes at cutover, no AE-owner coordination needed on target directories during a 4-day window, trivial rollback (just revert the analytics-side PR — AE is untouched). Cost accepted: AE keeps a `dbt_users` job (12 models) and `models/fes_users/` residue in AE across 5 subfolders until post-cutover hoist. Total dbt Cloud prod jobs go from 22 to 23 (AE 22 + analytics 1).
- **One-way Mesh preserved.** The 12 residuals' upstreams are all AE-side (either non-fes_users AE models or other residuals in the same closure). Analytics → AE cross-project refs = 78 known hits across 37 files (per §1 analysis); AE → analytics cross-project refs = 0. Two-way Mesh rejected.
- **Job naming.** Analytics-side job named `analytics_users` (NOT `dbt_users`) to avoid collision with AE's retained `dbt_users` job. Cron `35 13 * * *` (5-min offset from AE's `30 13 * * *`) so analytics compilations see today's build of the 12 residuals rather than yesterday's. `job_completion_trigger_condition` coupling deferred as post-cutover polish.
- **All AE models get `access: public` from day one** (posture confirmed 2026-07-19). Implemented via folder-level default in `dbt-fes-ae/dbt_project.yml` under `models.fes_data: +access: public + +group: analytics_engineering`. Rationale: enumerating the exact ref surface adds work without materially reducing risk — the repo/group boundary is the meaningful ownership control, not per-model access. Per-model `config.access: protected` overrides are available as a fall-forward if a specific AE model later needs to be hidden (e.g. PII-sensitive intermediates).
- Downstream analytics models can stay `protected` (default) — nothing outside the analytics project needs them.

**Manifest freshness (local Fusion + Cloud jobs):** authenticated Fusion resolves cross-project refs via dbt Cloud's metadata service on every `dbt parse`/`compile`/`build` invocation — no user-visible cache, no manual pull, no scheduled sync. Environment-scoped: analytics's `--target prod` reads from AE's prod manifest, `dev` from AE's dev manifest. Freshness depends entirely on AE's most-recent successful job run in the matching environment. Full write-up in [`local-development.md`](local-development.md) → "Manifest freshness."

**Day-1 developer workflow: dbt Cloud IDE only. Local editor is a post-cutover follow-up (learning 2026-07-19).** Repo recon of fanatics-gaming shows 10 FBG dbt Mesh projects already in production (9 siblings + `dbt_analytics_engineering` hub); pattern is uniform (dependencies.yml, `+access: public` default, two-argument `ref('dbt_project', 'model')`). Local dev standard across siblings is **dbt-core CLI** (not Fusion CLI) — dbt-finance's README is canonical. No FBG team runs Fusion CLI locally today. For our cutover, the safest posture is:
- Day 1: fes_users analysts use the dbt Cloud IDE (matches AE team; see Confluence [How to Use dbt Cloud](https://betfanatics.atlassian.net/wiki/spaces/DATA/pages/3099689383)).
- Post-cutover: adopt dbt-finance-style local dbt-core CLI as an option for analysts who want local editing. Cross-project ref resolution in local parse is an open sub-question — likely a stub-generation pattern per analytics-engineering's `scripts/`, verify before rolling out.
- Explicitly NOT: local Fusion CLI. Would be first-at-FBG; no team currently does this. Fusion Stable release track (what our dbt Cloud projects run on) is unrelated to the local Fusion CLI question.

**Why now (pre-cutover):**
- Repo ownership boundary belongs at the repo layer, not just at a subdirectory in dbt-fes-ae. Deferring to post-cutover means running a second migration on stabilizing prod — higher risk than doing it once, upfront.
- Both projects share the same service role, so ownership transfer (`cutover_ownership_transfer.sql`) is unchanged — the split adds no Snowflake-side complexity.

**Reverses/extends prior decisions:**
- **D2** (Mesh deferred to post-cutover gradual extraction) → partially reversed. Mesh setup happens NOW at repo/project layer. Model contracts + tighter Mesh discipline still deferred to post-cutover.
- **D3** (two empty repos, migrate models into new repos with quality curation) → partially fulfilled. dbt-fes-analytics was one of the two "empty new repos"; fes_users migration IS the analytics-side migration.
- **D23** (defer Mesh split until Q4) → **superseded by D42.** The Q4 gate was on Mesh cost/benefit — user directive 2026-07-18 makes the split a repo-ownership imperative that outweighs the Q4-planning gate.
- **D32** (dbt project `name: fes_data` stays) — reaffirmed. AE keeps `fes_data`; analytics gets `fes_analytics`. No rename to `fes_ae`.
- **D41** (delete dbt DAGs without ingest/export coupling) — unchanged. `dbt_users.py` still deleted from fes-airflow. Analytics-project `dbt_users` job runs on dbt Cloud cron `30 13 * * *`, no Airflow interaction.

**Timeline & fallback:**
- Target: complete pre-cutover (2026-07-23). Decision gate EOD 2026-07-22 based on Phase 3 dev validation evidence.
- **Fallback Option B**: if not clean by 2026-07-22, defer split to post-cutover. Cutover proceeds with fes_users still in dbt-fes-ae + AE `dbt_users` job running as-is. Split becomes a post-cutover follow-up.

**How to apply:** Full substep list in [`analytics-project-split.md`](analytics-project-split.md). 24 substeps across 6 phases (verify, scaffold, provision, validate, delete-from-AE, cutover-coordination).

**Ownership-transfer script implications:** ZERO. `sql/cutover_ownership_transfer.sql` filters by `owner = 'SVC_MWAA_ROLE'` and targets `FES_USERS` already; both projects use `SVC_DBT_CLOUD_ROLE` as target. Dry-run count (1347) unchanged.

**Rollback implications:**
- Analytics split is independently rollback-able (delete new project + revert AE PR that removed fes_users) — orthogonal to main cutover rollback.
- If main cutover rolls back post-T0, analytics project continues running against Fusion (no dependency on AE cutover state).

**Coupling test implications:** ZERO. Analytics project has no Airflow interaction — coupling tests (H1/F1) still cover only `dbt_loyalty_6hours` in dbt-fes-ae.

---

## Change log

- 2026-07-10 — Doc created. D19–D24 added as addendum to `decisions.md`.
- 2026-07-11 — D25–D31 added during smoke-test setup.
- 2026-07-11 — D32 added during Fusion parse-check import.
- 2026-07-12 — D33–D39 added alongside `cutover-playbook.md` drafting. D33 (waves within prod), D34 (utils.dbt_cloud helper), D35 (1 job per DAG), D36 (per-DAG parallel run), D37 (cross-DAG deps via ExternalTaskSensor on log_run), D38 (per-DAG ownership transfer), D39 (steps_override for Airflow context).
- 2026-07-12 — D40 added; D33, D36, D38 marked SUPERSEDED. Engineer clarified single-cutover-PR approach (matches D1/D19 intent). All migration work consolidates onto `dbt-cloud-migration` long-lived branch; zero merges to main until final cutover PR.
- 2026-07-18 — D42 added. Second dbt Cloud project for `fes_users` via one-way dbt Mesh, pre-cutover. Reverses D23 (defer Mesh); partially reverses D2 (Mesh at cutover, not post-cutover). Full plan in `analytics-project-split.md`.
- 2026-07-19 — D42 refined. Substep §1 executed: found 10 AE→fes_users hits across 6 models; transitive closure = 12 models. Added substep §1a to hoist them back to AE before the split. One-way Mesh direction preserved; scope not expanded to two-way.
- 2026-07-19 — D42 refined again after user pushback on pre-cutover hoist cost. **Adopted leave-in-place variant**: 12 residuals stay in AE `models/fes_users/` untouched, 116 move to analytics. AE `dbt_users` job retained (builds the 12); analytics adds `analytics_users` job (builds the 116). §1a deferred to post-cutover cleanup. Total prod jobs 22 → 23. Rationale: zero data-shape changes in the 4-day cutover window; trivial rollback; deferred cleanup is architecturally straightforward.
- 2026-07-19 — D41 amended after user identified missed scope. Audit found **8 ingest-coupled DAGs still using MWAA-embedded `dbt.create_dbt_dag(...)` calls**: `fanapp_mdm`, `google_ad_manager`, `cassandra_extract`, `impact`, `loyalty_bonus_postgres_to_s3_ingest`, `loyalty_postgres_to_s3_ingest`, `magnite_dag`, `sfmc_optin_preferences_import`. Original D41 enumeration listed only the 22 standalone `dbt_*.py` DAGs; the ingest-DAG class fell through the audit. D41's core rule ("no `dbt` command runs under MWAA post-cutover") always covered this — the miss was in the migration checklist, not the architecture. Full remediation plan in [`dbt-in-airflow-removal.md`](dbt-in-airflow-removal.md) — 5 phases, 8 new dbt Cloud jobs, `dags/dbt/` + `dags/utils/dbt.py` deletion, mermaid diagram update as final substep. **This is the most critical pre-cutover step; if it doesn't complete cleanly by 2026-07-22, cutover date moves.**

