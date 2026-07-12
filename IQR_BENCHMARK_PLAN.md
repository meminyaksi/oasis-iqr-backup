# IQR Accelerator — Workshop-Paper Measurement Plan

**Goal:** produce the correctness and performance evidence for the paper:
1. The **1024-bin histogram** on the FPGA is a *correct, bounded-error approximation* of the exact
   IQR outlier decision, and the **hardware is bit-exact** vs the same algorithm on CPU.
2. The FPGA **end-to-end** query **beats DuckDB CPU** (across thread counts and two CPU algorithms),
   over a **range of data sizes**, on **real data (NYC taxi)** and **TPC-H**.

All timing is **end-to-end host→FPGA→host** (send data … receive result). No test/validation/print
code inside any timed region. Same machine (`alveo-u55c-07`), same parquet files, warm OS cache.

---

## 0. Key facts that shape the methodology (verified in repo)

- `iqr_flags(parquet, col)` path = **FPGA decode** (`DecodeColumnChunkOperator`) → host buffer →
  **FPGA IQR** (`IqrRunner.run`) → flags back. Decode is *on the FPGA*, not CPU.
- Extension uses **`auto_window=true`**: `bin_min`/`bin_shift` derived from data min/max ⇒ real data
  gets `bin_shift>0` ⇒ a *genuine* 1024-bin approximation (bin width = `2^bin_shift`).
- Operator quartile semantics (must be mirrored by the CPU models): integer **nearest-rank** on
  cumulative counts — smallest bin value `v` with `cum*4 ≥ total` (Q1) and `cum*4 ≥ 3*total` (Q3);
  fences `lo = Q1 − (IQR + IQR>>1)`, `hi = Q3 + (IQR + IQR>>1)` (integer `>>1` for the ×1.5).
- Datasets on disk (`~/datasets/`), all single BIGINT column:
  | file | rows (≈) | column | range → binning |
  |---|---|---|---|
  | `tpch_qty.parquet` | ~6M (SF1 l_quantity) | quantity | **1..50 → fits 1024, bin_shift=0 ⇒ histogram EXACT** (control) |
  | `taxi_d1..d4.parquet` | 2.96M / 5.97M / 13.1M / 20.3M | `fare_cents` | wide → bin_shift>0 ⇒ approximation + tail |
  | `tpch_extprice.parquet` | ~6M (SF1) | ext. price | wide → approximation |
  | `tpch_extprice_sf10.parquet` | ~60M (SF10) | ext. price | wide → approximation, largest |

  `tpch_qty` is the **exact-fit control** (proves FPGA==CPU-exact when data fits 1024 bins);
  taxi/extprice are the **approximation** cases. This spectrum *is* the accuracy story.

---

## 1. Correctness — three-model design

Compute the **same statistic three ways** and cross-check:

1. **CPU-exact** (ground truth): exact IQR with the operator's discrete nearest-rank semantics on the
   full column (no binning). → `Q1,Q3,IQR,lo,hi`, per-row `is_outlier`, outlier count.
2. **CPU-hist-1024**: re-implement the operator *exactly* — auto-window (`bin_min=min`,
   `bin_shift=ceil(log2((max-min+1)/1024))`), 1024-bin counts, integer nearest-rank, integer ×1.5.
   Isolates **approximation error** (algorithm only, no hardware).
3. **FPGA-hist-1024**: `iqr_flags` on silicon.

**Claims / checks:**
- **(a) Hardware correct:** `FPGA == CPU-hist-1024` → identical fences, **per-row flag mismatch = 0**.
  (On `tpch_qty` this also equals CPU-exact — headline "bit-exact" control.)
- **(b) Approximation good:** `CPU-hist-1024 ≈ CPU-exact` → small, *characterized* error.

**Metrics (per dataset):**
- Fence-level: abs & relative error of `Q1,Q3,IQR,lo,hi` (relative = % of exact IQR).
- Decision-level (per row, vs exact flags): confusion matrix → **precision, recall, F1**, accuracy,
  disagreement rate (ppm). This is the metric that matters — does the *outlier decision* change?
- Outlier count: exact vs approx, Δ and %.
- Approximation driver (explains the error): report **bin width `2^bin_shift`** and **fraction of rows
  clamped outside the 1024-window** — show error → 0 as range/1024 falls within resolution
  (`tpch_qty` = 0 error). This directly answers "how well does 1024-bin approximate exact."

---

## 2. Performance — end-to-end time

### Systems compared
| System | Algorithm | Config |
|---|---|---|
| CPU-exact | DuckDB exact quantile → fences → flag | threads {1,4,16,32} |
| CPU-hist-1024 | DuckDB 1024-bin histogram (mimics operator) → flag | threads {1,4,16,32} |
| **FPGA (headline)** | `iqr_flags` (FPGA decode+IQR, via DuckDB) | single engine |
| FPGA kernel-only (optional, non-headline) | `iqr_sim` raw int64, IQR only (no decode, no DuckDB) — internal sanity + one "where does the time go" sidebar | single engine |

### Sizes
`taxi_d1..d4` (size sweep, one domain) + `tpch_qty`, `tpch_extprice` (SF1), `tpch_extprice_sf10` (SF10).

### The timed query — **identical shape both sides**
Consume the full result without bulk printing so "receive it back" is real but no I/O noise:
```sql
-- FPGA:
SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags('FILE.parquet','COL');
-- CPU (both algorithms): a CTE computes fences, outer query flags+counts (forces full scan+receive)
WITH f AS (/* exact- or hist-1024 fences */) SELECT count(*) FILTER (WHERE v<lo OR v>hi) FROM data, f;
```
Both are single DuckDB queries, timed by DuckDB's own `.timer` / `PRAGMA enable_profiling`,
both fully materialize output, neither prints millions of rows.

### Timed region — what's IN vs OUT (fairness contract)
- **IN:** the data movement + compute that produces the result. FPGA headline includes
  host→FPGA decode + host round-trip + FPGA IQR + flags returned (the honest product path,
  including its double-DMA). CPU includes parquet decode + compute (same input state).
- **OUT (excluded on *both*):** process/DB startup, driver load, bitstream flash, **one-time**
  buffer alloc + TLB mapping, result printing, correctness comparison, allocation of compare buffers.
  → Measure **steady-state repeated-query** time (a served query). **Report the one-time init cost
  separately** for transparency (don't hide it, don't charge it per-query).
- **Trials:** 2 warmup (discarded, warms cache) + **10 timed**; report **median** and [min,max]
  (or p10/p90). Warm OS page cache (touch each file once before timing).

### Derived / headline numbers
- **Speedup** = t(CPU best-threads)/t(FPGA) and t(CPU 1-thread)/t(FPGA).
- **Throughput**: input GB/s and rows/s.
- **Thread-scaling** curve: does any CPU thread count catch the FPGA? Where's the crossover vs size?

---

## 3. Figures / tables for the paper
- **T1 Correctness:** per dataset — exact vs hist `Q1/Q3/IQR`, fence rel-err, outlier-count Δ%,
  flag F1 & disagreement ppm, and `FPGA-vs-CPUhist mismatch = 0`. (`tpch_qty` row = 0 error control.)
- **F1 Accuracy:** flag-F1 / disagreement-ppm per dataset, annotated with bin width & % clamped.
- **F2 End-to-end time vs size** (log-log): CPU-exact-1t, CPU-exact-32t, CPU-hist-32t, FPGA.
- **F3 Thread scaling** at the largest size: CPU time vs threads, FPGA as a horizontal line.
- **F4 Throughput (GB/s) & speedup** bars per dataset.
- **T2 Timing table** (all cells) + separate **one-time init** column (transparency).

---

## 4. Deliverables (I build; USER runs on hardware)
- `bench/cpu_models.sql` — the exact-quantile and hist-1024 flag queries (parameterized by file/col).
- `bench/correctness.py` — computes the 3 models, cross-checks, emits T1/F1 CSV. (Reads parquet via
  DuckDB for CPU-exact & CPU-hist; reads FPGA flags via the extension.)
- `bench/perf.sh` — sweeps {system × threads × dataset}, N=10+2 trials, warm cache, `.timer` capture
  → `perf_results.csv`; then a small plotter → F2/F3/F4.
- FPGA kernel-only timing: reuse `examples/iqr_sim` (already argv-driven) with a tight timer around
  `runner.run` only.

## 5. Decisions taken (flip if you disagree)
1. **CPU output = per-row flags + count** (apples-to-apples with FPGA output). Also record a
   fences-only CPU variant as a CPU lower bound. — *default: flags+count headline.*
2. **TPC-H = SF1 + SF10** (files exist). Skip SF30 unless you want it (needs generating).
3. **Threads = {1,4,16,32}** (per your call; confirm u55c-07 has ≥32 physical cores via `nproc`).
4. **Headline FPGA number = `iqr_flags` (decode included)**; kernel-only reported separately, clearly
   labelled, so we never overclaim.
