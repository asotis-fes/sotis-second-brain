#!/usr/bin/env python3
"""Verify AIRFLOW_CONN_DBT_CLOUD_AE (already exported by the wrapper) is a
valid URI that Airflow's DbtCloudHook can use.

This script assumes the wrapper has already:
  1. Sourced ~/repos/fes-airflow/.env (so DBT_CLOUD_AE_URI is exported)
  2. Copied that value into AIRFLOW_CONN_DBT_CLOUD_AE
  3. Run this script via .tox/py311/bin/python

Security posture:
  - No .env parsing here (wrapper handles that)
  - All logging disabled at CRITICAL+1 (kills Airflow's http.py error logger
    that leaked the raw Authorization header on the prior run)
  - Exception messages are NEVER printed. Only exception type + a generic
    marker. If you need details, run with SAFETY_OFF=1 in env (not recommended).
"""

import logging
import os
import sys

# --- Aggressive log kill BEFORE importing anything Airflow ---------------
# setLevel(ERROR) admits ERROR-level records through — the previous mistake.
# disable() sets a floor above the level given: nothing at CRITICAL or below
# passes. That includes the http.py ERROR log that leaked the token.
logging.disable(logging.CRITICAL)
for name in ("airflow", "airflow.providers.http.hooks.http",
             "airflow.hooks.base", "urllib3", "requests"):
    logging.getLogger(name).setLevel(logging.CRITICAL + 1)
    logging.getLogger(name).disabled = True

ACCOUNT_ID = 70437463654557
HOST = "sh023.us1.dbt.com"
PROD_LOYALTY_6H = 70437463791502
PROD_SOURCES = 70437463791521
SAFETY_OFF = os.environ.get("SAFETY_OFF") == "1"


def report_fail(where: str, exc: BaseException) -> None:
    if SAFETY_OFF:
        print(f"✗ {where}: {type(exc).__name__}: {exc}")
    else:
        # Never emit the exception message — could contain the URI/token
        # (Airflow's HttpHook logs response body on 4xx/5xx).
        print(f"✗ {where}: {type(exc).__name__} (message redacted; set SAFETY_OFF=1 to see)")


def check_uri_shape(uri: str) -> None:
    if not uri.startswith(f"dbt-cloud://{ACCOUNT_ID}:"):
        raise SystemExit(f"✗ URI does not start with 'dbt-cloud://{ACCOUNT_ID}:'")
    if not uri.endswith(f"@{HOST}"):
        raise SystemExit(f"✗ URI does not end with '@{HOST}'")
    token_len = len(uri) - len(f"dbt-cloud://{ACCOUNT_ID}:@{HOST}")
    if token_len < 20:
        raise SystemExit(f"✗ Token portion too short ({token_len} chars)")
    print(f"✓ URI shape OK ({len(uri)} chars total, token portion {token_len} chars)")


def main() -> int:
    uri = os.environ.get("AIRFLOW_CONN_DBT_CLOUD_AE", "")
    if not uri:
        print("✗ AIRFLOW_CONN_DBT_CLOUD_AE not set. Run via the bash wrapper.")
        return 1

    check_uri_shape(uri)

    try:
        from airflow.providers.dbt.cloud.hooks.dbt import DbtCloudHook
    except ImportError as e:
        print(f"✗ Cannot import DbtCloudHook: {e}")
        return 1

    hook = DbtCloudHook(dbt_cloud_conn_id="dbt_cloud_ae")

    # --- 1. Auth: get the account by ID (NOT list_accounts — that hits the
    #     tenant root, which is an S3-fronted static page)
    print(f"\n→ hook.get_account(account_id={ACCOUNT_ID})")
    try:
        r = hook.get_account(account_id=ACCOUNT_ID)
        data = r.json().get("data", {})
        if data.get("id") != ACCOUNT_ID:
            print(f"✗ Unexpected account payload: id={data.get('id')}")
            return 1
        print(f"✓ Auth OK. Account: '{data.get('name')}' (id={data.get('id')})")
    except Exception as e:
        report_fail("get_account", e)
        return 1

    # --- 2. Read prod loyalty_6hours job — the one MWAA will actually trigger
    print(f"\n→ hook.get_job(job_id={PROD_LOYALTY_6H})  # dbt_loyalty_6hours prod")
    try:
        r = hook.get_job(job_id=PROD_LOYALTY_6H, account_id=ACCOUNT_ID)
        job = r.json().get("data", {})
        if job.get("id") != PROD_LOYALTY_6H:
            print(f"✗ Unexpected job payload id={job.get('id')}")
            return 1
        print(f"✓ Job accessible. Name: {job.get('name')} · Env id: {job.get('environment_id')}")
    except Exception as e:
        report_fail("get_job(loyalty_6hours prod)", e)
        return 1

    # --- 3. Read prod dbt_sources job (safe read-only alternate)
    print(f"\n→ hook.get_job(job_id={PROD_SOURCES})  # dbt_sources prod")
    try:
        r = hook.get_job(job_id=PROD_SOURCES, account_id=ACCOUNT_ID)
        job = r.json().get("data", {})
        if job.get("id") != PROD_SOURCES:
            print(f"✗ Unexpected job payload id={job.get('id')}")
            return 1
        print(f"✓ Job accessible. Name: {job.get('name')} · Env id: {job.get('environment_id')}")
    except Exception as e:
        report_fail("get_job(dbt_sources prod)", e)
        return 1

    print("\n" + "=" * 60)
    print("✓ URI is well-formed, parseable by Airflow's Connection loader,")
    print("  and the hook auths + reads prod jobs. When prod MWAA reads the")
    print("  same URI from prod SSM, the auth path behaves identically.")
    print()
    print("  Remaining unknowns (not testable from your laptop):")
    print("    - Prod MWAA execution role has ssm:GetParameter on the param")
    print("    - Prod MWAA has network egress to sh023.us1.dbt.com")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
