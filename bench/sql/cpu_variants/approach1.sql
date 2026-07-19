-- CPU-exact flag array, Approach 1: GROUP BY histogram + cumulative window.
-- Collapses duplicates (N -> distinct) before the quartile math; divider-free quartiles (cc*4>=t),
-- integer 1.5*IQR fences via shifts. WINNER on low cardinality (tpch_qty: 0.092 s warm, 2026-07-19).
-- @PATH@/@COL@ substituted by the runner. Produces the identical mask to approaches 2-5.
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
