`timescale 1ns / 1ps

import libstf::*;

/**
 * IQR_detection index-mode equivalence: run the SAME column through the core twice -- once with
 * i_idx_mode = 0 (pass 2 re-reads the 64-bit values) and once with i_idx_mode = 1 (pass 2 re-reads
 * the packed 16-bit indices the core itself emitted during pass 1) -- and assert the flag columns
 * are IDENTICAL.
 *
 * This is the gate for step 2 as integrated. tb_iqr_index proved the arithmetic and
 * tb_iqr_index_stream proved the pack/unpack in isolation; what is only testable here is the core's
 * own wiring: that the index stream it emits during HISTOGRAM is the one FLAG can consume, that the
 * fences reach index space correctly through fence_step 4, that FLAG leaves on the OUTPUT's last
 * (one input beat yields up to 4 flag beats, so leaving on the input's last would truncate), and
 * that HISTOGRAM back-pressures on the index packer without deadlocking.
 *
 * A wrong answer here still produces a plausible outlier COUNT, so equality against the value path
 * -- not a reference model -- is the check that matters.
 */
module tb_iqr_idx_mode;

    localparam int NUM_ELEMENTS = 8;
    localparam int NUM_BINS     = 1024;
    localparam int CLK_HALF     = 2;
    localparam int MAX_N        = 800;
    localparam int IDX_PER_BEAT = 32;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    // -- Config ----------------------------------------------------------------------------------
    logic [63:0]  bin_min;
    logic [6:0]   bin_shift;
    logic         is_signed;
    logic         idx_mode;
    logic [63:0]  expected;
    logic         clear_pulse;

    // -- Core ------------------------------------------------------------------------------------
    ndata_i #(data64_t, NUM_ELEMENTS) iqr_in   (.clk(clk), .rst_n(rst_n));
    ndata_i #(data64_t, NUM_ELEMENTS) flag_out (.clk(clk), .rst_n(rst_n));

    data64_t     dbg_total, dbg_clear_seq;
    logic [63:0] dbg_accepted, dbg_committed, dbg_flushes, dbg_collisions;
    logic        hist_active;

    logic [NUM_ELEMENTS*64-1:0] idx_data;
    logic                       idx_valid, idx_last;
    logic                       idx_ready;
    logic [63:0]                idx_beats;

    localparam int FLAGW_LANES = (NUM_ELEMENTS*64) / 16;   // 32
    logic [FLAGW_LANES-1:0]     flagw_data, flagw_keep;
    logic                       flagw_valid, flagw_ready, flagw_last;

    IQR_detection #(
        .value_t(data64_t), .NUM_ELEMENTS(NUM_ELEMENTS),
        .NUM_BINS(NUM_BINS), .COUNT_WIDTH(32)
    ) core (
        .clk(clk), .rst_n(rst_n),
        .bin_min(bin_min), .bin_shift(bin_shift[$clog2(65)-1:0]), .is_signed(is_signed),
        .clear_req(clear_pulse),
        .dbg_total(dbg_total), .dbg_clear_seq(dbg_clear_seq),
        .dbg_accepted(dbg_accepted), .dbg_committed(dbg_committed),
        .dbg_flushes(dbg_flushes), .dbg_collisions(dbg_collisions),
        .o_hist_active(hist_active),
        .i_idx_mode(idx_mode), .i_expected(expected),
        .o_idx_data(idx_data), .o_idx_valid(idx_valid), .i_idx_ready(idx_ready),
        .o_idx_last(idx_last), .o_idx_beats(idx_beats),
        .o_flagw_data(flagw_data), .o_flagw_keep(flagw_keep), .o_flagw_valid(flagw_valid),
        .i_flagw_ready(flagw_ready), .o_flagw_last(flagw_last),
        .in(iqr_in), .out(flag_out)
    );

    // Index-mode flags leave on the WIDE path: pack them 32/beat into 512-bit words, exactly as the
    // top does, so this TB validates the whole core->wide-packer seam (FSM exit included).
    logic [NUM_ELEMENTS*64-1:0] wp_data;
    logic                       wp_valid, wp_ready, wp_last;
    IqrWideFlagPack #(.NUM_LANES(FLAGW_LANES), .OUT_W(NUM_ELEMENTS*64)) wpack (
        .clk(clk), .rst_n(rst_n),
        .i_flags(flagw_data), .i_keep(flagw_keep), .i_valid(flagw_valid), .o_ready(flagw_ready),
        .i_last(flagw_last),
        .o_data(wp_data), .o_valid(wp_valid), .o_ready_in(wp_ready), .o_last(wp_last)
    );

    // Host sink for the index stream: capture the beats pass 1 emits so pass 2 can replay them.
    logic [NUM_ELEMENTS*64-1:0] idx_mem [0:MAX_N];
    int                         n_idx_beats;
    assign idx_ready = 1'b1;
    always_ff @(posedge clk) begin
        if (rst_n && idx_valid && idx_ready) begin
            idx_mem[n_idx_beats] <= idx_data;
            n_idx_beats          <= n_idx_beats + 1;
        end
    end

    // Irregular back-pressure on both flag outputs, so neither mode gets a free ride.
    logic [15:0] lfsr = 16'h7A5C;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    assign flag_out.ready = rst_n && (lfsr[2:0] != 3'd0);
    assign wp_ready       = rst_n && (lfsr[2:0] != 3'd0);

    // -- Flag capture ----------------------------------------------------------------------------
    // Value mode: flags stream out on `flag_out` (8-wide). Index mode: `flag_out` is idle and the
    // flags arrive wide-packed on wp_* (512-bit words, element e at bit e). Capture both; run_pass
    // resolves flags_got from whichever path was active.
    bit flags_got [MAX_N];
    int n_flags;
    int n_last;
    always_ff @(posedge clk) begin
        if (rst_n && flag_out.valid && flag_out.ready) begin
            for (int j = 0; j < NUM_ELEMENTS; j++) begin
                if (flag_out.keep[j]) begin
                    if (n_flags < MAX_N) flags_got[n_flags] = flag_out.data[j][0];
                    n_flags++;
                end
            end
            if (flag_out.last) n_last++;
        end
    end

    localparam int MAX_WORDS = (MAX_N + NUM_ELEMENTS*64 - 1) / (NUM_ELEMENTS*64) + 2;
    logic [NUM_ELEMENTS*64-1:0] flag_words [0:MAX_WORDS];
    int                         n_words;
    int                         n_wp_last;
    always_ff @(posedge clk) begin
        if (rst_n && wp_valid && wp_ready) begin
            flag_words[n_words] <= wp_data;
            n_words             <= n_words + 1;
            if (wp_last) n_wp_last++;
        end
    end

    // -- Column ----------------------------------------------------------------------------------
    longint col [MAX_N];
    int     n_elems;
    bit     flags_value_mode [MAX_N];
    int     errors = 0;

    task automatic drive_beats(input bit index_beats);
        automatic bit taken;
        automatic int nb = index_beats ? n_idx_beats
                                       : ((n_elems + NUM_ELEMENTS - 1) / NUM_ELEMENTS);
        for (int b = 0; b < nb; b++) begin
            @(negedge clk);
            if (index_beats) begin
                for (int e = 0; e < NUM_ELEMENTS; e++)
                    iqr_in.data[e] = idx_mem[b][e*64 +: 64];
                iqr_in.keep = '1;
                iqr_in.last = (b == nb - 1);
            end else begin
                for (int e = 0; e < NUM_ELEMENTS; e++) begin
                    automatic int i = b*NUM_ELEMENTS + e;
                    iqr_in.data[e] = (i < n_elems) ? data64_t'(col[i]) : '0;
                    iqr_in.keep[e] = (i < n_elems);
                end
                iqr_in.last = ((b + 1) * NUM_ELEMENTS >= n_elems);
            end
            iqr_in.valid = 1'b1;
            taken = 1'b0;
            while (!taken) begin
                taken = iqr_in.ready;
                @(posedge clk); @(negedge clk);
            end
            iqr_in.valid = 1'b0;
            iqr_in.last  = 1'b0;
        end
    endtask

    // One full two-pass run. `mode` selects what pass 2 re-reads.
    task automatic run_pass(input bit mode);
        automatic int guard;
        rst_n = 1'b0;
        iqr_in.valid = 1'b0; iqr_in.last = 1'b0; iqr_in.data = '0; iqr_in.keep = '0;
        clear_pulse = 1'b0; idx_mode = mode;
        n_flags = 0; n_last = 0; n_idx_beats = 0; n_words = 0; n_wp_last = 0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        expected = 64'(n_elems);
        @(negedge clk); clear_pulse = 1'b1;
        @(negedge clk); clear_pulse = 1'b0;
        guard = 0;
        while (dbg_clear_seq == 0 && guard < 8000) begin @(posedge clk); guard++; end

        // pass 1: always the raw values
        drive_beats(1'b0);
        guard = 0;
        while (hist_active && guard < 20000) begin @(posedge clk); guard++; end
        repeat (2*NUM_BINS + 64) @(posedge clk);   // let QUARTILES finish

        // pass 2: values or the captured index beats
        drive_beats(mode);
        repeat (400) @(posedge clk);

        // In index mode the flags came out wide-packed; unpack element e from bit e so the rest of
        // the scenario can compare flags_got against the value-mode reference uniformly.
        if (mode) begin
            for (int e = 0; e < n_elems; e++)
                flags_got[e] = flag_words[e / (NUM_ELEMENTS*64)][e % (NUM_ELEMENTS*64)];
            n_flags = n_elems;    // match value mode's per-element count
            n_last  = n_wp_last;  // exactly one, from the wide packer's flush
        end
    endtask

    task automatic run_scenario(input string name, input int n, input longint bmin, input int shift,
                                input bit sgn, input int pattern);
        automatic int errors0 = errors;
        n_elems   = n;
        bin_min   = bmin[63:0];
        bin_shift = shift[6:0];
        is_signed = sgn;

        for (int i = 0; i < n; i++) begin
            case (pattern)
                0: col[i] = bmin + ((longint'(i % NUM_BINS)) <<< shift);
                1: col[i] = bmin + ((longint'($urandom_range(0, NUM_BINS-1))) <<< shift)
                                 + $urandom_range(0, (shift == 0) ? 0 : ((1 <<< shift) - 1));
                2: col[i] = (i % 23 == 0) ? bmin + (longint'(NUM_BINS*4) <<< shift)
                                          : bmin + ((longint'(400 + (i % 200))) <<< shift);
                default: col[i] = bmin + ((longint'(500)) <<< shift);
            endcase
        end

        // Reference: the value path.
        run_pass(1'b0);
        if (n_flags != n) begin
            $error("%s: value mode emitted %0d flags, expected %0d", name, n_flags, n);
            errors++;
        end
        if (dbg_total !== data64_t'(n)) begin
            $error("%s: value mode dbg_total = %0d, expected %0d", name, dbg_total, n);
            errors++;
        end
        for (int i = 0; i < n; i++) flags_value_mode[i] = flags_got[i];

        // Under test: the index path.
        run_pass(1'b1);
        if (n_flags != n) begin
            $error("%s: INDEX mode emitted %0d flags, expected %0d", name, n_flags, n);
            errors++;
        end
        if (n_last != 1) begin
            $error("%s: INDEX mode asserted last %0d times, expected 1", name, n_last);
            errors++;
        end
        if (n_idx_beats != (n + IDX_PER_BEAT - 1) / IDX_PER_BEAT) begin
            $error("%s: emitted %0d index beats, expected %0d", name, n_idx_beats,
                   (n + IDX_PER_BEAT - 1) / IDX_PER_BEAT);
            errors++;
        end
        for (int i = 0; i < n; i++) begin
            if (flags_got[i] !== flags_value_mode[i]) begin
                $error("%s: flag[%0d] index=%0b value=%0b (v=%0d)",
                       name, i, flags_got[i], flags_value_mode[i], $signed(col[i]));
                errors++;
            end
        end

        $display("  %-28s N=%4d idx_beats=%3d flags=%4d  %s",
                 name, n, n_idx_beats, n_flags,
                 (errors == errors0) ? "PASS (index == value)" : "*** FAIL ***");
    endtask

    initial begin
        $display("=== IQR_detection index-mode equivalence (NUM_BINS=%0d) ===", NUM_BINS);

        run_scenario("sweep, whole beats",     256,       0,  4, 0, 0);
        run_scenario("random, whole beats",    256,       0,  4, 0, 1);
        run_scenario("partial tail +1",        257,       0,  4, 0, 1);
        run_scenario("partial tail +9",        265,       0,  4, 0, 1);
        run_scenario("planted far outliers",   320,    1000,  5, 0, 2);
        run_scenario("signed, negative min",   192, -500000,  6, 1, 1);
        run_scenario("bin_shift 0",            160,       0,  0, 0, 0);
        run_scenario("all equal (IQR = 0)",    128,     500,  3, 0, 3);

        $display("=== %s (%0d error%s) ===",
                 (errors == 0) ? "INDEX MODE MATCHES VALUE MODE IN THE CORE" : "FAILURES",
                 errors, (errors == 1) ? "" : "s");
        if (errors != 0) $fatal(1, "index-mode equivalence FAILED");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "TIMEOUT -- core stalled (index packer back-pressure deadlock?)");
    end

endmodule
