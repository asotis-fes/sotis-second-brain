# Findings

## 1. Error signature — WHICH ingestion & what fails

**Two Magnite ingestions exist:**
- **A. `magnite_curate` DAG** (fes-airflow, API pull) → `MAGNITE_PA_HOURLY` + `MAGNITE_PA_FUNNEL_HOURLY`. ← **THE CONSISTENT FAILURE.**
- **B. CTV streaming + DV+ exposure** — vendor drops files into `FES_MAGNITE_PROD_STAGE`
  (`streaming_logs/` JSON, `transparency/exposure/` parquet); external tables auto-refresh.
  No Airflow DAG. Not the failing one.

**Symptom (from Slack thread `C0BEX8UD61F` p1790011359 + alert history):**
Recurring transient failure of `magnite_curate` — data missing for scattered days
(9/12, 9/15, 9/17, again 9/25), each fixed by a manual re-run/backfill hours later.
Same pattern seen since **June** (6/24, 6/27, 7/1). The reported error text varies:
- Zoe (9/25): report said **"file not ready"**.
- Megan (6/27): `requests.exceptions.HTTPError: 500 Server Error: ... api.rubiconproject.com/analytics/v2/default?account=mp-vendor%2F202` (on report-create POST).
- Megan (7/1): "Failed initially with a 500, succeeded on re-run… job timing issue, api/data not available at 8am."
- Sean (6/24): "api returns error if data doesn't go that far back."

Alert routing: FireHydrant P3 → **#fes-data-alerts** (C07SGLT9VE1) / #demigod-alerts (C0BEN7WU23W).

## 2. Current code path

**Repo/file:** `fanatics-gaming/fes-airflow` → `dags/magnite/magnite_dag.py`
**DAG id:** `magnite_curate` — prod schedule `0 8 * * *` daily, `catchup=False`, P3 callbacks.
Single `PythonOperator` (`fetch_to_s3`) → `dbt_magnite` (dbt Cloud job).

**Flow:** POST async report to Magnite Curate API (`/analytics/v2/default`) → poll status
(exp backoff, 30-min timeout) → paginate (50k/page, 500k cap) → clean `-N/A-`→None →
`pa.Table.from_pylist(rows)` → write snappy Parquet → `s3.load_file(..., replace=True)` →
external tables auto-refresh via SQS → dbt dedup.

**Two API calls per date** (funnel + detail) partitioning 20 metrics; each writes
`magnite/curate_{funnel,detail}/{date}.parquet`.

**Fragility candidates visible in code (unconfirmed until we see the error):**
1. `pa.Table.from_pylist(clean_rows)` — PyArrow **infers schema from the row data**. If a
   day's values differ in type (e.g. a mostly-null column, int vs str), Arrow raises
   `ArrowInvalid/ArrowTypeError`. No explicit schema → schema can drift day to day.
2. **0-rows guard raises** `ValueError(... "verify auth")` — but a legit empty day (e.g.
   funnel call, no traffic) would hard-fail the whole DAG.
3. Whole result set (up to 500k rows × 2 calls) held **in memory** before write → possible
   worker OOM on big days.
4. **500k ROW_LIMIT** silently truncates if a day exceeds it (pagination stops at cap; no
   error) — data-loss risk, not a failure.
5. No retry/`raise_for_status` handling for transient 5xx/429 from the API; polling 409 hard-fails.
6. External-table schema fixed by DDL; if Parquet column set changes, dbt cast can break.

## 3. Runbook / vault status

- **No Magnite runbook** exists — grep of all 358 files in `docs/runbooks/**` = 0 matches.
  (This pipeline is undocumented operationally → resilience fix should ship with a runbook.)
- **Vault**: Magnite only appears as an *outbound share consumer*, not an ingestion system:
  - `sources/source-snowflake-shares-inventory.md` — Magnite = 1 of 14 FDE outbound share consumers.
  - `systems/snowflake-data-sharing.md` — Magnite share hit by the Mar-2026
    `CREATE OR REPLACE VIEW` drop-grants outage. Unrelated to this ingestion DAG.

## 4. Root cause

**Timing race + zero resilience.** `magnite_curate` runs at **08:00 ET daily** and pulls an
*async offline report* from Magnite. On some days the report/underlying data **isn't ready at
run time** — Magnite returns a 500 on report-create, an `error`/`canceled` report status, a 409,
or a "file not ready" on the data endpoint. The DAG has **`retries: 0`** (from
`get_default_args()`, not overridden) and its in-task logic hard-fails on these states, so a
single not-ready moment fails the whole run and pages. Re-running later the same day succeeds
because the report has since finalized — which is exactly the observed "backfill fixed it" pattern.

Secondary fragility (all in `magnite_dag.py`, unchanged from earlier analysis):
- `retries: 0` → no automatic recovery from a transient/timing error.
- Report-create POST + data "file not ready" are **not** covered by the 30-min status-poll loop;
  no 5xx/429 backoff on the session.
- Zero-row guard hard-fails a legitimately empty day.
- Whole result set held in memory; 500k row cap silently truncates.

**Not a data-share/grants issue** (that's a different Magnite touchpoint). Ingestion B is healthy.
