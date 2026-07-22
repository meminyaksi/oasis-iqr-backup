-- Head-to-head, all three implementations, materialized so each really produces the full mask.
-- Each runs TWICE: read the SECOND (warm) "Run Time ... real" for every block.
PRAGMA threads=32;
.timer on

-- ==================== tpch_qty : FPGA ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_qty.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_qty.parquet','v');
-- ==================== tpch_qty : C++ CPU ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_qty.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_qty.parquet','v');
-- ==================== tpch_qty : SQL baseline ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_qty.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_qty.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;

-- ==================== tpch_extprice : FPGA ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice.parquet','v');
-- ==================== tpch_extprice : C++ CPU ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice.parquet','v');
-- ==================== tpch_extprice : SQL baseline ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;

-- ==================== taxi_d1 : FPGA ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
-- ==================== taxi_d1 : C++ CPU ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
-- ==================== taxi_d1 : SQL baseline ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d1.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d1.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;

-- ==================== taxi_d2 : FPGA ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
-- ==================== taxi_d2 : C++ CPU ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
-- ==================== taxi_d2 : SQL baseline ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d2.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d2.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;

-- ==================== taxi_d3 : FPGA ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
-- ==================== taxi_d3 : C++ CPU ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
-- ==================== taxi_d3 : SQL baseline ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d3.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d3.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;

-- ==================== taxi_d4 : FPGA ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
-- ==================== taxi_d4 : C++ CPU ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
-- ==================== taxi_d4 : SQL baseline ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;

-- ==================== tpch_extprice_sf10 : FPGA ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
-- ==================== tpch_extprice_sf10 : C++ CPU ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
-- ==================== tpch_extprice_sf10 : SQL baseline ====================
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice_sf10.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice_sf10.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) q;
