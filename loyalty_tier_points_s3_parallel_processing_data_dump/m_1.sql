EXPLAIN USING TEXT
WITH ranked AS (SELECT 'p' AS pfid, 'src' AS source_loyalty_id, 1 AS rn, 2 AS grp_size)
SELECT pfid AS private_fan_id, source_loyalty_id::VARCHAR AS source_loyalty_id,
  CASE WHEN rn = 1 THEN source_loyalty_id::VARCHAR
             ELSE LEFT(UUID_STRING('e5567350-8395-4672-b41f-45f9bcbe4047', pfid || ':' || source_loyalty_id::VARCHAR), 14) || '1' || SUBSTR(UUID_STRING('e5567350-8395-4672-b41f-45f9bcbe4047', pfid || ':' || source_loyalty_id::VARCHAR), 16) END AS effective_loyalty_id,
  (rn = 1) AS is_primary, (grp_size > 1) AS dup_group FROM ranked;
