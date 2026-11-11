# Source Table Findings — `fes_users.zoe_sarwar.gl_new_to_x`

Measured live on **2026-08-07** via `snow` CLI (connection `FAN_DATA_EXCHANGE_PROD`,
role `FES_DATA_DEVELOPER`, warehouse `FDE_DEVELOPER_WH`).

This is the single source both AE staging tables INSERT from, so its actual schema
and fill rates determine whether the export jobs will have data.

## Columns present (32)

```
PRIVATE_FAN_ID                          TEXT
FANAPP_TENANT_FAN_ID                    TEXT      ← user_id / external_id source
REGISTER_TS                             TIMESTAMP_NTZ  ← event_time source
FANAPP_ACCOUNT_CREATION_TIMESTAMP       TIMESTAMP_NTZ
COMMERCE_ACCOUNT_CREATION_TIMESTAMP     TIMESTAMP_NTZ
FBG_ACCOUNT_CREATION_TIMESTAMP          TIMESTAMP_NTZ
COLLECT_ACCOUNT_CREATION_TIMESTAMP      TIMESTAMP_NTZ
LIVE_ACCOUNT_CREATION_TIMESTAMP         TIMESTAMP_LTZ
TOPPS_DIGITAL_ACCOUNT_CREATION_TIMESTAMP TIMESTAMP_NTZ
TOPPS_COM_CREATED_TIMESTAMP             TIMESTAMP_NTZ
APPSFLYER_ID                            TEXT
PLATFORM                                TEXT
USER_AGENT                              TEXT
IP_ADDRESS                              TEXT
APP_ID                                  NUMBER
IDFA                                    TEXT
IDFV                                    TEXT
ANDROID_ID                              TEXT
CONSENT_STATUS                          TEXT
FIREBASE_APP_INSTANCE_ID                TEXT
EXTINFO_0_VERSION                       TEXT
EXTINFO_1_PACKAGE                       TEXT
EXTINFO_2_SHORT_VERSION                 TEXT
EXTINFO_3_LONG_VERSION                  TEXT
EXTINFO_4_OS_VERSION                    TEXT
EMAIL                                   TEXT
SHA256_HASHED_EMAIL                     TEXT
MD5_HASHED_EMAIL                        TEXT
IS_NEW_TO_FANATICS                      BOOLEAN
IS_NEW_TO_COMMERCE                      BOOLEAN
IS_NEW_TO_FBG                           BOOLEAN
IS_NEW_TO_COLLECTIBLES                  BOOLEAN
```

### Columns the AE tickets reference that DO NOT exist
- `first_name` — **absent**
- `last_name` — **absent**

ENTDATA-2264's INSERT computes `SHA2(LOWER(TRIM(first_name)), 256)` and
`...(last_name)`. As written it will fail with an invalid-identifier compile error.
Only `email` / `sha256_hashed_email` / `md5_hashed_email` exist for PII. DE
ticket 2262 already states "for the moment we only have email" — fn/ln are future.

## Fill rates (all 966,179 rows)

| Column | % populated | Verdict |
|--------|-------------|---------|
| `sha256_hashed_email` | **99.5%** | ✅ good |
| `ip_address` | **96.0%** | ✅ good |
| `platform` | **96.0%** | ✅ good |
| `extinfo_0_version` | **96.0%** | ✅ good (pre-computed in source — no Amplitude join needed) |
| `extinfo_4_os_version` | **96.0%** | ✅ good |
| `is_new_to_fbg` (=TRUE) | 99.0% | ✅ |
| `user_agent` | **55.7%** | ⚠️ ~44% NULL — Meta readiness gate loses them |
| `consent_status` | **0.0%** | 🔴 effectively empty (see below) |
| `firebase_app_instance_id` | **0.0%** | 🔴 empty — hard blocker for Firebase |

Row volume: **966,179 total**, **2,239 in the last 7 days** (the steady-state
incremental slice).

## Value-domain checks

**`platform`** (exact casing — matters because the Firebase send code branches on it):
| value | rows |
|-------|------|
| `iOS` | 708,760 |
| `Android` | 218,860 |
| `<null>` | 38,559 |

→ Casing is `iOS` / `Android`, which **matches** the Firebase send code's
`if platform == "iOS"` branch. Good.

**`consent_status`**:
| value | rows |
|-------|------|
| `<null>` | 966,175 |
| `true` | 4 |

→ Not just empty — the only non-null value is `true`, **not** `'authorized'`.
ENTDATA-2264 maps `CASE WHEN consent_status = 'authorized' THEN 1 ELSE 0`, so even
the 4 populated rows map to 0. The literal is wrong *and* the column is empty.

**`firebase_app_instance_id` in the last 7 days**: 0 of 2,239 populated. It is
**not** starting to flow in recent data — the blocker is current, not historical.

## Reproduce

```sql
-- fill rates
USE WAREHOUSE FDE_DEVELOPER_WH;
SELECT
  COUNT(*) AS total_rows,
  COUNT_IF(register_ts >= CURRENT_DATE()-7) AS rows_last_7d,
  ROUND(100*COUNT_IF(sha256_hashed_email IS NOT NULL)/COUNT(*),1) AS pct_email,
  ROUND(100*COUNT_IF(ip_address IS NOT NULL)/COUNT(*),1) AS pct_ip,
  ROUND(100*COUNT_IF(user_agent IS NOT NULL)/COUNT(*),1) AS pct_ua,
  ROUND(100*COUNT_IF(platform IS NOT NULL)/COUNT(*),1) AS pct_platform,
  ROUND(100*COUNT_IF(consent_status IS NOT NULL)/COUNT(*),1) AS pct_consent,
  ROUND(100*COUNT_IF(firebase_app_instance_id IS NOT NULL)/COUNT(*),1) AS pct_fb_iid,
  ROUND(100*COUNT_IF(extinfo_0_version IS NOT NULL)/COUNT(*),1) AS pct_ext0,
  ROUND(100*COUNT_IF(is_new_to_fbg)/COUNT(*),1) AS pct_new_fbg
FROM fes_users.zoe_sarwar.gl_new_to_x;
```
