#!/usr/bin/env bash
#
# Wrapper for test_ssm_uri_via_airflow.py.
#
# Sources ~/repos/fes-airflow/.env (so `export DBT_CLOUD_AE_URI=...` is picked
# up naturally — no parsing), copies that value into AIRFLOW_CONN_DBT_CLOUD_AE,
# and runs the Python test inside the fes-airflow tox py311 env.
#
# Belt-and-suspenders: pipes stdout+stderr through a sed filter that redacts
# anything matching `dbtc_[A-Za-z0-9]+` before it reaches the terminal /
# calling process. This is a defense-in-depth against future Airflow log
# leaks that the Python side didn't anticipate.

set -euo pipefail

FES_AIRFLOW="${HOME}/repos/fes-airflow"
BROCK_BOT="${HOME}/repos/fes-data-brock-bot"

if [[ ! -f "$FES_AIRFLOW/.env" ]]; then
    echo "ERROR: $FES_AIRFLOW/.env not found" >&2
    exit 1
fi

if [[ ! -x "$FES_AIRFLOW/.tox/py311/bin/python" ]]; then
    echo "ERROR: fes-airflow tox py311 env not built. Run 'tox -e py311 -- --collect-only' in $FES_AIRFLOW first." >&2
    exit 1
fi

# Source .env, capturing exports
set -a
# shellcheck disable=SC1091
source "$FES_AIRFLOW/.env"
set +a

if [[ -z "${DBT_CLOUD_AE_URI:-}" ]]; then
    echo "ERROR: DBT_CLOUD_AE_URI not defined after sourcing .env" >&2
    exit 1
fi

# Copy into the Airflow-standard connection env var
export AIRFLOW_CONN_DBT_CLOUD_AE="$DBT_CLOUD_AE_URI"

# Run the Python test, filtering any stray token substrings out of output.
# Matches dbt Cloud service token prefix `dbtc_` followed by base64-ish chars.
cd "$FES_AIRFLOW"
"$FES_AIRFLOW/.tox/py311/bin/python" \
    "$BROCK_BOT/projects/dbt_cloud_migration/scripts/test_ssm_uri_via_airflow.py" 2>&1 |
    sed -E 's/dbtc_[A-Za-z0-9]{20,}/dbtc_REDACTED_TOKEN/g'

exit "${PIPESTATUS[0]}"
