# Tiger Export DAGs — Runbook Notes (draft)

Notes pulled out of the DAG code so the code stays terse. Fold into a proper
`fes-airflow` runbook when convenient. Covers `meta_capi_export` / `firebase_mp_export`.

## Send-once & dedup
- `sent_at` is the ledger. Each run selects `ready_to_send AND sent_at IS NULL`, sends,
  then stamps `sent_at` + `batch_id`. A sent row is never re-selected.
- Meta: each event carries a stable `event_id = {fan_id}:{event_name}`, so a retry
  dedups on Meta's side instead of double-counting.
- GA4/Firebase has no dedup key — rely on `sent_at` and `retries=1` (see below).

## Failure handling (poison-pill)
- A failed Meta chunk / Firebase row is **skipped** (not marked sent) and the loop
  continues; the task still **fails at the end** so it shows red and the skipped rows
  retry next run.
- Why skip instead of raise-in-place: Meta rows are ordered oldest-first, so with
  `retries=0` a single bad row would re-fetch first every run and block everything
  behind it until it ages out of the 7-day window (silent data loss).

## Staleness windows
- Meta rejects events older than 7 days. The Meta SELECT gates on `event_time_unix`
  (the exact value we send) so a row can't pass the query yet be rejected by Meta.
- GA4 silently drops events for `app_instance_id`s with no SDK activity in 72h — it
  still returns 204, so there's no error signal. Firebase SELECT orders newest-first
  and caps at 3 days. (This is why bumped/old dev rows can 204 but not land in GA4.)

## dev vs prod
- Dev and prod share the same Meta dataset / GA4 stream. Dev runs prefix the event
  name with `dev_` (`dev_new_fbg`, ...) so stakeholders can ignore/delete dev traffic.
- The prefix is applied to the **outbound payload only** — never to the `mark-sent`
  key, which uses the table's raw `event_name`.
- `export_db` switches `FDE_DEV` (dev) / `FDE` (prod); dev writes `sent_at` only in
  `FDE_DEV`, so a dev run never touches prod rows.

## Retries / cadence
- Firebase: `retries=1` (overrides the team default of 0) — the 72h window allows only
  ~3 daily attempts, so it can't absorb a missed run. Retry is safe because mark-sent
  is incremental (committed rows aren't re-sent).
- Meta: `retries=0` (default) — safe because `event_id` dedups any resend.
- Prod cadence: both DAGs run **hourly** (`0 * * * *`) to match the hourly model refresh.
  The DEMI tickets (183 Meta / 178 Firebase) don't specify a send cadence — hourly was
  chosen for freshness (Meta recommends sending within ~1h; Firebase has a 72h drop window).

## Throughput
- Meta: 1000 events/POST (hard cap), up to `MAX_ROWS_PER_RUN` (8000) rows/run in
  1000-chunks. No Meta rate limit, so many POSTs/run is fine.
- Firebase: one POST per row (MP only batches events sharing an `app_instance_id`),
  serial, `MAX_ROWS_PER_RUN` 5000, ~7 min at ~2k/day — well inside the 30-min timeout.

## dbt model config (AE-owned, dbt-fes-ae tiger_exports)
- Both models set `full_refresh: false` so a `dbt run --full-refresh` can't rebuild the
  table and wipe the `sent_at`/`batch_id` ledger.
- Both tagged `hourly` so the shared hourly dbt Cloud job refreshes them. Decoupled from
  the send DAGs by design (the export tables are a shared sink; producers own their logic).
- `merge_update_columns` excludes `sent_at`/`batch_id` and the incremental predicate is
  `sent_at IS NULL`, so a dbt run never clobbers the send ledger.

## Field notes
- `extinfo` is a 16-string array: indices 0–4 come from the table, 5–15 are static.
- `advertiser_tracking_enabled` derives from `consent_status` (only ~1.9% authorized
  today — consent still wiring up from Amplitude).
- `value` is a TEXT column; the payload builder tolerates non-numeric.
