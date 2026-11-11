# The Issue

## What broke

The fanflow bronze ingestion macros (`fanflow_unparsed_files`, `fanflow_ingest_topic`) —
and one Mention Me model, and one dbt-governance data-quality model — build their
incremental-run window from `var("data_interval_end")` (and, in one case,
`var("ds_nodash")`).

Under the previous Airflow-orchestrated setup, dbt was invoked with
`--vars '{data_interval_start: "...", data_interval_end: "..."}'` on every run, so those
variables always resolved to the current Airflow data-interval bounds.

Under dbt Cloud, nothing injects these vars. dbt falls back to whatever default is set in
`dbt_project.yml` under `vars:`. For the affected repos, those defaults are static
placeholder timestamps left over from local `dbt docs generate`:

```yaml
# dbt-fes-ae/dbt_project.yml and dbt-fes-analytics/dbt_project.yml
vars:
  data_interval_start: '2023-01-01T00:00:00.0000000+00:00'
  data_interval_end:   '2023-01-02T00:00:00.0000000+00:00'
  ds_nodash: '20250925'
```

## The failure mode

For fanflow: the window collapses to a 2-hour slice on **January 2, 2023**. Zero files
match; the anti-join on `_filename` (correctly) skips nothing new; the incremental table
is unchanged run after run.

For mention_me: the source-file filter compares filenames to
`mention_me/referrals/CRMFeedV2_20250925.csv`. Only files with that exact date pattern
match. New daily files (`CRMFeedV2_20260722.csv`, etc.) are silently ignored on
incremental runs.

For dbt-governance: its default is the raw string `CURRENT_TIMESTAMP`, which Snowflake
evaluates at query time — so it "works" but pinned to yesterday's date with no
backfill safety.

## Why it went silent

dbt reports the runs as **successful** — the model ran, the merge/insert executed, it
just inserted zero rows. There is no exception, no error, no warning.

The only signal was `dbt_utils.recency` tests failing on downstream tables (which then
skipped their own downstream models). Nobody noticed until the recency test tripped and
someone traced the freshness gap back.

## Blast radius

**Directly affected** (models running the broken window logic):
- 5 raw bronze S3-stage ingest models in dbt-fes-ae (`fes_enriched`, `fes_enriched_fanapp`,
  `fcore_fes_enriched`, `fcore_fes_enriched_fanapp`, `fes_fanflow_enriched`) — 0 rows
  landing.
- 1 mention_me referrals ingest model (`mention_me__referrals`) — filename filter
  permanently pinned to 2025-09-25.
- 1 dbt-governance DQ check (`bets_total_stake_validity_check`) — pinned to yesterday's
  date, no backfill safety.

**Frozen downstream** (natural consequence — their sources aren't advancing):
- ~47 per-event fanflow bronze models under
  `dbt-fes-ae/models/fanflow/bronze_events/*__bronze.sql` — each `ref()`s one of the 5 raw
  bronzes via `fanflow_bronze_with_backfill`. Since sources are frozen, these get no new
  data on incremental runs.
- Everything downstream of those (silver, gold, marts) is silently pinned to the last
  good ingestion.

**Not affected** (verified — see `findings.md`):
- All other FBG dbt Mesh projects (dbt-finance, dbt-customer, dbt-vip, dbt-trading,
  dbt-casino, dbt-hris, dbt-fmx, dbt-operations, dbt-product, dbt-fes-ads, dbt-regulatory,
  dbt_data_catalog, dbt-sandbox, dbt-internal-nonfinancial-audit).
- Airflow-orchestrated SQL under `fes-airflow/dags/**/sql/` (correctly uses Airflow context).
- `dbt-fes-ae/macros/gam_report.sql` (only docstring mentions `data_interval_start`).

## Immediate mitigation (in flight in a separate session)

A parallel session is running catch-up ingestion via manual Snowflake queries against the
`@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT` stage to gap-fill the frozen period. That
work is not tracked here — this workspace is for the **permanent fix**.
