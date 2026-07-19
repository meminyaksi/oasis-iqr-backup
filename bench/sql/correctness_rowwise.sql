-- Direct per-ROW correctness: compares the FPGA's ACTUAL per-row outlier flag against the CPU-EXACT
-- IQR decision for EVERY row -- not just the outlier count (which can hide compensating errors).
--
-- Why this is a true line-by-line comparison even though we don't zip two arrays by position:
-- the outlier flag is a deterministic function of the value (flag = v<lo OR v>hi, one global fence
-- pair), so every row with a given value MUST get the same flag on each side. Carrying the value with
-- each FPGA row and re-deciding it under the CPU-exact fences therefore checks every row exactly,
-- and is robust to DuckDB's parallel row ordering (a naive positional zip of two flag arrays is not).
--
-- @PATH@/@COL@ substituted by the runner. Returns ONE row:
--   total_rows      -- N
--   fpga_outliers   -- rows the FPGA flagged
--   cpu_outliers    -- rows CPU-exact flags
--   agree_rows      -- rows where FPGA flag == CPU-exact flag  (want: == total_rows)
--   disagree_rows   -- rows where they differ                  (want: 0; small = binning boundary)
--   disagree_ppm    -- disagree_rows / total_rows * 1e6
WITH
s    AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq),
fp   AS (SELECT v, f AS fpga FROM iqr_flags('@PATH@','@COL@') t(v,f))
SELECT
  count(*)                                                                       AS total_rows,
  count(*) FILTER (WHERE fp.fpga)                                                AS fpga_outliers,
  (SELECT count(*) FROM s, ef WHERE s.v < ef.lo OR s.v > ef.hi)                  AS cpu_outliers,
  count(*) FILTER (WHERE fp.fpga = (fp.v < ef.lo OR fp.v > ef.hi))               AS agree_rows,
  count(*) FILTER (WHERE fp.fpga <> (fp.v < ef.lo OR fp.v > ef.hi))              AS disagree_rows,
  round(1e6 * count(*) FILTER (WHERE fp.fpga <> (fp.v < ef.lo OR fp.v > ef.hi))
        / count(*), 3)                                                           AS disagree_ppm
FROM fp, ef;
