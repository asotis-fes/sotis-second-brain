# Tiger — Resume State (as of 2026-08-20)

Read this first after a /compact. Single source of "where we are." Details live in the
other files here (`gap-analysis.md`, `field-crosswalk.md`, `source-table-findings.md`,
`open-items.md`, `runbook-notes.md`, `scripts/`).

## What this is
Server-to-server (S2S) conversion-event export: FES Snowflake staging tables → Meta CAPI
and Firebase/GA4 Measurement Protocol, no CDP. Two Airflow send DAGs read AE-owned dbt
export tables and POST ready rows.

## Tickets (note: moved from ENTDATA project → DEMI "GoD" project)
- Epic: ENTDATA-2246 "Tiger project"
- **DEMI-183** (was ENTDATA-2262) — Meta CAPI send job (DE)
- **DEMI-178** (was ENTDATA-2259) — Firebase MP send job (DE)
- ENTDATA-2264 / 2265 — AE export tables (meta / firebase), status Done
- Tickets do **not** specify a send cadence (only "hourly" for the AE table refresh).

## Repos / branches / PRs
| Repo | Branch | PR | Status |
|------|--------|----|--------|
| fes-airflow | `tiger/capi-firebase-export` | **#2336** | OPEN, mergeable, **needs review approval**; CI green; HEAD=origin=`53d3f045` (all pushed) |
| dbt-fes-ae | `tiger/firebase-hourly-tag` | **#187** | **MERGED** (firebase `hourly` tag + meta `full_refresh: false`) |
| fanapp-terraform | `tiger/mwaa-tiger-secrets` | #3141 | MERGED (SSM connection placeholders, dev+prod) |
| fanapp-terraform | `fix/dev-compute-partnerships-qc-import` | #3148 | MERGED (unrelated dev-compute plan fix) |
| data-infrastructure-deploy | — | — | reverted (was the WRONG repo; secrets live in fanapp-terraform) |

## ✅ Done
- Both DAGs built + dev-validated: Meta sent 25, Firebase sent 25 / 22 landed (3 dropped =
  stale `app_instance_id`, a dev artifact of bumping old rows — expected, not a bug).
- Refactored to pass flake8 `max-complexity=10` (helpers: `_group_by_event`,
  `_process_meta_chunk`, `_creds_complete`, `_deliver_firebase_row`) — no `# noqa`.
- Comments/DOC_MD trimmed; rationale moved to `runbook-notes.md`.
- Hardening: autocommit, per-chunk/row incremental mark-sent, poison-pill skip + fail-at-end,
  Meta `event_id` retry-dedup, Meta gate on `event_time_unix`, Firebase `retries=1`.
- **Both DAGs now hourly in prod** (`0 * * * *`); dev unscheduled (trigger on demand).
- dbt PR #187 merged (firebase hourly tag + meta full_refresh:false).
- SSM **dev** connection values set (Meta + Firebase) — send worked in dev.

## 🔲 Remaining before prod (3 things)
1. **fes-airflow PR #2336**: get a review approval → merge to main → `deploy_prod` ships the
   DAGs to prod MWAA (they then run hourly).
2. **Confirm PROD SSM connection values are set** for `http_meta_capi_api` and
   `http_firebase_mp_api` (I could NOT verify — AWS SSO expired, only ReadOnly profiles).
   If still `"change me"`, prod DAGs fail on the connection. Set via the Datadog
   **SSM Parameter Self Service** app (see below).
3. **dbt #187 is merged** → wait for one hourly dbt Cloud run so prod `FDE.fde_info.
   firebase_mp_export` has in-window (≤72h) rows; until then prod Firebase sends nothing.
   (Prod Meta is already fresh.)

## Key design decisions
- **Decoupled** (NOT coupled): export tables are a "dumb" sink; producers own their logic +
  cadence; send DAGs just drain `ready_to_send AND sent_at IS NULL`. That's why the fix for
  stale Firebase was "add the hourly tag," not "trigger dbt from the DAG."
- `sent_at` is the send-once ledger. dbt models are incremental-merge with
  `merge_update_columns` excluding `sent_at`/`batch_id` and `incremental_predicates:
  sent_at IS NULL`, plus `full_refresh: false` — so dbt never clobbers the ledger.
- Dev + prod share one Meta dataset / GA4 stream; **dev prefixes event names with `dev_`**
  (outbound payload only, never the mark-sent key) so stakeholders ignore/delete dev traffic.

## Snowflake / env facts
- snow connection: `FAN_DATA_EXCHANGE_PROD` (role FES_DATA_DEVELOPER). DBs: `FDE` (prod) /
  `FDE_DEV` (dev), schema `FDE_INFO`. Tables: `meta_capi_export`, `firebase_mp_export`.
- Warehouse: `FDE_DEVELOPER_WH` (use `FDE_DEVELOPER_3XL_WH` for amplitude.events_537355).
- DAG `export_db` = dev `FDE_DEV` / prod `FDE`; `snowflake_service_user` conn (already exists).
- Windows: Meta rejects >7d; GA4 drops `app_instance_id`s idle >72h (still returns 204).
- Volume: ~2–4k ready/day/platform, peak ~6.3k raw.

## GOTCHAS (cost me time — remember these)
- **snow CLI `--format json` HANGS** on this build; use `--format csv --query "..."`.
- **snow OAuth expires** → any snow call hangs in this non-interactive shell. Ask the user
  to run `! snow connection test -c FAN_DATA_EXCHANGE_PROD` to re-auth, THEN I can query.
- **git commit signing = 1Password** → I cannot commit/push (no TTY). Stage + hand the user
  a `! ...` command with `git commit -F <scratchpad msg>`.
- **AWS SSO expired; only `*.AWSReadOnlyAccess` profiles** → can't write S3/SSM. Dev MWAA
  bucket account = `010526250084`. Dev deploy skill: `fes-airflow-dev-deploy`.
- **Dev Airflow UI**: AWS console (account fes-data-compute-dev / 010526250084) → MWAA env
  `fes-data` → "Open Airflow UI". NOT `airflow-dev.dsea...` (that's DSEA k8s Airflow).
- SSM value format = Airflow connection JSON, `extra` as a nested object (not escaped string);
  app can't take multiline. Meta: `{conn_type:http, password:<token>, extra:{dataset_id,
  api_version}}`. Firebase: `{conn_type:http, extra:{api_secret_ios/android, app_id_ios/android}}`.
  app_id_ios=`1:510880785382:ios:03514906a7ba296ea42c27`, android=`1:510880785382:android:9ac6d6e46c558799a42c27`.

## Re-seed a dev test (rows go stale/sent, so dev often shows "No events ready")
```sql
USE WAREHOUSE FDE_DEVELOPER_WH;
UPDATE FDE_DEV.fde_info.meta_capi_export
SET event_time = CURRENT_TIMESTAMP(),
    event_time_unix = DATE_PART(EPOCH_SECOND, CURRENT_TIMESTAMP())::INTEGER,
    sent_at = NULL, batch_id = NULL
WHERE (fanapp_tenant_fan_id, event_name) IN (
  SELECT fanapp_tenant_fan_id, event_name FROM FDE_DEV.fde_info.meta_capi_export
  WHERE ready_to_send = TRUE AND event_name = 'new_fbg' LIMIT 25);
-- firebase: same but drop event_time_unix. (SQL writes are deny-listed for me → user runs.)
```

## Scratchpad commit/PR text (may persist same-session)
`/private/tmp/claude-502/-Users-alex-sotis-repos-fes-data-brock-bot/c598cd1b-313b-4842-aaed-367b6b21caa9/scratchpad/`
→ `tiger_dag_*`, `tiger_ae_*`, `tiger_fanapp_tf_*`, `tiger_tf_*` (commit msgs + PR bodies).
