-- Where the FPGA disagrees with CPU-EXACT: the specific distinct values whose flag differs, with how
-- many rows each accounts for. These are always the values in the band between the FPGA's binned
-- fences and the exact fences -- i.e. the 1024-bin quantization boundary. Empty result = bit-exact.
-- @PATH@/@COL@ substituted by the runner. Top 20 by row count.
WITH
s    AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq),
fpv  AS (SELECT v, bool_or(f) AS fpga_flag, count(*) AS rows
         FROM iqr_flags('@PATH@','@COL@') t(v,f) GROUP BY v)
SELECT fpv.v                                  AS value,
       fpv.rows                               AS rows,
       fpv.fpga_flag                          AS fpga_flag,
       (fpv.v < ef.lo OR fpv.v > ef.hi)       AS exact_flag,
       ef.lo                                  AS exact_lo,
       ef.hi                                  AS exact_hi
FROM fpv, ef
WHERE fpv.fpga_flag <> (fpv.v < ef.lo OR fpv.v > ef.hi)
ORDER BY fpv.rows DESC
LIMIT 20;
