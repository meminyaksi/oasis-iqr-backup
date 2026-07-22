-- SUPERSEDED by decoder_probe.sql (2026-07-22). Kept because §9.8 was measured with it.
-- TWO CORRECTIONS, both verified in RTL:
--   1. The percentages below are taken over (handshakes+starved+stalled) and so EXCLUDE
--      in_idle. in_idle is the gap BETWEEN column chunks -- the host having no next chunk
--      ready -- which is precisely the host-feed signal. §9.8's "0 % starved => compute-bound"
--      therefore never inspected the term where a feed shortfall would actually appear.
--   2. The profilers do NOT auto-reset on read. Reading a lane's last register asserts `stop`,
--      returning the profiler to WAIT and HOLDING the counters; they are zeroed by the next
--      valid DATA BEAT (stream_profiler.sv:69-77, column_chunk_decoder_config.sv:83). The
--      read-discard-then-query pattern is still correct -- the read arms the reset, the query
--      performs it -- but a second read with no query in between returns THE SAME values.
--
-- Is the decoder COMPUTE-bound (more lanes help) or STARVED/STALLED (more lanes do nothing)?
-- Run this BEFORE spending ~5 hours on a --decoders 4 bitstream.
--
-- The ColumnChunkDecoder StreamProfilers AUTO-RESET after each full read, so the pattern is:
--   read once to clear -> run the query -> read again = that query's cycles.
-- 250 MHz, so us = cycles / 250.
--
-- HOW TO READ THE SECOND TABLE (per decoder lane):
--   in_handshakes high, in_starved low, out_stalled low  -> COMPUTE-BOUND. More lanes scale ~linearly.
--   in_starved high                                      -> waiting on compressed bytes from the host.
--                                                           Fetch/PCIe-bound: more lanes do NOTHING.
--   out_stalled high                                     -> decoder output back-pressured by the sink.
--                                                           Downstream is the limit: more lanes do NOTHING.
PRAGMA threads=32;

-- clear the counters
SELECT 'baseline (discard)' AS phase, * FROM decoder_profiler();

-- the decode-bound worst case
CREATE OR REPLACE TABLE m AS
SELECT is_outlier FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');

-- this run's decoder cycles
SELECT 'sf10' AS phase,
       decoder,
       in_handshakes, in_starved, in_stalled,
       out_handshakes, out_starved, out_stalled,
       round(100.0*in_handshakes /nullif(in_handshakes +in_starved +in_stalled ,0),1) AS in_busy_pct,
       round(100.0*in_starved    /nullif(in_handshakes +in_starved +in_stalled ,0),1) AS in_starved_pct,
       round(100.0*out_stalled   /nullif(out_handshakes+out_starved+out_stalled,0),1) AS out_stalled_pct,
       round((in_handshakes+in_starved+in_stalled)/250000.0, 2)                       AS active_ms
FROM decoder_profiler();
