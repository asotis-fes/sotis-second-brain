#!/usr/bin/env bash
#
# Interactive helper for populating prod SSM /airflow/connections/dbt_cloud_ae.
#
# Flow:
#   1. Prompts for the dbt Cloud service token (hidden input, `read -s`).
#   2. Validates the token by hitting GET /api/v2/accounts/{id}/ — 200 = valid.
#   3. Sanity-checks by GETting the prod dbt_loyalty_6hours job (must 200).
#   4. Builds the URI and copies it to the macOS clipboard (pbcopy).
#   5. You paste it into the Datadog SSM Self-Service app.
#
# Note on scoping: Job Admin (the role dbt-cloud UI recommends for MWAA
# service tokens) is ACCOUNT-WIDE — dbt Cloud does not offer an env selector
# for that role. Both the dev and prod tokens can technically see both envs.
# Isolation is achieved by (a) different AWS accounts hosting the two SSM
# params and (b) DAG-side env branching via `config.get_value_for_env`,
# NOT by token scope. A token-level scoping check is intentionally not
# performed here — it would always fail (or always pass, depending on how
# you framed it).
#
# The token never touches disk. It lives in a shell variable for the duration
# of this script's process and is unset before exit. No stdout of the token
# either — only the length is echoed, so you can spot-check paste-ability.
#
# Usage:
#   bash projects/dbt_cloud_migration/scripts/populate-ssm-token.sh
#
# Prerequisites:
#   - curl, jq, pbcopy (macOS default)
#   - You generated the token in dbt Cloud UI first (see ssm-prod-populate.md)

set -euo pipefail

ACCOUNT_ID=70437463654557
HOST=sh023.us1.dbt.com
PROD_JOB_ID=70437463791502  # dbt_loyalty_6hours prod

for cmd in curl jq pbcopy; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found" >&2; exit 1; }
done

echo "Paste the dbt Cloud prod service token (input is hidden). Press Enter."
read -rs TOKEN
echo

if [[ -z "${TOKEN:-}" ]]; then
    echo "ERROR: empty token" >&2
    exit 1
fi
echo "Received token, length: ${#TOKEN} chars"

trap 'unset TOKEN' EXIT

# --- 1. Basic auth check ---
echo
echo "→ Validating token against dbt Cloud API..."
http_code=$(curl -sS -o /tmp/dbt_resp.$$ -w "%{http_code}" \
    -H "Authorization: Token $TOKEN" \
    "https://$HOST/api/v2/accounts/$ACCOUNT_ID/")

if [[ "$http_code" != "200" ]]; then
    echo "✗ Token validation failed (HTTP $http_code)"
    jq . /tmp/dbt_resp.$$ 2>/dev/null || cat /tmp/dbt_resp.$$
    rm -f /tmp/dbt_resp.$$
    exit 1
fi
account_name=$(jq -r '.data.name // "unknown"' /tmp/dbt_resp.$$)
rm -f /tmp/dbt_resp.$$
echo "✓ Token valid. Account: '$account_name' (id=$ACCOUNT_ID)"

# --- 2. Prod-scope check: should see the prod job ---
echo
echo "→ Checking token can access PROD job $PROD_JOB_ID (dbt_loyalty_6hours)..."
prod_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Token $TOKEN" \
    "https://$HOST/api/v2/accounts/$ACCOUNT_ID/jobs/$PROD_JOB_ID/")

if [[ "$prod_code" == "200" ]]; then
    echo "✓ Token can read prod job (HTTP 200)"
else
    echo "✗ Token cannot read prod job (HTTP $prod_code) — did you scope it to Production env 70437463672974?"
    exit 1
fi

# --- 3. Build URI and copy to clipboard ---
# (No token-scope isolation check — Job Admin is account-wide by design.
# Env isolation lives in the DAG code via config.get_value_for_env, not in
# the token itself.)
URI="dbt-cloud://$ACCOUNT_ID:$TOKEN@$HOST"
printf '%s' "$URI" | pbcopy

echo
echo "══════════════════════════════════════════════════════════════"
echo "✓ URI copied to clipboard (${#URI} chars total, token ${#TOKEN} chars)"
echo
echo "  Next: open Datadog SSM Self-Service:"
echo "    https://app.datadoghq.com/app-builder/apps/0f0cd1e3-34fa-44cc-bf2e-e5ab60f8b6a1"
echo
echo "  Target parameter: /airflow/connections/dbt_cloud_ae"
echo "  Account:          fes-data-compute-prod"
echo "  Value:            paste (clipboard already loaded)"
echo
echo "  Then run:"
echo "    bash projects/dbt_cloud_migration/scripts/verify-ssm-populated.sh"
echo "══════════════════════════════════════════════════════════════"
