#!/usr/bin/env python3
"""
export_tp_migration.py — SQL builders for the one-time Tier-Points migration export
(Snowflake prod -> Loyalty S3). See README.md.

v4 (2026-08-07) — Suneel rebuilt the model in fes-loyalty-tp-migration-ws/snowflake
(fmti.sql / overrides.sql / ledger.sql / preflight.sql). This is a REDESIGN, not a tweak:

  1) 3-TIER IDENTITY MAP (was: single legacy tenant map). fan-id -> loyalty-id resolves via
     tier-1 identity.orchestration.loyalty_private_fan_id_map, else tier-2 a prod email-chain
     (scylla -> auth_id -> account_internal -> user_service -> hashed_email -> cde loyalty_account),
     else tier-3 the legacy LOYALTY_ACCOUNT_ID_FAN_ID_TENANT_MAP. UNION with that priority.
  2) DE-COLLIDE: many fan-ids can share one loyalty-id. We do NOT merge them — every fan-id
     migrates as its OWN account. Within a colliding loyalty-id the highest-active-balance fan-id
     (is_primary) KEEPS the original id; every other fan-id gets a NEW deterministic v1-shaped
     UUID: UUID_STRING(NS, pfid||':'||source_loyalty_id) with the version nibble (15th char)
     flipped 5->1 (Cassandra loyaltyAccountId is a timeuuid and rejects v5). Deterministic, so all
     datasets recompute the SAME secondary id with no shared table. The KEY thus flips from
     one-row-per-loyalty_id to one-row-per-fan_id (effective_loyalty_id is 1:1 with fan-id).
  3) FMTI is 39 cols now: + source_loyalty_id, is_primary, dup_group (drive the loader's
     account_metadata write); dedup per fan-id; balances cast to DECIMAL(38,2).

Our framework layered on top (unchanged in spirit from v3):
  - SINGLE-SNAPSHOT PINNING: the 6-DB map + the de-collide are EXPENSIVE, so setup() materializes
    them ONCE into TP_MAP_SNAP (raw union) and TP_EFFECTIVE_SNAP (de-collide). FMTI/overrides/ledger
    then just JOIN the pinned de-collide -> no cross-statement drift AND the monster chain runs once.
  - ONE FILE PER CHUNK (SINGLE=TRUE), chunked by effective_loyalty_id (== per fan-id account, so an
    account's whole history lands in exactly one chunk).
  - UTC 'Z' timestamps, NULL_IF=() bare-empty nulls, HEADER per chunk. Deleted accounts INCLUDED.

Type adaptations of Suneel's SQL (his literals assume TEXT; our schema differs — verified):
  - IS_TEST_TRANSACTION is BOOLEAN  -> COALESCE(IS_TEST_TRANSACTION, FALSE) <> TRUE
  - TRANSACTION_TIMESTAMP is LTZ    -> IS NOT NULL; cutover via < '<ts>'::TIMESTAMP_LTZ
Timestamp FORMATTING: Suneel's queries return raw timestamps (UI-download design); we keep our
validated COPY-INTO formatting (UTC 'YYYY-MM-DD HH24:MI:SS.FF3' || ' Z') that Suneel accepted.

Run order (gen.py -> `snow sql -f`):
  setup(cutover) -> [count] -> fmti + overrides + ledger chunks 0..N-1 -> verify -> cleanup
Output layout: tp_migration/fmti/fmti.csv.gz, override_cdc/overrides.csv.gz,
               ledger/chunk_NNNNN/chunk_NNNNN.csv.gz (one file per chunk).
"""
from __future__ import annotations
import sys

# ── source objects ──────────────────────────────────────────────────────────────
LEDGER_TABLE    = "LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2"
OVERRIDES_TABLE = "LOYALTY.LOYALTY_INFO.TIER_POINTS_OVERRIDES_V2"
FMTI_TABLE = ('SALESFORCE."schema_FanJourney_Loyalty_Promotion_Shares"'
              '."FanMemberTierInformation_00DHs000003WzIz__dll"')

# 3-tier map sources (verified readable 2026-08-07). ⚠ tier-2 entry point is a `_dev` schema —
# Suneel flagged it for prod confirmation (may be a dev leftover): commerce_dev.source.scylla…
IDENTITY_MAP      = "identity.orchestration.loyalty_private_fan_id_map"          # tier 1
SCYLLA_FANID      = "commerce_dev.source.scylla_tenant_fanid_ext"               # tier 2 entry ⚠
AUTH_ID           = "fde.fde_info.auth_id"
ACCT_INTERNAL_LKP = "fde.fde_info.account_internal_id_lkp"
ACCT_USER_SVC     = "fde.fde_info.account_user_service_id"
CUST_ACCT_MAP     = "commerce.fan_key.customer_account_map"
CDE_LOYALTY_ACCT  = "cde.cde_core.loyalty_account"
LEGACY_TENANT_MAP = "LOYALTY.LOYALTY_INFO.LOYALTY_ACCOUNT_ID_FAN_ID_TENANT_MAP"  # tier 3

# de-collide secondary-id namespace — FIXED (Suneel: never change; account_metadata correlation +
# every re-export must recompute identical ids). Fed to UUID_STRING before the 5->1 version flip.
DECOLLIDE_NS = "e5567350-8395-4672-b41f-45f9bcbe4047"

# ── transient snapshot tables (single-snapshot pinning) ───────────────────────────
MAP_SNAP    = "FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT"        # raw 3-tier union (pre de-collide)
EFF_SNAP    = "FES_USERS.ALEX_SOTIS.TP_EFFECTIVE_SNAPSHOT"  # de-collide: fan-id -> effective id
LEDGER_SNAP = "FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT"     # ledger export + chunk_num
UNRESOLVED  = "FES_USERS.ALEX_SOTIS.TP_MIGRATION_UNRESOLVED"  # §P1 data-loss surface

CHUNK_SIZE  = 200_000
WH          = "FDE_DEVELOPER_3XL_WH"
# NULL_IF=() (empty) so SQL NULL unloads as a BARE empty field (,,) — NOT "".
FILE_FORMAT = ("FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='\"' "
               "NULL_IF=() COMPRESSION=GZIP)")
COPY_OPTS   = "HEADER = TRUE  SINGLE = TRUE  MAX_FILE_SIZE = 5368709120  OVERWRITE = TRUE"

# ── timestamp formatting (TIMESTAMP_LTZ -> UTC string the Postgres loader accepts) ─
TS_FMT    = "'YYYY-MM-DD HH24:MI:SS.FF3'"
TS_SUFFIX = "' Z'"        # CONFIRMED good by Suneel 2026-08-10 (full perf export); one-line change if ever needed


def ltz(col: str, alias: str) -> str:
    return f"TO_CHAR(CONVERT_TIMEZONE('UTC', {col}), {TS_FMT}) || {TS_SUFFIX} AS {alias}"


def stage(env: str) -> str:
    return f"@LOYALTY.LOYALTY_INFO.loyalty_migration_stage_{env}"


def _eff_id_expr(pfid: str, src: str) -> str:
    """De-collide effective id: primary keeps source; secondary = deterministic v1-shaped uuid."""
    u = f"UUID_STRING('{DECOLLIDE_NS}', {pfid} || ':' || {src}::VARCHAR)"
    return (f"CASE WHEN rn = 1 THEN {src}::VARCHAR\n"
            f"             ELSE LEFT({u}, 14) || '1' || SUBSTR({u}, 16) END")


# ── 3-tier map CTEs (faithful to Suneel's fmti.sql/ledger.sql/overrides.sql/preflight.sql) ─────
def _map_cte_body() -> str:
    """The new_map/email_map/old_map union that resolves fan-id -> loyalty-id. Ends at
    `loyalty_map AS (...)`; embed under a WITH, then SELECT ... FROM loyalty_map."""
    return f"""new_map AS (                                             -- tier 1: identity service
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID
    FROM {IDENTITY_MAP}
    WHERE LOYALTY_ACCOUNT_ID IS NOT NULL
    -- 1 PRIVATE_FAN_ID can map to >1 LOYALTY_ACCOUNT_ID (e.g. loyalty account recreated). Take the
    -- LATEST-CREATED loyalty id (tie-break on the id for determinism) -- NOT lexical ORDER BY id.
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PRIVATE_FAN_ID
            ORDER BY CREATED DESC NULLS LAST, LOYALTY_ACCOUNT_ID) = 1
),
distinct_fanids AS (                                         -- tier 2: prod email-chain entry
    SELECT DISTINCT PRIVATE_FANID FROM {SCYLLA_FANID} WHERE PRIVATE_FANID IS NOT NULL
),
fanid_to_auth AS (
    SELECT df.PRIVATE_FANID, a.AUTH_ID FROM distinct_fanids df
    JOIN {AUTH_ID} a ON a.PRIVATE_FAN_ID = df.PRIVATE_FANID WHERE a.AUTH_ID IS NOT NULL
),
auth_to_account_internal AS (
    SELECT fa.PRIVATE_FANID, ail.ACCOUNT_INTERNAL_ID FROM fanid_to_auth fa
    JOIN {ACCT_INTERNAL_LKP} ail ON ail.AUTH_ID = fa.AUTH_ID WHERE ail.ACCOUNT_INTERNAL_ID IS NOT NULL
),
account_user_service_id_pick AS (
    SELECT ACCOUNT_ID, TO_VARCHAR(DATA:"1094") AS ACCOUNT_USER_SERVICE_ID, MODIFIED,
        ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID
            ORDER BY (SUBSTR(MODIFIED,15,4)||SUBSTR(MODIFIED,10,4)||SUBSTR(MODIFIED,1,8)) DESC, MODIFIED DESC) AS rn
    FROM {ACCT_USER_SVC}
    WHERE ACCOUNT_ID IS NOT NULL AND DATA:"1094" IS NOT NULL AND SUBSTR(MODIFIED,15,1) = '1'
),
account_internal_to_user_service AS (
    SELECT aai.PRIVATE_FANID, aai.ACCOUNT_INTERNAL_ID, pick.ACCOUNT_USER_SERVICE_ID FROM auth_to_account_internal aai
    JOIN account_user_service_id_pick pick ON pick.ACCOUNT_ID = aai.ACCOUNT_INTERNAL_ID AND pick.rn = 1
),
customer_account_map_latest AS (
    SELECT SURROGATE_ACCOUNT_KEY, HASHED_EMAIL, LAST_MODIFIED_TIME,
        ROW_NUMBER() OVER (PARTITION BY SURROGATE_ACCOUNT_KEY ORDER BY LAST_MODIFIED_TIME DESC) AS rn
    FROM {CUST_ACCT_MAP}
    WHERE SURROGATE_ACCOUNT_KEY IS NOT NULL AND HASHED_EMAIL IS NOT NULL AND LAST_MODIFIED_TIME IS NOT NULL
),
user_service_to_hashed_email AS (
    SELECT aius.PRIVATE_FANID, aius.ACCOUNT_USER_SERVICE_ID, cam.HASHED_EMAIL FROM account_internal_to_user_service aius
    JOIN customer_account_map_latest cam ON cam.SURROGATE_ACCOUNT_KEY = aius.ACCOUNT_USER_SERVICE_ID AND cam.rn = 1
),
loyalty_account_pick AS (
    SELECT HASHED_EMAIL, LOYALTY_ACCOUNT_ID, LOYALTY_ACCOUNT_DIRECTORY_ID, REGISTRATION_SITE_ID,
        ROW_NUMBER() OVER (PARTITION BY HASHED_EMAIL
            ORDER BY CASE WHEN LOYALTY_ACCOUNT_DIRECTORY_ID = 2 AND REGISTRATION_SITE_ID = 510005 THEN 1
                          WHEN LOYALTY_ACCOUNT_DIRECTORY_ID = 2 THEN 2 ELSE 3 END) AS rn
    FROM {CDE_LOYALTY_ACCT} WHERE HASHED_EMAIL IS NOT NULL AND LOYALTY_ACCOUNT_ID IS NOT NULL
),
email_map AS (
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM (
        SELECT ushe.PRIVATE_FANID AS PRIVATE_FAN_ID, lap.LOYALTY_ACCOUNT_ID
        FROM user_service_to_hashed_email ushe
        JOIN loyalty_account_pick lap ON lap.HASHED_EMAIL = ushe.HASHED_EMAIL AND lap.rn = 1
    ) QUALIFY ROW_NUMBER() OVER (PARTITION BY PRIVATE_FAN_ID ORDER BY LOYALTY_ACCOUNT_ID) = 1
),
old_map AS (                                                 -- tier 3: legacy tenant map
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM {LEGACY_TENANT_MAP}
    WHERE LOYALTY_ACCOUNT_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PRIVATE_FAN_ID
        ORDER BY CASE WHEN LOYALTY_ACCOUNT_DIRECTORY_ID = 2 THEN 1 ELSE 2 END, LAST_MODIFIED_TIME DESC) = 1
),
loyalty_map AS (
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM new_map
    UNION ALL SELECT e.PRIVATE_FAN_ID, e.LOYALTY_ACCOUNT_ID FROM email_map e
        WHERE NOT EXISTS (SELECT 1 FROM new_map n WHERE n.PRIVATE_FAN_ID = e.PRIVATE_FAN_ID)
    UNION ALL SELECT o.PRIVATE_FAN_ID, o.LOYALTY_ACCOUNT_ID FROM old_map o
        WHERE NOT EXISTS (SELECT 1 FROM new_map  n WHERE n.PRIVATE_FAN_ID = o.PRIVATE_FAN_ID)
          AND NOT EXISTS (SELECT 1 FROM email_map e WHERE e.PRIVATE_FAN_ID = o.PRIVATE_FAN_ID)
)"""


# ── shared predicates ─────────────────────────────────────────────────────────────
def _has_override_data(a: str) -> str:
    """'This override row carries real data' — matches Suneel's overrides.sql has_override_data
    (used by the overrides export cohort + verify). Incl. TRIAL_TARGET_POINTS; NO rollover fields."""
    return (
        f"( {a}.INVITE_ONLY_APPROVALS IS NOT NULL"
        f" OR {a}.PLACEMENT_TIER_OVERRIDE_NAME IS NOT NULL OR {a}.PLACEMENT_START IS NOT NULL"
        f" OR {a}.PLACEMENT_EXPIRY IS NOT NULL OR {a}.PLACEMENT_NOTE IS NOT NULL"
        f" OR {a}.PLACEMENT_EXTRA_DATA IS NOT NULL"
        f" OR {a}.STATUS_MATCH_TIER_OVERRIDE_NAME IS NOT NULL OR {a}.STATUS_MATCH_START IS NOT NULL"
        f" OR {a}.STATUS_MATCH_EXPIRY IS NOT NULL OR {a}.STATUS_MATCH_NOTE IS NOT NULL"
        f" OR {a}.STATUS_MATCH_EXTRA_DATA IS NOT NULL"
        f" OR {a}.TRIAL_START IS NOT NULL OR {a}.TRIAL_EXPIRY IS NOT NULL"
        f" OR COALESCE({a}.TRIAL_TARGET_POINTS, 0) <> 0"
        f" OR COALESCE({a}.TRIAL_START_TIER_POINTS, 0) <> 0"
        f" OR COALESCE({a}.TRIAL_START_LIFETIME_TIER_POINTS, 0) <> 0"
        f" OR COALESCE({a}.TRIAL_START_ROLLOVER_TIER_POINTS, 0) <> 0 )")


def _short_override_test(a: str) -> str:
    """Suneel's FMTI-cohort override test (active_source_loyalty in fmti.sql): a fan-id counts as
    'active' if it has any tier-override name or an invite. Broader on rollover, narrower on trial
    than _has_override_data — kept faithful; the verify gate proves FMTI still covers overrides."""
    return (f"({a}.PLACEMENT_TIER_OVERRIDE_NAME IS NOT NULL"
            f" OR {a}.STATUS_MATCH_TIER_OVERRIDE_NAME IS NOT NULL"
            f" OR {a}.ROLLOVER_TIER_OVERRIDE_NAME IS NOT NULL"
            f" OR {a}.INVITE_ONLY_APPROVALS IS NOT NULL)")


def _active_source_loyalty_cte() -> str:
    """Source loyalty ids with any fan-id activity — the FMTI export cohort. Derived from the
    pinned raw union MAP_SNAP so it matches Suneel's loyalty_map-scoped definition exactly."""
    return f"""active_source_loyalty AS (
    SELECT DISTINCT lm.LOYALTY_ACCOUNT_ID
    FROM {MAP_SNAP} lm
    WHERE EXISTS (SELECT 1 FROM {LEDGER_TABLE} l
                  WHERE l.PRIVATE_FAN_ID = lm.PRIVATE_FAN_ID
                    AND COALESCE(l.EXTERNAL_ID_TYPE, '') <> 'NON_TRANSACTOR')
       OR EXISTS (SELECT 1 FROM {OVERRIDES_TABLE} o
                  WHERE o.PRIVATE_FAN_ID = lm.PRIVATE_FAN_ID AND {_short_override_test('o')})
)"""


def _ledger_filters(cutover_ts: str, alias: str = "l") -> str:
    """Suneel's ledger row filters, type-adapted for BOOLEAN / LTZ columns."""
    a = alias
    return (
        f"      AND (COALESCE({a}.DERIVED_TIER_POINTS_AMOUNT, 0) <> 0 OR {a}.NOTES = 'EOY-Rollover')\n"
        f"      AND COALESCE({a}.EXTERNAL_ID_TYPE, '') NOT IN ('OVERRIDE', 'NON_TRANSACTOR')\n"
        f"      AND COALESCE({a}.NOTES, '') <> 'TierPoints 10x Loyalty Program'\n"
        f"      AND {a}.TRANSACTION_TIMESTAMP IS NOT NULL\n"
        f"      AND COALESCE({a}.IS_TEST_TRANSACTION, FALSE) <> TRUE\n"
        f"      AND {a}.TRANSACTION_TIMESTAMP < '{cutover_ts}'::TIMESTAMP_LTZ")


# 24-col ledger projection for the SNAPSHOT (loyalty_account_id = de-collided effective id;
# transaction_timestamp formatted). Order faithful to Suneel's ledger.sql.
def _ledger_snapshot_cols() -> str:
    return f"""
        {ltz('l.TRANSACTION_TIMESTAMP', 'transaction_timestamp')},
        l.SALESFORCE_TRANSACTION_ID        AS salesforce_transaction_id,
        e.effective_loyalty_id             AS loyalty_account_id,
        l.EXTERNAL_ID                      AS external_id,
        l.EXTERNAL_ID_TYPE                 AS external_id_type,
        l.REFERENCE_ID                     AS reference_id,
        l.TRANSACTION_STATUS               AS transaction_status,
        l.DERIVED_TIER_POINTS_AMOUNT       AS derived_tier_points_amount,
        l.PROGRAM_FLAG                     AS program_flag,
        l.TENANT_ID                        AS tenant_id,
        l.SITE_ID                          AS site_id,
        l.INITIATED_BY                     AS initiated_by,
        l.IS_TEST_TRANSACTION              AS is_test_transaction,
        l.CURRENT_BALANCE                  AS current_balance,
        l.LIFETIME_BALANCE                 AS lifetime_balance,
        l.NOTES                            AS notes,
        l.EARN_TIER                        AS earn_tier,
        l.PUBLIC_FACING_TIER               AS public_facing_tier,
        l.INVITE_ONLY_TIER_NAME            AS invite_only_tier_name,
        l.STATUS_MATCH_ACTIVE              AS status_match_active,
        l.PLACEMENT_ACTIVE                 AS placement_active,
        l.ROLLOVER_ACTIVE                  AS rollover_active,
        l.STATUS_MATCH_TRIAL_EARNED_POINTS AS status_match_trial_earned_points,
        l.TIER_POINTS_MULTIPLIER           AS tier_points_multiplier"""


LEDGER_OUT_COLS = (
    "transaction_timestamp, salesforce_transaction_id, loyalty_account_id, external_id, "
    "external_id_type, reference_id, transaction_status, derived_tier_points_amount, "
    "program_flag, tenant_id, site_id, initiated_by, is_test_transaction, current_balance, "
    "lifetime_balance, notes, earn_tier, public_facing_tier, invite_only_tier_name, "
    "status_match_active, placement_active, rollover_active, status_match_trial_earned_points, "
    "tier_points_multiplier")


def sql_effective_snapshot() -> str:
    """De-collide, built on the pinned raw union MAP_SNAP ⋈ FMTI. One row per fan-id:
    private_fan_id, source_loyalty_id, effective_loyalty_id, is_primary, dup_group.
    (fb dedups FMTI to one row per fan-id up front so grp_size counts distinct fan-ids and the
    snapshot is a clean 1:1 map — a faithful consolidation of Suneel's end-of-query QUALIFY.)"""
    return f"""
CREATE OR REPLACE TRANSIENT TABLE {EFF_SNAP} AS
WITH fb AS (
    SELECT lm.LOYALTY_ACCOUNT_ID                                   AS source_loyalty_id,
           m."MembershipNumber_c__c"                               AS pfid,
           TRY_TO_DECIMAL(m."TPMigration_c__c"::VARCHAR, 38, 2)    AS active,
           TRY_TO_DECIMAL(m."LTTPMigrationF_c__c"::VARCHAR, 38, 2) AS lt,
           TRY_TO_DECIMAL(m."SMTPMigration_c__c"::VARCHAR, 38, 2)  AS sm,
           m."LastModifiedDate__c"                                 AS lmd,
           m."Id__c"                                               AS id
    FROM {FMTI_TABLE} m
    JOIN {MAP_SNAP} lm ON lm.PRIVATE_FAN_ID = m."MembershipNumber_c__c"
    QUALIFY ROW_NUMBER() OVER (PARTITION BY m."MembershipNumber_c__c"
            ORDER BY m."LastModifiedDate__c" DESC NULLS LAST, m."Id__c" DESC) = 1
),
ranked AS (
    SELECT fb.*,
        ROW_NUMBER() OVER (PARTITION BY source_loyalty_id
            ORDER BY active DESC NULLS LAST, lmd DESC NULLS LAST, lt DESC NULLS LAST,
                     sm DESC NULLS LAST, id DESC) AS rn,
        COUNT(*)     OVER (PARTITION BY source_loyalty_id) AS grp_size
    FROM fb
)
SELECT
    pfid                                    AS private_fan_id,
    source_loyalty_id::VARCHAR              AS source_loyalty_id,
    {_eff_id_expr('pfid', 'source_loyalty_id')} AS effective_loyalty_id,
    (rn = 1)                                AS is_primary,
    (grp_size > 1)                          AS dup_group
FROM ranked;
"""


def sql_ledger_snapshot(cutover_ts: str) -> str:
    """Materialize the ledger export + a STABLE chunk_num (chunk by effective_loyalty_id) from the
    ALREADY-PINNED de-collide (EFF_SNAP). Split out of sql_setup so the ledger snapshot can be
    rebuilt at the real cutover WITHOUT rebuilding the map/de-collide — required when FMTI/overrides
    were already exported off a prior EFF_SNAP and the ledger chunks must key on that SAME snapshot."""
    return f"""CREATE OR REPLACE TRANSIENT TABLE {LEDGER_SNAP} AS
WITH ledger_export AS (
    SELECT {_ledger_snapshot_cols()}
    FROM {LEDGER_TABLE} l
    JOIN {EFF_SNAP} e ON e.private_fan_id = l.PRIVATE_FAN_ID
    WHERE 1=1
{_ledger_filters(cutover_ts)}
),
ranked AS (
    SELECT loyalty_account_id,
           FLOOR((DENSE_RANK() OVER (ORDER BY loyalty_account_id) - 1) / {CHUNK_SIZE}) AS chunk_num
    FROM (SELECT DISTINCT loyalty_account_id FROM ledger_export)
)
SELECT e.*, r.chunk_num
FROM ledger_export e JOIN ranked r USING (loyalty_account_id);"""


def sql_setup(cutover_ts: str) -> str:
    """Pin the 3-tier map + de-collide + chunk-assigned ledger; build the §P1 unresolved surface.
    Runs as the session role (owns the transient tables). No cross-statement drift downstream."""
    return f"""
USE WAREHOUSE {WH};

-- 1) pin the raw 3-tier union map (fan-id -> loyalty-id, one row per fan-id) ----------
CREATE OR REPLACE TRANSIENT TABLE {MAP_SNAP} AS
WITH {_map_cte_body()}
SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM loyalty_map;

-- 2) pin the DE-COLLIDE (fan-id -> effective loyalty id + is_primary/dup_group) -------
{sql_effective_snapshot().strip()}

-- 3) materialize the ledger export + a STABLE chunk_num (chunk by effective_loyalty_id)
--    (deleted accounts INCLUDED per Suneel — they become stale in the new ledger)
{sql_ledger_snapshot(cutover_ts).strip()}

-- 4) §P1 DATA-LOSS SURFACE: fan-ids with points-bearing ledger activity that resolve in NONE
--    of the 3 tiers (no account created -> their tx are silently dropped). Gate on points.
CREATE OR REPLACE TABLE {UNRESOLVED} AS
WITH active_fanids AS (
    SELECT DISTINCT PRIVATE_FAN_ID
    FROM {LEDGER_TABLE}
    WHERE COALESCE(EXTERNAL_ID_TYPE, '') NOT IN ('OVERRIDE', 'NON_TRANSACTOR')
      AND (COALESCE(DERIVED_TIER_POINTS_AMOUNT, 0) <> 0 OR NOTES = 'EOY-Rollover')
      AND COALESCE(IS_TEST_TRANSACTION, FALSE) <> TRUE
)
SELECT af.PRIVATE_FAN_ID,
       (SELECT SUM(GREATEST(l.DERIVED_TIER_POINTS_AMOUNT, 0))
        FROM {LEDGER_TABLE} l WHERE l.PRIVATE_FAN_ID = af.PRIVATE_FAN_ID) AS points_at_stake
FROM active_fanids af
WHERE NOT EXISTS (SELECT 1 FROM {MAP_SNAP} m WHERE m.PRIVATE_FAN_ID = af.PRIVATE_FAN_ID);
"""


def sql_count_chunks() -> str:
    return f"USE WAREHOUSE {WH};\nSELECT MAX(chunk_num) + 1 AS n_chunks FROM {LEDGER_SNAP};"


def sql_fmti(env: str) -> str:
    # 39 cols; keyed on effective_loyalty_id; dedup per fan-id; cohort = active_source_loyalty.
    # Balances -> DECIMAL(38,2); timestamps formatted UTC 'Z' (our COPY-INTO convention).
    return f"""
COPY INTO {stage(env)}/fmti/fmti.csv.gz
FROM (
  WITH {_active_source_loyalty_cte()}
  SELECT
      e.effective_loyalty_id AS loyalty_id,
      m."Id__c" AS id,
      m."MembershipNumber_c__c" AS privatefanid,
      m."InviteOnlyApprovals_c__c" AS inviteonlyapprovals,
      m."PlacementTierOverrideName_c__c" AS placementtieroverridename,
      {ltz('m."PlacementStart_c__c"', 'placementstart')},
      {ltz('m."PlacementExpiry_c__c"', 'placementexpiry')},
      m."PlacementNote_c__c" AS placementnote,
      m."PlacementExtraData_c__c" AS placementextradata,
      m."StatusMatchTierOverrideName_c__c" AS statusmatchtieroverridename,
      {ltz('m."StatusMatchStart_c__c"', 'statusmatchstart')},
      {ltz('m."StatusMatchExpiry_c__c"', 'statusmatchexpiry')},
      m."StatusMatchNote_c__c" AS statusmatchnote,
      m."StatusMatchExtraData_c__c" AS statusmatchextradata,
      {ltz('m."TrialStart_c__c"', 'trialstart')},
      {ltz('m."TrialExpiry_c__c"', 'trialexpiry')},
      m."TrialTargetPoints_c__c" AS trialtargetpoints,
      m."TrialStartTierPoints_c__c" AS trialstarttierpoints,
      m."TrialStartLifetimeTierPoints_c__c" AS trialstartlifetimetierpoints,
      m."TrialStartRolloverTierPoints_c__c" AS trialstartrollovertierpoints,
      m."RolloverTierOverrideName_c__c" AS rollovertieroverridename,
      {ltz('m."RolloverStart_c__c"', 'rolloverstart')},
      {ltz('m."RolloverExpiry_c__c"', 'rolloverexpiry')},
      m."RollOverNote_c__c" AS rollovernote,
      m."RolloverExtraData_c__c" AS rolloverextradata,
      TRY_TO_DECIMAL(m."RolloverBalance_c__c"::VARCHAR, 38, 2)          AS rolloverbalance,
      TRY_TO_NUMBER(NULLIF(TRIM(m."RolloverBalanceYear_c__c"::VARCHAR), ''))::INT      AS rolloverbalanceyear,
      TRY_TO_NUMBER(NULLIF(TRIM(m."BalanceOnLastRolloverYear_c__c"::VARCHAR), ''))::INT AS balanceonlastrolloveryear,
      TRY_TO_DECIMAL(m."TierPointsBeforeRollOver_c__c"::VARCHAR, 38, 2) AS tierpointsbeforerollover,
      m."RolloverPercent_c__c" AS rolloverpercent,
      TRY_TO_DECIMAL(m."LTTPMigrationF_c__c"::VARCHAR, 38, 2) AS lt_currentvalue,
      TRY_TO_DECIMAL(m."SMTPMigration_c__c"::VARCHAR, 38, 2)  AS sm_currentvalue,
      TRY_TO_DECIMAL(m."TPMigration_c__c"::VARCHAR, 38, 2)    AS tp_pointsbalance,
      m."isManuallyInviteApproved_c__c" AS manual_invite_approval,
      m."isInviteApprovedOnSmBlack_c__c" AS sm_invite_approval,
      m."isInviteApprovedOnPlacementBlack_c__c" AS placement_invite_approval,
      e.source_loyalty_id AS source_loyalty_id,   -- col 37 (original loyalty id)
      e.is_primary        AS is_primary,          -- col 38
      e.dup_group         AS dup_group            -- col 39 (drives metadata write)
  FROM {EFF_SNAP} e
  JOIN {FMTI_TABLE} m ON m."MembershipNumber_c__c" = e.private_fan_id
  WHERE e.source_loyalty_id IN (SELECT LOYALTY_ACCOUNT_ID::VARCHAR FROM active_source_loyalty)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY e.private_fan_id
    ORDER BY m."LastModifiedDate__c" DESC NULLS LAST, m."Id__c" DESC) = 1
)
{FILE_FORMAT}
{COPY_OPTS};
"""


def sql_overrides(env: str) -> str:
    # 20 cols; keyed on effective_loyalty_id; CDC feed (keep rows with override data OR that follow
    # one, so override-cleared transitions are captured). Timestamps formatted; window on raw LTZ.
    return f"""
COPY INTO {stage(env)}/override_cdc/overrides.csv.gz
FROM (
  WITH override_rows AS (
    SELECT
        e.effective_loyalty_id AS loyalty_account_id, o.PRIVATE_FAN_ID, o.LAST_MODIFIED_DATE, o.INVITE_ONLY_APPROVALS,
        o.PLACEMENT_TIER_OVERRIDE_NAME, o.PLACEMENT_START, o.PLACEMENT_EXPIRY, o.PLACEMENT_NOTE, o.PLACEMENT_EXTRA_DATA,
        o.STATUS_MATCH_TIER_OVERRIDE_NAME, o.STATUS_MATCH_START, o.STATUS_MATCH_EXPIRY, o.STATUS_MATCH_NOTE, o.STATUS_MATCH_EXTRA_DATA,
        o.TRIAL_START, o.TRIAL_EXPIRY, o.TRIAL_TARGET_POINTS, o.TRIAL_START_TIER_POINTS,
        o.TRIAL_START_LIFETIME_TIER_POINTS, o.TRIAL_START_ROLLOVER_TIER_POINTS,
        CASE WHEN {_has_override_data('o')} THEN 1 ELSE 0 END AS has_override_data
    FROM {OVERRIDES_TABLE} o
    JOIN {EFF_SNAP} e ON e.private_fan_id = o.PRIVATE_FAN_ID
  ),
  override_history AS (
    SELECT override_rows.*,
           MAX(has_override_data) OVER (
               PARTITION BY PRIVATE_FAN_ID ORDER BY LAST_MODIFIED_DATE
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS had_previous_override
    FROM override_rows
  )
  SELECT
      loyalty_account_id,
      PRIVATE_FAN_ID,
      {ltz('LAST_MODIFIED_DATE', 'last_modified_date')},
      INVITE_ONLY_APPROVALS,
      PLACEMENT_TIER_OVERRIDE_NAME,
      {ltz('PLACEMENT_START', 'placement_start')},
      {ltz('PLACEMENT_EXPIRY', 'placement_expiry')},
      PLACEMENT_NOTE,
      PLACEMENT_EXTRA_DATA,
      STATUS_MATCH_TIER_OVERRIDE_NAME,
      {ltz('STATUS_MATCH_START', 'status_match_start')},
      {ltz('STATUS_MATCH_EXPIRY', 'status_match_expiry')},
      STATUS_MATCH_NOTE,
      STATUS_MATCH_EXTRA_DATA,
      {ltz('TRIAL_START', 'trial_start')},
      {ltz('TRIAL_EXPIRY', 'trial_expiry')},
      TRIAL_TARGET_POINTS,
      TRIAL_START_TIER_POINTS,
      TRIAL_START_LIFETIME_TIER_POINTS,
      TRIAL_START_ROLLOVER_TIER_POINTS
  FROM override_history
  WHERE (has_override_data = 1 OR COALESCE(had_previous_override, 0) = 1)
  ORDER BY loyalty_account_id, LAST_MODIFIED_DATE
)
{FILE_FORMAT}
{COPY_OPTS};
"""


def sql_ledger_chunk(env: str, n: int) -> str:
    # One file per chunk; reads the FIXED snapshot -> no drift, account fully in one chunk.
    return f"""
COPY INTO {stage(env)}/ledger/chunk_{n:05d}/chunk_{n:05d}.csv.gz
FROM (
  SELECT {LEDGER_OUT_COLS}
  FROM {LEDGER_SNAP}
  WHERE chunk_num = {n}
  ORDER BY loyalty_account_id, transaction_timestamp
)
{FILE_FORMAT}
{COPY_OPTS};
"""


def sql_verify() -> str:
    # Go/no-go gate. §P2 cohort integrity: every effective loyalty id in the ledger/override export
    # MUST have an FMTI row (both counts = 0). §P1 data-loss: unresolved-active fan-ids + points at
    # stake (should be 0 / tiny; escalate the list if points are material). Plus scope counts.
    return f"""
USE WAREHOUSE {WH};
WITH {_active_source_loyalty_cte()},
fmti_eff AS (   -- effective ids the FMTI export emits (mirrors sql_fmti's cohort filter)
    SELECT DISTINCT e.effective_loyalty_id AS loyalty_account_id
    FROM {EFF_SNAP} e
    WHERE e.source_loyalty_id IN (SELECT LOYALTY_ACCOUNT_ID::VARCHAR FROM active_source_loyalty)
),
ledger_eff AS (SELECT DISTINCT loyalty_account_id FROM {LEDGER_SNAP}),
override_eff AS (
    SELECT DISTINCT e.effective_loyalty_id AS loyalty_account_id
    FROM {OVERRIDES_TABLE} o JOIN {EFF_SNAP} e ON e.private_fan_id = o.PRIVATE_FAN_ID
    WHERE {_has_override_data('o')}
)
SELECT
  (SELECT COUNT(*) FROM ledger_eff)                              AS ledger_members,
  (SELECT MAX(chunk_num) + 1 FROM {LEDGER_SNAP})                 AS n_chunks,
  (SELECT COUNT(*) FROM fmti_eff)                                AS fmti_accounts,
  (SELECT COUNT(*) FROM override_eff)                            AS override_members,
  (SELECT COUNT(*) FROM {EFF_SNAP} WHERE dup_group)              AS decollide_secondary_or_dup,
  (SELECT COUNT(*) FROM ledger_eff
     WHERE loyalty_account_id NOT IN (SELECT loyalty_account_id FROM fmti_eff))
                                                                 AS ledger_missing_account,   -- MUST be 0
  (SELECT COUNT(*) FROM override_eff
     WHERE loyalty_account_id NOT IN (SELECT loyalty_account_id FROM fmti_eff))
                                                                 AS overrides_missing_account, -- MUST be 0
  (SELECT COUNT(*) FROM {UNRESOLVED})                            AS unresolved_active_fanids,  -- §P1
  (SELECT COALESCE(SUM(points_at_stake), 0) FROM {UNRESOLVED})   AS unresolved_points_at_stake;
"""


def sql_cleanup() -> str:
    return (f"DROP TABLE IF EXISTS {LEDGER_SNAP};\n"
            f"DROP TABLE IF EXISTS {EFF_SNAP};\n"
            f"DROP TABLE IF EXISTS {MAP_SNAP};\n"
            f"-- (keep {UNRESOLVED} for reference)")


if __name__ == "__main__":
    a = sys.argv[1:]
    mode = a[0] if a else "help"
    if mode == "setup":       print(sql_setup(a[1]))
    elif mode == "fmti":      print(sql_fmti(a[1] if len(a) > 1 else "perf"))
    elif mode == "overrides": print(sql_overrides(a[1] if len(a) > 1 else "perf"))
    elif mode == "chunk":     print(sql_ledger_chunk(a[1] if len(a) > 1 else "perf", int(a[2])))
    elif mode == "count":     print(sql_count_chunks())
    elif mode == "verify":    print(sql_verify())
    elif mode == "cleanup":   print(sql_cleanup())
    elif mode == "effective": print(sql_effective_snapshot())
    else:                     print(__doc__)
