-- QUARTILE / FENCE DIAGNOSTIC  (explains any cpp_vs_oracle disagreement from correctness_3way_builtin.sql)
--
-- No FPGA and no per-row join needed, so this runs at full thread count and is fast even on sf10. It puts
-- the two CPU quartile methods side by side and then asks the two questions that a flag disagreement can
-- come from:
--
--   (1) quartiles_match  -- does our GROUP BY + cumulative-count quartile pick the SAME q1/q3 as DuckDB's
--                           built-in quantile_disc?  If false, the difference is a nearest-rank convention
--                           at a tie and is localized to a couple of boundary values.
--   (2) n_floor vs n_true -- does it matter that the operator uses floor(1.5*IQR) = d + d>>1 (integer,
--                           divider-free) instead of the textbook 1.5*IQR as a real number? n_floor is the
--                           outlier count under the operator's fence; n_true under the exact 1.5x fence.
--                           Equal => the 0.5 flooring never crosses a value on this dataset.
--
-- quantile_disc is the correct oracle for an integer nearest-rank operator: it returns an actual data
-- value (discrete). quantile_cont interpolates and would differ BY DESIGN, so it is not the oracle.
--
-- @PATH@ / @COL@ substituted by bench/correctness_3way.sh.
WITH
s    AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
-- (A) TRUSTED: DuckDB built-in discrete quantile
b    AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
-- (B) OURS: GROUP BY histogram + cumulative-count quartile (what iqr_cpu_flags_groupby transliterates)
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
g    AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3)
SELECT
  b.q1 AS builtin_q1, g.q1 AS ours_q1,
  b.q3 AS builtin_q3, g.q3 AS ours_q3,
  (b.q1=g.q1 AND b.q3=g.q3)                                             AS quartiles_match,
  b.q1-((b.q3-b.q1)+((b.q3-b.q1)>>1))                                   AS lo_floor,
  b.q3+((b.q3-b.q1)+((b.q3-b.q1)>>1))                                   AS hi_floor,
  (SELECT count(*) FROM s WHERE s.v < b.q1-((b.q3-b.q1)+((b.q3-b.q1)>>1))
                             OR s.v > b.q3+((b.q3-b.q1)+((b.q3-b.q1)>>1)))  AS n_floor,
  (SELECT count(*) FROM s WHERE s.v < b.q1-1.5*(b.q3-b.q1)
                             OR s.v > b.q3+1.5*(b.q3-b.q1))                 AS n_true
FROM b, g;
