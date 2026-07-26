`timescale 1ns / 1ps

/**
 * Cross-column state test for IqrWideFlagPack (the §9.23 first-word leak suspect).
 *
 * The existing TBs reset per scenario, so they never see one column inherit state from the previous one
 * in the same session. This drives two columns through ONE packer with a SINGLE reset at the start and
 * NONE between them, in two scenarios:
 *
 *   S1 "clean A"  -- column A completes normally (asserts i_last -> flush). Column B (all-zero flags)
 *                    must produce an all-zero word. This checks the NORMAL path: a well-terminated
 *                    column already leaves the packer empty, so B is clean with or without the fix.
 *   S2 "dirty A"  -- column A is left mid-accumulation (no i_last, e.g. upstream dropped `last`), so acc
 *                    holds A's bits. Column B (all-zero flags) then flushes. WITHOUT a per-column reset,
 *                    A's residual bits appear in B's word (the leak). WITH i_restart (+RESTART), B is
 *                    clean. This is what the fix guards against.
 *
 * Column B feeds ALL-ZERO flags, so a correct result is a fully-zero packed word; ANY 1 bit is column A
 * leaking through. Run with and without +RESTART; the no-RESTART run is the revert check.
 */
module tb_iqr_wide_pack_reset;

    localparam int NUM_LANES = 32;
    localparam int OUT_W     = 512;
    localparam int A_BEATS   = 6;    // left mid-word in S2 -> 6 slots of ones remain in acc
    localparam int B_BEATS   = 4;    // 128 all-zero elems

    logic clk = 1'b0, rst_n = 1'b0;
    always #2 clk = ~clk;

    logic [NUM_LANES-1:0] i_flags = '0, i_keep = '0;
    logic                 i_valid = 1'b0, i_last = 1'b0, i_restart = 1'b0;
    logic                 o_ready;
    logic [OUT_W-1:0]     o_data;
    logic                 o_valid, o_ready_in, o_last;

    IqrWideFlagPack #(.NUM_LANES(NUM_LANES), .OUT_W(OUT_W)) dut (
        .clk(clk), .rst_n(rst_n), .i_restart(i_restart),
        .i_flags(i_flags), .i_keep(i_keep), .i_valid(i_valid), .o_ready(o_ready), .i_last(i_last),
        .o_data(o_data), .o_valid(o_valid), .o_ready_in(o_ready_in), .o_last(o_last)
    );

    logic [15:0] lfsr = 16'hBEEF;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    assign o_ready_in = rst_n && (lfsr[1:0] != 2'd0);

    logic [OUT_W-1:0] words [0:16];
    int               nwords;
    logic             capture;
    always_ff @(posedge clk)
        if (!rst_n || !capture) nwords <= 0;
        else if (o_valid && o_ready_in) begin
            words[nwords] <= o_data;
            nwords        <= nwords + 1;
        end

    int errors = 0;
    bit use_restart;

    task automatic drive_col(input int nbeats, input bit flagval, input bit assert_last);
        automatic bit taken;
        for (int b = 0; b < nbeats; b++) begin
            @(negedge clk);
            i_flags = {NUM_LANES{flagval}};
            i_keep  = '1;
            i_valid = 1'b1;
            i_last  = assert_last && (b == nbeats - 1);
            taken   = 1'b0;
            while (!taken) begin
                taken = o_ready;
                @(posedge clk); @(negedge clk);
            end
            i_valid = 1'b0;
            i_last  = 1'b0;
        end
        repeat (80) @(posedge clk);
    endtask

    // One scenario: (optionally dirty) column A, then all-zero column B; B's word(s) must be all zero.
    task automatic run_pair(input string label, input bit dirty_a);
        automatic int e0 = errors;
        capture = 1'b0;
        drive_col(A_BEATS, 1'b1, /*assert_last*/ !dirty_a);

        if (use_restart) begin
            @(negedge clk); i_restart = 1'b1;
            @(negedge clk); i_restart = 1'b0;
        end

        capture = 1'b1;
        drive_col(B_BEATS, 1'b0, /*assert_last*/ 1'b1);

        if (nwords < 1) begin
            $error("%s: column B produced no word", label); errors++;
        end
        for (int w = 0; w < nwords; w++)
            for (int e = 0; e < OUT_W; e++)
                if (words[w][e] !== 1'b0) begin
                    $error("%s: B word %0d bit[%0d] = 1 (should be 0)  <-- column A leaked through",
                           label, w, e);
                    errors++;
                end
        $display("  %-16s -> %s", label, (errors == e0) ? "clean" : "*** LEAK ***");
    endtask

    initial begin
        use_restart = $test$plusargs("RESTART");
        $display("=== IqrWideFlagPack back-to-back column test (RESTART=%0d) ===", use_restart);

        rst_n = 1'b0; repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (3) @(posedge clk);

        run_pair("S1 clean A", 1'b0);   // normal completion: clean either way
        run_pair("S2 dirty A", 1'b1);   // residue: leaks WITHOUT restart, clean WITH it

        $display("=== %s (%0d error%s, RESTART=%0d) ===",
                 (errors == 0) ? "ALL CLEAN" : "LEAK PRESENT",
                 errors, (errors == 1) ? "" : "s", use_restart);
        $finish;
    end

    initial begin
        #4_000_000;
        $fatal(1, "TIMEOUT");
    end

endmodule
