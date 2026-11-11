# fanflow_missing_loyalty_events — self-service backfill runbook

When the `fanflow_missing_loyalty_events` test fails (in `dbt_fanflow` or `dbt_loyalty_6hours`),
run these 3 steps. No per-incident editing needed — the SQL is generic and idempotent.

Root cause: legacy enricher drops ~2-3% of loyalty events (Shotover/Cassandra tail-loss).
The dropped events survive in the NEW `FCORE_FES_ENRICHED` topic, which the pipeline doesn't
read yet. This backfill copies them from fcore into `FES_ENRICHED`. Permanent fix = fes-airflow
PR #2241 (fcore cutover) + platform repairing the enricher.

Connection: `snow -c FAN_DATA_EXCHANGE_PROD`, warehouse `FDE_DEVELOPER_2XL_WH`.

---

## Step 1 — Backfill from fcore (run verbatim every time)

```sql
INSERT INTO FANFLOW.SOURCE.FES_ENRICHED (
    WITH fcore_loyalty AS (
        SELECT fcore.*,
               to_timestamp(fcore.fanflow_event:a:creationDate::number, 3) AS creation_time
        FROM FANFLOW.SOURCE.FCORE_FES_ENRICHED AS fcore
        WHERE fcore.fanflow_event:et::VARCHAR = 'LOYALTY_TRANSACTION_SUCCESSFUL.ACCOUNT'
          AND fcore._INSERT_TS >= dateadd('day', -5, current_timestamp())
    ),
    windowed AS (
        SELECT * FROM fcore_loyalty
        WHERE creation_time BETWEEN dateadd('day',-4,current_timestamp())
                                AND dateadd('hour',-3,current_timestamp())   -- matches the test window
    ),
    already_in_fes AS (
        SELECT DISTINCT
            fanflow_event:a:loyActID::VARCHAR  AS loyalty_account_id,
            fanflow_event:a:loyTranId::VARCHAR AS loyalty_txn_id,
            fanflow_event:a:status::VARCHAR    AS txn_status
        FROM FANFLOW.SOURCE.FES_ENRICHED
        WHERE fanflow_event:et::VARCHAR = 'LOYALTY_TRANSACTION_SUCCESSFUL.ACCOUNT'
          AND _INSERT_TS >= dateadd('day', -6, current_timestamp())
    ),
    missing AS (
        SELECT w.*
        FROM windowed w
        LEFT JOIN already_in_fes a
          ON a.loyalty_account_id = w.fanflow_event:a:loyActID::VARCHAR
         AND a.loyalty_txn_id     = w.fanflow_event:a:loyTranId::VARCHAR
         AND a.txn_status         = w.fanflow_event:a:status::VARCHAR
        WHERE a.loyalty_txn_id IS NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY w.fanflow_event:a:loyActID::VARCHAR, w.fanflow_event:a:loyTranId::VARCHAR, w.fanflow_event:a:status::VARCHAR
            ORDER BY w._INSERT_TS DESC) = 1
    )
    SELECT
        concat('backfill-', pk) AS pk, offset, kafka_insert_ts, fanflow_event,
        concat('backfill-', _filename) AS _filename, _file_modified_ts,
        CURRENT_TIMESTAMP AS _dw_insert_ts, CURRENT_TIMESTAMP AS _insert_ts,
        CURRENT_TIMESTAMP AS _update_ts
    FROM missing
);
```

## Step 2 — Flow it through bronze THEN silver (order matters)

Silver reads BRONZE, not fes_enriched. Running silver alone = `SUCCESS 0` and the test still fails.

```bash
dbt run --select loyalty_transaction_successful__account__bronze loyalty_transaction_successful__account
```

## Step 3 — Verify (should return 0)

```sql
WITH scylla AS (
  SELECT * FROM LOYALTY.LOYALTY_CORE.loyalty_transaction_raw
  WHERE creation_time BETWEEN dateadd('day',-4,current_timestamp()) AND dateadd('hour',-3,current_timestamp())),
silver AS (
  SELECT * FROM FANFLOW.ACCOUNT_EVENTS.loyalty_transaction_successful__account
  WHERE creation_time BETWEEN dateadd('day',-4,current_timestamp()) AND dateadd('hour',-3,current_timestamp()))
SELECT count(*) AS still_missing
FROM scylla s LEFT JOIN silver f USING (loyalty_account_id, loyalty_txn_id, txn_status)
WHERE f.loyalty_txn_id IS NULL;
```

---

## Notes / gotchas

- **Safe to re-run.** The `already_in_fes` anti-join skips anything already backfilled, so re-running
  never duplicates. Downstream silver also dedups by `loyalty_txn_k`.
- **It inserts MORE than the test count.** The test compares Scylla↔silver; this backfill grabs all
  fcore loyalty events missing from fes_enriched, which includes real events not in that Scylla table.
  That's expected and correct — do NOT time-travel-undo (fes_enriched is a live append table).
- **It will NOT alert on the extra rows.** The test is one-directional (Scylla rows missing from silver);
  extra silver rows are invisible to it.
- **If Step 3 still returns > 0 after running:** those residual events aren't in fcore either
  (dropped from both topics — rarer S3/Snowpipe-leg loss). Do NOT re-run — escalate to
  #fes-platform-support with the leftover IDs.
- **Big bursts:** if Step 1 inserts hundreds (vs the usual handful), flag it to platform — that's a
  real enricher degradation event, not the normal trickle.
