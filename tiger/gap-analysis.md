# Tiger Project — Data Continuity Gap Analysis

**Question asked:** Between the DE export example code, the env/secrets in the DE
tickets, and the fields in the AE staging tables — is there continuity, or will we
find missing data when we go to build the export jobs?

**Answer:** Continuity mostly holds for Meta, with fixable gaps. **Firebase is a
hard blocker** — 0% of rows are sendable today. Details below, verified against the
live source table (see `source-table-findings.md`).

---

## Verdict at a glance

| # | Severity | Integration | Gap |
|---|----------|-------------|-----|
| 1 | 🔴 Blocker | Firebase | `firebase_app_instance_id` is 0% populated → 100% of rows never `ready_to_send`. Send job reads an empty set. |
| 2 | 🔴 Semantic | Meta | `consent_status` 0% populated + domain is `true`/null, not `'authorized'` → `advertiser_tracking_enabled = 0` for every event → Meta won't optimize. |
| 3 | 🟠 Partial | Meta | `user_agent` only 55.7% populated → ~44% of users fail the Meta readiness gate. |
| 4 | 🟠 Compile | Meta | AE INSERT references `first_name`/`last_name` which don't exist in source → SQL won't compile as written. |
| 5 | 🟡 Logic | Meta | Send code re-hashes `USER_ID` for `external_id`, but AE table already stores `external_id_hashed` → double-hash risk. |
| 6 | 🟡 Logic | Both | `event_time` semantics + staleness: Meta rejects events >7d old; Firebase silently drops iid idle >72h. Full-history backfill (964k of 966k rows are >7d old) will mostly be rejected/dropped. |
| 7 | 🟡 Scope | Both | Event taxonomy differs between DE and AE tickets. |

---

## What's fine (continuity holds)

Every structural column the AE INSERTs need **exists** in `gl_new_to_x`, and the
high-risk ones are well-populated:

- `sha256_hashed_email` 99.5%, `ip_address` 96.0%, `platform` 96.0%
- **`extinfo_0…4` all exist and are 96% populated** — despite DE 2262's example
  deriving extinfo from an Amplitude join (`amplitude.events_537355`), the source
  table already has them pre-computed. **No Amplitude join is required.**
- All four `is_new_to_*` flags exist.
- `platform` values are exactly `iOS` / `Android` — matches the Firebase send
  code's `platform == "iOS"` branch.
- DE env vars (`META_ACCESS_TOKEN`, `META_DATASET_ID`, `FIREBASE_API_SECRET_*`,
  `FIREBASE_APP_ID_*`) are secrets/infra — no source-data dependency. Fine.

---

## Gap details

### 1. 🔴 Firebase blocker — `firebase_app_instance_id` is 0% populated
- **Evidence:** 0 of 966,179 rows; 0 of 2,239 in the last 7 days.
- **Impact:** AE 2265 gates `ready_to_send` on `firebase_app_instance_id IS NOT NULL`.
  With 0% fill, the export table has **zero** ready rows. The DE 2259 send job will
  run against an empty set and ship nothing.
- **Acknowledged:** DE 2259 Req #1 calls this "the critical blocker." Confirmed live.
- **Options:**
  - (a) Get `firebase_app_instance_id` flowing into the source (Cassandra pipeline
    / Amplitude `user_properties`) — the real fix.
  - (b) DE 2259's fallback: fix the BigQuery GA4 export (stopped 2026-07-21) and
    source `app_instance_id` from BQ. **No AE table covers this path** — it would
    bypass `fde.firebase_mp_export` entirely. Needs its own design if pursued.
- **Do not start the Firebase send job until (a) or (b) is in place.**

### 2. 🔴 Meta `advertiser_tracking_enabled` collapses to 0
- **Evidence:** `consent_status` 0% populated; only non-null value is `true` (4 rows),
  never `'authorized'`.
- **Impact:** `CASE WHEN consent_status='authorized' THEN 1 ELSE 0` → **0 for every
  row**. Per DE 2262, `advertiser_tracking_enabled=0` means Meta may not use the
  event for optimization — defeating the campaign-optimization purpose. Not a
  readiness gate, so events still send, but with the optimization signal off.
- **Fix:** decide the real consent source + default. DE validation hardcoded `1`.
  At minimum correct the literal (`'authorized'` never matches `true`/null).

### 3. 🟠 Meta `user_agent` only 55.7% populated
- **Impact:** AE 2264 requires `client_user_agent IS NOT NULL` for `ready_to_send`.
  ~44% of new users never become ready for Meta.
- **Fix:** confirm whether UA should be a hard readiness requirement, or make it
  optional (Meta accepts events without UA, just with lower match quality).

### 4. 🟠 AE Meta INSERT won't compile — `first_name`/`last_name` absent
- **Evidence:** source has only `email`, `sha256_hashed_email`, `md5_hashed_email`.
- **Impact:** `SHA2(LOWER(TRIM(first_name)))` / `...(last_name)` → invalid identifier.
- **Fix:** drop `sha256_hashed_first_name`/`last_name` from the AE INSERT (leave the
  columns NULL for future) until a name source exists. DE 2262 already treats fn/ln
  as future PII.

### 5. 🟡 `external_id` double-hash risk
- AE stores `external_id_hashed = SHA2(fanapp_tenant_fan_id)` (already hashed). The
  DE 2262 example does `sha256_hash(row['USER_ID'])` again at send time.
- **Fix:** send job must pass `external_id_hashed` straight through — do **not**
  re-hash.

### 6. 🟡 `event_time` semantics + staleness
- AE stores `register_ts`; DE example uses `int(time.time())` (now).
- Meta rejects events >7 days old; Firebase silently drops app_instance_ids idle
  >72h (returns 204 anyway — no error signal).
- Only 2,239 of 966,179 rows are within 7 days. A first-run full-history backfill
  will be almost entirely rejected/dropped.
- **Fix:** decide event_time semantics (send `register_ts` vs "now") and cap the
  initial send to recent rows; prioritize recently active users for Firebase.

### 7. 🟡 Event taxonomy mismatch
- **Meta:** DE 2262 lists `Purchase / high_value_cvp_m2 / new_fbg / new_commerce`;
  AE 2264 lists `new_fbg / new_commerce / new_fanatics / new_collectibles / Purchase`.
  `high_value_cvp_m2` is modeled nowhere; `new_fanatics`/`new_collectibles` are AE-only.
- **Firebase:** DE 2259's example centers on `osb_profit`; AE 2265 centers on
  `new_fbg` (marks `osb_profit`/`Purchase` future).
- **Fix:** agree one canonical event list per platform so both sides build the same set.

---

## Open decisions (need product/eng sign-off before prod)

1. **Firebase:** which source for `app_instance_id` — upstream Snowflake feed (a) or
   BigQuery fallback (b)?
2. **Consent:** real source for `consent_status`, and default when null (send `1`? or
   suppress?).
3. **User agent:** hard readiness requirement for Meta, or optional?
4. **Event time:** send `register_ts` or "now"? Initial backfill window?
5. **Event taxonomy:** finalize the canonical event list per platform.

---

## Evidence

- Live schema + fill rates: `source-table-findings.md`
- Field-by-field mapping: `field-crosswalk.md`
- Measured 2026-08-07, `FAN_DATA_EXCHANGE_PROD` / `FES_DATA_DEVELOPER`.
