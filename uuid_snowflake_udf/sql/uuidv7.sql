-- =============================================================================
-- UUIDv7 generator for Snowflake  (RFC 9562 §5.7)   -- PURE SQL, no JavaScript.
-- =============================================================================
-- Purpose: mint valid, unique, k-sortable UUIDv7 values on the Snowflake side of
-- the Snowflake -> Postgres migration. These are NOT reproductions of any specific
-- gofrs/uuid output (gofrs NewV7 uses 74 crypto-random bits and cannot be matched);
-- they are standards-compliant v7s that Snowflake generates as the source of truth.
-- The other team has confirmed non-determinism is fine.
--
-- Layout (32 hex, grouped 8-4-4-4-12):
--   [ 48-bit unix_ts_ms ] [ ver=0x7 | rand_a(12b) ] [ variant=10 | rand_b(62b) ]
--
-- Randomness comes from Snowflake's native UUID_STRING() (a crypto-random v4 UUID),
-- so no PRNG is reimplemented. int<->hex uses TO_CHAR/TO_NUMBER with the 'X' format.
-- Every expression below was validated read-only in FAN_DATA_EXCHANGE_PROD
-- (50k-row bulk check + RFC 9562 vector reconstruction) before being wrapped as UDFs.
--
-- SET YOUR TARGET before running, e.g.:  USE DATABASE <DB>; USE SCHEMA <SCHEMA>;
-- =============================================================================

-- 1) Deterministic assembler: pure formatting of (epoch_ms, random hex).
--    RAND_HEX = a UUID_STRING()-style hex string (>= 32 hex chars). The variant
--    nibble is force-set to RFC 10xx, so ANY input hex yields a valid v7.
CREATE OR REPLACE FUNCTION UUIDV7_ASSEMBLE(EPOCH_MS NUMBER, RAND_HEX STRING)
RETURNS STRING
IMMUTABLE
COMMENT = 'RFC 9562 UUIDv7 assembly from a 48-bit epoch-ms and a UUID_STRING()-style random hex.'
-- NOTE: single scalar expression (no CTE/subquery) — a subquery inside a scalar
-- SQL UDF fails with "Unsupported subquery type ... inside Function object" when
-- the function is called per-row. The ts/rand exprs are repeated inline instead.
AS
$$
    CASE
        -- Guard: 48-bit timestamp must fit [0, 2^48). TO_CHAR('X') would otherwise emit
        -- two's-complement hex for negatives (pre-1970) or '#' overflow, both SILENT.
        -- Fail loud instead (the offending value appears in the error message).
        WHEN EPOCH_MS IS NULL OR EPOCH_MS < 0 OR EPOCH_MS >= 281474976710656
            THEN TO_CHAR(TO_DATE('uuidv7_epoch_ms_out_of_range:' || COALESCE(EPOCH_MS::STRING, 'NULL')))
        ELSE
            SUBSTR(LOWER(LPAD(TRIM(TO_CHAR(EPOCH_MS, 'XXXXXXXXXXXX')), 12, '0')), 1, 8)        -- time_high
                || '-' || SUBSTR(LOWER(LPAD(TRIM(TO_CHAR(EPOCH_MS, 'XXXXXXXXXXXX')), 12, '0')), 9, 4)  -- time_mid
                || '-7' || SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 1, 3)                     -- ver=7 + rand_a
                || '-' || LOWER(TRIM(TO_CHAR(                                                  -- variant: (nibble&3)|8
                        BITOR(BITAND(TO_NUMBER(SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 17, 1), 'XXXXXXXX'), 3), 8), 'X')))
                || SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 18, 3)                            -- rand_b hi
                || '-' || SUBSTR(LOWER(REPLACE(RAND_HEX, '-', '')), 21, 12)                    -- rand_b lo
    END
$$;

-- 2) Generators (VOLATILE: fresh randomness per row; not constant-folded).
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

-- NTZ variant: treats the stored wall-clock value as UTC (adjust upstream if not UTC).
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

-- 3) Decoders (debug / validation): recover the embedded timestamp.
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
