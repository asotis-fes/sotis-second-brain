# Discoveries & Ruled-Out Hypotheses

## Confirmed findings (with evidence)

| # | Finding | Evidence |
|---|---------|----------|
| 1 | July spike is real but tiny share | $692k null-earn vs $54.3M total burned = **1.28%** (baseline ~0.3–0.4%) |
| 2 | Driven by **value**, not volume | rows 14.9k→20.7k (+39%), but avg burn $16→$33; dollars +185% |
| 3 | Concentrated in time | daily spikes **Jul 12 ($167k), 13 ($83k), 1 ($77k), 8 ($54k), 14 ($40k)**; rest flat ~$5–20k/day |
| 4 | Concentrated in **one opco** | tenant `100026`/site `610942` = **$372k / 169 rows / 19 accts** (54% of July). Next: `100002`/`608111` = $207k / 13.3k rows (small-dollar baseline) |
| 5 | Burns ARE matched (not orphaned) | **100%** of July null rows have `earn_txn_id NOT NULL` (`EARN_UNMATCHED=False` for all 20,690 rows) |
| 6 | Matched "earn" has **no `ADD` row** in the ledger | 0 of 94 distinct earn IDs have an `ADD` record in `loyalty_analytics_ledger` |
| 7 | In fanflow source, those IDs are **voided authorizations** | only `AUTH` + `VOID_1` (type `AUTH`), no `ADD`/`CAPTURE`; `site_id` **populated**; dates Jun 29–Jul 30 |
| 8 | Null is **deterministic** from enrichment | `loyalty_analytics_ledger_stage.sql:451-456` stamps `earn_*` **only** `IFF(STARTSWITH(txn_status,'ADD'), …, NULL)` |
| 9 | Burn-side mapping is correct | site `610942` → tenant `100026` present in `mde.mde_core.site_id_tenant_id_map` |
| 10 | Onset aligns with tenant `100026` | not in named `tenant_id_*` vars in `dbt_project.yml`; steady since Jan, spiked July on volume |

## Fanflow `tenant_id` DQ finding (asked: "does fanflow null a column scylla would have?")

- **YES, fanflow nulls `tenant_id` on most earn `ADD` events.** For the 19 affected accounts: **191,651 of 219,669 (87%)** ADD earns have `tenant_id = NULL`, `site_id` populated.
- **BUT it's compensated downstream** — the ledger recomputes `tenant_id = COALESCE(map.tenant_id, tenant_id_commerce)` from `site_id` via `mde.mde_core.site_id_tenant_id_map` (`loyalty_analytics_ledger_stage.sql` `cte_ledger_tenant`). That's why only 1.28% of burns go null, not 87%.
- **So null fanflow `tenant_id` is NOT the direct cause** of these burns' null `earn_tenant_id` — the map already backfills it. The direct cause remains: matched "earn" has no `ADD` row (Findings 6–8).
- **Scylla `temp_transaction_fix` is not involved** — 0 rows for these 19 accounts; and it only feeds the *balance* stage, not the earn-burn/ledger path.
- **Latent risk worth its own ticket:** the fanflow null-`tenant_id` is masked only by the site map. Any earn with a missing/unmapped `site_id` would surface as null tenant.
- **Caveat:** if prod `loyalty_analytics_ledger` is still Scala-produced (`fes-snowpark`) and uses raw fanflow `tenant_id`, this could shift — but the 1.28% (not 87%) null rate implies the dbt map-recompute path is live.

## Late-arrival & cross-source (Scylla) check — both ruled out (2026-08-07)

Hypothesis tested: the real `ADD` arrived *after* the UDTF ran (so it matched a void-auth), or the `ADD` lives in
the previous/external ledger source (Scylla) that's stale and unrefreshed.

- **Late arrival — NO.** Of the 94 null burns (site 610942, July), **94/94 have a real FIFO-eligible `ADD` earn**
  for the account in fanflow (created before the burn, not expired), and **0/94 arrived late** (fanflow `_INSERT_TS`
  within the matcher window). Real earns were present on time. *(Caveat: existence+eligibility confirmed, not
  unconsumed balance at burn time — so "matcher ignored an available earn" vs "fell back after exhaustion" is open,
  but it's a matcher question either way.)*
- **Hiding in the Scylla source — NO.** Refreshed `LOYALTY.LOYALTY_STAGE.LOYALTY_TRANSACTION_RAW` (external table over
  `…/scylla_replication/…`, S3/parquet) via `ALTER EXTERNAL TABLE … REFRESH` on `FDE_DEVELOPER_2XL_WH` (succeeded —
  no ownership block). It *was* stale; post-refresh it has data through **2026-08-07** (490M+ June-onward rows).
  The 94 matched IDs in Scylla show the **same lifecycle as fanflow — only `AUTH` + `VOID_1` (type 1), no `ADD`**,
  tenant null / site populated. The `ADD` is not hiding in the old source.
- **Conclusion:** not a data-availability, late-arrival, or stale-external-table problem. The burns were linked to
  authorizations while real earns were present → **matcher-attribution issue**. Refresh + replay does NOT fix it
  (UDTF is deterministic); only the matcher logic change does.
- `_INSERT_TS` caveat: the fanflow table `FANFLOW.ACCOUNT_EVENTS.loyalty_transaction_successful__account` was
  backfilled 2026-06-09, so `_INSERT_TS` is a clean arrival signal only for post-June rows (fine for the July burns).

## Ruled out

| Hypothesis | Why ruled out |
|------------|---------------|
| **Missing / late fanflow earn data** (original guess) | The transactions ARE in fanflow (`AUTH`+`VOID_1`, `site_id` populated). Nothing missing. (Finding 7) |
| **Repeat of Jan-2026 missed-redeems incident** (ENTDATA-1893) | That was late earns breaking FIFO → *unconnected* burns. Here burns are 100% *matched* (Finding 5). Different failure. |
| **Truly unconnected burns** (`earn_txn_id` NULL) | Zero unconnected — all matched (Finding 5). |
| **Self-healing gap that a re-run fixes** | Re-run can't create an `ADD` row that never existed (Finding 6). |
| **Site not in the site→tenant map** | `610942` is mapped correctly (Finding 9); and the burn side isn't null anyway. |
| **`unconnected_earn` dropping site/tenant is THE cause** | Real (it does hardcode NULL) but **not the driver here** — these earns have no `ADD` at all; the `ADD`-only enrichment (Finding 8) is the operative cause. Still worth fixing (defense-in-depth). |

## Confirmation round (2026-08-06) — A, B, C

- **A (fix-gating): the matched "earn" is a same-opco voided authorization, NOT a real earn.** For 166/169 the matched `earn_txn_id` has `earn_site`/`earn_tenant` = the **burn's own** site/tenant (610942/100026); statuses are `AUTH`+`VOID_1` only; 41 share the burn's `order_id`. ⇒ the FIFO matcher is linking burns to voided redemption authorizations. **This kills the COALESCE `ADD`→`AUTH` fix** — it would stamp `earn_tenant_id` = burn tenant (fabricated same-opco earn).
- **B: prod is dbt, not Scala.** `LOYALTY_ANALYTICS_LEDGER` carries the dbt signature (`PK`, `ICEMAKER_UPDATE_TS`, `_INSERT_TS`, `_UPDATE_TS`, `EARN_TENANT_ID`, `EARN_SITE_ID`, `ADD_ACTIVITY`); airflow `lids_loyalty_report.py` waits on dbt Cloud job `dbt_loyalty`. Fix location `loyalty_analytics_ledger_stage.sql` confirmed; `fes-snowpark` Scala is legacy.
- **C: one root cause across all months.** May baseline: 26,461 distinct null-earn IDs, **0 with an `ADD` row** (all present in ledger as non-ADD) — identical to July. July is just higher volume/value of the same pattern.

## UDTF source located — the mechanism, confirmed in code (2026-08-06)

`connect_loyalty_transactions` = Python UDTF `LoyaltyProcessor`, source documented in-repo:
**`docs/runbooks/fes-data/redeems-incident-repair.md:756-917`**.

- Line 789-790 `void_auth_filter`: `loyalty_txn_type == 1 AND "VOID" in txn_status` (a voided authorization).
- Line 795-796 `is_matchable_earn`: `(earn_filter … ) OR void_auth_filter(t)` → **voided authorizations are deliberately in the earn pool.**
- Line 851-867 `connect()`: emits a `REDEEM` row with `loyalty_txn_id = earn['loyalty_txn_id']`; line 857 sets `l_txn_type = burn type (1)` when the "earn" is a void-auth (not a real ADD earn).
- **Result:** burns get linked to void-auths → REDEEM rows whose "earn" has no `ADD` record → null `earn_tenant_id`. Matches the measured fingerprint exactly (AUTH→VOID_1, same site, type 1, no ADD).
- **These null-earn rows are authorization/void netting artifacts, NOT real earn→burn consumption.** Intentional logic, not a crash — but questionable to count as "burned FanCash."

## Site 610942 is AUTHORIZATION-ONLY — the null "burns" aren't real (2026-08-06)

Daily fanflow (`FANFLOW.ACCOUNT_EVENTS.loyalty_transaction_successful__account`) for site 610942, Jun 15–Jul 31:
- **`ADD` earn rows = 0 every day. `CAPTURE` (completed burn) rows = 0 every day.** Only `AUTH` + `VOID_1`.
- ⇒ the site never emits a real earn or a captured burn. The UDTF puts void-auths in **both** the earn pool
  (`is_matchable_earn`) and burn pool (`b_list`), so it manufactures `REDEEM` rows purely from auth/void holds.
- **Consequence:** the null-`earn_tenant_id` "burned FanCash" at this site has no real earn AND no captured burn
  behind it — it's authorization-hold netting noise. A large part of Caroline's $692k (esp. the $372k here) is
  **not real burned FanCash.**
- **July timing explained:** void-auth *counts* in July are normal (June had 22- and 19-count days). The spike is
  *dollars* — a few large-value auth holds on **Jul 12–13** (~$11–13k each). Not a systemic change.

## `loyalty_redeem_iceberg` — retired OUTPUT export, not in the mapper lineage

- **It's an OUTPUT write-back, not an input.** External Glue iceberg table (`ecomm_analytics_glue_fes_loyalty_prod` /
  `fes_loyalty.loyalty_redeem`), created by `fes-airflow/dags/create_tables/sql/loyalty/create_loyalty_redeem_incremental.sql`.
- **Frozen on 2026-06-29** (`max icemaker_update_ts = 2026-06-29 18:00`, max creation_time 6/29; 5.57B rows, 2024-02-19→6/29).
  Almost certainly decommissioned at the loyalty redeem MWAA→dbt Cloud (`dbt_loyalty`) cutover.
- **The prod mapper does NOT read it.** Lineage: `loyalty_earn_burn_mapper ← …_stage ← loyalty_analytics_ledger ←
  …_stage ← loyalty_redeem ← redeem_matches ← new_ledger_txn (FANFLOW)`. `loyalty_redeem.sql` = `FROM ref('redeem_matches')`.
  `loyalty_redeem_iceberg` referenced by 0 prod models (only the source decl in `loyalty.yml:27`).
- ⇒ **Iceberg staleness is a red herring for the null-earn issue.** The UDTF runs on fanflow, not the iceberg.
- **Separate side-finding (worth flagging):** if any external/legacy consumer still reads the `fes_loyalty.loyalty_redeem`
  Glue table, they've had data frozen since 2026-06-29. Unrelated to Caroline's issue, but a possible orphaned export.
- Architecture: **old = Scala/MWAA + iceberg export; new (June cutover, dbt Cloud) = fanflow + UDTF reconstruction.**

## ⚠️ One Credits is NOT related (corrected 2026-08-06)

- **One Credits is a SEPARATE loyalty program from FanCash.** `LOYALTY.ONE_CREDITS.*` is its own program's data,
  not a parallel FanCash earn-burn implementation. The `..._loyalty_analytics_ledger` naming caused an earlier
  mis-identification.
- Retracted: "adopt One Credits linkage as the FanCash fix" and "the 2026-07-06 One Credits cutover caused the
  July FanCash spike." Do not use `ONE_CREDITS.*` for FanCash earn-burn reasoning.
- **The real "ingested source we may not be using"** (per owner hint, UNVERIFIED) is the FanCash service's own
  redeem→earn linkage: `LOYALTY.LOYALTY_CORE.loyalty_redeem_iceberg` / `loyalty_redeem`. Investigate whether it
  carries authoritative earn attribution vs. the FIFO reconstruction. **Do not assume — confirm with owner.**
- July timing for tenant 100026 (Jul 12–14) is **unexplained**; the void-auth mechanism explains the class of null
  rows, not the July spike.

## How the pipeline works (for context)

- **FIFO matcher:** `redeem_matches.sql` calls Snowpark UDTF `connect_loyalty_transactions(...) OVER (PARTITION BY loyalty_account_id)` → emits `REDEEM` / `EARN_UPDATED` / `UNCONNECTED_BURN` / `LEDGER`.
- **Self-healing loop:** every run re-feeds `unconnected_earn` + `unconnected_burn` sources (no date filter) so unmatched txns keep retrying. New earns enter only within `redeem_lookback_days = 2` on `creation_time`.
- **Enrichment:** `loyalty_analytics_ledger_stage.sql` builds REDEEM ledger rows; `earn_tenant_id`/`earn_site_id` come **only from the earn `ADD` row**, and `tenant_id` is resolved via `mde.mde_core.site_id_tenant_id_map`.
- **Mapper:** `loyalty_earn_burn_mapper_stage.sql` aggregates REDEEM ledger rows → `loyalty_earn_burn_mapper` (clone).

## Loose ends / not fully closed

- **Why** tenant `100026` earns present as `AUTH`/`VOID` with no `ADD` — lives in the compiled UDTF + upstream loyalty service; not resolvable from dbt alone.
- Whether Scala (`fes-snowpark/LoyaltyAnalyticsLedgerFullRefresh.scala`) or dbt currently produces prod `loyalty_analytics_ledger` — dbt models use prod `FDE_MWAA_*` warehouses (migration appears live), but not verified end-to-end.
