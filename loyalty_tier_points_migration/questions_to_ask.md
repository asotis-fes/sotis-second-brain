# Open Questions — Tier Points Migration

Resolve before writing code. Ask Suneel / loyalty eng team + coordinate with analytics engineer.

## For Suneel / loyalty eng

### Q1 — ~~Confirm exact PG table names~~ **RESOLVED via `tp_schema_discovery` DAG run**

See `analysis/dev_pg_discovery.md`. Definitive PG names:
- `test_tier`, `test_tier_override_configuration`, `test_tier_account_override`, `test_tier_account_override_trial`, `test_tier_invite_approval`
- Suneel dropped `tier_` prefix from `override_configuration` and `invite_approval` in his message.
- `test_transacrion` is confirmed typo for `test_transaction`.

### Q2 — ~~Missing table?~~ **RESOLVED**

`test_tier_account_override_trial` exists in dev PG (10 cols). Suneel omitted but it's needed for STATUS_MATCH trial analytics. Ingest.

### Q3 — ~~Any `account_balance` schema change we need to catch?~~ **RESOLVED**

`lifetime numeric NOT NULL DEFAULT 0` exists in dev PG today on `test_account_balance`. Contradicts schema doc's "NULL for non-TierPoints" note — non-TierPoints rows will show `lifetime = 0`, not `NULL`.

**Action confirmed:** add `lifetime` to:
- `dags/create_tables/sql/loyalty/create_account_balance_ext.sql`
- OC config `account_balance` entry (if cols enumerated)
- `dags/dbt/models/loyalty/source/account_balance.sql`

No Suneel confirmation needed — column is there and column type is `numeric` (unqualified precision in `information_schema`; likely `NUMERIC(18,6)` per doc).

### Q4 — Any new columns on `transaction`? **RESOLVED (no new tier-specific columns)**

Ran the discovery DAG. `test_transaction` has the same 22 columns already documented. No tier-only columns added. Downstream tier ledger will filter existing rows on `program_id = 2` (schema doc enum F8).

### Q4b — NEW: undocumented columns to ask about

Discovery surfaced a few PG-vs-doc deltas:
- **`test_tier_account_override.rollover_tierpoints`** (numeric NULL) — present in PG but NOT in schema doc. Coexists with `tier_points_on_rollover`. Ask Suneel: rename in progress? Two separate fields? Which is authoritative for downstream?
- **`test_tier_override_configuration.expires_at`** — documented in schema doc's newer section but NOT PRESENT in dev PG. Ask if column is coming.

### Q5 — Cutover date + coordination

- Target prod cutover date?
- Same pattern as OneCredits: merge dormant to main, then 2-line flip PR at cutover?
- Loyalty team's migration for prod PG — same day / earlier / different mechanism?

### Q6 — Historical data at cutover

- Will loyalty team backfill Tier Points history from Loyalty Cloud into the new schema at prod cutover?
- Or will Tier Points tables start empty at cutover and accumulate going forward?
- Affects our backfill flow (empty backfill still fine; historical backfill means bigger first-run volume).

## For analytics engineer

### Q7 — Downstream tier points ledger

- Are you planning a `tier_points_loyalty_analytics_ledger` sibling to `one_credits_loyalty_analytics_ledger`?
- Same collaboration pattern (you add your rewrite to our shared feature branch)?
- What existing tier points reporting/models will need to be updated to source from the new tables? (There's `models/loyalty/fanatics_one/tier_points_ledger*.sql` — presumably these ref the Loyalty Cloud stage today. Do they need Jinja conditional treatment for pre-cutover vs post-cutover?)

### Q8 — Existing Loyalty Cloud tier points path

- How does tier points currently flow? Presumably via `loyalty__loyalty_stage` sources (LOYALTY_STAGE schema in Snowflake, sourced from Salesforce Loyalty Cloud via Data Cloud).
- Which existing dbt models will need to be rewritten to use the new bucket-model tables at cutover?
- Same "keep OLD branch + add NEW branch with Jinja conditional" pattern?

### Q9 — Downstream tier points footprint (blast-radius scope)

Verified 2026-07-13 that tier points has a MUCH larger downstream footprint than OneCredits did. Grep in `fes-airflow/dags/dbt/models/` shows:

**Fanatics One layer**:
- `tier_points_ledger.sql` (v1, still exists)
- `tier_points_ledger_v2.sql` (current primary)
- `tier_points_ledger_fbg.sql` (fbg-filtered variant)
- `tier_points_overrides_v2.sql`
- `tier_points_overrides_fbg.sql`
- `tier_points_overrides__placement.sql`
- `tier_points_overrides__invite_only.sql`
- `tier_points_status_match_earned_points.sql`
- `metrics/tier_points_ledger_fbg_metrics.sql`
- `metrics/tier_points_overrides_fbg_metrics.sql`

**Cortex layer**: `loyalty_cortex_tier_points_ledger_v2_v.sql`, `loyalty_cortex_tier_points_overrides_v2_v.sql`
**CDE layer**: `cde_tier_points_ledger.sql`, `cde_tier_points_overrides.sql`, plus metrics
**Enterprise metrics**: `enterprise_metrics_cortex_tier_points_ledger_v2_v.sql`
**fes_users (analyst-owned)**: `challenge_with_fone_tier`, `ob_microtier`, `f1_points_tier_members_pacing`, `f1_loyalty_tier_members_pacing`, `mvcs_by_tier`

Coordinate with AE on:
- Which of these need the Jinja-conditional OLD/NEW branch treatment at cutover?
- Which are safe to leave sourcing from Loyalty Cloud stage (if Loyalty Cloud continues to receive tier points writes during a parallel-run period)?
- Are `tier_points_ledger` (v1) and `tier_points_ledger_v2` both consumed downstream, or is v1 already dead-code?
- Are `tier_points_overrides` and `tier_points_overrides_v2` both live?

### Q11 — ~~`account_metadata` — new table, in-scope?~~ **RESOLVED (not yet in dev PG)**

Discovery DAG confirmed `test_account_metadata` does NOT exist in dev PG. Schema doc is ahead of PG. Skip for now. Add to future-work watchlist — if the loyalty team creates it later, revisit ingest need.

### Q10 — Tier points existing test setup

For OneCredits, we had no legacy ledger to preserve — OneCredits was NEW. For TierPoints, there's a rich live path already. Ask AE:
- Do you want to run a shadow/dev validation of the new bucket-model tier ledger against the existing Loyalty Cloud tier ledger? (Row-count parity, sum parity, per-user reconciliation?)
- If yes, we should build the new tier ledger model early to give validation runway before cutover.

### D1 — Toggle: reuse `oc_ingest_live` or add `tp_ingest_live`? **DECIDED**

**Decision (2026-07-13): separate `TP_INGEST_LIVE` + `tp_ingest_live`.**

Verified in `configs.py`: `OC_INGEST_LIVE = get_value_for_env(dev=True, prod=True)`. The OC toggle is now permanently on in both envs post-OneCredits-cutover. Reusing it is structurally impossible:
- Can't deploy Tier Points dormant to prod without also disabling OneCredits ingest (rollback risk).
- Renaming the OC toggle would require rewriting all OneCredits Jinja conditionals — churn for no benefit.

Separate toggle is not a design choice; it's the only viable path. Move to implementation.

### D2 — Config list: extend `OC_POSTGRES_TABLE_CONFIGS` or add `TP_POSTGRES_TABLE_CONFIGS`? **DECIDED**

**Decision (2026-07-13): add `TP_POSTGRES_TABLE_CONFIGS`.**

Follows from D1. New toggle → new list. Symmetry with OC. Keeps the two program migrations reviewable in isolation. Post-cutover we can consider a cleanup PR to merge lists if we want, but not now.

**Special case**: `account_balance` already ingests via the OC config with `lifetime` missing. Either:
- (a) Add `lifetime` column to the shared OC `account_balance` config (touches OneCredits ingest — small blast radius since it's just an added column).
- (b) Keep TP config disjoint, don't touch OC config.

Recommend (a) — the column exists in prod PG already; projecting it costs ~nothing and avoids two configs owning overlapping tables. **But** confirm with Suneel that adding a column projection to an existing incremental ingest won't retroactively re-ingest old rows or otherwise misbehave.

### D3 — Naming for the tier ledger model

- `tier_points_loyalty_analytics_ledger` matches OneCredits sibling naming.
- Confirm with AE what they want.
