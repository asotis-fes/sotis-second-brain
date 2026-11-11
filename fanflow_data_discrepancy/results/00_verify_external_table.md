# Step 0 — Verify external table accessible

## Result

| commerce_rows | distinct_txn_id_status | min_ts | max_ts |
|---|---|---|---|
| 30,289,218 | 30,289,218 | 2026-05-24 20:00:00 | 2026-05-27 23:59:59.971 |

## Interpretation

- External table is queryable and contains 30.3M rows
- `total_rows == distinct(loyTranId, status)` → confirmed unique-per-row on Commerce side
- Time range matches the original UNLOAD (2026-05-24 20:00 UTC → 2026-05-28 00:00 UTC)
- The wider UNLOAD (May 10 → May 24) has not been refreshed into this external table (AUTO_REFRESH=FALSE, no manual ALTER refresh). Fine for our purposes — we want the original 3.5-day window for consistency with prior analysis.
