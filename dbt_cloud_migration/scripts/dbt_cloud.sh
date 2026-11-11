#!/usr/bin/env bash
#
# dbt Cloud REST API driver — scoped strictly to the dbt-fes-ae project.
#
# NEVER touches other projects in the same dbt Cloud account. Before any
# writes, provision-jobs GETs the project + environment records and prints
# their names, then requires interactive 'yes' confirmation (or --yes flag).
#
# Auth: expects DBT_CLOUD_TOKEN in env. Never write the token to disk, never
# echo it to logs, never commit it to git.
#
# Discover the token from SSM (dev, per D-06/D28):
#   aws ssm get-parameter --name /airflow/connections/dbt_cloud_ae \
#       --profile fes-data-compute-dev --with-decryption \
#       --query 'Parameter.Value' --output text
#   # value format: dbt-cloud://<account_id>:<token>@<host>
#   # Extract account_id, token, host from the URI.
#
# Subcommands:
#   discover        — read-only: list projects, environments, existing jobs
#   provision-jobs  — create the deploy jobs (requires DBT_CLOUD_PROJECT_ID
#                     and DBT_CLOUD_ENVIRONMENT_ID). Supports --dry-run and
#                     --yes flags.
#
# Jobs are created with state=1 and all triggers.* set to false. See yolo/
# discoveries.md D-18 for why state=2 is not "paused" (it's soft-delete).
#
set -euo pipefail

# Auto-source .env at the repo root if present. Convenience — same effect as
# `set -a; source .env; set +a` before invoking.
_REPO_ROOT="$HOME/repos/fes-airflow"
if [[ -f "${_REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${_REPO_ROOT}/.env"
    set +a
fi

: "${DBT_CLOUD_TOKEN:?DBT_CLOUD_TOKEN required (in .env or exported)}"
: "${DBT_CLOUD_ACCOUNT_ID:?DBT_CLOUD_ACCOUNT_ID required (in .env or exported)}"
: "${DBT_CLOUD_HOST:=sh023.us1.dbt.com}"

BASE_URL="https://${DBT_CLOUD_HOST}/api/v2/accounts/${DBT_CLOUD_ACCOUNT_ID}"
V3_URL="https://${DBT_CLOUD_HOST}/api/v3/accounts/${DBT_CLOUD_ACCOUNT_ID}"

# ---- utility ---------------------------------------------------------------

_get() {
    curl --silent --show-error --fail \
        --header "Authorization: Token ${DBT_CLOUD_TOKEN}" \
        --header "Accept: application/json" \
        "$1"
}

_post() {
    # $1 = URL, $2 = JSON body
    # --fail-with-body: exit non-zero on 4xx/5xx but still print the response
    # body so we see dbt Cloud's error message (unlike --fail which suppresses).
    curl --silent --show-error --fail-with-body \
        --header "Authorization: Token ${DBT_CLOUD_TOKEN}" \
        --header "Content-Type: application/json" \
        --header "Accept: application/json" \
        --data "$2" \
        "$1"
}

_confirm_target() {
    # Print the target project + env NAMES loudly, then require explicit
    # confirmation before doing any writes. --yes bypasses (for CI or when
    # the caller has already visually verified).
    local pid="$1"
    local eid="$2"
    local skip_prompt="$3"

    local project_name env_name env_type
    project_name=$(_get "${BASE_URL}/projects/${pid}/" | jq -r '.data.name // "UNKNOWN"')
    local env_json
    env_json=$(_get "${V3_URL}/projects/${pid}/environments/${eid}/")
    env_name=$(echo "$env_json" | jq -r '.data.name // "UNKNOWN"')
    env_type=$(echo "$env_json" | jq -r '.data.deployment_type // .data.type // "UNKNOWN"')

    cat >&2 <<EOF

  Target project     : ${project_name}  (id=${pid})
  Target environment : ${env_name}      (id=${eid}, type=${env_type})
  Job count          : ${#_JOB_ROWS[@]}
  Job state          : 1 (active), all triggers false — Airflow-only

EOF

    if [[ "$skip_prompt" == "1" ]]; then
        echo "  (--yes given, skipping interactive confirmation)" >&2
        return
    fi

    read -r -p "  Proceed? Type 'yes' to continue: " reply
    if [[ "$reply" != "yes" ]]; then
        echo "  aborted." >&2
        exit 1
    fi
}

# ---- DAG → deploy-job mapping ----------------------------------------------
# Kept inline so nothing external can steer creation at other projects.
# Every row: dag_name | steps (semicolon-separated for multi-step)
_JOB_ROWS=(
    "dbt_loyalty|dbt build --select tag:loyalty"
    "dbt_loyalty_6hours|dbt build --select tag:loyalty_6hours"
    "dbt_loyalty_metrics|dbt build --select tag:loyalty_metrics"
    "dbt_loyalty_monthly_snapshot|dbt build --select tag:loyalty_monthly"
    "dbt_fanflow|dbt build --select tag:fanflow"
    "dbt_hourly|dbt build --select tag:hourly"
    "dbt_daily|dbt build --select tag:daily"
    "dbt_daily_9am|dbt build --select tag:daily_9am"
    "dbt_every_3hours|dbt build --select tag:3hours"
    "dbt_every_6hours|dbt build --select tag:6hours"
    "dbt_weekly|dbt build --select tag:weekly;dbt run-operation refresh_eval_ground_truth"
    "dbt_meta_ads|dbt build --select tag:meta_ads"
    "dbt_ltv|dbt build --select tag:ltv"
    "dbt_mde|dbt build --select tag:mde"
    "dbt_fanapp_recs|dbt build --select tag:fanapp_recs"
    "dbt_enterprise_metrics|dbt build --select tag:enterprise_metrics"
    "dbt_enterprise_metrics_daily|dbt build --select tag:enterprise_metrics_daily"
    "dbt_fanatics_one|dbt build --select tag:fanaticsone"
    "dbt_xtremepush|dbt build --select tag:xtremepush"
    "dbt_users|dbt build --select tag:users"
    "dbt_sources|dbt source freshness"
    "dbt_fangraph|dbt build --selector fangraph"
    # Ingest-DAG-triggered jobs (Airflow-triggered, no cron) — see
    # projects/dbt_cloud_migration/dbt-in-airflow-removal.md
    "dbt_fanapp_mdm|dbt build --select tag:mdm_sdp"
    "dbt_google_ad_manager|dbt build --select tag:google_ad_manager"
    "dbt_identity|dbt build --select tag:identity"
    "dbt_impact|dbt build --select tag:impact"
    "dbt_fesbonus|dbt build --select tag:fesbonus"
    "dbt_fesloyalty|dbt build --select tag:fesloyalty"
    "dbt_magnite|dbt build --select tag:magnite"
    "dbt_optin_preferences|dbt build --select tag:optin_preferences"
)

# ---- subcommands -----------------------------------------------------------

cmd_discover() {
    echo "=== Projects ==="
    _get "${BASE_URL}/projects/" | jq -r '.data[] | "  id=\(.id)  name=\(.name)"'
    echo
    if [[ -n "${DBT_CLOUD_PROJECT_ID:-}" ]]; then
        echo "=== Environments in project ${DBT_CLOUD_PROJECT_ID} ==="
        _get "${V3_URL}/projects/${DBT_CLOUD_PROJECT_ID}/environments/" \
            | jq -r '.data[] | "  id=\(.id)  name=\(.name)  type=\(.type)  deployment_type=\(.deployment_type // "null")"'
        echo
        echo "=== Existing jobs in project ${DBT_CLOUD_PROJECT_ID} ==="
        _get "${BASE_URL}/jobs/?project_id=${DBT_CLOUD_PROJECT_ID}" \
            | jq -r '.data[] | "  id=\(.id)  name=\(.name)  env_id=\(.environment_id)  state=\(.state)"'
    else
        echo "(set DBT_CLOUD_PROJECT_ID env var to also list environments + jobs)"
    fi
}

cmd_provision_jobs() {
    : "${DBT_CLOUD_PROJECT_ID:?DBT_CLOUD_PROJECT_ID required (from dbt Cloud UI — project settings URL)}"
    : "${DBT_CLOUD_ENVIRONMENT_ID:?DBT_CLOUD_ENVIRONMENT_ID required (from dbt Cloud UI — Deploy → Environments URL)}"

    local dry_run=0
    local skip_prompt=0
    local only_filters=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            --yes)     skip_prompt=1 ;;
            --only)    shift; only_filters+=("$1") ;;
            *) echo "unknown flag: $1" >&2; exit 1 ;;
        esac
        shift
    done

    if [[ $dry_run -eq 1 ]]; then
        echo "DRY RUN — no POSTs will be executed" >&2
    fi

    _confirm_target "${DBT_CLOUD_PROJECT_ID}" "${DBT_CLOUD_ENVIRONMENT_ID}" "$skip_prompt"

    # Output CSV: dag_name,job_id (or dry-run placeholder). Engineer captures
    # this to feed to write-job-ids.py.
    echo "dag_name,job_id"

    for row in "${_JOB_ROWS[@]}"; do
        local dag_name steps steps_json
        dag_name="${row%%|*}"
        # Apply --only filter if set (repeatable flag)
        if [[ ${#only_filters[@]} -gt 0 ]]; then
            local matched=0
            for f in "${only_filters[@]}"; do
                [[ "$dag_name" == "$f" ]] && { matched=1; break; }
            done
            [[ $matched -eq 0 ]] && continue
        fi
        steps="${row#*|}"
        # Split semicolon-separated steps into a JSON array
        steps_json=$(printf '%s' "$steps" | jq -R -s -c 'split(";")')

        local body
        body=$(jq -n \
            --arg name "$dag_name" \
            --argjson project_id "${DBT_CLOUD_PROJECT_ID}" \
            --argjson env_id "${DBT_CLOUD_ENVIRONMENT_ID}" \
            --argjson account_id "${DBT_CLOUD_ACCOUNT_ID}" \
            --argjson steps "$steps_json" \
            '{
                account_id: $account_id,
                project_id: $project_id,
                environment_id: $env_id,
                name: $name,
                execute_steps: $steps,
                dbt_version: null,
                triggers: {
                    schedule: false,
                    github_webhook: false,
                    git_provider_webhook: false,
                    on_merge: false,
                    custom_branch_only: false
                },
                settings: {
                    threads: 4,
                    target_name: "default"
                },
                generate_docs: false,
                run_generate_sources: false,
                state: 1
            }')

        if [[ $dry_run -eq 1 ]]; then
            echo "${dag_name},DRY_RUN"
            echo "  would POST ${BASE_URL}/jobs/" >&2
            echo "  body: $(echo "$body" | jq -c '.')" >&2
        else
            local resp job_id
            resp=$(_post "${BASE_URL}/jobs/" "$body")
            job_id=$(echo "$resp" | jq -r '.data.id')
            if [[ -z "$job_id" || "$job_id" == "null" ]]; then
                echo "ERROR: create failed for ${dag_name}" >&2
                echo "  response: $resp" >&2
                exit 1
            fi
            echo "${dag_name},${job_id}"
            echo "created: ${dag_name} → job_id=${job_id}" >&2
        fi
    done
}

# ---- dispatch --------------------------------------------------------------

case "${1:-help}" in
    discover)         shift; cmd_discover "$@" ;;
    provision-jobs)   shift; cmd_provision_jobs "$@" ;;
    *)
        cat <<EOF
Usage: $0 <subcommand>

Subcommands:
  discover
      Read-only: list projects, environments (if DBT_CLOUD_PROJECT_ID set),
      and existing jobs. Useful for sanity-checking, not required if you
      already have the IDs from the dbt Cloud UI.

  provision-jobs [--dry-run] [--yes] [--only <name>]...
      Create the 30 dbt Cloud deploy jobs (22 standalone + 8 ingest-triggered).
      Each is created with state=1 (active) but ALL triggers false — dbt Cloud
      will never auto-fire them; they only run when Airflow POSTs to
      /jobs/{id}/run/. Prints target project + env names before starting and
      requires typing 'yes' to proceed (bypass with --yes for CI).

      --only <name>  Provision only jobs whose dag_name matches <name> exactly.
                     Repeatable. Useful when adding new jobs to an existing set
                     without duplicating what's already been provisioned.

Env vars (auto-sourced from .env at repo root if present):
  DBT_CLOUD_TOKEN         Service token (from the SSM URI's password field)
  DBT_CLOUD_ACCOUNT_ID    From the SSM URI's login field
  DBT_CLOUD_HOST          Default sh023.us1.dbt.com
  DBT_CLOUD_PROJECT_ID    From dbt Cloud UI — project settings URL
  DBT_CLOUD_ENVIRONMENT_ID From dbt Cloud UI — Deploy → Environments URL

Output of provision-jobs is CSV to stdout (dag_name,job_id). Redirect to
a file, then pass to scripts/dbt_cloud_write_job_ids.py to patch the
DAG file constants.
EOF
        ;;
esac
