# IQR-on-Oasis — session handoff (continue here)

**Read first, in this order:** `IQR_OASIS_PLAYBOOK.md` (repo map, 4 workflows, 10 gotchas),
`IQR_RESULTS.md` (silicon results), then this file (the live state + what's next). Memory files
under `~/.claude/.../memory/` (`iqr-oasis-integration-status.md`, `oasis-integration-playbook.md`,
`coyote-celeris-system-guide.md`, `celeris-modules-and-hardware-lessons.md`) hold the deeper history
— don't re-derive what's already there.

## Working style (how the previous session ran)
- **User runs ALL Vivado builds, sims, hardware tests** on the cluster. You provide commands + do
  code edits + software/Python analysis. User has read-only push on celeris-labs → works local.
- **Shared filesystem:** you can directly read/inspect the user's repo + outputs under
  `/home/myaksi/oasis` and `/home/myaksi/celeris` and `~` (e.g. read `build-NN/analysis.txt`,
  bitgen logs, ILA CSVs) — use that instead of guessing.
- **Two nodes, shared home:** build on **hacc-build-02**, run/flash on **alveo-u55c-07**.
- Be concise, command-first. Confirm before destructive/outward actions.

## Where things stand (branch `feature/iqr-integration`, HEAD `40e7263`)
1. **IQR integrated into oasis** (decode→IQR, `SELECT * FROM iqr_flags('file.parquet','col')`),
   validated on silicon. Co-resident lane in `hardware/src/vfpga_top.svh` (local mode, `--no-rdma`).
2. **NUM_BINS 256→1024** (commit `c0b5213`): accuracy vs CPU-exact **97% → 99.6%**, CONFIRMED on
   silicon (taxi/fare: fpga 317,554 vs cpu 318,801).
3. **Count-loss root-caused.** Host diagnostics (4 CSR counters: accepted/committed/flushes/
   collisions) + a full-lifecycle ILA proved: histogram is written correctly (`committed==16`
   deterministic), but `total` read back low (`13/16`) because the **8-way bank-sum (`bin_total_q`)
   + fence math FAIL SETUP** (WNS −0.430) — a measurement/readback timing bug, NOT a write loss,
   NOT the long-assumed BRAM hazard (`collisions=0`). (Timing report: failing paths are all in
   `bin_total_q_reg/D`, `upper/lower_fence`, `rd_q` — the readback chain.)
4. **THE FIX (commit `40e7263`, validated in co-sim: `total=16`, 0 mismatches):**
   - Pipelined the 8-way reduction into 3 single-level adder stages (`red1→red2→bin_total_q`);
     read→merge latency 2→`SCAN_LAT=4`; Q_SUM/Q_SCAN skip `scan_cnt<SCAN_LAT`, run to
     `NUM_BINS+SCAN_LAT-1`, locate bin at `scan_cnt-SCAN_LAT`.
   - Pipelined the once-per-dataset fence math across 4 registered steps (`fence_step`).
   - Reworked the ILA (`ila_iqr`, 20 probes, module scope) to trace the full life of `total`:
     `bank_q → red1 → red2 → bin_total_q → total → dbg_total` + quartiles/fences/context.
   - Files: `hardware/iqr_app/hdl/IQR_detection.sv`, `hardware/src/init_ip.tcl`.

## IMMEDIATE NEXT STEP: build & validate the fix on silicon
The fix passed co-sim; the **pending action is the bitstream `build-04` and the hardware re-test.**
Full copy-paste command sheet is in the previous chat, and the workflows are in
`IQR_OASIS_PLAYBOOK.md §3`. Summary:
1. **Bitgen** (hacc-build-02): `export PATH=$HOME/.local/bin:$PATH CMAKE_POLICY_VERSION_MINIMUM=3.5`
   then `./scripts/synthesize.sh --no-rdma --device u55c --decoders 1` → `hardware/build-04/...`.
2. **Flash** (alveo-u55c-07): playbook §C, pointing at `build-04`.
3. **Win condition — Test 1:** rebuild `iqr_sim` in **hardware** mode (NO `-DEN_SIMULATION`), run it
   on the FPGA → **`total` should now read 16** (was 13). That confirms the fix on silicon.
4. **Test 2:** DuckDB `iqr_flags` on `~/datasets/taxi_d1.parquet`/`fare_cents` → ~317,554 (99.6%).
5. **ILA** (`build-04/bitstreams/cyt_top.ltx`): trigger on `state==QUARTILES` to watch `total`
   accumulate to 16. (ILA usage: playbook + previous chat; `~/oasis/hardware/ila_capture.tcl`.)

## CRITICAL gotchas that cost hours (don't re-pay — details in PLAYBOOK gotchas 1–10)
- **CMake 4.x breaks the Coyote build** (`cmake_minimum_required < 3.5`). `~/.local/bin/cmake`=4.3.4,
  `/usr/bin/cmake`=3.22 (too old). **Always `export CMAKE_POLICY_VERSION_MINIMUM=3.5`** before any
  `cmake`/`synthesize.sh`. (Proper fix later: `pip install --user "cmake>=3.28,<4"`.)
- **`iqr_sim` needs `vivado` on PATH; `make sim`/`synthesize.sh` use it from PATH too.** If the
  module isn't loaded, the co-sim silently returns instant garbage. Gate on `which vivado`
  (`source /tools/Xilinx/Vivado/2024.2/settings64.sh` or the module). hacc-build-02 has 2025.2.
- **`-DEN_SIMULATION=ON` → co-sim** (SimpleMemoryPool, no hugepages, needs `COYOTE_SIM_DIR`);
  **omit it → hardware** (HugePageMemoryPool, needs flashed FPGA + `hdev set hugepages`). Mixing
  them = the "0 free 1GiB huge pages" abort or an instant-garbage run.
- **Vivado won't recompile an `\`include`d file:** after editing IQR RTL or copying the top into the
  sim slot, `rm -rf hardware/build-sim/sim/{xsim.dir,coyote_sim.so}` before `make -C ... sim`.
- **ILA (`\`define IQR_DEBUG_ILA` in IQR_detection.sv) is synth-only — breaks xsim.** Comment it for
  co-sim, uncomment for bitgen. Currently **ON** (bitgen-ready, HEAD `40e7263`).
- **DuckDB extension links INSTALLED `~/opt` oasis:** after any oasis/parcore change, rebuild +
  `cmake --install software` to `~/opt`, THEN rebuild `extension/build/release`.
- **`--no-rdma` is mandatory** for the IQR bitstream (IQR lane is `ifndef EN_RDMA`).
- **In Vivado Tcl, `~` does NOT expand** — use absolute paths. Run `iqr_sim` in a *bash* shell, ILA
  `run/wait_on_hw_ila` in the *Vivado* shell (two shells).

## Recovery points
- Known-good **256-bin** bitstream archived: `~/bitstream-archive/iqr-256bin-silicon-validated/`
  (+MANIFEST). Source: git tag `iqr-256bin-silicon-validated`.
- This 1024 + fix + ILA: HEAD `40e7263`.

## Open / next ideas (not blocking)
- After Test 1 confirms `total=16`: archive `build-04` bitstream, update `IQR_RESULTS.md` with the
  fixed-sum silicon result, and (if desired) drop the diagnostics/ILA for a lean production build.
- z-score operator: a colleague is porting it the same way (see memory
  `celeris-modules-and-hardware-lessons` / playbook gotcha 1 for the parcore/vhsnunzip fix).
