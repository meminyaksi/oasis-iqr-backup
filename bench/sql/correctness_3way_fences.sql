-- STAGE 1 of the flags comparison: PURE SQL, NO FPGA operator. Computes both fences and the CPU/oracle
-- counts, and emits them as one CSV row for the runner to inject into the FPGA aggregate (stage 2).
--
-- Emitted columns, in order (–csv –noheader):
--   gf_lo, gf_hi   -- C++-exact fence (GROUP BY + cumulative count, what iqr_cpu_flags_groupby computes)
--   bf_lo, bf_hi   -- oracle fence (DuckDB built-in quantile_disc)
--   n_cpp          -- outliers under the C++-exact fence
--   n_oracle       -- outliers under the oracle fence
--   cpp_vs_oracle  -- rows where the two fences disagree per row  (MUST be 0 — proven by the quartiles run)
--
-- @PATH@ / @COL@ substituted by bench/correctness_3way.sh.
WITH
s    AS (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
b    AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
bf   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM b),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
g    AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
gf   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM g)
SELECT
  gf.lo, gf.hi, bf.lo, bf.hi,
  (SELECT count(*) FROM s, gf WHERE s.v < gf.lo OR s.v > gf.hi)                  AS n_cpp,
  (SELECT count(*) FROM s, bf WHERE s.v < bf.lo OR s.v > bf.hi)                  AS n_oracle,
  (SELECT count(*) FROM s, gf, bf
     WHERE (s.v < gf.lo OR s.v > gf.hi) <> (s.v < bf.lo OR s.v > bf.hi))         AS cpp_vs_oracle
FROM gf, bf;
