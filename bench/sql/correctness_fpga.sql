-- FPGA correctness for one column: runs iqr_flags on silicon, recovers the effective fences from
-- the per-row flags (min/max value NOT flagged -- valid because the IQR decision is a contiguous
-- threshold), and compares the FPGA decision to CPU-EXACT. @PATH@/@COL@ substituted by runner.
-- Returns ONE row: n, fpga outliers, fpga effective fences, exact fences+outliers, disagreement.
WITH s  AS (SELECT @COL@::BIGINT v FROM read_parquet('@PATH@')),
fp AS (SELECT v, f FROM iqr_flags('@PATH@','@COL@') t(v,f)),
feff AS (SELECT count(*) n,
                count(*) FILTER (WHERE f) n_out,
                min(v)   FILTER (WHERE NOT f) lo_eff,
                max(v)   FILTER (WHERE NOT f) hi_eff FROM fp),
-- CPU-EXACT fences (same definition as correctness_cpu.sql)
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq),
enout AS (SELECT count(*) c FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi),
dis  AS (SELECT count(*) c FROM s,ef,feff
         WHERE ((s.v<ef.lo OR s.v>ef.hi)) <> ((s.v<feff.lo_eff OR s.v>feff.hi_eff)))
SELECT feff.n, feff.n_out fpga_nout, feff.lo_eff, feff.hi_eff,
       ef.lo e_lo, ef.hi e_hi, enout.c e_nout,
       dis.c fpga_vs_exact_disagree
FROM feff,ef,enout,dis;
