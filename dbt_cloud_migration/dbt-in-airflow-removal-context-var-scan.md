# Phase 0 §0.4 — context-var / data-interval scan

Scanning .sql files for models tagged with one of the 8 ingest tags (against dbt-fes-ae/fix/fusion-parse-cleanup — CI-only delta vs origin/main).


## `mdm_sdp` — 3 models
  ✅ no interval-context references
  ℹ️ other `var(...)` refs (may be static config, not runtime):
    - `mdm_cd_tenerife_team_id` → in 2 model(s)
    - `mdm_college_league_id` → in 3 model(s)
    - `mdm_donnie_allison_team_id` → in 2 model(s)
    - `mdm_international_clubs_league_id` → in 2 model(s)
    - `mdm_mls_league_id` → in 2 model(s)
    - `mdm_nascar_league_id` → in 2 model(s)
    - `mdm_nathan_frazer_team_id` → in 2 model(s)
    - `mdm_san_diego_fc_team_id` → in 2 model(s)
    - `mdm_uconn_huskies_team_id` → in 2 model(s)
    - `mdm_wwe_league_id` → in 2 model(s)
    - `sdp_ncaaf_league_id` → in 1 model(s)
    - `sdp_ncaamb_league_id` → in 1 model(s)

## `google_ad_manager` — 9 models
  ✅ no interval-context references

## `identity` — 5 models
  **⚠ 2 interval-context hits** → job likely needs steps_override:
    - `loyalty_private_fan_id_map` uses `data_interval_start` (`models/identity/orchestration/loyalty_private_fan_id_map.sql`)
    - `martech_private_fan_id_map` uses `data_interval_start` (`models/identity/orchestration/martech_private_fan_id_map.sql`)

## `impact` — 1 models
  ✅ no interval-context references

## `fesbonus` — 8 models
  ✅ no interval-context references

## `fesloyalty` — 25 models
  ✅ no interval-context references

## `magnite` — 1 models
  ✅ no interval-context references

## `optin_preferences` — 6 models
  **⚠ 4 interval-context hits** → job likely needs steps_override:
    - `xp_optin_preferences_delta` uses `data_interval_end` (`models/xtremepush/xp_optin_preferences_delta.sql`)
    - `xp_optin_preferences_snapshot` uses `data_interval_end` (`models/xtremepush/xp_optin_preferences_snapshot.sql`)
    - `xp_push_last_opened_delta` uses `data_interval_end` (`models/xtremepush/xp_push_last_opened_delta.sql`)
    - `xp_push_last_opened_snapshot` uses `data_interval_end` (`models/xtremepush/xp_push_last_opened_snapshot.sql`)
  ℹ️ other `var(...)` refs (may be static config, not runtime):
    - `tenant_id_fanapp` → in 1 model(s)


## Bulk grep sanity — any interval keyword anywhere in the 8 tag file paths?
  [mdm_sdp] `{{ var(` → 2 file(s): ['mdm_to_sdp_leagues.sql', 'mdm_to_sdp_teams.sql']
  [identity] `data_interval_start` → 2 file(s): ['loyalty_private_fan_id_map.sql', 'martech_private_fan_id_map.sql']
  [identity] `{{ var(` → 2 file(s): ['loyalty_private_fan_id_map.sql', 'martech_private_fan_id_map.sql']
  [optin_preferences] `data_interval_end` → 4 file(s): ['xp_optin_preferences_delta.sql', 'xp_optin_preferences_snapshot.sql', 'xp_push_last_opened_delta.sql', 'xp_push_last_opened_snapshot.sql']
  [optin_preferences] `{{ var(` → 5 file(s): ['xp_optin_preferences.sql', 'xp_optin_preferences_delta.sql', 'xp_optin_preferences_snapshot.sql', 'xp_push_last_opened_delta.sql', 'xp_push_last_opened_snapshot.sql']


## Summary table

| tag | models | interval hits | other var() refs | env_var refs | needs steps_override? |
|---|---|---|---|---|---|
| `mdm_sdp` | 3 | 0 | 12 | 0 | no |
| `google_ad_manager` | 9 | 0 | 0 | 0 | no |
| `identity` | 5 | 2 | 0 | 0 | **YES** |
| `impact` | 1 | 0 | 0 | 0 | no |
| `fesbonus` | 8 | 0 | 0 | 0 | no |
| `fesloyalty` | 25 | 0 | 0 | 0 | no |
| `magnite` | 1 | 0 | 0 | 0 | no |
| `optin_preferences` | 6 | 4 | 1 | 0 | **YES** |
