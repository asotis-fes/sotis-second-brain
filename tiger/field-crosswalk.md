# Field Crosswalk — Payload → AE Table → Source Column

Traces every payload field from the platform API back through the AE staging table
to the source column in `gl_new_to_x`. Fill rates from `source-table-findings.md`
(measured 2026-08-07).

Legend: ✅ present & populated · ⚠️ present but sparse · 🔴 missing/empty

---

## Meta CAPI  (payload ← `fde.fde_info.meta_capi_export` ← `gl_new_to_x`)

| Meta payload field | AE table column | Source column | Fill | Notes |
|--------------------|-----------------|---------------|------|-------|
| `event_name` | `event_name` | derived from `is_new_to_*` | ✅ | taxonomy mismatch, see gap #7 |
| `event_time` | `event_time` | `register_ts` | ✅ | staleness risk, gap #6 |
| `user_data.em` | `sha256_hashed_email` | `sha256_hashed_email` | ✅ 99.5% | |
| `user_data.fn` | `sha256_hashed_first_name` | `first_name` | 🔴 | column absent → won't compile, gap #4 |
| `user_data.ln` | `sha256_hashed_last_name` | `last_name` | 🔴 | column absent, gap #4 |
| `user_data.client_ip_address` | `client_ip_address` | `ip_address` | ✅ 96% | |
| `user_data.client_user_agent` | `client_user_agent` | `user_agent` | ⚠️ 55.7% | ~44% fail readiness, gap #3 |
| `user_data.external_id` | `external_id_hashed` | `SHA2(fanapp_tenant_fan_id)` | ✅ | don't re-hash in send job, gap #5 |
| `app_data.advertiser_tracking_enabled` | `advertiser_tracking_enabled` | `consent_status` | 🔴 0% | maps to 0 for all; literal wrong, gap #2 |
| `app_data.extinfo[0]` | `extinfo_0` | `extinfo_0_version` | ✅ 96% | |
| `app_data.extinfo[1]` | `extinfo_1` | `extinfo_1_package` | ✅ | |
| `app_data.extinfo[2]` | `extinfo_2` | `extinfo_2_short_version` | ✅ | |
| `app_data.extinfo[3]` | `extinfo_3` | `extinfo_3_long_version` | ✅ | |
| `app_data.extinfo[4]` | `extinfo_4` | `extinfo_4_os_version` | ✅ 96% | |
| `app_data.extinfo[5..15]` | (static) | — | ✅ | send job supplies static defaults |
| `custom_data.currency` | `currency` | literal `'USD'` | ✅ | |
| `custom_data.value` | `value` | NULL for `new_*` | ✅ | populated only for Purchase-type |
| (routing) | `platform` | `platform` | ✅ 96% | |

**Readiness gate (AE 2264):** email + ip + user_agent + platform + extinfo_0 all
NOT NULL. Binding constraint is `user_agent` (55.7%).

---

## Firebase MP  (payload ← `fde.fde_info.firebase_mp_export` ← `gl_new_to_x`)

| Firebase payload field | AE table column | Source column | Fill | Notes |
|------------------------|-----------------|---------------|------|-------|
| `app_instance_id` | `firebase_app_instance_id` (LOWER) | `firebase_app_instance_id` | 🔴 0% | **hard blocker**, gap #1 |
| `user_id` | `fanapp_tenant_fan_id` | `fanapp_tenant_fan_id` | ✅ | |
| `events[].name` | `event_name` | derived from `is_new_to_*` | ✅ | taxonomy mismatch, gap #7 |
| `events[].params.currency` | `currency` | literal `'USD'` | ✅ | |
| `events[].params.value` | `value` | NULL for `new_*` | ✅ | |
| `events[].params.engagement_time_msec` | (static 1000) | — | ✅ | send job supplies |
| (routing: app_id + secret) | `platform` | `platform` | ✅ 96% | values `iOS`/`Android` match send code |
| (ordering) | `event_time` | `register_ts` | ✅ | 72h staleness risk, gap #6 |

**Readiness gate (AE 2265):** `firebase_app_instance_id` + `platform` NOT NULL.
Binding constraint is `firebase_app_instance_id` (0%) → **no rows ready**.

---

## Secrets (no source-data dependency)

| Ticket | Env var | Where it should live |
|--------|---------|----------------------|
| 2262 (Meta) | `META_ACCESS_TOKEN` | AWS Secrets Manager / Airflow Variable |
| 2262 (Meta) | `META_DATASET_ID` | Airflow Variable |
| 2259 (Firebase) | `FIREBASE_API_SECRET_IOS` | AWS Secrets Manager |
| 2259 (Firebase) | `FIREBASE_API_SECRET_ANDROID` | AWS Secrets Manager |
| 2259 (Firebase) | `FIREBASE_APP_ID_IOS` | Airflow Variable (non-secret ID) |
| 2259 (Firebase) | `FIREBASE_APP_ID_ANDROID` | Airflow Variable (non-secret ID) |

**Never commit these values.** The export scripts read them at runtime.
