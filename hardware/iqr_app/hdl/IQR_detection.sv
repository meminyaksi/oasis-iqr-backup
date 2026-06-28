`timescale 1ns / 1ps

`include "libstf_macros.svh"

// Uncomment to build the count-loss ILA (probes bank-0's BRAM read-modify-write path so the
// read-after-write hazard can be watched live on silicon). Requires the ila_iqr IP from
// hardware/src/init_ip.tcl and the probe widths there to match (BIN_IDX_WIDTH / COUNT_WIDTH).
// Leave commented for production bitstreams -- the host-readable counters below need no ILA.
`define IQR_DEBUG_ILA

module IQR_detection #(
    parameter type value_t,
    parameter      NUM_ELEMENTS,
    parameter      NUM_BINS    = 16,         // generic bin count
    parameter      COUNT_WIDTH = 32          // width of each bin counter
) (
    input logic clk,
    input logic rst_n,

    // Runtime configuration, driven from host CSRs (held stable for a run):
    //   bin_min   : window low edge (interpreted signed when is_signed)
    //   bin_shift : bin width = 2**bin_shift
    //   is_signed : treat input values as signed (sign-aware binning + fences)
    input logic [$bits(value_t) - 1:0]            bin_min,
    input logic [$clog2($bits(value_t) + 1) - 1:0] bin_shift,
    input logic                                   is_signed,

    // Host-pulsed clear: forces a full histogram zero-sweep before the next pass-1, so
    // every run starts clean regardless of how the previous run terminated. Coyote does
    // not reset the user logic between host processes, and the end-of-run self-clear is
    // not guaranteed to take effect across that boundary -- this pulse recovers it.
    input logic                                   clear_req,

    // Debug: grand total of the histogram for the last scanned dataset (== element count
    // iff the banks were properly zeroed). The host reads it to confirm no cross-run residue.
    output logic [$bits(value_t) - 1:0]           dbg_total,

    // Clear-completion sequence: increments by 1 every time a clear_req-initiated zero-sweep
    // FINISHES (not the reset/end-of-run self-clears). The host captures it, pulses clear_req,
    // then polls until it advances -- a race-free fence so the posted clear write is guaranteed
    // applied (banks zeroed, core idle-ready) before pass-1 data is allowed to stream in.
    output logic [$bits(value_t) - 1:0]           dbg_clear_seq,

    // -- Count-loss diagnostics (read back via the IQR CSR block; reset on clear_req each run) ---
    // The host knows N (values streamed in pass-1) and compares the chain
    //     N  >=  dbg_accepted  >=  dbg_committed  >=  dbg_total
    // to localize WHERE pass-1 counts are lost on silicon (sim is hazard-free, so loss hides):
    //   accepted  < N         -> loss at the input handshake / DMA (before binning)
    //   committed < accepted  -> loss in the coalescing accumulator (runs not fully carried)
    //   total     < committed -> loss in the BRAM read-modify-write (the read-after-write hazard)
    // dbg_collisions counts flush-reads that hit a just-written bin -- direct hazard evidence;
    // dbg_flushes is the BRAM write count (texture for how much coalescing happened).
    output logic [63:0]                           dbg_accepted,
    output logic [63:0]                           dbg_committed,
    output logic [63:0]                           dbg_flushes,
    output logic [63:0]                           dbg_collisions,

    ndata_i.s in,   // #(value_t, NUM_ELEMENTS) input values
    ndata_i.m out   // #(value_t, NUM_ELEMENTS) results (driven later)
);

`RESET_RESYNC // Reset pipelining

    localparam int VALUE_WIDTH   = $bits(value_t);
    localparam int BIN_IDX_WIDTH = (NUM_BINS > 1) ? $clog2(NUM_BINS) : 1;

    typedef enum logic [1:0] {
        HISTOGRAM,
        QUARTILES,
        FLAG
    } state_t;

    state_t state;

    // Quartile search status
    logic q1_found;
    logic q3_found;

    // -- Quartile scan state --------------------------------------------------
    // The histogram lives spread across NUM_ELEMENTS banks. The quartile scan
    // sweeps the bins, summing the banks per bin (the deferred merge), in two
    // passes: Q_SUM computes the grand total, Q_SCAN walks the cumulative count
    // to locate Q1 (25%) and Q3 (75%).
    logic [COUNT_WIDTH - 1:0]  bank_q [NUM_ELEMENTS];   // per-bank read data (exposed by g_bank)

    // -- Count-loss diagnostics: per-bank accumulators, summed into the CSR debug regs below ----
    logic [63:0] bank_committed  [NUM_ELEMENTS];   // Σ delta each bank intended to write to BRAM
    logic [63:0] bank_flushes    [NUM_ELEMENTS];   // # BRAM writes (flushes) per bank
    logic [63:0] bank_collisions [NUM_ELEMENTS];   // # flush-reads that hit a just-written bin

    typedef enum logic {Q_SUM, Q_SCAN} q_phase_t;
    q_phase_t                   q_phase;
    logic [BIN_IDX_WIDTH:0]     scan_cnt;               // sweep counter, 0..NUM_BINS+1
    logic [BIN_IDX_WIDTH - 1:0] q_raddr;                // bank read address during QUARTILES
    assign q_raddr = scan_cnt[BIN_IDX_WIDTH - 1:0];

    logic [COUNT_WIDTH - 1:0]   total;                  // total element count (sum of all bins)
    logic [COUNT_WIDTH - 1:0]   cumulative;             // running cumulative during Q_SCAN

    assign dbg_total = ($bits(value_t))'(total);        // debug readback (zero-extended)

    logic [BIN_IDX_WIDTH - 1:0] q1_bin, q3_bin;         // bins where Q1 / Q3 land
    logic [VALUE_WIDTH - 1:0]   q1_val, q3_val;         // their representative values
    logic signed [VALUE_WIDTH + 2:0] iqr_val;           // Q3 - Q1
    logic signed [VALUE_WIDTH + 2:0] lower_fence;       // Q1 - 1.5*IQR
    logic signed [VALUE_WIDTH + 2:0] upper_fence;       // Q3 + 1.5*IQR

    // -- BRAM clear sweep -----------------------------------------------------
    // A BRAM cannot be wiped in one cycle, so on entering HISTOGRAM we walk
    // address 0..NUM_BINS-1 writing zero to every bank before accepting data.
    // Also reused to re-clear the banks between datasets (FLAG -> HISTOGRAM).
    logic                       clearing;
    logic [BIN_IDX_WIDTH - 1:0] clear_addr;

    // Host clear-completion handshake: clear_req_pending marks that the *current* sweep was
    // started by a host clear_req; clear_seq is bumped once that sweep finishes so the host can
    // observe its specific clear completed (immune to the posted write-FIFO and to missing the
    // ~1us sweep). Reset/end-of-run self-clears leave clear_req_pending low and do not bump it.
    logic                       clear_req_pending;
    logic [31:0]                clear_seq;
    assign dbg_clear_seq = ($bits(value_t))'(clear_seq);

    // -- Per-lane bin index: two-stage pipeline (timing) ----------------------
    // The bin index is a long combinational cloud once bin_min/bin_shift/is_signed
    // are runtime CSRs: a signed subtract (value - bin_min) FOLLOWED BY a *variable*
    // barrel shift (>> bin_shift) and the saturate compare. Driving the histogram
    // BRAM address off that whole cloud in a single cycle is the marginal path that
    // mis-bins values on silicon when bin_shift > 0 -- functionally correct in sim
    // (proven bit-exact), but it fails setup post-route, scattering counts into wrong
    // bins and grossly shifting the quartiles (the "wide" example: ~248 flag misses,
    // while bin_shift = 0 distributions, whose shift is trivial, pass). Split the
    // cloud into TWO registered stages so the subtract and the variable shift occupy
    // separate clock cycles:
    //   stage A : diff = value - bin_min   (+ below-window flag)        -> *_q1
    //   stage B : shifted = diff >> bin_shift, then saturate to a bin   -> lane_idx_q
    // bin_min/bin_shift/is_signed are held stable for the whole run, so they need no
    // pipelining. This adds ONE more cycle between input accept and the increment
    // commit (beat -> commit is now 4 cycles), so the HISTOGRAM drain waits one extra
    // cycle (drain_cnt = 4 instead of 3). Out-of-window values clamp into the edge
    // bins (Q1/Q3 are central, so edge pile-up does not perturb them).

    // A beat is accepted at the input on this cycle (it is binned three cycles later,
    // after the two-stage bin-index pipeline below).
    logic accept;
    assign accept = (state == HISTOGRAM) && !clearing && in.valid && in.ready;

    // -- Stage A (comb): signed/unsigned subtract + below-window flag ---------
    logic                        below_a [NUM_ELEMENTS];
    logic signed [VALUE_WIDTH:0] diff_a  [NUM_ELEMENTS];   // value - bin_min, one extra bit
    always_comb begin
        for (int i = 0; i < NUM_ELEMENTS; i++) begin
            // Compare/subtract in the configured signedness. Unsigned: zero-extend;
            // signed: sign-extend. When !below the value is >= bin_min, so diff >= 0.
            if (is_signed) begin
                below_a[i] = $signed(in.data[i]) < $signed(bin_min);
                diff_a[i]  = $signed({in.data[i][VALUE_WIDTH-1], in.data[i]})
                           - $signed({bin_min[VALUE_WIDTH-1], bin_min});
            end else begin
                below_a[i] = in.data[i] < bin_min;
                diff_a[i]  = $signed({1'b0, in.data[i]}) - $signed({1'b0, bin_min});
            end
        end
    end

    // -- Stage A register -----------------------------------------------------
    logic                        below_q1 [NUM_ELEMENTS];
    logic signed [VALUE_WIDTH:0] diff_q1  [NUM_ELEMENTS];
    logic                        accept_q1;
    logic [NUM_ELEMENTS - 1:0]   keep_q1;
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            accept_q1 <= 1'b0;
        end else begin
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                below_q1[i] <= below_a[i];
                diff_q1[i]  <= diff_a[i];
                keep_q1[i]  <= in.keep[i];
            end
            accept_q1 <= accept;
        end
    end

    // -- Stage B (comb): variable barrel shift + saturate to bin index --------
    logic [BIN_IDX_WIDTH - 1:0] lane_idx_b [NUM_ELEMENTS];
    always_comb begin
        logic [VALUE_WIDTH:0] shifted;
        for (int i = 0; i < NUM_ELEMENTS; i++) begin
            if (below_q1[i]) begin
                lane_idx_b[i] = '0;                                  // saturate low
            end else begin
                shifted = $unsigned(diff_q1[i]) >> bin_shift;        // diff >= 0 here
                if (shifted >= NUM_BINS)
                    lane_idx_b[i] = BIN_IDX_WIDTH'(NUM_BINS - 1);    // saturate high
                else
                    lane_idx_b[i] = shifted[BIN_IDX_WIDTH - 1:0];
            end
        end
    end

    // -- Stage B register (feeds the histogram BRAM address in g_bank) --------
    logic [BIN_IDX_WIDTH - 1:0] lane_idx_q [NUM_ELEMENTS];
    logic                       accept_q;
    logic [NUM_ELEMENTS - 1:0]  keep_q;
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            accept_q <= 1'b0;
        end else begin
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                lane_idx_q[i] <= lane_idx_b[i];
                keep_q[i]     <= keep_q1[i];
            end
            accept_q <= accept_q1;
        end
    end

    // -- Banked histogram store: collision-free via run coalescing -------------
    // The earlier version read-modified-wrote the BRAM for EVERY value. Two
    // consecutive values in the same bin then read AND wrote the same address in
    // one cycle -- a BRAM read/write collision that drops counts on silicon
    // (invisible to zero-delay sim, ~10% wandering loss), and it leaned on a
    // same-cycle forwarding bypass whose registers sat at marginal hold (+0.021 ns).
    //
    // Here each bank keeps the CURRENT bin's running count in registers (acc_*),
    // and the BRAM is touched only when the bin CHANGES (a "flush"): mem[bin]+=delta.
    // Because we only flush on a change, two consecutive flushes are ALWAYS different
    // bins, so every BRAM read that actually feeds a flush is collision-free (the
    // simultaneous write is the PREVIOUS flush -- a different bin), a repeated bin is
    // >=2 flushes apart (its earlier write has committed), and NO forwarding is needed
    // (so the +0.021 ns hold path is gone). flush_final (driven by the FSM drain)
    // pushes every bank's last run into the BRAM before the quartile scan reads it.
    logic flush_final;   // FSM pulse: commit each bank's pending run at end of pass-1
    for (genvar K = 0; K < NUM_ELEMENTS; K++) begin : g_bank
        // Force BRAM: at NUM_BINS=256 Vivado otherwise infers distributed LUTRAM
        // (~2.5k LUTs across 8 banks), which congests the fabric near the shell.
        (* ram_style = "block" *)
        logic [COUNT_WIDTH - 1:0]   mem [NUM_BINS];   // histogram bank (BRAM)
        logic [COUNT_WIDTH - 1:0]   rd_q;             // registered read data

        // Coalescing accumulator: the run currently being counted for this bank.
        logic [BIN_IDX_WIDTH - 1:0] acc_bin;
        logic [COUNT_WIDTH - 1:0]   acc_cnt;
        logic                       acc_valid = 1'b0; // power-up empty (no reset block -> BRAM)

        // Flush request (coalescing -> RMW pipeline register): add fl_delta to mem[fl_bin].
        logic                       fl_we = 1'b0;
        logic [BIN_IDX_WIDTH - 1:0] fl_bin;
        logic [COUNT_WIDTH - 1:0]   fl_delta;

        // RMW stage-1 (commit) registers.
        logic                       s1_we = 1'b0;
        logic [BIN_IDX_WIDTH - 1:0] s1_bin;
        logic [COUNT_WIDTH - 1:0]   s1_delta;

`ifdef IQR_BRAM_RAW_HAZARD_SIM
        // -- SIM-ONLY: model the silicon BRAM read-after-write hazard ----------------
        // Behavioural sim makes a write to mem[B] visible to a read of B on the very next
        // cycle, so it HIDES the hardware count-loss. Real registered BRAM does not: a read up
        // to HAZ_DEPTH cycles after the write returns the STALE (pre-write) value. The define's
        // VALUE sets the depth, so the test can sweep it to match the measured hardware loss
        // (1 ~= 5%, 2 ~= ~10%). Guarded -> NEVER in synthesis (the `else branch is the real RTL).
        localparam int              HAZ_DEPTH = `IQR_BRAM_RAW_HAZARD_SIM;
        logic                       haz_v [HAZ_DEPTH];   // recent-write valid (newest at [0])
        logic [BIN_IDX_WIDTH - 1:0] haz_b [HAZ_DEPTH];   // recent-write bin
        logic [COUNT_WIDTH - 1:0]   haz_s [HAZ_DEPTH];   // bin value BEFORE that write
        initial for (int j = 0; j < HAZ_DEPTH; j++) haz_v[j] = 1'b0;
`endif

        // Expose this bank's read data so the quartile scan can merge the banks.
        assign bank_q[K] = rd_q;

        logic beat;
        assign beat = accept_q && keep_q[K];   // a value for this bank this cycle

        // BRAM read address. In HISTOGRAM we read the bin being flushed (fl_bin) so
        // the RMW has its old value; when there is no flush the read is unused, so we
        // park it OFF the write address (~s1_bin) -- this guarantees the read never
        // shares an address with the write even on the unused cycles. In QUARTILES
        // every bank reads the shared scan address so the merge can sum them.
        logic [BIN_IDX_WIDTH - 1:0] raddr;
        assign raddr = (state == HISTOGRAM) ? (fl_we ? fl_bin : ~s1_bin) : q_raddr;

        // NOTE: memory read/write kept OUTSIDE any reset-conditional (Vivado refuses
        // ram_style=block otherwise, Synth 8-6849). No reset needed: acc_valid/fl_we/
        // s1_we power up 0, and the CLEAR phase (write priority) zeroes every bin
        // before any accumulation.
        always_ff @(posedge clk) begin
            // -- Coalescing front-end: accumulate same-bin runs, flush on change --
            fl_we <= 1'b0;                            // default: no flush this cycle
            if (clearing) begin
                acc_valid <= 1'b0;                    // banks being zeroed -> drop accumulation
            end else if (flush_final) begin
                // End of pass-1: push this bank's final run into the BRAM.
                fl_we     <= acc_valid;
                fl_bin    <= acc_bin;
                fl_delta  <= acc_cnt;
                acc_valid <= 1'b0;
            end else if (beat) begin
                if (acc_valid && (lane_idx_q[K] == acc_bin)) begin
                    acc_cnt <= acc_cnt + COUNT_WIDTH'(1'b1);   // same bin: register-only, no BRAM
                end else begin
                    fl_we     <= acc_valid;                    // bin changed: flush the old run
                    fl_bin    <= acc_bin;
                    fl_delta  <= acc_cnt;
                    acc_bin   <= lane_idx_q[K];                // and start a new one
                    acc_cnt   <= COUNT_WIDTH'(1'b1);
                    acc_valid <= 1'b1;
                end
            end

            // -- RMW: stage 0 read mem[fl_bin], stage 1 write mem[fl_bin] + delta --
`ifdef IQR_BRAM_RAW_HAZARD_SIM
            begin : haz_rd
                automatic logic                     hit = 1'b0;
                automatic logic [COUNT_WIDTH - 1:0] val = '0;
                // A bin read within HAZ_DEPTH cycles of its write sees the stale value -> its
                // increment is overwritten and lost, exactly like the silicon leak.
                for (int j = 0; j < HAZ_DEPTH; j++)
                    if (haz_v[j] && (raddr == haz_b[j])) begin hit = 1'b1; val = haz_s[j]; end
                rd_q <= hit ? val : mem[raddr];
            end
            // shift the recent-write history (capture pre-write value of this cycle's write)
            haz_v[0] <= s1_we && !clearing;
            haz_b[0] <= s1_bin;
            haz_s[0] <= mem[s1_bin];
            for (int j = 1; j < HAZ_DEPTH; j++) begin
                haz_v[j] <= haz_v[j-1];
                haz_b[j] <= haz_b[j-1];
                haz_s[j] <= haz_s[j-1];
            end
`else
            rd_q     <= mem[raddr];
`endif
            s1_we    <= fl_we;
            s1_bin   <= fl_bin;
            s1_delta <= fl_delta;

            if (clearing)
                mem[clear_addr] <= '0;
            else if (s1_we)
                mem[s1_bin] <= rd_q + s1_delta;
        end

        // -- Count-loss diagnostics for this bank (pure observation, NOT in the datapath) ----
        // Track the last DIAG_HAZ committed write bins. A flush that READS a bin written within
        // that window gets the stale (pre-write) value on real BRAM -> its add overwrites the
        // recent write and a count is lost. hazard_hit flags exactly that read.
        localparam int DIAG_HAZ = 2;
        logic                       w_hist_v [DIAG_HAZ];
        logic [BIN_IDX_WIDTH - 1:0] w_hist_b [DIAG_HAZ];
        logic                       hazard_hit;
        always_comb begin
            hazard_hit = 1'b0;
            if (fl_we)
                for (int j = 0; j < DIAG_HAZ; j++)
                    if (w_hist_v[j] && (fl_bin == w_hist_b[j])) hazard_hit = 1'b1;
        end

        logic [63:0] diag_committed;   // Σ delta this bank intended to write into its BRAM
        logic [63:0] diag_flushes;     // # BRAM writes (flushes) for this bank
        logic [63:0] diag_collisions;  // # flush-reads that hit a just-written bin (hazard)
        always_ff @(posedge clk) begin
            if (reset_synced == 1'b0) begin
                for (int j = 0; j < DIAG_HAZ; j++) w_hist_v[j] <= 1'b0;
                diag_committed  <= '0;
                diag_flushes    <= '0;
                diag_collisions <= '0;
            end else begin
                // Shift recent-write history (this cycle's BRAM write is s1_we -> mem[s1_bin]).
                w_hist_v[0] <= s1_we && !clearing;
                w_hist_b[0] <= s1_bin;
                for (int j = 1; j < DIAG_HAZ; j++) begin
                    w_hist_v[j] <= w_hist_v[j-1];
                    w_hist_b[j] <= w_hist_b[j-1];
                end
                if (clear_req) begin               // host re-arms before each run -> per-run counts
                    diag_committed  <= '0;
                    diag_flushes    <= '0;
                    diag_collisions <= '0;
                end else begin
                    if (s1_we && !clearing) begin
                        diag_committed <= diag_committed + 64'(s1_delta);
                        diag_flushes   <= diag_flushes   + 64'd1;
                    end
                    if (hazard_hit) diag_collisions <= diag_collisions + 64'd1;
                end
            end
        end
        assign bank_committed[K]  = diag_committed;
        assign bank_flushes[K]    = diag_flushes;
        assign bank_collisions[K] = diag_collisions;

`ifdef IQR_DEBUG_ILA
        // Live waveform of the BRAM read-modify-write on bank 0 -- captures the exact cycle a
        // flush reads a just-written bin (hazard_hit=1) so the count drop is observed, not guessed.
        // Probe widths MUST match hardware/src/init_ip.tcl.
        if (K == 0) begin : g_iqr_ila
            ila_iqr inst_ila_iqr (
                .clk    (clk),
                .probe0 (state),          // 2  : HISTOGRAM/QUARTILES/FLAG
                .probe1 (clearing),       // 1
                .probe2 (accept_q),       // 1  : a beat is being binned
                .probe3 (keep_q),         // 8  : NUM_ELEMENTS lane-valid
                .probe4 (lane_idx_q[0]),  // BIN_IDX_WIDTH : bin for this lane
                .probe5 (fl_we),          // 1  : flush requested (BRAM read for RMW)
                .probe6 (fl_bin),         // BIN_IDX_WIDTH
                .probe7 (fl_delta),       // COUNT_WIDTH
                .probe8 (s1_we),          // 1  : BRAM write commit
                .probe9 (s1_bin),         // BIN_IDX_WIDTH
                .probe10(s1_delta),       // COUNT_WIDTH
                .probe11(rd_q),           // COUNT_WIDTH : value read back for the RMW
                .probe12(hazard_hit)      // 1  : this flush read a just-written bin
            );
        end
`endif
    end

    // -- Count-loss diagnostics: input-accepted counter + bank sums (read via the CSR block) ---
    // dbg_accepted counts the values that actually entered binning in pass-1 (compare to N).
    // committed/flushes/collisions are the per-bank accumulators summed across all banks.
    logic [63:0] accepted_r;
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) accepted_r <= '0;
        else if (clear_req)       accepted_r <= '0;                       // per-run reset
        else if (accept_q)        accepted_r <= accepted_r + 64'($countones(keep_q));
    end

    logic [63:0] committed_sum, flushes_sum, collisions_sum;
    always_comb begin
        committed_sum  = '0;
        flushes_sum    = '0;
        collisions_sum = '0;
        for (int k = 0; k < NUM_ELEMENTS; k++) begin
            committed_sum  = committed_sum  + bank_committed[k];
            flushes_sum    = flushes_sum    + bank_flushes[k];
            collisions_sum = collisions_sum + bank_collisions[k];
        end
    end
    assign dbg_accepted   = accepted_r;
    assign dbg_committed  = committed_sum;
    assign dbg_flushes    = flushes_sum;
    assign dbg_collisions = collisions_sum;

    // -- Quartile-scan merge pipeline (timing) --------------------------------
    // The per-cycle quartile work -- the 8-way reduction of the bank counts, the
    // cumulative add, the *4 and the >=total / >=3*total compares -- became the
    // critical path once binning was pipelined. Split it: do the 8-way reduction
    // combinationally and REGISTER it (bin_total_q), so the cumulative add and the
    // compares run off a register the next cycle. This adds one more cycle of
    // read->merge latency, so the scan below skips scan_cnt 0 AND 1 (instead of
    // just 0), runs to NUM_BINS+1, and the located bin is scan_cnt-2 (instead of
    // -1). The scan runs once per dataset (~NUM_BINS cycles), so the extra latency
    // is free.
    logic [COUNT_WIDTH + 2:0] bin_total;     // 8-way sum of the banks for the bin read last cycle
    logic [COUNT_WIDTH + 2:0] bin_total_q;   // registered -> consumed by the FSM merge below
    always_comb begin
        bin_total = '0;
        for (int k = 0; k < NUM_ELEMENTS; k++)
            bin_total = bin_total + (COUNT_WIDTH + 3)'(bank_q[k]);
    end
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) bin_total_q <= '0;
        else                      bin_total_q <= bin_total;
    end

    // -- Control FSM ----------------------------------------------------------
    logic       last_seen;
    logic [2:0] drain_cnt;

    // One-cycle pulse during the end-of-pass drain that tells every g_bank to commit
    // its pending coalesced run to the BRAM. Timed so the last input beat has already
    // reached the coalescers (2-stage bin-index pipe) and so the resulting RMW commits
    // a couple cycles before the quartile scan starts (drain_cnt reaches 0).
    assign flush_final = (state == HISTOGRAM) && last_seen && (drain_cnt == 3'd5);

    always_ff @(posedge clk) begin
        logic [COUNT_WIDTH + 2:0]        cum4, tot1, tot3;
        logic [VALUE_WIDTH - 1:0]        q1v, q3v;
        logic signed [VALUE_WIDTH + 2:0] iqrv;
        logic signed [VALUE_WIDTH + 2:0] q1e, q3e;   // sign/zero-extended quartile values

        if (reset_synced == 1'b0) begin
            state             <= HISTOGRAM;
            clearing          <= 1'b1;   // clear the banks before first dataset
            clear_addr        <= '0;
            last_seen         <= 1'b0;
            drain_cnt         <= '0;
            q1_found          <= 1'b0;
            q3_found          <= 1'b0;
            clear_req_pending <= 1'b0;   // reset sweep is not a host clear -> no seq bump
            clear_seq         <= '0;
        end else if (clear_req) begin
            // Host requested a fresh start: re-arm the clear sweep from whatever state
            // the previous run left us in. Recovers cross-run residue at the process
            // boundary (the per-bank clear at clearing=1 zeroes every bin below).
            state             <= HISTOGRAM;
            clearing          <= 1'b1;
            clear_addr        <= '0;
            last_seen         <= 1'b0;
            drain_cnt         <= '0;
            q1_found          <= 1'b0;
            q3_found          <= 1'b0;
            clear_req_pending <= 1'b1;   // this sweep is host-requested -> bump seq on completion
        end else begin
            case (state)
                HISTOGRAM: begin
                    if (clearing) begin
                        // Sweep zeros across every bank, then open the input.
                        // (in.ready is held low by the combinational block.)
                        if (clear_addr == BIN_IDX_WIDTH'(NUM_BINS - 1)) begin
                            clearing <= 1'b0;
                            // Sweep done. If it was host-requested, signal completion so the
                            // host's poll releases and streams pass-1 into a guaranteed-zero,
                            // idle-ready core (no early beats consumed -> no lost counts).
                            if (clear_req_pending) begin
                                clear_seq         <= clear_seq + 1'b1;
                                clear_req_pending <= 1'b0;
                            end
                        end else begin
                            clear_addr <= clear_addr + 1'b1;
                        end
                    end else if (!last_seen) begin
                        // Bin until the terminating beat is consumed (in.ready is
                        // high in this phase, so consumed == valid).
                        if (in.valid && in.ready && in.last) begin
                            last_seen <= 1'b1;
                            // Drain: let the 2-stage bin-index pipe deliver the last beats to
                            // the coalescers, then flush_final (at drain_cnt==5) pushes every
                            // bank's final run into the BRAM, then the RMW commits -- all before
                            // the quartile scan reads the histogram.
                            drain_cnt <= 3'd7;
                        end
                    end else begin
                        // Drain the RMW pipeline before reading the histogram.
                        if (drain_cnt == 3'd0) begin
                            state      <= QUARTILES;
                            last_seen  <= 1'b0;
                            // Arm the quartile scan.
                            q_phase    <= Q_SUM;
                            scan_cnt   <= '0;
                            total      <= '0;
                            cumulative <= '0;
                            q1_found   <= 1'b0;
                            q3_found   <= 1'b0;
                        end else begin
                            drain_cnt <= drain_cnt - 3'd1;
                        end
                    end
                end

                QUARTILES: begin
                    if (q1_found && q3_found) begin
                        // Both quartiles located. Derive their values and the
                        // 1.5*IQR fences (1.5*IQR = IQR + IQR/2, no multiplier),
                        // then hand over to FLAG.
                        q1v  = bin_min + (VALUE_WIDTH'(q1_bin) << bin_shift);
                        q3v  = bin_min + (VALUE_WIDTH'(q3_bin) << bin_shift);

                        // Sign- or zero-extend the quartile values to the fence width
                        // (matching the flag compare), so signed windows work.
                        q1e  = is_signed ? $signed({{3{q1v[VALUE_WIDTH-1]}}, q1v}) : $signed({3'b0, q1v});
                        q3e  = is_signed ? $signed({{3{q3v[VALUE_WIDTH-1]}}, q3v}) : $signed({3'b0, q3v});
                        iqrv = q3e - q1e;

                        q1_val      <= q1v;
                        q3_val      <= q3v;
                        iqr_val     <= iqrv;
                        lower_fence <= q1e - iqrv - (iqrv >>> 1);
                        upper_fence <= q3e + iqrv + (iqrv >>> 1);

                        state <= FLAG;
                    end else begin
                        case (q_phase)
                            Q_SUM: begin
                                // Pass 1: grand total = sum of every bin.
                                // bin_total_q holds bin scan_cnt-2 (read + reduction latency),
                                // so accumulate bins 0..NUM_BINS-1 over scan_cnt 2..NUM_BINS+1.
                                if (scan_cnt >= 2)
                                    total <= total + bin_total_q[COUNT_WIDTH - 1:0];

                                if (scan_cnt == NUM_BINS + 1) begin
                                    q_phase  <= Q_SCAN;
                                    scan_cnt <= '0;
                                end else begin
                                    scan_cnt <= scan_cnt + 1'b1;
                                end
                            end

                            Q_SCAN: begin
                                // Pass 2: cumulative count locates the quartiles.
                                // Q1 = first bin with 4*cumulative >= total,
                                // Q3 = first bin with 4*cumulative >= 3*total.
                                // bin_total_q is bin scan_cnt-2, so the located bin is scan_cnt-2.
                                if (scan_cnt >= 2) begin
                                    cum4 = ((COUNT_WIDTH + 3)'(cumulative) + bin_total_q) << 2;
                                    tot1 = (COUNT_WIDTH + 3)'(total);
                                    tot3 = ((COUNT_WIDTH + 3)'(total) << 1) + (COUNT_WIDTH + 3)'(total);

                                    cumulative <= cumulative + bin_total_q[COUNT_WIDTH - 1:0];

                                    if (!q1_found && cum4 >= tot1) begin
                                        q1_found <= 1'b1;
                                        q1_bin   <= scan_cnt[BIN_IDX_WIDTH - 1:0] - 2'd2;
                                    end
                                    if (!q3_found && cum4 >= tot3) begin
                                        q3_found <= 1'b1;
                                        q3_bin   <= scan_cnt[BIN_IDX_WIDTH - 1:0] - 2'd2;
                                    end
                                end

                                if (scan_cnt != NUM_BINS + 1)
                                    scan_cnt <= scan_cnt + 1'b1;
                            end
                        endcase
                    end
                end

                FLAG: begin
                    // Pass 2: stream the column back out with the outlier mask
                    // (combinational passthrough below). Finish on the last beat
                    // actually transferred (in.ready == out.ready here).
                    if (in.valid && in.ready && in.last) begin
                        state      <= HISTOGRAM;
                        clearing   <= 1'b1;        // re-clear banks for next dataset
                        clear_addr <= '0;
                    end
                end
            endcase
        end
    end

    // -- Input ready ----------------------------------------------------------
    // Combinational so FLAG can backpressure straight from out.ready (zero-buffer
    // passthrough). HISTOGRAM accepts only in its binning phase; QUARTILES stalls.
    always_comb begin
        case (state)
            HISTOGRAM: in.ready = (!clearing) && (!last_seen);
            FLAG:      in.ready = out.ready;
            default:   in.ready = 1'b0;     // QUARTILES
        endcase
    end

    // -- Output (pass 2 flag column) ------------------------------------------
    // Idle outside FLAG. In FLAG we emit one flag per input element: 1 if the
    // element is an outlier (outside the [lower_fence, upper_fence] window), 0 if
    // normal. keep is passed through unchanged, so the stream stays dense (no
    // holes mid-beat) and the host receives a same-length 0/1 column aligned with
    // its input. The fences are signed; the value is sign-extended when is_signed
    // and zero-extended otherwise, so the compare matches the configured domain.
    always_comb begin
        logic signed [VALUE_WIDTH + 2:0] sval;
        logic                            is_outlier;

        // Default: idle.
        out.valid = 1'b0;
        out.last  = 1'b0;
        out.keep  = '0;
        out.data  = '0;

        if (state == FLAG) begin
            out.valid = in.valid;
            out.last  = in.last;
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                sval        = is_signed ? $signed({{3{in.data[i][VALUE_WIDTH-1]}}, in.data[i]})
                                        : $signed({3'b0, in.data[i]});
                is_outlier  = (sval < lower_fence) || (sval > upper_fence);
                out.data[i] = is_outlier ? value_t'(1) : value_t'(0);  // flag, not the value
                out.keep[i] = in.keep[i];                              // dense: no holes
            end
        end
    end

endmodule


// =================================================================================================
// FlagBitPacker
//
// Packs a per-element 0/1 flag stream into a dense bitmask: element e -> bit e (byte e/8, bit e%8),
// emitted as full OUT_W-bit beats (NUM_ELEMENTS x value_t); the final beat is zero-padded and
// carries last. Shrinks the host output transfer + readback by OUT_W/NUM_ELEMENTS (= 64x at 8x64):
// a 64 MB INT64 flag column becomes a 1 MB bitmask -- the readback was ~85% of the end-to-end time.
//
// Kept in this file (rather than its own) on purpose: it is only *reachable* through a
// `ifdef in the sim wrapper, and Vivado drops conditionally-unreachable files from the auto
// compile order. Living in the always-compiled DUT file guarantees it is in the library.
//
// Input  : in.data[i][0] = outlier flag for lane i, in.keep[i] = lane valid (only the final
//          beat is partial, since the column streams NUM_ELEMENTS-wide).
// =================================================================================================
module FlagBitPacker #(
    parameter type value_t,
    parameter      NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in,    // flags  : #(value_t, NUM_ELEMENTS)
    ndata_i.m out    // bitmask: #(value_t, NUM_ELEMENTS), full beats, last on the final beat
);

`RESET_RESYNC

    localparam int LANE_W = $bits(value_t);
    localparam int OUT_W  = NUM_ELEMENTS * LANE_W;       // bits per output beat (512)
    localparam int SLOTS  = OUT_W / NUM_ELEMENTS;        // input beats per output beat (64)
    localparam int SLOT_W = (SLOTS > 1) ? $clog2(SLOTS) : 1;

    logic [OUT_W - 1:0]  acc;          // bit accumulator for the current output word
    logic [SLOT_W - 1:0] slot;         // which NUM_ELEMENTS-bit group we fill next
    logic [OUT_W - 1:0]  out_word;     // registered output payload
    logic                out_valid_r;
    logic                out_last_r;

    // This beat's NUM_ELEMENTS flag bits (unkept lanes contribute 0).
    logic [NUM_ELEMENTS - 1:0] beat_bits;
    always_comb
        for (int i = 0; i < NUM_ELEMENTS; i++)
            beat_bits[i] = in.keep[i] & in.data[i][0];

    // acc with this beat's bits dropped into its slot.
    logic [OUT_W - 1:0] acc_next;
    always_comb begin
        acc_next                                      = acc;
        acc_next[slot * NUM_ELEMENTS +: NUM_ELEMENTS] = beat_bits;
    end

    // Accept input unless a completed beat is still waiting to be taken.
    assign in.ready = !out_valid_r || out.ready;

    wire fire      = in.valid && in.ready;
    wire last_slot = (slot == SLOT_W'(SLOTS - 1));
    wire emit      = fire && (last_slot || in.last);

    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            acc <= '0; slot <= '0; out_valid_r <= 1'b0; out_last_r <= 1'b0;
        end else begin
            if (out_valid_r && out.ready) out_valid_r <= 1'b0;  // previous beat consumed

            if (fire) begin
                if (emit) begin
                    out_word    <= acc_next;
                    out_valid_r <= 1'b1;
                    out_last_r  <= in.last;
                    acc         <= '0;
                    slot        <= '0;
                end else begin
                    acc  <= acc_next;
                    slot <= slot + 1'b1;
                end
            end
        end
    end

    always_comb begin
        for (int g = 0; g < NUM_ELEMENTS; g++)
            out.data[g] = out_word[g * LANE_W +: LANE_W];
        out.valid = out_valid_r;
        out.last  = out_last_r;
        out.keep  = '1;     // every emitted beat is a full word (final beat zero-padded)
    end

endmodule
