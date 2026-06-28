-- IQR end-to-end timing: FPGA vs DuckDB-32core-exact vs DuckDB-32core-histogram
-- each query produces per-row flags; count() forces flag generation. Read the 2nd (warm) time.
SET threads=32;
SELECT 'threads' k, current_setting('threads') v;
.timer on

-- ===== d1 (2.96M rows) =====
-- d1/FPGA (warm x2):
SELECT 'd1/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
SELECT 'd1/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');

-- d1/EXACT (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d1.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd1/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d1.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd1/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;

-- d1/HIST (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d1.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd1/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d1.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd1/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;

-- ===== d2 (5.97M rows) =====
-- d2/FPGA (warm x2):
SELECT 'd2/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
SELECT 'd2/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');

-- d2/EXACT (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d2.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd2/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d2.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd2/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;

-- d2/HIST (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d2.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd2/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d2.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd2/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;

-- ===== d3 (13.1M rows) =====
-- d3/FPGA (warm x2):
SELECT 'd3/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
SELECT 'd3/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');

-- d3/EXACT (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d3.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd3/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d3.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd3/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;

-- d3/HIST (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d3.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd3/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d3.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd3/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;

-- ===== d4 (20.3M rows) =====
-- d4/FPGA (warm x2):
SELECT 'd4/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
SELECT 'd4/FPGA' tag, count(*) FILTER (WHERE is_outlier) n FROM iqr_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');

-- d4/EXACT (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd4/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
 q AS (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3 FROM d)
SELECT 'd4/EXACT' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,q;

-- d4/HIST (warm x2):
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd4/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;
WITH d AS (SELECT fare_cents v FROM read_parquet('/home/myaksi/datasets/taxi_d4.parquet')),
 w AS (SELECT quantile_cont(v,0.01) lo, quantile_cont(v,0.99) hi FROM d),
 p AS (SELECT lo, GREATEST(1.0,(hi-lo)/256.0) binw FROM w),
 b AS (SELECT LEAST(255,GREATEST(0,CAST(floor((v-(SELECT lo FROM p))/(SELECT binw FROM p)) AS BIGINT))) bin FROM d),
 h AS (SELECT bin,count(*) c FROM b GROUP BY bin),
 cc AS (SELECT bin, sum(c) OVER (ORDER BY bin) cum, (SELECT sum(c) FROM h) tot FROM h),
 qq AS (SELECT min(bin) FILTER (WHERE cum>=0.25*tot) b1, min(bin) FILTER (WHERE cum>=0.75*tot) b3 FROM cc),
 fen AS (SELECT (SELECT lo FROM p)+b1*(SELECT binw FROM p) q1, (SELECT lo FROM p)+b3*(SELECT binw FROM p) q3 FROM qq)
SELECT 'd4/HIST' tag, count(*) FILTER (WHERE v<q1-1.5*(q3-q1) OR v>q3+1.5*(q3-q1)) n FROM d,fen;
