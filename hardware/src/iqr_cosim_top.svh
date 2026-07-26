`timescale 1ns / 1ps

import oasis::*;
import parcore::*;

// -------------------------------------------------------------------------------------------------
// IQR software-in-the-loop CO-SIM top.
//
// This is the production vfpga_top (hardware/src/vfpga_top.svh) with ONE change: the heavy
// ColumnChunkDecoder datapath (which pulls in the VHDL vhsnunzip/dictionary/varint stack) is NOT
// instantiated. That stack makes the Vivado xsim kernel FATAL at t=0 -- a pre-existing limitation
// of simulating the full production datapath, unrelated to IQR (the bare unit-test top and the
// pre-IQR baseline both reproduce it). Uninstantiated modules don't run at t=0, so dropping the
// decoder clears the crash while keeping everything the IqrRunner software actually exercises:
// the four config blocks (MemConfig, ColumnChunkDecoderConfig, ReadReqConfig, IqrConfig), the
// LocalRead/OutputWriter streaming path, and the full IQR_detection lane.
//
// The decoder stream is kept as a raw LocalRead -> OutputWriter passthrough so num_decoders still
// reads 1 (OasisContext derives iqr_stream from it) and the decoder config/read/output interfaces
// stay driven; the iqr_sim test never streams on that lane.
//
// Local mode only (no EN_RDMA): this top exists purely for the co-sim.
//
// To use: copy this over the sim slot before running the co-sim test --
//   cp hardware/src/iqr_cosim_top.svh hardware/build-sim/sim/vfpga_top.svh
// (the coyote_test unit tests clobber that slot, so re-copy if you ran them.)
// -------------------------------------------------------------------------------------------------

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb cq_rd.tie_off_s();

localparam NUM_STREAMS         = N_STRM_AXI;
localparam DATABEAT_SIZE       = AXI_DATA_BITS / 8;
localparam MEM_CONFIG_NUM_REGS = (NUM_STREAMS + 1 > 3) ? NUM_STREAMS + 1 : 3;

localparam NUM_CONFIGS   = 4;                 // MemConfig, decoder cfg, read-req cfg, IQR cfg
localparam NUM_DECODERS  = NUM_STREAMS - 1;   // reserve the last lane for IQR

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
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS,
        NUM_IQR_CONFIG_REGS
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

// Decoder streams: raw LocalRead -> OutputWriter passthrough (NO ColumnChunkDecoder, so the VHDL
// vhsnunzip stack is never instantiated and never runs at t=0). The iqr_sim test does not use them.
for (genvar I = 0; I < NUM_DECODERS; I++) begin : g_decoder_passthrough
    AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
    ndata_i #(data8_t, DATABEAT_SIZE) decoder_in(.*);

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

    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(decoder_in),
        .out(axi_out[I])
    );

    // Decoder config is advertised (num_decoders must read correctly) but unused here -- tie off the
    // config-out consumer side and feed zero profiling counters back.
    always_comb column_chunk_conf[I].tie_off_s();
    always_comb decoder_profiles[I].counters = '0;
end

// -- IQR_detection lane (the reserved last stream) ------------------------------------------------
localparam int IQR_LANE         = NUM_STREAMS - 1;
localparam int IQR_NUM_ELEMENTS = DATABEAT_SIZE / 8;   // 8 int64 per 512-bit beat

// IQR input source: host DMA (legacy) or card/HBM (axis_card_recv), selected by the use_card CSR.
logic iqr_use_card;  // driven by inst_iqr_config.use_card

AXI4S iqr_axi_in (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[IQR_LANE], iqr_axi_in)

ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_host();
LocalRead #(
    .AXI_STRM_ID(IQR_LANE),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_iqr_local_read (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[IQR_LANE]),
    .sq_rd(sq_rd_strm[IQR_LANE]),

    .in(iqr_axi_in),
    .out(iqr_bytes_host)
);

ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_in();

`ifdef EN_MEM
// Card/HBM source: staged column arrives on axis_card_recv[0] (receive only, no sq_rd).
AXI4S iqr_card_axi (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_card_recv[0], iqr_card_axi)

ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_card();
AXIToNData #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_iqr_card_recv (
    .clk(clk),
    .rst_n(rst_n),
    .in(iqr_card_axi),
    .out(iqr_bytes_card)
);

for (genvar C = 0; C < N_CARD_AXI; C++) begin : g_iqr_card_send_tie
    always_comb axis_card_send[C].tie_off_m();
end
for (genvar C = 1; C < N_CARD_AXI; C++) begin : g_iqr_card_recv_tie
    always_comb axis_card_recv[C].tie_off_s();
end

assign iqr_bytes_in.data    = iqr_use_card ? iqr_bytes_card.data  : iqr_bytes_host.data;
assign iqr_bytes_in.keep    = iqr_use_card ? iqr_bytes_card.keep  : iqr_bytes_host.keep;
assign iqr_bytes_in.last    = iqr_use_card ? iqr_bytes_card.last  : iqr_bytes_host.last;
assign iqr_bytes_in.valid   = iqr_use_card ? iqr_bytes_card.valid : iqr_bytes_host.valid;
assign iqr_bytes_host.ready = iqr_use_card ? 1'b0 : iqr_bytes_in.ready;
assign iqr_bytes_card.ready = iqr_use_card ? iqr_bytes_in.ready : 1'b0;
`else
assign iqr_bytes_in.data    = iqr_bytes_host.data;
assign iqr_bytes_in.keep    = iqr_bytes_host.keep;
assign iqr_bytes_in.last    = iqr_bytes_host.last;
assign iqr_bytes_in.valid   = iqr_bytes_host.valid;
assign iqr_bytes_host.ready = iqr_bytes_in.ready;
`endif

// data8 ndata (64 lanes) -> data64 ndata (8 lanes): same 512 bits; regroup keep (8 bytes -> 1 elem).
ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_in();
assign iqr_in.data        = iqr_bytes_in.data;
assign iqr_in.last        = iqr_bytes_in.last;
assign iqr_in.valid       = iqr_bytes_in.valid;
assign iqr_bytes_in.ready = iqr_in.ready;
for (genvar K = 0; K < IQR_NUM_ELEMENTS; K++) begin : g_iqr_keep_in
    assign iqr_in.keep[K] = &iqr_bytes_in.keep[K * 8 +: 8];
end

// -- StreamProfiler taps (mirror of the production top so co-sim exercises them) -------------------
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

// IQR config block (config 3): window CSRs in, profiler/debug out.
logic [63:0] iqr_bin_min, iqr_bin_shift_w, iqr_dbg_total, iqr_dbg_clear_seq;
logic        iqr_is_signed, iqr_clear_req;
IqrConfig inst_iqr_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

    .dbg_accepted(64'd0),   // fallback top: diagnostics not wired (the production top does)
    .dbg_committed(64'd0),
    .dbg_flushes(64'd0),
    .dbg_collisions(64'd0),
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
    .clear_req(iqr_clear_req),
    .use_card(iqr_use_card)
);

ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_flags_nd();
IQR_detection #(
    .value_t(data64_t),
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS),
    .NUM_BINS(4096),
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

    .in(iqr_in),
    .out(iqr_flags_nd)
);

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

StreamProfiler inst_iqr_profile_out (
    .clk(clk),
    .rst_n(rst_n),
    .last (iqr_packed.last),
    .valid(iqr_packed.valid),
    .ready(iqr_packed.ready),
    .profile(iqr_profile_out)
);

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
