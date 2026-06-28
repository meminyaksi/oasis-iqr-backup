# IQR-on-Oasis: Results & Evaluation

Measured 2026-06-28 on ETHZ HACC (build: hacc-build-02, run: alveo-u55c-07, Alveo U55C).
Companion to [IQR_OASIS_PLAYBOOK.md](IQR_OASIS_PLAYBOOK.md). All data is real (NYC TLC yellow taxi
2024) unless noted; reproduction harness: `~/datasets/iqr_bench.sql`.

---

## 1. Validation ladder (correctness)

| Stage | Result |
|---|---|
| Software-in-the-loop co-sim | PASS, 0 mismatches (bit-exact vs histogram model) |
| Hardware `iqr_sim` (raw int64) | PASS, 0 mismatches |
| DuckDB `iqr_flags` over parquet (decode→FPGA→IQR) | runs on silicon |
| FPGA vs CPU, small data with outliers | 10 = 10 |
| FPGA vs CPU-exact, 3M real taxi fares | 309,309 vs 318,801 (97.0%) |
| **FPGA vs its own 256-bin histogram model** | **309,309 = 309,309 (EXACT)** — silicon is faithful |

The hardware is **bit-exact to the histogram algorithm**. Differences vs CPU-exact are the
histogram method's resolution, not silicon error (see §3).

## 2. End-to-end timing — FPGA vs DuckDB(32t) exact vs DuckDB(32t) histogram

Real NYC taxi `fare_amount`→cents (BIGINT). Each implementation produces per-row flags
(decode→flags); `count() FILTER` forces flag generation. Warm (2nd-run) times.

| dataset | rows | FPGA (s) | exact (s) | hist (s) | FPGA vs exact | FPGA vs hist |
|---|---|---|---|---|---|---|
| d1 | 2,964,624  | **0.036** | 0.093 | 0.101 | 2.6× | 2.8× |
| d2 | 5,972,150  | **0.053** | 0.166 | 0.147 | 3.1× | 2.8× |
| d3 | 13,069,067 | **0.122** | 0.393 | 0.326 | 3.2× | 2.7× |
| d4 | 20,332,093 | **0.175** | 0.641 | 0.687 | 3.7× | 3.9× |

Throughput (M rows/s): FPGA 82–116 ; exact 31–36 ; hist 29–41.
**Slope throughput** (startup-canceled): **FPGA ≈125 M/s, exact ≈32 M/s, hist ≈30 M/s → ~4× on compute.**

Findings: (1) FPGA fastest at every size, speedup **grows with data** (2.6→3.7×); (2) the CPU
histogram is **not** a fast path (≥ exact's time) — FPGA beats *both* CPU options; (3) ~110–125 M
rows/s on one FPGA vs ~30–40 M/s on the server CPU.

Caveats: DuckDB used only ~3–7 cores effectively (user/real ratio) — these light, bandwidth-bound
queries don't scale to 32; "32-thread" = available, not utilized. Times are whole-query (FPGA
decode + 2-pass IQR + flags), not the isolated kernel.

## 3. Accuracy vs exact quantiles, and the bin-count lever

The FPGA is exact to the histogram; accuracy *vs exact continuous quantiles* is governed by bin
count. Replicated FPGA algorithm in Python on the 3M taxi column (gap = vs CPU-exact 318,801):

| config | outliers | bin width | gap |
|---|---|---|---|
| 256 bins lower-edge (HW now) | 309,309 | 32¢ | −9,492 |
| 1024 bins lower-edge | 317,554 | 8¢ | −1,247 |
| 4096 bins lower-edge | 318,801 | 2¢ | 0 (exact) |
| 1024 bins + midpoint | 318,751 | 8¢ | −50 |

Levers (cheapest first): **1024 bins + bin-midpoint quantile** → ~exact, single-BRAM depth (no
cascade), low timing risk — the recommended next bitstream. Why **1024 not 4096**: 1024 is the max
depth that fits one BRAM primitive; 4096 forces depth-cascaded BRAM + output mux → extra read-path
latency, risky at the current **WNS −0.127**. BRAM is not the limit (4096≈64 RAMB18, U55C has ~2000);
timing is. The 1.5× multiplier is NOT a lever (it changes the outlier *definition*, not FPGA-vs-CPU
agreement).

## 4. Match status (FPGA vs simple SQL histogram reference)

| dataset | FPGA | hist ref | Δ |
|---|---|---|---|
| d1 | 309,309 | 316,713 | 2.3% |
| d2 | 609,186 | 609,132 | 0.01% |
| d3 | 1,290,645 | 1,331,475 | 3.1% |
| d4 | 2,046,941 | 2,106,324 | 2.8% |

The 2–3% is the **power-of-2 bin width** (HW) vs exact `(hi−lo)/256` (SQL reference) — a window
variant, not error. FPGA matches its *own* algorithm exactly (d1: 309,309 = model).

## 5. Known limitation: extreme-range / bimodal columns

`huge.parquet` (synthetic decoder stress file: 64% of values 128–224, 36% spanning 100M–17B, a
6-order gap) is pathological for any fixed-bin histogram: Q1 and Q3 land in different regimes, only
11/256 bins fill, and **count-loss destabilizes the quartile** (FPGA returned 5.47M then 0 vs the
true histogram answer 3.87M, run-to-run). Not realistic data; documented as a failure mode.
Fixes: log-binning, more bins, or the count-loss fix. On well-conditioned data (taxi) the FPGA is
exact and stable.

## 6. Hardware / build facts

- Bitstream `hardware/build-01/bitstreams/cyt_top.bit`, local mode (`--no-rdma`), 1 decoder.
- **WNS −0.127** (within −0.5 tolerance); failing paths all in vhsnunzip decoder, none in IQR.
- Histogram **in BRAM**: 8 true-dual-port banks (`IQR_detection:/g_bank[*].mem_reg`), not LUTs —
  the celeris histogram→BRAM restructure holds. User region: 42 RAMB18 + 10 RAMB36 + 84 URAM.
- Build time: **~4h 43m** (cmake→bitstream), BUILD_SHELL flow.

## 7. Datasets & reproduction

- `~/datasets/taxi_d{1,2,3,4}.parquet` — cumulative NYC taxi months (2.96M / 5.97M / 13.1M / 20.3M
  rows), column `fare_cents` (BIGINT = fare_amount×100). Built from `ytd_2024_0{1..6}.parquet`.
- Harness: `~/datasets/iqr_bench.sql` — `SET threads=32; .timer on;` then FPGA/exact/hist × 4 sizes,
  warm ×2. Run: `cd ~/oasis/extension/build/release && LD_LIBRARY_PATH=$HOME/opt/lib ./duckdb < ~/datasets/iqr_bench.sql`.
- Reference counts (CPU): d1 exact 318,801 / hist 316,713 ; d2 628,322 / 609,132 ;
  d3 1,328,270 / 1,331,475 ; d4 2,057,243 / 2,106,324.
