`timescale 1ns / 1ps

/**
 * Suspect #2 for the §9.23 first-word leak: can IqrIndexFlag be left WITHOUT emitting o_last, thereby
 * leaving the downstream IqrWideFlagPack un-flushed (dirty) so the next column inherits its bits?
 *
 * IqrIndexFlag asserts o_last purely as `o_valid && (emitted + LANES >= i_expected)`. So o_last only
 * fires if i_expected matches the number of elements actually streamed in. If i_expected OVERSHOOTS the
 * delivered beats (a stale count, or the index buffer handing back fewer elements than pass 1 promised),
 * that condition never becomes true -> o_last is never asserted -> the wide packer never flushes.
 *
 * This drives the real IqrIndexFlag -> IqrWideFlagPack seam for two column-A cases, each followed by an
 * all-inside column B, with NO reset between (only the per-column i_restart pulses the real top issues):
 *
 *   MATCHED   column A: i_expected == delivered elements -> o_last fires -> packer flushes -> B clean.
 *   MISMATCH  column A: i_expected  >  delivered elements -> o_last NEVER fires -> packer left dirty.
 *                        Then B (all-inside, flags 0) leaks A's bits WITHOUT the wide-packer i_restart,
 *                        and is clean WITH it (+RESTART).
 *
 * Reports, per case: how many times column A's o_last fired (0 == the suspect-#2 condition), and whether
 * column B leaked. The flagger's own i_restart IS pulsed between columns (as the top does); only the wide
 * packer's i_restart is gated by +RESTART -- exactly the asymmetry that is the bug.
 */
module tb_iqr_indexflag_last;

    localparam int IDX_BITS = 16;
    localparam int IDX_W    = 14;
    localparam int FIDX_W   = 20;
    localparam int IN_W     = 512;
    localparam int LANES    = IN_W / IDX_BITS;   // 32

    logic clk = 1'b0, rst_n = 1'b0;
    always #2 clk = ~clk;

    // Flagger input side (driven by TB)
    logic                     i_enable = 1'b1;
    logic [63:0]              i_expected = '0;
    logic                     fl_restart = 1'b0;
    logic signed [FIDX_W-1:0] lo_fidx, hi_fidx;
    logic [IN_W-1:0]          fl_idata = '0;
    logic                     fl_ivalid = 1'b0;
    logic                     fl_oready;
    // Flagger -> packer
    logic [LANES-1:0]         fl_flags, fl_keep;
    logic                     fl_ovalid, fl_oready_in, fl_olast;
    // Packer
    logic                     wp_restart = 1'b0;
    logic [IN_W-1:0]          wp_data;
    logic                     wp_valid, wp_ready_in, wp_last;

    IqrIndexFlag #(.IDX_BITS(IDX_BITS), .IDX_W(IDX_W), .FIDX_W(FIDX_W), .IN_W(IN_W)) flagger (
        .clk(clk), .rst_n(rst_n), .i_enable(i_enable), .i_expected(i_expected), .i_restart(fl_restart),
        .i_lo_fidx(lo_fidx), .i_hi_fidx(hi_fidx),
        .i_data(fl_idata), .i_valid(fl_ivalid), .o_ready(fl_oready),
        .o_flags(fl_flags), .o_keep(fl_keep), .o_valid(fl_ovalid),
        .o_ready_in(fl_oready_in), .o_last(fl_olast)
    );

    IqrWideFlagPack #(.NUM_LANES(LANES), .OUT_W(IN_W)) packer (
        .clk(clk), .rst_n(rst_n), .i_restart(wp_restart),
        .i_flags(fl_flags), .i_keep(fl_keep), .i_valid(fl_ovalid), .o_ready(fl_oready_in),
        .i_last(fl_olast),
        .o_data(wp_data), .o_valid(wp_valid), .o_ready_in(wp_ready_in), .o_last(wp_last)
    );

    logic [15:0] lfsr = 16'hACE1;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    assign wp_ready_in = rst_n && (lfsr[1:0] != 2'd0);

    // Capture packer words during the column under test (B).
    logic [IN_W-1:0] words [0:16];
    int              nwords;
    logic            capture;
    always_ff @(posedge clk)
        if (!rst_n || !capture) nwords <= 0;
        else if (wp_valid && wp_ready_in) begin words[nwords] <= wp_data; nwords <= nwords + 1; end

    // Count column-A o_last pulses.
    int   fl_last_cnt;
    logic count_last;
    always_ff @(posedge clk)
        if (!rst_n || !count_last) fl_last_cnt <= 0;
        else if (fl_ovalid && fl_oready_in && fl_olast) fl_last_cnt <= fl_last_cnt + 1;

    int errors = 0;
    bit use_restart;

    function automatic logic [IN_W-1:0] make_beat(input int idx, input bit ex);
        logic [IN_W-1:0] b = '0;
        for (int e = 0; e < LANES; e++)
            b[e*IDX_BITS +: IDX_BITS] = {1'b0, ex, idx[IDX_W-1:0]};
        return b;
    endfunction

    task automatic drive_idx(input int nbeats, input int idx, input bit ex);
        automatic bit taken;
        for (int b = 0; b < nbeats; b++) begin
            @(negedge clk);
            fl_idata  = make_beat(idx, ex);
            fl_ivalid = 1'b1;
            taken     = 1'b0;
            while (!taken) begin
                taken = fl_oready;
                @(posedge clk); @(negedge clk);
            end
            fl_ivalid = 1'b0;
        end
        repeat (80) @(posedge clk);
    endtask

    // A = 4 beats (128 elems) of OUTLIER indices; B = 4 beats of INSIDE indices. `a_expected` sets the
    // count fed to the flagger for column A (128 = matched, 200 = overshoot -> o_last withheld).
    task automatic run_case(input string label, input longint a_expected);
        automatic int e0 = errors;
        automatic int a_last;

        // COLUMN A
        @(negedge clk); fl_restart = 1'b1; @(negedge clk); fl_restart = 1'b0;   // top restarts the flagger
        i_expected = a_expected;
        capture = 1'b0; count_last = 1'b1;
        drive_idx(4, 2000, 1'b1);      // idx 2000 > hi_fidx(1000) -> outlier=1 (residue if not flushed)
        a_last = fl_last_cnt;
        count_last = 1'b0;

        // BETWEEN COLUMNS: flagger restarted (as the top does); wide packer only if the fix is present.
        @(negedge clk); fl_restart = 1'b1; @(negedge clk); fl_restart = 1'b0;
        if (use_restart) begin @(negedge clk); wp_restart = 1'b1; @(negedge clk); wp_restart = 1'b0; end

        // COLUMN B: matched count, all-inside -> flags 0 -> word must be all zero.
        i_expected = 128;
        capture = 1'b1;
        drive_idx(4, 500, 1'b1);       // idx 500 within [0,1000] -> outlier=0

        for (int w = 0; w < nwords; w++)
            for (int e = 0; e < IN_W; e++)
                if (words[w][e] !== 1'b0) begin errors++; end

        $display("  %-26s A_o_last=%0d %s | B %s",
                 label, a_last,
                 (a_last == 0) ? "(withheld <- suspect #2)" : "(fired)   ",
                 (errors == e0) ? "clean" : "*** LEAK ***");
    endtask

    initial begin
        use_restart = $test$plusargs("RESTART");
        lo_fidx = 20'sd0;
        hi_fidx = 20'sd1000;
        $display("=== IqrIndexFlag o_last / wide-pack leak test (RESTART=%0d) ===", use_restart);

        rst_n = 1'b0; repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (3) @(posedge clk);

        run_case("MATCHED  (i_expected=128)", 128);   // o_last fires -> flush -> B clean
        run_case("MISMATCH (i_expected=200)", 200);   // o_last withheld -> dirty -> B leaks w/o fix

        $display("=== %s (%0d error%s, RESTART=%0d) ===",
                 (errors == 0) ? "ALL CLEAN" : "LEAK PRESENT",
                 errors, (errors == 1) ? "" : "s", use_restart);
        $finish;
    end

    initial begin #4_000_000; $fatal(1, "TIMEOUT"); end

endmodule
