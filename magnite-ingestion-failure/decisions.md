# Decisions

## D-1 — Failing ingestion identified (2026-09-25)
The consistently-failing process is the **`magnite_curate`** DAG (API pull → PA_HOURLY /
PA_FUNNEL_HOURLY), NOT the CTV/DV+ vendor-drop ingestion. Confirmed by the Slack thread naming
`MAGNITE_PA_HOURLY` / `MAGNITE_PA_FUNNEL_HOURLY`.

## D-2 — Root cause = timing race + retries:0 (2026-09-25)
Transient "report/data not ready at 08:00" failures, hard-failed by `retries: 0` and no
not-ready handling. Recurring since June; manual re-run always fixes it. This is the class of
problem to make resilient (not a one-off bug).

## D-3 — SUPERSEDED by D-4. (was: retries + backoff)

## D-4 — Resilience approach = SELF-HEALING lookback, NOT retries (2026-09-28)
User decision: make the daily run self-healing instead of adding Airflow retries.
(`retries` stays 0 — we simply don't add them; we add gap-fill instead.)

**Design:**
- Each scheduled run processes a **lookback window** `[ds - N + 1 .. ds]` (default N=7, var-configurable),
  not just `ds`.
- For each (date, call ∈ {funnel, detail}), check whether the target S3 object
  `magnite/curate_{prefix}/{date}.parquet` already exists (`S3Hook.check_for_key`).
  - Missing → fetch + write.  Present → skip (idempotent, `replace=True`).
- So a day that failed heals on the **next** scheduled run automatically — no human backfill.
- **Manual backfill mode** (explicit `backfill_start`/`backfill_end`) unchanged: force re-pull the range.

**Failure semantics (replaces the hard-fail-on-any-error behavior):**
- A single not-ready date does NOT fail the run — it's skipped and retried by the next run.
- Raise (→ page) only when a gap is *persistent*: a date still missing after it has been in the
  window ≥ `alert_after_days` (e.g. 3). Prevents silent long-term data loss while tolerating the
  normal late-report race. (Threshold TBD with user.)

**Guardrails:**
- Cap dates fetched per run (e.g. today + up to K oldest-missing) so a long-outage catch-up
  doesn't blow `execution_timeout` (currently 55 min). Steady state = 1 date, fast.
- Keep zero-row `-N/A-` cleanup; revisit the 0-row hard-fail so a legit empty day doesn't
  re-attempt forever.

**Tradeoff accepted:** a late-but-same-day report now heals up to ~24h later (next run) instead
of same-day (which retries would have given). Simpler, no paging on transient lateness, no human backfill.

Still ship: fetch hardening (treat file-not-ready/409/500 as skip-not-crash) + a runbook.
