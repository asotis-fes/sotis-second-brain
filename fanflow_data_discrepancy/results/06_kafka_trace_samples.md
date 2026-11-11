# Step 6 — Sample loyalty_txn_ids for Kafka UI trace

One representative event per `(gap_hour_utc, txn_status)` combination, ordered by event_ts.

## Samples (8 total — covers all 3 remaining gap hours × all observed statuses)

| gap_hour_utc | txn_status | loyalty_txn_id | site_id | tenant_id | external_ref_id | event_ts |
|---|---|---|---|---|---|---|
| 2026-05-26 02:00 | ADD | `729937f0-58a8-11f1-b990-198b878660d8` | 515621 | (null) | `365-4722-5291+3` | 02:13:12.586 |
| 2026-05-26 02:00 | AUTH | `c1f835b0-58aa-11f1-8f83-8fd8b84ded06` | 515620 | (null) | `21-9523-2464` | 02:29:44.755 |
| 2026-05-26 02:00 | CAPTURE_1 | `5afeee90-58a9-11f1-90ed-bdff0133ce6c` | 608111 | 100002 | `5afbba40-58a9-11f1-bcbb-3165b5faa154` | 02:19:42.804 |
| 2026-05-26 12:00 | ADD | `c88df830-5902-11f1-b058-4967835caf97` | 608111 | 100002 | `BONUS_SETTLEMENT_10645743690` | 12:59:51.516 |
| 2026-05-26 13:00 | ADD | `6671bd20-5903-11f1-b990-198b878660d8` | 608111 | 100002 | `FANCASH_WAGERED_CASHOUT_26209474000019803` | 13:04:16.399 |
| 2026-05-26 13:00 | AUTH | `e1ffb950-5904-11f1-a218-9d4f2558fd56` | 610753 | 100004 | `US-13687975-S` | 13:14:53.191 |
| 2026-05-26 13:00 | CAPTURE_1 | `2a01a1c0-5903-11f1-9090-db0e136f54ea` | 608111 | 100002 | `29fee2a0-5903-11f1-a356-2131acb8502a` | 13:02:35.157 |
| 2026-05-26 13:00 | VOID_1 | `decfaf10-5904-11f1-8f83-8fd8b84ded06` | 610935 | 100015 | `372a0f3e-4079-4d55-8ae1-8f5352582bd5` | 13:14:54.312 |

## Kafka UI trace plan

For each `loyalty_txn_id`, check in order:

1. **FES Kafka `fes_enriched`** — https://kafka-ui.prod.fanatics-app.com/ui/clusters/fanflow-prod/all-topics/fes_enriched/messages
   - Use MessagePack deserialization (per Anna's screenshot)
   - Search by `loyalty_txn_id` value
   - If found → drop is FES Kafka → S3 sink. FES platform team.
   - If not found → continue to step 2.

2. **Commerce `fes_enriched`** — https://master.fanflow-kafka-ui.prod.frgcloud.com/ui/clusters/ecomprod/all-topics/fes_enriched/messages
   - If found → drop is MirrorMaker2 (between Commerce Kafka and FES Kafka). FES platform team.
   - If not found → continue to step 3.

3. **Commerce `ALL`** — same Commerce Kafka UI, different topic
   - If found → drop is enrichment service. Identity team (`#lids-data-identity-eng`).
   - If not found → escalate, indicates problem further upstream.

## Cross-site representation

The 8 sample IDs span all 5 distinct site_ids in our 599 missing events:
- 608111 / 100002 (FBG sportsbook casino, 4 samples)
- 515621 / null (3 events total, 1 sample)
- 515620 / null (1 event total, 1 sample)
- 610935 / 100015 (1 event total, 1 sample)
- 610753 / 100004 (1 event total, 1 sample)

Tracing all 8 will tell us whether the drop point is consistent across sites or differs by site/tenant.
