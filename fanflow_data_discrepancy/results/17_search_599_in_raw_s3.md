# Step 17 — Search raw S3 for the 599 specific missing events

## Result

| strategy | found_in_raw_s3 | still_missing | total_checked |
|---|---|---|---|
| A. strict 3-column match (account, txn_id, status) | **0** | **599** | 599 |
| B. loose match by loyalty_txn_id only | 11 | 588 | 599 |

## Interpretation

- **Strategy A**: 0 of the 599 missing events found in raw S3 under the canonical key. The events do not exist as files in the FES S3 stage.
- **Strategy B**: 11 of the 599 transactions have *something* in raw S3, but with a different status (same partial-lifecycle pattern we already found in fes_enriched at Step 8). Same 11 cases.

## Definitive finding

The 599 are confirmed missing from **raw S3 itself**, not just from FES Snowflake. Combined with Step 16 (raw S3 → fes_enriched is perfectly clean), this proves:

**The drop point is at or upstream of the FES S3 sink — NOT in any FES Snowflake layer.**

Specifically, the loss occurs somewhere in this segment of the pipeline:

```
Commerce ALL topic
  → Enrichment service
  → Commerce fes_enriched topic
  → MirrorMaker2
  → FES Kafka fes_enriched topic
  → S3 sink                    ← loss occurs at or before here
  ──────────────────────────
  S3 files (Snowflake stage)   ← all events present here are in fes_enriched
  → fes_enriched (Snowflake)
  → bronze/silver
```

The Kafka UI trace will localize which specific upstream hop drops them.
