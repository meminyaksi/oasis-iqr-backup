`timescale 1ns / 1ps

/**
 * Equivalence testbench for the pass-2 bin-index encoding.
 *
 * THE ONE QUESTION THIS ANSWERS: does comparing a 16-bit half-bin index against index-space fences
 * give the SAME outlier bit as comparing the raw 64-bit value against the value-space fences, for
 * every value and every reachable window/quartile combination (now at NUM_BINS=4096)?
 *
 * If yes, pass 2 can ship ~2x less data with no change in results, and the documented correctness
 * numbers (taxi_d1 1247, taxi_d3 162, ov_drift 200 ...) stay valid. If no -- even for one input --
 * the whole optimisation is invalid, because a wrong flag still yields a plausible outlier COUNT and
 * would not be caught downstream.
 *
 * The reference is IQR_detection's OWN value-space arithmetic, reproduced here:
 *     q1_val = bin_min + (q1_bin << bin_shift)          -- bin LOWER EDGE, not interpolated
 *     iqr    = q3_val - q1_val
 *     lo     = q1_val - iqr - (iqr >>> 1)               -- 1.5*IQR as IQR + IQR/2
 *     hi     = q3_val + iqr + (iqr >>> 1)
 *     outlier = (v < lo) || (v > hi)
 *
 * Coverage is deliberately adversarial on the cases the algebra says are dangerous:
 *   - values sitting EXACTLY on a fence, and at +-1 around it (the exact-bit case: every value in
 *     (hi, hi + 2**s) floors to the same index as hi)
 *   - values far outside the window in both directions (the saturation case)
 *   - bin_shift = 0 (no half-bin exists) and large bin_shift
 *   - q1_bin == q3_bin (IQR = 0, degenerate fences)
 *   - q1_bin/q3_bin at the extremes, where at 4096 bins the fence index reaches ~+20475 / -12285 and
 *     would overflow a 14-bit encoding (the reason for the IDX_W 14->16 re-widen)
 */
module tb_iqr_index;

    localparam int VALUE_WIDTH = 64;
    localparam int NUM_BINS    = 4096;   // build-24 re-widen: was 1024
    localparam int IDX_W       = 16;     // was 14; +-32768 covers the 4096-bin fence indices (~+20475)
    localparam int FIDX_W      = 20;
    localparam int FENCE_WIDTH = VALUE_WIDTH + 3;

    // -- DUTs ------------------------------------------------------------------------------------
    logic [VALUE_WIDTH-1:0]                    value, bin_min;
    logic [$clog2(VALUE_WIDTH+1)-1:0]          bin_shift;
    logic                                      is_signed;

    logic signed [IDX_W-1:0]                   idx;
    logic                                      exact;

    IqrIndexEncode #(.VALUE_WIDTH(VALUE_WIDTH), .IDX_W(IDX_W)) enc (
        .i_value(value), .i_bin_min(bin_min), .i_bin_shift(bin_shift), .i_is_signed(is_signed),
        .o_idx(idx), .o_exact(exact)
    );

    logic signed [FENCE_WIDTH-1:0] lo_fence, hi_fence;
    logic signed [FIDX_W-1:0]      lo_fidx, hi_fidx;

    IqrFenceIndex #(.VALUE_WIDTH(VALUE_WIDTH), .FENCE_WIDTH(FENCE_WIDTH), .FIDX_W(FIDX_W)) fl (
        .i_fence(lo_fence), .i_bin_min(bin_min), .i_bin_shift(bin_shift), .i_is_signed(is_signed),
        .o_fidx(lo_fidx)
    );
    IqrFenceIndex #(.VALUE_WIDTH(VALUE_WIDTH), .FENCE_WIDTH(FENCE_WIDTH), .FIDX_W(FIDX_W)) fh (
        .i_fence(hi_fence), .i_bin_min(bin_min), .i_bin_shift(bin_shift), .i_is_signed(is_signed),
        .o_fidx(hi_fidx)
    );

    logic idx_outlier;
    IqrIndexCompare #(.IDX_W(IDX_W), .FIDX_W(FIDX_W)) cmp (
        .i_idx(idx), .i_exact(exact), .i_lo_fidx(lo_fidx), .i_hi_fidx(hi_fidx),
        .o_outlier(idx_outlier)
    );

    // -- Reference (IQR_detection's value-space arithmetic) --------------------------------------
    int      errors  = 0;
    longint  checked = 0;

    // Set the window + quartiles, derive both fences, and settle the combinational DUTs.
    task automatic set_window(input longint bmin, input int shift, input int q1b, input int q3b,
                              input bit sgn);
        longint q1v, q3v, iqr;
        bin_min   = bmin[VALUE_WIDTH-1:0];
        bin_shift = shift[$clog2(VALUE_WIDTH+1)-1:0];
        is_signed = sgn;
        q1v = bmin + (longint'(q1b) <<< shift);
        q3v = bmin + (longint'(q3b) <<< shift);
        iqr = q3v - q1v;
        lo_fence = FENCE_WIDTH'(q1v - iqr - (iqr >>> 1));
        hi_fence = FENCE_WIDTH'(q3v + iqr + (iqr >>> 1));
        #1;
    endtask

    // Check one value against the reference. `v` is interpreted per is_signed.
    task automatic check(input longint v);
        bit  ref_outlier;
        value = v[VALUE_WIDTH-1:0];
        #1;
        if (is_signed) ref_outlier = ($signed(v) < $signed(lo_fence)) || ($signed(v) > $signed(hi_fence));
        else           ref_outlier = ($signed({1'b0, v}) < $signed(lo_fence))
                                  || ($signed({1'b0, v}) > $signed(hi_fence));
        checked++;
        if (idx_outlier !== ref_outlier) begin
            $error("MISMATCH v=%0d bin_min=%0d shift=%0d signed=%0b | idx=%0d exact=%0b lo_fidx=%0d hi_fidx=%0d | got %0b want %0b (lo=%0d hi=%0d)",
                   $signed(v), $signed(bin_min), bin_shift, is_signed,
                   idx, exact, lo_fidx, hi_fidx, idx_outlier, ref_outlier,
                   $signed(lo_fence), $signed(hi_fence));
            errors++;
        end
    endtask

    // Sweep the values that matter for a given window: on and around both fences, around bin_min,
    // and far outside. `step` is the half-bin size, which is exactly the granularity the index
    // encoding can resolve -- so +-1 and +-step around a fence are the adversarial points.
    task automatic sweep_window(input longint bmin, input int shift, input int q1b, input int q3b,
                                input bit sgn);
        longint step, lo, hi;
        set_window(bmin, shift, q1b, q3b, sgn);
        step = (shift == 0) ? 1 : (longint'(1) <<< (shift - 1));
        lo   = longint'($signed(lo_fence));
        hi   = longint'($signed(hi_fence));

        // Exactly on / adjacent to each fence -- the exact-bit cases.
        for (int k = -2; k <= 2; k++) begin
            check(lo + k);
            check(hi + k);
            check(lo + k*step);
            check(hi + k*step);
        end
        // Around the window itself.
        check(bmin);
        check(bmin - 1);
        check(bmin + 1);
        check(bmin + (longint'(q1b) <<< shift));
        check(bmin + (longint'(q3b) <<< shift));
        check(bmin + (longint'(NUM_BINS) <<< shift));
        // Far outside, where the index saturates.
        if (!sgn) begin
            check(0);
            check(64'h0000_0000_FFFF_FFFF);
        end else begin
            check(bmin - (longint'(NUM_BINS) <<< shift) * 8);
            check(bmin + (longint'(NUM_BINS) <<< shift) * 8);
        end
        // A spread of ordinary in-window values.
        for (int k = 0; k < 40; k++) begin
            check(bmin + ((longint'($urandom_range(0, NUM_BINS-1))) <<< shift)
                       + $urandom_range(0, (shift == 0) ? 0 : ((1 <<< shift) - 1)));
        end
    endtask

    initial begin
        $display("=== IQR bin-index equivalence (IDX_W=%0d, NUM_BINS=%0d) ===", IDX_W, NUM_BINS);

        // ---- directed: the corners the algebra flags -------------------------------------------
        // bin_shift = 0: no half-bin exists, index == d.
        sweep_window(0,           0, 100, 900, 0);
        sweep_window(-5000,       0, 100, 900, 1);
        // Quartiles at the extremes: at 4096 bins the fence index reaches ~+20475 / ~-12285, which
        // IDX_W=14 (+-8191) would saturate -- these are the cases that prove IDX_W=16 is wide enough.
        sweep_window(0,           4,   0, NUM_BINS-1, 0);
        sweep_window(0,           4, NUM_BINS-1, NUM_BINS-1, 0);
        sweep_window(0,           4,   0,    0, 0);
        // Degenerate IQR (q1 == q3) -> both fences equal -> only exact hits are inside.
        sweep_window(1000,        3, 500,  500, 0);
        // Odd bin span, so 1.5*IQR lands on a half-bin and not a whole one.
        sweep_window(0,           5, 100,  101, 0);
        sweep_window(0,           5, 100,  103, 0);
        // Signed windows, negative bin_min.
        sweep_window(-1_000_000,  7, 200,  800, 1);
        sweep_window(-128540,    15,  10,  400, 1);
        // Large shifts.
        sweep_window(0,          20, 300,  700, 0);
        sweep_window(0,          31, 300,  700, 0);
        // Taxi-like: wide window, fares in a narrow band.
        sweep_window(0,           5,  20,   60, 1);

        // ---- randomised -------------------------------------------------------------------------
        for (int t = 0; t < 3000; t++) begin
            int     shift = $urandom_range(0, 32);
            int     q1b   = $urandom_range(0, NUM_BINS-1);
            int     q3b   = $urandom_range(q1b, NUM_BINS-1);
            bit     sgn   = $urandom_range(0, 1);
            longint bmin  = sgn ? (longint'($urandom_range(0, 2_000_000)) - 1_000_000)
                                : longint'($urandom_range(0, 2_000_000));
            sweep_window(bmin, shift, q1b, q3b, sgn);
        end

        $display("  checked %0d (value, window) combinations", checked);
        $display("=== %s (%0d error%s) ===",
                 (errors == 0) ? "INDEX COMPARE IS BIT-IDENTICAL TO VALUE COMPARE" : "FAILURES",
                 errors, (errors == 1) ? "" : "s");
        if (errors != 0) $fatal(1, "bin-index equivalence FAILED");
        $finish;
    end

endmodule
