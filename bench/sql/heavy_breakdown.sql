-- Separates OPERATOR time (the 'heavy' line, printed to stderr by OASIS_IQR_TIMING=1) from the
-- shared DuckDB emit+materialize tax that both implementations pay identically.
-- Run with:  OASIS_IQR_TIMING=1 ./extension/build/release/duckdb < bench/sql/heavy_breakdown.sql
-- For each dataset compare the FPGA's '[iqr] heavy' against the CPU's '[iqr-cpu] heavy', and compare
-- BOTH against the '.timer' real time -- the difference is the shared tax.
PRAGMA threads=32;
.timer on

-- ################ taxi_d1 : FPGA ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
-- ################ taxi_d1 : C++ CPU ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');

-- ################ tpch_qty : FPGA ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_qty.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_qty.parquet','v');
-- ################ tpch_qty : C++ CPU ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_qty.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_qty.parquet','v');

-- ################ taxi_d2 : FPGA ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
-- ################ taxi_d2 : C++ CPU ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d2.parquet','fare_cents');

-- ################ tpch_extprice : FPGA ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice.parquet','v');
-- ################ tpch_extprice : C++ CPU ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice.parquet','v');

-- ################ taxi_d3 : FPGA ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
-- ################ taxi_d3 : C++ CPU ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d3.parquet','fare_cents');

-- ################ taxi_d4 : FPGA ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
-- ################ taxi_d4 : C++ CPU ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');

-- ################ tpch_extprice_sf10 : FPGA ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
-- ################ tpch_extprice_sf10 : C++ CPU ################
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM iqr_cpu_flags('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
