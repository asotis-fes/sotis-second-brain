# Step 13 — Final sanity checks

## A. Distinct loyTranIds in our 599 missing set

| row_count | distinct_txn_ids | rows_with_duplicated_txn_ids |
|---|---|---|
| 599 | **599** | 0 |

**Every missing event represents a unique transaction.** No transaction appears twice in our missing set with different statuses.

## B. CDE table search by loyalty_txn_id only (no status match)

Zero rows. None of the 599 transactions exist in `CDE.CDE_CORE.FF_LOYALTY_TRANSACTION_SUCCESSFUL_ACCOUNT` at any status.

## C. fes_enriched_fanapp search by loyalty_txn_id only (no et filter)

Zero rows. None of the 599 transactions exist in the fanapp topic at any status.

## Synthesis — final breakdown of the 599

Cross-referencing Steps 8, 9, 12, 13:

| Category | count | What we know |
|---|---|---|
| Transactions completely absent from FES (no events at any status) | **588** | No trace in fes_enriched, fanapp, or CDE |
| Transactions with partial lifecycle in FES (different status event exists) | **11** | fes_enriched has earlier/later state transition (AUTH where missing has CAPTURE_1, etc.) |
| **Total missing events** | **599** | All confirmed truly missing |

## What this rules out

- ❌ Boundary timing artifacts (only 65 of the original 664 — all in the 23:00 UTC hour boundary, now excluded)
- ❌ `redeem_id` join false positives (verified)
- ❌ Casing/whitespace `et` variants (fes_enriched only has matches with the correct `et`)
- ❌ Wrong bronze topic (fanapp has zero)
- ❌ Different analytics path (CDE has zero)

## What we definitively know

- 599 events are truly absent from every FES data layer we have access to
- 588 of those represent transactions with zero presence in FES
- 11 represent transactions with partial lifecycle in FES (data quality concern worth raising)
- Drop point is upstream of FES Snowflake — somewhere in Commerce → Enrichment → MirrorMaker2 → FES Kafka → S3 sink
- Kafka UI trace is needed to localize which hop loses them
