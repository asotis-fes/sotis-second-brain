# Decisions

- **PR #66 is a reference for scope only, not a source of truth for the fix.** (per user)
- **CONFIRMED (2026-08-09): the 10x discriminator is date-based on `interval_end`
  (`end_override_active`), NOT ordinal "most recent override".**

## Final rule (locked)
In `tier_points_ledger_v2.sql`'s `status_match` CTE, replace the target expression with:
```sql
CASE
  WHEN override_id IS NULL THEN trial_target_points
  WHEN interval_end <= '{{ var("10x_launch_timestamp") }}' THEN trial_target_points * 10
  ELSE trial_target_points
END AS trial_target_points
```
Full CTE in `corrected_cte.sql`. `10x_launch_timestamp = '2026-04-23 13:17:21.000 +0000'`.

## Why (root cause)
The 4/23 migration multiplied `trial_target_points` ×10 **in place on each member's
then-current Salesforce override record only**. So per flattened interval:
- interval_end ≤ launch  → never migrated → still 1x → **×10**
- interval_end > launch   → active-at-launch (migrated) or created-after (native) → already 10x → **keep**

## Why PR #66 is wrong
It ×10s every interval except the member's latest by `interval_start`. That double-10xes
(→100x) the previously-active override of any member who got a NEW override after launch.
**452 intervals** in prod are double-10xed by PR #66; 29 are under-10xed. (Q3)

## Validation (all passed)
- 2 sample fans: correct. (Q2)
- 10 more affected fans: 0 mismatches each; each ×10s exactly its pre-launch interval.
- Full table: rule agrees with independent CDC ground truth on **33,231 / 33,232** intervals.
- The 1 exception is a single `GOLDTEST500` **test** override (active at launch but never
  migrated) — unreachable by any date-based rule; accepted/negligible.

## Generalizable correctness check
`validation_query.sql` → returns `mismatch_rows = 0` (excluding test overrides) when the
fix is correct for everyone. It independently derives, from Salesforce CDC, whether each
interval is still 1x, and asserts the fix's ×10 decision matches.

## Location decision (2026-08-09, user-confirmed)
**Fix UPSTREAM in `tier_points_overrides__status_match`** (normalize `trial_target_points`
to one 10x scale), NOT only in `tier_points_ledger_v2`. Use the **exact `last_modified_date`
signal** (per-snapshot / max-lmd-in-interval), matching how `pfi_status_matches` already
reasons about scale — this also handles the GOLDTEST500 test row that the `interval_end`
proxy misses. Rationale + consumer table in findings.md ⭐ "WHERE SHOULD THE FIX LIVE".
- `pfi_status_matches` (fangraph) reads `overrides_v2` directly and self-handles scale → out
  of scope, no change, no conflict.
- Pre-ship tests requested: end-to-end ledger outcome, override_transactions blast radius,
  boundary + population counts. (see queries.md Q5+)

## FINAL fix (locked, upstream) — 2026-08-09
In `tier_points_overrides__status_match.sql`, `status_match` CTE, normalize per snapshot:
```sql
iff(o.last_modified_date < '{{ var("10x_launch_timestamp") }}',
    o.trial_target_points * 10,   -- pre-launch snapshot: 1x
    o.trial_target_points)        -- migrated / native post-launch: already 10x
AS trial_target_points
```
Then REVERT the ledger `status_match` CTE to a plain passthrough (abandon PR #66). Full
text + exact edit in `corrected_upstream.sql`.

### Validation of the final fix
- **Real customers (UUID fan_id): 0 mismatches / 33,233 intervals** vs independent CDC truth.
- End-to-end (Test A): correctly flips false status-match grants (current prod over-grants).
- Edge cases (both single rows):
  - `GOLDTEST500` (fan 3aef9dfc, REAL "Gold Fast Track" customer): lmd fix ✅ (interval_end
    proxy ✗ — a reason we went upstream).
  - `SuneelRachamallu` (DEV account, non-UUID): lmd fix over-scales 6000→60000; zero prod
    impact. Only case where lmd rule differs from CDC truth.

### Two viable fix forms (both upstream)
1. **Per-snapshot lmd × MAX** (chosen — one-line, simplest): correct for all real customers.
2. **cdc_expected semantics** ("if any post-launch snapshot → use its value; else pre×10"):
   also correct on the Suneel dev row, but needs group-level window logic before the flatten
   (more code). Only upgrade if we ever expect real customers with human-entered 10x-magnitude
   pre-launch targets — not observed. Documented as optional hardening.

## Open / uncertain
- **Test-account edge case**: `%TEST%` overrides active at launch but not migrated (1 found).
  The fix leaves them at 1x. Harmless for prod reporting; excluded from validation.
- **tz nuance**: comparison casts the `+0000` var string to `timestamp_ntz`; data is UTC so
  wall-clock matches. Mirrors the existing `transaction_journal` 10x comparison style.
- **Not yet done**: apply the fix to a dbt-fes-ae branch / PR (awaiting user go-ahead);
  create the FES_USERS.ALEX_SOTIS sample tables (DDL in `sample_tables.sql`, user runs it).