# IQR → Oasis Integration Playbook

How the IQR FPGA operator was integrated into oasis (DuckDB-callable), end to end.
Written 2026-06-28 after reaching validated-on-silicon. Read this first to resume the work.

---

## 0. The one-paragraph picture

**celeris** = a standalone FPGA query engine; operators are driven by hand-written C++ host
programs. **oasis** = a **DuckDB extension** that makes the same FPGA operators callable as plain
SQL (`SELECT * FROM iqr_flags('file.parquet','col')`). Moving IQR from celeris to oasis meant:
(1) drop the self-contained IQR RTL into oasis's production FPGA top as a co-resident lane,
(2) write an oasis host driver for it, (3) expose it as a DuckDB table function, (4) make the
parquet **decoder** feed it. The hardware computes the quartile fences itself; the CPU only sizes
the histogram window, pulses a clear, and reads back the packed flag bitmask.

---

## 1. Repo map — what each module does

```
oasis/
├── hardware/                         # the FPGA design (Coyote shell + our user logic)
│   ├── src/vfpga_top.svh             # THE production user-logic top. Wires: GlobalConfig (4 cfgs),
│   │                                 #   MemConfig, ColumnChunkDecoderConfig, ReadReqConfig, IqrConfig,
│   │                                 #   the decoder datapath, the IQR lane, OutputWriter.
│   ├── src/iqr_cosim_top.svh         # sim-only fallback top = production minus the decoder datapath
│   │                                 #   (kept in case the heavy decoder won't simulate; not needed now)
│   ├── src/hdl/common.sv             # oasis package params: OASIS_SYSTEM_ID, NUM_IQR_CONFIG_REGS, IQR_CONFIG_ID
│   ├── src/hdl/iqr_config.sv         # IqrConfig CSR block (HW): window in, profiler/debug out, clear pulse
│   ├── src/hdl/local_read.sv         # LocalRead: turns a host LOCAL_READ into byte-typed ndata
│   ├── iqr_app/hdl/IQR_detection.sv  # the IQR operator RTL (copy of celeris's; self-contained).
│   │                                 #   load_apps globs <dir>/hdl/* so it must live under an hdl/ subdir.
│   ├── CMakeLists.txt                # load_apps (which HDL dirs), N_DECODERS, FDEV_NAME, RDMA on/off
│   ├── build-sim/                    # simulation project (made by setup_simulation.sh)
│   └── build-NN/                     # bitstream build dirs (made by synthesize.sh)
│
├── software/oasis/                   # host runtime library = liboasis
│   ├── oasis_context.hpp/.cpp        # CENTRAL: cThread, config discovery, RDMA-vs-IQR detection,
│   │                                 #   interrupt routing (scheduler vs bypass receiver), scheduler,
│   │                                 #   bypass receiver. isIQRPresent()/iqrStream() live here.
│   ├── iqr_config.hpp                # CSR control panel for IQR (set window/signed, pulse clear, read debug)
│   ├── iqr_runner.hpp/.cpp           # the two-pass IQR driver (window -> clear -> stream x2 -> drain flags)
│   ├── bypass_receiver.hpp/.cpp      # FPGA-initiated output: acquire(size) enqueues buffers, next() drains
│   ├── scheduler.cpp                 # the normal decode pipeline runtime (QuerySplinter -> OperatorFlows)
│   ├── configuration.cpp            # GlobalConfig wrapper (config-ID discovery)
│   └── operator.cpp / query_splinter.hpp / splinter_result.hpp
│
├── extension/                        # the DuckDB extension
│   ├── src/oasis_iqr.cpp             # iqr_flags(path,col) TABLE FUNCTION: Bind (schema+type check),
│   │                                 #   decode the whole column (pipeline breaker), run IqrRunner, emit
│   ├── src/oasis_scan.cpp            # read_oasis (the streaming scan table function)
│   ├── src/coalesced_fetcher.cpp     # reads parquet bytes into FPGA-mappable buffers
│   ├── src/oasis_extension.cpp       # registers all functions
│   └── build/release/duckdb          # duckdb shell with the extension auto-loaded
│
├── parcore/   (submodule)            # shared FPGA data-processing core
│   ├── hardware/src/hdl/column_chunk_decoder.sv  # parquet column-chunk decoder
│   ├── hardware/src/hdl/vhsnunzip_wrapper.sv     # wraps the Snappy decompressor (the version-sensitive bit)
│   ├── libstf/  (submodule)          # low-level: streaming, config interfaces, memory pool, TLB, Coyote
│   │   └── coyote/                    # the Coyote shell (HW) + cThread driver (SW, real + sim variants)
│   └── vhsnunzip/ (submodule)        # Snappy decompressor (VHDL), pinned at 0fc61dd
│
├── celeris/   (submodule)            # where IQR_detection.sv came from
├── examples/iqr_sim/                 # our software-in-the-loop co-sim test (main.cpp + CMakeLists)
└── scripts/  setup_simulation.sh | synthesize.sh | install_arrow.sh
```

**Two libstf forks (important):** celeris has its own libstf (`package common`); parcore/oasis has
its own (`package libstf`). They are incompatible — you cannot include both. `IQR_detection.sv` was
written self-contained (only needs `ndata_i` + the `RESET_RESYNC` macro, both in parcore's libstf),
so it drops into oasis cleanly.

---

## 2. Architecture & data flow

**Config plane.** `GlobalConfig` (HW) advertises N config blocks; each block's register 0 is its
**ID**. The SW `GlobalConfig` reads `system_id` (reg 0), `num_configs` (reg 1), then each block's
ID, and `get_config<T>()` matches `T::ID`. Our top advertises **4**: MemConfig(ID 0),
ColumnChunkDecoderConfig, ReadReqConfig, IqrConfig(0x4951524445544354 = "IQRDETCT").
`ADDR_SPACE_SIZES` in `vfpga_top.svh` must list one size per block, in order.

**Data plane.** Host posts `LOCAL_READ` DMAs → `LocalRead` yields byte-typed `ndata` →
(decoder lane) `ColumnChunkDecoder`, or (IQR lane) reinterpret bytes as int64 → `IQR_detection`.
Output is **FPGA-initiated**: the host pre-enqueues an output buffer (`MemConfig`), the
`OutputWriter` fills it and raises a completion **interrupt** (the `notify` path). This is the key
difference from celeris (which used host `LOCAL_WRITE` + `checkCompleted`).

**Parquet decode is split CPU/FPGA — the heavy part is on the FPGA.** This is the whole reason the
accelerator exists: per-value decompress+decode is bit-twiddling work the FPGA is good at; the CPU
keeps only cheap, branchy metadata parsing.
- **CPU (light, structural):** `metadata.cpp` / `parcore_metadata_util.cpp` parse the Parquet footer
  (schema, row groups, where each column chunk's bytes live, codec, encodings); `coalesced_fetcher.cpp`
  reads the **raw still-compressed-and-encoded** column-chunk bytes into DMA buffers; host
  `column_chunk_decoder.cpp` only configures/feeds the hardware decoder (it doesn't decode values).
- **FPGA (heavy, per-value)**, in `parcore/hardware/src/hdl/`: `page_header_parser.sv` (page headers,
  moved off the CPU), `vhsnunzip_wrapper.sv` (Snappy decompression), `run_decoder.sv` /
  `expand_rle.sv` / `hybrid_page_decoder.sv` (RLE / bit-packing), `varint_decoder.sv` (varints),
  `TypedDictionary` (dictionary encoding) — all chained by `column_chunk_decoder.sv`
  (**raw bytes in → typed values out**, e.g. a stream of int64).

For IQR this means `iqr_flags` runs **decode + IQR** on the FPGA. The `iqr_sim` test fed **raw int64**
and bypassed the decoder, so the DuckDB run was the first time the **decode→IQR** path executed on
silicon. In this first version the decoded data still **round-trips through the host** before IQR
(the host streams it back twice); fusing decode→IQR on-chip is a later optimization.

**The IQR lane** is the "reserved last stream" past the decoders, present only in local mode
(`ifndef EN_RDMA`). In RDMA builds that slot is the RDMA bypass; in local IQR builds it's IQR — both
owned by the **bypass receiver**, told apart by whether `IqrConfig::ID` is advertised.
`NUM_DECODERS = NUM_STREAMS - 1`, `iqr_stream = num_decoders` (the last index).

**Two-pass IQR** (`IqrRunner::run`):
1. set window CSRs (`bin_min`/`bin_shift`, optionally auto-derived from an ~8192-row sample),
2. pulse `clear_histogram`, spin until `clear_seq` advances (fences the clear ahead of the DMA),
3. `bypass_receiver().acquire(out_bytes)` — enqueue the flag output buffer,
4. stream the column **twice** (pass 1 = histogram → HW derives Q1/Q3 fences; pass 2 = flag),
5. drain the flag buffer(s) via `handle->next()` (blocks on the completion interrupt).
Flags come back as a **packed bitmask** (1 bit/element, 64-byte beats) — element i = byte i/8, bit i%8.

---

## 3. The four workflows (exact commands)

### A. Simulation (software-in-the-loop co-sim)
```bash
module load vivado/2025.2
cd ~/oasis
./scripts/setup_simulation.sh                                   # builds hardware/build-sim
cp hardware/src/vfpga_top.svh hardware/build-sim/sim/vfpga_top.svh   # put PRODUCTION top in the sim slot
export PATH=$HOME/.local/bin:$PATH
cmake -S examples/iqr_sim -B examples/iqr_sim/build -DEN_SIMULATION=ON -DCMAKE_PREFIX_PATH=$HOME/opt
cmake --build examples/iqr_sim/build -j
COYOTE_SIM_DIR=$PWD/hardware/build-sim ./examples/iqr_sim/build/iqr_sim   # launches xsim, drives the RTL
```
Sim logs: `hardware/build-sim/sim/oasis.sim/sim_1/behav/xsim/{simulate,xvlog,elaborate}.log`.

### B. Bitstream (overnight)
```bash
cd ~/oasis
./scripts/synthesize.sh --no-rdma --device u55c --decoders 1     # --no-rdma is MANDATORY (IQR is ifndef EN_RDMA)
# detached in tmux; output: hardware/build-NN/bitstreams/cyt_top.bit; timing: build-NN/analysis.txt
```

### C. Hardware bring-up (on the U55C node, e.g. alveo-u55c-07)
```bash
hdev set hugepages --size 1G --pages 8
cd ~/oasis/parcore/libstf/coyote/driver && make           # builds build/coyote_driver.ko
cd ~/oasis
bash parcore/libstf/coyote/util/program_hacc_local.sh \
     hardware/build-01/bitstreams/cyt_top.bit \
     parcore/libstf/coyote/driver/build/coyote_driver.ko 1
lsmod | grep coyote_driver && ls /dev/coyote*             # verify
```

### D. DuckDB run (the product)
```bash
# rebuild+install oasis to ~/opt AND rebuild the extension after ANY oasis/parcore change (see gotcha 5)
cd ~/oasis && export PATH=$HOME/.local/bin:$PATH
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt
cmake --build software/build -j && cmake --install software/build
cmake --build extension/build/release -j
# run:
cd ~/oasis/extension/build/release && export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
./duckdb -c "SELECT * FROM iqr_flags('FILE.parquet','BIGINT_COL') LIMIT 20;"
```

---

## 4. Gotchas / war stories (each cost hours — don't re-pay)

1. **parcore must be current.** The full production design crashed xsim at t=0 (`std.sv` FATAL)
   because `ColumnChunkDecoder`/`vhsnunzip` wouldn't elaborate. Fix = parcore `564565a` (libstf
   `c3e6193`): `vhsnunzip_wrapper.sv` `DECOMP_DATA_BYTES` 16→8 (co_data width) + drop the
   `SPECULATIVE` generic absent in pinned vhsnunzip `0fc61dd`. Same bump unblocks the z-score op.
2. **Output model differs.** celeris pushes output with host `LOCAL_WRITE` + `checkCompleted`;
   oasis is FPGA-initiated (`bypass_receiver().acquire()` + `handle->next()`, completion via
   interrupt). The celeris pattern hangs forever in oasis.
3. **Interrupt routing.** `handle_interrupt` only routed the past-decoders stream to the bypass
   receiver when `rdma_enabled_`. IQR is local (rdma off) → added `|| iqr_present_`.
4. **Sim slot clobber.** The sim compiles `hardware/build-sim/sim/vfpga_top.svh` (it's `` `include``d
   into user_logic). The coyote_test unit-tests overwrite it with their per-test top. For the
   production co-sim you must re-copy `hardware/src/vfpga_top.svh` into that slot.
5. **The DuckDB extension links the INSTALLED oasis in `~/opt`, not source.** After any oasis/parcore
   change: rebuild + `cmake --install software` to `~/opt`, THEN rebuild `extension/build/release`.
   Stale symptom: `iqr_flags` throws "LocalSourceOperator cannot be used when RDMA is enabled"
   (old lib lacks `iqr_present_` → `rdma_enabled_ = num_streams(2)!=num_decoders(1) = true`).
   `examples/iqr_sim` builds from source so it's never stale — divergence between the two = stale ~/opt.
6. **`--no-rdma` is mandatory** for the bitstream or the IQR lane (ifndef EN_RDMA) is absent.
7. **Build env:** CMake ≥3.25 needed (`pip install --user "cmake>=3.28"`, `PATH=$HOME/.local/bin:$PATH`).
   jemalloc + the stack install under `~/opt` (`-DCMAKE_PREFIX_PATH=$HOME/opt`, `LD_LIBRARY_PATH=$HOME/opt/lib`).
   Build on hacc-build-02 (build server), run on the alveo node (shared home).
8. **Vivado:** `module load vivado/2025.2` (slash syntax). 2024.2 didn't help the t=0 crash; parcore did.

---

## 5. Validation results (2026-06-27/28)

| Stage | Result |
|---|---|
| Co-sim (software-in-the-loop) | PASS, 0 mismatches |
| Hardware `iqr_sim` (raw int64) | PASS, 0 mismatches (histogram_total 12/16 = benign count-loss) |
| DuckDB `iqr_flags` over parquet | runs on silicon |
| FPGA vs CPU, small data with outliers | 10 = 10 ✓ |
| FPGA vs CPU, 10M synthetic (cluster + 1000 outliers) | 1000 = 1000 ✓ exact, <1s |
| FPGA vs CPU, 21.3M huge.parquet (range 128→17e9, skewed) | 5.47M vs 3.87M — histogram resolution, not a bug |

**Count-loss (histogram_total < N):** benign for IQR — the quartile test uses a ratio
(`cum*4 >= total`), and the loss is proportional, so it cancels. histogram_total is debug-only.

**Wide-range accuracy:** on extreme-range skewed columns the 256-bin histogram resolves the
quartiles only to ~1 bin width, so the fence can be off and sweep millions of dense rows. Fixes
(cheapest first): log-transform the column in SQL before `iqr_flags`; or more NUM_BINS (re-synth);
or two-pass window refinement in `derive_window`.

---

## 6. Open / next steps

- Cross-check accuracy on a TPC-H column (`lineitem.l_quantity`); parcore/benchmarks has dbgen.
- Negative-value path on hardware (only covered in sim).
- Optional: log-transform wrapper so heavy-tailed columns match CPU.
- Optional: port celeris's histogram→BRAM restructure if histogram_total must read exactly N.
- Bitstream timing: WNS −0.127 (within −0.5 tolerance); failing paths are all vhsnunzip, none IQR.
```
```
