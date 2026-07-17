-- ============================================================================
--  Manual IQR test queries -- run these yourself in the DuckDB CLI.
--
--  Launch:
--    export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
--    cd /home/myaksi/oasis
--    ./extension/build/release/duckdb                 # interactive
--    # or, for the FPGA phase breakdown:
--    OASIS_IQR_TIMING=1 ./extension/build/release/duckdb
--
--  Session setup (run once):
--    .timer on
--    PRAGMA threads=32;      -- or 1/4/16 to sweep the CPU baseline
--
--  FPGA queries (iqr_flags) need: card flashed + 1 GiB huge pages set.
--  Swap the path/column for other datasets:
--    taxi_d1..d4 : /home/myaksi/datasets/taxi_d{N}.parquet   col fare_cents
--    tpch_qty    : /home/myaksi/datasets/tpch_qty.parquet    col v
--    tpch_extprice[_sf10] : .../tpch_extprice[_sf10].parquet col v
--  Or set variables and reuse the query bodies below:
--    SET VARIABLE p = '/home/myaksi/datasets/taxi_d4.parquet';
--    SET VARIABLE c = 'fare_cents';
--    (then use getvariable('p') / getvariable('c') -- see the FPGA example)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. FPGA -- outlier count. The headline FPGA number.
-- ---------------------------------------------------------------------------
SELECT count(*) FILTER (WHERE f)
FROM iqr_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents') t(v,f);

-- variable form (edit the two SET lines, rerun the SELECT):
-- SET VARIABLE p = '/home/myaksi/datasets/taxi_d4.parquet';
-- SET VARIABLE c = 'fare_cents';
-- SELECT count(*) FILTER (WHERE f)
-- FROM iqr_flags(getvariable('p'), getvariable('c')) t(v,f);

-- ---------------------------------------------------------------------------
-- 2. CPU EXACT -- the baseline the FPGA must beat (GROUP BY + window, no binning).
-- ---------------------------------------------------------------------------
WITH s AS (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT count(*) FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi;

-- ---------------------------------------------------------------------------
-- 3. CPU HIST-1024 -- same 1024-bin algorithm as the FPGA, on CPU (isolates
--    algorithm error from hardware; expected ~7x slower than exact).
-- ---------------------------------------------------------------------------
WITH s AS (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
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

-- ---------------------------------------------------------------------------
-- 4. CORRECTNESS: FPGA vs EXACT -- per-row agreement + effective fences.
--    fpga_vs_exact_disagree / n = ppm disagreement.
-- ---------------------------------------------------------------------------
WITH s  AS (SELECT fare_cents::BIGINT v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
fp AS (SELECT v, f FROM iqr_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents') t(v,f)),
feff AS (SELECT count(*) n, count(*) FILTER (WHERE f) n_out,
                min(v) FILTER (WHERE NOT f) lo_eff, max(v) FILTER (WHERE NOT f) hi_eff FROM fp),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t) q1, (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq),
enout AS (SELECT count(*) c FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi),
dis  AS (SELECT count(*) c FROM s,ef,feff WHERE ((s.v<ef.lo OR s.v>ef.hi)) <> ((s.v<feff.lo_eff OR s.v>feff.hi_eff)))
SELECT feff.n, feff.n_out fpga_nout, feff.lo_eff, feff.hi_eff,
       ef.lo e_lo, ef.hi e_hi, enout.c e_nout, dis.c fpga_vs_exact_disagree
FROM feff,ef,enout,dis;

-- ---------------------------------------------------------------------------
-- 5. CPU-only correctness: EXACT vs HIST-1024 (no card needed) -- how much error
--    comes from the 1024-bin approximation alone. See bench/sql/correctness_cpu.sql
--    for the full version (it also reports shift/bin_min and both fence sets).
-- ---------------------------------------------------------------------------
-- (run:  .read bench/sql/correctness_cpu.sql  after sed-substituting, or copy it here)
