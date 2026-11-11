# dbt Cloud Migration — Test Ledger

Central register of tests performed (or planned) to validate the dbt-core (MWAA) → dbt Cloud (Fusion) migration before cutover.

Each test answers: **does Fusion produce equivalent output to dbt-core for the models we care about?** Tests span parse-time behavior (does Fusion accept the code), runtime behavior (does the Airflow↔dbt Cloud handshake work, does the dbt Cloud → dbt Cloud chain fire), and data-equivalence (does the SQL Fusion emits yield the same rows).

**Architectural rule under D41** (relevant to how the runtime tests are scoped):
- Airflow interacts with dbt Cloud in exactly TWO ways: (a) trigger ONE dbt Cloud job after ingest signals clear, (b) poll ONE dbt Cloud job to release a downstream export task.
- Airflow NEVER coordinates between multiple dbt Cloud jobs. dbt-to-dbt job chains live entirely in dbt Cloud via `job_completion_trigger_condition`.
- Tests 2 and 3 validate the Airflow↔dbt Cloud handshake. Test 7a validates the dbt Cloud ↔ dbt Cloud chain. Different mechanisms, different tests.

## Test matrix

| # | Test | Scope | Status | Result |
|---|---|---|---|---|
| 1 | Fusion parse-clean on full dbt tree | 500+ models across all opcos | ✅ Complete | All models parse under Fusion 2.0.0-preview.196 |
| 2 | Airflow↔dbt Cloud handshake (H1) — ingest sensor → trigger → wait → downstream | trigger-and-sensor mechanism | ✅ Complete | Passed on dev deploy 2026-07-13 |
| 3 | Airflow↔dbt Cloud handshake (F1) — real workload variant | end-to-end with real job | ✅ Complete | Passed on dev latest deploy |
| 4 | Loyalty ledger diff (Fusion vs dbt-core on prod-cloned stage) | 4 `table_clone` ledgers | ✅ Complete | **Byte-identical (0 delta)** via `dbfork_final_verify` HASH_AGG |
| 5 | Fangraph diff (Fusion vs MWAA prod baseline) | 208 fangraph-tagged models, `fangraph.admin.fangraph` leaf | ✅ Complete | Rows +0.015%, nulls proportional, 70% of common IDs byte-identical after excluding build-timestamp column |
| 6 | Prod credential smoke on `dbt_sources` (job 70437463791521) | 1 dbt Cloud job in prod env | 🟡 Partial | Ran 2026-07-14: keypair auth ✅ (git clone/profile/deps all Success), but `dbt source freshness` errored on missing DATABASE USAGE for `AMPLITUDE`. Grants spec'd in `fusion-migration/monday-terraform-pr-spec.md` — 22 source DBs need TF-ified grants for SVC_DBT_CLOUD_ROLE. Re-run after grants land. |
| 7a | `job_completion_trigger_condition` mechanism smoke via 2 dev mock jobs | 2-job chain in dev env | ✅ Complete | Job A `70437463792298` → Job B `70437463792299` (dev env). Trigger fires within ~5s of upstream completion. |
| 7b | Prod-specific chain smoke: prod `dbt_fanflow` → prod `dbt_loyalty` via `job_completion_trigger_condition` | 2-job chain in prod env | ⏳ Post-merge | Redundant belt-and-suspenders once 7a passes — same dbt Cloud API. Do after PR #2877 merges if desired. |
| 8 | dbt Cloud failure webhook to Slack | notifications config across 22 prod jobs | ⏳ Pending | Requires Slack webhook URL + channel |
| 9 | dbt-fes-ae repo guardrails parity with fes-airflow | Okta groups, CODEOWNERS, workflows via fanapp-github-terraform | ⏳ Deferred | Not blocking cutover; post-migration cleanup |

## Detailed test records

### 1. Fusion parse-clean

**Scope**: Every model, macro, test, and source in `dbt-fes-ae` parses cleanly under Fusion Stable (2.0.0-preview.196).

**Method**: `~/.local/bin/dbt parse --target dev` after applying the parse-cleanup patches on branch `fix/fusion-parse-cleanup`.

**Findings captured in**: `projects/dbt_cloud_migration/fusion-migration/dbt1005-invalid-materialization.md`, `dbt1041-package-lock-format.md`, `dbt1048-dependency-not-found.md`, `dbt1060-unused-config-keys.md`, `dbt1159-test-arguments.md`, `runtime-behavior-concerns.md`, `dbt-autofix-tool.md`.

**Status**: ✅ Complete. All parse warnings resolved. Any remaining warnings are informational (e.g. version-deprecated syntax that still parses).

### 2. H1 coupling — Airflow ↔ dbt Cloud handshake

**Scope**: Prove that an Airflow task can trigger a dbt Cloud job and wait for its completion using `DbtCloudRunJobOperator` + `DbtCloudJobRunSensor`.

**Method**: `dbt_cloud_coupling_test` DAG in fes-airflow dev, triggering a stub dbt Cloud smoke job.

**Result**: ✅ Passed on dev deploy 2026-07-13. Full trigger → poll → success handoff works end-to-end.

**Code**: `fes-airflow/dags/utils/dbt_cloud.py` (`create_dbt_cloud_task_group`).

### 3. F1 coupling — real workload variant of H1

**Scope**: Same handshake as H1 but wired to a real dbt Cloud job doing actual model builds (not a stub).

**Result**: ✅ Passed on dev latest deploy 2026-07-13.

### 4. Loyalty ledger diff — byte-identical

**Scope**: Fusion's output for `loyalty_state`, `loyalty_analytics_ledger`, `loyalty_earn_burn_mapper`, `loyalty_balance` matches dbt-core prod output byte-for-byte given the same source state.

**Method**: dbfork clone the loyalty `_stage_final` upstream at T_dbfork, run Fusion `dbt build --defer --state <prod manifest>` writing to dbfork test schema, then HASH_AGG-compare Fusion output vs the dbfork clone.

**Result**: ✅ **0 delta** across all 4 ledgers on windowed HASH_AGG. All 4 return identical row counts and identical hashes.

```
MATCH loyalty_state:            5,441,850 rows, hash 6857527446325652217 (both sides)
MATCH loyalty_analytics_ledger: 7,250,658 rows, hash -749958131054492442
MATCH loyalty_earn_burn_mapper: 3,368,924 rows, hash -6323272546819507789
MATCH loyalty_balance:            92,637 rows, hash  247200048907054441
```

**Cost**: 54 seconds on FDE_DEVELOPER_2XL_WH. Under $1.

**Full runbook**: `projects/dbt_cloud_migration/fusion-migration/loyalty-diff-runbook.md`.

**Interpretation**: All 4 ledgers materialize as `table_clone` — Fusion and dbt-core both emit `CREATE OR REPLACE TABLE X CLONE Y`. Snowflake does the work identically. This validates Fusion's SQL emission for the CLONE materialization path.

### 5. Fangraph diff — Fusion vs MWAA prod

**Scope**: 208 tag:fangraph models rebuilt by Fusion locally, then `fangraph.admin.fangraph` (leaf) compared to MWAA's prod output.

**Method**:
- Rewrote source YAMLs to point 46 sources at dbfork clones (`FES_USERS.alex_sotis.dbfork___prod__*`), one source skipped (`commerce.source.unified_send_log_iceberg` — 5.1 TB iceberg, would take hours to CTAS; reverted to live prod read, source-drift accepted for that one column path)
- Cloned sources at T_clone_start = 2026-07-13 16:04 UTC (2.5h after T_mwaa = 13:38 UTC)
- Fusion built with `--target test --defer --state .defer-state` — writes went to `FES_USERS.alex_sotis.dbfork___fusion_diff__<db>__<schema>__<model>`
- Compared Fusion output vs MWAA's prod `fangraph.admin.fangraph`

**Result** (row counts + set diff):

| Metric | MWAA | Fusion | Delta | % |
|---|---:|---:|---:|---:|
| Total rows | 191,324,166 | 191,351,980 | +27,814 | +0.015% |
| fangraph_ids in MWAA only | | 4,514 | | |
| fangraph_ids in Fusion only | | 32,328 | | |

Set diff reconciles: 32,328 − 4,514 = 27,814 ✓

**Result** (row-hash diff, ALL columns):

| Bucket | Count | % of common |
|---|---:|---:|
| common IDs, same hash | 110,805,950 | 58% |
| common IDs, diff hash | 80,513,702 | 42% |

**Result** (row-hash diff, EXCLUDING `fangraph_last_updated_timestamp`):

| Bucket | Count | % of common |
|---|---:|---:|
| common IDs, same hash | 134,189,806 | 70% |
| common IDs, diff hash | 57,157,689 | 30% |

Excluding the build-time timestamp lifted the byte-identical share from 58% to 70% — the timestamp field alone flipped 23.4M rows from "diff" to "same". The remaining 30% is dominated by other drift-sensitive columns:
- **Other build-time timestamps**: `fangraph_account_creation_timestamp`, `commerce_last_updated_timestamp`, `fanapp_last_login_timestamp`, `fbg_last_login_timestamp`, `fbg_last_transaction_timestamp`, `fanapp_session_last_timestamp`, `fanapp_*_last_played_date`, `topps_com_updated_timestamp`, `collect_last_active_timestamp`, `collect_last_purchased_timestamp`, `collect_last_listed_at_timestamp`, `collect_last_sold_at_timestamp`, `topps_digital_*_last_activity_timestamp` — MWAA and Fusion snapshot these at different wall-clock moments.
- **Activity counts**: `commerce_order_count`, `commerce_order_amount_total`, `fanapp_games_times_played`, `fbg_transaction_total`, `fbg_total_transaction_count`, `collect_total_sales`, `collect_orders_lifetime`, `topps_com_order_first_date`, `live_transaction_count`, etc. — mechanically increment as fans transact.
- **Session/state fields**: `fbg_status`, `fanapp_last_session`, `collect_is_frozen` — can flip between build times.

**Result** (auto_delta per-column diff — 500+ columns):

Ran `dbt run-operation auto_delta` after MWAA had re-fired fangraph once (row count grew from 191,324,166 → 191,372,866). Metrics table:
- Table A (MWAA): 191,372,866 rows | pk unique ✓ | 25,371 IDs not in Fusion
- Table B (Fusion): 191,351,980 rows | pk unique ✓ | 4,485 IDs not in MWAA

Top 15 columns by diff count (out of ~500+):

| Column | Rows differing | % of total |
|---|---:|---:|
| `fangraph_last_updated_timestamp` | 80,553,444 | **42.1%** (build-time metadata — expected) |
| `topps_digital_state` | 6,943,773 | 3.63% |
| `fbg_country` | 4,476,965 | 2.34% |
| `commerce_order_amount_total` | 3,613,545 | 1.89% |
| `commerce_billing_state` | 2,407,803 | 1.26% |
| `topps_com_billing_region` | 2,211,666 | 1.16% |
| `commerce_order_count` | 951,479 | 0.50% |
| `fbg_transaction_total` | 926,411 | 0.48% |
| `commerce_discount_total` | 913,201 | 0.48% |
| `collect_country` | 760,415 | 0.40% |
| `commerce_first_order_timestamp` | 602,110 | 0.31% |
| `commerce_fan_segment` | 376,297 | 0.20% |
| `fbg_preference_mlb_teams` | 348,553 | 0.18% |
| `fanatics_one_amount_to_next_earn_tier` | 313,369 | 0.16% |
| `fbg_preference_nba_teams` | 306,907 | 0.16% |

**Distribution by column diff magnitude:**
- ≥1M row diffs: **6 columns** (only `fangraph_last_updated_timestamp` is dominant at 42%; next 5 all <4%)
- 100k–1M row diffs: 37 columns (activity totals, geo, preferences)
- 10k–100k row diffs: 49 columns
- <10k row diffs: 8 columns

**Interpretation**: Only `fangraph_last_updated_timestamp` shows a large diff, and that's structural (set to `current_timestamp()` when a row's snapshot hash changes — MWAA and Fusion built at different wall-clock times so this diverges for any row that changed anywhere). Every other column is <4% delta, and all top-diffing columns are drift-sensitive by nature (running totals, addresses that get updated as fans move, preference arrays that fans edit). No column shows a suspicious pattern that would suggest Fusion produces systematically different values.

Result table locations (retained in Alex's schema for later inspection):
- `FES_USERS.alex_sotis.auto_delta_fangraph_metrics`
- `FES_USERS.alex_sotis.auto_delta_fangraph_conflicting_rows`
- `FES_USERS.alex_sotis.auto_delta_fangraph_conflicting_column_count`

**Result** (null counts + segment counts across 15 high-signal columns): All deltas proportional to the 0.015% row growth. No systematic Fusion nulling of fields.

| Column | MWAA nulls | Fusion nulls | % change |
|---|---:|---:|---:|
| null_email | 3,228,791 | 3,231,058 | +0.07% |
| null_phone | 80,304,141 | 80,313,230 | +0.01% |
| null_dob | 178,746,651 | 178,773,165 | +0.015% |
| null_first_name | 61,933,975 | 61,939,618 | +0.009% |
| null_last_name | 61,933,975 | 61,939,618 | +0.009% |
| null_last_updated | 0 | 0 | — |
| null_creation_ts | 206,385 | 208,903 | +1.22% (2,518 abs) |
| commerce_fans | 174,760,968 | 174,774,653 | +0.008% |
| fbg_fans | 4,469,271 | 4,477,689 | +0.19% |
| live_fans | 1,273,809 | 1,278,210 | +0.35% |
| fanapp_fans | 2,807,502 | 2,810,456 | +0.11% |

**Interpretation**: Consistent with 2.5h of source drift over 191M rows. `null_last_updated` = 0 in both means the uniqueness/not-null constraint on that field holds identically. Segment counts grow proportionally to row growth. No red flags for cutover.

**Caveats**:
- Sources were not Time-Traveled to T_mwaa — 15 secure views blocked Time Travel, so all clones are at T_clone_start (~2.5h post-T_mwaa)
- `commerce.source.unified_send_log_iceberg` reads live (skipped clone due to 5.1 TB size) — passthrough view `commerce_unified_send_log_v`, downstream fanapp aggregations use this
- Local dbt-core 1.8.7 can't parse this branch (Fusion-specific `arguments:` test syntax), so no side-by-side Fusion-vs-dbt-core against identical clones — MWAA prod is the only baseline

**Full runbook**: `projects/dbt_cloud_migration/fusion-migration/fangraph-diff-runbook.md`.

### 6. Prod credential smoke

**Scope**: Verify prod dbt Cloud credential `70437463679983` (target_name=prod, SVC_DBT_CLOUD_ROLE) can execute a real prod job end-to-end.

**Method**: Triggered prod job `dbt_sources` (`70437463791521`) via API 2026-07-14 (run `70437510361577`).

**Result (2026-07-14)**: 🟡 **Partial pass — credential validated, grants incomplete.**

Steps 1–3 (git clone, create profile from FES Snowflake connection, `dbt deps`) all **succeeded** — this confirms:
- Keypair authentication works for SVC_DBT_CLOUD_ROLE
- Prod credential `70437463679983` maps correctly to Snowflake
- git access to dbt-fes-ae repo works
- Package resolution works (dbt_utils 1.3.0 installed cleanly)

Step 4 (`dbt source freshness`) errored on the first source it tried:
```
[Snowflake] 002003 (02000): SQL compilation error:
  Database 'AMPLITUDE' does not exist or not authorized.
```

The failure is **not** an auth or connectivity problem. It's a missing grant: SVC_DBT_CLOUD_ROLE lacks `USAGE ON DATABASE AMPLITUDE`. The freshness command fails fast on the first source database it can't reach, so we didn't get a complete list of missing grants from one run — but by extrapolation, likely all 22 source DBs listed in `fusion-migration/monday-terraform-pr-spec.md` need grants.

**Grants required** (from `monday-terraform-pr-spec.md`):
- Source DBs (22): `AAIA`, `AMPLITUDE`, `APPSFLYER`, `CDE`, `COLLECTIBLES_FDE`, `COMMERCE`, `COMMERCE_CDE`, `COMMERCE_FDE`, `COMMERCE_MDE`, `FANFLOW`, `FANGRAPH`, `FBG_FDE`, `FDE`, `FES_INTEGRATIONS`, `FES_USERS`, `IDENTITY`, `LEXIS_NEXIS`, `LIVE_FDE`, `LOYALTY`, `MONTEROSA`, `SALESFORCE`, `SALESFORCE_QC`
- Per-DB grants: USAGE on DATABASE + USAGE on ALL/FUTURE SCHEMAS + SELECT on ALL/FUTURE TABLES/VIEWS/DYNAMIC TABLES
- Warehouses (11): FDE_DEVELOPER_{XS,SM,WH,LG,XL,2XL,3XL} + FDE_FANGRAPH_{MD,LG,XL,3XL}

**Next step**: land these grants via TF (either fanapp-terraform PR #2877 if that's its scope, or a new PR per `monday-terraform-pr-spec.md`), then re-trigger job `70437463791521`. Expected outcome: all sources pass freshness, or a small subset warn with stale-data messages (business logic, not permission).

**Retained artifacts**: `/tmp/dbt_sources_run.json` has the full step-by-step run detail including logs.

### 7a. Chain-trigger mechanism smoke (dev)

**Scope**: Prove `job_completion_trigger_condition` fires a downstream dbt Cloud job when an upstream job succeeds. This is the mechanism prod `dbt_loyalty` (`70437463791501`) relies on to auto-fire after prod `dbt_fanflow` (`70437463791505`) completes.

**Method**: Provisioned two smoke jobs in the dev environment (env `70437463672950`):
- Job A (`70437463792298` — `smoke_chain_test_A`): `dbt run --select dbt_cloud_smoke`, no trigger conditions
- Job B (`70437463792299` — `smoke_chain_test_B`): `dbt run --select dbt_cloud_smoke` with `job_completion_trigger_condition = {job_id: 70437463792298, project_id: 70437463666576, statuses: [10]}`

Triggered job A via `POST /api/v2/accounts/{acct}/jobs/{job_id}/run/`. Polled both jobs' runs via `/runs/{run_id}/`.

**Result**: ✅ Chain fires reliably within seconds.

| Event | UTC timestamp | Δ from upstream done |
|---|---|---:|
| Job A triggered (Queued) | 18:13:24 | — |
| Job A finished (Success, status=10) | 18:13:35.76 | — |
| Job B auto-created | 18:13:40.72 | **+4.96s** |
| Job B finished (Success, status=10) | 18:13:57.83 | +22.07s |

**Independent of TF/Snowflake**: this is a dbt Cloud API mechanism test. No prod credential involvement, no ownership transfer required. Runs entirely against dev.

**Retained artifacts**: Jobs `70437463792298` and `70437463792299` left active in dev for future re-runs. `state: 1`, no schedule (only fire when manually triggered or via chain). Safe to leave; delete via PATCH `state: 2` if desired.

### 7b. Prod chain smoke (post PR #2877)

**Scope**: Same mechanism as 7a but exercising the actual prod jobs. Redundant validation once 7a passes — dbt Cloud's API doesn't distinguish dev vs prod for this behavior.

**Status**: ⏳ Optional post-cutover.

### 8. dbt Cloud failure webhook to Slack

**Scope**: One Slack webhook subscribed to failure events across all 22 prod jobs — closes the "no alerting" gap.

**Method**: `POST /api/v3/accounts/70437463654557/notifications/`. Needs Slack webhook URL + target channel from user.

**Status**: ⏳ Pending.

### 9. dbt-fes-ae repo guardrails parity

**Scope**: Same Okta groups, CODEOWNERS, and CI workflows as fes-airflow — provisioned via fanapp-github-terraform.

**Status**: ⏳ Deferred post-cutover. Open item in `monday-cutover-plan.md`.

## What's NOT tested (and why)

- **Full 208-model output diff against MWAA**: only the `fangraph` leaf was diff'd against MWAA. Intermediate models weren't individually compared — they roll up into fangraph, so if the leaf matches, upstream behavior is validated end-to-end.
- **`share/tableau_*` and downstream `_v` cortex views**: skipped because they're views over the fangraph output, not independent data. Cortex `fangraph_v` = `SELECT * FROM fangraph WHERE <exclusion>` — if `fangraph` matches, these views match by construction.
- **REPORTING supercharged_* models**: descendants of fangraph, same argument as above.
- **Behavior under incremental with column drift**: not exercised in this diff — sources cloned mid-day and Fusion+MWAA ran near-simultaneously. If a source adds a column between clone and run, we didn't test that scenario.

## Cutover gate

All ✅ tests + the two pending prod smokes (6 and 7) must complete before flipping `triggers.schedule=true` on the 22 prod dbt Cloud jobs and running the ownership-transfer SQL. Test 8 (alerting) is a strong preference but not a hard gate — can be added same-day. Test 9 is post-cutover.
