
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

-- 1) pin the raw 3-tier union map (fan-id -> loyalty-id, one row per fan-id) ----------
CREATE OR REPLACE TRANSIENT TABLE FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT AS
WITH new_map AS (                                             -- tier 1: identity service
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID
    FROM identity.orchestration.loyalty_private_fan_id_map
    WHERE LOYALTY_ACCOUNT_ID IS NOT NULL
    -- 1 PRIVATE_FAN_ID can map to >1 LOYALTY_ACCOUNT_ID (e.g. loyalty account recreated). Take the
    -- LATEST-CREATED loyalty id (tie-break on the id for determinism) -- NOT lexical ORDER BY id.
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PRIVATE_FAN_ID
            ORDER BY CREATED DESC NULLS LAST, LOYALTY_ACCOUNT_ID) = 1
),
distinct_fanids AS (                                         -- tier 2: prod email-chain entry
    SELECT DISTINCT PRIVATE_FANID FROM commerce_dev.source.scylla_tenant_fanid_ext WHERE PRIVATE_FANID IS NOT NULL
),
fanid_to_auth AS (
    SELECT df.PRIVATE_FANID, a.AUTH_ID FROM distinct_fanids df
    JOIN fde.fde_info.auth_id a ON a.PRIVATE_FAN_ID = df.PRIVATE_FANID WHERE a.AUTH_ID IS NOT NULL
),
auth_to_account_internal AS (
    SELECT fa.PRIVATE_FANID, ail.ACCOUNT_INTERNAL_ID FROM fanid_to_auth fa
    JOIN fde.fde_info.account_internal_id_lkp ail ON ail.AUTH_ID = fa.AUTH_ID WHERE ail.ACCOUNT_INTERNAL_ID IS NOT NULL
),
account_user_service_id_pick AS (
    SELECT ACCOUNT_ID, TO_VARCHAR(DATA:"1094") AS ACCOUNT_USER_SERVICE_ID, MODIFIED,
        ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID
            ORDER BY (SUBSTR(MODIFIED,15,4)||SUBSTR(MODIFIED,10,4)||SUBSTR(MODIFIED,1,8)) DESC, MODIFIED DESC) AS rn
    FROM fde.fde_info.account_user_service_id
    WHERE ACCOUNT_ID IS NOT NULL AND DATA:"1094" IS NOT NULL AND SUBSTR(MODIFIED,15,1) = '1'
),
account_internal_to_user_service AS (
    SELECT aai.PRIVATE_FANID, aai.ACCOUNT_INTERNAL_ID, pick.ACCOUNT_USER_SERVICE_ID FROM auth_to_account_internal aai
    JOIN account_user_service_id_pick pick ON pick.ACCOUNT_ID = aai.ACCOUNT_INTERNAL_ID AND pick.rn = 1
),
customer_account_map_latest AS (
    SELECT SURROGATE_ACCOUNT_KEY, HASHED_EMAIL, LAST_MODIFIED_TIME,
        ROW_NUMBER() OVER (PARTITION BY SURROGATE_ACCOUNT_KEY ORDER BY LAST_MODIFIED_TIME DESC) AS rn
    FROM commerce.fan_key.customer_account_map
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
    FROM cde.cde_core.loyalty_account WHERE HASHED_EMAIL IS NOT NULL AND LOYALTY_ACCOUNT_ID IS NOT NULL
),
email_map AS (
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM (
        SELECT ushe.PRIVATE_FANID AS PRIVATE_FAN_ID, lap.LOYALTY_ACCOUNT_ID
        FROM user_service_to_hashed_email ushe
        JOIN loyalty_account_pick lap ON lap.HASHED_EMAIL = ushe.HASHED_EMAIL AND lap.rn = 1
    ) QUALIFY ROW_NUMBER() OVER (PARTITION BY PRIVATE_FAN_ID ORDER BY LOYALTY_ACCOUNT_ID) = 1
),
old_map AS (                                                 -- tier 3: legacy tenant map
    SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM LOYALTY.LOYALTY_INFO.LOYALTY_ACCOUNT_ID_FAN_ID_TENANT_MAP
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
)
SELECT PRIVATE_FAN_ID, LOYALTY_ACCOUNT_ID FROM loyalty_map;

-- 2) pin the DE-COLLIDE (fan-id -> effective loyalty id + is_primary/dup_group) -------
CREATE OR REPLACE TRANSIENT TABLE FES_USERS.ALEX_SOTIS.TP_EFFECTIVE_SNAPSHOT AS
WITH fb AS (
    SELECT lm.LOYALTY_ACCOUNT_ID                                   AS source_loyalty_id,
           m."MembershipNumber_c__c"                               AS pfid,
           TRY_TO_DECIMAL(m."TPMigration_c__c"::VARCHAR, 38, 2)    AS active,
           TRY_TO_DECIMAL(m."LTTPMigrationF_c__c"::VARCHAR, 38, 2) AS lt,
           TRY_TO_DECIMAL(m."SMTPMigration_c__c"::VARCHAR, 38, 2)  AS sm,
           m."LastModifiedDate__c"                                 AS lmd,
           m."Id__c"                                               AS id
    FROM SALESFORCE."schema_FanJourney_Loyalty_Promotion_Shares"."FanMemberTierInformation_00DHs000003WzIz__dll" m
    JOIN FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT lm ON lm.PRIVATE_FAN_ID = m."MembershipNumber_c__c"
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
    CASE WHEN rn = 1 THEN source_loyalty_id::VARCHAR
             ELSE LEFT(UUID_STRING('e5567350-8395-4672-b41f-45f9bcbe4047', pfid || ':' || source_loyalty_id::VARCHAR), 14) || '1' || SUBSTR(UUID_STRING('e5567350-8395-4672-b41f-45f9bcbe4047', pfid || ':' || source_loyalty_id::VARCHAR), 16) END AS effective_loyalty_id,
    (rn = 1)                                AS is_primary,
    (grp_size > 1)                          AS dup_group
FROM ranked;

-- 3) materialize the ledger export + a STABLE chunk_num (chunk by effective_loyalty_id)
--    (deleted accounts INCLUDED per Suneel — they become stale in the new ledger)
CREATE OR REPLACE TRANSIENT TABLE FES_USERS.ALEX_SOTIS.TP_LEDGER_SNAPSHOT AS
WITH ledger_export AS (
    SELECT 
        TO_CHAR(CONVERT_TIMEZONE('UTC', l.TRANSACTION_TIMESTAMP), 'YYYY-MM-DD HH24:MI:SS.FF3') || ' Z' AS transaction_timestamp,
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
        l.TIER_POINTS_MULTIPLIER           AS tier_points_multiplier
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 l
    JOIN FES_USERS.ALEX_SOTIS.TP_EFFECTIVE_SNAPSHOT e ON e.private_fan_id = l.PRIVATE_FAN_ID
    WHERE 1=1
      AND (COALESCE(l.DERIVED_TIER_POINTS_AMOUNT, 0) <> 0 OR l.NOTES = 'EOY-Rollover')
      AND COALESCE(l.EXTERNAL_ID_TYPE, '') NOT IN ('OVERRIDE', 'NON_TRANSACTOR')
      AND COALESCE(l.NOTES, '') <> 'TierPoints 10x Loyalty Program'
      AND l.TRANSACTION_TIMESTAMP IS NOT NULL
      AND COALESCE(l.IS_TEST_TRANSACTION, FALSE) <> TRUE
      AND l.TRANSACTION_TIMESTAMP < '2026-08-10 12:00:00'::TIMESTAMP_LTZ
),
ranked AS (
    SELECT loyalty_account_id,
           FLOOR((DENSE_RANK() OVER (ORDER BY loyalty_account_id) - 1) / 200000) AS chunk_num
    FROM (SELECT DISTINCT loyalty_account_id FROM ledger_export)
)
SELECT e.*, r.chunk_num
FROM ledger_export e JOIN ranked r USING (loyalty_account_id);

-- 4) §P1 DATA-LOSS SURFACE: fan-ids with points-bearing ledger activity that resolve in NONE
--    of the 3 tiers (no account created -> their tx are silently dropped). Gate on points.
CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.TP_MIGRATION_UNRESOLVED AS
WITH active_fanids AS (
    SELECT DISTINCT PRIVATE_FAN_ID
    FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2
    WHERE COALESCE(EXTERNAL_ID_TYPE, '') NOT IN ('OVERRIDE', 'NON_TRANSACTOR')
      AND (COALESCE(DERIVED_TIER_POINTS_AMOUNT, 0) <> 0 OR NOTES = 'EOY-Rollover')
      AND COALESCE(IS_TEST_TRANSACTION, FALSE) <> TRUE
)
SELECT af.PRIVATE_FAN_ID,
       (SELECT SUM(GREATEST(l.DERIVED_TIER_POINTS_AMOUNT, 0))
        FROM LOYALTY.LOYALTY_INFO.TIER_POINTS_LEDGER_V2 l WHERE l.PRIVATE_FAN_ID = af.PRIVATE_FAN_ID) AS points_at_stake
FROM active_fanids af
WHERE NOT EXISTS (SELECT 1 FROM FES_USERS.ALEX_SOTIS.TP_MAP_SNAPSHOT m WHERE m.PRIVATE_FAN_ID = af.PRIVATE_FAN_ID);

