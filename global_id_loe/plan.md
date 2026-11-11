# Plan — LOE breakdown & estimate

Goal: high-level Confluence doc: per-surface change areas + headline
**"X engineers for X months"**. Detail lives here; the doc stays basic.

## Framing assumption that drives the number
The `private_fan_id` identity/mapping layer **already exists** in all three surfaces
(see `findings.md` → "Biggest single finding"). So this is a **re-keying + cutover**
effort, not a build-identity-resolution effort. The cost is breadth (many models/views)
and **cross-team coordination**, not novel engineering.

## Per-surface change areas & sizing

### 1. Ingestion — `fes-airflow` — MEDIUM
Change areas:
- Route loyalty Postgres ingest to carry/emit `private_fan_id` (via existing map) instead
  of raw `loyalty_id` as the downstream key (`configs.py`, 13+ tables).
- Update Tiger / Commerce / Salesforce / TD / fanapp export queries to resolve
  `tenant_fan_id → private_fan_id` (join through existing maps).
- Verify/scale the mapping DAGs (`loyalty_id_export.py`, martech/profile maps); reconcile
  fanflow backfill `PRIVATE_FAN_ID` hardcoding.
- Backfill / dual-run window.
**Size: ~2 engineers × ~1 month.**

### 2. Data shares — `fanapp-terraform` — LARGE (coordination-bound)
Change areas:
- Edit ~60 explicit-column secure views across 4 shares (FBG, Collectibles, FMX, FBG PII)
  to project `private_fan_id` in place of `tenant_fan_id`.
- Lockstep coordination with 4 external consumer teams (their SQL/BI must change together).
- Dual-expose both IDs during transition; grants/share validation; consumer sign-off.
**Size: ~1–2 engineers × ~2 months** (most of it is coordination + safe cutover, not code).

### 3. dbt models — `dbt-fes-ae` — LARGE
Change areas:
- Unify `private_fan_id` production in fangraph staging; collapse `fan_id_tenant_map` +
  `loyalty_account_tenant_map` into a central PFI mapping.
- Re-key ~169 models: joins (~52), partition/group-by (~36), and `unique_key`/incremental
  merge configs — highest touch in fangraph, loyalty/tier-points, fanapp reporting.
- Retarget downstream marts to `pfi_*` instead of mid-layer lookups; update tests.
- Full-refresh/validation of incremental models whose keys change.
**Size: ~2 engineers × ~2–3 months** (staging re-key is contained; mart propagation is the long pole).

## Sequencing
Ingestion lands `private_fan_id` → dbt re-keys → shares expose → consumers cut over.
Surfaces overlap but shares can't complete until dbt marts are re-keyed. A dual-run
(carry both IDs) transition is favored — several objects already carry both.

## Headline estimate (for the Confluence doc)
**≈ 2–3 engineers for ≈ 3–4 months**, as a coordinated, sequenced effort with a dual-run
transition. Lower end if consumers cut over quickly and we accept staged delivery; higher
end driven almost entirely by **downstream consumer coordination on the data shares**, not
by our own code. Materially cheaper than a from-scratch identity migration because the
`private_fan_id` mapping already exists across all three surfaces.

_(Rough raw sum ≈ 5 eng-months ingestion+... — the 3–4 month calendar figure assumes the
three surfaces run partly in parallel with a small team, not strictly serial.)_
