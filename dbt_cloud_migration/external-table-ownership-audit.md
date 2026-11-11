# External-Table Ownership, Auto-Refresh & Grant Audit (post-cutover)

**Status:** in progress · **Started:** 2026-07-23 · **Last updated:** 2026-07-24
**Owner:** alex.sotis · **Related:** [[permissions.md]], [[manual_grants_2026-07-22.md]], [[pr-tracker.md]], [[post-cutover-watch-list.md]]
Memory note (global): `reference_external_table_refresh_ownership` in the auto-memory dir.

> Keep this file updated as work progresses — source of truth across sessions. Treat `/compact` and `/clear` as checkpoints, not losses.

## ⭐ WEEKEND-SAFETY BRIEF (2026-07-24) — do only these two; everything else is post-weekend
Core fix is DONE & verified (external tables → AR_FES_EXT_TABLE_OWNER, dbt refreshes succeeding, grants preserved). To keep dbt/Airflow from failing over the weekend:
1. **Run AUTO_REFRESH re-enable** on the 27 tables the transfers disabled (16 external + 11 COMMERCE.SOURCE iceberg — see §4.1 list). Run as `ACCOUNTADMIN` (`ALTER {EXTERNAL|ICEBERG} TABLE IF EXISTS <fqn> SET AUTO_REFRESH = TRUE;`). ~16 have no dbt-refresh backup → would go stale otherwise.
2. **Merge PR #2966** (https://github.com/fanatics-gaming/fanapp-terraform/pull/2966) — codifies dbt's ecomm iceberg integration/volume USAGE (currently manual drift) so a `snowflake-v2` apply can't revoke it. Idempotent; depends_on part is a plan no-op (no ownership churn). Supersedes #2950 + #2962 (both closed).

**DO NOT touch over the weekend:** `SVC_DBT_CLOUD_ROLE → SYSADMIN` and `→ FAN_DATA_EXCHANGE_CDE_STAGE_RW` — live, harmless, TF won't manage them; revoking is the only thing that could break something. `dbt → CDE_STAGE_RW` is a redundant leftover (the CDE_STAGE subordination is covered by the codified `AR → CDE_STAGE_RW`), but leave it. Post-weekend cleanup only.

---

## 0. TL;DR / current state

- Root problem: **Snowflake external (and iceberg) tables can only be REFRESHed by their OWNER.** Pre-migration one role (MWAA, running dbt-core) created + owned + refreshed them. dbt Cloud split the refresh onto `SVC_DBT_CLOUD_ROLE`, colliding with MWAA (creator via `fes-airflow` `create_tables` DAGs). There is no grantable REFRESH/MODIFY privilege — only OWNERSHIP (verified: [ALTER EXTERNAL TABLE docs](https://docs.snowflake.com/en/sql-reference/sql/alter-external-table)).
- Fix (Hemanth's design, hardened by us): a shared account role **`AR_FES_EXT_TABLE_OWNER`** owns all external tables across 9 DBs (current + future), granted to both `MWAA` and `DBT_CLOUD` service **users** via `extra_roles`; both inherit it because the users have `DEFAULT_SECONDARY_ROLES=['ALL']` (verified). So both can create AND refresh.
- **PR #2960 (fanapp-terraform) — MERGED 2026-07-24 15:46.** Applied to **prod** (there is NO separate dev snowflake-v2 root; `terraform/fes-data/snowflake-v2/` has only `prod/infra`; modified schemas COMMERCE.SOURCE/LOYALTY.SOURCE/CDE.CDE_STAGE are production).
- **APPLY ATTEMPT 1 (run 30106730590, 2026-07-24 16:07) — FAILED on `CDE.CDE_STAGE` ONLY** (`003514`). Root cause: **Terraform ordering race** — the `grant_ownership["CDE.CDE_STAGE"]` (all + future) ran in parallel with the `fes_ext_table_owner_to_cde_stage_rw` subordination grant, so the transfer executed before the grant landed. COMMERCE.SOURCE succeeded (its `→SYSADMIN` grant finished earlier). **~85/86 external tables transferred OK with grants preserved (COPY verified on COMMERCE.SOURCE.CRM_ACCOUNT_EXT).** Both subordination grants are now **live in Snowflake** (`AR_FES_EXT_TABLE_OWNER` inherited by SYSADMIN + FAN_DATA_EXCHANGE_CDE_STAGE_RW). CDE.CDE_STAGE.LOYALTY_ACCOUNT_EXT unharmed (still SVC_DBT_CLOUD_ROLE-owned, still refreshing).
- **FIX: just re-run the apply** — the subordination grants exist now, so the CDE.CDE_STAGE transfer will pass. **Permanent fix (follow-up PR):** add `depends_on = [snowflake_grant_account_role.fes_ext_table_owner_to_sysadmin, .fes_ext_table_owner_to_cde_stage_rw]` to both `snowflake_grant_ownership` resources so from-scratch applies don't race.
- **Immediately after the re-run completes:** re-enable AUTO_REFRESH (§4.1), then run verification queries (§7).
- **Biggest open item:** iceberg tables are NOT covered by the ownership PR (§4 item 1) — same bug, one object-type over.

---

## 1. Timeline of what happened (why current state looks like it does)

- **Pre-migration:** MWAA `create_tables` DAG does `CREATE OR REPLACE EXTERNAL TABLE` + `ALTER … REFRESH` as MWAA; dbt-core also ran under MWAA's role → one role owned+refreshed. No ownership transfer → managed-access never triggered.
- **~07-22 (migration):** ownership of many external tables moved to `SVC_DBT_CLOUD_ROLE` so dbt Cloud could refresh. For managed-access `CDE.CDE_STAGE`, this worked because the migration ALSO granted `SVC_DBT_CLOUD_ROLE` to the schema owner `FAN_DATA_EXCHANGE_CDE_STAGE_RW` (makes dbt subordinate to schema owner → satisfies error 003514).
- **07-23 ~20:38 (my mistake):** I ran a "FES_INTEGRATIONS over-reach" remediation that transferred 6 dbt-refreshed external tables (SUMMIT.SHOP_REDEMPTIONS_EXT, SUMMIT.INFINITE_REWARDS_EXT, META_ADS.META_AD_COST_DTL_HRLY_EXT, MAGNITE.MAGNITE_PA_HOURLY_EXT, MENTION_ME.REFERRALS_EXT, TICKETMASTER.TICKETMASTER_RAW) to `SVC_MWAA_ROLE`. This **broke dbt's refresh** (dbt lost ownership) → the `dbt_every_3hours` failures. Lesson: refresh-via-pre-hook = legitimate dbt ownership; do NOT flag as over-reach.
- **07-24:** I transferred those 6 back to dbt (COPY). Hemanth built the shared-owner design (#2958) and the REVOKE patch (#2960). We hardened #2960 (below).

---

## 2. The design & the two Snowflake error classes

- `003036` "Dependent grant of privilege 'APPLYBUDGET' … must be revoked first" on GRANT OWNERSHIP → fixed with `outbound_privileges = "COPY"` (= `COPY CURRENT GRANTS`, preserves READ_ONLY/ADMIN grants). **NOT** `REVOKE` (would strip reader grants on ~86 tables until next apply + on every future re-transfer).
- `003514` "Ownership restriction violation in a managed access schema. Grantee need to be a subordinate role of the schema owner." Only 2 managed-access schemas in scope: **COMMERCE.SOURCE** (owner = `SYSADMIN`) and **CDE.CDE_STAGE** (owner = `FAN_DATA_EXCHANGE_CDE_STAGE_RW`). Fix = make `AR_FES_EXT_TABLE_OWNER` subordinate to each schema owner via `snowflake_grant_account_role`:
  - `AR_FES_EXT_TABLE_OWNER → SYSADMIN`
  - `AR_FES_EXT_TABLE_OWNER → FAN_DATA_EXCHANGE_CDE_STAGE_RW` (Option B; user accepted the trade-off that the clean-room role thereby inherits ownership of all shared external tables).
- Rejected approaches: `REVOKE` (strips grants); adding owner to schema `admin_roles` (wrong direction — makes owner a *parent* of `<schema>_ADMIN`, doesn't satisfy 003514); granting whole `SVC_MWAA_ROLE` to `SVC_DBT_CLOUD_ROLE` (privilege-escalation anti-pattern).

---

## 3. PR / commit tracker

| PR | Repo | State | What |
|----|------|-------|------|
| #2958 | fanapp-terraform | MERGED 07-24 00:59 | Create `AR_FES_EXT_TABLE_OWNER`, grant to MWAA+DBT_CLOUD users (`extra_roles`), `grant_ownership` ALL+FUTURE external tables over 9 DBs |
| #2960 | fanapp-terraform | MERGED 07-24 15:46 | outbound_privileges (orig REVOKE). **Our commits:** `9cf39175` REVOKE→COPY; `0e3a500e` revert admin_roles edits + add owner→SYSADMIN & owner→FAN_DATA_EXCHANGE_CDE_STAGE_RW subordination grants |
| #2953 | fanapp-terraform | MERGED 07-23 | dbt Cloud access to COMMERCE iceberg catalog integrations (transactions_db_main_pii, customer_db) |
| #2951 | fanapp-terraform | MERGED 07-23 | dbt Cloud read access to IMPRINT shared DB |
| #2948 | fanapp-terraform | MERGED 07-22 | dbt Cloud USAGE on 7 sized `FDE_MWAA_*` warehouses |
| #2950 | fanapp-terraform | **OPEN (asotis-fes)** | Grant dbt Cloud + FES_ANALYST on Ecomm iceberg integrations — **this is the drift-closure PR to finish (§4 item 3)** |
| #2956 | fanapp-terraform | CLOSED (not merged) | Alvin's "MODIFY grants for external tables" (superseded) |
| dbt-fes-ae #28 | dbt-fes-ae | (earlier) | fanflow revert + 2XL (separate workstream) |

Design branch: `fix-ext-table-ownership-revoke-grants`. Files touched (net vs main): `db-fes_integrations.tf` (COPY on 2 grant_ownership), `persona-functional_roles.tf` (2 subordination grants). `db-cde.tf`/`db-commerce.tf` net-unchanged.

---

## 4. The four-part audit — findings & actions

### 4.1 Auto-refresh (turned off by ownership changes) — ACTION REQUIRED
- Ownership transfer sets `AUTO_REFRESH=FALSE`. Confirmed **0 prod external tables currently carry an auto-refresh notification** → it's off fleet-wide. Tables relying on auto-refresh with no dbt manual refresh are **going stale**.
- fes-airflow defines **27 tables** with `AUTO_REFRESH = TRUE` (source of truth):
  - **11 iceberg** (all `COMMERCE.SOURCE`): ADOBE_CLICKS_ICEBERG, ADOBE_OPENS_ICEBERG, EXP_PROD_FANKEY_MAP_ICEBERG, EXP_PROD_FILTERED_PAGE_VIEW_ICEBERG, FANAPP_DAILY_PRODUCTS_ICEBERG, FANAPP_WEEKLY_TRADING_ICEBERG, FES_DAILY_VISITOR_ACTIVITY_LEADING_INDICATORS_ICEBERG, SES_CLICKS_ICEBERG, SES_OPENS_ICEBERG, UNIFIED_SEND_LOG_ICEBERG, WEEKLY_TRADING_ICEBERG
  - **16 external:** FES_INTEGRATIONS.GOOGLE_ADS.GAM_REPORT_RAW_EXT, FES_INTEGRATIONS.MAGNITE.MAGNITE_PA_HOURLY_EXT, LOYALTY.SOURCE.{BONUS_EXT,BONUS_REWARD_EXT,BONUS_STEP_EXT,USER_BONUS_EXT,USER_BONUS_REWARD_EXT,USER_BONUS_STEP_EVENT_EXT,USER_BONUS_STEP_EXT,USER_EVENT_EXT}, IDENTITY.SOURCE.{CORE_EXT,FAVORITES_EXT,LOYALTY_PRIVATE_FAN_ID_MAP_EXT,MARTECH_PRIVATE_FAN_ID_MAP_EXT,PREFERENCES_EXT}, XP.SOURCE.CAMPAIGN_ENGAGEMENT_EXT
- **Re-enable syntax (owner or higher):** `ALTER {ICEBERG|EXTERNAL} TABLE IF EXISTS <fqn> SET AUTO_REFRESH = TRUE;` — full block saved at `sql/reenable_auto_refresh.sql` (see §6). **Run AFTER the PR apply** (apply re-disables external ones), as `ACCOUNTADMIN`.

### 4.2 Manual GRANTs missing COPY — CLEAN (no action)
- Audited all GRANT/REVOKE by user ALEX.SOTIS (role SNOWFLAKE-FES-FES_ADMIN) last 3 days. Every successful `GRANT OWNERSHIP` used `COPY CURRENT GRANTS`. The only no-COPY ones **failed** (MAGNITE retry; a `GRANT MODIFY` typo) or were `ON FUTURE` (no current grants to copy → correct). Nothing silently stripped.

### 4.3 Terraform PR to codify manual grants — FINISH #2950 (no new PR)
- **Already codified:** 7 sized `FDE_MWAA_*` WH USAGE (#2948); transactions_db_main_pii + customer_db integration USAGE (#2953); `IMPORTED PRIVILEGES` on SALESFORCE + SALESFORCE_QC (via `read_only_roles` in `db_from_share-salesforce.tf` + `database-from-share` module); external-table ownership (#2958/#2960).
- **The real drift = #2950:** add `dbt_cloud` (+`FES_ANALYST` for exp_prod) to the `roles` list of 5 ecomm iceberg modules in `integrations-commerce.tf`: `prod_exp_prod_db_glue_integration`, `prod_order_intelligence_analytics_db_main_glue_integration`, `prod_crm_iceberg_db_glue_integration`, `prod_crm_iceberg_db_cdm_glue_integration`, `prod_avexp_glue_integration`. The `iceberg-integration` module grants BOTH `EXTERNAL VOLUME` USAGE (`main.tf:50` volume_usage_grant) and `INTEGRATION` USAGE (`main.tf:66` catalog_usage_grant) from the same `var.roles` — so one line per module covers integration + volume.
  - **#2950 needs rebase:** its transactions_db_main_pii/customer_db hunks are now redundant (merged by #2953) — drop them; keep the 5 modules above.
- **Do NOT codify (would orphan grants — TF doesn't manage these objects):** `FDE_MWAA_WH` (base) & `FDE_SNOWPARK_WH` (base) USAGE to dbt (base warehouses not in TF — only sized variants are); `PMG_FANAPP` IMPORTED PRIVILEGES (`PMG_FANAPP` not a TF DB; TF has `PMG`). Confirm if these should be TF-managed separately / if PMG_FANAPP is legacy.
- **Do NOT codify (self-correcting):** all ownership transfers — MWAA/dbt are already `admin_roles` (CREATE TABLE) on those schemas, so ownership re-establishes on `CREATE OR REPLACE` / dbt build. `database-setup` module intentionally doesn't manage per-table ownership. (Groups: MWAA-owned FES_INTEGRATIONS non-external + SHEETZU + SALESFORCE_SALES_CLOUD + LOYALTY.LOYALTY_STAGE.BONUS_FANCASH; dbt-owned COMMERCE.STAGE.* + COMMERCE.SOURCE.*_ICEBERG).

### 4.4 Other permission concerns
1. **🟠 Iceberg tables NOT covered by the ownership PR** (downgraded from 🔴 after investigation). `grant_ownership` uses `object_type_plural = "EXTERNAL TABLES"`; iceberg is a separate object type. **17 iceberg tables in the 9 DBs, ALL currently owned by `SVC_DBT_CLOUD_ROLE`:** CDE.CDE_CORE.ORDER_PAYMENT_ICEBERG; LOYALTY.LOYALTY_CORE.LOYALTY_REDEEM_ICEBERG; COMMERCE.SOURCE ×15 (adobe_clicks/opens, exp_prod_fankey_map, exp_prod_filtered_page_view, fanapp_daily_products, fanapp_weekly_trading, **fan_key_account_map_pii, fan_key_fan_id_map, fan_key_master_pii, unified_fanid_pii** (PII), fes_daily_visitor_activity_leading_indicators, ses_clicks, ses_opens, unified_send_log, weekly_trading).
   - **Key finding: dbt does NOT refresh iceberg tables** — no `ALTER ICEBERG TABLE … REFRESH` anywhere in dbt-fes-ae, and `refresh_external_table` macro only emits `ALTER EXTERNAL TABLE`. So iceberg tables lack the hard refresh-ownership coupling that broke external tables. They rely on `AUTO_REFRESH` (the 11 COMMERCE ones) or are read-only sources.
   - Remaining concern (narrower): they're **MWAA-created** (`create_tables` DAG `CREATE OR REPLACE`) but **currently dbt-owned** — inverted from "creator owns." On the next create-DAG run, MWAA takes ownership (and the transfer disables AUTO_REFRESH). Cleaner end-state: fold iceberg into the same shared-owner role (add an `ICEBERG TABLES` ownership pass — COMMERCE.SOURCE is managed-access, already covered by the SYSADMIN subordination), OR let MWAA own + dbt SELECT. Not an active outage today. NOTE: COMMERCE.SOURCE iceberg auto-refresh is in the §4.1 re-enable list.
2. **🟠 Auto-refresh off fleet-wide** — §4.1, active freshness risk.
3. **🟠 Clean-room grant** `SVC_DBT_CLOUD_ROLE → FAN_DATA_EXCHANGE_CDE_STAGE_RW` (pre-existing migration artifact) — clean-room owner inherits the entire dbt role. Confirm intentional.
4. **🟡 `AR_FES_EXT_TABLE_OWNER` granted to service USERS, not roles** — works only via `DEFAULT_SECONDARY_ROLES=['ALL']`. Consider granting to `SVC_DBT_CLOUD_ROLE`/`SVC_MWAA_ROLE` (roles) for robustness.
5. **🟡 Ownership sprawl + empty-owner tables** — external/iceberg ownership split across SVC_MWAA_ROLE, SVC_DBT_CLOUD_ROLE, FES_DATA_DEVELOPER, ACCOUNTADMIN, AR_FES_EXT_TABLE_OWNER, and some `owner=""` (dropped-role?). Investigate the empty-owner ones.
6. **🟡 dbt has USAGE on `FDE_MWAA_*` warehouses** — cost attribution blur between MWAA & dbt Cloud.
7. **🟠 AUTO_REFRESH vs ownership-transfer-on-create (recurring).** Ownership transfer sets `AUTO_REFRESH=FALSE`. The `future` ownership grant auto-transfers a table to AR on creation — so every time the fes-airflow create_tables DAG runs `CREATE OR REPLACE` on an AUTO_REFRESH=TRUE external table (the 16 in §4.1), the create's `AUTO_REFRESH=TRUE` is immediately clobbered back to FALSE by the transfer. create_tables DAGs are deploy-time (infrequent), so it's not continuous — but auto-refresh dies on every redeploy until re-enabled. Fix options: (a) fes-airflow create SQL re-runs `ALTER … SET AUTO_REFRESH=TRUE` as the new owner after create; (b) exclude AUTO_REFRESH tables from the shared-owner transfer; (c) drop auto-refresh in favor of dbt/manual refresh. Decide before next redeploy of those tables.

### Dev-plan review (run 30106129814, plan job 89524194905)
- `Plan: 34 add / 0 change / 14 destroy`. **Safe** — the 14 destroys are all `external_table_future_ownership[...]` **replacements** forced by adding `outbound_privileges="COPY"` (future grants govern only future tables → recreating touches no existing table, revokes no access). 20 adds = 16 all-ownership transfers (COPY, ~86 tables) + 2 future-ownership (the 2 managed schemas) + 2 subordination grants. Warnings all benign (deprecated `dynamodb_table` backend param, stale preview-feature list, known-after-apply ids, Node20). **It's the PROD root, not dev.**

---

## 5. Key environment / how to run the audit queries

- CLI: `snow sql -c FAN_DATA_EXCHANGE_PROD` (Snowflake CLI). Account VYB11067.
- Env: `set -a && . /Users/alex.sotis/repos/fes-airflow/.env >/dev/null 2>&1; set +a` (has `SNOW_CONN`, dbt cloud token, etc.).
- Warehouse: `USE WAREHOUSE FDE_DEVELOPER_3XL_WH;` (fanflow/large scans need 3XL). Role: `USE ROLE ACCOUNTADMIN;` for full visibility.
- SHOW gotchas: `SHOW EXTERNAL TABLES` / `SHOW ICEBERG TABLES` have **no `auto_refresh` column** — infer auto-refresh from non-empty `notification_channel` (external) / `ALTER … SET AUTO_REFRESH` (both). Iceberg is a separate object type from external.
- query_history: `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (latency ~45min–3h); filter `user_name ILIKE '%ALEX.SOTIS%'`, `query_type IN ('GRANT','REVOKE')`, flag `query_text ILIKE '%COPY CURRENT GRANTS%'`.

---

## 6. Reusable SQL (also see sql/ subdir if written)

### Re-enable auto-refresh (run AFTER apply, as ACCOUNTADMIN) — see §4.1 for full list
```sql
USE ROLE ACCOUNTADMIN;
ALTER ICEBERG TABLE   IF EXISTS COMMERCE.SOURCE.<name>            SET AUTO_REFRESH = TRUE;  -- x11 iceberg
ALTER EXTERNAL TABLE  IF EXISTS <DB>.<SCHEMA>.<name>             SET AUTO_REFRESH = TRUE;  -- x16 external
```

### Verify grant preservation after COPY transfer (spot-check)
```sql
SHOW GRANTS ON EXTERNAL TABLE COMMERCE.SOURCE.CRM_ACCOUNT_EXT;   -- expect <schema>_READ_ONLY SELECT + <schema>_ADMIN privs intact
```

### Manual-grant audit (missing COPY)
```sql
SELECT start_time,user_name,role_name,query_type,execution_status,LEFT(query_text,200)
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time > DATEADD('day',-3,CURRENT_TIMESTAMP()) AND user_name ILIKE '%ALEX.SOTIS%'
  AND query_type='GRANT' AND execution_status='SUCCESS' AND query_text ILIKE '%ownership%'
  AND query_text NOT ILIKE '%COPY CURRENT GRANTS%' AND query_text NOT ILIKE '%ON FUTURE%';
```

### Prod external tables with auto-refresh on (should be >0 after re-enable)
```sql
SHOW EXTERNAL TABLES IN ACCOUNT;
SELECT database_name,schema_name,name FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE NVL("notification_channel",'')<>'' AND "database_name" IN
 ('FES_INTEGRATIONS','LOYALTY','COMMERCE','FANFLOW','FDE','CDE','IDENTITY','FANAPP','XP');
```

---

## 7. What's left / next steps (punch list)

- [x] Apply attempt 1 (run 30106730590) — FAILED on CDE.CDE_STAGE only (003514 ordering race); ~85/86 transferred; subordination grants now live.
- [x] Apply attempt 2 (run 30106730590 job 89531545221) — FAILED at `terraform init`: `snowflakedb/snowflake v2.18.0: github.com: bad response code: 500` (transient provider-download error, unrelated to our config; never reached apply).
- [x] Apply attempt 3 — **SUCCESS.** Verified: CDE.CDE_STAGE.LOYALTY_ACCOUNT_EXT now `AR_FES_EXT_TABLE_OWNER`-owned; sampled tables (LOYALTY.SOURCE.USER_EVENT_EXT, FES_INTEGRATIONS.SUMMIT.SHOP_REDEMPTIONS_EXT, IDENTITY.SOURCE.CORE_EXT) all AR-owned with `<schema>_ADMIN`+`_READ_ONLY` SELECT preserved (COPY worked); dbt `EXTERNAL_TABLE_REFRESH` succeeding post-apply (16:06–16:10, incl CDE.CDE_STAGE). **Design verified end-to-end.**
- [ ] User re-running §4.1 AUTO_REFRESH re-enable in the UI.
- [x] **Follow-up PR #2962 OPENED** (branch `fix-ext-table-ownership-depends-on`): adds `depends_on` from the 2 `grant_ownership` resources to the 2 subordination `grant_account_role`s. No-op for current state; prevents the race on from-scratch/DR applies. https://github.com/fanatics-gaming/fanapp-terraform/pull/2962
- [ ] **Post-apply:** run §6 re-enable-auto-refresh block (ACCOUNTADMIN).
- [ ] **Post-apply verify:** grant preservation spot-check (§6); confirm dbt `EXTERNAL_TABLE_REFRESH` succeeds again; confirm the 2 managed-access tables transferred.
- [ ] **Finish #2950** (rebase; drop transactions/customer hunks; keep 5 ecomm iceberg modules).
- [ ] **🔴 New PR: iceberg-table ownership** — mirror `AR_FES_EXT_TABLE_OWNER` design with `object_type_plural = "ICEBERG TABLES"` for COMMERCE.SOURCE (+ CDE, others). Do before next create-DAG run.
- [ ] Decide: import base `FDE_MWAA_WH`/`FDE_SNOWPARK_WH` into TF (or leave manual grants); confirm `PMG_FANAPP` legacy.
- [ ] Confirm clean-room grant `SVC_DBT_CLOUD_ROLE → FAN_DATA_EXCHANGE_CDE_STAGE_RW` is intentional.
- [ ] Investigate `owner=""` external/iceberg tables.
- [ ] (Optional hygiene) grant `AR_FES_EXT_TABLE_OWNER` to the service ROLES not just users.
