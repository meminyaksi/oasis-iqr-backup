`timescale 1ns / 1ps

import libstf::*;
import oasis::NUM_IQR_CONFIG_REGS;
import oasis::IQR_CONFIG_ID;

`include "libstf_macros.svh"
`include "config_macros.svh"

// Host CSR block for the IQR_detection operator (the HW half of software/oasis/iqr_config.hpp).
//
// Read side advertises IQR_CONFIG_ID at register 0 (so GlobalConfig binds it), then the count-loss
// diagnostic counters and the histogram debug counters. Write side holds the runtime window
// (bin_min/bin_shift/is_signed) stable for a run and pulses a one-cycle clear_req.
//
// (Registers 1-4 originally held unwired StreamProfiler cycle counts -- tied to 0. They now carry
//  the count-loss diagnostics from IQR_detection so the host can read N >= accepted >= committed >=
//  total and pinpoint where pass-1 counts are lost. See software/oasis/iqr_config.hpp.)
//
//   read  0 = IQR_CONFIG_ID        write 0 = bin_min
//   read  1 = dbg_accepted         write 1 = bin_shift
//   read  2 = dbg_committed        write 2 = is_signed
//   read  3 = dbg_flushes          write 3 = clear pulse
//   read  4 = dbg_collisions       write 4 = use_card (0=host DMA, 1=card/HBM input)
//   read  5 = dbg_total (histogram grand total of the last run)
//   read  6 = clear_seq (clear-completion counter)
//   read  7..10 = input  StreamProfiler: handshakes / starved / stalled / idle cycles
//   read 11..14 = output StreamProfiler: handshakes / starved / stalled / idle cycles
// The profiler counters accumulate across both passes of a run and are re-zeroed by the next run's
// first input beat, so the host reads them after the passes complete (see iqr_runner / iqr_config.hpp).
module IqrConfig (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    // Count-loss diagnostics + debug inputs, driven from the IQR data path.
    input logic [63:0] dbg_accepted,
    input logic [63:0] dbg_committed,
    input logic [63:0] dbg_flushes,
    input logic [63:0] dbg_collisions,
    input logic [63:0] dbg_total,
    input logic [63:0] clear_seq,

    // StreamProfiler cycle counters for the IQR input and output streams (tapped in the top).
    input logic [63:0] prof_in_handshakes,
    input logic [63:0] prof_in_starved,
    input logic [63:0] prof_in_stalled,
    input logic [63:0] prof_in_idle,
    input logic [63:0] prof_out_handshakes,
    input logic [63:0] prof_out_starved,
    input logic [63:0] prof_out_stalled,
    input logic [63:0] prof_out_idle,

    // Runtime window outputs, driven to IQR_detection.
    output logic [63:0] bin_min,
    output logic [63:0] bin_shift,
    output logic        is_signed,
    output logic        clear_req,

    // Data source select for the IQR input passes: 0 = host DMA (axis_host_recv, legacy),
    // 1 = card/HBM (axis_card_recv). The host stages the decoded column into HBM (LOCAL_OFFLOAD)
    // and sets this so both passes read from HBM instead of re-DMAing from the host.
    output logic        use_card
);

`RESET_RESYNC // Reset pipelining

// -- Read: ID + profiler + debug ------------------------------------------------------------------
logic [AXIL_DATA_BITS - 1:0] values[NUM_IQR_CONFIG_REGS];
assign values[0] = IQR_CONFIG_ID;
assign values[1] = dbg_accepted;
assign values[2] = dbg_committed;
assign values[3] = dbg_flushes;
assign values[4] = dbg_collisions;
assign values[5] = dbg_total;
assign values[6] = clear_seq;
assign values[7]  = prof_in_handshakes;
assign values[8]  = prof_in_starved;
assign values[9]  = prof_in_stalled;
assign values[10] = prof_in_idle;
assign values[11] = prof_out_handshakes;
assign values[12] = prof_out_starved;
assign values[13] = prof_out_stalled;
assign values[14] = prof_out_idle;

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_IQR_CONFIG_REGS)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Write: held window params --------------------------------------------------------------------
ConfigWriteRegister #(0, logic [63:0]) inst_bin_min (
    .clk(clk), .write_config(write_config), .data(bin_min)
);
ConfigWriteRegister #(1, logic [63:0]) inst_bin_shift (
    .clk(clk), .write_config(write_config), .data(bin_shift)
);
logic [63:0] is_signed_reg;
ConfigWriteRegister #(2, logic [63:0]) inst_is_signed (
    .clk(clk), .write_config(write_config), .data(is_signed_reg)
);
assign is_signed = is_signed_reg[0];

// reg 4 = use_card: input data source select (0 = host DMA, 1 = card/HBM). Held stable for a run.
logic [63:0] use_card_reg;
ConfigWriteRegister #(4, logic [63:0]) inst_use_card (
    .clk(clk), .write_config(write_config), .data(use_card_reg)
);
assign use_card = use_card_reg[0];

// reg 3 = clear pulse: assert clear_req for one cycle when written.
always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        clear_req <= 1'b0;
    end else begin
        clear_req <= write_config.valid && (write_config.addr == 3);
    end
end

endmodule
