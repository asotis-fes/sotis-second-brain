USE ROLE SYSADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_WH;

CREATE OR REPLACE FUNCTION UUIDV7_ASSEMBLE(EPOCH_MS NUMBER, RAND_HEX STRING)
RETURNS STRING
IMMUTABLE
AS
$$
    CASE
        WHEN EPOCH_MS IS NULL OR EPOCH_MS < 0 OR EPOCH_MS >= 281474976710656
            THEN TO_CHAR(TO_DATE('uuidv7_epoch_ms_out_of_range:' || COALESCE(EPOCH_MS::STRING, 'NULL')))
        ELSE
            SUBSTR(LOWER(LPAD(TRIM(TO_CHAR(EPOCH_MS, 'XXXXXXXXXXXX')), 12, '0')), 1, 8)
                || '-' || SUBSTR(LOWER(LPAD(TRIM(TO_CHAR(EPOCH_MS, 'XXXXXXXXXXXX')), 12, '0')), 9, 4)
                || '-7' || SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 1, 3)
                || '-' || LOWER(TRIM(TO_CHAR(
                        BITOR(BITAND(TO_NUMBER(SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 17, 1), 'XXXXXXXX'), 3), 8), 'X')))
                || SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 18, 3)
                || '-' || SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 21, 12)
    END
$$;

GRANT USAGE ON FUNCTION FES_USERS.ALEX_SOTIS.UUIDV7_ASSEMBLE(NUMBER, VARCHAR) TO ROLE FES_DATA_DEVELOPER;

USE ROLE FES_DATA_DEVELOPER;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_WH;

WITH gen AS (
    SELECT UUIDV7() AS u FROM TABLE(GENERATOR(ROWCOUNT => 10000))
)
SELECT test, name, result FROM (
    SELECT 1 AS test, 'RFC 9562 vector reconstruction' AS name,
           IFF(UUIDV7_ASSEMBLE(1645557742000, 'cc3000000000000098c4dc0c0c07398f')
               = '017f22e2-79b0-7cc3-98c4-dc0c0c07398f', 'PASS', 'FAIL') AS result
    UNION ALL SELECT 2, 'all 10k match canonical v7 regex',
           IFF((SELECT COUNT(*) FROM gen WHERE NOT u RLIKE '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') = 0, 'PASS', 'FAIL')
    UNION ALL SELECT 3, 'version nibble always 7',
           IFF((SELECT COUNT(*) FROM gen WHERE SUBSTR(u, 15, 1) <> '7') = 0, 'PASS', 'FAIL')
    UNION ALL SELECT 4, 'variant nibble in {8,9,a,b}',
           IFF((SELECT COUNT(*) FROM gen WHERE SUBSTR(u, 20, 1) NOT IN ('8','9','a','b')) = 0, 'PASS', 'FAIL')
    UNION ALL SELECT 5, '10k/10k unique',
           IFF((SELECT COUNT(*) FROM gen) = (SELECT COUNT(DISTINCT u) FROM gen), 'PASS', 'FAIL')
    UNION ALL SELECT 6, 'epoch-ms round-trip',
           IFF(UUIDV7_EPOCH_MS(UUIDV7_FROM_EPOCH_MS(1700000000123)) = 1700000000123, 'PASS', 'FAIL')
    UNION ALL SELECT 7, 'decoder recovers RFC timestamp',
           IFF(UUIDV7_TIMESTAMP('017f22e2-79b0-7cc3-98c4-dc0c0c07398f') = '2022-02-22 19:22:22.000'::TIMESTAMP_NTZ, 'PASS', 'FAIL')
    UNION ALL SELECT 8, 'k-sortable by timestamp',
           IFF(UUIDV7_FROM_EPOCH_MS(1000) < UUIDV7_FROM_EPOCH_MS(2000000000000), 'PASS', 'FAIL')
    UNION ALL SELECT 9, 'max in-range ms (2^48-1) still valid',
           IFF(UUIDV7_ASSEMBLE(281474976710655, 'ffffffffffffffffffffffffffffffff')
               RLIKE '^ffffffff-ffff-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', 'PASS', 'FAIL')
)
ORDER BY test;

-- Guard probe: MUST error (not return a valid-looking UUID). Runs last.
SELECT UUIDV7_FROM_EPOCH_MS(-1) AS should_have_errored;
