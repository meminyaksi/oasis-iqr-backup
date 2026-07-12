`timescale 1ns / 1ps

import oasis::*;
import parcore::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb cq_rd.tie_off_s();

`ifdef EN_RDMA
always_comb rq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

for (genvar I = 0; I < N_RDMA_AXI; I++) begin
    always_comb axis_rrsp_send[I].tie_off_m();
    always_comb axis_rrsp_recv[I].tie_off_s();
    always_comb axis_rreq_send[I].tie_off_m();
end

`ASSERT_ELAB(N_STRM_AXI == N_RDMA_AXI)
`endif

localparam NUM_STREAMS        = N_STRM_AXI;
localparam DATABEAT_SIZE      = AXI_DATA_BITS / 8;
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3 (ID, num_streams, max_enqueued).
localparam MEM_CONFIG_NUM_REGS = (NUM_STREAMS + 1 > 3) ? NUM_STREAMS + 1 : 3;

// In local mode the last stream is reserved for the IQR_detection operator (a 4th config block),
// mirroring how RDMA reserves a bypass stream. RDMA/production builds are unchanged.
`ifdef EN_RDMA
localparam NUM_CONFIGS   = 3;
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_CONFIGS   = 4;                 // + IQR config block
localparam NUM_DECODERS  = NUM_STREAMS - 1;   // reserve the last lane for IQR
`endif

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                       write_configs[NUM_CONFIGS](.*);
read_config_i                        read_configs [NUM_CONFIGS](.*);
mem_config_i                         mem_conf[NUM_STREAMS](.*);
ready_valid_i #(read_req_t)          read_conf[NUM_STREAMS](.*);
ready_valid_i #(column_chunk_conf_t) column_chunk_conf[NUM_DECODERS](.*);
decoder_profile_i                    decoder_profiles[NUM_DECODERS]();

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS),
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS
`ifndef EN_RDMA
        , NUM_IQR_CONFIG_REGS
`endif
    })
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

MemConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_conf)
);

ColumnChunkDecoderConfig #(
    .NUM_DECODERS(NUM_DECODERS)
) inst_column_chunk_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .out(column_chunk_conf),

    .profile(decoder_profiles)
);

ReadReqConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_read_req_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(read_conf)
);

// -- Arbiter the read send queue ------------------------------------------------------------------
metaIntf #(.STYPE(req_t)) sq_rd_strm [NUM_STREAMS](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(
    .N_INTERFACES(NUM_STREAMS),
    .STYPE(req_t)
) inst_sq_wr_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .intf_in(sq_rd_strm),
    .intf_out(sq_rd)
);

// -- Data path ------------------------------------------------------------------------------------
AXI4S axi_out[NUM_STREAMS](.aclk(clk), .aresetn(rst_n));
for (genvar I = 0; I < NUM_DECODERS; I++) begin
    AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
    ndata_i       #(data8_t, DATABEAT_SIZE) decoder_in(.*);
    typed_ndata_i #(DATABEAT_SIZE)          typed_out(.*);
    ndata_i       #(data8_t, DATABEAT_SIZE) out(.*);

`ifdef EN_RDMA
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_rreq_recv[I], axi_in)

    RDMARead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_rdma_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`else
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_host_recv[I], axi_in)

    LocalRead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_local_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`endif

    ColumnChunkDecoder #(
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_column_chunk_decoder (
        .clk(clk),
        .rst_n(rst_n),

        .conf(column_chunk_conf[I]),

        .in(decoder_in),
        .out(typed_out),

        .profile(decoder_profiles[I])
    );

    // Discard typed
    `DATA_ASSIGN(typed_out, out);

    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(axi_out[I])
    );
end

// -- RDMA bypass stream (last stream slot, no decoder) --------------------------------------------
`ifdef EN_RDMA
localparam BYPASS_ID = NUM_STREAMS - 1;

AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
ndata_i #(data8_t, DATABEAT_SIZE) bypass_ndata();

// AXI4SR to AXI4S
`AXIS_ASSIGN(axis_rreq_recv[BYPASS_ID], axi_in)

RDMARead #(
    .AXI_STRM_ID(BYPASS_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_rdma_read_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[BYPASS_ID]),
    .sq_rd(sq_rd_strm[BYPASS_ID]),    

    .in(axi_in),
    .out(bypass_ndata)
);

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .in(bypass_ndata),
    .out(axi_out[BYPASS_ID])
);
`endif

// -- IQR_detection lane (local mode: the reserved last stream) ------------------------------------
`ifndef EN_RDMA
localparam int IQR_LANE         = NUM_STREAMS - 1;
localparam int IQR_NUM_ELEMENTS = DATABEAT_SIZE / 8;   // 8 int64 per 512-bit beat

// Host streams the decoded int64 column in on the IQR lane via LOCAL_READ. LocalRead drives the DMA
// request and yields byte-typed ndata; reinterpret it as data64 ndata for the operator.
AXI4S iqr_axi_in (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[IQR_LANE], iqr_axi_in)

ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_in();
LocalRead #(
    .AXI_STRM_ID(IQR_LANE),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_iqr_local_read (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[IQR_LANE]),
    .sq_rd(sq_rd_strm[IQR_LANE]),

    .in(iqr_axi_in),
    .out(iqr_bytes_in)
);

// data8 ndata (64 lanes) -> data64 ndata (8 lanes): same 512 bits; regroup keep (8 bytes -> 1 elem).
ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_in();
assign iqr_in.data        = iqr_bytes_in.data;
assign iqr_in.last        = iqr_bytes_in.last;
assign iqr_in.valid       = iqr_bytes_in.valid;
assign iqr_bytes_in.ready = iqr_in.ready;
for (genvar K = 0; K < IQR_NUM_ELEMENTS; K++) begin : g_iqr_keep_in
    assign iqr_in.keep[K] = &iqr_bytes_in.keep[K * 8 +: 8];
end

// -- StreamProfiler taps on the IQR input (both passes) and output (flag emission) ----------------
// Free-running (stop tied low): counters accumulate over a run and re-zero on the next run's first
// beat. Host reads them via the IQR CSRs after the passes. starved => waiting on host/DMA (the
// round-trip we are optimizing); stalled => back-pressured by the output writer.
stream_profile_i iqr_profile_in();
stream_profile_i iqr_profile_out();
assign iqr_profile_in.stop  = 1'b0;
assign iqr_profile_out.stop = 1'b0;

StreamProfiler inst_iqr_profile_in (
    .clk(clk),
    .rst_n(rst_n),
    .last (iqr_in.last),
    .valid(iqr_in.valid),
    .ready(iqr_in.ready),
    .profile(iqr_profile_in)
);

// IQR config block (config 3): window CSRs in, count-loss diagnostics + debug out.
logic [63:0] iqr_bin_min, iqr_bin_shift_w, iqr_dbg_total, iqr_dbg_clear_seq;
logic [63:0] iqr_dbg_accepted, iqr_dbg_committed, iqr_dbg_flushes, iqr_dbg_collisions;
logic        iqr_is_signed, iqr_clear_req;
IqrConfig inst_iqr_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

    .dbg_accepted(iqr_dbg_accepted),
    .dbg_committed(iqr_dbg_committed),
    .dbg_flushes(iqr_dbg_flushes),
    .dbg_collisions(iqr_dbg_collisions),
    .dbg_total(iqr_dbg_total),
    .clear_seq(iqr_dbg_clear_seq),

    .prof_in_handshakes (iqr_profile_in.counters.handshakes_cycles),
    .prof_in_starved    (iqr_profile_in.counters.starved_cycles),
    .prof_in_stalled    (iqr_profile_in.counters.stalled_cycles),
    .prof_in_idle       (iqr_profile_in.counters.idle_cycles),
    .prof_out_handshakes(iqr_profile_out.counters.handshakes_cycles),
    .prof_out_starved   (iqr_profile_out.counters.starved_cycles),
    .prof_out_stalled   (iqr_profile_out.counters.stalled_cycles),
    .prof_out_idle      (iqr_profile_out.counters.idle_cycles),

    .bin_min(iqr_bin_min),
    .bin_shift(iqr_bin_shift_w),
    .is_signed(iqr_is_signed),
    .clear_req(iqr_clear_req)
);

ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_flags_nd();
IQR_detection #(
    .value_t(data64_t),
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS),
    .NUM_BINS(1024),
    .COUNT_WIDTH(32)
) inst_iqr_detection (
    .clk(clk),
    .rst_n(rst_n),

    .bin_min(iqr_bin_min),
    .bin_shift(iqr_bin_shift_w[$clog2($bits(data64_t) + 1) - 1:0]),
    .is_signed(iqr_is_signed),
    .clear_req(iqr_clear_req),
    .dbg_total(iqr_dbg_total),
    .dbg_clear_seq(iqr_dbg_clear_seq),
    .dbg_accepted(iqr_dbg_accepted),
    .dbg_committed(iqr_dbg_committed),
    .dbg_flushes(iqr_dbg_flushes),
    .dbg_collisions(iqr_dbg_collisions),

    .in(iqr_in),
    .out(iqr_flags_nd)
);

// Pack the 0/1 flags into a dense bitmask (what the host IqrRunner expects).
ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_packed();
FlagBitPacker #(
    .value_t(data64_t),
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS)
) inst_iqr_flag_packer (
    .clk(clk),
    .rst_n(rst_n),

    .in(iqr_flags_nd),
    .out(iqr_packed)
);

// Profile the packed-flag output stream (back-pressure from the output writer / host DMA).
StreamProfiler inst_iqr_profile_out (
    .clk(clk),
    .rst_n(rst_n),
    .last (iqr_packed.last),
    .valid(iqr_packed.valid),
    .ready(iqr_packed.ready),
    .profile(iqr_profile_out)
);

// data64 ndata -> data8 ndata for the output writer.
ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_out();
assign iqr_bytes_out.data  = iqr_packed.data;
assign iqr_bytes_out.last  = iqr_packed.last;
assign iqr_bytes_out.valid = iqr_packed.valid;
assign iqr_packed.ready    = iqr_bytes_out.ready;
for (genvar K = 0; K < IQR_NUM_ELEMENTS; K++) begin : g_iqr_keep_out
    assign iqr_bytes_out.keep[K * 8 +: 8] = {8{iqr_packed.keep[K]}};
end

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_iqr_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(iqr_bytes_out),
    .out(axi_out[IQR_LANE])
);
`endif

// -- Output writer --------------------------------------------------------------------------------
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_conf),

    .data_in(axi_out),
    .data_out(axis_host_send)
);
