# Progress Log

Chronological log of work done. Add entries as sessions complete. Include date, session
summary, and files touched.

---

## 2026-07-22 — Kickoff & scoping

**Session**: Initial framing + full audit + design lock.

**Done**:
- Audited every `dbt-*` / `dbt_*` repo in `fanatics-gaming` for `var("<airflow-name>")`
  references. Confirmed hits documented in `findings.md`.
- Inventoried `dbt_project.yml` placeholder defaults across all dbt repos.
- Confirmed blast radius: 5 raw bronze models + ~47 event bronzes frozen downstream +
  1 mention_me model + 1 dbt-governance DQ check.
- Designed the self-healing high-water-mark window macro (see `fix-design.md`).
- Locked two open questions with the user:
  - **D2**: Hard cutover on legacy var names.
  - **D3**: Bootstrap seed = `'2024-01-01T00:00:00'`.
- Created this project workspace under `projects/airflow-vars-in-dbt-cutover/`.

**Files touched**:
- Created `projects/airflow-vars-in-dbt-cutover/` (7 `.md` files).

**Next**:
- Kick off pre-flight audits (dbt Cloud job configs + external orchestration callers).
- Then start PR 1 (dbt-fes-ae).

---

## 2026-07-22 (continued) — Per-model verification of Option 2

**Session**: Walked through each of the 7 problematic models to confirm the target-table
high-water-mark fix works as-designed.

**Two design tweaks came out of it**:

1. **Fanflow default `safety_lookback_minutes` = 120** (not 15). Preserves the
   current 2-hour tolerance for out-of-order S3 arrivals. Applied to `fix-design.md`
   §Fix 1.
2. **`bets_total_stake_validity_check` is `materialized: view`** — my initial
   `run_started_at` draft would have baked a compile-time literal into the view SQL
   and frozen it. Corrected fix: `CURRENT_DATE - 1` (Snowflake evaluates at query
   time). Recorded as **D7**; `fix-design.md` §Fix 4 updated.

**Other findings recorded in `per-model-verification.md`**:
- All 5 fanflow raw bronzes carry `full_refresh_prevention()` — gap-fill after PR 1
  must go via `--vars '{window_start_ts: ...}'`, not `--full-refresh`.
- `mention_me__referrals` — no changes to the drafted fix; QUALIFY + `unique_key`
  handle cross-file dedup correctly; ext-table pre-hook auto-refreshes the S3
  metadata catalog before each run.
- ~47 event bronzes are frozen by consequence only — no code change needed; they
  self-recover once raw bronzes advance.

**Also**: workspace was relocated under `projects/dbt_cloud_migration/airflow-vars-cutover/`
per the user's guidance (rather than a standalone project folder). Parent
`dbt_cloud_migration/README.md` TOC updated; `_index.md` and `findings.md`
cross-reference the pre-existing `../data-interval-usage.md` (D39 migration-time
enumeration).

**Files touched**:
- Created `per-model-verification.md`.
- Edited `fix-design.md` (Fix 1 default + Fix 4 rewrite).
- Edited `_index.md` (added new file to TOC + parent-project cross-references).
- Edited `decisions.md` (added D7).
- Edited `../README.md` (added TOC row for this subfolder).
- Edited `findings.md` (cross-reference note to `../data-interval-usage.md`).

**Next**:
- Pre-flight audits still queued (tasks #5, #6).
- Then PR 1.

---

## 2026-07-23 — PR 22 merged; wave-2 diagnostic run

**Session**: PR 22 merged. Then ran a broader diagnostic across the ~30 other
models in dbt-fes-ae that reference `var("data_interval_*")` / `var("ds_nodash")`.
Queried prod Snowflake via `dbt show --inline` to check MAX(affected column) per model.

**Full findings recorded in [`wave-2-diagnostic.md`](wave-2-diagnostic.md)**. Three
distinct problems, none the same as the fanflow incident:

1. **xp_push_last_opened + xp_optin_preferences (4 models) frozen at 2026-06-09** —
   ~6+ weeks stale. Highest-impact hidden incident.
2. **13 loyalty metric models frozen at 2026-07-21 14:00** — ~2 days stale. Coincides
   with cutover but historical rows have real dates → orchestration issue, not code.
3. **gl_new_to_x_registration_events never materialized** — table doesn't exist in prod.

Wave 2 is 90% ops (paused/broken orchestration) not code. Removing `var()` references
wouldn't fix Problems 1 + 2; only Problem 3 might benefit from code work.

**Also confirmed via dbt Cloud API + Airflow DAG audit**:
- Most dbt Cloud jobs (scheduled and Airflow-triggered) do NOT pass `--vars` at all;
  they rely on placeholder defaults in `dbt_project.yml`. Only 3 DAGs use
  `steps_override`, and none have fired in the last 50 runs.
- The `dbt_fanflow` PROD job was scheduled at cron=True but had 4 errors in a row
  before PR 22.
- No prod env vars override `data_interval_*` (verified via env-vars API).

**Tasks reshuffled**: closed #5, #6, #10 (subsumed by this diagnostic). New tasks
#11/#12/#13 for wave-2 investigations.

**Files touched**:
- Created `wave-2-diagnostic.md`.
- Updated `_index.md` TOC.
- This progress entry.

---

## 2026-07-23 (continued) — PR 23 opened: dynamic placeholder vars

**Session**: Low-hanging fruit dbt-only fix ahead of the fes-airflow orchestration
work. User asked for immediate dbt-model-side fix while deferring airflow fixes.

**PR**: https://github.com/fanatics-gaming/dbt-fes-ae/pull/23 (draft)
**Branch**: `fix/dynamic-placeholder-vars-clean`
**Commit**: `865b8ba`

**Change**: `dbt_project.yml` only — swap static `'2023-01-01T00:00:00...'` /
`'2023-01-02T00:00:00...'` / `'20250925'` placeholders for Jinja expressions
that evaluate at dbt project parse time (every dbt invocation):

```yaml
data_interval_start: "{{ modules.datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:00:00') }}"
data_interval_end:   "{{ modules.datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:00:00') }}"
ds_nodash:           "{{ modules.datetime.datetime.utcnow().strftime('%Y%m%d') }}"
```

**Hourly rounding is deliberate**: preserves PK / `unique_key` stability in Pattern C
snapshot models that hash on `data_interval_end` — multiple runs within the same
hour produce identical PKs, so MERGE updates existing rows rather than exploding
the table.

**Discovery driving this PR** (added to `wave-2-diagnostic.md` as Problem 4): user
noticed that `xtremepush_tier_change_events.py` docstring described an
ExternalTaskSensor + dbt build that don't exist in the actual code. Investigation
found the end-to-end pipeline is broken:

1. `dbt_fanatics_one` scheduled cron every 30 min, no `--vars` → stamps
   `tier_changes_all.update_ts` and `tier_points_marketing_triggers.update_ts`
   with the placeholder `'2023-01-02T00:00:00'`.
2. `xtremepush_tier_change_events` DAG queries
   `WHERE mt.update_ts = '{{ params.data_interval_end }}'` (Airflow's real time)
   → matches ZERO rows.
3. Real tier changes are silently NOT reaching XtremePush.

Confirmed corruption: 79,210 rows in `tier_points_marketing_triggers` and 359 in
`tier_changes_all` stamped `2023-01-02`, growing every 30 min.

**What PR 23 fixes**: stops the placeholder bleed forward — all future rows get
hour-rounded "today" timestamps.

**What PR 23 does NOT fix** (deferred to Wave 2 airflow work):
- XP DAG coordination — dbt-side and airflow-side timestamps still don't match
  exactly, so the exact-match filter still fails. Needs either restoring
  Airflow-triggered `steps_override` OR changing the DAG's filter semantic.
- 79,210 + 359 bad rows already in prod — need targeted cleanup (DELETE +
  `--full-refresh`, or UPDATE from `transaction_timestamp`).
- Frozen orchestration for Problems 1, 2 — DAGs/jobs that stopped firing.

**Files touched**:
- `dbt-fes-ae/dbt_project.yml` (one file, 6 lines changed).
- `progress.md` — this entry.
- Tasks: closed 5/6/10 as subsumed; added #11–#14 for wave-2 issues; #15
  tracks PR 23 draft status.

---

## 2026-07-23 (continued) — Withdrew PR 23; opened PR 24 (Pattern E proper fix)

**Session**: User pushed back on PR 23 (correctly): the placeholder-only fix
leaves the underlying `var("data_interval_*")` dependency in place in every
model, and setting start == end is semantically incoherent. Real fix is
per-model rewrites like fanflow.

**Actions**:
- **Closed PR 23** with a comment explaining why (placeholder-only bandaid,
  start=end semantically wrong, real fix is per-model rewrites).
- **Opened PR 24** for Pattern E (highest customer-facing impact — the two
  Fanatics One models feeding the broken XP tier-change pipeline).

**PR 24**: https://github.com/fanatics-gaming/dbt-fes-ae/pull/24 (draft)
**Branch**: `fix/pattern-e-run-started-at`
**Commit**: `8ec93f9`

**Change**: 2 files, 2 lines. In both `tier_changes_all.sql` and
`tier_points_marketing_triggers.sql`:

```diff
-    '{{ var("data_interval_end") }}'::timestamp_ntz AS update_ts
+    '{{ run_started_at.strftime("%Y-%m-%d %H:%M:%S") }}'::timestamp_ntz AS update_ts
```

**Semantics**: `update_ts` now captures when the dbt run inserted the row.
Same-batch rows share a timestamp; across batches, timestamps advance
naturally. Anti-join incremental keeps existing rows unchanged — only new
rows get fresh `run_started_at`.

**What PR 24 fixes**:
- Stops the 2023-01-02 corruption bleed on the two Fanatics One tables.
- Removes the model's dependency on external `--vars` injection entirely
  (fanflow-style).

**What PR 24 does NOT fix** (coordinated follow-ups):
1. `xtremepush_tier_change_events.py` DAG filter — needs to change from
   exact-match on `data_interval_end` to a range on `update_ts`. Fes-airflow
   PR to follow.
2. Cleanup of the 79,210 + 359 existing bad rows — needs DELETE +
   `--full-refresh` OR targeted UPDATE from `transaction_timestamp`.

**Remaining wave-2 patterns still to fix** (following the same
per-model-rewrite approach):
- Pattern A: 13 loyalty metric models (`snapshot_ts` → `run_started_at`).
- Pattern C: 6 xtremepush snapshots + deltas (deferred until orchestration
  investigation determines whether push/optin freeze is code or ops).
- Pattern B: ~5 date-window filters (target-table high-water or
  run_started_at-with-lookback).
- Pattern F: metric_threshold_check test macro (target-table high-water).

**Files touched**:
- `dbt-fes-ae/models/loyalty/fanatics_one/tier_changes_all.sql`
- `dbt-fes-ae/models/loyalty/fanatics_one/tier_points_marketing_triggers.sql`
- Tasks: #15 deleted (PR 23 closed), #16 completed (PR 24 opened).
- This progress entry.

---

## 2026-07-23 (continued) — PR 24 expanded: full Wave 2 dbt sweep (30 files)

**Session**: User asked to think LOGICALLY per model (not just mechanical
`run_started_at` substitution) and bundle everything into one PR. Right call.

**Approach — one logical answer per pattern**:

| Pattern | Logical answer | Why |
|---|---|---|
| A snapshot_ts (13) | `CURRENT_TIMESTAMP()::TIMESTAMP` | "When this snapshot was taken." Simpler than `run_started_at`. |
| B date filters (8) | `CURRENT_TIMESTAMP() - INTERVAL 'N DAY'` | "Last N days rolling window." |
| C xtremepush (6) | `CURRENT_DATE` (unquoted for PK hash), `CURRENT_TIMESTAMP()` for stamps | Preserves "one row per user per day" — CURRENT_DATE in HASH gives stable-per-day PK. |
| E fanatics_one (2) | `CURRENT_TIMESTAMP()::TIMESTAMP_NTZ` | "When this row was inserted." Changed from `run_started_at` (PR 24 initial) for consistency. |
| F test macro (1) | `(SELECT MAX(snapshot_ts_col) FROM {{ model }})` | Target-table high-water — test the latest snapshot. |
| D ledger.yaml (4 hits) | **DEFERRED** | `loyalty_insert_row_count` wraps arg in `'...'::TIMESTAMP_NTZ`, incompatible with bare `CURRENT_TIMESTAMP()`. Monitoring-only, no customer impact. Separate PR needed to refactor the macro. |

**Commit**: `4adf187` — 30 files changed, 52 insertions, 52 deletions.

**PR 24 updated**: https://github.com/fanatics-gaming/dbt-fes-ae/pull/24
- Title: "Wave 2: remove var(data_interval_*) from 30 dbt files (Patterns A/B/C/E/F)"
- Body rewritten to cover all patterns + deferred Pattern D + still-required follow-ups.

**Verified**:
- `dbt parse` clean.
- `dbt compile -s <representative model each pattern> --target dev` clean.
- `grep -rn 'var("data_interval\|var('data_interval\|var("ds_nodash' models/ macros/ tests/` — only the 4 deferred `ledger.yaml` entries remain.

**Still-required follow-ups** (not in this PR):
1. fes-airflow `xtremepush_tier_change_events.py` DAG filter fix (exact-match → range) — restores XP tier-change delivery after PR 24 merges.
2. Cleanup of the 79,210 + 359 existing `'2023-01-02'` rows in tier_points_marketing_triggers + tier_changes_all.
3. Orchestration investigation for the 6-week-stale xtremepush push/optin models.
4. Pattern D macro refactor (`loyalty_insert_row_count` post-hook).

---

## 2026-07-23 (continued) — Adversarial review + surgical fixes

**Session**: Launched 5 parallel background subagents to adversarially review
PR 24 by pattern. All 5 completed. Applied surgical fixes for confirmed issues;
reverted Pattern C entirely (too many correctness blockers).

**Review outputs** written to `reviews/pattern-{a,b,c,e,f}.md`.

### Fixes applied (commit `2ecf4fe`)

- **Pattern A DATE_TRUNC fix** (13 files): `CURRENT_TIMESTAMP()::TIMESTAMP` →
  `DATE_TRUNC('DAY', CURRENT_TIMESTAMP())::TIMESTAMP`. Preserves retry
  idempotency. Verified in dev: 148 → 149 rows on first run, stayed at 149
  on second same-day run. ✓
- **Pattern B loyalty_private_fan_id_map**: target-table high-water (matches
  martech_private_fan_id_map fix from earlier). Self-heals across missed
  runs; not limited by 1-day lookback.
- **Pattern B redeem_matching quad** (4 files): shared `run_started_at`
  anchor. Restores family-level alignment previously provided by shared
  `data_interval_end`. Verified: all 4 render `'2026-07-23 05:13:47'`
  on same compile.
- **martech_private_fan_id_map**: target-table high-water (previously committed
  as `59177f3`).
- **Pattern E, Pattern F**: unchanged — reviewers verified safe.
- **Session TZ verified UTC** → no `CONVERT_TIMEZONE` wrapper needed anywhere.

### Reverted (commit `2ecf4fe`)

- **Pattern C — all 6 xtremepush files** back to main. Reviewer surfaced 3
  blockers:
  1. **CRITICAL**: `xp_user_attributes_snapshot` `schema.yml` post_hook still
     uses `var()` — would cause ~125M rows/day unbounded growth if
     snapshot_date became dynamic. Missed by initial sweep.
  2. **HIGH**: delta models are `incremental append` with no `unique_key` —
     old placeholder's identical `insert_ts` gave natural dedup; new
     `CURRENT_TIMESTAMP()` doesn't → same-day re-run appends duplicates.
  3. **HIGH**: delta model emits full 12B-row change set when
     `previous_obj` is empty (weekend gap, first run).
  `xp_user_attributes` pair is currently getting real values via unknown
  mechanism — need to understand actual data flow before touching.

### PR 24 title + body updated

Title: "Wave 2: remove var(data_interval_*) — Patterns A/B/E/F (Pattern C deferred)"

Body: acknowledges SFMC pipeline also broken (not just XP), corrects the
downstream-fix suggestion (half-open range, not `>= now - 1h` which would
double-deliver), notes UTC session-TZ verified, cites reviewer findings.

**Still deferred**:
- fes-airflow DAG fixes (XP + SFMC)
- Cleanup of 79,210 + 359 corrupted rows (targeted UPDATE, not
  `--full-refresh`)
- Pattern C proper investigation
- Pattern D macro refactor

---

## 2026-07-23 (continued) — PIVOT to Airflow-trigger strategy

**Session**: User pushed back on PR 24 approach — even after surgical fixes
from the review, we're modifying too many models in an active incident with
unknown downstream impact. Proposed alternative: revert to pre-migration
"Airflow drives dbt" pattern as a bridge state, decouple per-model over
time with proper testing.

**Decision**: Adopted. Plan captured in
[`airflow-trigger-strategy.md`](airflow-trigger-strategy.md).

**Key confirmations before pivot**:
- `dbt_loyalty` has an active `job_completion_trigger_condition` on
  `dbt_fanflow` completion (dbt Cloud-native chain). No `--vars` pass
  through. `tag:loyalty` includes 5+ models using `var("data_interval_end")`.
  Chain must be removed, `dbt_loyalty` needs Airflow-trigger with vars.
- PR 22 (fanflow + mention_me) stays — different failure mode, no
  downstream coordination trap, actively fixing prod. Reverting would
  re-break the P1 incident.
- Snowflake session TZ confirmed UTC — no timezone-wrapping needed anywhere.

**Next actions** (per new plan):
1. Close PR 24 in dbt-fes-ae (with a comment linking to this plan)
2. Draft fes-airflow PR — extend `create_dbt_cloud_task_group` utility to
   auto-inject `data_interval_*` / `ds_nodash` vars; add new DAGs for the
   dbt Cloud jobs that currently only run on internal cron
3. Coordinated cutover: remove dbt Cloud chain, pause dbt Cloud schedules

Reviewer artifacts (still valuable as reference for future decoupling PRs)
at `reviews/pattern-{a,b,c,e,f}.md`.

---

## 2026-07-22 (continued) — Scope tightened

**Session**: User pushed back on scope. PR 1 refocused, PR 2 and PR 3 dropped.

**Removed from PR 1**:
- `.github/workflows/lint-airflow-vars.yml` (CI grep guard) — prevention, not fixing.
- Long "don't add Airflow-context vars here" comment in `dbt_project.yml` — shortened
  to a one-liner about `fanflow_bootstrap_ts`.

**Dropped entirely** (see decision **D8**):
- **dbt-governance PR** — that model's view + `CURRENT_TIMESTAMP` string default
  already gives correct behavior under dbt Cloud; not an incident, and different
  team's repo.
- **dbt-fes-analytics dead-code cleanup PR** — the duplicate fanflow macros there
  are unused; removing them is optional hygiene, not incident-fixing.

**Files touched**:
- `plan.md` — collapsed to single-PR plan.
- `decisions.md` — revised D6 (CI guard deferred), added D8 (scope reduction).
- `progress.md` — this entry.

**Followup commit on PR 22**: `c18bcf5` "Tighten scope: drop CI grep guard from this PR."

---

## 2026-07-22 (continued) — PR 1 opened as draft

**Session**: Drafted and pushed PR 1 for dbt-fes-ae.

**PR**: https://github.com/fanatics-gaming/dbt-fes-ae/pull/22 (draft)
**Branch**: `fix/airflow-vars-cutover`
**Commit**: `5b87917`

**Six files changed** (verified via `dbt parse` clean + `dbt compile -s fes_enriched
referrals` clean, rendered SQL inspected):
- `macros/fanflow/fanflow_unparsed_files.sql` — full rewrite
- `macros/fanflow/fanflow_ingest_topic.sql` — signature simplified
- `macros/fanflow/fanflow_test_unparsed_files.sql` — full rewrite
- `models/fes_integrations/mentionme/referrals.sql` — high-water on source_file_name
- `dbt_project.yml` — remove 3 placeholder vars, add fanflow_bootstrap_ts
- `.github/workflows/lint-airflow-vars.yml` — NEW, PR-time grep guard

**Open items before ready-for-review**:
- Task #5: dbt Cloud job-config audit (hard-cutover precondition).
- Task #6: mitigation session alignment on target-table watermarks.
- PR 2 (dbt-governance) and PR 3 (dbt-fes-analytics) — independent, no merge order
  dependency, safe to draft in parallel.

**Files touched (in Brock workspace)**: this progress log.
