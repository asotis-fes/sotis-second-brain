-- fanflow backfill: faithful dbt incremental MERGE (on pk), window widened to now-13h .. now
-- Source of truth: compiled dbt Cloud model body + real MERGE clauses pulled from query_history.
-- ONLY deviation from prod dbt code is the ingestion window anchor:
--   broken  '2023-01-02T00:00:00'::timestamp_ntz
--   ->      CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz   (lower bound 2h -> 13h)
-- Idempotent: merges on pk (matched -> update, not matched -> insert). Safe to re-run.
-- STOPGAP ONLY until the data_interval_end macro fix actually takes effect.

USE WAREHOUSE FDE_DEVELOPER_3XL_WH;

-- ============================================================================
-- 1/5  fcore_fes_enriched
-- ============================================================================
MERGE INTO FANFLOW.SOURCE.fcore_fes_enriched AS DBT_INTERNAL_DEST
USING (
--noqa: disable=ST03,LT07,LT09,LT02,AL03
WITH files_to_ingest AS (
    WITH parsed_files AS (
    SELECT DISTINCT
        _filename,
        _file_modified_ts
    FROM FANFLOW.SOURCE.fcore_fes_enriched
    WHERE
        _file_modified_ts >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
        AND _file_modified_ts < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
)SELECT
    p.relative_path AS _filename,
    p.last_modified AS _file_modified_ts
FROM DIRECTORY(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT) AS p
LEFT JOIN parsed_files AS n
    ON p.relative_path = n._filename
WHERE
    STARTSWITH(p.relative_path, 'fcore_fes_enriched' || '/')
    AND p.last_modified >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
    AND p.last_modified < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
    AND n._filename IS NULL
),
src AS (
    SELECT
        _filename,
        SPLIT(_filename, '/')[1]::integer AS kafka_partition,
        _file_modified_ts::timestamp_ntz(9) AS last_modified_ts,
        fde.fde_stage.fanflow_parse_stage_file(
            BUILD_SCOPED_FILE_URL(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT, _filename)
        ) AS records
    FROM files_to_ingest
)
SELECT
    kafka_partition || '-' || value:offset AS pk,
    value:offset AS offset,
    value:timestamp AS kafka_insert_ts,
    value:value AS fanflow_event,
    src._filename,
    src.last_modified_ts AS _file_modified_ts,
    current_timestamp AS _insert_ts,
    current_timestamp AS _update_ts
FROM src,
LATERAL FLATTEN(input => src.records)
) AS S
ON (S.pk = DBT_INTERNAL_DEST.pk)
WHEN MATCHED THEN UPDATE SET
    "PK" = S."PK","OFFSET" = S."OFFSET","KAFKA_INSERT_TS" = S."KAFKA_INSERT_TS","FANFLOW_EVENT" = S."FANFLOW_EVENT","_FILENAME" = S."_FILENAME","_FILE_MODIFIED_TS" = S."_FILE_MODIFIED_TS","_UPDATE_TS" = S."_UPDATE_TS"
WHEN NOT MATCHED THEN INSERT
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS")
VALUES
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS");

-- ============================================================================
-- 2/5  fcore_fes_enriched_fanapp
-- ============================================================================
MERGE INTO FANFLOW.SOURCE.fcore_fes_enriched_fanapp AS DBT_INTERNAL_DEST
USING (
--noqa: disable=ST03,LT07,LT09,LT02,AL03
WITH files_to_ingest AS (
    WITH parsed_files AS (
    SELECT DISTINCT
        _filename,
        _file_modified_ts
    FROM FANFLOW.SOURCE.fcore_fes_enriched_fanapp
    WHERE
        _file_modified_ts >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
        AND _file_modified_ts < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
)SELECT
    p.relative_path AS _filename,
    p.last_modified AS _file_modified_ts
FROM DIRECTORY(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT) AS p
LEFT JOIN parsed_files AS n
    ON p.relative_path = n._filename
WHERE
    STARTSWITH(p.relative_path, 'fcore_fes_enriched_fanapp' || '/')
    AND p.last_modified >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
    AND p.last_modified < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
    AND n._filename IS NULL
),
src AS (
    SELECT
        _filename,
        SPLIT(_filename, '/')[1]::integer AS kafka_partition,
        _file_modified_ts::timestamp_ntz(9) AS last_modified_ts,
        fde.fde_stage.fanflow_parse_stage_file(
            BUILD_SCOPED_FILE_URL(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT, _filename)
        ) AS records
    FROM files_to_ingest
)
SELECT
    kafka_partition || '-' || value:offset AS pk,
    value:offset AS offset,
    value:timestamp AS kafka_insert_ts,
    value:value AS fanflow_event,
    src._filename,
    src.last_modified_ts AS _file_modified_ts,
    current_timestamp AS _insert_ts,
    current_timestamp AS _update_ts
FROM src,
LATERAL FLATTEN(input => src.records)
) AS S
ON (S.pk = DBT_INTERNAL_DEST.pk)
WHEN MATCHED THEN UPDATE SET
    "PK" = S."PK","OFFSET" = S."OFFSET","KAFKA_INSERT_TS" = S."KAFKA_INSERT_TS","FANFLOW_EVENT" = S."FANFLOW_EVENT","_FILENAME" = S."_FILENAME","_FILE_MODIFIED_TS" = S."_FILE_MODIFIED_TS","_UPDATE_TS" = S."_UPDATE_TS"
WHEN NOT MATCHED THEN INSERT
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS")
VALUES
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS");

-- ============================================================================
-- 3/5  fes_enriched   (9-col table; dbt merge inserts only these 8, never _DW_INSERT_TS)
-- ============================================================================
MERGE INTO FANFLOW.SOURCE.fes_enriched AS DBT_INTERNAL_DEST
USING (
--noqa: disable=ST03,LT07,LT09,LT02,AL03
WITH files_to_ingest AS (
    WITH parsed_files AS (
    SELECT DISTINCT
        _filename,
        _file_modified_ts
    FROM FANFLOW.SOURCE.fes_enriched
    WHERE
        _file_modified_ts >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
        AND _file_modified_ts < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
)SELECT
    p.relative_path AS _filename,
    p.last_modified AS _file_modified_ts
FROM DIRECTORY(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT) AS p
LEFT JOIN parsed_files AS n
    ON p.relative_path = n._filename
WHERE
    STARTSWITH(p.relative_path, 'fes_enriched' || '/')
    AND p.last_modified >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
    AND p.last_modified < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
    AND n._filename IS NULL
),
src AS (
    SELECT
        _filename,
        SPLIT(_filename, '/')[1]::integer AS kafka_partition,
        _file_modified_ts::timestamp_ntz(9) AS last_modified_ts,
        fde.fde_stage.fanflow_parse_stage_file(
            BUILD_SCOPED_FILE_URL(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT, _filename)
        ) AS records
    FROM files_to_ingest
)
SELECT
    kafka_partition || '-' || value:offset AS pk,
    value:offset AS offset,
    value:timestamp AS kafka_insert_ts,
    value:value AS fanflow_event,
    src._filename,
    src.last_modified_ts AS _file_modified_ts,
    current_timestamp AS _insert_ts,
    current_timestamp AS _update_ts
FROM src,
LATERAL FLATTEN(input => src.records)
) AS S
ON (S.pk = DBT_INTERNAL_DEST.pk)
WHEN MATCHED THEN UPDATE SET
    "PK" = S."PK","OFFSET" = S."OFFSET","KAFKA_INSERT_TS" = S."KAFKA_INSERT_TS","FANFLOW_EVENT" = S."FANFLOW_EVENT","_FILENAME" = S."_FILENAME","_FILE_MODIFIED_TS" = S."_FILE_MODIFIED_TS","_UPDATE_TS" = S."_UPDATE_TS"
WHEN NOT MATCHED THEN INSERT
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS")
VALUES
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS");

-- ============================================================================
-- 4/5  fes_enriched_fanapp
-- ============================================================================
MERGE INTO FANFLOW.SOURCE.fes_enriched_fanapp AS DBT_INTERNAL_DEST
USING (
--noqa: disable=ST03,LT07,LT09,LT02,AL03
WITH files_to_ingest AS (
    WITH parsed_files AS (
    SELECT DISTINCT
        _filename,
        _file_modified_ts
    FROM FANFLOW.SOURCE.fes_enriched_fanapp
    WHERE
        _file_modified_ts >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
        AND _file_modified_ts < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
)SELECT
    p.relative_path AS _filename,
    p.last_modified AS _file_modified_ts
FROM DIRECTORY(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT) AS p
LEFT JOIN parsed_files AS n
    ON p.relative_path = n._filename
WHERE
    STARTSWITH(p.relative_path, 'fes_enriched_fanapp' || '/')
    AND p.last_modified >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
    AND p.last_modified < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
    AND n._filename IS NULL
),
src AS (
    SELECT
        _filename,
        SPLIT(_filename, '/')[1]::integer AS kafka_partition,
        _file_modified_ts::timestamp_ntz(9) AS last_modified_ts,
        fde.fde_stage.fanflow_parse_stage_file(
            BUILD_SCOPED_FILE_URL(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT, _filename)
        ) AS records
    FROM files_to_ingest
)
SELECT
    kafka_partition || '-' || value:offset AS pk,
    value:offset AS offset,
    value:timestamp AS kafka_insert_ts,
    value:value AS fanflow_event,
    src._filename,
    src.last_modified_ts AS _file_modified_ts,
    current_timestamp AS _insert_ts,
    current_timestamp AS _update_ts
FROM src,
LATERAL FLATTEN(input => src.records)
) AS S
ON (S.pk = DBT_INTERNAL_DEST.pk)
WHEN MATCHED THEN UPDATE SET
    "PK" = S."PK","OFFSET" = S."OFFSET","KAFKA_INSERT_TS" = S."KAFKA_INSERT_TS","FANFLOW_EVENT" = S."FANFLOW_EVENT","_FILENAME" = S."_FILENAME","_FILE_MODIFIED_TS" = S."_FILE_MODIFIED_TS","_UPDATE_TS" = S."_UPDATE_TS"
WHEN NOT MATCHED THEN INSERT
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS")
VALUES
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS");

-- ============================================================================
-- 5/5  fes_fanflow_enriched
-- ============================================================================
MERGE INTO FANFLOW.SOURCE.fes_fanflow_enriched AS DBT_INTERNAL_DEST
USING (
--noqa: disable=ST03,LT07,LT09,LT02,AL03
WITH files_to_ingest AS (
    WITH parsed_files AS (
    SELECT DISTINCT
        _filename,
        _file_modified_ts
    FROM FANFLOW.SOURCE.fes_fanflow_enriched
    WHERE
        _file_modified_ts >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
        AND _file_modified_ts < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
)SELECT
    p.relative_path AS _filename,
    p.last_modified AS _file_modified_ts
FROM DIRECTORY(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT) AS p
LEFT JOIN parsed_files AS n
    ON p.relative_path = n._filename
WHERE
    STARTSWITH(p.relative_path, 'fes_fanflow_enriched' || '/')
    AND p.last_modified >= CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '13 hours'
    AND p.last_modified < CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::timestamp_ntz - INTERVAL '0 hours'
    AND n._filename IS NULL
),
src AS (
    SELECT
        _filename,
        SPLIT(_filename, '/')[1]::integer AS kafka_partition,
        _file_modified_ts::timestamp_ntz(9) AS last_modified_ts,
        fde.fde_stage.fanflow_parse_stage_file(
            BUILD_SCOPED_FILE_URL(@FDE.FDE_STAGE.PROD_FANFLOW_KAFKA_CONNECT, _filename)
        ) AS records
    FROM files_to_ingest
)
SELECT
    kafka_partition || '-' || value:offset AS pk,
    value:offset AS offset,
    value:timestamp AS kafka_insert_ts,
    value:value AS fanflow_event,
    src._filename,
    src.last_modified_ts AS _file_modified_ts,
    current_timestamp AS _insert_ts,
    current_timestamp AS _update_ts
FROM src,
LATERAL FLATTEN(input => src.records)
) AS S
ON (S.pk = DBT_INTERNAL_DEST.pk)
WHEN MATCHED THEN UPDATE SET
    "PK" = S."PK","OFFSET" = S."OFFSET","KAFKA_INSERT_TS" = S."KAFKA_INSERT_TS","FANFLOW_EVENT" = S."FANFLOW_EVENT","_FILENAME" = S."_FILENAME","_FILE_MODIFIED_TS" = S."_FILE_MODIFIED_TS","_UPDATE_TS" = S."_UPDATE_TS"
WHEN NOT MATCHED THEN INSERT
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS")
VALUES
    ("PK", "OFFSET", "KAFKA_INSERT_TS", "FANFLOW_EVENT", "_FILENAME", "_FILE_MODIFIED_TS", "_INSERT_TS", "_UPDATE_TS");
