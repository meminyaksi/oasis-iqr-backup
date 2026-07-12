-- CPU-side correctness metrics for one column: EXACT (no binning) vs HIST-1024 (mirrors the
-- FPGA operator's auto-window). Placeholders @PATH@ and @COL@ are substituted by the runner.
-- Returns ONE row: n, exact fences+count, hist fences+count, shift/bin_min, hist-vs-exact disagreement.
WITH s AS (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
-- ---- EXACT: integer nearest-rank quartiles on the full distribution ----
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1,q3,(q3-q1) iqr, q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq),
-- ---- HIST-1024: replicate derive_window (1st/99th pct, width=ceil(range/1024) rounded up to 2^k) ----
p   AS (SELECT CAST(quantile_disc(v,0.01) AS BIGINT) lo1, CAST(quantile_disc(v,0.99) AS BIGINT) hi99 FROM s),
w   AS (SELECT lo1,hi99, CASE WHEN (hi99-lo1)<=0 THEN 0
                 ELSE CAST(ceil(log2(GREATEST(1.0,((hi99-lo1)+1023)//1024))) AS BIGINT) END shift FROM p),
w2  AS (SELECT lo1, shift,
          CAST(CASE WHEN lo1>=0 THEN (lo1/(1::BIGINT<<shift))*(1::BIGINT<<shift)
               ELSE -(((-lo1)+(1::BIGINT<<shift)-1)/(1::BIGINT<<shift))*(1::BIGINT<<shift) END AS BIGINT) bin_min
        FROM w),
hb  AS (SELECT LEAST(1023,GREATEST(0,(v-bin_min)>>shift)) bin, count(*) c FROM s,w2 GROUP BY 1),
htot AS (SELECT sum(c) t FROM hb),
hcum AS (SELECT bin, sum(c) OVER (ORDER BY bin) cc FROM hb),
hq  AS (SELECT (SELECT min(bin) FROM hcum,htot WHERE cc*4>=t)   b1,
               (SELECT min(bin) FROM hcum,htot WHERE cc*4>=3*t) b3),
hv  AS (SELECT CAST(bin_min+(b1<<shift) AS BIGINT) q1, CAST(bin_min+(b3<<shift) AS BIGINT) q3 FROM hq,w2),
hf  AS (SELECT q1,q3,(q3-q1) iqr, q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM hv),
-- ---- counts + disagreement (cross joins keep the fences as single-row scalars) ----
enout AS (SELECT count(*) c FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi),
hnout AS (SELECT count(*) c FROM s,hf WHERE s.v<hf.lo OR s.v>hf.hi),
dis   AS (SELECT count(*) c FROM s,ef,hf WHERE ((s.v<ef.lo OR s.v>ef.hi))<>((s.v<hf.lo OR s.v>hf.hi)))
SELECT (SELECT count(*) FROM s) n,
       ef.q1 e_q1, ef.q3 e_q3, ef.iqr e_iqr, ef.lo e_lo, ef.hi e_hi, enout.c e_nout,
       hf.q1 h_q1, hf.q3 h_q3, hf.iqr h_iqr, hf.lo h_lo, hf.hi h_hi, hnout.c h_nout,
       (SELECT shift FROM w2) shift, (SELECT bin_min FROM w2) bin_min,
       dis.c h_vs_exact_disagree
FROM ef,hf,enout,hnout,dis;
