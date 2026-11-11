-- =============================================================================
-- Deploy the UUIDv7 UDFs to FES_USERS.ALEX_SOTIS and generate 10 examples.
-- Run:  snow sql -c FAN_DATA_EXCHANGE_PROD -f sql/deploy_and_generate.sql
-- (CREATE FUNCTION is state-changing -> you run this, not the assistant.)
-- =============================================================================
USE ROLE SYSADMIN;              -- owns FES_USERS.ALEX_SOTIS; FES_DATA_DEVELOPER lacks CREATE FUNCTION there
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_WH;

-- ---- Functions (pure SQL, RFC 9562) ----------------------------------------

CREATE OR REPLACE FUNCTION UUIDV7_ASSEMBLE(EPOCH_MS NUMBER, RAND_HEX STRING)
RETURNS STRING
IMMUTABLE
COMMENT = 'RFC 9562 UUIDv7 assembly from a 48-bit epoch-ms and a UUID_STRING()-style random hex.'
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

CREATE OR REPLACE FUNCTION UUIDV7_FROM_EPOCH_MS(EPOCH_MS NUMBER)
RETURNS STRING
VOLATILE
COMMENT = 'Generate a UUIDv7 from an explicit unix epoch-millisecond value.'
AS $$ UUIDV7_ASSEMBLE(EPOCH_MS, REPLACE(UUID_STRING(), '-', '')) $$;

CREATE OR REPLACE FUNCTION UUIDV7(TS TIMESTAMP_LTZ)
RETURNS STRING
VOLATILE
COMMENT = 'Generate a UUIDv7 for a specific instant (true epoch).'
AS $$ UUIDV7_FROM_EPOCH_MS(DATE_PART('EPOCH_MILLISECOND', TS)) $$;

CREATE OR REPLACE FUNCTION UUIDV7(TS TIMESTAMP_NTZ)
RETURNS STRING
VOLATILE
COMMENT = 'Generate a UUIDv7 from a TIMESTAMP_NTZ, treating the value as UTC.'
AS $$ UUIDV7_FROM_EPOCH_MS(DATE_PART('EPOCH_MILLISECOND', TS)) $$;

CREATE OR REPLACE FUNCTION UUIDV7()
RETURNS STRING
VOLATILE
COMMENT = 'Generate a UUIDv7 stamped with the current time.'
AS $$ UUIDV7_FROM_EPOCH_MS(DATE_PART('EPOCH_MILLISECOND', CURRENT_TIMESTAMP())) $$;

CREATE OR REPLACE FUNCTION UUIDV7_EPOCH_MS(U STRING)
RETURNS NUMBER
IMMUTABLE
COMMENT = 'Extract unix_ts_ms (first 48 bits) from a UUIDv7 string.'
AS $$ TO_NUMBER(SUBSTR(REPLACE(U, '-', ''), 1, 12), 'XXXXXXXXXXXX') $$;

CREATE OR REPLACE FUNCTION UUIDV7_TIMESTAMP(U STRING)
RETURNS TIMESTAMP_NTZ
IMMUTABLE
COMMENT = 'Decode a UUIDv7 back to its UTC timestamp (TIMESTAMP_NTZ).'
AS $$ TO_TIMESTAMP_NTZ(UUIDV7_EPOCH_MS(U) / 1000.0)::TIMESTAMP_NTZ(9) $$;

-- ---- Generate 10 examples for the Go/Postgres team -------------------------
-- Each row: input timestamp -> UUIDV7(input) -> timestamp decoded back out of
-- that same UUID -> validity flag. decoded_back must equal input_ts_utc.
WITH inputs AS (
    SELECT column1::TIMESTAMP_NTZ AS input_ts, column2 AS note
    FROM VALUES
        ('1970-01-01 00:00:00.000', 'unix epoch zero'),
        ('2020-02-29 12:00:00.000', 'leap day'),
        ('2022-02-22 19:22:22.000', 'RFC 9562 reference instant'),
        ('2022-02-22 19:22:22.000', 'SAME ts as above -> different UUID (non-deterministic)'),
        ('2023-12-31 23:59:59.999', 'end of year, millisecond'),
        ('2024-01-01 00:00:00.000', 'new year 2024'),
        ('2025-06-15 12:34:56.789', 'sub-second precision'),
        ('2026-09-14 17:00:00.000', 'recent'),
        ('2028-07-04 08:15:30.500', 'future with half-second'),
        ('2030-01-01 00:00:00.000', 'far future')
),
gen AS (
    -- materialize one UUID per row so the decode column refers to the SAME value
    SELECT input_ts, note, UUIDV7(input_ts) AS uuidv7
    FROM inputs
)
SELECT
    TO_CHAR(input_ts, 'YYYY-MM-DD HH24:MI:SS.FF3')          AS input_ts_utc,
    DATE_PART('EPOCH_MILLISECOND', input_ts)                AS input_epoch_ms,
    uuidv7,
    TO_CHAR(UUIDV7_TIMESTAMP(uuidv7), 'YYYY-MM-DD HH24:MI:SS.FF3') AS decoded_back_from_uuid,
    uuidv7 RLIKE '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' AS is_valid_v7,
    note
FROM gen
ORDER BY input_epoch_ms;
