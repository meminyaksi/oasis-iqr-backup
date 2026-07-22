-- Three-way correctness: FPGA vs the C++ CPU operator vs the original SQL baseline.
-- threads=1 so all three emit in input order and POSITIONAL JOIN compares row i to row i.
--
-- READ IT LIKE THIS:
--   * n_fpga / n_cpp / n_sql are the OUTLIER COUNTS each side found. They must agree with each other.
--     An all-false implementation shows n_cpp = 0 while the others are non-zero -- do not read only
--     the mismatch columns, because the tpch datasets have ZERO outliers by nature (uniform data)
--     and would agree with a broken implementation. taxi is the dataset with real outliers.
--   * fpga_vs_cpp and cpp_vs_sql are exact per-row disagreement counts. Both must be 0.
-- taxi first (the datasets that can actually fail); sf10 last and slow single-threaded (~minutes).
PRAGMA threads=1;
.timer off

SELECT 'taxi_d1' AS dataset, count(*) AS rows,
       count(*) FILTER (WHERE g.is_outlier)                          AS n_fpga,
       count(*) FILTER (WHERE c.is_outlier)                          AS n_cpp,
       count(*) FILTER (WHERE s.is_outlier)                          AS n_sql,
       count(*) FILTER (WHERE g.is_outlier IS DISTINCT FROM c.is_outlier) AS fpga_vs_cpp,
       count(*) FILTER (WHERE c.is_outlier IS DISTINCT FROM s.is_outlier) AS cpp_vs_sql
FROM iqr_flags_only('/home/myaksi/datasets/taxi_d1.parquet','fare_cents') g
POSITIONAL JOIN iqr_cpu_flags('/home/myaksi/datasets/taxi_d1.parquet','fare_cents') c
POSITIONAL JOIN (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d1.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) s;

SELECT 'taxi_d2' AS dataset, count(*) AS rows,
       count(*) FILTER (WHERE g.is_outlier)                          AS n_fpga,
       count(*) FILTER (WHERE c.is_outlier)                          AS n_cpp,
       count(*) FILTER (WHERE s.is_outlier)                          AS n_sql,
       count(*) FILTER (WHERE g.is_outlier IS DISTINCT FROM c.is_outlier) AS fpga_vs_cpp,
       count(*) FILTER (WHERE c.is_outlier IS DISTINCT FROM s.is_outlier) AS cpp_vs_sql
FROM iqr_flags_only('/home/myaksi/datasets/taxi_d2.parquet','fare_cents') g
POSITIONAL JOIN iqr_cpu_flags('/home/myaksi/datasets/taxi_d2.parquet','fare_cents') c
POSITIONAL JOIN (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d2.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) s;

SELECT 'taxi_d3' AS dataset, count(*) AS rows,
       count(*) FILTER (WHERE g.is_outlier)                          AS n_fpga,
       count(*) FILTER (WHERE c.is_outlier)                          AS n_cpp,
       count(*) FILTER (WHERE s.is_outlier)                          AS n_sql,
       count(*) FILTER (WHERE g.is_outlier IS DISTINCT FROM c.is_outlier) AS fpga_vs_cpp,
       count(*) FILTER (WHERE c.is_outlier IS DISTINCT FROM s.is_outlier) AS cpp_vs_sql
FROM iqr_flags_only('/home/myaksi/datasets/taxi_d3.parquet','fare_cents') g
POSITIONAL JOIN iqr_cpu_flags('/home/myaksi/datasets/taxi_d3.parquet','fare_cents') c
POSITIONAL JOIN (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d3.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) s;

SELECT 'taxi_d4' AS dataset, count(*) AS rows,
       count(*) FILTER (WHERE g.is_outlier)                          AS n_fpga,
       count(*) FILTER (WHERE c.is_outlier)                          AS n_cpp,
       count(*) FILTER (WHERE s.is_outlier)                          AS n_sql,
       count(*) FILTER (WHERE g.is_outlier IS DISTINCT FROM c.is_outlier) AS fpga_vs_cpp,
       count(*) FILTER (WHERE c.is_outlier IS DISTINCT FROM s.is_outlier) AS cpp_vs_sql
FROM iqr_flags_only('/home/myaksi/datasets/taxi_d4.parquet','fare_cents') g
POSITIONAL JOIN iqr_cpu_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents') c
POSITIONAL JOIN (WITH s AS MATERIALIZED (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) s;

SELECT 'tpch_qty' AS dataset, count(*) AS rows,
       count(*) FILTER (WHERE g.is_outlier)                          AS n_fpga,
       count(*) FILTER (WHERE c.is_outlier)                          AS n_cpp,
       count(*) FILTER (WHERE s.is_outlier)                          AS n_sql,
       count(*) FILTER (WHERE g.is_outlier IS DISTINCT FROM c.is_outlier) AS fpga_vs_cpp,
       count(*) FILTER (WHERE c.is_outlier IS DISTINCT FROM s.is_outlier) AS cpp_vs_sql
FROM iqr_flags_only('/home/myaksi/datasets/tpch_qty.parquet','v') g
POSITIONAL JOIN iqr_cpu_flags('/home/myaksi/datasets/tpch_qty.parquet','v') c
POSITIONAL JOIN (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_qty.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) s;

SELECT 'tpch_extprice' AS dataset, count(*) AS rows,
       count(*) FILTER (WHERE g.is_outlier)                          AS n_fpga,
       count(*) FILTER (WHERE c.is_outlier)                          AS n_cpp,
       count(*) FILTER (WHERE s.is_outlier)                          AS n_sql,
       count(*) FILTER (WHERE g.is_outlier IS DISTINCT FROM c.is_outlier) AS fpga_vs_cpp,
       count(*) FILTER (WHERE c.is_outlier IS DISTINCT FROM s.is_outlier) AS cpp_vs_sql
FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice.parquet','v') g
POSITIONAL JOIN iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice.parquet','v') c
POSITIONAL JOIN (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) s;

SELECT 'tpch_extprice_sf10' AS dataset, count(*) AS rows,
       count(*) FILTER (WHERE g.is_outlier)                          AS n_fpga,
       count(*) FILTER (WHERE c.is_outlier)                          AS n_cpp,
       count(*) FILTER (WHERE s.is_outlier)                          AS n_sql,
       count(*) FILTER (WHERE g.is_outlier IS DISTINCT FROM c.is_outlier) AS fpga_vs_cpp,
       count(*) FILTER (WHERE c.is_outlier IS DISTINCT FROM s.is_outlier) AS cpp_vs_sql
FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v') g
POSITIONAL JOIN iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v') c
POSITIONAL JOIN (WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('/home/myaksi/datasets/tpch_extprice_sf10.parquet')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef) s;
