# Summary — Final findings for the platform team handoff

## Final missing count: 599

Down from the originally-reported 664 after Anna's boundary check caught 65 false positives. Exhaustive verification across all FES data layers, INCLUDING the raw S3 stage parsed on-the-fly, confirms the 599 are genuinely missing from FES.

## Breakdown of the 599

| Category | count | Detail |
|---|---|---|
| Truly missing transactions (zero presence in FES) | **588** | No events for these transactions in fes_enriched, fanapp topic, CDE analytics, or raw S3 stage |
| Partial-lifecycle transactions (different status event present) | **11** | FES received one state transition (e.g., AUTH) but is missing the subsequent one (e.g., CAPTURE_1 or VOID_1) for the same transaction. Found in both fes_enriched AND raw S3 |

## Drop point localized: upstream of FES S3 sink

The raw S3 stage verification (Step 17) is the decisive layer. Combined with Step 16 (raw S3 → fes_enriched is perfectly clean), the loss is conclusively **at or upstream of the S3 sink**, not in any FES Snowflake layer.

```
Commerce ALL topic
  → Enrichment service
  → Commerce fes_enriched topic
  → MirrorMaker2
  → FES Kafka fes_enriched topic
  → S3 sink                              ← LOSS BEFORE OR HERE
────────────────────────────────────────
  S3 files (Snowflake stage)             ← verified clean
  → fes_enriched (Snowflake)             ← verified clean
  → bronze/silver/CDE analytics          ← verified clean
```

Kafka UI trace will localize which hop. Based on what we already know:
- If FES Kafka fes_enriched HAS the events → loss is at S3 sink (FES platform team)
- If FES Kafka fes_enriched does NOT have them but Commerce fes_enriched does → loss is at MirrorMaker2 (FES platform team)
- If Commerce fes_enriched does NOT have them but Commerce ALL does → loss is at enrichment service (Identity team)

## Updates vs the existing Confluence doc

| Field | Was | Now |
|---|---|---|
| Total missing events | 664 | **599** |
| Anomalous hours | 4 (02:00, 12:00, 13:00 on 5/26; 23:00 on 5/27) | **3** (02:00, 12:00, 13:00 on 5/26) — 23:00 hour was 100% boundary artifact |
| Join key | 4-column (`account, txn_id, status, redeem_id`) | 3-column. `redeem_id` verified as a no-op (0 REDEEM events in the missing set) |
| Boundary check | Implicit | Explicit. 65 of original 664 had FES event_ts = `2026-05-28 00:00:00` (1 sec after Commerce ts) |
| Dollar value | Not reported | **$169.92 total** ($13.12 earns / $33.58 captures / $105.22 AUTH / $18.00 VOID) |
| Raw S3 verification | Not done | **Done.** Parsed 4.8M events across all 3 gap hours via fanflow_parse_stage_file. Confirmed 599 absent from raw S3 too. |
| Drop point | Unknown ("upstream of FES Snowflake") | **Upstream of FES S3 sink** — drilled down 2 layers further |
| Partial-lifecycle observation | Not captured | 11 transactions have FES events at one status but missing the subsequent state transition |

## Reply to Anna in Slack thread

> Updates after your boundary push:
>
> 1. **Boundary verified — you were right.** 65 of the original 664 had FES event_ts at exactly `2026-05-28 00:00:00` (1 sec after Commerce ts), just outside our strict `<` bound. All 65 were from the 23:00 UTC hour on 5/27 — that hour is no longer a gap hour. **True missing count: 599.**
>
> 2. **`redeem_id` removed from join.** Verified — joining without it yields the same 599. Zero of the 599 are REDEEM-status (per data dictionary, `redeem_id` only populates for REDEEMs), so it was a no-op for our set. Doc now uses the simpler 3-column join.
>
> 3. **Dollar totals**:
>    - Earns (ADD): 587 events, **$13.12**
>    - Captures (CAPTURE_1): 7 events, **$33.58**
>    - AUTH: 4 events, $105.22
>    - VOID_1: 1 event, $18.00
>    - **Grand total: $169.92 across 599 events** over 3.5 days
>
> 4. **Raw S3 stage parsed and checked.** Pulled 4.8M `LOYALTY_TRANSACTION_SUCCESSFUL.ACCOUNT` events directly from `@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT` (covering 14 hours including all gap hours plus buffer, file window 48 hours). Two findings:
>    - Raw S3 → fes_enriched is clean. Every single S3 event made it into Snowflake. Rules out dbt ingest as the loss source.
>    - 0 of the 599 found by strict 3-column match in raw S3. The events don't exist as files in the FES S3 stage.
>    - The drop point is **at or upstream of the FES S3 sink**.
>
> 5. **Partial-lifecycle observation worth flagging.** 11 transactions exist in fes_enriched AND in raw S3, but with a DIFFERENT state-transition status than what's missing (e.g., FES has AUTH where Commerce has CAPTURE_1 for the same transaction). Those 11 transactions appear "auth-only" in FES analytics when Commerce shows the full lifecycle continued. Separate data-quality flag for the platform team.
>
> 6. **CSV attached** — 599-row file with full payload and enriched_attrs for each event.
>
> 7. **Kafka UI trace next.** 8 sample `loyalty_txn_id`s prepared spanning all 3 gap hours and all 5 distinct site_ids. Trace will localize whether the loss is at S3 sink, MirrorMaker2, or enrichment service.

## Status of all investigation steps

| # | Step | Status | Headline |
|---|------|--------|----------|
| 0 | Verify external table | done | 30.3M rows |
| 1 | Create LOYALTY_MISSING_EVENTS persistent table | done | 664 → became 599 after boundary fix |
| 2 | Anna's no-redeem_id verification | done | Same 664 — redeem_id was a no-op |
| 3 | redeem_id distribution | done | 100% null, 0 REDEEMs |
| 4 | Boundary check vs full silver history | done | 65 boundary, 599 truly missing |
| 4b | Drilldown on 65 boundary | done | All from 23:00 UTC 5/27, FES event_ts = 2026-05-28 00:00:00 |
| 4c | Recreate table with no FES time filter | done | Table now has exactly 599 truly-missing events |
| 5 | Dollar totals by status | done | $169.92 total |
| 6 | Kafka trace samples | done | 8 loyalty_txn_ids captured |
| 7 | Export CSV | done | `missing_loyalty_events_599.csv` |
| 8 | Deep search fes_enriched (no et filter) | done | 11 partial-lifecycle, 588 absent |
| 9 | Deep search fanapp (no et filter) | done | 0 matches |
| 10 | Compare the 11 commerce vs FES | done | All 11 have matching loyTranId+account but different status |
| 11+12 | Check CDE analytics table | done | 0 matches |
| 13 | Final sanity (distinct counts, comprehensive search) | done | 599 unique transactions; nothing recoverable |
| 14 | Parse raw S3 for 3 gap hours | done | 4.8M events captured into working table |
| 15 | Raw S3 sanity stats | done | Pipeline healthy, files land in S3 within minutes |
| 16 | Compare raw S3 vs fes_enriched | done | **Zero gap. dbt ingest is clean.** |
| 17 | Search 599 in raw S3 | done | **0 found by canonical join. Drop is upstream of S3 sink.** |

## What remains for handoff

- **Manual Kafka UI trace** (Alex): use the 8 sample IDs from Step 6 in the FES + Commerce Kafka UIs. Three-layer decision tree localizes the exact drop hop.
- **Update Confluence page 3066134696**: new totals (599 / 3 hours), boundary explanation, simplified 3-column join, raw S3 verification result, partial-lifecycle note, CSV attachment.
