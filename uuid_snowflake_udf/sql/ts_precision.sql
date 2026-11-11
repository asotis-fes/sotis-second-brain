USE ROLE FES_DATA_DEVELOPER;
USE WAREHOUSE FDE_DEVELOPER_WH;

-- 1) Declared column types
SELECT table_catalog, table_schema, table_name, column_name, data_type
FROM LOYALTY.INFORMATION_SCHEMA.COLUMNS
WHERE (table_schema, table_name, column_name) IN (
    ('LOYALTY_CORE', 'LOYALTY_ANALYTICS_LEDGER', 'CREATION_TIME')
)
ORDER BY table_name;

-- 2) Does the DATA actually carry sub-second precision? (sampled)
SELECT
    COUNT(*)                                                                   AS n_sampled,
    SUM(IFF(creation_time <> DATE_TRUNC('second', creation_time), 1, 0))       AS rows_with_subsecond,
    SUM(IFF(creation_time <> DATE_TRUNC('millisecond', creation_time), 1, 0))  AS rows_finer_than_ms,
    MIN(creation_time)                                                         AS min_ts,
    MAX(creation_time)                                                         AS max_ts
FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER
    SAMPLE (1000000 ROWS)
WHERE creation_time >= '2023-01-01';

-- 3) A few raw values at full precision, to eyeball the fractional seconds
SELECT TO_CHAR(creation_time, 'YYYY-MM-DD HH24:MI:SS.FF9') AS creation_time_full
FROM LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER
WHERE creation_time >= '2023-01-01'
LIMIT 8;
