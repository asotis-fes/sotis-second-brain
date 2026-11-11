#!/usr/bin/env bash
#
# Verifies that prod SSM /airflow/connections/dbt_cloud_ae has been populated,
# WITHOUT reading the value itself. Only checks metadata (existence + last-
# modified timestamp + last-modified user).
#
# Usage:
#   bash projects/dbt_cloud_migration/scripts/verify-ssm-populated.sh [aws-profile]
#
# Default profile: fes-data-compute-prod.AdministratorAccess

set -euo pipefail

PROFILE="${1:-fes-data-compute-prod.AdministratorAccess}"
PARAM=/airflow/connections/dbt_cloud_ae
REGION=us-east-1

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found"       >&2; exit 1; }

echo "→ Checking SSM parameter $PARAM"
echo "    profile: $PROFILE"
echo "    region:  $REGION"
echo

meta=$(aws ssm describe-parameters \
    --parameter-filters "Key=Name,Values=$PARAM" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --output json 2>&1) || {
        echo "✗ AWS call failed. If auth expired:"
        echo "    aws-sso-util login"
        echo
        echo "  Raw error:"
        echo "$meta"
        exit 1
    }

count=$(echo "$meta" | jq '.Parameters | length')

if [[ "$count" == "0" ]]; then
    echo "✗ Parameter does NOT exist in this account."
    echo "  → Verify fanapp-terraform PR #2873 was applied to prod (merged 2026-07-11)."
    exit 1
fi

last_modified=$(echo "$meta" | jq -r '.Parameters[0].LastModifiedDate')
last_user=$(echo "$meta" | jq -r '.Parameters[0].LastModifiedUser // "unknown"')
version=$(echo "$meta" | jq -r '.Parameters[0].Version')
tier=$(echo "$meta" | jq -r '.Parameters[0].Tier')
type=$(echo "$meta" | jq -r '.Parameters[0].Type')

echo "✓ Parameter exists"
echo "    Version:          $version"
echo "    Type:             $type"
echo "    Tier:             $tier"
echo "    Last modified:    $last_modified"
echo "    Last modified by: $last_user"
echo
echo "  Current time (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "  If 'Last modified' is within the last few minutes and Version > 1,"
echo "  your populate landed. Version 1 with a placeholder-shaped timestamp"
echo "  means only the TF placeholder is there — populate hasn't run yet."
echo
echo "  Final validation happens post-cutover when the first"
echo "  dbt_loyalty_6hours prod run POSTs against dbt Cloud. If token is"
echo "  wrong, run_dbt.trigger returns 401; if right, it 200s."
