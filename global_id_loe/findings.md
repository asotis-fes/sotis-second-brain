# Findings — how the IDs are used today

Discovery via parallel Explore across the three local repos (2026-08-25). Distilled;
file paths kept for attribution.

## ID glossary
- **`private_fan_id`** — the proposed "global id" (FBG-wide fan identity).
- **`tenant_fan_id`** — per-tenant fan identifier; today's inbound/outbound id for most
  non-loyalty flows (Tiger, Commerce, Salesforce, fanapp, shares).
- **`loyalty_id`** — loyalty-program identifier; primary key for loyalty Postgres ingest
  and loyalty dbt source models.

### 🔑 Biggest single finding — the mapping already exists
A `private_fan_id` identity/resolution layer is **already built and operational** in all
three surfaces. This is the dominant cost-reducer: we are *re-routing through existing
maps*, not building identity resolution from scratch.
- **fes-airflow:** `dags/loyalty/loyalty_id_export.py` (daily `loyalty_id ↔ private_fan_id`
  map → S3), plus landing maps `create_loyalty_private_fan_id_map_ext.sql`,
  `create_martech_private_fan_id_map_ext.sql`, `create_profile_id_private_fan_id_map_ext.sql`.
  Some pipelines (e.g. XtremePush) already join through these maps.
- **dbt-fes-ae:** `models/fangraph/private_fan_id/` (18 `pfi_*` models producing
  `private_fan_id` as grain; `pfi_customer_mart.sql`, `pfi_tenant_id_mapping.sql`), plus
  macros `lookup_loyalty_tenant_fan_id.sql`, `translate_tenant_fan_id.sql`. A parallel
  `private_fan_id` migration is already underway (~210 files reference it).
- **fanapp-terraform:** several secure views already expose `private_fan_id` (or alias
  `private_fan_id AS fan_id`), so the pattern is proven.

## 1. Ingestion — `fes-airflow` — blast radius: **MEDIUM**
- **~42 files across 8 domains.** Concentrated in two pipelines; the rest are export
  consumers needing SELECT/join tweaks, not re-architecture.
- **Inbound source of `loyalty_id`:** loyalty Postgres→S3 ingest (`dags/loyalty/configs.py`
  defines 13+ tables keyed on `loyalty_id`: `transaction`, `auth_hold`, `user_bonus`, …).
- **Inbound `tenant_fan_id`:** Tiger (`firebase_mp_export.py`, `meta_capi_export.py`),
  Commerce (`sql/merge_ids.sql`, `amplitude_events_correction.sql`), Salesforce SFMC CSV
  import (`sql/import_optin_preferences.sql`), Treasure Data, fanapp, DSR — each keeps its
  own column independently, so **the two IDs are largely separable by pipeline.**
- **Resolution engine:** `dags/loyalty/sql/export_fan_id_mapping.sql` builds the master
  `loyalty_id → private_fan_id` map via FDE identity tables.
- Watch-out: several fanflow backfill tables hardcode `FI AS PRIVATE_FAN_ID` — verify alignment.

## 2. Data shares — `fanapp-terraform` — blast radius: **LARGE**
- **~60 secure views across 4 consumer shares.** All under
  `root/fes-data/snowflake-v2/outbound_shares-*.tf`. Views use **explicit named columns**
  (not `SELECT *`), so each needs a hand edit.
- **No `loyalty_id` outbound** — only `tenant_fan_id` and `private_fan_id` in scope here.
- Affected shares: **FBG** (`outbound_shares-fbg_secure_views.tf`, 46 views, 27 tenant_fan_id
  refs — all LOYALTY_*, TIER_POINTS_*, account-event views), **Collectibles**
  (`...collectibles_secure_views.tf`, 17 views), **FMX** (`...fmx_secure_views.tf`, 4 loyalty
  views), **FBG PII** (`...fbg_pii_secure_views.tf`, FANGRAPH_PII with `*_tenant_fan_ids` cols).
- Some views already expose **both** IDs (FANATICS_ID_DSR_DELETES, TASKS_CREATED_DSR,
  REGISTER_ACCOUNT_EVENT) and some alias `private_fan_id AS fan_id` — reduces friction.
- **Dominant cost = downstream coordination:** 4 external consumer teams read these daily;
  their SQL/BI must change in lockstep. This is the main driver of the "LARGE" rating.

## 3. dbt models — `dbt-fes-ae` — blast radius: **LARGE**
- **~169 SQL models** reference `tenant_fan_id` / `loyalty_id`. Concentrates in source/
  staging but propagates to ~100+ marts.
- **Highest touch:** fangraph (~67 files, `fangraph_fan_id_tenant_map_*.sql`), loyalty
  (~31 files incl. `models/loyalty/fanatics_one/` tier-points ×18, `models/loyalty/source/`
  keyed `unique_key: loyalty_id`, `models/loyalty/fancash/loyalty_account_id_fan_id_tenant_map.sql`),
  fanapp reporting (~24), enterprise_metrics (~10), cde (~8).
- **Usage patterns that make re-keying non-trivial:** ~52 models JOIN on `tenant_fan_id`
  (4 on `loyalty_id`); ~36 PARTITION/GROUP BY these IDs; several `unique_key`/incremental
  merge configs keyed on them (`fde.yaml` `['tenant_fan_id','tenant_id']`,
  `tiger_exports.yaml` `['fanapp_tenant_fan_id','event_name']`, `source.yaml` `loyalty_id`).
- **Critical path:** unify `private_fan_id` production in fangraph staging → collapse
  `fan_id_tenant_map` + `loyalty_account_tenant_map` into central PFI mapping → retarget
  downstream joins to `pfi_*` marts instead of mid-layer lookups.

## Cross-surface dependency & open questions
- **Natural sequence:** ingestion lands `private_fan_id` → dbt re-keys models → shares
  expose it → consumers cut over. Shares can't finish until dbt marts are re-keyed.
- 1:1 hard cutover vs. transition carrying both IDs? (Several objects already carry both,
  which favors a dual-run transition and lowers risk.)
- Is identity resolution fully owned upstream, or do we harden/scale the existing maps?
  (Maps exist but were built incrementally — may need consolidation, per dbt critical path.)
