# Tiger — Open Items

Running list of follow-ups, in priority order.

## 1. DECISION: keep the export DAGs DECOUPLED from the dbt models (owner: DE + AE)
**Status:** decided 2026-08-20 — do NOT couple.

We considered triggering the dbt models from the send DAG, but chose to keep them
**decoupled**: the AE models refresh on their own schedule (the shared hourly dbt Cloud
job, tag-selected), and the send DAGs independently drain whatever is `ready_to_send`.

**Rationale:** we want a future state where the export process is "dumb" — any number of
dbt models can write into the export tables with their own producer-specific logic and
cadence, and the send DAG just ships whatever is ready. Coupling would hard-wire one
producer per DAG and fight that goal.

**Consequence (the concrete fix, see item #5):** because refresh stays tag-driven,
`firebase_mp_export` **must carry a refresh tag**. It currently has none, so it isn't in
the hourly job — that's why it's stale. Fix = add `tags: ['hourly', 'firebase_mp']` in
`dbt-fes-ae/models/growthloop/tiger_exports/tiger_exports.yaml` (done in this pass;
needs an AE PR). Confirm hourly is the intended Firebase cadence (mirrors Meta); if the
requirement is daily, use the daily selector instead.

Contract note: whichever way, the send job owns `sent_at`/`batch_id`; the dbt merge must
keep excluding them (`merge_update_columns` + `incremental_predicates: sent_at IS NULL`).

## 2. Meta send-job hardening: poison-pill + per-run limit + cadence (owner: DE) — before prod
**Status:** open · **Priority:** high (the poison-pill is a silent data-loss path)

From volume analysis (prod ~2–4k ready events/day/platform; sendable backlog meta 3,650 /
firebase 0) + adversarial review:
- **Poison-pill / head-of-line blocking (real bug):** Meta SELECT is `ORDER BY event_time_unix`
  (oldest-first). On `events_received == 0` the loop `raise`s; with `retries=0` the run dies, the
  same oldest poison row is re-fetched first next run, fails identically, and everything queued
  behind it ages out of the 7-day window and is lost — then the DAG goes green. **Fix the reject
  handling, not the chunk size:** on zero-accept, log + record the failed chunk + `continue`; fail
  the task at end if any chunk failed. Optional: binary-split a zero-accept chunk to quarantine the
  one bad event.
- **Per-run cap too low:** `LIMIT 1000` == `MAX_BATCH 1000` → the chunk loop never iterates; any
  day > 1000 ready leaves the oldest tail undrained → ages out. Raise SQL `LIMIT` to **8000**, keep
  `MAX_BATCH=1000`. Do NOT drop the chunk to 250 (fiddling; doesn't fix the poison-pill).
- **Cadence (decision):** Meta recommends sending within ~1h; daily (`0 9 * * *`) ships 12–24h late
  and degrades attribution. Recommend **hourly `0 * * * *` with `LIMIT 2000`** (per-run ~85–170;
  limit nearly irrelevant). Reverses the earlier "daily" choice — confirm before changing.
- Optional: `ORDER BY event_time_unix, fanapp_tenant_fan_id, event_name` for tie determinism.

## 3. Firebase send-job hardening (owner: DE) — before prod
**Status:** open · **Priority:** medium

- **No concurrency needed** — serial ~2k/day ≈ 6–7 min; 5k cap ≈ ~15 min even in a 72h fresh-backlog
  spike, inside the 30-min timeout. The aged-row backfill spike can't happen (the `event_time >=
  now-72h` gate permanently excludes old rows).
- **72h window can't afford a missed run** (~3 daily attempts before aging out). Give this task
  `retries=1` (short delay, overriding the team `retries=0`) or run twice-daily.
- **Timezone nit:** the age gate compares `event_time` (TIMESTAMP_NTZ, stored UTC) to
  `CURRENT_TIMESTAMP()` (session TZ). If session TZ ≠ UTC the 72h boundary is off by the offset
  (~4–5h). Confirm session TZ or use epoch/`CONVERT_TIMEZONE`. (Meta is unaffected — gates on integer epoch.)

## 4. Add `full_refresh_prevention` to the AE export models (owner: AE)
**Status:** open · before prod go-live

**Firebase is already protected** — `firebase_mp_export` config has `full_refresh: false`
on main. **Only `meta_capi_export` is missing it.** Add `full_refresh: false` (or the
`full_refresh_prevention` macro) to the `meta_capi_export` config in
`dbt-fes-ae/.../tiger_exports.yaml`. Without it, a `dbt run --full-refresh` rebuilds the
Meta table and **wipes `sent_at` → re-fires every event** (Meta double-counts beyond its
dedup window). One-line fix; fold into the Firebase-tag AE PR.

## 5. Firebase export staleness — FIX STAGED, needs AE PR
**Status:** fix applied to yaml locally; needs an AE PR + merge + one hourly run

`firebase_mp_export` had **no tags**, so it wasn't in the hourly dbt Cloud job → its
export table went stale (newest event 8/14 vs Meta = today). Fix (per the decouple
decision, item #1): added `tags: ['hourly', 'firebase_mp']` to
`dbt-fes-ae/.../tiger_exports.yaml`. Once merged and one hourly run completes, prod
Firebase will have in-window rows to send. Until then prod Firebase sends nothing.

## 6. (FYI, AE) Late-arriving readiness vs. staleness window
**Status:** accepted · low priority

Rows that become `ready_to_send` only after their `event_time` ages past the send window
(Meta 7d / Firebase 72h) are silently skipped — the platforms would reject them anyway.
Accepted as a low-severity miss for an ad-optimization signal. Revisit only if we want to
measure the miss rate. No code planned.
