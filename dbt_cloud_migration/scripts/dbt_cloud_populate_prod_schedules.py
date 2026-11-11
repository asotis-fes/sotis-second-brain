#!/usr/bin/env python3
"""Populate schedule.cron on prod jobs; triggers.schedule stays false.

Reads prod-job-ids.csv, applies the schedule map, PATCHes each job via
full-body-replace (dbt Cloud v2 pattern per D-19).
"""
import csv
import json
import os
import sys
import urllib.request
import urllib.error

token = os.environ["DBT_CLOUD_TOKEN"]
account_id = int(os.environ["DBT_CLOUD_ACCOUNT_ID"])
host = os.environ["DBT_CLOUD_HOST"]
base_url = f"https://{host}/api/v2/accounts/{account_id}"

# dag_name -> cron. Skip dbt_loyalty_6hours (Airflow triggers), dbt_enterprise_metrics
# (was ad-hoc), dbt_fangraph (paused until Fusion validation — but we still populate cron)
SCHEDULES = {
    "dbt_loyalty":                    "0 * * * *",
    "dbt_loyalty_metrics":            "0 14 * * *",
    "dbt_loyalty_monthly_snapshot":   "0 9 2 * *",
    "dbt_fanflow":                    "0 * * * *",
    "dbt_hourly":                     "0 * * * *",
    "dbt_daily":                      "0 12 * * *",
    "dbt_daily_9am":                  "15 13 * * *",
    "dbt_every_3hours":               "0 */3 * * *",
    "dbt_every_6hours":               "30 0,1,6,12,18 * * *",
    "dbt_weekly":                     "0 10 * * 1",
    "dbt_meta_ads":                   "0 8 * * *",
    "dbt_ltv":                        "0 12 * * *",
    "dbt_mde":                        "45 11 * * *",
    "dbt_fanapp_recs":                "0 12 * * *",
    "dbt_enterprise_metrics_daily":   "0 12 * * *",
    "dbt_fanatics_one":               "*/30 * * * *",
    "dbt_xtremepush":                 "0 12 * * *",
    "dbt_users":                      "30 13 * * *",
    "dbt_sources":                    "0 13 * * 1-5",
    "dbt_fangraph":                   "0 10 * * *",
}
# These get a job but no cron (fully manual / Airflow-triggered)
NO_CRON = {
    "dbt_loyalty_6hours",
    "dbt_enterprise_metrics",
    # Ingest-DAG-triggered jobs — Airflow POSTs runs; no cron in dbt Cloud.
    # Added 2026-07-19 per dbt-in-airflow-removal.md. They stay
    # triggers.schedule=false permanently; the default schedule.cron dbt Cloud
    # returns for them is inert and never fires.
    "dbt_fanapp_mdm",
    "dbt_google_ad_manager",
    "dbt_identity",
    "dbt_impact",
    "dbt_fesbonus",
    "dbt_fesloyalty",
    "dbt_magnite",
    "dbt_optin_preferences",
}


def call(method, path, body=None):
    req = urllib.request.Request(
        f"{base_url}{path}",
        data=json.dumps(body).encode() if body else None,
        method=method,
        headers={
            "Authorization": f"Token {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} {method} {path}: {e.read().decode()[:400]}", file=sys.stderr)
        raise


with open(sys.argv[1]) as f:
    reader = csv.DictReader(f)
    for row in reader:
        dag_name = row["dag_name"].strip()
        job_id = int(row["job_id"].strip())

        if dag_name in NO_CRON:
            print(f"SKIP {dag_name} job_id={job_id} (no cron in dbt Cloud)")
            continue

        cron = SCHEDULES.get(dag_name)
        if not cron:
            print(f"WARN {dag_name} — no schedule mapping, skipping")
            continue

        current = call("GET", f"/jobs/{job_id}/")["data"]
        # dbt Cloud API quirk: `schedule.cron` alone is ignored — the API DERIVES
        # the cron string from `schedule.date.type` + `schedule.time.type`. To set
        # an arbitrary cron, use `date.type = "custom_cron"` with `date.cron` set.
        # Discovered 2026-07-21 during initial populate run — see analytics_users
        # job (70437463793734) setup for the same pattern.
        current["schedule"] = {
            "date": {"type": "custom_cron", "cron": cron},
            "time": {"type": "every_hour", "interval": 1},
            "cron": cron,
        }
        # keep triggers.schedule false — cutover script flips it
        current["triggers"]["schedule"] = False

        call("POST", f"/jobs/{job_id}/", body=current)
        print(f"OK   {dag_name} job_id={job_id} cron='{cron}'")
