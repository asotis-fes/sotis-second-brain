# Plan

## Approach

1. Identify the exact pipeline (DAG/job/repo) and where failures surface.
2. Pull the failing run + error text.
3. Read the ingestion code path; understand what breaks and why.
4. Grep `docs/runbooks/**` + vault for existing docs on this pipeline.
5. Only then: design a resilience fix (retries, idempotency, schema/API drift handling, alerting).

## What I need from Alex (pick whichever is fastest)

- **DAG id or repo path** for the Magnite ingestion (e.g. `fes-airflow/dags/.../magnite*`).
- **Error signature** — paste the traceback, or a link to a failed Airflow/dbt/Databricks run.
- **Cadence** — how often it fails (every run? nightly?).

## Notes

- Magnite = ad-tech SSP; likely an ad-spend / revenue ingestion (API or S3 file drop).
- Haven't yet confirmed which repo owns it. First grep the repos I can reach.
