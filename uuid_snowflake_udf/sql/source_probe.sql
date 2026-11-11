USE ROLE FES_DATA_DEVELOPER;
USE WAREHOUSE FDE_DEVELOPER_WH;

-- 1) All columns + types for the historical ledger and the new transaction source
SELECT table_schema, table_name, column_name, data_type, ordinal_position
FROM LOYALTY.INFORMATION_SCHEMA.COLUMNS
WHERE (table_schema = 'LOYALTY_CORE' AND table_name = 'LOYALTY_ANALYTICS_LEDGER')
   OR (table_schema = 'SOURCE'       AND table_name = 'TRANSACTION_UNI_EXT')
ORDER BY table_name, ordinal_position;

-- 2) A few sample rows of the ledger (eyeball ids + all timestamps at full precision)
SELECT * FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER
    SAMPLE (3 ROWS)
WHERE creation_time >= '2023-01-01';

-- 3) A few sample rows of the new transaction source
SELECT * FROM LOYALTY.SOURCE.TRANSACTION_UNI_EXT SAMPLE (3 ROWS);
