# IQR × OASIS — Session Handoff

**Purpose:** Paste this into a new Claude chat to resume exactly where we left off. It captures the
project, the root-cause work already done, the current code state, and the pending next step.

**Date of handoff:** 2026-07-01
**Repo:** `celeris-labs/oasis` (checked out at `~/oasis`); companion `~/celeris` (`feature/mehmet`).
**Branch:** `feature/iqr-integration` (oasis). Last commit `fe6f7b6` (LUTRAM fix, validated on silicon).

---

## Operating constraints (DO NOT VIOLATE)

- **The USER runs all Vivado builds/sims/hardware tests.** Claude never launches bitgen or hw.
- **Build node:** `hacc-build-02` (has `/tools/Xilinx/2025.2`, 64 cores). **Flash/run node:** `alveo-u55c-07`. Shared home dir.
- **`--no-rdma` is MANDATORY** for the IQR bitstream.
- **Read-only push** on `celeris-labs`: commit locally, **do not push**.
- **`IQR_DEBUG_ILA` is synth-only** — it breaks xsim; keep it commented for co-sim.
- Don't use `huge.parquet` for reported results — use the **taxi** dataset.

## Build / sim / run cheatsheet

```bash
# --- bitgen (on hacc-build-02) ---
source /tools/Xilinx/2025.2/Vivado/settings64.sh && which vivado
cd ~/oasis
export PATH=$HOME/.local/bin:$PATH CMAKE_POLICY_VERSION_MINIMUM=3.5
./scripts/synthesize.sh --no-rdma --device u55c --decoders 1   # COMP_CORES defaults to 32 now
#   -> writes hardware/build-NN/ (auto-incremented), runs detached in a tmux session.

# --- co-sim (SW-in-the-loop, EN_SIMULATION) ---
#   IQR_DEBUG_ILA must be COMMENTED in IQR_detection.sv (line 9) or xsim breaks.
# --- iqr_sim on hardware ---
#   examples/iqr_sim now takes argv:  ./iqr_sim [N] [MOD]   (defaults N=8192, MOD=10)
#   Expect: histogram_total == N exactly; diagnostics accepted==committed==total==N, collisions==0.
```

---

## What the IQR operator does (mental model)

Two-pass outlier detector integrated as a co-resident lane in the OASIS vfpga_top, callable from
DuckDB via the extension. `NUM_BINS=1024`, `COUNT_WIDTH=32`, `bin_shift=0` so **bin == value**.

- **Pass 1 — HISTOGRAM:** BANKED, `NUM_ELEMENTS=8` banks (one per 64-bit lane of the 512-bit AXI beat).
  A coalescing front-end holds per-bank `acc_bin/acc_cnt/acc_valid`; BRAM is touched only on a bin
  CHANGE (a "flush"). RMW: stage0 reads `mem[fl_bin]→rd_q`; stage1 writes `mem[s1_bin]=rd_q+s1_delta`.
  Read is parked off the write address (`~s1_bin`) on non-flush cycles.
- **Drain:** `last_seen` starts `drain_cnt`; `flush_final` pulse commits each bank's pending run.
- **QUARTILES:** `Q_SUM` grand total → `Q_SCAN` cumulative → Q1/Q3 + 1.5×IQR fences. `SCAN_LAT=4`
  pipelined reduction (`bank_q → red1[4] → red2[2] → bin_total_q → total`).
- **Pass 2 — FLAG:** packed outlier bitmask (element i → byte i/8, bit i%8, LSB-first).
- State enum: `HISTOGRAM=0, QUARTILES=1, FLAG=2`. q_phase: `Q_SUM=0, Q_SCAN=1`.

**Diagnostic CSR counters (always present, NOT ILA):** `dbg_accepted, dbg_committed, dbg_flushes,
dbg_collisions`. The chain **N ≥ accepted ≥ committed ≥ total** localizes any count loss.

---

## THE BUG (fully root-caused) and THE FIX

**Symptom:** histogram lost ~3% (silicon) / ~10% (taxi) of counts. Per-write, proportional to write
count, **non-deterministic, STA-clean, collisions==0** — invisible to timing analysis and to the
logical hazard counter.

**Root cause:** `(* ram_style = "block" *)` on the bank memory was only half-honored. Vivado built
**banks 0–3 as LUTRAM (RAMD64E, async read → ZERO loss)** and **banks 4–7 as true-dual-port RAMB36
(synchronous read → read-during-write collision, [Synth 8-6430] → ~9% loss on those banks)**.

Evidence that nailed it (build-06, all-8-bank scan ILA + host counters + routed DCP):
- Per-bank totals `[128,128,128,128,116,117,116,117]` (only 4–7 short).
- `accepted=committed=flushes=1024, collisions=0, total=978`.
- Scaling: N=64→lost 2, 1024→lost 30, 8192→lost 302 (≈3%, proportional — refuted the earlier
  "drain-boundary" theory).
- Routed-DCP primitive query (`check_bank_prim.tcl`): `RAMB36E2: 8 / RAMD64E: 5120`.
- Synth log literally: banks 4–7 `[8-3971 TDP + 8-6430 collision]`; banks 0–3
  `[8-6849 infeasible ram_style=block → LUTRAM]`.

**THE FIX** (`hardware/iqr_app/hdl/IQR_detection.sv`, ~line 243):
```systemverilog
(* ram_style = "distributed" *)  // was "block"; forces all 8 banks to LUTRAM (proven-good, async read)
logic [COUNT_WIDTH - 1:0] mem [NUM_BINS];
```

**FIX VALIDATED ON SILICON (build-07):**
- `iqr_sim` → `total == 8192` exactly (was 7890).
- Distributed RAM Final Mapping: all 8 banks `RAM64M8`.
- Taxi via DuckDB: `d1=317554` (= 1024-bin model), `d3` within 0.01% of CPU-exact; `d4=2112164`
  over-counts vs CPU-exact = histogram **bin-resolution tail effect**, NOT loss.
- Committed `fe6f7b6`.

---

## Current code state (uncommitted vs fe6f7b6 = the "lean production" prep)

Goal for the NEXT build (build-08): **remove all the debug ILAs we added** and rebuild a lean
production bitstream. Edits already made toward this:

- **`hardware/iqr_app/hdl/IQR_detection.sv`:**
  - Line 9: `IQR_DEBUG_ILA` define **COMMENTED OUT** (ILAs off for production).
  - Line ~243: the `ram_style="distributed"` FIX (keep — this is the real fix).
  - ILA instances (`ila_iqr`, `ila_iqr_rmw`) and `wdata_dbg` tap are all under `ifdef IQR_DEBUG_ILA`,
    so commenting the define disables them.
  - Harmless leftover from a superseded hypothesis (safe to leave): `drain_cnt` widened to [3:0],
    `DRAIN_START=12`, `DRAIN_FLUSH=DRAIN_START-2`.
- **`hardware/src/init_ip.tcl`:** still creates `ila_iqr`/`ila_iqr_rmw` IP unconditionally. That's
  **harmless when the define is off** (unused IP, same pattern as `ila_rdma_read`). Can leave as-is,
  or clean up if you want a truly minimal project.
- **`examples/iqr_sim/src/main.cpp`:** dataset is argv-configurable — `./iqr_sim [N] [MOD]`.
- **`scripts/synthesize.sh`:** added `--cores N` option; **`COMP_CORES` now defaults to 32**.

### bitgen speed note (answered last)
`COMP_CORES` → `launch_runs -jobs N` speeds only the **parallel synthesis phase** (the ~20+ IP/OOC
synth runs). **Place & route is a single run capped at ~8 internal Vivado threads** and is NOT sped
by COMP_CORES, so total speedup from 8→32 is modest (~15–25%). The bigger real win is removing the
ILAs (less to place/route + one fewer big OOC synth). A deeper P&R lever (`set_param
general.maxThreads`) lives in the parcore submodule's `base.tcl.in` and gives little — skip it.

---

## PENDING NEXT STEP

1. **User kicks off build-08** (lean, ILAs off):
   ```bash
   ./scripts/synthesize.sh --no-rdma --device u55c --decoders 1   # 32 cores by default
   ```
2. After build-08 flashes: re-validate `iqr_sim` `total==8192`, re-run taxi via DuckDB, re-baseline
   `IQR_RESULTS.md`.
3. (Optional, undecided) Strip the `dbg_*` CSR counters for a truly minimal interface — but they're
   cheap and useful; **recommendation: keep them.** Changing them alters the host interface.

---

## Key files (paths)

- Operator RTL: `hardware/iqr_app/hdl/IQR_detection.sv`
- IP creation TCL: `hardware/src/init_ip.tcl`
- Build script: `scripts/synthesize.sh`
- SW driver (sim/hw): `examples/iqr_sim/src/main.cpp`
- Routed-DCP diagnostics: `hardware/check_bank_prim.tcl` (the decisive one) + `check_bank_{slr,slr2,sites,dist}.tcl`
- ILA capture: `hardware/ila_capture.tcl` (both ILAs), `hardware/ila_capture_b06_scan.tcl` (scan-only)
- Playbook (full resume doc): `~/oasis/IQR_OASIS_PLAYBOOK.md`
- Claude memory: `~/.claude/projects/-home-myaksi-celeris/memory/iqr-oasis-integration-status.md`
