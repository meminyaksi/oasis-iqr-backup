-- CPU-EXACT timed query: end result = number of IQR outliers. @PATH@/@COL@ substituted by runner.
WITH s AS (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT count(*) FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi;
