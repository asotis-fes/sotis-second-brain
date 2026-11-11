# Snowflake Masking Policy Performance Tax — Report

**Date:** 2026-06-10
**Run ID:** `20260610a`
**Author:** alex.sotis@betfanatics.com

## TL;DR

We measured the wall-clock and credit cost of adding Snowflake column masking policies to a representative FES Data workload, in two passes:

1. **Microbenchmark** (Phase 2) — small queries against the final `fangraph` table on a SMALL warehouse, designed to isolate the per-row mask cost.
2. **Production-realistic** (Phase 3) — full rebuild of the `fangraph` dbt model with all 45 PII columns masked across both source tables (`fangraph_base`, `fangraph_snapshots`), on the prod warehouse size (`3X-LARGE`).

The two phases produced **very different numbers**, both correct, measuring different things:

| Scenario | Mask form | Tax vs baseline |
|---|---|---|
| Phase 2 (SMALL WH, single-column queries) | SHA2 hash | **+110% to +190%** |
| Phase 3 (3XL WH, full fangraph rebuild, 45 cols) | SHA2 hash | **~0% (within noise)** |
| Phase 3 (3XL WH, full fangraph rebuild, 45 cols) | Constant (`'***MASKED***'` / NULL) | **−15% (faster than baseline)** |

**The Phase 3 numbers are the right input for the FES Data ↔ other-data-team alignment decision** — they reflect the actual cost on the actual workload at the actual prod warehouse size. The Phase 2 numbers are the right reference for *understanding* the unit cost of masking, but they substantially overstate the tax for production-size workloads.

Why the gap: per-row mask cost parallelizes well across a 3XL warehouse, and the fangraph rebuild has a lot of non-mask work (joins, 530-column projection, row-hash macro across 496 cols) that dilutes the mask cost into the noise.

The view-based PII handling alternative is out of scope for this report.

---

## Phase 3 — Production-realistic test (headline)

### Setup
- Zero-copy clones of `FANGRAPH.ADMIN.FANGRAPH_BASE` (190M rows) and `FANGRAPH.ADMIN.FANGRAPH_SNAPSHOTS` (1.14B rows, 5-day window).
- The team's authoritative 45-column PII set, identified by diffing the columns selected in `fangraph` against `fangraph_nonpii_v`. Composition: 39 STRING (names, emails, addresses), 4 NUMBER (phones), 2 DATE (DOBs). One column (`TOPPS_COM_PHONE`) is NUMBER in base but VARCHAR in snapshots — handled with per-table type-specific policies.
- Three per-type policies, all role-conditional via `IS_ROLE_IN_SESSION('TEST_PII_READER_...')`:
  - **Hash variant**: `SHA2(val, 256)` / `HASH(val)` / `DATE_TRUNC('YEAR', val)`
  - **Const variant**: `'***MASKED***'` / `NULL` / `NULL`
- Warehouse: `FDE_DEVELOPER_3XL_WH` (3X-LARGE) — same size as the prod warehouse for both `fangraph` and `fangraph_base`.
- Resolved `fangraph.sql` from fes-airflow with macros expanded inline (no dbt dependency in the runner).
- 3 reps of BASELINE (no policy) and HASH-mask, 1 rep of CONST-mask, all interleaved against the same clones with `USE SECONDARY ROLES NONE` and `USE_CACHED_RESULT = FALSE`.

### Results

| Variant | Wall sec (median) | Wall sec (range) | Credits @ 3XL | vs baseline |
|---|---:|---:|---:|---:|
| BASELINE (no policy) | 291.1 | 278.1 – 292.1 | 5.10 | — |
| MASKED — hash | 290.6 | 288.4 – 306.8 | 5.04 | **−0.2%** (within noise) |
| MASKED — const | 248.9 | (single rep) | 4.36 | **−14.5%** |

**Per-run cost at FBG rates** (~$2.50/credit on 3XL): baseline ≈ $12.75/run, hash-mask ≈ $12.60/run, const-mask ≈ $10.90/run.

### Verification

After Step 3, `SELECT email, first_name, phone, dob FROM <result_table> LIMIT 5` returned `'***MASKED***'` for strings and `NULL` for phone (NUMBER) and DOB (DATE) — confirming the policies fire all the way through the row-hash macro, the join, and the final projection. The earlier MASKED runs produced SHA2 hashes in those same columns; we verified the masked branch was hit via `bytes_scanned = 0` (vs. 209.5 GB for baseline runs).

### Findings (Phase 3)

1. **Hash masking adds no measurable cost to the fangraph rebuild on the prod warehouse.** Median delta is −0.5 sec (faster), 0.06 fewer credits per run. Variance across reps is ±5%, larger than the inter-variant delta. For the team's daily fangraph rebuild, **adopting SHA2 masking on all 45 PII columns is effectively free.**

2. **Constant-return masking is *faster* than no policy at all** by ~14.5%. Snowflake's optimizer recognizes constant projections and skips reading the underlying column data. The savings (≈ 42 sec / $1.85 per fangraph rebuild) are real, but the masked-branch output is information-free — every user without unmask sees `'***MASKED***'` everywhere, can't join on hashed values, can't count distinct, etc.

3. **The two mask styles serve different use cases:**
   - **Hash**: preserves uniqueness/joinability for downstream consumers. Good for service-role pipelines that need to rebuild downstream tables where consumers will eventually have unmask access.
   - **Const**: free (actually faster), but destroys all signal. Good for hard-deny scenarios where the masked role never legitimately needs to do anything analytical with the column.

4. **`column_intersection_row_hash` works correctly with masked sources, but with a hidden caveat.** The fangraph model uses this macro to detect row changes between snapshots and base. With deterministic masking (SHA2 or constant), masked-side hashes match each other but don't reflect changes in the *underlying* PII value. **If PII changes upstream (e.g., a user updates their email), the row hash will not pick it up, and `fangraph_last_updated_timestamp` will not bump.** This is a correctness concern that exists independently of performance — flag for the team.

---

## Phase 2 — Microbenchmark (decomposition)

The Phase 2 runs were designed to isolate the per-row mask cost on simple queries. They overstate the production tax substantially (see "Why the gap" below), but they're useful for *explaining* the cost structure.

### Setup
- Single masked column (`FANGRAPH_EMAIL`) on the final `fangraph` table (190M rows).
- Warehouse: `FDE_DEVELOPER_SM_WH` (SMALL — 1/32 the compute of 3XL).
- N=10 reps per cell, first 2 discarded as warmup, median of reps 3–10.
- Four policy variants × four query patterns × two roles for conditional variants.

### Headline tax — masked branch

| Query | Baseline (ms) | `P_HASH` (ms) | `P_COND_ISR` masked (ms) | Tax |
|---|---:|---:|---:|---:|
| Q1 — full-projection scan (`MAX(LENGTH(email))`) | 1,544 | 3,586 | 3,551 | +130% |
| Q2 — `COUNT(DISTINCT email)` | 6,728 | 14,248 | 14,298 | +113% |
| Q3 — predicate on masked col (`WHERE email = 'x'`) | 1,206 | 3,496 | 3,392 | +181% |
| Q_MC — 4 masked cols projected | 2,892 | 9,240 | — | +219% |

### Plaintext branch (unmask role, `THEN val`)

| Query | Baseline | Plaintext (ms) | Tax |
|---|---:|---:|---:|
| Q1 | 1,544 | 1,478 | −4% |
| Q2 | 6,728 | 6,952 | +3% |
| Q3 | 1,206 | 1,293 | +7% |

Analysts with unmask access pay essentially nothing for the policy being present.

### Findings (Phase 2)

1. **`P_COND_ISR` (`IS_ROLE_IN_SESSION()`) and `P_COND` (`CURRENT_ROLE()`) cost essentially the same.** Within 1% on every cell. **Recommendation: write production policies with `IS_ROLE_IN_SESSION()`** — works correctly with secondary-role grants (FBG's default) and has no measurable performance penalty.

2. **Compile cost is essentially flat across all variants** (108–180 ms regardless of policy). The entire microbenchmark tax is per-row execution work.

3. **Predicate-on-masked is the worst-case pattern in the microbenchmark (+181%)** because the predicate evaluates against the post-mask value, losing pushdown. Production effect: see Phase 3 — the parallelism at 3XL absorbs even this worst case.

4. **`P_NULL` ran ~90% *faster* than baseline** because the optimizer elided the column scan for constant projections. This was the early signal that const masking would beat baseline, and Phase 3 confirmed it at scale.

5. **`bytes_scanned = 0` for all masked queries** vs ~72 GB for baseline. Not a useful metric for masked queries; rely on wall-clock and exec-time deltas.

---

## Why Phase 2 and Phase 3 differ so much

| Dimension | Phase 2 microbenchmark | Phase 3 fangraph rebuild |
|---|---|---|
| Warehouse | SMALL (2 credits/hr) | 3XL (64 credits/hr) — **32× the compute** |
| Workload | one full scan, one masked column, COUNT DISTINCT — masking is ~100% of the CPU work | full table rebuild with row-hash macro across 496 cols, join on `fangraph_id`, projection of 530 cols — masking is a *small fraction* of total CPU |
| Per-row mask invocations | 190M (one column × one ref) | ~25 B (45 PII cols × 3 refs each × 190M rows) |
| Relative cost of masking | dominant | dilute and parallelizable |
| Tax (HASH) | +110% to +190% | ~0% |

Two effects compound:
- **Parallelism:** 3XL has ~32× the per-second compute of SMALL. The per-row SHA2 work parallelizes well, so absolute mask cost shrinks dramatically as warehouse size grows.
- **Workload composition:** in Phase 2 the mask is on the critical path; in Phase 3 it's one of many things the query does. The non-mask work (joins, hash macros over non-PII cols, projection) doesn't shrink when masking is added — so the relative cost falls.

**Implication:** the right number to quote depends on the workload.
- **Production dbt rebuilds on prod-size warehouses → Phase 3 numbers (~0%).**
- **Analyst ad-hoc queries on smaller dev warehouses (XS–S) → closer to Phase 2 numbers**, especially if the query is dominated by masked-column work.

The microbenchmark is the worst case in isolation; the real production cost will fall somewhere between Phase 2 and Phase 3 depending on warehouse size and query shape.

---

## Methodology (full)

See `test_plan.md` for the parameterized SQL, role-isolation pattern (`USE SECONDARY ROLES NONE` plus dedicated scratch roles), cache-control approach (`USE_CACHED_RESULT = FALSE` + warehouse suspend/resume per cell), statistical approach (drop warmup reps, report median, flag cells with high coefficient-of-variation), and cell-ordering rule (interleave per-query so warehouse drift hits every variant equally).

Phase 3 specifically:
- Resolved `fangraph.sql` from fes-airflow with macros expanded inline (`build_fangraph_sql.py` + column intersection via `INFORMATION_SCHEMA`).
- Per-table family-of-type policy attachment (`build_phase3_step2.py`) to handle the `TOPPS_COM_PHONE` type mismatch between source tables.
- `ACCOUNTADMIN` + `USE SECONDARY ROLES NONE` for masked runs, so admin's secondary-role grants don't leak `TEST_PII_READER` back into the session and accidentally trigger the plaintext branch.

### Validated controls (Phase 3)

Verified post-hoc by querying `QUERY_HISTORY_BY_USER` and `QUERY_HISTORY_BY_WAREHOUSE`:

- **No warehouse contention.** Zero queries from other users on `FDE_DEVELOPER_3XL_WH`, `FDE_DEVELOPER_SM_WH`, or `FDE_DEVELOPER_XS_WH` during the entire experiment window. Every measured run had the warehouse to itself.
- **Warehouse size constant** at `3X-Large` across all 7 Phase 3 CTAS runs — no mid-experiment scaling.
- **Role constant** at `ACCOUNTADMIN` across all 7 runs.
- **Single cluster** (`cluster_number = 1`) for every run — no `MAX_CLUSTER_COUNT` scaling effects.
- **Cold-start state consistent.** `queued_provisioning_time` was 0.4–0.6 sec on 6 of 7 runs (with one 2.8s outlier — ~1% of total, within noise), confirming each CTAS hit a freshly-resumed warehouse.
- **No queueing or contention.** `queued_overload_time` and `queued_repair_time` were 0 for every run.
- **Result cache disabled and honored.** All 3 BASELINE runs scanned 209.5 GB from storage — confirming `USE_CACHED_RESULT = FALSE` was respected (a cache hit would show 0 bytes scanned).
- **Source tables immutable during the experiment.** Zero-copy clones taken once at start, never refreshed.

**Residual unknowns** (not invalidating, but worth noting):

- **Clustering keys / search optimization on source tables** — if present in `FANGRAPH.ADMIN.FANGRAPH_BASE` / `FANGRAPH_SNAPSHOTS`, those properties are inherited by zero-copy clones and apply equally to baseline and masked runs. The relative tax comparison is unaffected; the absolute baseline runtime may not match a hypothetical un-clustered version of the same table.
- **Adaptive plan reuse** across structurally-identical CTAS calls. Compilation time was stable (2.7–4.8s) across runs, so plan reuse isn't dominating; minor warmup effects are absorbed by the per-cell warehouse suspend.

---

## Limitations

The numbers above are warm-cache, steady-state, single user, no concurrency, on the listed warehouse sizes. Specifically, the following are **not** measured and could change the picture:

- **Concurrent users.** Contention on the same warehouse may amplify cost — masked queries occupy the warehouse longer (if Phase 2 dynamics dominate) or about the same (if Phase 3 dynamics dominate).
- **Smaller warehouses (XS–S) for production work.** Phase 2 measured SMALL; if a team moves dbt or analyst workloads to even smaller warehouses, expect the tax to scale up toward Phase 2 numbers.
- **Joins between two masked tables on the masked column.** Phase 2 Q3 measured a single-table predicate. A two-side masked join is plausibly worse.
- **Numeric / date masks at scale.** The 45-column Phase 3 test included 4 NUMBER and 2 DATE columns, but they're a small fraction; pure-numeric or pure-date masks weren't isolated.
- **Clustering keys, search optimization, materialized views, time-travel, semi-structured masking.** All can interact with masking in non-trivial ways; out of scope.
- **`bytes_scanned`** is 0 for all masked queries (vs. baseline). Don't quote this as evidence of pushdown loss or optimization — it's a metric artifact. Use wall-clock and exec-time deltas instead.

### Correctness caveat (not a perf issue)

Masking sources that feed `column_intersection_row_hash` (or any change-detection logic that hashes column values) will produce stable hashes regardless of underlying PII changes, because both SHA2 and constant-return are deterministic. **A user changing their email will not trigger a row-hash mismatch and `fangraph_last_updated_timestamp` will not bump.** This is independent of warehouse size or query pattern — it's a correctness implication of source-table masking on this specific model. Worth raising with the team before adoption.

---

## What this means for the alignment discussion

The Phase 3 numbers are the right input for the decision on the actual workload:

> *Adopting masking policies (hash form, `IS_ROLE_IN_SESSION()`-conditional) on all 45 PII columns in `fangraph_base` and `fangraph_snapshots` adds essentially zero runtime and zero credit cost to the daily fangraph rebuild on the prod 3XL warehouse. Adopting constant-return masking (`'***MASKED***'` / NULL) instead would make the rebuild ~14% faster, but at the cost of zero information for masked users — every masked value is identical.*

For analyst workloads (smaller warehouses, simpler queries), the tax is bigger — the Phase 2 numbers approximate the upper bound. The team should:
- Quote the **Phase 3 numbers** when discussing impact on production dbt jobs.
- Quote the **Phase 2 plaintext-path numbers (+3–7%)** when discussing impact on analysts with unmask permission, regardless of warehouse size.
- Quote the **Phase 2 masked-branch numbers (+110–190%)** when discussing the upper-bound impact on small-warehouse analyst queries hitting the masked branch.
- Decide separately on the **correctness implication** of masking columns that feed change-detection macros.

---

## Reproducing

All artifacts in `snowflake_masking_tax/`:

- `test_plan.md` — methodology, decisions, parameterized SQL.
- **Phase 1 (smoke test, 1M-row synthetic):** `run_20260610a_phase1.sql`.
- **Phase 2 (microbenchmark, single column, 190M rows):** `generate_phase2.py` → `run_20260610a_phase2_stage_a.sql`, `..._stage_b.sql`, `..._results.sql`.
- **Phase 3 (full fangraph rebuild, 45 cols, 190M+1.14B rows):**
  - `build_fangraph_sql.py` — expand the dbt model's Jinja into runnable SQL.
  - `build_phase3_step2.py` — generate the interleaved BASELINE/MASKED matrix with per-table type-family policy attachment.
  - `/tmp/p3_baseline.sql`, `/tmp/p3_step2.sql`, `/tmp/p3_step3_const.sql` — actual run artifacts (not under version control).

To rerun the Phase 3 test against a different dbt model:
1. Re-export the model's column intersection to `/tmp/fg_base_cols.txt`.
2. Update `BASE_CLONE` / `SNAP_CLONE` / `FANGRAPH_SQL` paths in `build_fangraph_sql.py`.
3. Update the PII column lists in `build_phase3_step2.py` (and any per-table type-family overrides).
4. Re-emit and re-run.
