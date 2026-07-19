-- CPU-exact flag array, Approach 2: no GROUP BY, single-pass quantile_disc list.
-- Computes both quartiles in one sorted selection (list form). Processes all N (no dedup collapse) ->
-- 6.6x slower than Approach 1 on low card (tpch_qty: 0.603 s warm, 2026-07-19). Exact.
-- @PATH@/@COL@ substituted by the runner.
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
q  AS (SELECT quantile_disc(v, [0.25, 0.75]) qq FROM s),
ef AS (SELECT qq[1] q1, qq[2] q3,
              qq[1]-((qq[2]-qq[1])+((qq[2]-qq[1])>>1)) lo,
              qq[2]+((qq[2]-qq[1])+((qq[2]-qq[1])>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
