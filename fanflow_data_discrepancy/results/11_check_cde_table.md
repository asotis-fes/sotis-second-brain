# Steps 11–12 — Check CDE.CDE_CORE.FF_LOYALTY_TRANSACTION_SUCCESSFUL_ACCOUNT

The CDE table is the loyalty analytics layer referenced in the recover-tier-points runbook (page 2384461902). It's an external table pulling from a different parquet source than `fes_enriched`, so worth checking as a separate data path.

## Step 12 — search by (loyalty_txn_id, status) — match key

| rows_in_cde_matching | distinct_txn_ids_in_cde |
|---|---|
| **0** | **0** |

## Step 13B — search by loyalty_txn_id only (regardless of status)

Zero rows returned across all statuses.

## Interpretation

The 599 missing events are absent from the CDE analytics layer entirely. This is consistent — CDE is likely fed from the same upstream commerce data path that's losing these events, so they're missing here too.
