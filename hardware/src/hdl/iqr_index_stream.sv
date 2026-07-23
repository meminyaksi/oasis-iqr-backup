`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * The two ends of IQR step 2: turning pass 2 from a 64-bit value re-read into a 16-bit index
 * re-read. Both modules are self-contained so they can be simulated without the IQR core.
 *
 * The wire format is fixed by iqr_index.sv: 16 bits per element = a 14-bit signed half-bin index
 * plus an `exact` bit, proven bit-identical to the value compare over 204884 combinations
 * (tb_iqr_index). At 512 bits per beat that is IDX_PER_BEAT = 32 elements, against 8 values per beat
 * today -- so pass 2 moves 4x fewer beats, which is the whole point.
 *
 * WHY TWO MODULES AND NOT ONE WIDER PORT. Only the pass-2 INPUT gets wider. The flag OUTPUT keeps
 * its existing 8-lane shape and simply runs 4 beats per input beat, which means FlagBitPacker and
 * everything downstream of it are untouched. That was the cheapest place to put the width change.
 */

// -------------------------------------------------------------------------------------------------
// IqrIndexPack -- pass 1 side. Takes NUM_ELEMENTS encoded indices per beat and gathers GATHER=4 of
// them into one 512-bit output beat of IDX_PER_BEAT indices, for the host to store and hand back as
// pass 2's input.
//
// The tail is zero-padded rather than length-tracked: the host knows the element count N and the
// consumer masks the tail off against it (see IqrIndexFlag), so a partial final beat needs no
// in-band length. `i_flush` emits whatever is accumulated -- tie it to the end of pass 1.
// -------------------------------------------------------------------------------------------------
module IqrIndexPack #(
    parameter int NUM_ELEMENTS = 8,
    parameter int IDX_BITS     = 16,
    parameter int OUT_W        = 512
) (
    input logic clk,
    input logic rst_n,

    // One beat of encoded indices, packed LSB-first: element i occupies [i*IDX_BITS +: IDX_BITS].
    input  logic [NUM_ELEMENTS*IDX_BITS - 1:0] i_data,
    input  logic [NUM_ELEMENTS - 1:0]          i_keep,
    input  logic                               i_valid,
    output logic                               o_ready,
    // Emit a partial beat now (end of pass 1). Held until the beat is taken.
    input  logic                               i_flush,
    // Re-arm the beat counter for a new column (tie to the histogram clear pulse).
    input  logic                               i_restart,

    output logic [OUT_W - 1:0]                 o_data,
    output logic                               o_valid,
    input  logic                               o_ready_in,
    output logic                               o_last,

    // Beats actually handed to the output writer this column. The host polls this before draining
    // the index transfer: the bypass receiver's next() blocks on a completion interrupt with NO
    // timeout, so a short stream would hang the query with nothing to report -- exactly the failure
    // mode that made the build-15 arbiter bug so expensive to find. Reset by i_restart.
    output logic [63:0]                        o_beats
);

`RESET_RESYNC

    localparam int IN_BITS = NUM_ELEMENTS * IDX_BITS;      // 128
    localparam int GATHER  = OUT_W / IN_BITS;              // 4
    localparam int GCNT_W  = $clog2(GATHER + 1);

    logic [63:0]         beats;
    logic [OUT_W - 1:0]  acc;
    logic [GCNT_W - 1:0] filled;
    logic                out_valid_r, out_last_r;
    logic [OUT_W - 1:0]  out_word;
    logic                flush_pending;

    // Fixed shift, new bits at the top -- same reasoning as FlagBitPacker: an indexed write into a
    // 512-bit register is a barrel-shifter cloud, a fixed shift is wiring. After GATHER beats the
    // first group sits in the low bits, which is the order the host expects.
    function automatic logic [OUT_W - 1:0] shift_in(logic [OUT_W - 1:0] cur,
                                                    logic [IN_BITS - 1:0] grp);
        return {grp, cur[OUT_W - 1:IN_BITS]};
    endfunction

    wire out_free = !out_valid_r || o_ready_in;
    assign o_ready = out_free && !flush_pending;

    wire fire = i_valid && o_ready;

    assign o_data  = out_word;
    assign o_valid = out_valid_r;
    assign o_last  = out_last_r;
    assign o_beats = beats;

    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            acc <= '0; filled <= '0; out_valid_r <= 1'b0; out_last_r <= 1'b0;
            flush_pending <= 1'b0; beats <= '0;
        end else begin
            if (out_valid_r && o_ready_in) begin
                out_valid_r <= 1'b0;
                beats       <= beats + 64'd1;
            end

            if (i_restart) beats <= '0;

            if (i_flush && !flush_pending && filled != '0) begin
                flush_pending <= 1'b1;
            end

            if (flush_pending) begin
                if (out_free) begin
                    // Zero-fill the rest of the word; the consumer masks the tail against N.
                    logic [OUT_W - 1:0] padded;
                    padded = acc;
                    for (int g = 0; g < GATHER; g++) begin
                        if (GCNT_W'(g) >= filled) begin
                            padded = shift_in(padded, '0);
                        end
                    end
                    out_word      <= padded;
                    out_valid_r   <= 1'b1;
                    out_last_r    <= 1'b1;
                    acc           <= '0;
                    filled        <= '0;
                    flush_pending <= 1'b0;
                end
            end else if (fire) begin
                logic [OUT_W - 1:0]  nxt;
                logic [GCNT_W - 1:0] nfill;
                logic [IN_BITS - 1:0] grp;
                // Masked-off lanes contribute a zero index; they are beyond N and get dropped by the
                // consumer, but leaving them undefined would make the packed word non-deterministic.
                for (int i = 0; i < NUM_ELEMENTS; i++) begin
                    grp[i*IDX_BITS +: IDX_BITS] = i_keep[i] ? i_data[i*IDX_BITS +: IDX_BITS]
                                                            : IDX_BITS'(0);
                end
                nxt   = shift_in(acc, grp);
                nfill = filled + GCNT_W'(1);
                if (nfill == GCNT_W'(GATHER)) begin
                    out_word    <= nxt;
                    out_valid_r <= 1'b1;
                    out_last_r  <= 1'b0;
                    acc         <= '0;
                    filled      <= '0;
                end else begin
                    acc    <= nxt;
                    filled <= nfill;
                end
            end
        end
    end

endmodule


// -------------------------------------------------------------------------------------------------
// IqrIndexFlag -- pass 2 side. Consumes one 512-bit beat of IDX_PER_BEAT indices, compares each
// against the index-space fences, and emits the outlier bits as GATHER beats of NUM_ELEMENTS -- the
// same shape the value path produces, so FlagBitPacker downstream is unchanged.
//
// Validity comes from `i_expected` (the host's element count) rather than an in-band length: the
// packed index array is padded to a whole beat, and elements at or beyond N are dropped here. That
// is also what places `o_last` on exactly the beat containing element N-1.
// -------------------------------------------------------------------------------------------------
module IqrIndexFlag #(
    parameter int NUM_ELEMENTS = 8,
    parameter int IDX_BITS     = 16,
    parameter int IDX_W        = 14,
    parameter int FIDX_W       = 20,
    parameter int IN_W         = 512
) (
    input logic clk,
    input logic rst_n,

    input logic                        i_enable,     // index mode on
    input logic [63:0]                 i_expected,   // total elements in the column
    input logic                        i_restart,    // re-arm the element counter for a new column

    input logic signed [FIDX_W - 1:0]  i_lo_fidx,
    input logic signed [FIDX_W - 1:0]  i_hi_fidx,

    input  logic [IN_W - 1:0]          i_data,
    input  logic                       i_valid,
    output logic                       o_ready,

    output logic [NUM_ELEMENTS - 1:0]  o_flags,
    output logic [NUM_ELEMENTS - 1:0]  o_keep,
    output logic                       o_valid,
    input  logic                       o_ready_in,
    output logic                       o_last
);

`RESET_RESYNC

    localparam int IDX_PER_BEAT = IN_W / IDX_BITS;                 // 32
    localparam int GATHER       = IDX_PER_BEAT / NUM_ELEMENTS;     // 4
    localparam int SUB_W        = $clog2(GATHER);

    // -- Combinational compare of all IDX_PER_BEAT indices in the incoming beat -------------------
    logic [IDX_PER_BEAT - 1:0] beat_outlier;
    for (genvar E = 0; E < IDX_PER_BEAT; E++) begin : g_cmp
        logic signed [IDX_W - 1:0] e_idx;
        logic                      e_exact;
        // Layout, fixed by IqrIndexPack: [IDX_W-1:0] = index, [IDX_W] = exact, rest reserved.
        assign e_idx   = i_data[E*IDX_BITS +: IDX_W];
        assign e_exact = i_data[E*IDX_BITS + IDX_W];

        IqrIndexCompare #(.IDX_W(IDX_W), .FIDX_W(FIDX_W)) inst_cmp (
            .i_idx(e_idx), .i_exact(e_exact),
            .i_lo_fidx(i_lo_fidx), .i_hi_fidx(i_hi_fidx),
            .o_outlier(beat_outlier[E])
        );
    end

    // -- Hold one beat, emit GATHER sub-beats -----------------------------------------------------
    logic [IDX_PER_BEAT - 1:0] flags_r;
    logic                      have;
    logic [SUB_W - 1:0]        sub;
    logic [63:0]              emitted;    // elements emitted so far this column

    assign o_ready = i_enable && !have;

    // Element index of sub-beat lane j in the held beat.
    function automatic logic [63:0] elem_of(logic [SUB_W-1:0] s, int j);
        return emitted + 64'(s) * 64'(NUM_ELEMENTS) + 64'(j) - 64'(0);
    endfunction

    logic [NUM_ELEMENTS - 1:0] sub_keep;
    logic [NUM_ELEMENTS - 1:0] sub_flags;
    logic [63:0]               base_elem;
    always_comb begin
        // `emitted` counts elements already handed out, so the beat's lane j is at emitted + j once
        // sub-beats are accounted for. sub advances only on accepted sub-beats, so emitted already
        // includes the earlier sub-beats of this same beat.
        base_elem = emitted;
        for (int j = 0; j < NUM_ELEMENTS; j++) begin
            automatic int lane = int'(sub) * NUM_ELEMENTS + j;
            sub_flags[j] = flags_r[lane];
            sub_keep[j]  = (base_elem + 64'(j)) < i_expected;
        end
    end

    assign o_flags = sub_flags;
    assign o_keep  = sub_keep;
    assign o_valid = have && (sub_keep != '0);
    // Last when this sub-beat carries the final element of the column.
    assign o_last  = o_valid && ((base_elem + 64'(NUM_ELEMENTS)) >= i_expected);

    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            have <= 1'b0; sub <= '0; flags_r <= '0; emitted <= '0;
        end else begin
            if (i_restart) begin
                have <= 1'b0; sub <= '0; emitted <= '0;
            end

            if (i_valid && o_ready) begin
                flags_r <= beat_outlier;
                have    <= 1'b1;
                sub     <= '0;
            end

            if (o_valid && o_ready_in) begin
                emitted <= emitted + 64'(NUM_ELEMENTS);
                if (sub == SUB_W'(GATHER - 1)) begin
                    have <= 1'b0;
                    sub  <= '0;
                end else begin
                    sub <= sub + SUB_W'(1);
                end
            end else if (have && (sub_keep == '0)) begin
                // Tail sub-beats entirely beyond N: retire them without emitting.
                if (sub == SUB_W'(GATHER - 1)) begin
                    have <= 1'b0;
                    sub  <= '0;
                end else begin
                    sub <= sub + SUB_W'(1);
                end
            end
        end
    end

endmodule
