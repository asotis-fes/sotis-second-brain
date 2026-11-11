#!/usr/bin/env bash
#
# Flip triggers.schedule=true on the prod dbt Cloud jobs at cutover moment.
# Reverse with --deactivate.
#
# Reads a CSV of `dag_name,job_id` rows (as produced by
# `scripts/dbt_cloud.sh provision-jobs`). Auto-sources .env at repo root.
#
# Full-body PATCH pattern per D-19 (fetch job → mutate → PATCH full body).
#
# Excluded from activation (schedule stays paused even at cutover):
#   dbt_loyalty_6hours    — Airflow triggers this, no cron in dbt Cloud
#   dbt_enterprise_metrics — was ad-hoc-only in old world
#   dbt_fanapp_mdm         \
#   dbt_google_ad_manager   \
#   dbt_identity             \  ingest-DAG-triggered jobs (added 2026-07-19 per
#   dbt_impact                \  dbt-in-airflow-removal.md); Airflow POSTs run
#   dbt_fesbonus              /  requests directly via DbtCloudRunJobOperator.
#   dbt_fesloyalty           /   No cron ever needed; stay triggers.schedule=false
#   dbt_magnite             /    permanently.
#   dbt_optin_preferences  /

set -euo pipefail

_REPO_ROOT="$HOME/repos/fes-airflow"
if [[ -f "${_REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${_REPO_ROOT}/.env"
    set +a
fi

: "${DBT_CLOUD_TOKEN:?required}"
: "${DBT_CLOUD_ACCOUNT_ID:?required}"
: "${DBT_CLOUD_HOST:=sh023.us1.dbt.com}"

BASE_URL="https://${DBT_CLOUD_HOST}/api/v2/accounts/${DBT_CLOUD_ACCOUNT_ID}"

TARGET_STATE=true
CSV_FILE=""

for arg in "$@"; do
    case "$arg" in
        --deactivate) TARGET_STATE=false ;;
        --help|-h)
            cat <<EOF
usage: $0 [--deactivate] <job-ids.csv>
  <job-ids.csv>   CSV with header: dag_name,job_id
  --deactivate    set triggers.schedule=false instead of true (rollback)
EOF
            exit 0
            ;;
        *) CSV_FILE="$arg" ;;
    esac
done

if [[ -z "$CSV_FILE" ]]; then
    echo "error: missing <job-ids.csv> argument (see --help)" >&2
    exit 1
fi
if [[ ! -f "$CSV_FILE" ]]; then
    echo "error: CSV file not found: $CSV_FILE" >&2
    exit 1
fi

_EXCLUDED=(
    "dbt_loyalty_6hours"
    "dbt_enterprise_metrics"
    # dbt_fangraph — REMOVED from exclusion 2026-07-21. Fusion parity validation
    # passed 2026-07-14 (fangraph diff: 191M rows, only build-time timestamp drift,
    # no systematic Fusion divergence). Must activate at cutover — MWAA no longer
    # runs dbt-core, so this is the only path that keeps fangraph tables refreshing.
    # Ingest-DAG-triggered jobs — Airflow POSTs run requests. Never activate.
    "dbt_fanapp_mdm"
    "dbt_google_ad_manager"
    "dbt_identity"
    "dbt_impact"
    "dbt_fesbonus"
    "dbt_fesloyalty"
    "dbt_magnite"
    "dbt_optin_preferences"
)

_is_excluded() {
    local name=$1
    for e in "${_EXCLUDED[@]}"; do
        [[ "$e" == "$name" ]] && return 0
    done
    return 1
}

echo "Target: triggers.schedule=${TARGET_STATE}"
echo "CSV:    ${CSV_FILE}"
echo "Excluded (unchanged): ${_EXCLUDED[*]}"
echo
read -r -p "Proceed? Type 'yes' to continue: " reply
if [[ "$reply" != "yes" ]]; then
    echo "aborted."
    exit 1
fi

# Skip header row
tail -n +2 "$CSV_FILE" | while IFS=',' read -r dag_name job_id; do
    dag_name=$(echo "$dag_name" | tr -d '[:space:]')
    job_id=$(echo "$job_id" | tr -d '[:space:]')
    if _is_excluded "$dag_name"; then
        echo "SKIP ${dag_name} (excluded)"
        continue
    fi

    current=$(curl --silent --show-error --fail-with-body \
        --header "Authorization: Token ${DBT_CLOUD_TOKEN}" \
        "${BASE_URL}/jobs/${job_id}/")

    modified=$(echo "$current" | jq --argjson s "$TARGET_STATE" \
        '.data | .triggers.schedule = $s')

    curl --silent --show-error --fail-with-body \
        --header "Authorization: Token ${DBT_CLOUD_TOKEN}" \
        --header "Content-Type: application/json" \
        --header "Accept: application/json" \
        --data "$modified" \
        "${BASE_URL}/jobs/${job_id}/" > /dev/null

    echo "OK   ${dag_name} job_id=${job_id} triggers.schedule=${TARGET_STATE}"
done

echo
echo "Done."
