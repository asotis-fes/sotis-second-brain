# Step 16 — Raw S3 vs fes_enriched

## Result

| in_s3_but_not_in_fes_enriched | in_both | total_s3_event_keys |
|---|---|---|
| **0** | 4,821,534 | 4,821,534 |

## Interpretation

**Zero events landed in raw S3 that didn't make it to `fes_enriched`.** The dbt ingest pipeline (S3 → `fes_enriched`) is operating cleanly — no late-arriving files past the 2h lookback, no failed MERGEs, nothing skipped.

This rules out the dbt ingest layer as a source of the loss.
