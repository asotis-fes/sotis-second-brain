# Loyalty tenant_id backfill — verification outcome & downstream plan

**Date:** 2026-07-21
**Tenants/sites in scope:** 100034→611458 (Fanatics One, PR #2296), 100036→611466 (myvenue, PR #2280), 100038→611699 (opsuite, PR #2280).
**Not in scope:** 100037→611567 — verified CLEAN (all 32 rows already correct, 0 stranded at 100001).

## Adversarial verification verdict (background subagent, 9 checks)

**Ledger fix is SAFE and COMPLETE for the ledger itself.** Verified:
- Only `tenant_id` + `earn_tenant_id` are tenant-derived (is_test_txn/fancash_type unaffected — confirmed live vs clone identical).
- Hardcoded site→tenant CASE exactly reproduces the model's `cte_tenant_map` output (map is 1:1; the three tenants pass through the inner IFF remap untouched).
- No revert risk: `loyalty_incremental_lookback_days = 2` (current value on main), unique_key excludes tenant_id, and 0 stranded rows fall inside the 2-day window.
- Updating BOTH `_STAGE` and `_STAGE_FINAL` is necessary (all_earn_txn reads all ADDs from `_STAGE.tenant_id`) — confirmed correct.
- `loyalty_analytics_ledger` is `table_clone` → re-run its model to propagate.

**Verdict was UNSAFE *as originally scoped*** only because of downstream stranding (below).

## Downstream stranded incrementals (the gap)

Three incremental + full_refresh_prevention tables carry tenant columns derived from the ledger and will NOT self-correct:

| Table | Affected rows | Note |
|-------|---------------|------|
| `loyalty_state_stage` | 15,244 site + 57 earn_site | **13,764 carry redeem aggregates.** `ecom_redeem`/`redeem_distribution` = `SUM(... WHERE tenant_id='100001')`; the 14,874 target-site redeems are mis-attributed to commerce. Correct fix must **recompute aggregates**, not relabel. |
| `loyalty_earn_burn_mapper_stage` | 14,874 site + 47 earn_site | Redeem-grained, MAX-aggregated. Rebuild from corrected ledger recomputes cleanly. |
| `loyalty_balance_monthly_snapshot` | n/a | **No site_id column** (only tenant_id); monthly point-in-time APPEND. Rebuild regenerates only current month → would drop history. |

Target-site ledger txn mix: ADD 57, AUTH 1451, CAPTURE 1445, **REDEEM 14874** (mostly 611466/myvenue).

## Decisions (2026-07-21)

1. **Scope: "Ledger now, scope downstream next."** Apply the verified ledger fix (Step 4 in `tenant_id_backfill_20260721.sql`) now. Scope + verify the downstream fix as a follow-up before touching those tables.
2. **`loyalty_balance_monthly_snapshot`: leave history, auto-correct forward.** Do NOT relabel historical monthly snapshots (point-in-time records); future months read the corrected ledger and label correctly on their own. No historical rewrite.

## Downstream plan (follow-up, execute AFTER ledger Step 4 + clone refresh)

**REJECTED approach — drop/rename + normal run.** This dodges the compiler error but produces the exact same output as `--full-refresh` (is_incremental()=false → full reconstruction of ALL history). That is precisely what `full_refresh_prevention` exists to stop, so it circumvents the guard's intent. Do NOT do this. (User correction, 2026-07-21.)

**CHOSEN approach — targeted UPDATEs (surgical DML, guard-respecting).** Decided better than the lookback bump: (a) UPDATEs touch only the ~15–17k affected rows vs the lookback reprocessing 157 days of ALL accounts; (b) `loyalty_earn_burn_mapper` is incremental/APPEND, so a lookback reprocess there would append DUPLICATES — UPDATE-in-place is the only clean fix, forcing UPDATEs regardless; (c) surgical DML never trips full_refresh_prevention. Confirmed all target tables carry the needed filter columns (site_id, earn_site_id) + targets via INFORMATION_SCHEMA.

Per-table:
- **`loyalty_earn_burn_mapper_stage`** — pure relabel UPDATE: tenant_id (WHERE site_id IN), earn_tenant_id (WHERE earn_site_id IN). Cols present; no tenant-filtered aggregate.
- **`loyalty_earn_burn_mapper`** (append final) — SAME relabel UPDATE. Only clean option for append. Cols: LOYALTY_ACCOUNT_ID, EARN_TXN_ID, REDEEM_TXN_ID, SITE_ID, EARN_SITE_ID, TENANT_ID, EARN_TENANT_ID.
- **`loyalty_state_stage`** — relabel (tenant_id, earn_tenant_id) PLUS recompute **`redeem_distribution`** (its JSON embeds ecom_redeem/fbg_redeem = SUM(REDEEM WHERE tenant_id='100001'/'100002'), which shift once redeems are re-attributed). NOTE: ecom_redeem/fbg_redeem are NOT separate output columns — only REDEEM_DISTRIBUTION (JSON) is materialized. Recompute = re-aggregate affected (account,txn) groups from the corrected ledger and rebuild the JSON.
- **`loyalty_state_stage_final`, `loyalty_state`** — plain `table` models → rebuild on next normal DAG run, auto-propagate. No UPDATE.
- **`loyalty_balance_monthly_snapshot`** — no action (decision #2).

Lookback bump remains a FALLBACK if the state_stage recompute proves too fiddly to hand-roll (earliest affected = 2026-02-14 = 157 days; `dbt run --select ... --vars '{"loyalty_incremental_lookback_days":165}'`, then revert) — but it does NOT work for the append mapper.

**The one correctness risk:** state_stage's redeem_distribution recompute is hand-rolled. Mitigation: validate UPDATE output against the model's OWN compiled SQL for the affected accounts on a clone (byte-match) → proves the logic faithful. Earn-burn tables are pure relabels (no such risk).

**To build:** clone → UPDATE → validate (incl. model-parity check for state_stage) → second adversarial pass, per table. Prereq: ledger fix applied and `loyalty_analytics_ledger` refreshed (state/earn_burn read the corrected ledger).

## EXECUTED & VERIFIED (2026-07-21)

All 11 UPDATEs from `all_updates_20260721.sql` run against the real tables. Post-execution validation:
- Labels on all 5 tables (_STAGE_FINAL, _STAGE, EBM_STAGE, EBM_FINAL, STATE_STAGE): **0 bad_tenant / 0 bad_earn**.
- state_stage redeem_distribution recompute vs corrected ledger: **14,331 / 14,331 exact, 0 mismatch**.
- BACKFILL COMPLETE. Remaining propagation (loyalty_analytics_ledger table_clone + loyalty_state / loyalty_state_stage_final tables) happens on the next scheduled DAG run. loyalty_balance_monthly_snapshot: left as-is (auto-corrects forward).
- CLEANUP: drop leftover clones — LAL_STAGE_FINAL_CLONE_20260721 (ledger dry-run) + any *_BAK_20260721 backups — once satisfied post next DAG run.

## Read-only dry-run validation (2026-07-21) — both correctness gaps CLOSED

- **earn_burn MAX(site_id) edge case:** 14,874 target-site redeem groups, **0 multi-site** → `MAX(site_id)` unambiguous, relabel is exact.
- **state_stage redeem_distribution parity:** recompute formula vs model's stored JSON on the affected groups = **14,331/14,331 exact match, 0 mismatch** → `TO_JSON` format + logic reproduce the model faithfully; the Tier-2 recompute is cleared.
- Consolidated runnable script: `all_updates_20260721.sql` (11 UPDATEs, no validation SQL).

**Residual (operational, not correctness):** no backup exists for the 3 downstream tables → take a zero-copy clone of each before running (rollback net). Run during a DAG-idle window. Order: ledger UPDATEs first (redeem_distribution recompute reads the corrected _STAGE_FINAL).
