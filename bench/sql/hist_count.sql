-- CPU-HIST-1024 timed query: end result = number of IQR outliers, using the operator's 1024-bin
-- auto-window algorithm entirely on CPU. @PATH@/@COL@ substituted by runner.
WITH s AS (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
p   AS (SELECT CAST(quantile_disc(v,0.01) AS BIGINT) lo1, CAST(quantile_disc(v,0.99) AS BIGINT) hi99 FROM s),
w   AS (SELECT lo1,hi99, CASE WHEN (hi99-lo1)<=0 THEN 0
                 ELSE CAST(ceil(log2(GREATEST(1.0,((hi99-lo1)+1023)//1024))) AS BIGINT) END shift FROM p),
w2  AS (SELECT lo1, shift,
          CAST(CASE WHEN lo1>=0 THEN (lo1/(1::BIGINT<<shift))*(1::BIGINT<<shift)
               ELSE -(((-lo1)+(1::BIGINT<<shift)-1)/(1::BIGINT<<shift))*(1::BIGINT<<shift) END AS BIGINT) bin_min FROM w),
hb  AS (SELECT LEAST(1023,GREATEST(0,(v-bin_min)>>shift)) bin, count(*) c FROM s,w2 GROUP BY 1),
htot AS (SELECT sum(c) t FROM hb),
hcum AS (SELECT bin, sum(c) OVER (ORDER BY bin) cc FROM hb),
hq  AS (SELECT (SELECT min(bin) FROM hcum,htot WHERE cc*4>=t)   b1,
               (SELECT min(bin) FROM hcum,htot WHERE cc*4>=3*t) b3),
hv  AS (SELECT CAST(bin_min+(b1<<shift) AS BIGINT) q1, CAST(bin_min+(b3<<shift) AS BIGINT) q3 FROM hq,w2),
hf  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM hv)
SELECT count(*) FROM s,hf WHERE s.v<hf.lo OR s.v>hf.hi;
