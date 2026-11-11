-- Step 14: Parse raw S3 fes_enriched files for the 3 gap hours
-- Generous parameters per user direction:
--   File window: 2026-05-26 00:00 UTC -> 2026-05-28 00:00 UTC (48 hours)
--   Event window: 2026-05-26 01:00 UTC -> 2026-05-26 15:00 UTC (14 hours, covering all 3 gap hours + 1h buffer)
-- 3XL warehouse
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS AS
WITH raw_s3 AS (
    SELECT
        value:value AS fanflow_event,
        p.relative_path AS _filename,
        p.last_modified AS _file_modified_ts
    FROM DIRECTORY(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT) p,
    LATERAL FLATTEN(input => fde.fde_stage.fanflow_parse_stage_file(
        BUILD_SCOPED_FILE_URL('@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT', p.relative_path)
    ))
    WHERE LEFT(p.relative_path, 13) = 'fes_enriched/'
      AND p.last_modified >= '2026-05-26 00:00:00'::TIMESTAMP_NTZ
      AND p.last_modified <  '2026-05-28 00:00:00'::TIMESTAMP_NTZ
)
SELECT
    fanflow_event:et::STRING                                AS et,
    fanflow_event:a:loyTranId::STRING                       AS loyalty_txn_id,
    fanflow_event:a:loyActID::STRING                        AS loyalty_account_id,
    fanflow_event:a:status::STRING                          AS txn_status,
    fanflow_event:a:redeemId::STRING                        AS redeem_id,
    TO_TIMESTAMP_NTZ((fanflow_event:ts::NUMBER/1000)::NUMBER) AS event_ts,
    _filename,
    _file_modified_ts,
    fanflow_event AS raw_event
FROM raw_s3
WHERE fanflow_event:et::STRING = 'LOYALTY_TRANSACTION_SUCCESSFUL.ACCOUNT'
  AND TO_TIMESTAMP_NTZ((fanflow_event:ts::NUMBER/1000)::NUMBER) >= '2026-05-26 01:00:00'::TIMESTAMP_NTZ
  AND TO_TIMESTAMP_NTZ((fanflow_event:ts::NUMBER/1000)::NUMBER) <  '2026-05-26 15:00:00'::TIMESTAMP_NTZ;

SELECT COUNT(*) AS raw_s3_event_count FROM FES_USERS.ALEX_SOTIS.RAW_S3_LOYALTY_EVENTS_GAP_HOURS;
