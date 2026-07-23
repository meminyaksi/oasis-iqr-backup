`timescale 1ns / 1ps

/**
 * Round-trip testbench for IQR step 2's index path: encode -> pack -> (host round trip) -> unpack ->
 * compare -> flags, checked against the value-space comparison it replaces.
 *
 * tb_iqr_index already proved the ARITHMETIC is bit-identical. This proves the PLUMBING preserves it:
 * that 16-bit indices survive being gathered 4-to-a-beat, handed back, unpacked 32-to-a-beat, and
 * re-expanded into 8-wide flag beats -- in the right ORDER, with the right ELEMENT COUNT, and with
 * `last` on the right beat. A packing or ordering slip here misplaces flags while still producing a
 * plausible outlier count, so it would not be caught downstream.
 *
 * Checks per scenario:
 *   - flag[i] matches the value-space outlier test for every element, in order
 *   - exactly N flags are emitted (no tail leakage from the zero-padded final index beat)
 *   - `last` is asserted exactly once, on the beat carrying element N-1
 */
module tb_iqr_index_stream;

    localparam int VALUE_WIDTH  = 64;
    localparam int NUM_ELEMENTS = 8;
    localparam int IDX_BITS     = 16;
    localparam int IDX_W        = 14;
    localparam int FIDX_W       = 20;
    localparam int OUT_W        = 512;
    localparam int IDX_PER_BEAT = OUT_W / IDX_BITS;    // 32
    localparam int FENCE_WIDTH  = VALUE_WIDTH + 3;
    localparam int CLK_HALF     = 2;
    localparam int MAX_N        = 600;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    // -- Column under test -----------------------------------------------------------------------
    longint col [MAX_N];
    int     n_elems;
    logic [VALUE_WIDTH-1:0]           bin_min;
    logic [$clog2(VALUE_WIDTH+1)-1:0] bin_shift;
    logic                             is_signed;
    logic signed [FENCE_WIDTH-1:0]    lo_fence, hi_fence;

    int errors  = 0;
    int n_flags = 0;
    int n_last  = 0;

    // -- Encode (pass 1): one beat of NUM_ELEMENTS values -> packed indices ----------------------
    logic [VALUE_WIDTH-1:0]            enc_value [NUM_ELEMENTS];
    logic [NUM_ELEMENTS*IDX_BITS-1:0]  enc_packed;
    for (genvar I = 0; I < NUM_ELEMENTS; I++) begin : g_enc
        logic signed [IDX_W-1:0] e_idx;
        logic                    e_exact;
        IqrIndexEncode #(.VALUE_WIDTH(VALUE_WIDTH), .IDX_W(IDX_W)) inst_enc (
            .i_value(enc_value[I]), .i_bin_min(bin_min), .i_bin_shift(bin_shift),
            .i_is_signed(is_signed), .o_idx(e_idx), .o_exact(e_exact)
        );
        // The layout IqrIndexFlag expects.
        assign enc_packed[I*IDX_BITS +: IDX_BITS] = {{(IDX_BITS-IDX_W-1){1'b0}}, e_exact, e_idx};
    end

    // -- Fences -> index space -------------------------------------------------------------------
    logic signed [FIDX_W-1:0] lo_fidx, hi_fidx;
    IqrFenceIndex #(.VALUE_WIDTH(VALUE_WIDTH), .FENCE_WIDTH(FENCE_WIDTH), .FIDX_W(FIDX_W)) fl (
        .i_fence(lo_fence), .i_bin_min(bin_min), .i_bin_shift(bin_shift), .i_is_signed(is_signed),
        .o_fidx(lo_fidx));
    IqrFenceIndex #(.VALUE_WIDTH(VALUE_WIDTH), .FENCE_WIDTH(FENCE_WIDTH), .FIDX_W(FIDX_W)) fh (
        .i_fence(hi_fence), .i_bin_min(bin_min), .i_bin_shift(bin_shift), .i_is_signed(is_signed),
        .o_fidx(hi_fidx));

    // -- Pack (pass 1 output) --------------------------------------------------------------------
    logic [NUM_ELEMENTS-1:0] pk_keep;
    logic                    pk_valid, pk_ready, pk_flush;
    logic [OUT_W-1:0]        pk_data;
    logic                    pk_out_valid, pk_out_ready, pk_out_last;

    IqrIndexPack #(.NUM_ELEMENTS(NUM_ELEMENTS), .IDX_BITS(IDX_BITS), .OUT_W(OUT_W)) packer (
        .clk(clk), .rst_n(rst_n),
        .i_data(enc_packed), .i_keep(pk_keep), .i_valid(pk_valid), .o_ready(pk_ready),
        .i_flush(pk_flush),
        .o_data(pk_data), .o_valid(pk_out_valid), .o_ready_in(pk_out_ready), .o_last(pk_out_last)
    );

    // -- The "host round trip": capture packed beats, replay them ---------------------------------
    logic [OUT_W-1:0] idx_mem [0:MAX_N];   // one entry per packed beat
    int               n_beats;

    assign pk_out_ready = 1'b1;            // host sink always accepts
    always_ff @(posedge clk) begin
        if (rst_n && pk_out_valid && pk_out_ready) begin
            idx_mem[n_beats] <= pk_data;
            n_beats          <= n_beats + 1;
        end
    end

    // -- Unpack + compare (pass 2) ---------------------------------------------------------------
    logic                    fl_enable, fl_restart;
    logic [63:0]             fl_expected;
    logic [OUT_W-1:0]        fl_data;
    logic                    fl_valid, fl_ready;
    logic [NUM_ELEMENTS-1:0] fl_flags, fl_keep;
    logic                    fl_out_valid, fl_out_ready, fl_out_last;

    IqrIndexFlag #(.NUM_ELEMENTS(NUM_ELEMENTS), .IDX_BITS(IDX_BITS), .IDX_W(IDX_W),
                   .FIDX_W(FIDX_W), .IN_W(OUT_W)) flagger (
        .clk(clk), .rst_n(rst_n),
        .i_enable(fl_enable), .i_expected(fl_expected), .i_restart(fl_restart),
        .i_lo_fidx(lo_fidx), .i_hi_fidx(hi_fidx),
        .i_data(fl_data), .i_valid(fl_valid), .o_ready(fl_ready),
        .o_flags(fl_flags), .o_keep(fl_keep), .o_valid(fl_out_valid),
        .o_ready_in(fl_out_ready), .o_last(fl_out_last)
    );

    // Irregular back-pressure on the flag output.
    logic [15:0] lfsr = 16'h1234;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    assign fl_out_ready = rst_n && (lfsr[2:0] != 3'd0);

    // -- Flag checker ----------------------------------------------------------------------------
    function automatic bit ref_outlier(longint v);
        if (is_signed) return ($signed(v) < $signed(lo_fence)) || ($signed(v) > $signed(hi_fence));
        else           return ($signed({1'b0, v}) < $signed(lo_fence))
                           || ($signed({1'b0, v}) > $signed(hi_fence));
    endfunction

    always_ff @(posedge clk) begin
        if (rst_n && fl_out_valid && fl_out_ready) begin
            for (int j = 0; j < NUM_ELEMENTS; j++) begin
                if (fl_keep[j]) begin
                    if (n_flags < n_elems) begin
                        automatic bit want = ref_outlier(col[n_flags]);
                        if (fl_flags[j] !== want) begin
                            $error("flag[%0d] = %0b, want %0b (value %0d)",
                                   n_flags, fl_flags[j], want, $signed(col[n_flags]));
                            errors++;
                        end
                    end
                    n_flags++;
                end
            end
            if (fl_out_last) n_last++;
        end
    end

    // -- Drivers ---------------------------------------------------------------------------------
    task automatic drive_pass1();
        automatic bit taken;
        automatic int sent = 0;
        while (sent < n_elems) begin
            automatic int k = (n_elems - sent >= NUM_ELEMENTS) ? NUM_ELEMENTS : (n_elems - sent);
            @(negedge clk);
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                enc_value[e] = (e < k) ? col[sent + e][VALUE_WIDTH-1:0] : '0;
                pk_keep[e]   = (e < k);
            end
            pk_valid = 1'b1;
            taken    = 1'b0;
            while (!taken) begin
                taken = pk_ready;
                @(posedge clk); @(negedge clk);
            end
            pk_valid = 1'b0;
            sent += k;
        end
        // Flush any partial word.
        @(negedge clk); pk_flush = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk); pk_flush = 1'b0;
        repeat (4) @(posedge clk);
    endtask

    task automatic drive_pass2();
        automatic bit taken;
        for (int b = 0; b < n_beats; b++) begin
            @(negedge clk);
            fl_data  = idx_mem[b];
            fl_valid = 1'b1;
            taken    = 1'b0;
            while (!taken) begin
                taken = fl_ready;
                @(posedge clk); @(negedge clk);
            end
            fl_valid = 1'b0;
        end
        repeat (200) @(posedge clk);
    endtask

    task automatic run_scenario(input string name, input int n, input longint bmin, input int shift,
                                input int q1b, input int q3b, input bit sgn, input int pattern);
        automatic int errors0 = errors;
        automatic int want_beats;
        automatic longint q1v, q3v, iqr;

        rst_n = 1'b0;
        pk_valid = 1'b0; pk_flush = 1'b0; pk_keep = '0;
        fl_valid = 1'b0; fl_enable = 1'b0; fl_restart = 1'b0;
        n_flags = 0; n_last = 0; n_beats = 0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        n_elems   = n;
        bin_min   = bmin[VALUE_WIDTH-1:0];
        bin_shift = shift[$clog2(VALUE_WIDTH+1)-1:0];
        is_signed = sgn;
        q1v = bmin + (longint'(q1b) <<< shift);
        q3v = bmin + (longint'(q3b) <<< shift);
        iqr = q3v - q1v;
        lo_fence = FENCE_WIDTH'(q1v - iqr - (iqr >>> 1));
        hi_fence = FENCE_WIDTH'(q3v + iqr + (iqr >>> 1));

        for (int i = 0; i < n; i++) begin
            case (pattern)
                0: col[i] = bmin + ((longint'(i % 1024)) <<< shift);          // sweep the window
                1: col[i] = bmin + ((longint'($urandom_range(0, 1023))) <<< shift);
                2: col[i] = (i % 17 == 0) ? (bmin - (longint'(4096) <<< shift))  // planted outliers
                                          : bmin + ((longint'(500)) <<< shift);
                default: col[i] = longint'($signed(hi_fence)) + (i % 5) - 2;   // straddle the fence
            endcase
        end

        fl_expected = n;
        @(negedge clk); fl_restart = 1'b1; fl_enable = 1'b1;
        @(negedge clk); fl_restart = 1'b0;

        drive_pass1();
        drive_pass2();

        want_beats = (n + IDX_PER_BEAT - 1) / IDX_PER_BEAT;
        if (n_beats != want_beats) begin
            $error("%s: packed %0d index beats, expected %0d", name, n_beats, want_beats);
            errors++;
        end
        if (n_flags != n) begin
            $error("%s: emitted %0d flags, expected %0d", name, n_flags, n);
            errors++;
        end
        if (n_last != 1) begin
            $error("%s: `last` asserted %0d times, expected 1", name, n_last);
            errors++;
        end
        $display("  %-30s N=%4d beats=%3d flags=%4d last=%0d  %s",
                 name, n, n_beats, n_flags, n_last,
                 (errors == errors0) ? "PASS" : "*** FAIL ***");
    endtask

    initial begin
        $display("=== IQR index stream round trip (IDX_PER_BEAT=%0d) ===", IDX_PER_BEAT);

        // Whole beats: 32 indices per beat, 8 elements per input beat.
        run_scenario("exact 1 beat",         32,       0,  4, 100, 900, 0, 0);
        run_scenario("exact 4 beats",       128,       0,  4, 100, 900, 0, 1);
        // Partial tails -- every residue class mod 32, and mod 8 within it.
        run_scenario("partial +1",           33,       0,  4, 100, 900, 0, 1);
        run_scenario("partial +7",           39,       0,  4, 100, 900, 0, 1);
        run_scenario("partial +8",           40,       0,  4, 100, 900, 0, 1);
        run_scenario("partial +31",          63,       0,  4, 100, 900, 0, 1);
        run_scenario("single element",         1,      0,  4, 100, 900, 0, 1);
        // Fence-straddling values: the exact-bit path under real streaming.
        run_scenario("straddle upper fence", 200,      0,  5, 100, 300, 0, 3);
        // Planted far outliers: the saturation path.
        run_scenario("planted outliers",     340,   1000,  6,  50, 800, 0, 2);
        // Signed / negative bin_min.
        run_scenario("signed window",        257, -100000, 7, 200, 800, 1, 1);
        // bin_shift 0: no half-bin exists.
        run_scenario("bin_shift 0",          160,       0,  0, 100, 900, 0, 0);
        // Degenerate IQR.
        run_scenario("q1 == q3",             128,    1000,  3, 500, 500, 0, 1);

        $display("=== %s (%0d error%s) ===",
                 (errors == 0) ? "INDEX STREAM ROUND TRIP MATCHES VALUE PATH" : "FAILURES",
                 errors, (errors == 1) ? "" : "s");
        if (errors != 0) $fatal(1, "index stream round trip FAILED");
        $finish;
    end

    initial begin
        #8_000_000;
        $fatal(1, "TIMEOUT -- index stream stalled");
    end

endmodule
