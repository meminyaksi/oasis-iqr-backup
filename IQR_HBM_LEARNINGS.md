# IQR + HBM (card memory): what we learned — 2026-07-13

Session goal: cut the IQR operator's PCIe traffic by keeping the decoded column in the FPGA's HBM
instead of re-streaming it from the host for each of the two passes ("Option A"), on build-09 — the
first bitstream ever built with `EN_MEM=1`.

**Verdict: Option A is dead. Card mode is 4–20× SLOWER than host mode and gets worse with size.**
The HBM *read* path is correct and bit-exact; the killer is how Coyote *gets data into* HBM.
Everything below is the evidence, the five driver bugs we had to fix to even get that answer, and
what it means for the next design.

---

## 1. Headline numbers

`examples/iqr_sim` on `alveo-u55c-07`, build-09, wall clock:

| dataset | host (`USE_CARD=0`) | card/HBM (`USE_CARD=1`) | |
|---|---|---|---|
| 8 MB (N=1048576) | **0.67 s** | 2.74 s | 4× slower |
| 64 MB (N=8388608) | **0.86 s** | 17.29 s | **20× slower** |

Both produce `Mismatches: 0` and `histogram_total == N`. Correctness is not the problem;
**throughput is**, and the gap widens with data size.

Also from the profiler (host mode, and this is the number that justified the whole effort):

```
stream profile [input]: handshakes=262144  starved=66819 (20.2%)  stalled=1056 (0.3%)
```

The input stream is **80% busy / 20% starved** → the FPGA is being fed at ~12.8 GB/s
(64 B/beat × 250 MHz × 0.8), i.e. **essentially PCIe Gen3 x16 line rate.** The operator is
PCIe-bandwidth-bound, so reducing PCIe crossings is still the right goal — just not this way.

---

## 2. Why Option A loses (the root cause)

To stage data in HBM, Coyote uses `LOCAL_OFFLOAD` → `offload_user_pages` → `migrate_to_card` →
`trigger_dma_offload` (`driver/src/vfpga/vfpga_hw.c`):

```c
void trigger_dma_offload(..., uint32_t n_pages, bool huge) {   // `huge` is accepted and NEVER USED
    for (int i = 0; i < n_pages; i++) {                        // 262,144 iterations for a 1 GiB page
        while (cmd_sent >= DMA_THRSH) {                        // DMA_THRSH = 32
            usleep_range(DMA_MIN_SLEEP_CMD, DMA_MAX_SLEEP_CMD);// 10–50 us sleep!
        }
        device->cnfg_regs->offl_ctrl = (bus_data->stlb_meta->page_size << 32) | ...;  // ALWAYS 4 KB
    }
}
```

Two compounding disasters:

1. **The migration granule is 4 KB.** One DMA command per 4 KB, with a sleep every 32 commands.
   Moving one 1 GiB huge page = 262,144 commands + ~8,192 sleeps ≈ **1 second of pure overhead.**
2. **It always migrates the WHOLE huge page.** Our memory pool hands out **1 GiB** pages, and the
   driver's mapping granule is the whole page — so staging an 8 MB buffer migrates **1 GiB**.

And structurally, even with a perfect offload Option A is weak: you pay a **PCIe crossing to push the
data into HBM** in order to save a PCIe crossing later. At 1 GiB granularity that's a wash at best.

> **Key architectural lesson: Coyote has two DMA paths, and they are not equal.**
> - **`OutputWriter` / `sq_wr` / `LOCAL_READ`** — the normal streaming path. Fast, full line rate.
>   This is what host mode uses.
> - **`LOCAL_OFFLOAD` / `LOCAL_SYNC` (migration)** — 4 KB at a time, sleep-throttled. **Avoid.**
>
> **Any future HBM design must move data with the first path and never the second.**

---

## 3. The five Coyote driver bugs (all fixed locally, all in `parcore/libstf/coyote/driver/`)

`EN_MEM=1` + **1 GiB huge pages** is a combination nobody has ever run. Coyote defaults to **2 MB**
huge pages (`cmake/FindCoyoteHW.cmake`: `set(TLBL_BITS 21 ...)`); this project overrides it to
**1 GiB** (`hardware/CMakeLists.txt:45`: `set(TLBL_BITS 30)`) because `HugePageMemoryPool` uses
1 GiB pages. Every bug below falls out of that combination — the HBM examples work fine at 2 MB.

### (a) Card-memory budget too small — `include/coyote_defs.h`
With `en_mem`, the driver **mirrors every host mapping with an equal-sized card allocation**, whether
or not you ever read from the card. At 1 GiB per host page, 4 buffers = 4 GiB. The stock huge region
is only 4 GB → 4th map fails `-ENOMEM` (`insufficient memory on card to store buffer`).
*This is why even `USE_CARD=0` failed.*

### (b) Misaligned card base → **silent data corruption** — `include/coyote_defs.h`
`create_tlb_mapping` stores `physical_address >> page_shift`, truncating the card address to the lTLB
granule. With `TLBL_BITS=30` that granule is **1 GiB**, but the huge region started at
`MEM_START(256 MB) + card_huge_offs(4 GB)` = **4.25 GB — not 1 GiB-aligned.** The low 256 MB was
silently discarded: the driver wrote the data to one place and the FPGA read from another.
(256 MB *is* 2 MB-aligned, which is exactly why nobody ever hit this.)

**Fix (both a and b):**
```c
#define MEM_START      (256UL * 1024UL * 1024UL)
#define N_SMALL_CHUNKS (458752UL)                  // 1.75 GB -> huge region based at EXACTLY 2 GB
#define N_LARGE_CHUNKS (3UL * 1024UL * 1024UL)     // 12 GB   (mirrors all 8 host 1 GiB pages)
// total = 0.25 + 1.75 + 12 = 14 GB, inside the U55C's 16 GB HBM
```
Verify in dmesg: allocations must land on clean 1 GiB steps —
`@ 80000000, c0000000, 100000000, 140000000, ...`

### (c) Kernel infinite loop (soft lockup) — `src/vfpga/vfpga_gup.c`
`offload_user_pages` / `sync_user_pages` looked the buffer up by its **raw address** with
`hash_for_each_possible`, but entries are keyed on the **huge-page-aligned base**. Any buffer not
starting exactly on a 1 GiB boundary (i.e. anything jemalloc returns) was never found — and
`vaddr_tmp` is only advanced *inside* the match branch, so the `while` loop spun forever:

```
watchdog: BUG: soft lockup - CPU#8 stuck for 366s! [iqr_sim:56693]
RIP: offload_user_pages+0xe2 [coyote_driver]
```
**Unkillable process, 8 GiB of huge pages pinned, node needed a reboot** (`sudo hdev reboot`).
**Fix:** scan the whole (tiny) map with `hash_for_each`, and always advance past the matched
mapping; return `-EINVAL` on a miss instead of looping.

### (d) Card chunk allocator re-issues in-use chunks → permanent leak — `src/vfpga/vfpga_hw.c`
`alloc_card_memory` bumped a ring cursor **without testing `->used`**, so it could hand the same
chunk to two mappings. The second free then hits the `used == false` branch, which **does not return
the chunk** (`pr_warn("likely bug: freeing card memory with used=false")` — Coyote's own warning
about its own bug). The pool bled away run after run; symptom was the card appearing to *shrink*
even after we tripled its size.
**Fix:** allocate a **contiguous, granule-aligned run of free chunks**. Contiguity is mandatory —
`tlb_map_gup` programs ONE lTLB entry per huge page from `cpages[0]`, so the card pages behind it
must be contiguous.

### (e) Deadlock + off-by-one — `src/vfpga/vfpga_hw.c`
Both `-ENOMEM` returns inside `alloc_card_memory` returned **while holding `card_lock`** (never
unlocked → the next `free_card_memory` would spin forever). Also the block search tested
`free_chunks > n_pages` (strict), rejecting an allocation that exactly fits.
**Fix:** unlock before returning; use `>=`.

---

## 4. Still-open bug (not chased — Option A was already dead)

**Segfault on exit in card mode only.** Host memory corruption: it dies inside jemalloc's own heap
metadata while freeing a buffer.
```
#0  edata_list_active_remove ... jemalloc/internal/edata.h
#8  libstf::BufferDeleter::operator()(libstf::Buffer const*)
#11 main ()
```
Something in the card path writes outside its region. If HBM is revisited, this must be found.

---

## 5. Traps that cost us hours (don't re-pay)

1. **The FPGA's profiler counters DO NOT RESET between processes.** They accumulate for the life of
   the bitstream. `handshakes=264192` on a run that should show `2048` is the previous run's total
   plus this one's. **Always take differences between consecutive runs, or better: use wall clock.**
   (I misread these once and drew a wrong conclusion — don't repeat it.)
2. **Build the kernel module ON the alveo node**, not on hacc-build-02 — it must match the running
   kernel (`6.8.0-134-generic`).
3. **The whole stack must be rebuilt bottom-up: libstf → oasis → extension.** `parcore`'s CMake does
   `find_package(libstf QUIET)`, so with `CMAKE_PREFIX_PATH=$HOME/opt` it happily reuses the **stale
   installed libstf** and never rebuilds it. Install libstf first, on its own:
   ```bash
   cmake -S parcore/libstf/software -B parcore/libstf/software/build \
         -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt
   cmake --build parcore/libstf/software/build -j && cmake --install parcore/libstf/software/build
   ```
   Symptom of skipping it: `undefined symbol: _ZN5oasis9IqrRunnerC1ERNS_12OasisContextEbblmb`
   (the new `use_card` ctor) or `too many arguments to function enqueue_stream_input`.
   `parcore` itself does **not** need rebuilding — it never calls `libstf::enqueue_stream_input`.
4. **The driver's `pr_warn` messages don't contain the word "coyote".** `dmesg | grep -i coyote`
   hides every actual error. Use `sudo dmesg | head -60` (HEAD, not tail — the failure is at the
   *start*; the tail is teardown spam).
5. **A soft-locked process cannot be killed and holds its huge pages until reboot.** `free_hugepages
   = 0` with `nr_hugepages = 8` means a dead process is still holding them. `sudo hdev reboot` is on
   the sudo allowlist (`sudo -l` to confirm); `sudo reboot` is not. The node may take 5–15 min and
   may need an admin power-cycle if it doesn't come back.

---

## 6. Where the code stands

**Keep (all committed, all still valuable):**
- Driver fixes (a)–(e) — **prerequisites for any HBM work**, and worth reporting upstream to the
  Coyote maintainers.
- `StreamProfiler` on the IQR lane (`vfpga_top.svh`, `iqr_config.sv` regs 7–14, `iqr_config.hpp`).
  This is what proved we're PCIe-bound.
- The card-receive path + `use_card` mux in `vfpga_top.svh` / `iqr_cosim_top.svh`, and
  `IqrRunner::stage_to_card`. **The HBM read path is proven bit-exact on silicon** — every future
  option needs it.
- `libstf::enqueue_stream_input(..., strm_kind)` (`STRM_HOST` / `STRM_CARD`).

**Default:** `OASIS_IQR_USE_CARD=0` (host). Card mode is a documented performance loss — do not
enable it without the redesign below.

**build-09 timing:** WNS **−0.429 ns** (vs build-08's −0.076). Neither failing path is ours: 6,434
endpoints are in the **HBM clock domain** (Xilinx HBM IP + Coyote's RAMA — a domain that didn't exist
before `EN_MEM=1`), and the worst path (−0.429) is the **parquet decoder → host-read credit FIFO**,
85% routing delay = congestion from the HBM stack, not logic depth. **Host mode is bit-exact anyway**
— the violation is not corrupting results.

---

## 7. What to do next (options, best first)

The goal is unchanged: **get the decoded column into HBM without paying a PCIe crossing for it.**
The data is *already on the FPGA* after decoding — that's the whole insight. The mistake in Option A
was shipping it to the host and back.

**Option B-fork — decode tees to host AND HBM simultaneously.**
Decode output goes to the host through the existing (fast) `OutputWriter` *and* to HBM through a new
card `StreamWriter`. Zero migration-path involvement. Requires: a card `StreamWriter` (`STRM_CARD` →
`axis_card_send`) + `sq_wr` arbitration in the IQR top. The tee needs dual backpressure (both
consumers ready).
PCIe: 1 crossing of the decoded column (the host copy) — half of today's 2.

**Option B-sequential (Mehmet's idea) — decode → HBM, then HBM → host.**
Simpler hardware (redirect, not tee). **BUT its HBM→host step is `LOCAL_SYNC` = the same broken 4 KB
migration path.** Only viable if `trigger_dma_sync`/`trigger_dma_offload` are first fixed to use the
`huge` granule they already accept-and-ignore (would cut ~262,144 commands → ~512).

**Option C — one pass, values+flags out (most PCIe-efficient).**
1. Decoder writes to HBM (FPGA-side, no PCIe) **and** ships a small **sample** (~8192 values) to the
   host — a tiny transfer.
2. Host derives the percentile window from the sample, sets `bin_min`/`bin_shift`.
3. Pass 1 (histogram) reads HBM. Pass 2 reads HBM and emits **(value, flag)** to the host through the
   normal `OutputWriter`.
PCIe: compressed in, one values+flags stream out. **No migration path at all.** Solves the
window chicken-and-egg (the sample) *and* gives DuckDB its value column. Most RTL work, best payoff.

**Non-negotiable:** the **percentile** window (1st/99th of a stride-sample) must stay. We measured
min/max windows: **90% disagreement** on taxi_d2/d3/d4 (bin width blows up 2048× because min/max is
set by the very outliers we're detecting). See `IQR_OPTIMIZATION_PLAN.md`.

---

## 8. Reproduce / re-verify

```bash
# on alveo-u55c-07 (driver MUST be built here -- kernel must match)
cd ~/oasis/parcore/libstf/coyote/driver && make clean && make
cd ~/oasis
bash parcore/libstf/coyote/util/program_hacc_local.sh \
     hardware/build-09/bitstreams/cyt_top.bit \
     parcore/libstf/coyote/driver/build/coyote_driver.ko 1
sudo hdev set hugepages --size 1G --pages 8
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages   # must be 8

export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
OASIS_IQR_USE_CARD=0 ./examples/iqr_sim/build_hw/iqr_sim 1048576 10   # PASSES, ~0.67 s
OASIS_IQR_USE_CARD=1 ./examples/iqr_sim/build_hw/iqr_sim 1048576 10   # PASSES but ~2.74 s + segfault

# card allocations must be 1 GiB-aligned:
sudo dmesg | grep alloc_card_memory     # @ 80000000, c0000000, 100000000, ...
```
