# Step 5 — Dollar value totals (post-boundary correction, 599 events)

## By transaction status

| txn_status | event_count | total_amount | min | max | avg |
|---|---|---|---|---|---|
| **ADD** (earns) | 587 | **$13.12** | $0.00004 | $5.00 | $0.022 |
| **CAPTURE_1** (captures) | 7 | **$33.58** | $0.15 | $27.00 | $4.80 |
| AUTH | 4 | $105.22 | $1.00 | $82.97 | $26.31 |
| VOID_1 | 1 | $18.00 | $18.00 | $18.00 | $18.00 |
| **TOTAL** | **599** | **$169.92** | | | |

## Interpretation

- **Earns missed: $13.12 across 587 events** (avg $0.022 per event — these are tiny percent-of-bet earn rates, expected for casino bet earns)
- **Captures missed: $33.58 across 7 events** — much smaller event count, much higher avg value per event
- AUTH ($105.22, 4 events) and VOID_1 ($18.00, 1 event) round out the set
- Grand total dollar impact: **$169.92 across 599 events** over the 3.5-day window
- Financial impact is small. The data-quality concern is about **transaction completeness/reconciliation**, not direct $ loss — these are real transactions that didn't reach FES analytics

## By hour and status

| gap_hour_utc | txn_status | event_count | total_amount |
|---|---|---|---|
| 2026-05-26 02:00 | ADD | 415 | $2.86 |
| 2026-05-26 02:00 | AUTH | 1 | $82.97 |
| 2026-05-26 02:00 | CAPTURE_1 | 4 | $32.35 |
| 2026-05-26 12:00 | ADD | 15 | $2.02 |
| 2026-05-26 13:00 | ADD | 157 | $8.24 |
| 2026-05-26 13:00 | AUTH | 3 | $22.25 |
| 2026-05-26 13:00 | CAPTURE_1 | 3 | $1.23 |
| 2026-05-26 13:00 | VOID_1 | 1 | $18.00 |

3 gap hours now (down from 4 after boundary correction removed 2026-05-27 23:00).
