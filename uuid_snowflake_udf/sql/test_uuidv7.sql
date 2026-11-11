-- =============================================================================
-- Unit tests for the UUIDv7 UDFs (run AFTER sql/uuidv7.sql in the same schema).
-- Read-only: SELECT only. Returns one row per test with PASS/FAIL.
-- Expected: all 8 rows = PASS.
-- =============================================================================
WITH gen AS (
    SELECT UUIDV7() AS u FROM TABLE(GENERATOR(ROWCOUNT => 10000))
)
SELECT test, name, result FROM (
    -- 1) Independent reference: reconstruct RFC 9562 §B.2 example vector.
    --    unix_ts_ms = 0x017F22E279B0 = 1645557742000; RFC random bits fed back in
    --    (rand_a=cc3 @1-3, variant nibble @17=9, rand_b=8c4 @18-20 + dc0c0c07398f @21-32).
    SELECT 1 AS test, 'RFC 9562 vector reconstruction' AS name,
           IFF(UUIDV7_ASSEMBLE(1645557742000, 'cc3000000000000098c4dc0c0c07398f')
               = '017f22e2-79b0-7cc3-98c4-dc0c0c07398f', 'PASS', 'FAIL') AS result
    UNION ALL
    -- 2) Every generated value matches the canonical UUIDv7 shape.
    SELECT 2, 'all 10k match canonical v7 regex',
           IFF((SELECT COUNT(*) FROM gen
                WHERE NOT u RLIKE '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') = 0,
               'PASS', 'FAIL')
    UNION ALL
    -- 3) Version nibble (char 15) is always 7.
    SELECT 3, 'version nibble always 7',
           IFF((SELECT COUNT(*) FROM gen WHERE SUBSTR(u, 15, 1) <> '7') = 0, 'PASS', 'FAIL')
    UNION ALL
    -- 4) Variant nibble (char 20) is always one of 8,9,a,b (top two bits = 10).
    SELECT 4, 'variant nibble in {8,9,a,b}',
           IFF((SELECT COUNT(*) FROM gen WHERE SUBSTR(u, 20, 1) NOT IN ('8','9','a','b')) = 0, 'PASS', 'FAIL')
    UNION ALL
    -- 5) 10k distinct values (uniqueness / collision sanity).
    SELECT 5, '10k/10k unique',
           IFF((SELECT COUNT(*) FROM gen) = (SELECT COUNT(DISTINCT u) FROM gen), 'PASS', 'FAIL')
    UNION ALL
    -- 6) Embedded timestamp round-trips exactly.
    SELECT 6, 'epoch-ms round-trip',
           IFF(UUIDV7_EPOCH_MS(UUIDV7_FROM_EPOCH_MS(1700000000123)) = 1700000000123, 'PASS', 'FAIL')
    UNION ALL
    -- 7) Decoder recovers the RFC vector's UTC instant.
    --    0x017F22E279B0 = 1645557742000 ms = 2022-02-22 19:22:22 UTC (verified in-DB).
    SELECT 7, 'decoder recovers RFC timestamp',
           IFF(UUIDV7_TIMESTAMP('017f22e2-79b0-7cc3-98c4-dc0c0c07398f')
               = '2022-02-22 19:22:22.000'::TIMESTAMP_NTZ, 'PASS', 'FAIL')
    UNION ALL
    -- 8) k-sortable: an earlier timestamp sorts lexicographically before a later one.
    SELECT 8, 'k-sortable by timestamp',
           IFF(UUIDV7_FROM_EPOCH_MS(1000) < UUIDV7_FROM_EPOCH_MS(2000000000000), 'PASS', 'FAIL')
)
ORDER BY test;

-- Eyeball sample:
-- SELECT UUIDV7() AS generated, UUIDV7_TIMESTAMP(UUIDV7()) AS decoded_ts;
