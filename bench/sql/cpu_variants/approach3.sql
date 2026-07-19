-- CPU-exact flag array, Approach 3: no GROUP BY, ordered-set percentile_disc WITHIN GROUP.
-- SQL-standard ordered-set aggregate; same engine path as Approach 2 (0.733 s warm, within noise of 0.603).
-- No planner advantage from the ordered-set syntax. Exact. @PATH@/@COL@ substituted by the runner.
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
q  AS (SELECT percentile_disc(0.25) WITHIN GROUP (ORDER BY v) q1,
              percentile_disc(0.75) WITHIN GROUP (ORDER BY v) q3 FROM s),
ef AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
