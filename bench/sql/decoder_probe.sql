-- ===========================================================================
-- WHERE DOES THE DECODER SPEND ITS TIME?  (build-14, 4 lanes)
--
-- Profiler placement (verified in RTL, 2026-07-22):
--   parcore/hardware/src/hdl/column_chunk_decoder.sv:404-424 taps the
--   ColumnChunkDecoder's OWN PORTS -- in.{valid,ready,last} (compressed bytes
--   from the host) and out.{valid,ready,last} (decoded values to the IQR
--   sink). It is a MODULE-BOUNDARY probe: it proves the module is internally
--   busy but says NOTHING about which internal stage (snappy vs
--   hybrid_page_decoder vs run_decoder) is the limiter.
--
-- Reset semantics (stream_profiler.sv:69-77, column_chunk_decoder_config.sv:83):
--   Reading a lane's LAST profile register asserts `stop` -> the profiler
--   returns to WAIT and HOLDS its counters. They are zeroed by the NEXT VALID
--   DATA BEAT, not by the read. So:
--     * read(discard) -> query -> read   is the correct pattern (the discard
--       read arms the reset; the query's first beat performs it);
--     * re-reading with NO query in between returns THE SAME VALUES, not
--       zeros -- which is why the balance query below can reuse a snapshot;
--     * counters accumulate across ALL column chunks in a query, because
--       IDLE->STREAM does not re-zero.
--
-- HOW TO READ THE INPUT SIDE:
--   in_stalled  decoder back-pressures the host = COMPUTE-BOUND (lanes scale)
--   in_starved  bubbles WITHIN a column chunk   = host feed too slow mid-chunk
--   in_idle     gaps BETWEEN column chunks      = host had no next chunk ready
--               -> THE WINDOW IS TOO SMALL. This is the term §9.8 never looked
--               at, and the one most likely to bite at 4 lanes.
--   out_stalled decoder output back-pressured by the IQR sink = downstream limit
--
-- NOTE: trailing idle after a lane's FINAL chunk is deliberately not counted,
-- so LOAD IMBALANCE shows up as a lower total cycle count on that lane -- never
-- as idle. That is what the balance query measures.
-- 250 MHz -> ms = cycles / 250000.
-- ===========================================================================
PRAGMA threads=32;

-- ---- arm the reset --------------------------------------------------------
SELECT 'discard' AS phase, count(*) AS lanes FROM decoder_profiler();

-- ---- A: decode-bound case (sf10, PLAIN, ~480 MB of snappy) ----------------
CREATE OR REPLACE TABLE a AS
SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');

-- snapshot once, query it twice (avoids relying on hold-after-read)
CREATE OR REPLACE TABLE pa AS SELECT * FROM decoder_profiler();

SELECT 'sf10' AS phase, decoder AS lane,
       round((in_handshakes+in_starved+in_stalled+in_idle)/250000.0,2) AS lane_ms,
       round(100.0*in_handshakes/nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS busy_pct,
       round(100.0*in_starved   /nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS starv_pct,
       round(100.0*in_stalled   /nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS stall_pct,
       round(100.0*in_idle      /nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS idle_pct,
       round(100.0*out_stalled  /nullif(out_handshakes+out_starved+out_stalled,0),1)      AS out_stall_pct
FROM pa ORDER BY lane;

-- load balance: lanes that ran dry finish with FEWER total cycles
SELECT 'sf10 balance' AS phase,
       round(min(in_handshakes+in_starved+in_stalled+in_idle)/250000.0,2) AS min_lane_ms,
       round(max(in_handshakes+in_starved+in_stalled+in_idle)/250000.0,2) AS max_lane_ms,
       round(max(in_handshakes+in_starved+in_stalled+in_idle)*1.0
             /nullif(min(in_handshakes+in_starved+in_stalled+in_idle),0),2)  AS imbalance_x,
       round(sum(in_handshakes)/250000.0,2) AS total_busy_ms
FROM pa;

-- ---- B: dictionary case (taxi_d4, PLAIN_DICTIONARY, ~28 MB snappy) --------
CREATE OR REPLACE TABLE b AS
SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/taxi_d4.parquet','fare_cents');

CREATE OR REPLACE TABLE pb AS SELECT * FROM decoder_profiler();

SELECT 'taxi_d4' AS phase, decoder AS lane,
       round((in_handshakes+in_starved+in_stalled+in_idle)/250000.0,2) AS lane_ms,
       round(100.0*in_handshakes/nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS busy_pct,
       round(100.0*in_starved   /nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS starv_pct,
       round(100.0*in_stalled   /nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS stall_pct,
       round(100.0*in_idle      /nullif(in_handshakes+in_starved+in_stalled+in_idle,0),1) AS idle_pct,
       round(100.0*out_stalled  /nullif(out_handshakes+out_starved+out_stalled,0),1)      AS out_stall_pct
FROM pb ORDER BY lane;

SELECT 'taxi_d4 balance' AS phase,
       round(min(in_handshakes+in_starved+in_stalled+in_idle)/250000.0,2) AS min_lane_ms,
       round(max(in_handshakes+in_starved+in_stalled+in_idle)/250000.0,2) AS max_lane_ms,
       round(max(in_handshakes+in_starved+in_stalled+in_idle)*1.0
             /nullif(min(in_handshakes+in_starved+in_stalled+in_idle),0),2)  AS imbalance_x,
       round(sum(in_handshakes)/250000.0,2) AS total_busy_ms
FROM pb;
