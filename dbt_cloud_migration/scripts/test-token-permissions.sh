#!/usr/bin/env bash
#
# Empirically validate whether a dbt Cloud service token has exactly the
# permissions MWAA needs, and nothing more.
#
# Runs through the API surface of `utils.dbt_cloud.create_dbt_cloud_task_group`
# in fes-airflow, mimicking what a real DAG run does. Then also probes a few
# write operations that MWAA does NOT need — expected to be denied for a
# properly-scoped Job Runner token.
#
# Usage:
#   bash projects/dbt_cloud_migration/scripts/test-token-permissions.sh <env>
#     <env> = dev | prod
#
# Prompts for the token (hidden input). Token never touches disk.
#
# A smoke run of a lightweight dev job is triggered as part of the test. In
# prod, the trigger step is skipped by default (would fire a real prod job);
# pass --trigger-prod to force it.

set -euo pipefail

ENV_ARG="${1:-}"
FORCE_PROD_TRIGGER=false

case "${2:-}" in
    --trigger-prod) FORCE_PROD_TRIGGER=true ;;
esac

if [[ "$ENV_ARG" != "dev" && "$ENV_ARG" != "prod" ]]; then
    echo "Usage: $0 <dev|prod> [--trigger-prod]" >&2
    exit 1
fi

ACCOUNT_ID=70437463654557
HOST=sh023.us1.dbt.com

# Job to exercise — use the loyalty_6hours dev job for dev (safe smoke; dbt Cloud
# will build a small tag). For prod, use dbt_sources (source freshness, read-only
# to Snowflake). Never triggering prod dbt_loyalty_6hours here — that would run
# real loyalty models against prod warehouses.
if [[ "$ENV_ARG" == "dev" ]]; then
    TARGET_JOB=70437463791264   # dbt_loyalty_6hours dev
    JOB_LABEL="dbt_loyalty_6hours dev"
else
    TARGET_JOB=70437463791521   # dbt_sources prod (source freshness, read-only)
    JOB_LABEL="dbt_sources prod (source freshness)"
fi

for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found" >&2; exit 1; }
done

echo "Environment: $ENV_ARG"
echo "Target job:  $TARGET_JOB ($JOB_LABEL)"
echo
echo "Paste the dbt Cloud service token (input hidden). Press Enter."
read -rs TOKEN
echo
[[ -n "${TOKEN:-}" ]] || { echo "ERROR: empty token" >&2; exit 1; }
trap 'unset TOKEN' EXIT

AUTH="Authorization: Token $TOKEN"
BASE="https://$HOST/api/v2/accounts/$ACCOUNT_ID"

# ---------------------------------------------------------------------------
# Helper: expect
#   $1 = expected HTTP status
#   $2 = description
#   $3+ = curl args
# ---------------------------------------------------------------------------
declare -a RESULTS
declare -i PASS=0 FAIL=0

expect() {
    local expected="$1" desc="$2"; shift 2
    local body="/tmp/dbt_test_$$.body"
    local code
    code=$(curl -sS -o "$body" -w "%{http_code}" "$@" -H "$AUTH")
    if [[ "$code" == "$expected" ]]; then
        RESULTS+=("✓ [$code] $desc")
        PASS+=1
    else
        RESULTS+=("✗ [got $code, expected $expected] $desc")
        FAIL+=1
        local snippet
        snippet=$(jq -c '.' "$body" 2>/dev/null | head -c 200 || head -c 200 "$body")
        RESULTS+=("    body: $snippet")
    fi
    rm -f "$body"
}

# ---------------------------------------------------------------------------
# CATEGORY 1 — Operations MWAA REQUIRES (must succeed)
# ---------------------------------------------------------------------------
echo "═══ Category 1: MWAA-required operations (must succeed) ═══"
echo

expect 200 "GET /accounts/{id}/ (auth check)" "$BASE/"

expect 200 "GET /accounts/{id}/jobs/{job_id}/ (read target job metadata)" \
    "$BASE/jobs/$TARGET_JOB/"

# Trigger a run of the target job
DO_TRIGGER=true
if [[ "$ENV_ARG" == "prod" && "$FORCE_PROD_TRIGGER" != "true" ]]; then
    DO_TRIGGER=false
    echo "  (skipping POST run trigger in prod — pass --trigger-prod to force)"
fi

RUN_ID=""
if $DO_TRIGGER; then
    # Trigger with a distinctive cause so the run is identifiable
    TRIGGER_BODY=$(mktemp)
    curl -sS -o "$TRIGGER_BODY" -w "trigger_http: %{http_code}\n" \
        -X POST "$BASE/jobs/$TARGET_JOB/run/" \
        -H "$AUTH" \
        -H "Content-Type: application/json" \
        -d '{"cause": "test-token-permissions.sh smoke — safe to ignore"}' > /tmp/dbt_test_trig_meta.$$
    trigger_code=$(grep '^trigger_http:' /tmp/dbt_test_trig_meta.$$ | awk '{print $2}')
    rm -f /tmp/dbt_test_trig_meta.$$
    if [[ "$trigger_code" == "200" ]] || [[ "$trigger_code" == "201" ]]; then
        RUN_ID=$(jq -r '.data.id // empty' "$TRIGGER_BODY")
        RESULTS+=("✓ [$trigger_code] POST /jobs/{id}/run/ — triggered run $RUN_ID")
        PASS+=1
    else
        RESULTS+=("✗ [got $trigger_code, expected 200/201] POST /jobs/{id}/run/")
        FAIL+=1
        snippet=$(jq -c '.' "$TRIGGER_BODY" 2>/dev/null | head -c 200)
        RESULTS+=("    body: $snippet")
    fi
    rm -f "$TRIGGER_BODY"
fi

# Read the run we just triggered (or an existing run — pick most recent for the job)
if [[ -z "$RUN_ID" ]]; then
    RECENT_BODY=$(mktemp)
    curl -sS -o "$RECENT_BODY" \
        -H "$AUTH" \
        "$BASE/runs/?job_definition_id=$TARGET_JOB&order_by=-id&limit=1"
    RUN_ID=$(jq -r '.data[0].id // empty' "$RECENT_BODY")
    rm -f "$RECENT_BODY"
fi

if [[ -n "$RUN_ID" ]]; then
    expect 200 "GET /runs/{run_id}/ (poll run status — used by DbtCloudJobRunSensor)" \
        "$BASE/runs/$RUN_ID/"
else
    RESULTS+=("⚠  Could not locate a run_id to poll — GET /runs/{run_id}/ test skipped")
fi

echo

# ---------------------------------------------------------------------------
# CATEGORY 2 — Operations MWAA does NOT need (Job Runner should be denied)
# ---------------------------------------------------------------------------
echo "═══ Category 2: Least-privilege probes (should FAIL for Job Runner) ═══"
echo
echo "  (For a Job Runner token, these should return 403. For a Job Admin"
echo "   token, these will return 200 — proving Job Admin has too much power.)"
echo

# Try to edit the target job (harmless PATCH — set num_threads to same value)
# Note: dbt Cloud requires all-fields on PUT for jobs. A PATCH with an empty body
# should still be attempted and rejected by RBAC before the schema check.
expect 403 "PUT /accounts/{id}/jobs/{job_id}/ (edit job — MWAA should NOT be able to)" \
    -X PUT "$BASE/jobs/$TARGET_JOB/" \
    -H "Content-Type: application/json" \
    -d '{}'

# Try to create a new job — should also 403
expect 403 "POST /accounts/{id}/jobs/ (create job — MWAA should NOT be able to)" \
    -X POST "$BASE/jobs/" \
    -H "Content-Type: application/json" \
    -d '{"account_id": '$ACCOUNT_ID', "project_id": 0, "environment_id": 0, "name": "x", "execute_steps": []}'

echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "═══ Results ═══"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo

if (( FAIL == 0 )); then
    echo "✓ All expectations met. Token is suitable for MWAA."
    exit 0
else
    echo "✗ At least one check did not match expectation."
    echo
    echo "  Interpretation:"
    echo "  - Failures in Category 1 = token is too restrictive (MWAA will 403 in prod)."
    echo "  - Category 2 endpoints returning 200 = token has more power than MWAA needs."
    echo "    (Not an outage risk, but larger leak blast radius.)"
    exit 1
fi
