-- ⭐ CHOSEN FIX — upstream in models/loyalty/fanatics_one/tier_points_overrides__status_match.sql
--
-- Normalize trial_target_points to a single 10x scale at the SNAPSHOT level, using
-- last_modified_date (the exact signal, same one pfi_status_matches uses). The flatten
-- macro's MAX(trial_target_points) then yields the correct 10x value per interval.
--
-- Rule per raw CDC snapshot:
--   last_modified_date <  10x_launch_timestamp  -> value is 1x  -> x10
--   last_modified_date >= 10x_launch_timestamp  -> value already 10x (migrated in place
--                                                   on 4/23, or created natively post-launch) -> keep
--
-- Why snapshot-level (not interval_end in the ledger):
--   * exact — handles the one migration-fuzzy-window row (real "Gold Fast Track" customer
--     GOLDTEST500 / fan 3aef9dfc) that the interval_end proxy gets wrong;
--   * fixes BOTH consumers of this model in one place;
--   * MAX over the flatten group is dominated by the migrated (10x) snapshot when one exists,
--     so pre-launch 1x snapshots that get x10'd never override it.

-- =============================================================================
-- EDIT: in the `status_match` CTE (currently ~line 40), replace this single line:
--
--        o.trial_target_points,
--
-- with:
--
--        iff(
--            o.last_modified_date < '{{ var("10x_launch_timestamp") }}',
--            o.trial_target_points * 10,   -- pre-launch snapshot: 1x -> x10
--            o.trial_target_points          -- migrated / native post-launch: already 10x
--        ) AS trial_target_points,
-- =============================================================================

-- Full corrected `status_match` CTE for reference:
status_match AS ( --noqa: disable=ST03
    SELECT DISTINCT
        o.salesforce_member_id,
        o.private_fan_id,
        coalesce(o.trial_start, o.last_modified_date) AS override_start,
        coalesce(lead(override_start) OVER (PARTITION BY o.salesforce_member_id ORDER BY override_start), '9999-12-31'::timestamp_ntz) AS override_end,
        o.status_match_tier_override_name AS override_id,
        o.status_match_tier_name AS override_tier,
        status_match_rank.tier_rank AS override_tier_rank,
        o.status_match_expiry AS override_expiry,
        o.original_override_start,
        -- 10x fix: pre-launch snapshots stored the target in 1x; migrated/native are already 10x
        iff(
            o.last_modified_date < '{{ var("10x_launch_timestamp") }}',
            o.trial_target_points * 10,
            o.trial_target_points
        ) AS trial_target_points,
        o.trial_start,
        o.trial_expiry,
        valid_trials.status_match_tier_override_name
    FROM remove_empty_rows_before_first_status_match AS o
    LEFT JOIN valid_trials
        ON
            o.private_fan_id = valid_trials.private_fan_id
            AND o.status_match_tier_override_name = valid_trials.status_match_tier_override_name
            AND o.trial_start = valid_trials.trial_start
    LEFT JOIN {{ ref('tier_points_tiers_info') }} AS status_match_rank
        ON o.status_match_tier_name = status_match_rank.tier_name
    WHERE override_id IS NULL OR valid_trials.status_match_tier_override_name IS NOT NULL
),

-- NOTE: after this fix, the `status_match` CTE in tier_points_ledger_v2.sql should be
-- REVERTED to its original passthrough (no x10 there) and PR #66 abandoned, since the
-- column arrives already normalized:
--
--   status_match AS (
--       SELECT salesforce_member_id, private_fan_id, override_id,
--              interval_start AS start_override_active, interval_end AS end_override_active,
--              override_tier AS status_match_tier_name, override_tier_rank AS status_match_tier_name_rank,
--              override_expiry AS status_match_expiry,
--              trial_target_points,               -- already 10x-normalized upstream
--              interval_start AS trial_start, trial_expiry
--       FROM {{ ref('tier_points_overrides__status_match') }}
--   ),
