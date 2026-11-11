# Data Classification Catalog (Operational Digest)

Operational summary of the FAN Data Classification Catalog. Source of truth is Confluence 1575781375 — fetch the latest if in doubt.

**Source**: [FES - Data Classification Catalog](https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/1575781375)
**Last verified**: 2026-06-10 (mirroring v1.0, approved 2026-02-03)

## Four classification tiers

| Tier | What it means | Phase 1 masking |
|---|---|---|
| **Critical** | Most sensitive. Includes PII, PCI, UCD, customer authentication. | **YES — mask** |
| **Highly Confidential** | Less sensitive than Critical but still requires protection. Includes HR PII, account balances, IP addresses. | **YES — mask** |
| **Confidential** | Internal-only but not personally identifying alone. IDs, fraud scores, device IDs. | No — not masked (Phase 1) |
| **Public** | Explicitly public. Sport teams, public profiles. | No — not masked |

## Critical (mask in Phase 1)

These get `meta.classification: critical`.

| Data element | `pii_category` value | Notes |
|---|---|---|
| Customer payment information | `payment` | PCI |
| Customer biometric data | `biometric` | PII |
| Customer SSN | `ssn` | PII |
| Customer national ID number | `national_id` | PII |
| Images of customer ID documents | `id_document_image` | PII |
| Customer authentication secrets | `auth_secret` | passwords, tokens that are secrets |
| Customer KYC information (with PII) | `kyc_pii` | PII |
| Customer full name | `name` | PII unless explicitly made public |
| Customer email address | `email` | PII |
| Customer address | `address` | PII (includes house number) |
| Customer fine geolocation | `geo_fine` | PII (≥3 decimal places lat/lon) |
| Customer telephone number | `phone` | PII |
| Customer date of birth | `dob` | PII |
| Customer driver's license number | `drivers_license` | PII |
| Clear customer betting history | `betting_history_clear` | clear = PII-attributable |
| Clear customer behavioral data | `behavioral_clear` |  |
| Clear betting data | `betting_data_clear` |  |
| Customer physical attributes | `physical_attribute` | PII (eye color, height, weight) |
| Photos/images of customers (non-public) | `image_private` | PII |
| Contents of digital communications | `comm_content` | UCD (SMS, email to customers) |
| Customer device/app usage data | `usage_data` | UCD (URLs, comments, bet notes) |
| Customer service chat logs | `chat_log` | UCD |
| Customer service account notes | `service_note` | UCD |
| Customer password history | `password_history` |  |
| Clear customer transaction history | `transaction_history_clear` |  |
| Promotional/redemption codes — monetary | `promo_code_monetary` |  |
| Credentials controlling Critical access | `credential_critical` |  |

## Highly Confidential (mask in Phase 1)

These get `meta.classification: highly_confidential`.

| Data element | `pii_category` value | Notes |
|---|---|---|
| Customer IP address | `ip_address` |  |
| Opaque customer betting history | `betting_history_opaque` | not directly attributable |
| Opaque customer behavioral data | `behavioral_opaque` |  |
| Opaque betting data | `betting_data_opaque` |  |
| Employee SSN | `employee_ssn` | HR PII |
| Employee national ID | `employee_national_id` | HR PII |
| Employee DOB | `employee_dob` | HR PII |
| Employee address | `employee_address` | HR PII |
| Employee background check info | `employee_background` | HR PII |
| Employee last 4 of SSN | `employee_ssn_last4` | HR PII |
| Employee salary | `employee_salary` |  |
| Customer authentication tokens | `auth_token` |  |
| Customer account balance | `account_balance` |  |
| Customer credit limit | `credit_limit` |  |
| Customer last 4 of SSN | `ssn_last4` | PII |
| Customer partial address | `address_partial` | no house number — applies to CITY, STATE, COUNTRY, ZIP individually |
| Customer coarse geolocation | `geo_coarse` | ≤2 decimal places |
| Customer age (not in catalog explicitly) | `age` | not in catalog; conservative bucket — engineer override allowed |
| Customer gender (not in catalog explicitly) | `gender` | not in catalog; conservative bucket — engineer override allowed |
| Customer self-exclusion status | `self_exclusion` |  |
| Customer KYC info (no PII) | `kyc_nonpii` |  |
| Terminal cashbox info | `cashbox` |  |
| Opaque customer transaction history | `transaction_history_opaque` |  |
| Unreleased company financials | `financial_unreleased` |  |
| FES source code | `source_code` |  |
| Security event logs | `security_log` |  |
| Promotional/redemption codes — non-monetary | `promo_code_nonmonetary` |  |
| Credentials controlling HC access | `credential_hc` |  |

## Confidential (NOT masked in Phase 1)

These get `meta.classification: confidential` if tagged. Phase 1 leaves them visible.

| Data element | `pii_category` value |
|---|---|
| Customer account ID / fan_id | `fan_id` |
| Customer fraud score | `fraud_score` |
| Customer mobile device ID | `device_id` |
| Customer VIP status | `vip_status` |
| Transaction ID | `transaction_id` |
| Bet ID | `bet_id` |
| Internal identifiers (non-public) | `internal_id` |
| Internal error messages | `internal_error` |
| Mobile device info (non-PII) | `device_info` |
| User registration status | `registration_status` |
| Company invoices/POs | `invoice` |
| Partial customer DOB | `dob_partial` |

## Public (NOT masked)

Explicitly public data. No tagging needed.

## Operational rules

- **Encryption/hashing does NOT change classification.** Hashed email is still email-classified. Confirms our "constant, not hashed" choice — hashing would add cost without compliance benefit. Practical consequence: `SYSTEM$CLASSIFY()` cannot detect hashed PII from values alone (hex strings match no pattern), so engineer review is required for tables holding hashed PII. See [`06_classify_script.md`](06_classify_script.md) "Limitations".
- **Critical data cannot be written to logs.** Per the Security Event Logging Standard (Confluence 1575782116). Relevant to D6 follow-up.
- **`pii_category` enum is the authoritative list** for our YAML. If a new data element appears (catalog updates, new product feature), add a row here and to [`02_decisions.md`](02_decisions.md) before tagging columns.

## Detection regex (from catalog)

For use in `SYSTEM$CLASSIFY()` custom classifiers or sanity checks:

| Pattern | Regex |
|---|---|
| Phone | `^[\+]?[(]?[0-9]{3}[)]?[-\s\.]?[0-9]{3}[-\s\.]?[0-9]{4,6}$` |
| Email | `\b[\w!#$%&'*+/=?\`{\|}~^-]+(?:\.[\w!#$%&'*+/=?\`{\|}~^-]+)*@(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,6}\b` |
| SSN | `^(?!0{3})(?!6{3})[0-8]\d{2}-(?!0{2})\d{2}-(?!0{4})\d{4}$` |

(Snowflake's built-in classifiers handle these natively. Listed here for reference.)
