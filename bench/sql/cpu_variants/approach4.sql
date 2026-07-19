-- CPU-exact flag array, Approach 4: full sort, row_number() nearest-rank (NO built-in quantile, NO dedup).
-- The pure "naive" reference: sorts all N and picks positions ceil(0.25*n)/ceil(0.75*n). Exact, but the
-- cautionary data point: 36.8x slower / 84x more CPU on low card (tpch_qty: 3.381 s, 44.8 CPU-s, 2026-07-19).
-- @PATH@/@COL@ substituted by the runner.
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
r  AS (SELECT v, row_number() OVER (ORDER BY v) rn, count(*) OVER () n FROM s),
q  AS (SELECT max(v) FILTER (WHERE rn = CAST(ceil(0.25*n) AS BIGINT)) q1,
              max(v) FILTER (WHERE rn = CAST(ceil(0.75*n) AS BIGINT)) q3 FROM r),
ef AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
