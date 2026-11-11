# Tiger Project — S2S Conversion Event Export (Meta CAPI + Firebase MP)

**Epic:** [ENTDATA-2246 "Tiger project"](https://betfanatics.atlassian.net/browse/ENTDATA-2246)
**Status:** design / pre-build
**Owner (DE):** Alex Sotis · **Owner (AE tables):** Zoe Sarwar
**Last updated:** 2026-08-07

## What this is

Send server-to-server (S2S) post-install conversion events from FES Snowflake/dbt
models directly to ad platforms — **Meta Conversions API (CAPI)** and **Google
Firebase Measurement Protocol (MP)** — *without* going through a CDP (Segment /
GrowthLoop). This lets Meta Ads and Google Ads optimize campaigns on events like
`new_fbg`, `new_commerce`, etc.

## Architecture

```
fes_users.zoe_sarwar.gl_new_to_x        ← single source of truth (966,179 rows, ~2,239/wk new)
        │
        │  (AE: dbt/SQL populate staging tables)
        ├──────────────────────────────► fde.fde_info.meta_capi_export      → (DE: Airflow send job) → Meta CAPI
        └──────────────────────────────► fde.fde_info.firebase_mp_export    → (DE: Airflow send job) → Firebase MP
```

- **AE side** (ENTDATA-2264, ENTDATA-2265): build & maintain the export-ready staging
  tables. One row per (user, event). Set `ready_to_send = TRUE` only when all
  required payload fields are populated. Hourly backfill re-checks not-ready rows.
- **DE side** (ENTDATA-2262, ENTDATA-2259): Airflow jobs that read
  `ready_to_send = TRUE AND sent_at IS NULL`, POST to the platform, then stamp
  `sent_at` / `batch_id`.

## Tickets

| Ticket | Side | Scope |
|--------|------|-------|
| [ENTDATA-2262](https://betfanatics.atlassian.net/browse/ENTDATA-2262) | DE | Export dbt models → Meta CAPI (send job) |
| [ENTDATA-2259](https://betfanatics.atlassian.net/browse/ENTDATA-2259) | DE | Export dbt models → Google Firebase (send job) |
| [ENTDATA-2264](https://betfanatics.atlassian.net/browse/ENTDATA-2264) | AE | Meta CAPI export table + population logic |
| [ENTDATA-2265](https://betfanatics.atlassian.net/browse/ENTDATA-2265) | AE | Firebase MP export table + population logic |

## Files in this folder

- `README.md` — this file
- `gap-analysis.md` — **the headline deliverable**: continuity check between the
  DE export code, the DE env/secrets, and the AE table fields, verified against
  the live source table. Read this first.
- `source-table-findings.md` — live schema + fill-rate measurements of
  `gl_new_to_x` (the evidence behind the gap analysis).
- `field-crosswalk.md` — field-by-field mapping: payload field → AE column →
  source column, for both platforms.
- `scripts/` — **temporary, local** dry-run validation scripts. These do NOT send
  real data. See `scripts/README.md`.

## Production code location

The real Airflow export jobs live in the **fes-airflow** repo, not here.
Branch: `tiger/capi-firebase-export`. See `gap-analysis.md` → "Open decisions"
before wiring the send jobs to production.
