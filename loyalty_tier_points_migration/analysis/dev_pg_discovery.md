# Dev PG Discovery Results (2026-07-13)

Source: `tp_schema_discovery` DAG run in Airflow dev, `manual__2026-07-13T16_30_36`, connection `loyalty_postgres_dev`.

## Full test_* table inventory (18 tables)

### 🆕 Tier-only (new pipeline needed) — 5 tables

**Suneel's list had 4 of these; `tier_account_override_trial` was omitted but is present in PG.**

#### `test_tier` (8 cols)
| col | type | nullable |
|---|---|---|
| tier_id | uuid | NOT NULL |
| program_id | bigint | NOT NULL |
| name | text | NOT NULL |
| minimum_eligible_balance | bigint | NOT NULL |
| invite_only | boolean | NOT NULL DEFAULT false |
| description | text | NULL |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

#### `test_tier_override_configuration` (12 cols)
| col | type | nullable |
|---|---|---|
| id | uuid | NOT NULL |
| program_id | bigint | NOT NULL |
| tier_id | uuid | NOT NULL |
| name | text | NOT NULL |
| type | USER-DEFINED (`tier_override_type` enum) | NOT NULL |
| rollover_percent | numeric | NULL |
| maximum_rollover_points | numeric | NULL |
| trial_days | integer | NULL |
| trial_target_points | bigint | NULL |
| is_active | boolean | NOT NULL DEFAULT true |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

Schema doc (main branch, "Tier Points configuration tables" section) also documented an `expires_at` column — **NOT PRESENT** in dev PG. Either schema doc is ahead of dev, or column was removed. Ask Suneel if this column is coming.

#### `test_tier_account_override` (21 cols)
| col | type | nullable |
|---|---|---|
| id | uuid | NOT NULL |
| external_id | text | NOT NULL |
| loyalty_id | uuid | NOT NULL |
| program_id | bigint | NOT NULL |
| type | USER-DEFINED (`tier_override_type` enum) | NOT NULL |
| tier_id | uuid | NOT NULL |
| override_config_id | uuid | NOT NULL |
| site_id | integer | NOT NULL |
| tenant_id | integer | NOT NULL |
| initiated_by | text | NULL |
| start_at | timestamptz | NOT NULL DEFAULT now() |
| expires_at | timestamptz | NOT NULL |
| reason | USER-DEFINED (`tier_override_reason` enum) | NOT NULL |
| note | text | NULL |
| extra_data | jsonb | NOT NULL DEFAULT `'{}'::jsonb` |
| trial_id | uuid | NULL |
| tier_points_on_rollover | numeric | NULL |
| lifetime_tier_points_on_rollover | numeric | NULL |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |
| **rollover_tierpoints** | numeric | NULL |

**Note**: `rollover_tierpoints` is **not documented in main-branch schema doc**. PG has evolved past the doc. Ask Suneel about semantics vs `tier_points_on_rollover` (looks like a rename-in-progress or a new column).

#### `test_tier_account_override_trial` (10 cols)
| col | type | nullable |
|---|---|---|
| id | uuid | NOT NULL |
| start_at | timestamptz | NOT NULL |
| expiry_at | timestamptz | NOT NULL |
| trial_target_points | bigint | NOT NULL |
| start_tier_points | numeric | NULL |
| start_lifetime_tier_points | numeric | NULL |
| start_rollover_tier_points | numeric | NULL |
| earned_tier_points | numeric | NOT NULL DEFAULT 0 |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Confirmed present in dev PG** despite absence from Suneel's list. No `program_id` column (matches doc). Ingest recommended for STATUS_MATCH trial analytics.

#### `test_tier_invite_approval` (7 cols)
| col | type | nullable |
|---|---|---|
| loyalty_id | uuid | NOT NULL |
| program_id | bigint | NOT NULL |
| tier_id | uuid | NOT NULL |
| status | USER-DEFINED (`tier_invite_status` enum) | NOT NULL |
| note | text | NULL |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

---

### ✅ Shared with OneCredits (already ingested)

#### `test_account_balance` (8 cols) — `lifetime` present
| col | type | nullable |
|---|---|---|
| id | uuid | NOT NULL |
| loyalty_id | uuid | NOT NULL |
| program_id | bigint | NOT NULL |
| available | numeric | NOT NULL DEFAULT 0 |
| pending | numeric | NOT NULL DEFAULT 0 |
| maturing | numeric | NOT NULL DEFAULT 0 |
| updated_at | timestamptz | NOT NULL DEFAULT now() |
| **lifetime** | numeric | **NOT NULL DEFAULT 0** |

**Key finding**: `lifetime` exists **in dev PG today**. It is `NOT NULL DEFAULT 0` — contradicts schema doc which said "NULL for other programs". Non-TierPoints rows will have `lifetime = 0`. Our current OneCredits ext-table DDL does NOT project `lifetime` → must add.

#### `test_transaction` (22 cols)
All 22 columns as documented in schema doc plus:
- `entry_type` (enum, nullable) — present in PG (schema doc listed it too)
- `campaign_code` (text, nullable) — present in PG (schema doc listed it too)
- `available_at` (timestamptz NOT NULL DEFAULT now()) — matches doc
- `reversed_transaction_id` (uuid, nullable) — present in PG (schema doc listed it too)

No unexpected column additions.

---

### ✅ OneCredits bucket-model tables (already ingested, 10 tables)

`test_allocation`, `test_allocation_remaining`, `test_auth_bucket_hold`, `test_auth_hold`, `test_bucket`, `test_bucket_type`, `test_capture_event`, `test_transfer_restriction`, `test_void_auth_event`, `test_void_remaining`. Column shapes match schema doc. No changes needed for tier points.

---

### ✅ Reference tables (already ingested, 2 tables)

`test_loyalty_account` (2 cols), `test_program` (6 cols). No changes.

---

## Not in dev PG (potentially still-forming)

- **`test_account_metadata`** — schema doc introduced this but it does NOT exist in dev PG. Skip for now; monitor for future ingestion need.
- **`test_tier_override_configuration.expires_at`** — documented in schema doc but not present as a column in PG.
- **`test_job_queue`** — documented in schema doc but skipped (async worker queue, not analytics-relevant).
- **`test_idempotency_keys`** — documented in schema doc but skipped in OneCredits.

## Suneel-list interpretation (Q1 RESOLVED)

| Suneel wrote | Actual PG name | Notes |
|---|---|---|
| `test_account_balance` | `test_account_balance` | ✓ exact |
| `test_tier_account_override` | `test_tier_account_override` | ✓ exact |
| `test_transacrion` | `test_transaction` | typo confirmed |
| `test_tier` | `test_tier` | ✓ exact |
| `test_override_configuration` | `test_tier_override_configuration` | Suneel dropped `tier_` prefix |
| `test_invite_approval` | `test_tier_invite_approval` | Suneel dropped `tier_` prefix |

Plus `test_tier_account_override_trial` (Suneel omitted but exists — should include).

## Enums that need to be documented

Six `USER-DEFINED` enum types show up across the new tier tables and existing shared tables:

- `type` on `test_tier_account_override` and `test_tier_override_configuration` — `tier_override_type` (`PLACEMENT`, `ROLLOVER`, `STATUS_MATCH`)
- `reason` on `test_tier_account_override` — `tier_override_reason` (various)
- `status` on `test_tier_invite_approval` — `tier_invite_status` (`APPROVED`, `REVOKED`)
- `type` on `test_transaction` — `transaction_type`
- `entry_type` on `test_transaction` and `test_bucket_type` — `entry_type`
- `reason` on `test_transaction` — `reason_type`
- `ref_id_type` on `test_transaction` — `ref_id_type`

In parquet ingest these serialize as strings. Staging models cast to VARCHAR.
