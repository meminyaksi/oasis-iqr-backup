# RESUME DOC — IQR FPGA vs CPU (updated 2026-07-23, after the build-15 hang + fix)

**Read this first after a compact.** Authoritative numbers: `bench/RESULTS.md` §9 (§9.1–§9.18).
This file is state + next actions.

> **NEWEST FIRST (2026-07-23, ~01:00):** build-15 flashed but **HUNG the decoder** — a fused query
> sat silent until `timeout` with no error. Root cause: an arbiter bug in `IqrHistogramFeed`
> (payload from last cycle's lane while `valid` followed *any* lane → early `last` → deadlock). Fixed
> + proved with TWO standalone xsim testbenches (feed alone, and feed→mux→IQR_detection connected).
> **build-16 is rebuilding on hacc-build-02 with the fix** (started 00:37, RTL on disk 00:00, so the
> fix IS in it — verified). Also: the fused-pass-1 poll now times out in 10 s of wall clock instead
> of ~200 s of spins, so a future stall reports instead of hanging. Full detail in §6. **When
> build-16 lands, validate exactly as §6 — do NOT reuse build-15.**

---

## 0. Status in one paragraph

The supervisor's critique ("your CPU baseline is a SQL query, so you're measuring DuckDB") was fixed
long ago: `iqr_cpu_flags()` is a C++ CPU operator, bit-exact with the SQL on 118 M rows. Since then
**two of our own benchmark defects were found and fixed, both of which had flattered the FPGA**
(§9.18). Against the corrected baseline the FPGA **wins 4 of 7 datasets on wall clock, not 7 of 7**,
and the mechanism is a clean **crossover at ~10 M rows**. Host CPU-seconds (2.07–6.07×) survived
every change and is the study's most defensible claim. The remaining wall-clock gap is a **bus
limit** — the FPGA reads at 12.5 GB/s over PCIe, the CPU at 63 GB/s from DRAM. Card memory was
disqualified as a workaround (8 MB/s). The current work removes the redundant PCIe traffic instead:
**RTL fuses IQR pass 1 into decode. build-15 hung (arbiter bug, now fixed + sim-proved); build-16
is rebuilding with the fix — see the banner at the top and §6.**

---

## 1. Environment — the gotchas that cost time

| thing | rule |
|---|---|
| **Build node** | `hacc-build-02` — 64 cores, 376 GB. All Vivado builds. `free -g`: 376 = build node, 62 = alveo. |
| **Bench node** | `alveo-u55c-10` (used for all of §9.13–§9.18). `-07` also works but had a wedge. |
| **Never build on alveo** | Two Vivado runs wedged it (sshd died on memory pressure). |
| **Vivado** | `module load vivado/2024.2` **before** `synthesize.sh`. |
| **CLI target** | `cmake --build extension/build/release --target shell` — `--target duckdb` builds the .so and leaves the binary **stale**. Check its mtime. |
| **`~/opt` is stale-prone** | The extension compiles against `~/opt/include/oasis/*`. After editing `software/oasis/*`: rebuild `software/build`, `cmake --install .`, **then** rebuild the shell. |
| **Runtime** | `export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH`. |
| **Huge pages** | `echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`, **after** any reprogram (it clears them). `hdev set hugepages` is a silent no-op. |
| **NEVER Ctrl-C an FPGA query** | It leaves pinned pages + enqueued buffers; Coyote has no inter-process reset and the node may need a reboot. Use `timeout`. |
| **tmux** | detach = `Ctrl-b` then `d`. `Ctrl-C` goes to Vivado and cancels the run. |
| **Home is NFS-shared** | `~/oasis` identical on all nodes; only processes are per-node. |

---

## 2. THE RESULT (medians of 15, `--consume`, build-14, streaming, overlap+fuse off)

Two benchmark defects were fixed on 2026-07-22 (§9.18); **all earlier end-to-end numbers are void**:

1. **`medians.py` timed `CREATE TABLE`**, and 92 % of that is DuckDB's single-threaded table append
   (438 ms of 647 ms on sf10) — a big constant added to *both* sides that dragged every ratio to 1.0.
   Producing the flags costs only 38 ms. → `medians.py --consume` aggregates instead.
2. **The C++ baseline freed its column with `new[]`** outside DuckDB, so releasing 457.7 MB landed
   after the `heavy` timer as CPU-side "tax" (up to 27 ms). → `Allocator::Get(context).Allocate()`.

| dataset | rows | FPGA | C++ | e2e | operator | CPU-work |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 0.012 | 0.019 | **1.58×** | **1.97×** | 3.03× |
| taxi_d2 | 6.0M | 0.018 | 0.023 | **1.28×** | **1.35×** | 3.64× |
| tpch_qty | 6.0M | 0.018 | 0.019 | 1.06× | 1.11× | 3.12× |
| extprice | 6.0M | 0.025 | 0.026 | 1.04× | 1.09× | 4.26× |
| taxi_d3 | 13.1M | 0.040 | 0.032 | **0.80×** | 0.80× | 2.07× |
| taxi_d4 | 20.3M | 0.058 | 0.044 | **0.76×** | 0.77× | 2.20× |
| sf10 | 60.0M | 0.181 | 0.159 | **0.88×** | 0.58× | **6.07×** |

**Report BOTH benchmarks.** `--consume` isolates the operators; the default (`CREATE TABLE`) is what
a user typing SQL experiences. Quoting only one invites a fair objection either way.

### Why: a crossover at ~10 M rows (operator ms per Mrow)

| | 3.0M | 6.0M | 13.1M | 20.3M | 60.0M |
|---|--:|--:|--:|--:|--:|
| FPGA | 2.74 | 2.28 | 2.53 | 2.42 | 2.81 |
| CPU | **5.37** | 2.52–3.68 | **2.03** | **1.87** | **1.63** |

**FPGA cost per row is flat at every scale; the CPU's falls as its ~13 ms fixed startup (32 threads,
allocation) amortises.** ≤6 M rows the FPGA wins, ≥13 M it loses. Encoding (PLAIN vs dictionary) is
secondary, worth 20–40 % — **earlier sections overstated it; size is the driver.**

---

## 3. Correctness gates

```bash
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
cd ~/oasis && ./extension/build/release/duckdb < bench/sql/cpu_op_correctness.sql
```

| dataset | n_fpga | fpga_vs_cpp | cpp_vs_sql |
|---|--:|--:|--:|
| taxi_d1 | 317554 | 1247 | **0** |
| taxi_d2 | 625445 | 2877 | **0** |
| taxi_d3 | 1328108 | 162 | **0** |
| taxi_d4 | 2112164 | 54921 | **0** |
| tpch × 3 | 0 | 0 | **0** |

- **TRAP:** the tpch sets have zero outliers by nature and taxi_d2/d3/d4 mostly use the memcpy sink,
  so this suite is **structurally blind** to anything touching the histogram window. It caught
  nothing when a prefix window flagged 20 M of 20 M rows.
- **The real window gate** is `bench/overlap_ab.sh accuracy` → `ov_uniform` and `ov_drift` must both
  return **200**. `ov_drift` (values rise with row order) is the adversarial case. Build them once
  with `bench/overlap_ab.sh gen`.
- With overlap enabled taxi_d2 legitimately shifts to 2617 (better). Restate the gate if so.

---

## 4. Where the time goes (sf10, measured, §9.16)

```
FPGA heavy 169.7 = decode 92.8 (fetch 38.5 | submit 19.9 | fpga_wait 30.1) + passes 76.6
CPU  heavy  91.7 = read 58.9 + quart 25.2 + flags 7.6
```

| phase | CPU | FPGA | |
|---|--:|--:|---|
| decode / read | 58.9 | 92.8 | CPU 1.6× |
| quartiles | 25.2 | 38.3 | CPU 1.5× |
| flags | 7.6 | 38.3 | **CPU 5.1×** |

**The flags row is the whole architecture.** Comparing 60 M values to two constants takes the CPU
7.6 ms and the FPGA 38.3 ms — because the FPGA must ship 457.7 MB across PCIe to look at them.
**FPGA 12.5 GB/s (PCIe Gen3 x16) vs CPU 63 GB/s (DRAM).** Every phase touching the raw column is
~5× handicapped before any computation. The IQR core itself is never the limit: its profiler shows
`stalled = 0.0 %`, `starved = 21.4 %`.

**PCIe traffic today: 1676 MB to produce 7.3 MB of flags.** The decoded column crosses the bus three
times (decoder→host, then host→FPGA twice) because `vfpga_top.svh` wires the decoder lanes and the
IQR lane as separate streams that never meet on-chip.

---

## 5. Dead ends — do not re-attempt

| thing | evidence |
|---|---|
| **Card memory / HBM** | `use_card` = **8 MB/s**, a size-independent **~1548×** penalty on the READ path (§9.17). Fixed per-request cost, not slow memory. sf10 can't even be staged: Coyote caps `invoke` at 128 MB. **The RTL card datapath is now deleted.** |
| **Prefix-derived histogram window** | Flagged **19,997,999 of 20 M rows** vs a true 200 on order-drifting data (§9.15). |
| **Footer min/max as the window** | taxi_d4 spans −128540..33407632 → 1024 bins are 32768 wide while fares live in 0..5000. Everything lands in bin 0 ⇒ q1 = q3 ⇒ degenerate. A percentile over per-group extremes fails too (outliers are in nearly every group). |
| **Host prefetch pool** | No-op, +7 % CPU (§9.11). |
| **`DECODE_WINDOW` tuning** | Flat within 1.5 % from 8 to 32 (§9.14.3). Keep 16. |
| **`OASIS_IQR_OVERLAP` (software)** | Correct after `DeriveWindowSpanning`, but the window costs ~18 ms/query → **net loss below ~40 M rows; 6 of 7 datasets got slower.** Superseded by the RTL fusion. Keep OFF. |

---

## 6. IN FLIGHT — build-16, the fused-pass-1 bitstream (build-15 hung; fixed)

**build-15 hung the decoder on silicon.** Flashed fine, `decoder_profiler` returned 0–3, but a fused
query sat SILENT until `timeout` — no error at all. **build-15 is dead; use build-16.**
`git reset --hard pre-rtl-fusion` reverts the whole fusion line if ever needed.

**The bug (in `iqr_histogram_feed.sv`).** The arbiter drove `out.valid` off `any_head` (ANY lane has
a beat) while the payload came from `sk_data[grant]` — last cycle's winner, i.e. the lane that just
ran dry. When that lane emptied while another had data, it asserted valid over an empty slot; garbage
`keep` bits inflated the element count, `fed` overshot `hist_expected`, `last` fired early, the core
left HISTOGRAM, the top's mux parked the feed's ready at 0, the skids filled, and the tee **stopped
the decoder**. The host never reached `finish_fused`, so its `histogram_total==N` check never ran —
hence silent. **Invisible at N_LANES=1** (`grant` always 0), which is why nothing caught it before.

**The fix (commits `9e5592d`, `4b7339e`, `01e1632`, `2db6c41`):**
- drive `out.data/keep` and `pop` from **`next_grant`** (the lane selected *this* cycle), not `grant`.
- **safety valve:** hold `o_ready` high once `done` and drop late beats — so any *future* miscount is
  a `histogram_total != N` error (which the host reads in 10 s) instead of a deadlocked decoder.
- `beat_elems` now counts off the skid slot, not `out.keep` (that was a circular comb dependency that
  xsim resolved to X); explicit keep-sum instead of `$countones` (returned X here).
- `IqrRunner::finish_fused` poll is now a **10 s wall-clock deadline**, not 200 M spins (~200 s) —
  each `feed_done()` is a PCIe MMIO read, so the old budget always outlived the query's `timeout`,
  which is *why build-15 presented as a pure hang with nothing printed*.

**PROVEN IN SIM (both run in seconds; need `module load vivado/2024.2`):**
- `hardware/unit-tests/run_feed_tb.sh` — feed alone, 4 lanes at uneven rates. 5 scenarios pass;
  all 5 FAIL with DUPLICATE EMISSION when the fix is reverted, so it demonstrably catches the bug.
- `hardware/unit-tests/run_fused_integration_tb.sh` — feed→mux→IQR_detection connected (the seam no
  prior test touched), real two-pass flow vs a reference: `dbg_total==N`, 96/96 flags bit-exact, mux
  switches correctly. Inverting the mux's `take_feed` deadlocks it → TIMEOUT, so it has teeth.
- **Sim can't reach:** CSR-vs-DMA ordering / the clear fence, and −0.4 ns timing closure. Those are
  what the morning gates below settle.

**build-16 has the fix — verified:** `iqr_histogram_feed.sv` mtime 00:00 < build-16 start 00:37, and
the on-disk file has `next_grant][0]` ×3 + the safety valve. Watch: `scripts/util/watch_build.sh -w`.

**What fusion does (unchanged):** the decoder output is TEE'd on-chip into the IQR histogram, so pass
1 runs *during* decode and never crosses PCIe. Pass 2 is untouched (needs final Q1/Q3). Register map:
`IqrConfig` +`fuse_enable`(5) +`hist_expected`(6) +`fed_elements`(15) +`feed_done`(16),
`NUM_IQR_CONFIG_REGS` 17. `OASIS_IQR_FUSE=1`, off by default; works with either sink.

**Target: `heavy` ~150 ms vs today's 169.7.** Do NOT validate against 131 — that figure (§9.15) used
the *free prefix* window (wrong answers). The correct spanning window costs ~18 ms, which build-16
pays too: `169.7 − 38 (pass 1 deleted) + 18 (window) ≈ 150`. ~150 = RTL right; 169 = fuse never
engaged. The window tax is why fusion only pays above ~20 M rows — the §8.1b follow-up removes it.

### When build-16 finishes

```bash
head -12 ~/oasis/hardware/build-16/analysis.txt          # WNS negative is OK (build-14 shipped -0.773)
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
cd ~/oasis && bash parcore/libstf/coyote/util/program_hacc_local.sh \
  hardware/build-16/bitstreams/cyt_top.bit parcore/libstf/coyote/driver/build/coyote_driver.ko 1
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages   # reprogram clears them
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
cd ~/oasis && timeout 60 ./extension/build/release/duckdb -c "SELECT decoder FROM decoder_profiler();"
```

Then, in order (leave `OASIS_IQR_WINDOW_FPGA` UNSET — validate the RTL against the trusted window):
```bash
# 1. does it engage and hit the target?  look for pass1=fused and heavy ~150 (NOT 131)
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_DECODE_WINDOW=16 OASIS_IQR_TIMING=1 \
  timeout 120 ./extension/build/release/duckdb -c \
  "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');"

# 2. window gate (the correctness suite cannot see this)
OASIS_IQR_FUSE=1 bench/overlap_ab.sh accuracy      # both must be 200

# 3. full gates + numbers
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 ./extension/build/release/duckdb < bench/sql/cpu_op_correctness.sql
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_DECODE_WINDOW=16 python3 bench/medians.py --consume -n 15
```

**If it hangs again** (should not — sim proved the datapath): it's now bounded, so `finish_fused`
throws `histogram_total != N` within 10 s. `fed_elements()` shows how far pass 1 got. The remaining
unsimulated suspects are the CSR clear-fence timing and closure, not the arbiter.

---

## 7. Also in flight — 07_perf_fpga (Coyote example)

Building on hacc-build-02 (tmux `perf`). Modified to sweep **host or card** memory in one bitstream:
`BENCH_STRM_REG`(8) → `sq_rd/sq_wr.strm`, `EN_MEM 1`, `--card/-c` flag. Coyote has no card alloc type
(REG/THP/HPF/GPU) — residency comes from a one-off `LOCAL_OFFLOAD`, done before the sweep; and the
benchmark's per-iteration re-randomisation is skipped for card buffers or the pages migrate back.

```bash
cd ~/oasis/parcore/libstf/coyote
bash util/program_hacc_local.sh examples/07_perf_fpga/hw/build_hw/bitstreams/cyt_top.bit driver/build/coyote_driver.ko
cd examples/07_perf_fpga/sw/build_sw
./test -o 0 -c 0 -x 64 -X 4194304    # read host   <- the useful one now
./test -o 1 -c 0 -x 64 -X 4194304    # write host
```

**Its purpose has shifted.** HBM is no longer needed (see §8), so the card sweep is only for the
record. The *host* sweep matters: at 8 lanes the bottleneck becomes **`fetch`+`submit` = 60.4 ms of
host work** inside the 92 ms decode, and FPGA-initiated reads (what this example demonstrates) are
the candidate replacement. **Flashing it replaces the IQR bitstream** — reflash afterwards.

---

## 8. Next steps after build-16, in priority order

1. **Validate build-16** (§6). Expect `heavy` 169.7 → **~150**, `passes` 76.6 → ~38, `decode`
   unchanged, `win_derive` ~18. Run with `OASIS_IQR_WINDOW_FPGA` **unset** so the window path is the
   one already trusted — a changed window would confound the RTL verdict.

1b. **Derive the window on the FPGA instead of the CPU** (`OASIS_IQR_WINDOW_FPGA=1`, pure software,
   already implemented). Today `DeriveWindowSpanning` decompresses the first `DataChunk` of 16
   spanning row groups **on the host** — and because you cannot decode 2048 rows out of a compressed
   page, that means fully decompressing 16 pages to keep 0.05 % of the column: ~18 ms wall and
   **~51 ms of host CPU**, duplicating work the FPGA is about to do anyway. §9.15.1 measured the
   damage to the study's headline: CPU-work on extprice fell **3.70× → 1.91×**.
   Instead: decode 16 spanning groups **on the FPGA** (fuse off), stride-sample their output, derive
   the window, then decode the whole column with the bins already set. The 16 groups decode twice —
   ~3 ms — which is deliberate: the alternative (replaying them from host memory into the idle
   `iqr_host_in` port) saves 1.7 ms but requires flipping `fuse_enable` mid-`HISTOGRAM`, i.e. a posted
   CSR write racing the data plane. That is the hazard class that already forced the histogram-clear
   fence. Not worth 1.7 ms.
   **Expect `heavy` ~150 → ~135 and host CPU back to baseline**, and fusion becomes a win on *every*
   dataset rather than only above ~20 M rows. Re-run `overlap_ab.sh accuracy` after: the sample
   differs from the CPU one, so `bin_min`/`bin_shift` may land a step apart and counts can shift
   (taxi_d2 moved 2877 → 2617 when the prefix window was replaced). **`ov_drift` must still be 200.**
   *Metadata cannot replace this.* Footer min/max is free and was tested: taxi_d4 spans
   −128540..33407632, so 1024 bins are 32768 wide while fares live in 0..5000 ⇒ everything in bin 0
   ⇒ q1 = q3 ⇒ degenerate. Percentiles over per-group extremes fail too (outliers in ~every group),
   page-level `ColumnIndex` fails for the same reason at finer grain, and dictionary pages give the
   value *domain* without frequencies and don't exist on PLAIN-encoded sf10/extprice. What is needed
   is a robust **quantile**; Parquet only stores **extremes**.
2. **Step 2 — store bin indices instead of values.** Pass 2 only needs "is v below lo / above hi".
   The histogram already computes a 10-bit bin index, so storing that instead of the 64-bit value is
   **6.4× less data: 457.7 MB → 71.5 MB**, taking pass 2 from ~38 ms to ~6 ms and `heavy` to ~98.
   **Open question:** `lo = q1 − 1.5·IQR` can land mid-bin, so bin comparison isn't exact — either
   round fences outward to bin edges or store 11 bits (half-bin). Measure against `ov_drift`.
3. **HOST MEMORY IS ENOUGH — do not build HBM for this.** With bin indices the intermediate is
   71.5 MB, so host round-trip costs ~5.7 ms vs HBM's ~4.5 ms. **HBM is worth ~1 ms.** And host
   writes/reads already exist (`OutputWriter` → `axis_host_send`, `LocalRead` → `axis_host_recv`), so
   Step 2 needs **no new data-movement machinery at all**.
4. **8 lanes** — only after 1–3, and then `fetch`+`submit` (60.4 ms) becomes the wall.
5. **Streaming guard for taxi's row groups** — taxi_d3/d4 fall back to `sink=memcpy` and pay
   `copy` (7.6 ms of taxi_d3's 35.2). Pure software.

**Projected ceiling with all of the above: `heavy` ~66 ms vs the CPU's ~92 — the first design in this
study that beats the CPU rather than reaching parity, because it attacks bytes moved, not throughput.**

---

## 9. Files

| file | purpose |
|---|---|
| `bench/medians.py` | main benchmark. **`--consume`** excludes DuckDB's table append. `-n`, `-d`, `-t`. |
| `bench/phases.sh` | raw per-phase timings, both operators, all datasets. No parsing. `phases.sh 3 [dataset]`. |
| `bench/phases.py` | same, but medians + derived GB/s tables. |
| `bench/overlap_ab.sh` | `gen` builds ov_uniform/ov_drift; `accuracy` is **the window gate**; `time` is the A/B. |
| `bench/sql/cpu_op_correctness.sql` | 3-way FPGA/C++/SQL, `threads=1`, POSITIONAL JOIN. |
| `bench/sql/decoder_probe.sql` | per-lane decoder profilers, all four terms + load balance. |
| `hardware/unit-tests/run_feed_tb.sh` | xsim, feed arbiter alone, 4 lanes uneven. Seconds. |
| `hardware/unit-tests/run_fused_integration_tb.sh` | xsim, feed→mux→IQR_detection connected. Seconds. |
| `scripts/util/watch_build.sh` | `[-w]` watch a `hardware/build-*` without touching Vivado. |
| `extension/src/oasis_iqr.cpp` | `DeriveWindowFromFpga` (§8.1b, `OASIS_IQR_WINDOW_FPGA=1`, off). |

## 10. Framing for the writeup

- **Lead with host CPU-seconds (2.07–6.07×)** — unaffected by both benchmark defects, latency-independent.
- **Report both benchmarks** (`--consume` and materialised) and say which is which.
- **The story is the crossover at ~10 M rows**, not encoding.
- **Disclose:** the FPGA's remaining loss is a bus limit (12.5 vs 63 GB/s), not an operator limit —
  and the redundant PCIe pass we removed in RTL is the measured proof that it's addressable.
- **Disclose:** the C++ baseline saturates ~3 cores and is not proven optimal; C++ spreads are 20–77 %.
