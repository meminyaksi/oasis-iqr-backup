PRAGMA threads=32;
.timer on
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice_sf10.parquet')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice_sf10.parquet')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
