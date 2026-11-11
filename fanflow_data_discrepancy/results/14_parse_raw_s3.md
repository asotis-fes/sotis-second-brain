# Step 14 — Parse raw S3 fes_enriched files for the 3 gap hours

## Result

- Working table: `FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS`
- Row count: **4,821,800**
- File window: 2026-05-26 00:00 → 2026-05-28 00:00 UTC (48 hours)
- Event window: 2026-05-26 01:00 → 2026-05-26 15:00 UTC (14 hours, covers all 3 gap hours + 1h buffer)
- Warehouse: FDE_DEVELOPER_3XL_WH

## Sanity stats

| metric | value |
|---|---|
| raw_event_count | 4,821,800 |
| distinct_txn_ids | 4,775,357 |
| distinct_files | 17,065 |
| earliest_event_ts | 2026-05-26 01:00:00 |
| latest_event_ts | 2026-05-26 14:59:59 |
| earliest_file_ts | 2026-05-26 01:00:20 |
| latest_file_ts | 2026-05-26 15:04:25 |

File modification timestamps span 01:00–15:04 UTC — events land in S3 within minutes of creation. The 48-hour file window was generous overkill but confirmed no events landed in S3 later than ~5 min after their event_ts.

## Hour distribution

| event_hour_utc | events | distinct_txn_ids |
|---|---|---|
| 2026-05-26 01:00 | 883,502 | 875,408 |
| 2026-05-26 02:00 (gap) | 972,304 | 964,886 |
| 2026-05-26 03:00 | 796,372 | 790,874 |
| 2026-05-26 04:00 | 499,537 | 494,006 |
| 2026-05-26 05:00 | 342,866 | 340,451 |
| 2026-05-26 06:00 | 45,707 | 45,351 |
| 2026-05-26 07:00 | 427 | 373 |
| 2026-05-26 08:00 | 15,038 | 14,690 |
| 2026-05-26 09:00 | 132,450 | 130,825 |
| 2026-05-26 10:00 | 173,485 | 171,538 |
| 2026-05-26 11:00 | 202,812 | 200,291 |
| 2026-05-26 12:00 (gap) | 224,184 | 221,053 |
| 2026-05-26 13:00 (gap) | 253,768 | 250,118 |
| 2026-05-26 14:00 | 279,348 | 275,695 |
