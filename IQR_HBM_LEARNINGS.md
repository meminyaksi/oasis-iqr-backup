# IQR + HBM (card memory): learnings & open experiment — 2026-07-13

**READ THIS FIRST before touching HBM / card memory / `EN_MEM` in oasis or celeris.**

Goal: the IQR operator is **PCIe-bandwidth-bound**. Cut the number of times the decoded column
crosses PCIe (today: 3) by keeping it in the FPGA's HBM.

**Status: HBM card reads run at 8–11 MB/s (vs 12 GB/s host DMA), bit-exact but ~1200x too slow.**
Two bitstreams are in flight (§7) to find out why. Until they land, `OASIS_IQR_USE_CARD=0` (host) is
the default and the system works correctly and at full PCIe speed.

---

## 1. The measurements (all on U55C / alveo-u55c-07, build-09)

`examples/iqr_sim`, wall clock, split into staging vs passes (`IqrRunner::Result.stage_ms/passes_ms`):

|  | staging (host→HBM) | passes (FPGA reading) | achieved read BW |
|---|---|---|---|
| **host** 16 MiB | 0 ms | 1.65 ms | **10.2 GB/s** ✅ |
| **card** 16 MiB | 549 ms | 1 513 ms | **0.011 GB/s** ❌ |
| **host** 128 MiB | 0 ms | 11.07 ms | **12.1 GB/s** ✅ |
| **card** 128 MiB | 553 ms | 15 938 ms | **0.008 GB/s** ❌ |

Everything is `Mismatches: 0` / `histogram_total == N`. **Correctness is fine; throughput is not.**

Three facts fall out:

1. **Host DMA hits PCIe Gen3 x16 line rate** (~12 GB/s). Confirms the StreamProfiler reading:
   `input: handshakes=262144 starved=20% stalled=0.3%` → the FPGA is *never* the bottleneck (0.3%
   stalled) and waits on data 20% of the time. **The operator is PCIe-bound. Reducing PCIe crossings
   is the right goal.**
2. **Staging is a flat ~550 ms regardless of size** → it always migrates a whole 1 GiB huge page.
3. **HBM reads are ~1200x slower than PCIe**, and the slowdown is ~7.6 µs per 64-byte beat — a
   *software/round-trip* timescale, not a plausible hardware bandwidth limit.

---

## 2. Coyote has TWO DMA paths and they are NOT equal

| path | how it moves data | speed |
|---|---|---|
| **streaming**: `OutputWriter` / `sq_wr` / `LOCAL_READ` | large chunks | **PCIe line rate** |
| **migration**: `LOCAL_OFFLOAD` / `LOCAL_SYNC` | **one DMA command per 4 KB, `usleep(10–50 µs)` every 32 commands**, and always the whole huge page | glacial |

`trigger_dma_offload` (`driver/src/vfpga/vfpga_hw.c`) takes a `bool huge` parameter and **never uses
it** — it always issues `stlb_meta->page_size` (4 KB) commands. Offloading one 1 GiB page = 262 144
commands + ~8 192 sleeps ≈ 1 s.

> **Never put bulk data through the migration path.** This killed "Option A" (host stages the column
> into HBM, both passes read it back): 4x slower at 8 MB, 20x slower at 64 MB.

**BUT** — the migration cost is a **one-time setup cost, not a per-query cost.** To write into HBM the
FPGA only needs a *card-resident vaddr*. Allocate a scratch buffer **once**, `LOCAL_OFFLOAD` it once
(it migrates garbage — irrelevant), and from then on the FPGA writes/reads that range with **zero
migration**. Option A only lost because it re-staged every query.

---

## 3. THE key configuration difference: 1 GiB vs 2 MB pages

Coyote defaults to **2 MB** huge pages (`cmake/FindCoyoteHW.cmake`: `set(TLBL_BITS 21 ...)`).
**This project overrides to 1 GiB** (`hardware/CMakeLists.txt:45`: `set(TLBL_BITS 30)`), because
libstf's `HugePageMemoryPool` uses 1 GiB pages (`HUGE_PAGE_BITS = 30`).

**Why celeris chose 1 GiB — it is a GOOD reason, not an accident.** The driver caps TLB entries per
mapping at `MAX_N_MAP_PAGES = 256`:

| page size | max data mappable in one call |
|---|---|
| 2 MB | 256 × 2 MB = **512 MB** |
| 1 GiB | 256 × 1 GiB = 256 GB |

Our largest dataset (SF10) is **480 MB decoded — right at the 512 MB ceiling.** With 2 MB pages we'd
be scraping the limit and anything bigger page-faults constantly. With 1 GiB pages a whole dataset is
**one TLB entry**.

**Every problem we hit today traces to this one flag.** It is also the **only** Coyote config
difference vs the working `hello_world` example (§5).

---

## 4. The five Coyote driver bugs (ALL FIXED, committed — `parcore/libstf/coyote/driver/`)

All five exist *only* at 1 GiB pages. Coyote's card memory is written and tested for 2 MB.

| # | file | bug |
|---|---|---|
| a | `coyote_defs.h` | **Card budget too small.** With `en_mem` the driver mirrors *every* host mapping with an equal-sized card allocation — whether or not you ever read the card. At 1 GiB/page, 4 buffers = 4 GiB; the stock huge region is 4 GB → 4th map fails `-ENOMEM`. *(This is why even `USE_CARD=0` failed.)* |
| b | `coyote_defs.h` | **Misaligned card base → SILENT DATA CORRUPTION.** `create_tlb_mapping` stores `physical_address >> page_shift`; with a 1 GiB granule the huge region's base (`MEM_START 256 MB + card_huge_offs 4 GB` = 4.25 GB) is **not 1 GiB-aligned**, so the low 256 MB is truncated — driver writes to one card address, FPGA reads another. (4.25 GB *is* 2 MB-aligned → invisible at the default page size.) |
| c | `vfpga_gup.c` | **Kernel infinite loop / soft lockup.** `offload_user_pages`/`sync_user_pages` looked buffers up by their *raw* address, but entries are keyed on the *huge-page-aligned base*. Any jemalloc pointer (never page-start-aligned) was never found, and `vaddr_tmp` only advances inside the match branch → `while` loop spins forever. `watchdog: BUG: soft lockup - CPU#8 stuck for 366s!` — **unkillable process, huge pages pinned, node needs `sudo hdev reboot`.** |
| d | `vfpga_hw.c` | **Card chunk allocator re-issues in-use chunks → permanent leak.** The ring cursor was bumped without testing `->used`; the double-free then hits the `used == false` branch which never returns the chunk (`pr_warn("likely bug: freeing card memory with used=false")` — Coyote's own warning about its own bug). Pool bled away run after run; the card appeared to *shrink* even after we tripled it. |
| e | `vfpga_hw.c` | Both `-ENOMEM` paths returned **holding `card_lock`** (next `free_card_memory` would spin forever); block search used `>` instead of `>=`. |

**Fixes:** huge region based at exactly **2 GB** (1 GiB-aligned) and grown to 12 GB
(`N_SMALL_CHUNKS 458752`, `N_LARGE_CHUNKS 3M`; total 0.25+1.75+12 = 14 GB < 16 GB HBM); full-map scan
with guaranteed forward progress; contiguous granule-aligned chunk runs (contiguity is **mandatory** —
`tlb_map_gup` programs ONE lTLB entry per huge page from `cpages[0]`); unlock before `-ENOMEM`.

**Verify after any driver rebuild:** card allocations must land on clean 1 GiB steps —
```
sudo dmesg | grep alloc_card_memory     # @ 80000000, c0000000, 100000000, 140000000, ...
```

---

## 5. `hello_world` IS a working card-memory reference (I was wrong to say otherwise)

`examples/01_hello_world` has `set(EN_MEM 1)` and exercises **both directions**:
```systemverilog
perf_local inst_card_link ( .axis_in(axis_card_recv[0]), .axis_out(axis_card_send[0]) );
```
and its software is a **bandwidth benchmark with a host/card switch** (`-s 1` host, `-s 0` card).
Its README confirms card mode "repeatedly read[s] the data from HBM" — so **its card number IS the
HBM read bandwidth**, i.e. exactly our missing reference.

It also documents that **host-in / card-out is supported**: *"in Coyote it's absolutely possible to
have source and destination streams being distinct as long as the vFPGA is implemented to reflect
this requirement."* → the 1-pass design (§8) is blessed.

Note: hello_world never calls `LOCAL_OFFLOAD`. Coyote **migrates automatically on page fault** when
you mark an sg `stream = CARD`; `LOCAL_OFFLOAD` is just the explicit trigger for the same thing.

**Full config diff (this is the whole list):**

| | hello_world (card works) | us (8 MB/s) |
|---|---|---|
| `EN_MEM`, `EN_STRM`, `N_CARD_AXI` | 1, 1, 1 | 1, 1, 1 — **same** |
| **`TLBL_BITS`** | **21 (2 MB)** | **30 (1 GiB)** ← **only difference** |
| allocator | `getMem(HPF)` → page-**aligned** | jemalloc → arbitrary offset in a 1 GiB page |
| design size | two tiny `perf_local` blocks | decoder + Snappy + IQR + HBM stack (congested) |

---

## 6. Hypotheses — none proven; be honest about this

| | hypothesis | evidence / status |
|---|---|---|
| **H1** | HBM AXI timing fails (our chip is congested) | build-09: WNS **−0.342 ns, 6 434 failing endpoints**, worst path `HBM_SNGLBLI_INTF_AXI/ARREADY_PIPE` (the read-address handshake), 66% routing delay + an SLR crossing. **Story is WEAK**: a *systematic* setup miss makes a flop latch last cycle's value (a 1-cycle lag), not a 99.9% handshake failure. Tested by **build-11**. |
| **H3** | 1 GiB pages break the card path | The **only** config difference vs hello_world, and the root of all five driver bugs. **But I searched the MMU RTL (`hw/hdl/mmu/tlb_fsm.sv`) for a width overflow and found NO mechanism** — `LEN_BITS = 28` (256 MB max request) vs `PG_L_SIZE = 1<<30`, but the truncating branch only fires when a read *crosses* a page boundary, and ours (8–128 MB) sit inside one 1 GiB page. Tested by a `TLBL_BITS=21` build if needed. |
| **H2** | Coyote's card-read DMA is misconfigured (bursts / outstanding requests) | **Unexplored.** |

The 7.6 µs/beat figure smells like a per-transfer round trip, not a wire delay — which is why I no
longer favour H1. **Page faults are ruled out** (dmesg would flood; it doesn't).

---

## 7. THE OPEN EXPERIMENT (both bitstreams started 2026-07-13, running in parallel)

Both run at **350 MHz HBM clock**, so **the clock is eliminated as a variable** between them.

| build | HBM clk | pages | design | dir | started |
|---|---|---|---|---|---|
| build-09 (done) | 450 | 1 GiB | ours | `hardware/build-09` | ❌ 8 MB/s |
| **build-11** | **350** | 1 GiB | ours | `hardware/build-11` | 14:53 (~5 h) |
| **hello_world** | **350** | **2 MB** | tiny | `parcore/libstf/coyote/examples/01_hello_world/hw/build_hw` | 15:42 (~1–2 h) |

**Watch:** `bash scripts/build_status.sh` (or `-w` to block until one lands).

### Interpretation matrix

| hello_world `-s 0` | build-11 | conclusion |
|---|---|---|
| fast | fast | Clock was it. Build the 1-pass design (§8). |
| **fast** | **slow** | **Platform is fine — OUR design is at fault.** Next: rebuild with `TLBL_BITS=21` + `HugePageMemoryPool HUGE_PAGE_BITS 21` (H3). |
| slow | slow | **HBM cannot do fast card reads here. STOP.** Keep host mode; it is correct and full-speed. |

### Commands when they land

```bash
# --- build-11: did the HBM domain close? (was -0.342 ns / 6434 failing) ---
grep -A6 "Intra Clock Table" hardware/build-11/reports/shell_timing_summary.rpt | grep hbm

# --- hello_world: THE reference number (NB: replaces the IQR bitstream; reflash after) ---
cd ~/oasis
bash parcore/libstf/coyote/util/program_hacc_local.sh \
     parcore/libstf/coyote/examples/01_hello_world/hw/build_hw/bitstreams/cyt_top.bit \
     parcore/libstf/coyote/driver/build/coyote_driver.ko 1
sudo hdev set hugepages --size 1G --pages 8
cd parcore/libstf/coyote/examples/01_hello_world/sw/build_sw
./test -s 1     # HOST -- sanity, expect ~10-12 GB/s
./test -s 0     # CARD -- THE ANSWER  (GB/s => platform fine, bug is ours;  ~10 MB/s => HBM dead here)

# --- our design on build-11 ---
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
OASIS_IQR_USE_CARD=0 ./examples/iqr_sim/build_hw/iqr_sim 1048576 10   # must still PASS
OASIS_IQR_USE_CARD=1 ./examples/iqr_sim/build_hw/iqr_sim 8388608 10 | grep bandwidth
```

### The HBM clock change (a trap worth knowing)

`HCLK_F` in cmake fed **only** the HBM IP's `USER_AXI_CLK_FREQ`; the MMCM was **hardcoded to 450 MHz**
in `hw/bd/ultrascale_plus/cr_hbm.tcl`. Changing `HCLK_F` alone would have told the controller "350"
while the clock stayed 450 — a silent desync that would have made things *worse*. Now the divider is
**derived** from `HCLK_F` (fixed VCO 1181.25 MHz ⇒ `2.625` = 450 MHz, `3.375` = 350 MHz; 450
reproduces the original exactly). Confirm in the log:
```
Coyote: HBM AXI clock = 350 MHz (VCO 1181.25, CLKOUT0_DIVIDE_F = 3.375)
```
Bandwidth given up is irrelevant: the HBM AXI port is 512-bit → 350 MHz still ≈ **22 GB/s**, far above
the ~12 GB/s PCIe ceiling we're actually bound by.

---

## 8. The target design (1 pass) — for when/if HBM is proven fast

**The insight:** after decoding, the data is **already inside the FPGA**, right next to HBM. Writing
it to HBM from there costs **zero PCIe**. Option A's mistake was shipping it to the host and back.

```
1. compressed parquet ──▶ FPGA                  (small, compressed)
2. FPGA decodes ──▶ writes to HBM                ← ON-CHIP. Zero PCIe.
3. FPGA sends a small SAMPLE ──▶ host            (~8192 values ≈ 64 KB, negligible)
     host derives the PERCENTILE window, writes bin_min / bin_shift
4. pass 1: HBM ──▶ histogram ──▶ fences          (on-chip, free)
5. pass 2: HBM ──▶ flags + values ──▶ host       ← the ONE unavoidable PCIe trip (highway)
```
PCIe crossings of the decoded column: **3 today → 1.** We're PCIe-bound ⇒ **~3x**.
The sample (step 3) also solves the window chicken-and-egg **without** the host ever seeing the full
column.

**Most of the mechanism already exists:**
- `StreamWriter` **already** has `parameter STRM = STRM_HOST` and documents `STRM_CARD`
  (`sq_wr.data.strm = STRM`). `OutputWriter` simply never passes it → everything defaults to host.
- `OutputWriter` **already** contains an `sq_wr` arbiter for multiple writers.
- `axis_card_send[]` already exists in our vFPGA — we currently just **tie it off**
  (`vfpga_top.svh:286`).
- The HBM **read** path is **proven bit-exact on silicon**.
- `axis_card_send` **is** exercised upstream by hello_world → not virgin territory.

**Work items:** (1) give the decoder lane a `StreamWriter #(.STRM(STRM_CARD))` → `axis_card_send[0]`
+ `sq_wr` arbitration in `vfpga_top.svh`; (2) SW: allocate a **persistent** HBM scratch buffer,
`LOCAL_OFFLOAD` once at init (§2); (3) point the decoder's `mem_config` vaddr at it; (4) IQR passes
read it with `STRM_CARD` (already works); (5) sample tap → host → window.

**NON-NEGOTIABLE:** keep the **percentile** window (1st/99th of a stride-sample). Measured: min/max
windows give **90% disagreement** on taxi_d2/d3/d4 (bin width blows up 2048x because min/max is set by
the very outliers being detected). See `IQR_OPTIMIZATION_PLAN.md`.

---

## 9. Traps that cost hours — do not re-pay

1. **FPGA profiler counters NEVER reset between processes.** They accumulate for the life of the
   bitstream. A run that should show `handshakes=2048` prints `264192` (previous total + this run).
   **Take differences between consecutive runs, or just use wall clock** (`stage_ms`/`passes_ms`).
   *I misread these once and drew a wrong conclusion. The code now warns about it.*
2. **Build the kernel module ON the alveo node** (must match the running kernel, `6.8.0-134-generic`).
3. **Rebuild the stack bottom-up: libstf → oasis → extension.** `parcore`'s CMake does
   `find_package(libstf QUIET)`, so with `CMAKE_PREFIX_PATH=$HOME/opt` it silently reuses the **stale
   installed libstf**. Install libstf first, on its own:
   ```bash
   cmake -S parcore/libstf/software -B parcore/libstf/software/build \
         -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt
   cmake --build parcore/libstf/software/build -j && cmake --install parcore/libstf/software/build
   ```
   Symptoms of skipping it: `undefined symbol: _ZN5oasis9IqrRunnerC1ERNS_12OasisContextEbblmb`, or
   `too many arguments to function enqueue_stream_input`. `parcore` itself does **not** need
   rebuilding (it never calls `libstf::enqueue_stream_input`).
4. **Driver `pr_warn`s don't contain the word "coyote"** → `dmesg | grep -i coyote` hides every real
   error. Use `sudo dmesg | head -60` (**HEAD**, not tail — failures are at the *start*; the tail is
   teardown spam).
5. **A soft-locked process cannot be killed and holds its huge pages until reboot.**
   `free_hugepages = 0` with `nr_hugepages = 8` ⇒ a dead process still owns them.
   `sudo hdev reboot` **is** on the sudo allowlist (`sudo -l`); `sudo reboot` is not. Node takes
   5–15 min; may need an admin power-cycle if it doesn't return.
6. **CMake cache lies.** `EN_MEM:STRING=0` / `TLBL_BITS:STRING=21` in `CMakeCache.txt` are the *Coyote
   defaults*; a plain `set(X ...)` in our `CMakeLists.txt` shadows them. **Check the generated
   `base.tcl`** (`cfg(en_mem)`, `cfg(tlbl_bits)`, `cfg(hclk_f)`) for the truth.
7. **`build-10` is a dead failed dir** (cmake configure died). Ignore/delete it.

---

## 10. Code state

**Default: `OASIS_IQR_USE_CARD=0` (host).** Card mode is a documented performance loss — do not enable
it without the redesign in §8. **The old 3-pass host behaviour IS the default** — nothing needs
reverting.

**Restore tags:** `iqr-preopt-checkpoint` (pre-everything), `iqr-profiler-checkpoint`,
`iqr-hbm-optionA`.

**Keep (all committed, all valuable regardless of the HBM outcome):**
- Driver fixes (a)–(e) — one is a **silent corruption** bug. Worth upstreaming to Coyote.
- `StreamProfiler` on the IQR lane (`vfpga_top.svh`, `iqr_config.sv` regs 7–14, `iqr_config.hpp`).
  It is what proved we're PCIe-bound.
- Wall-clock split (`IqrRunner::Result.stage_ms/passes_ms`) + bandwidth print in `iqr_sim`.
- Card-receive path + `use_card` mux in `vfpga_top.svh`/`iqr_cosim_top.svh`; `IqrRunner::stage_to_card`;
  `libstf::enqueue_stream_input(..., strm_kind)`.
- HBM clock derivation fix in `cr_hbm.tcl`.
- `scripts/build_status.sh`.

**Commits (local only — read-only push on celeris-labs):**
```
coyote   deea9d62  driver: fix card memory (en_mem) for 1 GiB huge pages
coyote   a96c46c5  hbm: drop the u55c HBM AXI clock 450 -> 350 MHz to close timing
libstf   26097ef   coyote: bump
parcore  dafc19b   libstf: bump
oasis    7fef9e8   IQR/HBM: bank the Option-A result + Coyote card-memory fixes
oasis    1ccc87e   IQR: measure the HBM read path, and lower the HBM clock to close its timing
```

**build-09 timing:** WNS −0.429 ns (build-08 was −0.076). Neither failing path is ours: 6 434
endpoints in the **HBM clock domain** (Xilinx HBM IP + Coyote RAMA — a domain that didn't exist before
`EN_MEM=1`), and the worst path is **parquet decoder → host-read credit FIFO**, 85% routing =
congestion from the HBM stack. **Host mode is bit-exact and full-speed anyway.**

---

## 11. Questions for the supervisor (still unanswered — could save days)

1. **What card bandwidth does `hello_world -s 0` report on a U55C?** (If a colleague already has this,
   it short-circuits the whole experiment.)
2. **Is the 450 MHz HBM AXI clock known to fail timing in large designs? Is there a pblock/floorplan
   constraint** to keep the HBM interconnect in SLR0? That would close timing *without* giving up
   clock speed — a better fix than mine.
3. **Why does libstf use `TLBL_BITS=30` (1 GiB) rather than Coyote's default 21 (2 MB)?** Coyote's card
   memory is only built/tested for 2 MB. Would 2 MB be acceptable for our workloads (SF10 = 480 MB,
   just under the 512 MB single-mapping cap)? **This is the highest-leverage question** — if the answer
   is "no strong reason", switching removes this entire class of problem.
4. Has anyone driven `axis_card_send` (vFPGA → HBM writes) beyond `hello_world`?
