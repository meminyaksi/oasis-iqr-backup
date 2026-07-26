-- STAGE 2 of the flags comparison: ONE aggregate over the FPGA function, nothing else.
--
-- This is the ONLY shape of FPGA query proven safe on this card: a single aggregate over iqr_flags, no
-- materialization (no CREATE TABLE), no join, no other pipeline breaker, no multi-statement script. The
-- fences are CONSTANTS, precomputed by stage 1 (correctness_3way_fences.sql) and injected by the runner,
-- so there is no CPU operator here to interleave with the FPGA pipeline and starve its no-timeout receiver.
--
-- iqr_flags echoes each row's value next to its FPGA flag, so `f <> (v < lo OR v > hi)` is a true per-row
-- check of the FPGA's ACTUAL flag against the exact / oracle decision, robust to row order.
--
-- Emitted (–csv –noheader): total_rows, n_fpga, fpga_vs_cpp, fpga_vs_oracle
--
-- @PATH@/@COL@ and the four fence literals @GLO@ @GHI@ @BLO@ @BHI@ substituted by bench/correctness_3way.sh.
SELECT
  count(*)                                                        AS total_rows,
  count(*) FILTER (WHERE f)                                       AS n_fpga,
  count(*) FILTER (WHERE f <> (v < @GLO@ OR v > @GHI@))           AS fpga_vs_cpp,
  count(*) FILTER (WHERE f <> (v < @BLO@ OR v > @BHI@))           AS fpga_vs_oracle
FROM iqr_flags('@PATH@','@COL@') t(v,f);
