# Tiger — Local Dry-Run Validation Scripts

**Temporary, local-only.** These scripts exist to prove the pipeline works
end-to-end *without sending real data to Meta or Google*. They are not part of the
production Airflow deploy (that lives in `fes-airflow` on branch
`tiger/capi-firebase-export`).

## What they do

| Script | Purpose | Sends data? |
|--------|---------|-------------|
| `check_source_readiness.py` | Query `gl_new_to_x` (or the AE export tables if they exist) and report how many rows would be `ready_to_send` per platform, with per-field fill rates. Surfaces the gaps in `../gap-analysis.md` against live data. | ❌ No |
| `validate_meta_payload.py` | Build Meta CAPI payloads from real source rows and validate them locally (extinfo all-strings, required fields, hashing). Optionally hit Meta's `test_event_code` path — **off by default**. | ❌ No (unless `--send-test` with a test_event_code) |
| `validate_firebase_payload.py` | Build Firebase MP payloads and validate via Google's **`/debug/mp/collect`** endpoint (validation-only, never records events). | ❌ No (debug endpoint only) |

## Safety model

- **No secrets in these files.** They read credentials from env vars
  (`META_ACCESS_TOKEN`, `META_DATASET_ID`, `FIREBASE_API_SECRET_IOS`,
  `FIREBASE_API_SECRET_ANDROID`, `FIREBASE_APP_ID_IOS`, `FIREBASE_APP_ID_ANDROID`).
- Default mode is **build + validate only** — nothing is POSTed to a production
  events endpoint.
- The Firebase validator uses `/debug/mp/collect`, which returns
  `validationMessages` and never records an event.
- The Meta validator only sends if you explicitly pass `--send-test` *and* a
  `--test-event-code`, which routes events to the Test Events tab (not production).

## Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install snowflake-connector-python requests
# credentials (do NOT commit):
export META_ACCESS_TOKEN=...           # only needed for --send-test
export META_DATASET_ID=...
export FIREBASE_API_SECRET_IOS=...     # only needed for firebase validation
export FIREBASE_API_SECRET_ANDROID=...
export FIREBASE_APP_ID_IOS=1:510880785382:ios:03514906a7ba296ea42c27
export FIREBASE_APP_ID_ANDROID=1:510880785382:android:9ac6d6e46c558799a42c27
```

Snowflake auth reuses your `snow` CLI connection (`FAN_DATA_EXCHANGE_PROD`) via the
connector's external-browser / cached OAuth.

## Run

```bash
# 1. Readiness / gap report (no external calls)
python check_source_readiness.py

# 2. Meta payload build + local validation (no send)
python validate_meta_payload.py --limit 50

#    optional: send to Meta Test Events tab only
python validate_meta_payload.py --limit 10 --send-test --test-event-code TEST12345

# 3. Firebase payload build + Google debug validation (no real events)
python validate_firebase_payload.py --limit 50
```

## When to delete

Once the production DAGs in `fes-airflow` are live and validated, these can be
removed. They are intentionally kept out of the fes-airflow repo.
