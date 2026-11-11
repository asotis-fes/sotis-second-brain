# Step 8 — Deep search of fes_enriched (raw) by loyTranId only

## Result

| et_in_fes | distinct_matching_txn_ids | matching_rows | earliest_event_ts | latest_event_ts |
|---|---|---|---|---|
| LOYALTY_TRANSACTION_SUCCESSFUL.ACCOUNT | **11** | 11 | 2026-05-26 02:19:42 | 2026-05-26 13:41:30 |

## Interpretation

11 of our 599 missing `loyalty_txn_id`s appear in `fes_enriched` — with the correct `et` value — but they were NOT matched by our canonical join.

## Drilldown (Step 10) — why didn't bronze catch them?

For all 11, the loyalty_account_id matches perfectly between Commerce and FES. The difference is **status**:

| loyalty_txn_id | commerce_status | fes_status | commerce_event_ts | fes_event_ts |
|---|---|---|---|---|
| 5afeee90... | CAPTURE_1 | AUTH | 02:19:42.804 | 02:19:42 |
| b25f7140... | CAPTURE_1 | AUTH | 02:29:18.946 | 02:29:19 |
| c1f835b0... | AUTH | CAPTURE_1 | 02:29:44.755 | 02:29:52 |
| bd3e7e30... | CAPTURE_1 | AUTH | 02:29:46.729 | 02:29:37 |
| c3736401... | CAPTURE_1 | AUTH | 02:29:47.440 | 02:29:47 |
| 2a01a1c0... | CAPTURE_1 | AUTH | 13:02:35.157 | 13:02:35 |
| e1ffb950... | AUTH | CAPTURE_1 | 13:14:53.191 | 13:15:00 |
| decfaf10... | VOID_1 | AUTH | 13:14:54.312 | 13:14:48 |
| e2dd9630... | AUTH | CAPTURE_1 | 13:14:54.642 | 13:23:47 |
| e3132520... | CAPTURE_1 | AUTH | 13:14:55.258 | 13:14:55 |
| 99d2de60... | AUTH | CAPTURE_1 | 13:41:30.086 | 13:41:30 |

## What this means

For these 11 transactions, FES received **a different state in the lifecycle** than what Commerce is showing us as missing.

Example: transaction `5afeee90...`
- Commerce has the **CAPTURE_1** event in our missing set (FES doesn't have it)
- FES has the **AUTH** event for the same transaction (Commerce iceberg may or may not also have this AUTH separately — different event)

These are *different events* per the join key `(account, loyalty_txn_id, status)`. The join correctly does not match them. The 599 stays at 599.

## New finding to flag

**11 transactions have partial lifecycle in FES.** FES received one state transition (e.g., AUTH) but not the subsequent one (e.g., CAPTURE_1 or VOID_1). This is concerning for analytics downstream — those transactions appear "auth-only" in FES when they were actually captured or voided in Commerce. Worth flagging to the platform team alongside the headline 599-event loss.
