EXPLAIN USING TEXT
WITH s AS (SELECT 1 AS a, 2 AS chunk_num), r AS (SELECT 1 AS a, 5 AS chunk_num)
SELECT s.* EXCLUDE (chunk_num), r.chunk_num FROM s JOIN r USING (a);
