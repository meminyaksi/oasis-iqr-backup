-- Validates our OPTIMIZED CPU-exact code (GROUP BY + CDF quartiles, used as the benchmark baseline)
-- against DuckDB's BUILT-IN quantile function -- the canonical/"traditional" way to compute quartiles.
-- Confirms the GROUP BY optimization did not change the answer. Execution time is irrelevant here.
--
-- quantile_disc is the right reference: it is the *discrete* quantile (returns an actual data value,
-- nearest-rank), matching our integer nearest-rank quartile. quantile_cont interpolates and would
-- differ BY DESIGN (fractional quartiles), so it is not the correctness oracle for an integer operator.
--
-- @PATH@/@COL@ substituted by the runner. Returns ONE row: the two quartile pairs, the two fence
-- pairs, whether they match, and the outlier count under each. quartiles_match & fences_match should
-- be true and the two counts equal; any gap is the quartile-rank convention, localized here.
WITH
s    AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
-- (A) TRADITIONAL: DuckDB built-in discrete quantile
trad AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
tf   AS (SELECT q1, q3, q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM trad),
-- (B) OUR OPTIMIZED: GROUP BY histogram + cumulative-count quartiles
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
oq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
of   AS (SELECT q1, q3, q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM oq)
SELECT
  tf.q1 AS trad_q1, of.q1 AS opt_q1,
  tf.q3 AS trad_q3, of.q3 AS opt_q3,
  (tf.q1=of.q1 AND tf.q3=of.q3)                                AS quartiles_match,
  tf.lo AS trad_lo, of.lo AS opt_lo, tf.hi AS trad_hi, of.hi AS opt_hi,
  (tf.lo=of.lo AND tf.hi=of.hi)                                AS fences_match,
  (SELECT count(*) FROM s WHERE s.v<tf.lo OR s.v>tf.hi)        AS trad_outliers,
  (SELECT count(*) FROM s WHERE s.v<of.lo OR s.v>of.hi)        AS opt_outliers
FROM tf, of;
