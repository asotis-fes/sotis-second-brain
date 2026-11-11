-- CORRECTED status_match CTE for models/loyalty/fanatics_one/tier_points_ledger_v2.sql
-- Replaces both the original CTE and PR #66's version.
--
-- Rule: an override interval's trial_target_points is still in 1x scale IFF the interval
-- ended before the 10x launch (interval_end <= 10x_launch_timestamp). Those get ×10.
-- Intervals active at launch (migrated in place) or created after launch are already 10x
-- and are left unchanged. Null-override gap rows are untouched.
--
-- This is simpler than PR #66 (no window function) and correct for 33,231/33,232 intervals
-- (the one exception is a single GOLDTEST500 test override — see queries.md).

status_match AS (
    SELECT
        salesforce_member_id,
        private_fan_id,
        override_id,
        interval_start AS start_override_active,
        interval_end AS end_override_active,
        override_tier AS status_match_tier_name,
        override_tier_rank AS status_match_tier_name_rank,
        override_expiry AS status_match_expiry,
        CASE
            WHEN override_id IS NULL THEN trial_target_points                       -- gap rows untouched
            WHEN interval_end <= '{{ var("10x_launch_timestamp") }}'
                THEN trial_target_points * 10                                       -- interval ended pre-launch: 1x -> x10
            ELSE trial_target_points                                                -- active-at / post-launch: already 10x
        END AS trial_target_points,
        interval_start AS trial_start,
        trial_expiry
    FROM {{ ref('tier_points_overrides__status_match') }}
),
