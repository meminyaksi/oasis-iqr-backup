PRAGMA threads=32;
.timer on
CREATE OR REPLACE TABLE mask AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
CREATE OR REPLACE TABLE mask AS SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
