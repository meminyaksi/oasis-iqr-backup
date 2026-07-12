# IQR Timing-Optimization Plan (PLAN ONLY — not implemented)

Revert point: commit `1e83625`, tag **`iqr-preopt-checkpoint`** (local only — read-only push on
celeris-labs). To roll back: `git reset --hard iqr-preopt-checkpoint`.

Two workstreams: **(1)** add a hardware stream/cycle profiler to the IQR lane, **(2)** fuse the
decode pass and the histogram pass so the decoded data is histogrammed on-chip instead of being sent
back to the host and re-streamed. Do (1) first so we can *measure* the win from (2).

---

## Part 1 — Hardware performance counters on the IQR lane

**Key finding: the primitive already exists.** `StreamProfiler`
(`parcore/libstf/hardware/src/hdl/util/stream_profiler.sv`) taps any ready/valid stream (`last`,
`valid`, `ready`) and produces four 64-bit counters (`stream_profile_t` in
`parcore/libstf/hardware/src/hdl/common.sv`):

| counter | meaning | tells us |
|---|---|---|
| `handshakes_cycles` | `valid && ready` | productive cycles (data actually moving) |
| `starved_cycles` | `ready && !valid` | engine idle **waiting on upstream/host** (DMA/PCIe-bound) |
| `stalled_cycles` | `valid && !ready` | **back-pressured** — engine can't keep up (compute-bound) |
| `idle_cycles` | between streams | dead time between passes |

The **decoders already instrument this** (`column_chunk_decoder.sv` lines ~396–425 → exposed via
`ColumnChunkDecoderConfig` CSRs → host reads them; see `extension/src/oasis_profile.cpp`). The **IQR
lane has none**. So Part 1 is "do for IQR what the decoder already does."

### 1a. Stream profilers at the IQR I/O boundary (reuse)
Instantiate `StreamProfiler` in `vfpga_top.svh` (or inside `IQR_detection`) on:
- `iqr_in` (input) — covers *both* the histogram and flag input passes,
- `iqr_flags_nd` / `iqr_packed` (output) — the flag emission.

This tells us, per pass, whether we're **starved** (host can't feed fast enough → fusion is the fix)
or **stalled** (engine too slow → pipeline the datapath). Hypothesis to confirm: input is
**starved-bound** (round-trip/PCIe), which is exactly what Part 2 attacks.

### 1b. Internal FSM cycle counters (new, small)
The stream profiler sees only the I/O edge, not *where inside the engine* time goes. Add one
free-running 64-bit counter per `IQR_detection` state, incremented in the existing `always_ff`:
`clearing`, `HISTOGRAM`, `QUARTILES` (split `Q_SUM`/`Q_SCAN`), fence pipeline, `FLAG`. Confirms the
per-dataset scan cost (`QUARTILES` ≈ 2·NUM_BINS ≈ 2048 cyc) is negligible and the BRAM clear isn't
hiding cost.

### 1c. CSR readback (extend `IqrConfig`)
Bump `NUM_IQR_CONFIG_REGS`, add read regs for the 8 stream counters + ~6 state counters, mirroring
`ColumnChunkDecoderConfig`'s `values[...]` layout. Reset them on `clear_req` (same as the count-loss
diagnostics).

### 1d. Host surface
Add fields to `IqrRunner::Result` + getters on `iqr_config_`; read after the passes (before the next
clear). Print/return via the existing `oasis_profile.cpp` path (it already formats decoder profiles).
Report each pass as productive % / starved % / stalled %.

**Deliverable of Part 1:** a before/after cycle breakdown so the Part 2 win is quantified, not
asserted. Run it on the *current* bitstream first to capture the baseline.

---

## Part 2 — Fuse the decode pass and the histogram pass

### Current data flow (3 crossings of the decoded column)
Per `iqr_runner.cpp::run()` + `oasis_iqr.cpp::DecodeColumnAllGroups` + `vfpga_top.svh`:

1. **DECODE**: host → compressed parquet → decoder lane → decoded int64 → **back to host** (kept for
   the `value` output column of `iqr_flags`).
2. **HIST (pass 1)**: host decoded buffer → IQR-lane DMA → `IQR_detection` builds the histogram.
3. **FLAG (pass 2)**: host decoded buffer → IQR-lane DMA → `IQR_detection` emits packed flags → host.

The decoded column crosses PCIe **3×**: out(decode), in(hist), in(flag).

### Target: histogram *during* decode → drop the HIST crossing (3 → 2)
The decoded values are already on-chip at the end of step 1. Fork them into the histogram engine
before/while they DMA back to the host. New flow:

1. **DECODE + HIST fused**: decoder output → **fork** → { host value buffer, IQR histogram }.
   Histogram **accumulates across all row groups** (clear once, before group 0).
2. **FLAG**: host decoded buffer → IQR lane → flags → host. *Unchanged* — the flag pass needs the
   complete histogram (global quartiles), so a second read of the data is unavoidable here.

### The crux: window-derivation dependency (must resolve first)
Today `derive_window()` sets `bin_min`/`bin_shift` on the **host from a stride-sample of the DECODED
values** — i.e. *after* decode. Histogramming *during* decode needs the window *before* the data
flows. Options:

- **(A) Parquet metadata min/max — recommended default.** Column-chunk statistics (already parsed by
  `BuildParcoreMetadata`) carry per-chunk min/max. Aggregate → global `[min,max]` → derive
  `bin_min`/`bin_shift` with the same power-of-two logic as `derive_window`, but from the full range.
  Zero extra passes. **Trade-off:** full range is wider than the 1st/99th percentile → coarser bins →
  possibly more approximation error. Measure vs checkpoint (esp. taxi_d4, already window-sensitive).
  Fall back to (B) if stats absent or correctness regresses.
- **(B) Cheap pre-sample decode.** Decode just the first row group (or a page stride), derive the
  percentile window from it, then fused-decode the rest. Keeps the robust percentile window; adds a
  small partial decode.
- **(C) Adaptive/two-level histogram.** Coarse then refined. Too complex now — note as future.

Default to **(A)**, keep the current host `derive_window` as the fallback path.

### Hardware changes (`vfpga_top.svh`, minimal touch to `IQR_detection`)
- **Fork** the decoder output for the IQR target column into two consumers: the existing
  `NDataToAXI → OutputWriter` (host value buffer) **and** a new tap into the IQR engine. Reuse the
  existing data8→data64 regroup already on the IQR lane. Put a small **skid/FIFO** on the IQR tap so
  a momentary IQR stall doesn't throttle the decode→host DMA (histogram is ~1 beat/cyc, should keep
  up, but decouple to be safe).
- **Source MUX** in front of `IQR_detection.in`: `fused ? decoder_tap : iqr_lane_DMA`. Histogram pass
  uses the tap; FLAG pass uses the DMA (host re-streams the decoded column). A CSR bit (set by the
  runner) selects per pass. `IQR_detection`'s FSM (`HISTOGRAM→QUARTILES→FLAG`) is otherwise unchanged
  — only *where `in` comes from* changes.
- Keep the clear/`clear_seq` fence before the fused histogram (unchanged ordering guarantee).

### Software changes (`oasis_iqr.cpp`, `iqr_runner.cpp`, `iqr_config`)
- Compute the window from metadata stats up front; write `bin_min`/`bin_shift`; clear histogram; set
  MUX = fused **before** decoding group 0.
- `DecodeColumnAllGroups`: unchanged decode splinters, but the FPGA side now also histograms as the
  decoded beats pass through. After all groups, the histogram is complete.
- Split `IqrRunner::run()` → the histogram is built by decode (no dedicated pass); the runner does
  **only the FLAG pass** (one `stream_pass`) + drains flags. Add a `MUX`/mode CSR to `IqrConfig`.
- Keep the legacy 2-pass path behind the CSR default so we can A/B and revert instantly.

### Expected benefit
Removes **one of the two** decoded-column host→FPGA crossings on the IQR side (the histogram DMA).
Since the integrated path is round-trip/starved-bound (~100 M rows/s, flat with size — see
RESULTS.md §2), dropping a full-width pass should move the FPGA line toward / past 32-core exact on
the larger datasets. Part 1's profiler quantifies it.

### Risks / validation checklist
- **Fork backpressure / deadlock**: skid-FIFO on the IQR tap; verify decode→host DMA is never
  throttled below the histogram rate.
- **Correctness shift from stats-window (A)**: re-run `bench/correctness.sh`; compare disagreement
  ppm to the checkpoint, especially taxi_d4. If materially worse, switch to (B).
- **Cross-group accumulation**: clear the histogram **once** before group 0, never between groups;
  assert `dbg_total == N` after all groups.
- **Keep legacy path**: CSR default = current 2-pass so A/B and rollback are trivial.

### Sequencing
1. **Part 1** on the current bitstream → capture the baseline breakdown (confirm starved-bound).
2. **Part 2 (A)**: metadata window + HW fork/MUX + runner split. Build (`--no-rdma`), co-sim, silicon.
3. Re-run correctness + perf; compare to checkpoint; read the profiler delta.
4. If (A) hurts correctness → add **(B)** pre-sample window.

### Out of scope (future — Part 3)
Also removing the **FLAG** host→FPGA crossing by keeping the decoded column in on-card HBM and
re-reading it locally for the flag pass (2 → 1 host crossings). Bigger change (on-card buffer mgmt);
note and defer.
