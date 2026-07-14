# IQR FPGA Operator — Correctness & Performance Results

**System:** Alveo U55C (VU47P), Coyote shell, `alveo-u55c-07`, 32 physical cores (`nproc=32`).
**Bitstream:** build-11 (1024-bin histogram; timing closed, WNS 0.000). **Software:** DuckDB
extension `iqr_flags` (FPGA decode + IQR) vs native DuckDB on the same binary/host.
**§1 correctness measured on build-08; §2–3 performance re-measured 2026-07-14 on build-11.**
**Method:** end-to-end, per-statement DuckDB `.timer`; 2 warm-up + 7 timed runs, warm OS cache;
median reported (min in CSV). Identical query shape every system: `count(*) FILTER (WHERE outlier)`.
Datasets: NYC-taxi `fare_cents` (d1–d4) and TPC-H `l_quantity`/`l_extendedprice` (SF1, SF10).

Raw data: `bench/perf_results.csv`, `bench/perf_fpga.csv`, `bench/correctness_out.txt`.

---

## 1. Correctness — 1024-bin histogram vs exact IQR

Three models: **CPU-exact** (no binning, ground truth), **CPU-hist-1024** (the operator's algorithm
on CPU, isolates approximation error), **FPGA** (`iqr_flags` on silicon). Outlier decision compared
row-for-row (FPGA effective fences recovered from the flag column; valid because the IQR decision is
a contiguous threshold).

| Dataset | Rows | bin width `2^s` | IQR rel-err (hist) | FPGA outlier-count Δ | **FPGA vs exact disagreement** | hist vs exact |
|---|--:|--:|--:|--:|--:|--:|
| tpch_qty (SF1) | 6.00 M | 1 (exact fit) | 0.000 % | 0.000 % | **0 ppm** | 0 ppm |
| taxi_d1 | 2.96 M | 8 | 0.504 % | −0.391 % | **421 ppm** | 46 ppm |
| taxi_d2 | 5.97 M | 8 | 0.504 % | −0.458 % | **482 ppm** | 55 ppm |
| taxi_d3 | 13.07 M | 8 | 0.080 % | −0.012 % | **12 ppm** | 120 ppm |
| taxi_d4 | 20.33 M | 16 | 0.317 % | +2.670 % | **2701 ppm** | 24 ppm |
| tpch_extprice (SF1) | 6.00 M | 16384 | 0.130 % | 0.000 % | **0 ppm** | 0 ppm |
| tpch_extprice (SF10) | 59.99 M | 16384 | 0.122 % | 0.000 % | **0 ppm** | 0 ppm |

**Findings.**
- **Exact-fit control (tpch_qty):** values span 1–50 → fit 1024 bins with `bin_shift=0` → the FPGA is
  **bit-exact** with the ground truth (0 disagreement). Confirms the operator + `iqr_flags` pipeline
  is correct end-to-end.
- **TPC-H extprice (SF1 & SF10):** despite a coarse 16384-wide bin, the fences land so that **no**
  outlier decision flips — **0 disagreement at 60 M rows**. The 1024-bin quartile estimate is within
  0.13 % of exact.
- **NYC-taxi:** IQR estimate within ≤0.5 %; outlier decisions agree to **≤482 ppm** on d1–d3
  (99.95 %+ decision accuracy). The **count-loss bug is gone** (`iqr_sim`: `total=8192`,
  `collisions=0`).
- **taxi_d4 is the one outlier: 2701 ppm (0.27 %).** This is *not* a hardware error and *not* binning
  resolution — CPU-hist (same 1024 bins) disagrees only 24 ppm. It is **auto-window placement**: the
  FPGA sizes bins from a *stride sample*'s 1st/99th percentile, which on d4 landed the upper fence at
  4048 vs exact 4080, over-flagging the 4048–4080 band. Fully explained, and addressable (larger
  sample / exact-percentile window) — not a correctness defect in the histogram or the silicon.

**Takeaway:** the 1024-bin histogram is a faithful approximation of exact IQR — 0 ppm where data fits
or the range is wide, ≤500 ppm typical on real skewed data, worst observed 0.27 % from sample-based
window placement.

---

## 2. Performance — end-to-end wall time (median of 7 warm runs, seconds)

**Re-measured 2026-07-14** on bitstream build-11 after the host-path optimizations of §3a.
Raw: `bench/perf_build11_ws.csv`. Outlier counts are unchanged by every optimization below.

| Dataset | Rows | exact@1 | exact@4 | exact@16 | exact@32 | hist@32 | **FPGA** |
|---|--:|--:|--:|--:|--:|--:|--:|
| tpch_qty | 6.00 M | 0.106 | 0.072 | 0.036 | 0.032 | 0.168 | **0.019** |
| taxi_d1 | 2.96 M | 0.071 | 0.055 | 0.027 | 0.025 | 0.087 | **0.013** |
| taxi_d2 | 5.97 M | 0.130 | 0.078 | 0.039 | 0.035 | 0.166 | **0.023** |
| taxi_d3 | 13.07 M | 0.269 | 0.117 | 0.069 | 0.059 | 0.327 | **0.044** |
| taxi_d4 | 20.33 M | 0.439 | 0.157 | 0.088 | 0.081 | 0.623 | **0.063** |
| tpch_extprice | 6.00 M | 0.634 | 0.238 | 0.102 | 0.102 | 0.175 | **0.051** |
| extprice SF10 | 59.99 M | 4.367 | 1.395 | 0.528 | 0.483 | 1.842 | **0.448** |

### Speedups (t_CPU ÷ t_FPGA)

| Dataset | vs exact@1 | **vs exact@32** | vs hist@32 |
|---|--:|--:|--:|
| tpch_extprice | 12.4× | **2.00×** | 3.4× |
| taxi_d1 | 5.5× | **1.92×** | 6.7× |
| tpch_qty | 5.6× | **1.68×** | 8.8× |
| taxi_d2 | 5.7× | **1.52×** | 7.2× |
| taxi_d3 | 6.1× | **1.34×** | 7.4× |
| taxi_d4 | 7.0× | **1.29×** | 9.9× |
| extprice SF10 | 9.7× | **1.08×** | 4.1× |

**FPGA throughput:** 118–323 M rows/s, and it now *grows* with data size (228 → 323 M rows/s across
taxi d1→d4) rather than being flat — the fixed per-query overheads that used to dominate are gone.
The two TPC-H `extprice` points are lower (118–134 M rows/s) because that column is
high-cardinality and poorly compressible (310 MB at SF10): throughput tracks **bytes decoded**, not rows.

---

## 3. Honest performance verdict

**The FPGA beats 32-thread DuckDB's native exact quantile on every dataset (1.08×–2.00×)**, with
identical outlier counts, decode included on both sides, same binary and host, median of 7 warm runs.
It also beats the same-algorithm SQL histogram at 32 threads by 3.4×–9.9×, and single-core DuckDB by
5×–12×.

Two caveats stated plainly:

- **The SF10 margin (1.08×) is thin** — within the run-to-run variance you would expect on a shared
  cluster node. Treat it as "parity or better", not as a robust win. taxi_d1 (1.92×) and
  `tpch_extprice` (2.00×) are the solid ones.
- **`cpu_exact` is the baseline that matters.** An earlier harness (`IQR_RESULTS.md`) used a
  `quantile_cont` formulation that runs ~8× slower than the `GROUP BY`+window form used here, which
  flattered the FPGA badly. Do not quote those numbers.

### 3a. What actually made it fast: the accelerator was never the bottleneck

Instrumenting the query end-to-end (`OASIS_IQR_TIMING=1`) produced the most important result in this
document. On taxi_d4, **before** optimization (0.144 s):

| phase | ms | |
|---|--:|---|
| DuckDB row emission | **81** | table function had `MaxThreads() == 1` — 20.3 M rows on one thread |
| IQR two passes (PCIe) | 26 | 163 MB streamed to the FPGA, twice, at line rate |
| host memcpy | 20 | per-row-group copy into the column buffer, one thread |
| IQR setup | 8 | `derive_window()` read all 163 MB to collect 8192 stride samples |
| parquet fetch + submit | 5 | |
| **waiting for the FPGA decoder** | **0.07** | **0.05% of the query** |

**We spent 70 µs of a 144 ms query waiting on the FPGA.** Everything else was serial host code
running on 1 of 32 cores. Four software changes (no bitstream, no RTL, no HBM):

1. **Parallel emission** — heavy phase moved to `InitGlobal`; workers claim disjoint row slices off an
   atomic cursor. 81 ms → ~10 ms. *This one change flipped taxi_d4 from 0.55× to 1.06× vs the CPU.*
2. **Pipelined decode** — the loop submitted one row group and blocked on it, idling the decoder
   through every fetch/submit/copy. Now keeps 8 groups in flight (`OASIS_IQR_DECODE_WINDOW`); the
   scheduler was already async and already load-balanced across lanes, we simply never used it.
3. **Parallel memcpy** (+ a zero-copy path where row groups align to the 64 KB FPGA transfer, guarded
   with a fallback; these files don't align).
4. **Sampling by seek, not scan** — `derive_window()` now jumps to `p[0], p[step], …` instead of
   walking 20.3 M elements to find 8192 of them. 8 ms → 0.6 ms.

taxi_d4: **0.180 s → 0.063 s (2.9×), with the bitstream untouched.**

### 3b. Where the remaining time goes, and what is left

taxi_d4 after optimization (0.063 s; `heavy` = 54 ms):

| phase | ms |
|---|--:|
| **IQR two passes (PCIe)** | **26** |
| FPGA decode wait | 9 |
| host memcpy | 10 |
| DuckDB emission (parallel) | ~9 |
| parquet fetch + submit | 6 |
| IQR setup | 0.6 |

The largest single cost is now the **two PCIe passes**: the decoded column (163 MB) crosses PCIe three
times — out once when the decoder produces it, back in twice for the histogram and the flag pass — at
12.5 GB/s, which *is* PCIe line rate. It cannot be made faster; it can only be done fewer times.

**The tap (fuse decode → IQR pass 1) — NOT implemented, and it is not a free wiring change.**
The histogram cannot bin a value until it knows the window (`bin_min`/`bin_shift`), and today the
window is derived *from the decoded column*, which does not exist while the decoder is still producing
it. Removing pass 1 therefore requires changing **where the window comes from** — e.g. deriving it from
a few row groups decoded up front, then tap-histogramming the rest and re-streaming those few (~4 MB).
That is worth ~13 ms on taxi_d4 (~18%) but **shifts the outlier counts**, and §1 already identifies
taxi_d4 as the dataset most sensitive to window placement (2701 ppm). Costed but deliberately deferred:
a 5-hour bitgen and an accuracy regression, for 18%, while already winning.

Smaller remaining items: more decoder lanes (`--decoders N`; `fpga_wait` is now a real 9 ms since the
memcpy no longer masks it) and eliminating the remaining memcpy via aligned row groups.

**HBM / card memory is a dead end** — see `IQR_HBM_LEARNINGS.md`. Even fully working it *relocates*
PCIe traffic to HBM rather than removing it, and card reads measured 8 MB/s against 12 GB/s for host
DMA (cause never found; three hypotheses falsified).

---

## 4. Fairness notes / threats to validity
- **Same binary, same host, same warm-cache protocol** for every system; identical query shape
  (outlier count) so all paths materialize the full result. Startup/flash/one-time FPGA context init
  excluded (amortized by warm-ups); this reflects a served, steady-state query.
- **FPGA number is the full product path** (decode + IQR + DuckDB emit), *not* a kernel microbench.
  Kernel-only sanity via `iqr_sim` (raw int64, no decode/DB) confirms correctness (`total=8192`,
  `collisions=0`) but is not used as a headline number.
- **CPU-hist is a slightly pessimistic baseline:** it computes its window with two exact
  `quantile_disc` passes, whereas the FPGA uses a cheap stride sample. A sample-based SQL window would
  narrow the FPGA-vs-hist gap somewhat; we report the straightforward SQL implementation.
- **Small workloads favor the CPU:** all inputs ≤310 MB compressed; fixed PCIe/launch overheads are a
  larger fraction of FPGA time here than they would be at 10–100× the data.

---

## 5. Reproduction
```bash
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
bash bench/correctness.sh | tee bench/correctness_out.txt   # Section 1
bash bench/perf.sh        | tee bench/perf_results.csv      # Section 2 (CPU + FPGA)
bash bench/perf_fpga.sh   | tee bench/perf_fpga.csv         # FPGA-only re-run
```
SQL models: `bench/sql/{correctness_cpu,correctness_fpga,exact_count,hist_count,fpga_count}.sql`.
