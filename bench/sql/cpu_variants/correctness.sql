-- Cross-check that all 5 quartile methods agree. Computes Q1/Q3 five ways in one query.
-- gb/qd/pd/rn must be equal (exact methods); approx may differ (t-digest). @PATH@/@COL@ substituted.
WITH s AS MATERIALIZED (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
a AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t) q1,
             (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
b AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
c AS (SELECT percentile_disc(0.25) WITHIN GROUP (ORDER BY v) q1,
             percentile_disc(0.75) WITHIN GROUP (ORDER BY v) q3 FROM s),
r AS (SELECT v, row_number() OVER (ORDER BY v) rn, count(*) OVER () n FROM s),
d AS (SELECT max(v) FILTER (WHERE rn=CAST(ceil(0.25*n) AS BIGINT)) q1,
             max(v) FILTER (WHERE rn=CAST(ceil(0.75*n) AS BIGINT)) q3 FROM r),
e AS (SELECT CAST(approx_quantile(v,0.25) AS BIGINT) q1,
             CAST(approx_quantile(v,0.75) AS BIGINT) q3 FROM s)
SELECT a.q1 gb, b.q1 qd, c.q1 pd, d.q1 rn, e.q1 approx,
       a.q3 gb3, b.q3 qd3, c.q3 pd3, d.q3 rn3, e.q3 approx3
FROM a,b,c,d,e;
