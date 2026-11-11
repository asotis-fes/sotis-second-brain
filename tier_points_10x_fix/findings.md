# Findings

## Domain context

- **Status match** = a trial period. The customer is given a higher tier "for free" as a
  trial and challenged to earn a target number of tier points (`trial_target_points`)
  within a window (`trial_start` → `trial_expiry`). If they hit the target they keep the
  tier for the rest of the year; if not, they drop back to their earned tier.
- **10x program launch: 2026-04-23 13:17:21 UTC.** After launch, all tier point *earnings*
  are 10x. So the trial target a customer must reach is also expressed in 10x terms.
- For historical consistency, **pre-launch** trial targets (stored in 1x scale) must be
  multiplied by 10 so they can be compared against the (now 10x) earned points.
  **Post-launch** overrides created in Salesforce already carry 10x target values and must
  NOT be multiplied again.

## Models involved (dbt-fes-ae)

Chain (source → consumer):

1. `tier_points_overrides_v2.sql` — raw pull from Salesforce
   `FanMemberTierInformation_..._dll` object. Provides `trial_target_points`
   (`TrialTargetPoints_c__c`), `trial_start` (`TrialStart_c__c`),
   `trial_expiry` (`TrialExpiry_c__c`), `status_match_start`, `status_match_expiry`,
   `last_modified_date` (`LastModifiedDate__c`).
2. `tier_points_overrides__status_match.sql` — filters to valid status-match trials,
   builds `override_start`/`override_end` intervals, then flattens them via the
   `flatten_override_intervals` macro. **Output columns:** `salesforce_member_id`,
   `private_fan_id`, `override_id`, `interval_start`, `interval_end`,
   `next_interval_start`, `override_tier`, `override_tier_rank`, `override_expiry`,
   `trial_target_points`, `trial_expiry`.
   - `override_start = coalesce(trial_start, last_modified_date)`.
   - `override_end = lead(override_start)` per member (else `9999-12-31`).
   - `flatten_override_intervals` groups consecutive identical
     (override_id, override_tier, trial_start, original_override_start) rows into a single
     interval and takes `MAX(trial_target_points)` within the group.
3. `tier_points_ledger_v2.sql` — the `status_match` CTE selects from the above and renames
   `interval_start → trial_start` / `start_override_active`, `interval_end →
   end_override_active`. This is where the PR made its edit.

## The (incorrect) PR #66 fix

PR rewrites the `status_match` CTE in `tier_points_ledger_v2.sql` to:
- compute `latest_override_start = max(interval_start) over (partition by member)` over
  non-null override rows;
- `CASE WHEN override_id IS NULL THEN trial_target_points`
  `WHEN interval_start = latest_override_start THEN trial_target_points` (no 10x on latest)
  `ELSE trial_target_points * 10` (10x all earlier overrides).

### Why it is wrong (hypothesis)
The PR uses **"is this the member's most recent override?"** as the proxy for "already
10xed." That proxy is wrong:
- A member can have **multiple pre-launch overrides**; the *latest pre-launch* one is still
  in 1x scale and needs the 10x, but the PR skips it because it's the max interval_start.
- Conversely a member's earlier overrides may already be post-launch (10x) if they had
  several post-launch trials — the PR would 10x those again → **double 10x (100x)**.

The correct discriminator per the user's hint is **the interval/trial dates vs. the 10x
launch timestamp**, NOT ordinal recency. Working hypothesis:

> 10x `trial_target_points` **iff the override/trial predates the 10x launch**
> (`2026-04-23 13:17:21 UTC`). Post-launch overrides already store 10x targets.

Open question: which date field is the correct discriminator — `trial_start`,
`interval_start` (= override_start = coalesce(trial_start, last_modified_date)),
`interval_end`/`trial_expiry`, or `last_modified_date` (when the Salesforce row was
written / when the 10x backfill stamped it)? This is the core thing to validate against
the sample fan ids. See queries.md.

## ⭐ ROOT CAUSE CONFIRMED (from Salesforce CDC history, 2026-08-09)

### Physical tables
- Prod: `LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2` (60M CDC rows, one per
  Salesforce `LastModifiedDate` per member), `..._OVERRIDES__STATUS_MATCH` (33,350
  flattened intervals), `..._TIER_POINTS_LEDGER_V2` (423M).
- Raw source is a Salesforce data-lake (`_dll`) object = **change-data-capture**: many
  versioned snapshots per member over time, each with its own `last_modified_date`.

### What the 10x migration actually did
On **2026-04-23** the migration **multiplied `trial_target_points` (and
`trial_start_tier_points`) by 10 IN PLACE on the member's then-current Salesforce
record** — i.e., the single override that was the latest/active record for that member at
migration time. Proven by the CDC series:

- Fan `7c25289f` override `newyear-…`: target `100` on all rows through 2026-02-03, then
  **jumps to `1000` on the 2026-04-23T14:47 row** (trial_start_tier_points 25.83 → 258.30
  same row). One override only → already 10x.
- Fan `8ad58668` override `NFL-CaesarsRewards-…`: target `100` through 2026-03-06, then
  **`1000` on 2026-04-23T14:57** (start pts 2132.32 → 21323.20). Its trial had already
  expired 2026-02-07, yet it was STILL 10xed because it was the current record.
- Same fan's **older** overrides (`DraftKingsDynasty` gold `600`, platinum `3000`,
  `nfl_mgm_noir` black `2000`) were **never modified on/after 4/23** → they stayed **1x**.

### Therefore, per override interval, three classes
1. **Ended before launch** (interval_end ≤ launch): never touched → **1x → must ×10.**
2. **Active at launch** (interval_start ≤ launch < interval_end): migrated in place →
   **already 10x → must NOT ×10.**  (Note: true even if the trial had already expired —
   `trial_expiry` can be < launch while the record was still current. This is why
   `trial_expiry`/`trial_start` are the WRONG discriminator.)
3. **Created after launch** (interval_start > launch): entered natively in 10x terms →
   **already 10x → must NOT ×10.**

### ⭐ The correct rule (date-based, on the flattened interval)
```sql
CASE
  WHEN override_id IS NULL           THEN trial_target_points          -- gap rows untouched
  WHEN end_override_active <= '{{ 10x_launch_timestamp }}'
                                     THEN trial_target_points * 10     -- interval ended pre-launch: 1x
  ELSE trial_target_points                                            -- active-at / post-launch: already 10x
END
```
`end_override_active` = `interval_end` from `tier_points_overrides__status_match`. Because
intervals are contiguous per member (interval_end = next interval_start), this cleanly
splits "everything before the active override" (×10) from "the active override + all
later ones" (keep). Classes 2 & 3 both satisfy interval_end > launch.

### Why PR #66 is wrong
PR uses ordinal recency ("10x all overrides except the member's *latest* interval_start").
That coincidentally matches the date rule for the two sample fans (their latest interval
IS the migrated one), but it **breaks whenever a member received a NEW status-match
override AFTER 2026-04-23**: the previously-active override was already 10xed by the
migration, but PR now sees it as "earlier" and 10xes it again → **double-10x (100x)**.
The date rule leaves it alone (its interval_end = the new override's start > launch).
It also mis-handles any member whose single/latest override ended pre-launch but was still
migrated (PR would skip it correctly here, but the general ordinal logic is fragile).

## ⭐ WHERE SHOULD THE FIX LIVE? (consumer analysis, 2026-08-09)

`trial_target_points` in `tier_points_overrides__status_match` is RAW Salesforce, in **mixed
scale** (1x for pre-launch, 10x for migrated/native). Consumers:

| Consumer | Reads from | Uses target how | Affected? |
|---|---|---|---|
| `tier_points_ledger_v2` (status_match CTE) | `overrides__status_match` | compares `trial_earned_points >= trial_target_points` → `status_match_active` → `public_facing_tier` | **YES — this is the bug** |
| `tier_points_override_transactions` | `overrides__status_match` (`SELECT *`) | carries `trial_target_points` as a passthrough event attribute (not compared) | Mixed-scale passthrough — check its downstream consumers |
| `pfi_status_matches` (fangraph) | **`tier_points_overrides_v2` directly** (NOT the status_match model) | compares running total vs raw target | **Already self-handles scale** (see below) |

### pfi_status_matches already solves scale a DIFFERENT way
It does NOT normalize the target. Instead it picks the **earned-points scale to match the
target**, keyed on the override's `last_modified_date` (lines 74-86, 129-141):
```sql
CASE WHEN last_modified_date < '{{ var("10x_launch_timestamp") }}'
     THEN SUM(tier_points_amount)          -- target is 1x → compare against 1x earned
     ELSE SUM(derived_tier_points_amount)  -- target is 10x → compare against 10x earned
END AS running_total
```
So it uses `last_modified_date < launch` as the 1x/10x discriminator — the **snapshot-lmd
signal**, which is EXACT (it correctly handles GOLDTEST500: latest lmd 2026-04-06 < launch →
treats target as 1x). pfi reads `overrides_v2` directly and is **out of scope** — it needs no
change and won't conflict with a ledger/status_match fix.

### Recommendation
- **Fix in `tier_points_overrides__status_match`** (normalize `trial_target_points` to a
  single 10x scale) rather than only in `tier_points_ledger_v2`:
  - It centralizes the fix for BOTH downstream consumers (ledger + override_transactions),
    instead of leaving `override_transactions` with a mixed-scale passthrough.
  - It's the model that owns the flatten, so `last_modified_date` is reachable there —
    letting us use the **exact lmd/CDC signal** (matches pfi's logic) instead of the
    `interval_end` proxy that misses the 1 test row.
- **Easiest** = the 6-line `interval_end` CASE in `tier_points_ledger_v2` (matches PR #66's
  location + the existing transaction-10x location; correct for all 33,231 real intervals,
  wrong only on the 1 test row).
- **Trade-off:** upstream = one authoritative scale for all consumers + exact + aligns with
  pfi's mental model, at the cost of touching a shared model (needs regression on
  override_transactions and its consumers). Ledger-only = contained + minimal, but
  duplicative and leaves override_transactions mixed-scale.

### Test B result — override_transactions is a DEAD passthrough
`tier_points_override_transactions` → its only consumer `tier_points_transaction_journal`
(lines 29-58) DROPS `trial_target_points` (keeps ts/ids, sets tier_points_amount=0, target
not selected). So the mixed-scale target **never propagates** through that path. The real,
customer-facing bug is confined to `tier_points_ledger_v2`'s status_match comparison.
→ Doesn't change the upstream decision (still cleaner + exact), but the **regression surface
is small**: normalizing upstream won't alter any currently-used downstream value except the
ledger's status_match, which is exactly what we're fixing.

**My call:** normalize upstream in `overrides__status_match`, using the lmd signal for
exactness. Add `last_modified_date` (max over the interval) to the flatten output OR compute
the ×10 pre-flatten per snapshot (`iff(last_modified_date < launch, target*10, target)` then
`MAX`). Either yields the exact result including the test row.

## Note on tier_points_transaction_journal (for contrast)

In `tier_points_ledger_v2.sql`, the *transaction* side already handles 10x cleanly:
`derived_tier_points_amount = CASE WHEN notes = 'TierPoints 10x Loyalty Program' THEN 0
WHEN transaction_timestamp >= 10x_launch_timestamp THEN tier_points_amount
ELSE tier_points_amount * 10 END`.
i.e. transactions use **timestamp >= launch** to decide 10x vs. not, and zero out the
one-time 10x migration transaction. The status_match fix should mirror this
timestamp-based approach rather than the ordinal approach in PR #66.
