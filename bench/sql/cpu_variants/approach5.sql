-- CPU-exact flag array, Approach 5: approx_quantile (t-digest). FAST but APPROXIMATE.
-- Fastest non-GROUP-BY method (0.380 s warm on tpch_qty) but still 4.1x slower than Approach 1, AND the
-- quartiles are approximate -> DISQUALIFIED from the canonical path unless correctness.sql shows the
-- quartiles are bit-exact on the dataset in question. @PATH@/@COL@ substituted by the runner.
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
q  AS (SELECT CAST(approx_quantile(v,0.25) AS BIGINT) q1,
              CAST(approx_quantile(v,0.75) AS BIGINT) q3 FROM s)
, ef AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
