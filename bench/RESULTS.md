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

**Re-verified 2026-07-14 on build-11** (`bench/correctness_build11.txt`): all 7 datasets pass, row
counts exact, and **every disagreement figure is identical to the build-08 reference below** — none of
the host-path optimizations of §3a changed a single outlier decision.

| dataset | rows | FPGA outliers | exact | disagreeing rows | ppm |
|---|--:|--:|--:|--:|--:|
| tpch_qty | 6,001,215 | 0 | 0 | **0** | **0** |
| tpch_extprice SF1 | 6,001,215 | 0 | 0 | **0** | **0** |
| tpch_extprice SF10 | 59,986,052 | 0 | 0 | **0** | **0** |
| taxi_d3 | 13,069,067 | 1,328,108 | 1,328,270 | 162 | 12 |
| taxi_d1 | 2,964,624 | 317,554 | 318,801 | 1,247 | 421 |
| taxi_d2 | 5,972,150 | 625,445 | 628,322 | 2,877 | 482 |
| taxi_d4 | 20,332,093 | 2,112,164 | 2,057,243 | 54,921 | **2701** |

### taxi_d4's 2701 ppm is bin-edge quantization, NOT the window sample (measured)

The window sample size was made tunable (`OASIS_IQR_SAMPLE`) and swept **8192 → 524288 (64×)**.
`n_out`, `lo_eff` and `hi_eff` are **bit-identical at every size** (2,112,164 / −934 / 4048) while the
`iqr` phase goes 27 → 56 ms and the query 0.064 → 0.090 s. **A larger sample is pure cost with zero
accuracy benefit — do not raise it.**

That isolates the cause. CPU-hist with the *same* 1024 bins but *exact* quartiles disagrees by only
24 ppm, so the bins are fine; the FPGA reports each quartile at its bin's **lower edge** (bin width 16
here), so Q1 and Q3 both land low, both fences shift down, and the 4048–4080 band is over-flagged —
exactly the 54,921 rows observed.

**Fix: a bin-MIDPOINT quartile.** One adder on the quartile output — no latency, no resources, no
timing risk. Simulated in §3 below: gap −1247 → −50, **~25× more accurate**. This is the bitstream
worth building. (The tap of §3b is not: it buys 18% speed *at the cost of* accuracy.)

---

### Original build-08 correctness detail

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
   atomic cursor. The table function had `MaxThreads() == 1`, so 20.3 M result rows were emitted through
   DuckDB on a single core. 81 ms → ~9 ms. *This one change flipped taxi_d4 from 0.55× to 1.06× vs the
   CPU — the largest single gain by far.*
2. **Pipelined decode** — the loop submitted one row group and blocked on it, idling the decoder
   through every fetch/submit/copy. Now keeps 8 groups in flight (`OASIS_IQR_DECODE_WINDOW`); the
   scheduler was already async and already load-balanced across lanes, we simply never used it.
   Reclaims the ~9 ms the host would otherwise sit blocked on the decoder; smallest of the four, and
   only pays off *together with* (3), which stops the memcpy from masking the wait.
3. **Parallel memcpy** — the 166 per-row-group copies into the contiguous column buffer write to
   disjoint ranges, so they run on a thread pool instead of one core. ~20 ms → ~10 ms.
4. **Sampling by seek, not scan** — `derive_window()` now jumps to `p[0], p[step], …` instead of
   walking 20.3 M elements to find 8192 of them. 8 ms → 0.6 ms.

**Per-step gain (taxi_d4, the phase each step attacks):**

| # | step | before | after | saved | note |
|---|---|--:|--:|--:|---|
| 1 | parallel emission     | 81 ms | ~9 ms  | **~72 ms** | biggest; flipped loss→win on its own |
| 3 | parallel memcpy        | 20 ms | ~10 ms | **~10 ms** | 166-buffer gather across cores |
| 2 | pipelined decode       | (hidden wait) | ~9 ms on critical path | **~9 ms** | keeps FPGA off the critical path |
| 4 | seek-sample window     | 8 ms  | 0.6 ms | **~7 ms**  | stop reading 163 MB for 8192 samples |

taxi_d4: **0.180 s → 0.063 s (2.9×), with the bitstream untouched.** vs 32-thread `cpu_exact` this went
from 0.55× (losing) to 1.29× (winning); across all 7 datasets, from losing on 6 → **winning on all 7
(1.08×–2.00×)**.

**The common thread:** none of the four touched the FPGA or the IQR math. Every one removed a place
where 31 of 32 cores sat idle while 1 did the work. The accelerator was always fast; the ordinary host
code wrapped around it was doing everything single-file.

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

Smaller remaining item: more decoder lanes (`--decoders N`; `fpga_wait` is now a real 9 ms since the
memcpy no longer masks it) — but decode was never the bottleneck, so this is low value and costs a
5-hour bitgen.

**Eliminating the memcpy via a zero-copy slice sink is a DEAD END (tried & failed 2026-07-15).** The
idea: rewrite the parquet to 64 KB-aligned row groups so the decoder DMAs each group straight into its
final slot in the column buffer, no copy. It **hangs, not errors, and window=1 hangs too** (not a
concurrency bug). Root cause: the FPGA output writer routes each decode-completion interrupt back per
*registered allocation*; a `MakeSlice()` view into a shared buffer is not one, so the interrupt never
arrives → deadlock. This is the one-buffer-per-chunk invariant the working scan path documents and
obeys (`oasis_scan.cpp:228,288` — every chunk's sink is its own `allocate_output_buffer()`; zero-copy
there lives on the SOURCE and DuckDB-emit side, never the sink). The 64 KB-alignment guard in
`oasis_iqr.cpp` had been *hiding* this by always falling back to memcpy on real (unaligned) files; an
aligned file removed the guard and exposed the hang. `zero_copy` is now hard-disabled with a warning
comment. The 10 ms memcpy stays until `IqrRunner` is taught to stream the 166 per-chunk buffers in
sequence instead of gathering them into one contiguous column (a real runner change, not scoped). See
`IQR_HBM_LEARNINGS.md`.

**HBM / card memory is a dead end** — see `IQR_HBM_LEARNINGS.md`. Even fully working it *relocates*
PCIe traffic to HBM rather than removing it, and card reads measured 8 MB/s against 12 GB/s for host
DMA (cause never found; three hypotheses falsified).

### 3c. Reading the budget — what actually bounds this query (analysis, 2026-07-16)

**Nothing in this query is compute-bound.** No arithmetic anywhere is the bottleneck — not the FPGA's
IQR math (idle 99.95%), not the decode (9 ms). The 63 ms splits into two comparable halves, both of
which are *data movement* or *row handling*, not computation:

```
IQR data movement (2 PCIe passes) ...... ~26 ms  (41%)  — the single largest piece
everything else ........................ ~37 ms  (59%)
   ├─ decode + gather(memcpy) + fetch ..  ~25 ms
   └─ DuckDB emission ..................   ~9 ms
```

So the sharp statements are: the **IQR operation is PCIe-bandwidth-bound** (moving 163 MB twice at line
rate), not compute-bound; and it is the *largest* single cost, **not** a small portion. The only lever
left on the IQR side is *fewer PCIe crossings* (a hardware change) — you cannot compute your way out of
a movement-bound problem.

**Is the win from decoding? No — decode is a tax, not an edge.** Both `cpu_exact` and `fpga` decode the
same parquet, so decode is a *shared* cost, not a differential advantage. On the FPGA it is worse than
neutral: the decode-related host work (decode-wait 9 + gather 10 + fetch 6 ≈ **25 ms, ~40%**) exists
only because we decode into 166 scattered buffers and must gather them — DuckDB decodes straight into
its pipeline with no equivalent gather. Estimate: strip parquet from both (raw int64 in memory) and the
FPGA would likely win by *more* (~1.8× vs 1.29× on taxi_d4), because it sheds its 25 ms decode tax while
the CPU still pays the heavy exact-IQR compute. (Not yet measured; a raw-int64 microbench would settle
it.)

**Why the win is thin (1.08–1.29× on most): DuckDB's exact method is very well tuned.** The tell is
`cpu_hist` — the *same* 1024-bin histogram algorithm the FPGA uses, run naively in SQL, is **~7× slower
than `cpu_exact`** (taxi_d4: 0.553 vs 0.079 s). So the FPGA is not winning with a smarter *algorithm*;
it runs a so-so-on-CPU algorithm on hardware fast enough to edge out a strong CPU implementation. The
FPGA's real edge is *cheap hardware IQR (streaming histogram at line rate) vs expensive CPU IQR
(hash-aggregate every distinct value + a cumulative window over 20 M rows)*.

**Why DuckDB emission is not "just streaming."** The heavy phase already has the two result arrays in
memory, yet emitting them cost 81 ms on one core because it is genuine O(rows) work: per row it (a)
**unpacks one bit** from the FPGA's packed 1-bit-per-row flag bitmask into DuckDB's 1-byte BOOL
(`flag_out[k] = (mask[i>>3] >> (i&7)) & 1` — a format transform, not a pointer), (b) writes the value,
across ~10,000 chunk calls each with engine overhead. 20.3 M × per-row work on one core ≈ 81 ms. The
work is embarrassingly parallel (row *i* is independent of row *j*), so splitting rows across 32 cores
via the atomic cursor cut it to ~9 ms. The flag column can *never* be zero-copy (bit→byte expansion is
unavoidable); the compact 1-bit packing that saves PCIe is paid back as an unpack at emission.

### 3d. Baseline optimization + the cardinality thesis (2026-07-17)

Today's work stress-tested the *CPU baseline itself* — is `exact_count.sql` the fastest fair CPU code,
and how much of the FPGA's margin rests on the baseline having slack? All numbers below are on
**alveo-u55c-07** (same host as the FPGA — the Intel build node has a different CPU, so CPU times must
come from the card node), **single warm runs** on a shared node with visible run-to-run variance;
**treat as directional, medians of 5–7 still pending.** Queries: `bench/manual_queries.sql`,
`bench/cpu_variants.sh`.

**Three exact CPU formulations (all bit-identical, count = 2,057,243 on taxi_d4):**

| CPU formulation | taxi_d4 warm | note |
|---|--:|---|
| `quantile_disc` (DuckDB built-in) | ~0.66 s | its own quantile; **~7–10× slower** — cannot collapse duplicates, processes all N |
| `groupby_current` (`exact_count.sql`) | ~0.089 s | GROUP BY + CDF, then **re-scans all N rows** to count |
| `groupby_histsum` (optimized) | ~0.068 s | count via `COALESCE(sum(c),0)` over the histogram — **no re-scan**; ~24% faster |

Findings:
1. **The current baseline has slack.** The final `count(*) FROM s WHERE …` re-scans all N rows, but the
   per-value counts already exist in the `ecnt` histogram. Replacing it with
   `SELECT COALESCE(sum(c),0) FROM ecnt,ef WHERE v<lo OR v>hi` avoids the second full pass. Warm gain
   **~24% (~21 ms)** on taxi_d4 — real but *smaller* than a cold single run suggested (~40%): measure
   warm, take medians. (`COALESCE` matters — `sum()` over an empty set returns NULL, not 0, when a
   dataset has zero outliers.)
2. **The FPGA's low-card margin is baseline-dependent.** taxi_d4 FPGA ≈ 0.063 s vs: `quantile_disc`
   **~10×**, `groupby_current` **~1.3×**, `groupby_histsum` **~1.0× (parity, within noise)**. Against
   the *fastest* exact CPU code, the FPGA's low-cardinality advantage nearly vanishes.
3. **`quantile_disc` is not the fair baseline for a low-card "beats DuckDB" claim** — it is ~10× slower
   only because it can't exploit low cardinality. Report it as the "naive user writes this" number, but
   the hand-tuned GROUP BY is the honest baseline. (Both CPU baselines use **zero** of our C++ — pure
   stock DuckDB, native `read_parquet`; our code only runs on the `iqr_flags` path.)

**Measured cardinality (why any of this happens):**

| dataset | rows | distinct | uniqueness |
|---|--:|--:|--:|
| taxi_d4 | 20.3 M | 14,681 | 0.072% (very low) |
| tpch_qty | 6.0 M | 50 | 0.0008% (extremely low) |
| tpch_extprice | 6.0 M | 933,900 | 15.6% (high) |

**The definitive contrast — optimized CPU (`histsum`) vs FPGA, same host, single warm runs:**

| dataset | distinct | CPU optimized | FPGA | outcome |
|---|--:|--:|--:|---|
| tpch_qty (low card) | 50 | ~0.021 s | ~0.021 s | **head-to-head** |
| tpch_extprice (high card) | 933,900 | ~0.105 s | ~0.053 s | **FPGA ~2×** |

Both tpch datasets have **0 IQR outliers** (bounded distributions; exact CPU and FPGA *agree* — the
`histsum` NULL is sum-over-empty = 0). Timing is valid regardless: both sides do the full
decode/histogram/quartile/scan work; the flag count doesn't change the work done.

**The reframed thesis (the headline that actually holds up):** the FPGA is **cardinality-independent**.
On low-cardinality data the CPU collapses duplicates (GROUP BY to 50 or 14,681 rows) and *matches or
beats* the FPGA; on high-cardinality data the CPU cannot collapse (934 K distinct) and the FPGA wins
**~2× even against the fastest hand-tuned CPU code**. Cardinality also drives **accuracy**: distinct >
1024 bins ⇒ quantization error (taxi_d4, 2701 ppm); distinct ≤ 1024 ⇒ bit-exact (tpch_qty). So the
honest claim is not one blended speedup but: **"matches the CPU on low-cardinality data, ~2× on
high-cardinality data, at cardinality-independent cost — the accelerator's niche is high cardinality."**

---

## 4. Fairness notes / threats to validity
- **Same binary, same host, same warm-cache protocol** for every system; identical query shape
  (outlier count) so all paths materialize the full result. Startup/flash/one-time FPGA context init
  excluded (amortized by warm-ups); this reflects a served, steady-state query.
- **FPGA number is the full product path** (decode + IQR + DuckDB emit), *not* a kernel microbench.
  Kernel-only sanity via `iqr_sim` (raw int64, no decode/DB) confirms correctness (`total=8192`,
  `collisions=0`) but is not used as a headline number.
- **The timed endpoints are symmetric, and if anything harder on the FPGA.** DuckDB's `.timer` wraps
  the whole statement for every system: start = raw parquet file, end = the single outlier count. The
  FPGA path additionally must **emit all 20.3 M `(value, is_outlier)` rows out through DuckDB's engine**
  to be counted (the ~9 ms emission), *inside* the timed region; `cpu_exact` fuses its final
  filter+count into its own pipeline with no such materialization. So the endpoint taxes the FPGA
  extra — the comparison is not rigged in its favour.
- **Timing is host-side wall clock, and it is a conservative *upper* bound on FPGA cost.** `wait_ms` is
  a `std::chrono` stopwatch around the blocking `get_next_batch()`; anything that delayed the query is
  captured (never an under-count), and it also absorbs queue/DMA-feed latency (so it slightly
  *over*-credits the FPGA). Overlapped FPGA cycles hidden behind host work are deliberately uncounted —
  they cost 0 wall clock. **The StreamProfiler is NOT used for the headline number:** its cycle counters
  see only the FPGA lane (blind to the ~54 ms of host work), and they never reset per query (accumulate
  until an explicit `profile.stop` the query path never issues). Using it would compare FPGA-kernel time
  against CPU-whole-query time and dishonestly flatter the FPGA ~7×. It is a *diagnostic* only
  (starved vs stalled vs handshakes). Recorded reading (input lane, 128 MiB, build-09):
  `handshakes=262144, starved=20%, stalled=0.3%` → **within the streaming window** the IQR compute is
  never the bottleneck (0.3% back-pressured) and the FPGA waits on PCIe 20% of the time (PCIe-bound
  signature). Distinct from the *end-to-end wall-clock* figure that the lane is active only ~0.05% of
  the whole query — that one includes emission/memcpy/decode where the FPGA isn't streaming at all. Do
  not conflate the two: 20% starved is *of the stream*, 0.05% active is *of the query*.
- **CPU-hist is a slightly pessimistic baseline:** it computes its window with two exact
  `quantile_disc` passes, whereas the FPGA uses a cheap stride sample. A sample-based SQL window would
  narrow the FPGA-vs-hist gap somewhat; we report the straightforward SQL implementation.
- **Scaling trend (measured): the advantage shrinks as data grows — it favors the CPU, not the FPGA.**
  This is the opposite of the usual accelerator story and worth stating plainly. The taxi series is a
  controlled experiment (same `fare_cents` column, more of it):

  | dataset | size | speedup | fpga MB/s | cpu MB/s |
  |---|--:|--:|--:|--:|
  | taxi_d1 | 3.8 MB | 1.92× | 291 | 151 |
  | taxi_d2 | 7.6 MB | 1.52× | 332 | 218 |
  | taxi_d3 | 17 MB | 1.34× | 385 | 287 |
  | taxi_d4 | 27 MB | 1.29× | 422 | 328 |
  | extprice_sf10 | 295 MB | 1.08× | 660 | 612 |

  Speedup falls monotonically with size; the largest dataset is ~parity. Both throughputs rise with
  size (fixed overhead amortizes) but **the CPU rises faster** and closes the gap. Two mechanisms:
  (1) the FPGA's end-to-end is dominated by **host plumbing that is strictly linear in rows** (emission
  bit-unpack, gather/memcpy, decode orchestration) — it pays the same per-row tax regardless of the
  values; (2) DuckDB's exact `GROUP BY value` scales **sub-linearly on bounded-cardinality columns**
  (taxi fares, TPC-H qty have few distinct values → the hash table stays small → extra rows are cheap
  increments), so the CPU gets *more efficient per row* at scale while the FPGA cannot. The FPGA's real
  edge is **cardinality-independence**: it wins biggest on high-cardinality, poorly-compressible data
  (`tpch_extprice` SF1 = 2.00×, where the CPU's hash table is large) — but even that collapses to 1.08×
  at 10× scale (sf10), because the linear host tax then dominates. *Earlier drafts of this section
  speculated the FPGA would do better at 10–100× the data; the sf10 point measured the opposite. That
  reasoning counted the FPGA amortizing its launch overhead but ignored that the CPU amortizes better.*
  Caveats: 7 points, sf10 is a single large point whose 1.08× is within cluster noise, and taxi d1→d4
  mildly confounds size with distribution — but the direction is consistent across the series and the
  scaled pair.

---

## 5. Reproduction
```bash
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
bash bench/correctness.sh | tee bench/correctness_out.txt   # Section 1
bash bench/perf.sh        | tee bench/perf_results.csv      # Section 2 (CPU + FPGA)
bash bench/perf_fpga.sh   | tee bench/perf_fpga.csv         # FPGA-only re-run
```
SQL models: `bench/sql/{correctness_cpu,correctness_fpga,exact_count,hist_count,fpga_count}.sql`.

---

## 6. The useful-product comparison — all timing codes (2026-07-18)

This section supersedes the earlier "scalar count" framing. **The count is not the useful product.**
`count(*) FILTER (WHERE is_outlier)` tells you *how many* outliers exist; it does not tell you *which
rows* are outliers — and only the latter lets a user actually filter, inspect, or remove them. Crucially,
the scalar count is the **one operation that most flatters the CPU**: DuckDB collapses 6M rows → 50
distinct groups and never materializes a per-row result, so on low-cardinality data the FPGA only *ties*.
The moment the deliverable becomes the **per-row product**, the CPU must expand back to all N rows and the
FPGA — which flags every row natively — wins on every cardinality.

Two orthogonal cost axes fall out of the measurements and are the core thesis:
- **FPGA host-CPU cost tracks OUTPUT size**, not cardinality (≈constant ~0.05 s CPU-time when 0 outliers).
- **CPU cost tracks CARDINALITY** (the `GROUP BY` grows), regardless of output.

So the FPGA is **cardinality-independent**; 32-core DuckDB is not.

All codes below are **whole queries** (embedded, not referenced). They are identical across datasets
except the path/column — substitute from this table:

| dataset | path | column | cardinality | outliers (FPGA / CPU) |
|---|---|---|---|---|
| tpch_qty (low card) | `/home/myaksi/datasets/tpch_qty.parquet` | `v` | 50 | 0 / 0 |
| tpch_extprice (high card) | `/home/myaksi/datasets/tpch_extprice.parquet` | `v` | 933,900 | 0 / 0 |
| taxi_d4 (mid card, real outliers) | `/home/myaksi/datasets/taxi_d4.parquet` | `fare_cents` | 14,681 | 2,112,164 / 2,057,243 |

Session setup for every run: `PRAGMA threads=32; .timer on;` — run each `CREATE` 3× and take the warm one.

### 6.1 CPU-exact code — the stage-by-stage evolution

Every stage produces the **identical, canonical** outlier decision (validated in §7); they differ only in
how much work they do. Stages 1–3 output the scalar **count**; stage 3.5 is the first (non-optimized)
per-row attempt that decodes the file twice; stage 4 is the optimized **useful per-row product** we compare.

**Stage 1 — Traditional (non-optimized) DuckDB, built-in `quantile_disc`.** The "naive user writes this"
baseline. ~7–10× slower because the built-in quantile cannot exploit low cardinality — it processes all N.
```sql
WITH s AS (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),
q AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
f AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT count(*) FROM s,f WHERE s.v<f.lo OR s.v>f.hi;
```

**Stage 2 — GROUP BY optimization (`groupby_current`).** Collapse duplicates into a histogram, derive
Q1/Q3 from the cumulative counts (integer, divider-free: `cc*4>=t` is the 25th percentile), 1.5×IQR fences
via shifts (`x+(x>>1)`). Still **re-scans all N rows** at the end to count.
```sql
WITH s AS (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT count(*) FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi;
```

**Stage 3 — Output-side optimization (`groupby_histsum`).** The per-value counts already exist in `ecnt`,
so count the outliers by **summing the histogram** instead of re-scanning all N rows. ~24% faster than
stage 2 (warm). `COALESCE` because `sum()` over an empty set is NULL, not 0. *Only the CTE body from stage
2 is reused; the final line changes:*
```sql
-- ... identical s / ecnt / etot / ecum / eq / ef CTEs as Stage 2 ...
SELECT COALESCE(sum(c),0) FROM ecnt,ef WHERE ecnt.v<ef.lo OR ecnt.v>ef.hi;
```
**Status: retained for the scalar-count case, but NOT used for the useful product.** `histsum` is a
count-only trick — it works because you can sum the histogram to get a *number*. It does **not** apply once
the output is a per-row mask/rows: producing a flag for every row cannot be collapsed to the histogram.
Kept here for completeness (and it is the right CPU code if a user only wants the count).

**Stage 3.5 — First per-row attempt (non-optimized: decodes the file TWICE).** The naive way to go from
count to per-row: a plain `s AS (...)` CTE, and store both the value and the flag. `s` is referenced twice
(once to build the histogram `ecnt`, once in the final labeling join `FROM s, ef`), and **without
`MATERIALIZED` DuckDB re-reads/re-decodes the parquet for each reference** — so the file is decoded twice.
Measured **0.196 s warm / 0.571 CPU-s** on tpch_qty (the FPGA was 0.167 s here). This is the version we
tried first and then optimized away.
```sql
CREATE OR REPLACE TABLE cpu_flags AS
WITH s AS (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),   -- NOTE: no MATERIALIZED -> decoded twice
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT s.v, (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;  -- also stores the redundant value
```
Two fixes turned this into Stage 4: **(a)** add `AS MATERIALIZED` to `s` → the parquet is decoded **once**
and reused (fair vs the FPGA, which also decodes once and passes twice); **(b)** drop the redundant `s.v`
column when only the mask is wanted (flag-only). Together these took tpch_qty from **0.196 → 0.064 s**
(full mask) and **0.040 s** (outlier rows only).

**Stage 4 — Useful product (per-row), the fair CPU we compare.** Two forms; both add
`AS MATERIALIZED` so the parquet is **decoded once** (fair vs the FPGA, which decodes once and passes
twice — without it DuckDB re-decodes the file for the labeling pass, as Stage 3.5 shows).

*4a — full per-row flag mask (aligned to every row, held in RAM):*
```sql
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
```
*4b — outlier rows only (inline filter; never materializes the full mask):*
```sql
CREATE OR REPLACE TABLE outliers AS
WITH s AS MATERIALIZED (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT s.v FROM s, ef WHERE s.v < ef.lo OR s.v > ef.hi;
```

### 6.2 FPGA code — the three stages

The FPGA compute (decode + two IQR passes on the histogram) is **identical** in all three; only the host
*output handling* changes. Two functions ship in the oasis extension: `iqr_flags` → `(value, is_outlier)`
per row; `iqr_flags_only` → just the `is_outlier` boolean (the pure mask, half the output — no value echoed).

**Stage 1 — scalar count** (fastest FPGA number, but not the useful product):
```sql
SELECT count(*) FILTER (WHERE f) FROM iqr_flags('<PATH>','<COL>') t(v,f);
```
**Stage 2 — full per-row flag mask into RAM** (the useful product; `iqr_flags_only` = flag-only, leanest):
```sql
CREATE OR REPLACE TABLE mask AS SELECT is_outlier FROM iqr_flags_only('<PATH>','<COL>');
```
**Stage 3 — outlier rows only** (inline filter; needs the value, so `iqr_flags`):
```sql
CREATE OR REPLACE TABLE outliers AS SELECT v FROM iqr_flags('<PATH>','<COL>') t(v,f) WHERE f;
```

### 6.3 Timing results (useful product, warm; single runs — medians pending)

**Stage 4b / FPGA stage 3 — outlier rows (inline filter):**

| dataset | FPGA (real) | CPU (real) | FPGA speedup | FPGA CPU-s | CPU CPU-s | CPU-work ratio |
|---|--:|--:|--:|--:|--:|--:|
| tpch_qty (low) | **0.040** | 0.063 | **1.58×** | 0.045 | 0.482 | **10.7×** |
| tpch_extprice (high) | **0.073** | 0.125 | **1.71×** | 0.051 | 1.619 | **31.7×** |
| taxi_d4 (20M, 2.1M outliers) | **0.266** | 0.332 | **1.25×** | 0.315 | 1.637 | **5.2×** |

**Stage 4a / FPGA stage 2 — full per-row mask materialized (flag-only), ALL 7 datasets (2026-07-20):**

The useful product: **one `is_outlier` boolean for EVERY row** (not just outlier rows — that is 4b),
materialized with `CREATE TABLE` on both sides so the storage tax is identical. FPGA = `iqr_flags_only`,
CPU = the optimized GROUP BY histogram → divider-free quartiles → fences → per-row compare. Warm runs.
Repro: `bash bench/stage4a_all.sh` (or the per-dataset codes in §6.5).

| dataset | rows | FPGA (real) | CPU (real) | **FPGA speedup** | FPGA CPU-s | CPU CPU-s | CPU-work ratio |
|---|--:|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | **0.034** | 0.063 | **1.85×** | 0.030 | 0.354 | 11.8× |
| tpch_qty | 6.0M | **0.062** | 0.092 | **1.48×** | 0.061 | 0.526 | 8.6× |
| taxi_d2 | 6.0M | **0.061** | 0.100 | **1.64×** | 0.068 | 0.537 | 7.9× |
| tpch_extprice | 6.0M | **0.095** | 0.161 | **1.69×** | 0.067 | 1.745 | **26.0×** |
| taxi_d3 | 13.1M | **0.128** | 0.198 | **1.55×** | 0.174 | 1.211 | 7.0× |
| taxi_d4 | 20.3M | **0.197** | 0.297 | **1.51×** | 0.272 | 1.833 | 6.7× |
| tpch_extprice_sf10 | 60.0M | **0.842** | 1.048 | **1.24×** | 0.798 | 11.109 | 13.9× |

**The FPGA wins on ALL SEVEN datasets, 1.24×–1.85×** — every cardinality, 3M to 60M rows. Two structural
findings the table makes plain:
- **Host CPU is the bigger story: the FPGA uses 6.7×–26× less** (`user` column). The outlier math runs on
  chip; the host only decodes and stores. In a busy database that freed CPU serves other queries.
- **The speedup shrinks as the data gets harder to decode** (1.85× on taxi_d1 → 1.24× on sf10), because
  the FPGA's single hardware decoder becomes the bottleneck on high-cardinality columns while DuckDB
  decodes across 32 threads. That is the decode-bound effect measured in §8.1/§8.2 — and it is exactly
  what more decoder lanes would recover (§8.6), not an IQR-core limitation (the core never stalls).

**Reading the numbers:**
- **The low-card tie is gone.** On the scalar count tpch_qty was 0.021 = 0.021 (tie). On the useful product
  the FPGA wins **1.58×** (outlier rows) / **1.44×** (full mask). The tie was an artifact of the CPU
  collapsing its output; asking for per-row results removes that shortcut.
- **CPU-work ratio (the `user` column) is the headline.** The FPGA uses **5–32× less host CPU** — because
  the outlier math runs on the chip; the host only decodes + stores. In a busy DB that freed CPU serves
  other queries. FPGA `user` is flat (~0.05) at 0 outliers and rises only with *output* (taxi = 0.315);
  CPU `user` balloons with *cardinality* (0.48 → 1.62).
- **Materializing the output is a shared tax.** The ~40 ms gap between the scalar count (~0.025) and the
  mask-in-RAM (~0.064) is DuckDB writing 6M values into a table — paid equally by both sides, so the
  comparison stays fair. Filtering to outlier rows inline (4b) avoids storing the full mask and is faster
  than the full mask on 0-outlier data (0.040 vs 0.064 on tpch_qty).
- **`iqr_flags_only` vs `iqr_flags`:** flag-only halves the FPGA output (no value re-emitted) — use it when
  you want the mask to apply to your own table; use `iqr_flags` when you need the values (e.g. filtering to
  outlier rows).

### 6.4 CPU-exact implementation sweep — which quartile method is fastest (2026-07-19)

The output is now fixed as the **flag array** (the useful product), and the labeling pass
(`SELECT (v<lo OR v>hi) FROM s,ef`) is **identical** for every implementation — so the only thing that
changes the CPU cost is **how Q1/Q3 are computed**. We swept 5 methods, all producing the identical mask,
all with `s AS MATERIALIZED` (decode once) + `CREATE OR REPLACE TABLE mask` (equal storage tax). The
"maybe it's faster without GROUP BY" idea was the motivation. Codes for all five are in §6.5; runnable as
`bench/sql/cpu_variants/approach{1..5}.sql` (runner `bench/cpu_flag_variants.sh`).

**tpch_qty (low cardinality, ~50 distinct of 6.0M rows), warm:**

| # | method | `real` (s) | `user` (CPU-s) | vs baseline | correct? |
|---|---|--:|--:|--:|:--:|
| **1** | **GROUP BY histogram + cumulative window** | **0.092** | 0.529 | **1.00× (winner)** | exact |
| 2 | no GROUP BY — `quantile_disc([.25,.75])` single pass | 0.603 | 1.418 | 6.6× slower | exact |
| 3 | no GROUP BY — `percentile_disc WITHIN GROUP` | 0.733 | 1.432 | 8.0× slower | exact |
| 4 | full sort — `row_number()` nearest-rank | 3.381 | 44.844 | 36.8× slower | exact |
| 5 | `approx_quantile` (t-digest) | 0.380 | 3.711 | 4.1× slower | **approx** |

**Verdict — the GROUP BY baseline is already optimal on low cardinality; the "no GROUP BY" idea loses.**
- **Dropping GROUP BY is a *pessimization* here.** The histogram collapses 6.0M rows → ~50 distinct
  *before* any quartile math; every method that skips it (2,3,4,5) must process all 6M and is 4–37× slower.
  The collapse is exactly why the baseline was already winning.
- **`quantile_disc` vs `percentile_disc` are the same engine path** (0.603 vs 0.733, within noise) — both
  do a full selection over 6M. No planner advantage from the ordered-set syntax.
- **Full sort (4) is catastrophic: 84× more CPU** (44.8 vs 0.53 CPU-s) — it sorts all 6M *and* computes a
  window count. This is the concrete cost of the "naive, no-helper" approach; keep it as the cautionary
  data point.
- **`approx_quantile` (5) is the fastest *non-*GROUP-BY method (0.380) but still 4× slower than the
  baseline** — and it is **approximate** (t-digest), so it is disqualified from the canonical path unless
  the §6.5 correctness check shows bit-exact quartiles on a given dataset. Not worth it here: slower *and*
  riskier.
- **Caveat — this is the LOW-card result only.** On high cardinality (tpch_extprice, taxi_d4) the GROUP BY
  collapse shrinks (few duplicates), so methods 2/3 may close the gap or win; that sweep is **pending**. If
  they win there, the right CPU baseline becomes **cardinality-adaptive** (GROUP BY when distinct-count is
  small, `quantile_disc` otherwise) — a finding to add once measured.

### 6.5 CPU-exact implementation sweep — all five codes

All five differ only in the `q`/`ef` block (quartile computation); the `s` CTE and the final
`SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef` labeling are identical. Shown on tpch_qty;
swap the `read_parquet` path + column (`v` / `fare_cents`) for the other datasets.

*Approach 1 — GROUP BY histogram + cumulative window (baseline, winner on low-card):*
```sql
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('<PATH>')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq  AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
               (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef  AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
```
*Approach 2 — no GROUP BY, single-pass `quantile_disc` list:*
```sql
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('<PATH>')),
q  AS (SELECT quantile_disc(v, [0.25, 0.75]) qq FROM s),
ef AS (SELECT qq[1] q1, qq[2] q3,
              qq[1]-((qq[2]-qq[1])+((qq[2]-qq[1])>>1)) lo,
              qq[2]+((qq[2]-qq[1])+((qq[2]-qq[1])>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
```
*Approach 3 — no GROUP BY, ordered-set `percentile_disc WITHIN GROUP`:*
```sql
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('<PATH>')),
q  AS (SELECT percentile_disc(0.25) WITHIN GROUP (ORDER BY v) q1,
              percentile_disc(0.75) WITHIN GROUP (ORDER BY v) q3 FROM s),
ef AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
```
*Approach 4 — full sort, `row_number()` nearest-rank (cautionary: 84× CPU):*
```sql
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('<PATH>')),
r  AS (SELECT v, row_number() OVER (ORDER BY v) rn, count(*) OVER () n FROM s),
q  AS (SELECT max(v) FILTER (WHERE rn = CAST(ceil(0.25*n) AS BIGINT)) q1,
              max(v) FILTER (WHERE rn = CAST(ceil(0.75*n) AS BIGINT)) q3 FROM r),
ef AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
```
*Approach 5 — `approx_quantile` (fast but APPROXIMATE — correctness-gated):*
```sql
CREATE OR REPLACE TABLE mask AS
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('<PATH>')),
q  AS (SELECT CAST(approx_quantile(v,0.25) AS BIGINT) q1,
              CAST(approx_quantile(v,0.75) AS BIGINT) q3 FROM s),
ef AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM q)
SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
```
*Correctness cross-check (all quartile columns must match; `approx` may differ):*
```sql
WITH s AS MATERIALIZED (SELECT v::BIGINT v FROM read_parquet('<PATH>')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
a AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t) q1,
             (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
b AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
c AS (SELECT percentile_disc(0.25) WITHIN GROUP (ORDER BY v) q1,
             percentile_disc(0.75) WITHIN GROUP (ORDER BY v) q3 FROM s),
r AS (SELECT v, row_number() OVER (ORDER BY v) rn, count(*) OVER () n FROM s),
d AS (SELECT max(v) FILTER (WHERE rn=CAST(ceil(0.25*n) AS BIGINT)) q1,
             max(v) FILTER (WHERE rn=CAST(ceil(0.75*n) AS BIGINT)) q3 FROM r),
e AS (SELECT CAST(approx_quantile(v,0.25) AS BIGINT) q1,
             CAST(approx_quantile(v,0.75) AS BIGINT) q3 FROM s)
SELECT a.q1 gb, b.q1 qd, c.q1 pd, d.q1 rn, e.q1 approx,
       a.q3 gb3, b.q3 qd3, c.q3 pd3, d.q3 rn3, e.q3 approx3
FROM a,b,c,d,e;
```

---

## 7. Correctness — all test codes and the logic (2026-07-18)

The outlier flag is a **deterministic function of the value**: `flag = (v < lo OR v > hi)` with one global
fence pair. Every row sharing a value therefore gets the same flag. This underpins the whole method: a
naive positional zip of two flag arrays is fragile (DuckDB's 32-thread scan does not guarantee row order,
and the data has no unique row key), but carrying each row's **value** and re-deciding it is a *true*
line-by-line check that is order-independent. `bench/sql/correctness_{rowwise,consistency,disagree_detail,
cpu_vs_builtin}.sql` + `bench/correctness_rowwise.sh`.

The full validation chain (both links proven **row-by-row**):
```
stock DuckDB quantile_disc  ==  our optimized CPU   →  0 disagree rows (bit-identical)
our optimized CPU           ≈   FPGA                →  0 on tpch_qty/extprice; 54,921 on taxi_d4
                                                         (2701 ppm, one-directional, boundary-confined)
FPGA internal consistency   →   0 values flagged both ways (clean threshold)
⇒ the FPGA is validated against canonical DuckDB, transitively.
```

### 7.1 FPGA vs CPU-exact — per-row agreement (the main test)
Compares the FPGA's **actual** per-row flag against the CPU-exact decision on **every row**. `agree_rows +
disagree_rows` must equal `total_rows`.
```sql
WITH
s    AS MATERIALIZED (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq),
fp   AS (SELECT v, f AS fpga FROM iqr_flags('<PATH>','<COL>') t(v,f))
SELECT count(*) AS total_rows,
       count(*) FILTER (WHERE fp.fpga)                               AS fpga_outliers,
       (SELECT count(*) FROM s,ef WHERE s.v<ef.lo OR s.v>ef.hi)      AS cpu_outliers,
       count(*) FILTER (WHERE fp.fpga = (fp.v<ef.lo OR fp.v>ef.hi))  AS agree_rows,
       count(*) FILTER (WHERE fp.fpga <> (fp.v<ef.lo OR fp.v>ef.hi)) AS disagree_rows,
       round(1e6*count(*) FILTER (WHERE fp.fpga<>(fp.v<ef.lo OR fp.v>ef.hi))/count(*),3) AS disagree_ppm
FROM fp, ef;
```

### 7.2 FPGA internal consistency (catches non-threshold bugs)
Every value must get **one** flag — result MUST be 0. This is what the count-only test could never verify.
```sql
SELECT count(*) AS values_with_inconsistent_flags
FROM (SELECT v FROM iqr_flags('<PATH>','<COL>') t(v,f) GROUP BY v HAVING count(DISTINCT f) > 1);
```

### 7.3 Disagreement detail (the *which* and *why*)
The specific values that differ — always in the 1024-bin quantization band at the fence. Empty = bit-exact.
```sql
WITH
s    AS MATERIALIZED (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq),
fpv  AS (SELECT v, bool_or(f) AS fpga_flag, count(*) AS rows
         FROM iqr_flags('<PATH>','<COL>') t(v,f) GROUP BY v)
SELECT fpv.v value, fpv.rows, fpv.fpga_flag, (fpv.v<ef.lo OR fpv.v>ef.hi) exact_flag, ef.lo, ef.hi
FROM fpv, ef WHERE fpv.fpga_flag <> (fpv.v<ef.lo OR fpv.v>ef.hi) ORDER BY fpv.rows DESC LIMIT 20;
```

### 7.4 Optimized CPU vs stock DuckDB (validates the baseline itself)
Confirms the GROUP BY optimization did not change the answer vs canonical `quantile_disc` (discrete = the
right oracle; `quantile_cont` interpolates and differs by design). Fence-level match ⇒ per-row match,
because both apply the identical `v<lo OR v>hi` rule to identical data — only the fence *values* could differ.
```sql
WITH
s    AS MATERIALIZED (SELECT <COL>::BIGINT v FROM read_parquet('<PATH>')),
trad AS (SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s),
tf   AS (SELECT q1,q3,q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM trad),
ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
etot AS (SELECT sum(c) t FROM ecnt),
ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
oq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t) q1, (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
of   AS (SELECT q1,q3,q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM oq)
SELECT tf.q1 trad_q1, of.q1 opt_q1, tf.q3 trad_q3, of.q3 opt_q3,
       (tf.q1=of.q1 AND tf.q3=of.q3) quartiles_match,
       tf.lo trad_lo, of.lo opt_lo, tf.hi trad_hi, of.hi opt_hi,
       (tf.lo=of.lo AND tf.hi=of.hi) fences_match,
       (SELECT count(*) FROM s WHERE s.v<tf.lo OR s.v>tf.hi) trad_outliers,
       (SELECT count(*) FROM s WHERE s.v<of.lo OR s.v>of.hi) opt_outliers
FROM tf, of;
```
Explicit per-row form (for symmetry with 7.1):
```sql
-- ... same s / trad / tf / ecnt.. / of CTEs (fences only) ...
SELECT count(*) total_rows,
       count(*) FILTER (WHERE (s.v<tf.lo OR s.v>tf.hi) <> (s.v<of.lo OR s.v>of.hi)) disagree_rows
FROM s, tf, of;
```

### 7.5 Correctness results

| dataset | 7.1 FPGA↔CPU disagree | ppm | 7.2 consistency | 7.4 CPU↔builtin |
|---|--:|--:|--:|---|
| tpch_qty | **0** (bit-exact) | 0 | 0 | quartiles/fences/count **identical**, 0 disagree rows |
| tpch_extprice | 0 (verified correct) | ~0 | 0 | identical, 0 disagree rows |
| taxi_d4 | 54,921 | 2701 | 0 | Q1/Q3 930/2190, fences −960/4080, count 2,057,243 — **identical**, 0 disagree rows |

Key observations:
1. **`disagree_rows` on taxi_d4 = `fpga_outliers − cpu_outliers` exactly** (54,921 = 2,112,164 − 2,057,243).
   So the binning error is **one-directional**: the FPGA over-flags 54,921 boundary rows and **misses zero**
   true outliers — the safe/conservative direction for outlier detection.
2. **Every disagreeing value lies in [4049, 4080]**, right at the exact upper fence (`hi = 4080`); the single
   value 4080 accounts for 46,760 of them. It is pure 1024-bin quantization at the fence, not scatter.
3. **tpch_qty is bit-exact** because 50 distinct values fit inside 1024 bins (no quantization). Low
   cardinality ⇒ exact FPGA; >1024 distinct ⇒ small, bounded, one-sided error.
4. **The CPU baseline is canonical** — bit-identical to stock DuckDB `quantile_disc`, so the entire
   FPGA-vs-CPU comparison rests on the standard DuckDB answer, not a hand-rolled approximation.

---

## 8. Measured FPGA time breakdown + optimization roadmap (2026-07-20)

Instrumented the FPGA's actual time-spend with the RTL **StreamProfiler** (cycle counters on the IQR
input/output, surfaced in the DuckDB path via `[iqr-prof]` lines under `OASIS_IQR_TIMING=1`, base-snapshot
subtracted since the counters are cumulative). Repro: `bash bench/fpga_profile.sh` (host wall-clock `[iqr]`
+ FPGA-internal `[iqr-prof]`). Handshakes read **exactly 2N/8** every run, so the numbers are validated.

### 8.1 The full breakdown — all 7 datasets (warm, ms)

| dataset | rows | decode | ⤷ fpga_wait | ⤷ copy | passes | **heavy** | in.starved | eff GB/s |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 6.2 | 1.3 | 1.9 | 3.8 | **10.5** | 21.0% | 12.4 |
| tpch_qty | 6.0M | 8.8 | 2.6 | 2.9 | 7.7 | **17.0** | 21.0% | 12.5 |
| taxi_d2 | 6.0M | 10.0 | 2.9 | 3.1 | 7.7 | **18.2** | 21.1% | 12.5 |
| taxi_d3 | 13.1M | 18.8 | 5.7 | 6.5 | 16.6 | **36.1** | 20.5% | 12.6 |
| taxi_d4 | 20.3M | 27.3 | 8.8 | 9.2 | 25.8 | **53.8** | 20.7% | 12.6 |
| tpch_extprice | 6.0M | **41.1** | **29.3** | 3.2 | 7.7 | **49.6** | 21.1% | 12.5 |
| tpch_extprice_sf10 | 60.0M | **358.9** | **249.3** | 33.3 | 76.9 | **436.4** | 21.6% | 12.5 |

`heavy ≈ decode + passes`. `fpga_wait` = blocked on the decoder HW; `copy` = the host memcpy gather.

### 8.2 What holds everywhere, and the bimodal bottleneck

**Scale- and cardinality-invariant** (3M → 60M rows, low card → high): input **starved ≈ 21%**, **stalled
≈ 0%**, **eff ≈ 12.5 GB/s** (PCIe line rate vs the 16 GB/s core ceiling). Output is always ~1.2% busy (the
bitmask is 128× smaller than the input — a non-issue). The core **never stalls** → it is purely PCIe-fed,
never compute-bound; every lever must target *feeding* it. Passes scale linearly at ~1.28 ms/M rows.

**The one wild variable is decode, and it splits the data into two families:**
- **Data-movement-bound (taxi, compressible):** decode ≈ passes; `fpga_wait` ~0.44 ms/M. Addressable
  ≈ 26% (the 21% starvation + the memcpy) → HBM/tap + memcpy-removal ≈ **1.35×**.
- **Decode-bound (tpch_extprice/sf10, hard to compress):** `fpga_wait` ~4.5 ms/M (**10×** taxi) and is
  **57–83% of the whole query** (249 ms of sf10's 436 ms). HBM barely helps; the **decoder** is the wall.

### 8.3 Largest-dataset head-to-head — sf10 (60M rows), useful product = flag array

`CREATE TABLE mask AS ...` both sides (equal materialization); warm. Codes: `bench/sf10_fpga.sql`
(`iqr_flags_only`) and `bench/sf10_cpu.sql` (Stage-4a GROUP BY mask).

| | real (wall) | user (CPU-s) | speedup / ratio |
|---|--:|--:|--:|
| **FPGA** | **0.886** | **0.79** | — |
| CPU-exact @32 | 1.066 | 10.25 | **1.20× / 13× less CPU** |

**The FPGA wins even on the largest, most decode-hostile dataset** (the earlier "may lose" prediction was
wrong): its slow single decoder (~360 ms) still beats DuckDB's cardinality cost — a GROUP BY + window +
full 60M mask over 60M high-card values burns **10.25 CPU-s across 32 threads**. Confirms the two-axis
thesis at scale: FPGA cost tracks output size (flat 0.79 CPU-s); CPU cost tracks cardinality (10.25 CPU-s).

### 8.4 PCIe accounting — 5 transfers, and which matter

The decoded column crosses PCIe **3×** (FPGA→host after decode, then host→FPGA for each pass), plus the
compressed input (host→FPGA, once) and the flag bitmask (FPGA→host). For taxi_d4: compressed ~28 MB,
decoded 163 MB ×3, flags ~1.3 MB. **The 3 decoded-column crossings = ~94% of PCIe traffic** — the whole
optimization target. The compressed input is small and unavoidable (data must reach the card); the flags
are negligible. The window sample is **not** an extra crossing — it reads the already-in-host column and
sends only `bin_min`/`bin_shift` as tiny CSR control writes.

### 8.5 HBM viability — the finding so far

- **Production build-11 has `EN_MEM=0`** → no HBM stack in the design at all (`OASIS_IQR_USE_CARD=1`
  cannot work on it). Every shipped build (09/10/11) reads `EN_MEM=0`.
- **build-09 *was* the `EN_MEM=1` HBM build** (full `design_hbm_*` IP present), **but its HBM AXI
  read-data path failed timing** — WNS −0.429, biggest failing cluster (237 paths) on
  `inst_int_hbm/.../axi_downsizer_inst/USE_READ.read_data_inst`. A failing read handshake → the measured
  8–11 MB/s card reads. This is a **P&R timing failure in our congested design**, not proven a platform
  limit. (`EN_MEM=1` = HBM ON; the earlier belief that HBM needs `EN_MEM=0` is backwards.)
- Also, the coded HBM path (`stage_to_card`) uses the **migration DMA** (`LOCAL_OFFLOAD`, 4 KB/cmd) and is
  **receive-only** — it re-spends the PCIe budget instead of the FPGA-initiated `sq_wr(STRM_CARD)` the
  `07_perf_fpga` example shows. The card write path (`axis_card_send`) is tied off in our vFPGA.
- **Viability test (in progress):** build tiny `hello_world` with `EN_MEM=1` (trivial logic → HBM timing
  should close) and measure `-s 0` (card) vs `-s 1` (host). Fast → platform fine, our issue is
  congestion (fixable); slow → HBM dead here. `make project` needs `TERM` set (Coyote's tcl error printer
  calls `tput`, which aborts in a bare shell) — pending re-run.

### 8.6 The optimization roadmap (measure-gated, cheapest first)

1. **Phase 1 — remove the host memcpy (software only, no bitgen, no HBM).** Stream the per-chunk decoded
   buffers instead of gathering. Two tiers: **aligned files → zero copy** (DuckDB's 122,880-row groups are
   multiples of 8; tpch), **odd files → remainder-carry stitch** (taxi's <8-element boundaries via ~64 B
   stitch beats, ~10 KB total vs 163 MB). Saves the `copy` column (3–33 ms). Guard: `correctness_rowwise`
   must stay bit-exact (tpch) / exactly 54,921 disagree (taxi) — the failure mode is silent misalignment
   (the FlagBitPacker advances 8 bits/beat, so a mid-stream partial beat shifts all later flags).
2. **Phase 0 gate for bitstream work:** (a) run sf10 CPU-vs-FPGA — done, FPGA wins; (b) prove HBM viable
   (§8.5) before any HBM build.
3. **Phase 2 — attack the exposed bottleneck:** decode-bound (extprice/sf10) → **more decoder lanes**
   (biggest lever there, 249 ms of fpga_wait); data-movement-bound (taxi) → **HBM/tap** if viable
   (removes the 21% starvation; ~1.3×, capped by the 16 GB/s core).
4. **Phase 3 — after the feed is fixed:** raise the core ceiling (wider datapath / 2nd lane); bin-midpoint
   quartile for accuracy. Neither matters until PCIe/decode stop starving the core.

**Framing:** the FPGA already beats 32-thread DuckDB on every dataset (incl. sf10, 1.20×); these all
*feed the core better* — none touch the compute, which never stalls.

---

## 9. Replacing the SQL baseline with a C++ operator (2026-07-21)

### 9.1 Why the SQL baseline had to go

Up to §8 the head-to-head was **asymmetric**: the FPGA side was a C++ table function invoked by one
line of SQL, while the CPU side was the *algorithm itself written in SQL* (6 CTEs, a GROUP BY, a
window function, correlated subqueries). That does not measure FPGA vs CPU. It measures:

> **FPGA operator** vs **(CPU algorithm + DuckDB's parser, binder, optimizer and general-purpose executor)**

The second term is overhead introduced by the choice of container, not by the CPU. Three consequences:

1. **The baseline is unfalsifiable.** Any reviewer can claim a faster query exists, and nothing in the
   paper can refute it.
2. **The number is dominated by phrasing, not by hardware.** §6.5 measured the *same algorithm* written
   five ways in SQL: **0.092 s, 0.380, 0.603, 0.733, 3.381 s — a 37× spread.** A baseline that moves 37×
   on rewording is not a measurement of the machine.
3. **It is unreadable.** No reviewer will verify that `cc*4>=3*t` inside a window function computes a
   third quartile.

### 9.2 What changed

`iqr_cpu_flags(path, column)` (`extension/src/oasis_iqr.cpp`) — the CPU twin of `iqr_flags_only`.
Both sides are now one line of SQL:

```sql
SELECT is_outlier FROM iqr_flags_only('f.parquet','v');   -- FPGA
SELECT is_outlier FROM iqr_cpu_flags ('f.parquet','v');   -- CPU
```

They share, **as the same code**: the bind and column validation (`ResolveIqrColumn`), the packed
1-bit-per-row mask layout, and the entire output path (`EmitFlagSlice`). The only difference is where
the quartiles and the fence comparison run. Each side uses its own best decoder — the FPGA its
on-chip ParCore decoder, the CPU DuckDB's native parquet reader — which is the fair pairing.

**Algorithm** (identical rule to the SQL, which resolves to plain order statistics):

| step | SQL form | C++ form |
|---|---|---|
| q1 | `min(v)` where `cc*4>=t` | the ⌈N/4⌉-th smallest value |
| q3 | `min(v)` where `cc*4>=3*t` | the ⌈3N/4⌉-th smallest value |
| fences | `q1-(d+(d>>1))`, `q3+(d+(d>>1))` | same, in `__int128` then clamped to the type |
| flag | `v < lo OR v > hi` | same, packed 8 flags/byte |

The quartiles use a **two-level histogram, not a sort**: one parallel min/max pass, one parallel
65536-bin pass to locate the bin holding each rank, then one parallel pass gathering only the two
winning bins and an `nth_element` inside them. O(N), bounded memory, every pass multithreaded at
`PRAGMA threads` — the same knob that governs the SQL baseline. This is deliberately the same shape
as the hardware's windowed histogram.

### 9.3 Verification — and one bug the first test failed to catch

**The first correctness run reported 0 mismatches on 4 of 7 datasets while the operator was returning
all-false.** Worth recording, because it is a trap this benchmark invites: `tpch_qty`,
`tpch_extprice` and `tpch_extprice_sf10` are uniform and contain **zero outliers**, so an
implementation that flags nothing agrees with them perfectly. Only the taxi datasets have real
outliers, and there the C++ side reported 0 against the FPGA's 317,554.

Root cause: `ReadColumnCpu` set the reader's `column_indexes` but not `column_ids`. DuckDB's
`ParquetReader::Schedule()` walks **`column_ids`** to decide which chunks to fetch, so no column data
was ever read; `std::vector::resize` zero-fills, giving q1 = q3 = 0, fences [0, 0], "outlier iff
v != 0" — and every value was 0. The row *count* still looked right because it comes from the footer.

Two things changed as a result:
1. `ReadColumnCpu` now asserts that each worker's row groups yielded exactly the number of values the
   footer promised, so a short read raises instead of silently zero-filling.
2. `bench/sql/cpu_op_correctness.sql` now prints the outlier count for **all three** implementations
   side by side, not just the mismatch columns. Agreement on a zero-outlier dataset is not evidence.

**Lesson for the writeup:** on this benchmark, "0 mismatches" is only meaningful on the taxi datasets.

### 9.3.1 Verification of the algorithm core

The quartile/fence/mask functions were extracted **verbatim** from the shipped source and tested
against a brute-force reference (full sort → direct index; naive flag loop) at 1, 4 and 32 threads:
sizes 1–40 (rank off-by-one), dense small ranges (the single-value-per-bin path), wide ranges (the
level-2 refinement path), constant columns, 95 %-skew, full-64-bit ranges straddling zero, unsigned
values above `INT64_MAX`, and both fence-clamping extremes. **All pass.**

The parquet read path is covered by a second standalone harness (no oasis/coyote, so it runs without
an FPGA): it drives the exact projection + `Scan` loop that ships and checks the values returned
against ground truth computed independently in pyarrow. taxi_d1 → `rows=2964624 min=-89900
max=500000 q1=860 q3=2050` and tpch_qty → `rows=6001215 min=1 max=50 q1=13 q3=38`, both exact. With
the `column_ids` line removed it reports `rows=0`, confirming the root cause above.

### 9.4 Expectation — state this before the numbers

**The speedup will drop, and may fall below 1× on the decode-bound datasets.** The C++ baseline
deletes real work the SQL baseline paid for (CTE materialization of the whole column, the sort behind
`sum(c) OVER (ORDER BY v)`, hash-aggregate build, correlated-subquery joins). That is the intended
outcome: **the previous margin was partly DuckDB's query machinery, and it should not have counted.**

The claim that survives unchanged is the **CPU-work ratio** (§6.3: 6.7–26× fewer CPU-seconds, FPGA
idle 99.95 % of the query). That is an *offload* claim — cores freed, energy, co-located queries — and
a faster CPU baseline barely moves it, because the FPGA path still does not burn cores.

### 9.5 Results — medians of 7 warm runs, replicated (`bench/medians.py`, 2026-07-21)

Measured twice: once alongside other activity, once on an idle alveo-u55c-10. **The replication agrees
to 0–1.1 % on FPGA operator time (sf10 to 0.1 %) and 0–7 % on the CPU side**, so the numbers below are
the quiet-machine run and can be treated as the reference measurement.

| dataset | rows | FPGA | ±% | **C++ CPU** | ±% | SQL | ±% | FPGA vs C++ | C++ vs SQL |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 0.035 | 6 | 0.039 | 8 | 0.054 | 17 | 1.11× | 1.38× |
| tpch_qty | 6.0M | 0.063 | 10 | 0.068 | 10 | 0.089 | 9 | 1.08× | 1.31× |
| taxi_d2 | 6.0M | 0.063 | 10 | 0.073 | 16 | 0.096 | 10 | 1.16× | 1.32× |
| tpch_extprice | 6.0M | 0.096 | 5 | 0.072 | 11 | 0.156 | 4 | **0.75×** | 2.17× |
| taxi_d3 | 13.1M | 0.134 | 10 | 0.137 | 8 | 0.192 | 11 | 1.02× | 1.40× |
| taxi_d4 | 20.3M | 0.205 | 8 | 0.208 | 10 | 0.281 | 17 | 1.01× | 1.35× |
| tpch_extprice_sf10 | 60.0M | 0.867 | 5 | 0.585 | 9 | 1.046 | 7 | **0.67×** | 1.79× |

The C++ baseline beats the SQL query on all seven (1.31–2.17×), so it cannot be dismissed as a
strawman. Comparing each ratio against the mean spread of the two implementations involved:

| dataset | ratio | difference | noise | verdict |
|---|--:|--:|--:|---|
| taxi_d1 | 1.11× | 11 % | 7 % | marginal FPGA |
| taxi_d2 | 1.16× | 16 % | 13 % | marginal FPGA |
| tpch_qty | 1.08× | 8 % | 10 % | **tie** |
| taxi_d3 | 1.02× | 2 % | 9 % | **tie** |
| taxi_d4 | 1.01× | 1 % | 9 % | **tie** |
| tpch_extprice | 0.75× | 25 % | 8 % | **FPGA loses** |
| tpch_extprice_sf10 | 0.67× | 33 % | 7 % | **FPGA loses** |

**End-to-end verdict: 3 ties, 2 marginal FPGA wins, 2 clear FPGA losses.** No end-to-end result is a
decisive FPGA win. This is a consequence of the shared DuckDB tax (§9.7), not of the accelerator.

### 9.5.1 CPU-seconds — the claim that survives

| dataset | FPGA | C++ | SQL | **C++/FPGA** | SQL/FPGA |
|---|--:|--:|--:|--:|--:|
| taxi_d1 | 0.029 | 0.083 | 0.311 | **2.84×** | 10.62× |
| tpch_qty | 0.068 | 0.114 | 0.490 | **1.67×** | 7.20× |
| taxi_d2 | 0.068 | 0.161 | 0.519 | **2.38×** | 7.65× |
| tpch_extprice | 0.067 | 0.178 | 1.688 | **2.66×** | 25.13× |
| taxi_d3 | 0.170 | 0.344 | 1.055 | **2.02×** | 6.21× |
| taxi_d4 | 0.263 | 0.589 | 1.575 | **2.24×** | 5.98× |
| tpch_extprice_sf10 | 0.801 | 1.822 | 10.983 | **2.28×** | 13.72× |

**1.67–2.84× less host CPU on every dataset**, including the two where the FPGA is slower in wall
clock. These gaps (67–184 %) are far outside the measurement noise, unlike the latency numbers. This
is the result to lead with.

### 9.5.2 Threats to validity — state these before a reviewer does

1. **The C++ baseline is probably still improvable.** It saturates only 1.9–3.9 cores, while DuckDB's
   SQL plan reaches 5–10. Further parallelisation would shrink or erase the FPGA's remaining margin.
   **The 1.07–1.34× should be read as an upper bound, not a converged result.**
2. **Both sides pay a large, identical DuckDB cost.** For taxi_d4 the heavy phase is ~54 ms (FPGA) and
   ~81 ms (C++), but both queries take ~200 ms end-to-end: the remainder is emitting 20 M rows through
   DuckDB vectors and materializing them. That fixed cost compresses every ratio toward 1.0, and it is
   the honest reason the wins are modest.
3. **The FPGA is an approximation, though a close one** (§9.6): bit-exact on 3 of 7 datasets, and
   99.73–100 % per-row decision accuracy on the rest (worst case taxi_d4, 2701 ppm). Quote it per-row;
   quoting it as "2.67 % of the outlier set" uses a denominator that overstates it ~10×.
4. Single warm run per cell; medians of 5–7 still pending.

### 9.6 Correctness result (`bench/sql/cpu_op_correctness.sql`, 2026-07-21)

| dataset | rows | n_fpga | n_cpp | n_sql | fpga_vs_cpp | **cpp_vs_sql** |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 2,964,624 | 317,554 | 318,801 | 318,801 | 1,247 | **0** |
| taxi_d2 | 5,972,150 | 625,445 | 628,322 | 628,322 | 2,877 | **0** |
| taxi_d3 | 13,069,067 | 1,328,108 | 1,328,270 | 1,328,270 | 162 | **0** |
| taxi_d4 | 20,332,093 | 2,112,164 | 2,057,243 | 2,057,243 | 54,921 | **0** |
| tpch_qty | 6,001,215 | 0 | 0 | 0 | 0 | **0** |
| tpch_extprice | 6,001,215 | 0 | 0 | 0 | 0 | **0** |
| tpch_extprice_sf10 | 59,986,052 | 0 | 0 | 0 | 0 | **0** |

**The C++ operator is bit-exact with the SQL baseline on every dataset** (`cpp_vs_sql = 0`, and the
outlier counts are identical). The CPU baseline is therefore validated: the two independent
implementations of the exact IQR rule agree on all 118 M rows tested.

**`fpga_vs_cpp` is the accuracy of the hardware, not a correctness failure.** On every dataset the
mismatch count *equals* the difference in outlier counts (1247 = 318801−317554, 2877, 162, 54921), so
every disagreement is one-directional — the signature of a slightly shifted fence, which is exactly
what the 1024-bin windowed histogram (§1) produces. It is not random corruption.

This run independently reproduces §1's numbers **exactly**, now against a second, independent exact
implementation (the C++ operator) rather than a SQL query — so the deviation is a property of the
hardware, confirmed twice by unrelated code paths:

| dataset | disagreeing rows | **ppm of rows** | decision accuracy | direction |
|---|--:|--:|--:|---|
| tpch_qty | 0 | **0** | 100 % | — (exact-fit, bin_shift=0) |
| tpch_extprice | 0 | **0** | 100 % | — |
| tpch_extprice_sf10 | 0 | **0** | 100 % | — |
| taxi_d3 | 162 | **12** | 99.9988 % | under-flags |
| taxi_d1 | 1,247 | **421** | 99.958 % | under-flags |
| taxi_d2 | 2,877 | **482** | 99.952 % | under-flags |
| taxi_d4 | 54,921 | **2701** | **99.73 %** | over-flags (misses zero true outliers) |

**Per-row decision accuracy is 99.73–100 %**, and three of seven datasets are bit-exact. taxi_d4 is
the worst case at 2701 ppm (0.27 % of rows), and §1 already traced it to bin-edge quantization in the
auto-window placement — with the useful property that it is a pure **over-flag**: it adds false
positives in the narrow 4048–4080 band at the fence and **misses zero true outliers**. The known fix
(bin-MIDPOINT quartile, one adder, no latency or resource cost) simulates to ~25× better.

So the honest sentence for the paper is *"the FPGA agrees with exact IQR on 99.73–100 % of rows, and is
bit-exact wherever the value range fits the bins"* — not a claim of bit-exactness, but not a
meaningful accuracy concession either.

---

### 9.7 Operator time vs the shared DuckDB tax — medians of 7, replicated (2026-07-21)

`heavy` = everything before DuckDB emits a row. `real − heavy` = DuckDB materializing the mask, which
neither implementation controls.

| dataset | FPGA op | ±% | C++ op | ±% | **operator ratio** | verdict | tax F | tax C | tax share |
|---|--:|--:|--:|--:|--:|---|--:|--:|--:|
| taxi_d1 | 11.0 | 4 | 17.2 | 7 | **1.57×** | FPGA wins | 24.0 | 21.8 | 69 % |
| taxi_d2 | 18.1 | 8 | 21.8 | 24 | **1.20×** | marginal FPGA | 44.9 | 51.2 | 71 % |
| tpch_qty | 17.5 | 6 | 18.1 | 20 | 1.03× | tie | 45.5 | 50.0 | 72 % |
| taxi_d3 | 37.0 | 3 | 32.2 | 14 | 0.87× | marginal CPU | 97.0 | 104.8 | 72 % |
| taxi_d4 | 56.0 | 2 | 45.5 | 11 | **0.81×** | FPGA loses | 149.0 | 162.5 | 73 % |
| tpch_extprice | 49.6 | 2 | 21.4 | 27 | **0.43×** | FPGA loses | 46.4 | 50.5 | 48 % |
| tpch_extprice_sf10 | 437.1 | 0 | 98.5 | 14 | **0.23×** | FPGA loses | 429.9 | 486.4 | 50 % |

**1. The DuckDB tax is 48–73 % of every query** and near-identical on both sides (149.0 vs 162.5;
429.9 vs 486.4). That near-equality is what licenses treating it as overhead rather than as part of
either operator — and it is why the end-to-end table collapses almost everything to a tie.

**2. Isolating the operator recovers the signal that end-to-end averages away, in both directions.**
taxi_d1's 1.57× operator win reads as a 1.11× marginal end-to-end; sf10's 4.3× operator loss reads as
0.67×. **Both tables must be published**: end-to-end is the user experience, operator time is the
hardware contribution.

**3. Hardware is far more repeatable than software.** FPGA `heavy` spreads are **0–8 %** (sf10: 0 %),
the C++ operator's are **7–27 %**, from thread-spawn and OS-scheduler jitter. Across the two
independent measurement sessions the FPGA operator times reproduced to **0–1.1 %** and sf10 to
**0.1 %** — the FPGA numbers are essentially exact, and every significant verdict has a margin well
outside both spreads.

**4. The FPGA's losses are entirely the decoder.** On sf10 the FPGA operator is **4.4× slower** than
the CPU operator (437.1 vs 98.5 ms); §8.1 measured `fpga_wait` at 249 ms of that, i.e. **57 % of the
FPGA's operator time is spent waiting on its own decoder**, while the IQR core never stalls
(stalled ≈ 0 %). §9.8 confirms the decoder is compute-bound, so more lanes are the direct fix.

**In one sentence: the IQR compute core wins where it is allowed to run (1.57× at the operator level
on taxi_d1), and one ParCore decoder lane loses to 32 CPU cores running DuckDB's parquet decoder,
which decides every dataset the FPGA loses.**

### 9.8 The decoder is compute-bound — measured, not assumed (2026-07-21)

Before committing ~5 h of bitgen to more decoder lanes, the built-in ColumnChunkDecoder
StreamProfilers were read around an sf10 run (`bench/sql/decoder_bound_check.sql`; the HW counters
auto-reset after a full read, so: read to clear → run → read again).

> **Two corrections to this section, from an RTL audit on 2026-07-22 (see §9.14).** Neither
> overturns the conclusion, but both limit how far it can be pushed:
>
> 1. **The percentages below exclude `in_idle`.** They are taken over
>    `handshakes+starved+stalled`. `in_starved` counts bubbles *within* a column chunk, whereas
>    the gap *between* chunks — the host failing to have the next one ready — accumulates in
>    `in_idle`. So "0 % starved ⇒ not fetch-bound" was read off a denominator that omitted the
>    term where a host-feed shortfall actually appears. At N=2 this was almost certainly benign;
>    it is re-measured at N=4 in §9.14 with `decoder_probe.sql`.
> 2. **The profilers are a module-boundary probe.**
>    `column_chunk_decoder.sv:404-424` taps the ColumnChunkDecoder's own `in`/`out` ports. They
>    establish that the module is internally busy; they do **not** identify which internal stage
>    (snappy decompressor, `hybrid_page_decoder`, `run_decoder`) is the limiter. Attributing the
>    bound to *snappy* specifically rests on the throughput match in §9.12, which is inference.
>
> Also, "auto-reset after a full read" is imprecise: reading a lane's last register asserts
> `stop`, which returns the profiler to WAIT and **holds** the counters; they are zeroed by the
> next valid data beat (`stream_profiler.sv:69-77`). The read→run→read pattern used here is
> therefore still correct.

| metric | value | meaning |
|---|--:|---|
| `in_busy` | **5.5 %** | the decoder accepts an input beat on 1 cycle in 18 |
| `in_starved` | **0.0 %** | it is *never* waiting for compressed bytes → **not** fetch/PCIe-bound |
| `in_stalled` | **94.5 %** | data is present at its input and the decoder refuses it → **internally busy** |
| `out_stalled` | **0.0 %** | its output is never back-pressured → **not** downstream-bound |
| `active` | 351.2 ms | matches §8.1's measured `decode = 358.9 ms` to 2 % |

**Verdict: compute-bound.** With starvation and output stall both at zero, the only thing limiting the
decode phase is the lane's own throughput — ~310 MB compressed in / 480 MB decoded out in 351 ms, i.e.
**~1.4 GB/s of decoded output from a single lane**, which is why 32 CPU cores running DuckDB's parquet
reader beat it by 4.3× (§9.7). This is the regime in which additional lanes scale ~linearly, so
`fpga_wait → fpga_wait / N` is a justified model rather than an assumption.

**Projection (only `fpga_wait` scales; ratio vs the C++ operator, >1 = FPGA wins):**

| dataset | decode share | N=1 | N=2 | N=4 | N=8 | N=∞ |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 12 % | 1.64 | 1.75 | 1.81 | 1.84 | 1.87 |
| taxi_d2 | 16 % | 1.24 | 1.34 | 1.40 | 1.44 | 1.47 |
| tpch_qty | 15 % | 1.04 | 1.12 | 1.17 | 1.20 | 1.22 |
| taxi_d3 | 16 % | 0.90 | 0.98 | **1.02** | 1.04 | 1.07 |
| taxi_d4 | 16 % | 0.85 | 0.92 | **0.97** | 0.99 | 1.01 |
| tpch_extprice | 59 % | 0.47 | 0.66 | 0.84 | 0.96 | 1.14 |
| tpch_extprice_sf10 | 57 % | 0.23 | 0.33 | 0.41 | 0.47 | **0.54** |

**Amdahl, not decoder throughput, is what bounds sf10.** Even with infinitely fast decoding it reaches
187 ms against the CPU's 102 ms, because the residue is `passes` 77 ms (two streams of 480 MB, already
at PCIe **line rate**), the host `copy` 33 ms, and `fetch+submit` 76 ms. Linear decoder scaling is
real and worth having; it is not sufficient for high-entropy columns without also removing the second
PCIe pass.

**Cost and risk.** One decoder = 75.8k LUTs / 119k FFs / 66 URAM (58 % of it `inst_typed_dictionary`).

| N | LUT | FF | URAM | BRAM |
|--:|--:|--:|--:|--:|
| 1 (build-11) | 21.4 % | 15.4 % | 8.8 % | 12.4 % |
| 2 | 27.3 % | 19.9 % | 15.6 % | 13.2 % |
| 4 | 38.9 % | 29.1 % | 29.4 % | 14.8 % |
| 8 | 62.1 % | 47.4 % | 56.9 % | 18.0 % |

Area is not the constraint; **timing is** — build-11 closed at **WNS = 0.000 ns with 0 failing paths**,
i.e. zero margin. build-13 (N=2) and build-14 (N=4) are therefore being built together: N=4 for the
larger win, N=2 as the fallback if N=4 cannot close, and the pair together *measures* the scaling law
instead of extrapolating it. Runtime note: `OASIS_IQR_DECODE_WINDOW` must be ≥ lanes × pipeline depth
(set 16 for N=4; the default is 8).

### 9.9 build-13 (N=2 decoders) — scaling law measured (2026-07-21)

> **build-13 did NOT meet timing** (WNS −0.456 ns, 1000 failing paths; clusters:
> `inst_iqr_flag_packer` 213, decoder-0 `run_decoder` 197, decoder-1 `inst_profile_out` 114).
> **The correctness gate was nevertheless re-run on this bitstream and passed exactly**:
> n_fpga = 317554 / 625445 / 1328108 / 2112164, `cpp_vs_sql = 0` and `fpga_vs_cpp` =
> 1247 / 2877 / 162 / 54921 — byte-identical to build-11 across all 118 M rows. The violated paths are
> therefore not exercised in a way that corrupts output, and these results stand. (Worst-case
> timing-corner failure ≠ functional failure; but it was verified, not assumed.)

Utilization at N=2: LUTs 27.7 %, FFs 20.2 %, URAM 16.6 % — matching the 27.3 % projection of §9.8.

**Operator time (median of 7, ms):**

| dataset | N=1 | predicted N=2 | **measured N=2** | model error | C++ op | ratio N=1 → N=2 |
|---|--:|--:|--:|--:|--:|---|
| taxi_d1 | 11.0 | 10.3 | 10.4 | +0.5 % | 16.2 | 1.47× → **1.56×** |
| tpch_qty | 17.5 | 16.2 | 16.7 | +3.1 % | 17.3 | 0.99× → **1.04×** |
| taxi_d2 | 18.1 | 16.7 | 16.5 | −0.9 % | 22.2 | 1.23× → **1.35×** |
| taxi_d3 | 37.0 | 34.1 | 34.7 | +1.6 % | 31.3 | 0.85× → 0.90× |
| taxi_d4 | 56.0 | 51.6 | 51.7 | +0.2 % | 45.0 | 0.80× → 0.87× |
| tpch_extprice | 49.6 | 35.0 | **32.2** | **−7.9 %** | 21.6 | 0.44× → **0.67×** |
| tpch_extprice_sf10 | 437.1 | 312.5 | **278.5** | **−10.9 %** | 99.2 | 0.23× → **0.36×** |

**The 1/N model is confirmed.** On the taxi family the prediction from §8.1's `fpga_wait` lands within
0.2–3.1 % of measurement. The two decode-bound datasets came in **8–11 % better than linear**: a second
lane also overlaps fetch/submit host work behind decode, so the parallelisable fraction is slightly
larger than `fpga_wait` alone (fitting `heavy = base + D/N` gives D = 317 ms for sf10 against an
`fpga_wait` of 249 ms).

**End-to-end:** sf10 0.867 → **0.711 s** (0.67× → 0.83×), extprice 0.096 → **0.078 s** (0.75× → 0.91×).
The taxi datasets barely move, being 69–75 % DuckDB tax. CPU-seconds are unchanged (1.97–2.84×).

**Measured build comparison — end-to-end (median of 7 warm runs, s):**

| dataset | rows | FPGA build-11 (N=1) | **FPGA build-13 (N=2)** | FPGA gain | C++ CPU | ratio N=1 | **ratio N=2** |
|---|--:|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 0.035 | **0.034** | −2.9 % | 0.039 | 1.11× | **1.15×** |
| tpch_qty | 6.0M | 0.063 | **0.062** | −1.6 % | 0.068 | 1.08× | **1.10×** |
| taxi_d2 | 6.0M | 0.063 | **0.061** | −3.2 % | 0.072 | 1.16× | **1.18×** |
| tpch_extprice | 6.0M | 0.096 | **0.078** | **−18.8 %** | 0.071 | 0.75× | **0.91×** |
| taxi_d3 | 13.1M | 0.134 | **0.133** | −0.7 % | 0.135 | 1.02× | **1.02×** |
| taxi_d4 | 20.3M | 0.205 | **0.204** | −0.5 % | 0.211 | 1.01× | **1.03×** |
| tpch_extprice_sf10 | 60.0M | 0.867 | **0.711** | **−18.0 %** | 0.588 | 0.67× | **0.83×** |

**End-to-end is the system-success metric, and on build-13 the FPGA is ahead or tied on 6 of 7
datasets.** The second decoder moved exactly the two decode-bound datasets — tpch_extprice
(−18.8 %, from a clear loss to a tie) and sf10 (−18.0 %, 0.67× → 0.83×) — and left the five
decode-light datasets essentially unchanged (−0.5 % to −3.2 %), which is precisely what §9.8's
per-dataset decode share predicts. **Only sf10 remains behind.**

**Consequence for the roadmap:** decoders alone fix exactly one dataset (extprice, at N≥4). For the
taxi family and sf10 the next lever must be the *second PCIe pass* and the host gather — §8.6's
HBM/streaming work — not more lanes.

### 9.10 Removing the host memcpy — streaming per-chunk buffers (2026-07-22, build-13 / N=2)

`OASIS_IQR_STREAM=1` hands the per-row-group decoded buffers straight to `IqrRunner::run()` instead of
gathering them into one contiguous column. **The runner needed no change** — `run()` already accepts a
*vector* of chunks and concatenates them logically, asserting `last` only on the final one. The gather
was never a device requirement, only a convenience, so the change is confined to
`DecodeColumnAllGroups`: keep the sink buffers, skip the memcpy *and* the contiguous allocation.

Two safety properties: it applies only to `iqr_flags_only` (`needs_values = false`; `iqr_flags` still
gathers because it echoes the value column), and every **non-final** chunk must be a whole multiple of
8 elements, because `FlagBitPacker` emits 8 flags per beat and a partial chunk mid-stream would insert
padding bits and misalign every later flag. If any group fails the check it silently falls back to the
memcpy — which is what happens on the taxi files, whose odd-sized row groups were already documented.

**Verified:** the diagnostic prints `sink=stream` with `copy 0.00`, and the full correctness suite
passes unchanged with streaming on (317554 / 625445 / 1328108 / 2112164, `cpp_vs_sql = 0`), proving
the chunk boundaries do not disturb the packed bitmask.

| dataset | operator (ms) | | e2e (s) | | **FPGA CPU-s** | | **CPU-work ratio** | |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| | base | stream | base | stream | base | stream | base | stream |
| tpch_extprice | 32.0 | **29.4** (−8.1 %) | 0.078 | 0.075 | 0.066 | **0.047** (−28.8 %) | 2.74× | **3.91×** |
| tpch_extprice_sf10 | 278.9 | **257.9** (−7.5 %) | 0.719 | 0.705 | 0.812 | **0.442** (−45.6 %) | 2.24× | **4.14×** |
| taxi_d4 | 51.7 | 51.5 | 0.199 | 0.202 | 0.258 | 0.264 | 2.27× | 2.23× |

**The wall-clock gain is modest; the host-CPU gain is large.** Operator time falls 7.5–8.1 % and
end-to-end only 2–4 % (inside the noise band), but the FPGA's **host CPU-seconds fall 29–46 %**,
lifting the CPU-work ratio from 2.24× to **4.14×** on sf10 and 2.74× to **3.91×** on extprice. The
memcpy was a 480 MB multi-threaded host copy: cheap in wall clock because it is parallel, expensive in
CPU-seconds for exactly the same reason. **Since the offload claim (§9.5.1) is the result this study
leads with, this is a first-order improvement to the headline, not a micro-optimisation.**

**taxi_d4 is unchanged because the guard correctly rejected it** — its odd-sized row groups break the
8-element rule, so it fell back to memcpy. The guard working silently on real data is the intended
behaviour, and it is why the correctness numbers are identical.

**The N=1 penalty did not reappear.** The first attempt at this (on the 1-decoder build-11) was a wash:
the copy saving was cancelled by ~27 ms of extra `fpga_wait` from holding every sink buffer to the end.
On build-13 the streaming `fpga_wait` is 113 ms and operator time *falls* — the decode-side penalty
shrinks as lanes are added while the copy saving does not, exactly as predicted. **A software change
that was worthless on one decoder becomes worthwhile on two**; it should be re-measured again on N=4.

### 9.11 Host-side prefetching — a measured NO-OP (2026-07-22), and what it rules out

Hypothesis: the decode phase spends `fetch 42.8 + submit 19.8 = 62.5 ms` of host work that serialises
with the FPGA, so moving the fetch to a background pool should hide it behind the decoder's own
113 ms wait. Implemented (4 workers, own `FileHandle` each, bounded `2 x window` ahead, strict
in-order consumption) and measured on sf10 / build-13 / streaming:

| | fpga_wait | fetch | submit | **decode total** | FPGA CPU-s |
|---|--:|--:|--:|--:|--:|
| inline (before) | 113.2 | **42.8** | 19.8 | **181.1** | **0.442** |
| prefetched, 1 worker | 165.2 | 4.3 | 7.8 | 182.6 | — |
| prefetched, 4 workers | 161.4 | 7.4 | 7.9 | **181.7** | 0.474 |

**The decode total did not move (181.1 → 181.7 ms); the fetch time simply migrated into `fpga_wait`.**
The inline fetch was *already* overlapped: the scheduler keeps `window` (8) row groups in flight, so
while the main thread fetched group *i* the FPGA was decoding *i−8…i−1*. Prefetching only changed
where the main thread happens to block. That 1 worker and 4 workers are indistinguishable (4.3 vs
7.4 ms of blocking) confirms fetching was never the constraint.

It also cost ~7 % more host CPU (0.442 → 0.474 CPU-s on sf10), dropping the offload ratio 4.14× →
3.86×. Since CPU-seconds is the headline claim, this is a regression for zero gain — **reverted**, with
the finding recorded in a code comment so it is not re-attempted.

**Why this result is worth keeping:** it eliminates the competing explanation. The decode phase is
bounded by the decoder itself and by nothing on the host — no fetch bottleneck, no submit bottleneck,
no copy bottleneck (§9.10 removed that one and decode still did not move). Combined with §9.8
(`in_starved = 0`, `in_stalled = 94.5 %`, compute-bound) and the ParCore spec match (§9.12), the
decoder is established as the sole remaining lever by elimination rather than by assumption.

---

## 9.13 build-14: four decoder lanes — the decode bottleneck resolved

The elimination argument of §9.8/§9.11/§9.12 left exactly one lever: **more decoder lanes**. build-14
(`synthesize.sh --no-rdma --decoders 4 --cores 24`, bitstream 2026-07-22 02:52) doubles build-13's two
lanes to four. Measured on `alveo-u55c-07`, streaming on, `OASIS_IQR_DECODE_WINDOW=16` (the default
window of 8 in-flight groups cannot keep four lanes fed), medians of 7 warm runs.

**Timing closure got worse, and it did not matter.** WNS **−0.773 ns** with 1004 failing paths, against
build-13's −0.456 ns / 1000 paths; the failing clusters are the same ones (`run_decoder`,
`inst_iqr_flag_packer`, `profile_in`). Utilization: 521914 LUTs (40.0 %), 776634 FFs (29.8 %), 360 BRAM
(17.9 %), 309 URAM (32.2 %). **The correctness suite reproduces bit-identically** — not merely
"passes", but returns the same counts *and the same FPGA-vs-C++ deltas* as build-13:

| dataset | n_fpga | fpga_vs_cpp | cpp_vs_sql |
|---|--:|--:|--:|
| taxi_d1 | 317554 | 1247 | 0 |
| taxi_d2 | 625445 | 2877 | 0 |
| taxi_d3 | 1328108 | 162 | 0 |
| taxi_d4 | 2112164 | 54921 | 0 |
| tpch × 3 | 0 | 0 | 0 |

Identical quantisation deltas mean the extra lanes changed throughput only — not the histogram, not
the fences, not the packing. The negative slack is on paths that are not datapath-critical in practice.

### Operator time — the lanes act exactly where predicted

| dataset | N=2 (build-13) | N=4 (build-14) | change |
|---|--:|--:|--:|
| tpch_extprice_sf10 | 257.9 | **170.4** | **−33.9 %** |
| tpch_extprice | 29.4 | **20.9** | **−28.9 %** |
| taxi_d4 | 51.5 | 51.0 | −1.0 % |

The two PLAIN-encoded datasets moved by a third; the dictionary-encoded taxi files did not move at
all. This is the §9.12 encoding hypothesis confirmed by intervention rather than by correlation: only
the datasets whose snappy payload is large are lane-limited.

### The decode model is now pinned by two measured points

Solving `heavy = base + D/N` on the sf10 pair (257.9 ms at N=2, 170.4 ms at N=4):

> **D ≈ 350 ms of decode work, base ≈ 83 ms of non-decode operator time.**

§9.12 independently predicted **319.9 ms** of snappy work from ParCore's published 1.5 GB/s
single-core figure and measured **351.2 ms**. Two unrelated derivations — one from a throughput spec,
one from a scaling experiment — agree to within 10 %. The decoder is characterised, and it scales
linearly in lane count as expected.

### End-to-end — the last loss is gone

| dataset | rows | FPGA | C++ CPU | SQL | FPGA/C++ | was (N=2) |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 0.033 | 0.040 | 0.056 | **1.21×** | 1.15× |
| tpch_qty | 6.0M | 0.059 | 0.067 | 0.088 | **1.14×** | 1.10× |
| taxi_d2 | 6.0M | 0.059 | 0.072 | 0.096 | **1.22×** | 1.18× |
| tpch_extprice | 6.0M | 0.066 | 0.070 | 0.153 | 1.06× | 0.93× |
| taxi_d3 | 13.1M | 0.132 | 0.135 | 0.188 | 1.02× | 1.02× |
| taxi_d4 | 20.3M | 0.201 | 0.210 | 0.284 | 1.04× | 1.02× |
| tpch_extprice_sf10 | 60.0M | 0.598 | 0.572 | 1.040 | 0.96× | **0.82×** |

Spreads 5–18 %. **The FPGA is now ahead or tied on all 7 datasets.** sf10 (0.96×) and taxi_d3 (1.02×)
are ties inside the noise band; the three clear wins are taxi_d1, taxi_d2 and tpch_qty at 1.14–1.22×.
sf10 — the single loss the study had to concede through §9.5 and §9.10 — is now a tie.

**The C++ column is the control.** It reproduced to within 2 % of the build-13 session (sf10 0.575 →
0.572, taxi_d1 0.039 → 0.040) despite a different benchmark node, so the FPGA deltas are attributable
to the bitstream and not to the host.

### Host CPU-seconds — unchanged, as expected

| dataset | FPGA | C++ | SQL | C++/FPGA | SQL/FPGA |
|---|--:|--:|--:|--:|--:|
| taxi_d1 | 0.025 | 0.089 | 0.310 | 3.54× | 12.30× |
| tpch_qty | 0.046 | 0.122 | 0.494 | 2.63× | 10.69× |
| taxi_d2 | 0.047 | 0.155 | 0.528 | 3.29× | 11.20× |
| tpch_extprice | 0.049 | 0.188 | 1.663 | **3.85×** | 34.02× |
| taxi_d3 | 0.170 | 0.366 | 1.043 | 2.15× | 6.13× |
| taxi_d4 | 0.264 | 0.580 | 1.580 | 2.20× | 5.98× |
| tpch_extprice_sf10 | 0.430 | 1.825 | 10.655 | **4.24×** | 24.75× |

sf10 holds at 4.24× (was 4.14×). This is the expected decomposition: **§9.10's streaming bought host
CPU, §9.13's lanes buy wall clock**, and the two are independent. The offload claim is unaffected by
lane count because the lanes do not run on the host.

### Standing of the study after build-14

- **End-to-end:** ahead or tied on **7 of 7** against an optimized 32-thread C++ operator; 1.02–1.22×.
- **Host CPU:** **2.2–4.2× less** on every dataset, and **6.0–34×** less than the SQL baseline.
- **Correctness:** C++ operator bit-exact with SQL on 118 M rows; FPGA 99.73–100 % per-row, over-flagging
  only at the fence.
- The decoder is no longer the open question. What remains is that the DuckDB emit tax is 68–76 % of
  every query on both sides (§9.7), which compresses all ratios toward 1.0 — that, not the accelerator,
  is what now bounds the end-to-end number.

---

## 9.14 Where the FPGA actually spends its time at 4 lanes (2026-07-22)

Measured on build-14 with `bench/sql/decoder_probe.sql` (per-lane StreamProfilers, all four terms
over the full denominator) and `OASIS_IQR_TIMING=1` (host wall clock). This section supersedes §9.8's
reading of the decoder and identifies a **new** bottleneck.

### 9.14.1 The §9.8 caveat was benign — and the conclusion is now properly supported

`in_idle` — the gap *between* column chunks, i.e. the host failing to have the next one ready — was
excluded from §9.8's denominator. Re-measured over the full total on sf10:

| lane | lane_ms | busy % | starv % | stall % | **idle %** | out_stall % |
|--:|--:|--:|--:|--:|--:|--:|
| 0 | 88.50 | 5.5 | 0.0 | 94.5 | **0.0** | 0.0 |
| 1 | 87.90 | 5.5 | 0.0 | 94.5 | **0.0** | 0.0 |
| 2 | 87.77 | 5.5 | 0.0 | 94.5 | **0.0** | 0.0 |
| 3 | 87.06 | 5.5 | 0.0 | 94.5 | **0.0** | 0.0 |

**`idle = 0.0 %` on every lane.** The omitted term is empirically zero, so §9.8's "not fetch-bound,
compute-bound" verdict survives — and is now established over a complete denominator rather than a
partial one. **Load balance is 1.02×** (87.06–88.50 ms), so there is no tail-group imbalance capping
N=4 either.

### 9.14.2 The decode-work constant, confirmed a fourth time

Aggregate lane occupancy on sf10 is **4 × ~88 ms = 352 ms**, compressed into 92.8 ms of wall clock —
**3.8× of a possible 4×, i.e. 95 % parallel efficiency.** That 352 ms is the same constant arrived at
three other ways:

| method | D (decode work) |
|---|--:|
| ParCore 1.5 GB/s spec (§9.12, predicted) | 319.9 ms |
| N=2 profiler `active` (§9.8, measured) | 351.2 ms |
| `heavy = base + D/N` fit over N=2,4 (§9.13) | ~350 ms |
| **N=4 summed lane occupancy (this section)** | **352 ms** |

The decoder is fully characterised. Nothing about it is now in doubt.

### 9.14.3 The scheduling window is NOT the limit

Sweeping `OASIS_IQR_DECODE_WINDOW` on sf10:

| window | decode (ms) | fpga_wait | fetch | submit | heavy (ms) |
|--:|--:|--:|--:|--:|--:|
| 8 | 94.09 | 31.08 | 39.76 | 18.32 | 171.43 |
| 12 | 93.27 | 30.95 | 39.38 | 18.10 | 171.18 |
| 16 | 92.67 | 27.09 | 40.56 | 20.58 | 170.31 |
| 24 | 92.70 | **21.00** | 39.27 | **27.91** | 170.58 |
| 32 | 93.06 | 23.18 | 37.06 | 28.20 | 170.76 |

**Flat within 1.5 % across a 4× window range.** Deepening the window only *relocates* time — at
window 24 `fpga_wait` falls 27.1 → 21.0 ms while `submit` rises 20.6 → 27.9 ms, total unchanged. That
is the signature of a saturated pipeline, and it retires the "window too small for 4 lanes" hypothesis.
**`window=16` is fine; it is not worth tuning further.**

### 9.14.4 Half the decode phase is now host work

| phase | sf10 (ms) | share of decode |
|---|--:|--:|
| `fetch` (host reads compressed bytes) | 38.54 | 42 % |
| `fpga_wait` (host blocked on FPGA) | 30.09 | 32 % |
| `submit` (host enqueues descriptors) | 19.73 | 21 % |
| `copy` (streaming ⇒ eliminated) | 0.00 | 0 % |
| **decode total** | **92.76** | |

`fetch` and `submit` are **lane-count-invariant** (N=2: 42.8 / 19.8 ms; N=4: 38.5 / 19.7 ms) — they
are pure host cost. Their sum, **58.3 ms, is a floor the decode phase cannot go below no matter how
many lanes are added.** Per-lane occupancy is 88 ms, so lanes still bind — but the margin is now
88 vs 58, i.e. **thin**. This is the measured reason §9.13 saw −33.9 % rather than the −50 % a pure
`D/N` model predicts.

### 9.14.5 The new bottleneck: the IQR pass phase

| dataset | decode | **iqr (passes)** | heavy | iqr share |
|---|--:|--:|--:|--:|
| taxi_d1 | 4.09 | 4.90 (3.98) | 9.01 | 54 % |
| taxi_d4 | 24.96 | 26.79 (26.06) | 51.78 | **52 %** |
| tpch_extprice | 12.00 | 9.15 (7.88) | 21.17 | 43 % |
| tpch_extprice_sf10 | 92.76 | **77.76** (76.57) | 170.55 | **46 %** |

At N=2 the split on sf10 was ~181 decode / ~78 iqr — decode dominated 70/30. **Halving decode has
made the two phases co-equal.** The IQR histogram passes are untouched by decoder work and are now
the single largest remaining item after the DuckDB tax. **Further decoder lanes are no longer the
highest-value change**; a fifth lane would cut ~44 ms of a 170 ms `heavy` at best, and less once the
58 ms host floor is accounted for.

### 9.14.6 taxi is a completely different regime — and it is NOT decode-bound

| lane | lane_ms | busy % | starv % | stall % | **idle %** | **out_stall %** |
|--:|--:|--:|--:|--:|--:|--:|
| 0 | 19.81 | 3.1 | 0.0 | 55.1 | **41.8** | **64.0** |
| 1 | 20.04 | 2.0 | 0.0 | 58.9 | **39.2** | **79.5** |
| 2 | 19.85 | 1.8 | 0.0 | 58.3 | **39.9** | **81.1** |
| 3 | 19.79 | 1.7 | 0.0 | 58.8 | **39.5** | **82.1** |

Two signals absent from sf10 dominate here:

- **`idle` 39–42 %** — the lanes spend two fifths of the run with *no chunk to work on*. taxi_d4's
  dictionary encoding means each chunk is tiny, so the lanes drain faster than the host refills.
- **`out_stalled` 64–82 %** — the decoder's **output is back-pressured by the IQR sink** for most of
  the run. Downstream, not the decoder, is the limiter.

This is the direct explanation for §9.13's "taxi_d4 unchanged (−1.0 %)": a decoder that is 40 % idle
and 80 % output-blocked cannot benefit from more lanes. It also indicts the memcpy — taxi_d4 runs
`sink=memcpy` (the streaming guard rejects its odd-sized row groups) and pays **11.35 ms of `copy`,
45 % of its entire 24.96 ms decode phase**. Making the streaming path handle non-multiple-of-8 groups
is worth more on taxi than any hardware change.

### 9.14.7 End-to-end: the accelerator is a minority of the query

sf10, end-to-end 0.598 s:

| component | ms | share |
|---|--:|--:|
| **DuckDB emit tax** | **427.5** | **71.5 %** |
| IQR passes (FPGA) | 76.6 | 12.8 % |
| decode — host `fetch`+`submit` | 58.3 | 9.7 % |
| decode — `fpga_wait` | 30.1 | 5.0 % |

**Everything this study has optimised lives inside the bottom 28.5 %.** Decode — the sole focus of
§9.8 through §9.13 — is now 15 % of the query, and only a third of *that* is time actually spent
waiting on the FPGA. The emit path (§9.7), which is near-identical on both the FPGA and C++ sides and
therefore compresses every ratio toward 1.0, is the dominant term and the only remaining place where
a large end-to-end win could come from.

---

## 9.15 Overlapping pass 1 with decode: the win is real, the prefix window is not (2026-07-22)

§9.14.7 showed the decoded column crosses PCIe three times (decoder→host, then host→FPGA twice for
the two IQR passes) and that `heavy` is exactly additive: sf10 = 92.8 decode + 77.8 iqr = 170.6 ms.
Pass 1 is a pure streaming reduction, so it can consume each row group as it decodes. Pass 2 cannot
move — it needs the final Q1/Q3. Implemented as `IqrRunner::begin_overlapped/feed_pass1/
finish_overlapped` driven by a `DecodeHooks` callback, behind `OASIS_IQR_OVERLAP=1`.

### The performance result — confirmed, and free

Warm A/B in one session, build-14, sf10, `DECODE_WINDOW=16`:

| phase | overlap=0 | overlap=1 |
|---|--:|--:|
| decode | 93.11 | 93.19 |
| passes | 76.56 | **38.54** |
| **heavy** | **170.47** | **131.82 (−22.7 %)** |

`passes` halves because one pass remains instead of two, and **`decode` is unchanged (+0.08 ms)** —
pass 1 fits entirely inside decode's existing host/FPGA slack. The concern that
`enqueue_stream_input` would block inside the decode loop and merely relocate the time did not
materialise. (The first `overlap=0` run of the session showed `heavy` 2722 ms with `fetch` 2606 ms:
a cold page cache, discarded and re-run warm.)

### The accuracy result — a hard failure on order-dependent data

`run()` stride-samples the **whole** column to place the 1024 bins. Overlapped, the bins must be
fixed before the first pass-1 beat, so they come from a **prefix** (1/16 of the column, capped at
4 M elements). Two purpose-built 20 M-row datasets, both streaming-eligible (122880-row groups):

| dataset | exact (C++) | overlap=0 | overlap=1 |
|---|--:|--:|--:|
| `ov_uniform` (stationary) | 200 | 200 | **200** |
| `ov_drift` (values rise with row order) | 200 | 200 | **19,997,999** |

On drifting data the prefix window spans only the early range; every later value clamps into the top
bin, Q3 lands far too low, and the fences flag **the entire column**. This is not a small
quantisation shift — it is a wrong answer.

**It also degraded a real dataset.** taxi_d1 is the one taxi file whose row groups are multiples of 8
(`sink=stream`; d2/d3/d4 fall back to memcpy and were untouched):

| | serial | overlapped |
|---|--:|--:|
| n_fpga | 317554 | 317453 |
| fpga_vs_cpp | 1247 | **1348** |

### Standing

**`OASIS_IQR_OVERLAP` stays OFF by default and must not be enabled as-is.** Any benchmark taken with
it set is invalid — including the 7-dataset medians run on 2026-07-22, where sf10 showed 1.01× and
taxi_d1 1.30 ×. Those numbers are *not* quotable.

The fix is not to abandon the overlap but to derive the window without a full pass over the data.
**Parquet footer statistics are the obvious source:** every row group carries an exact min/max for
the column, available before a single byte is decoded, and spanning the *whole* column rather than a
prefix. Taking a robust percentile over the 489 per-group (min,max) pairs would place bins that cover
the drift case correctly at zero data-movement cost. Until that exists, the 38 ms is unclaimable.

### 9.15.1 Fixing the window — correct, but the cure costs more than the disease

The prefix window of §9.15 was replaced with `DeriveWindowSpanning()`: a host-side sample of the first
`DataChunk` of 16 uniformly-spaced row groups (first and last always included), fed to the same robust
p1/p99 rule. Two cheaper sources were checked first and both fail:

- **parquet footer min/max** — present on every row group of every dataset here, but not robust:
  taxi_d4 spans −128540..33407632, so 1024 bins are 32768 wide while the fares live in 0..5000.
  Every value lands in bin 0 ⇒ q1 = q3 ⇒ IQR 0 ⇒ degenerate fences.
- **a percentile over the per-group footer min/max** — no better: taxi_d4 is 10 % outliers and
  `ov_drift` has one per ~122880 rows, so essentially *every* row group's max is extreme.

**Accuracy is fixed.** `ov_drift` returns **200** (was 19,997,999); taxi_d1 back to exactly 1247,
taxi_d3/d4 bit-identical; taxi_d2 changed 2877 → **2617**, i.e. *improved*. At
`OASIS_IQR_WINDOW_GROUPS=8` taxi_d1 regresses to 1348, so **16 is the minimum safe sample** — the
extra 5.5 ms buys real accuracy.

**But end-to-end it is a net loss.** Medians of 7, build-14, overlap on, vs §9.13's baseline:

| dataset | build-14 | +overlap | CPU-work ratio |
|---|--:|--:|--:|
| taxi_d1 | **1.21×** | 1.00× | 3.55× → 2.73× |
| taxi_d2 | **1.22×** | 1.14× | 3.38× → 3.22× |
| tpch_qty | **1.14×** | 1.10× | 2.69× → 2.20× |
| tpch_extprice | **1.06×** | 0.92× | 3.70× → **1.91×** |
| taxi_d4 | **1.04×** | 0.99× | 2.17× → 2.20× |
| taxi_d3 | **1.02×** | 0.96× | 2.10× → 1.99× |
| tpch_extprice_sf10 | 0.96× | **1.00×** | 4.21× → **3.91×** |

**Six of seven get worse, and host CPU-seconds — the study's headline — get worse on every dataset.**

The arithmetic is unforgiving: `win_derive` is a fixed ~8 ms plus ~1.3 ms/group, paid per query, while
the saving is half of `passes` and scales with N. It only pays above ~40 M rows:

| dataset | pass-1 saving | window cost | net |
|---|--:|--:|--:|
| sf10 (60 M) | ~38 ms | ~18 ms | **+20** |
| taxi_d4 (20 M) | ~13 ms | ~10 ms | ~0 |
| taxi_d1 (3 M) | ~2 ms | ~8 ms | **−6** |

**A wiring defect makes it worse than necessary:** `DeriveWindowSpanning()` runs *before*
`DecodeColumnAllGroups` decides whether the streaming guard accepts the file, so taxi_d3/taxi_d4 pay
the full window cost and then fall back to `sink=memcpy` and never use it (34.5 → 42.6 ms and
50.9 → 60.6 ms respectively).

### 9.15.2 Standing

**`OASIS_IQR_OVERLAP` remains OFF by default and should stay off.** The mechanism is sound — with a
free window it reached `heavy` 131.8 ms, −22.7 % — but as shipped the window costs more than the
overlap saves on every dataset except sf10, and it converts a 0.96 × loss into a 1.00 × tie while
giving back host CPU. Three fixes would change the verdict, in increasing risk:

1. **Skip the window unless streaming will actually engage.** The guard is computable from the footer
   (`num_values % 8` per non-final group) with no decoding. Removes the waste on taxi_d3/d4 outright.
2. **Skip the overlap when it cannot pay.** Enable only when `N * 8 / PCIe_BW` exceeds the window
   cost — empirically ~40 M rows. Below that, run the serial path.
3. **Share `BuildParcoreMetadata`**, which is currently walked twice (once here, once in the decode
   path), and/or derive the window on a background thread while the first row groups decode. The
   latter would hide it entirely but puts DuckDB's parquet reader on a second thread against the same
   `ClientContext`.

Until at least (1) and (2) are in, the honest configuration for every published number is build-14
with `OASIS_IQR_STREAM=1` and **no overlap** (§9.13).

---

## 9.16 Phase-by-phase: the two operators side by side (2026-07-22)

Both operators carry the same three-phase instrumentation. Measured warm on sf10 (60 M rows,
480 MB decoded), build-14, streaming, overlap OFF. FPGA repeated 3x: `heavy` 170.24 / 170.76 /
171.57, `passes` 76.59 / 76.62 / 76.64 — a 0.07 % spread on `passes`.

| phase | CPU (ms) | FPGA (ms) | ratio |
|---|--:|--:|--:|
| decode the column | 58.9 (`read`) | 93.0 (`decode`) | CPU 1.6× |
| quartiles / histogram | 25.2 (`quart`) | 38.3 (pass 1) | CPU 1.5× |
| flags vs the fences | 7.6 (`flags`) | 38.3 (pass 2) | **CPU 5.1×** |
| **operator total** | **91.7** | **170.6** | CPU 1.9× |

The FPGA's two passes are measured separately, not split by assumption: with the overlap enabled
(§9.15.1) pass 2 alone measured 38.2–38.5 ms, so pass 1 is the 76.6 − 38.3 remainder.

### The flags row is the whole architecture in one number

Comparing 60 M values against two constants is the most trivial work in the operator. The CPU does it
in **7.6 ms**; the FPGA takes **38.3 ms** — 5.1× longer — because it must ship the entire 480 MB
column across PCIe to look at it.

| | achieved read bandwidth |
|---|--:|
| FPGA (PCIe Gen3 x16) | **12.5 GB/s** |
| CPU (DRAM) | **63 GB/s** |

**Every phase that touches the raw column is ~5× handicapped before any computation happens.** This is
not the operator being slow, and it is not the ParCore decoder: it is the bus. It also reframes §9.14 —
the decoder was the *first* bottleneck, but the bus was always the floor underneath it.

### The ceiling of the current design

The column is already on the chip when decode finishes. Both IQR passes exist only because
`vfpga_top.svh` wires the decoder lanes and the IQR lane as **separate streams** that never meet
on-chip, so the decoded values go decoder → host → FPGA → FPGA. Feeding the IQR unit from the decoder
output would delete both passes:

    FPGA heavy  ->  ~93 ms  (decode alone)
    CPU  heavy  =   91.7 ms

**Operator parity, at ~4× less host CPU** (0.435 vs 1.826 CPU-s). That is the ceiling reachable
without a faster decoder, more lanes, or a bigger bitstream — and half of it is already demonstrated:
fusing pass 1 measured 131.8 ms (§9.15). The blocker is not throughput but ordering — the histogram
window must be known before the data arrives.

---

## 9.17 Card memory is unusable — the READ path, not just staging (2026-07-22)

§9.16 proposed parking the decoded column in card memory so the two IQR passes would not re-cross
PCIe. The `use_card` path already exists in hardware (`axis_card_recv[0]` → IQR) and software, and
`stage_ms` / `passes_ms` are timed separately, so the read could be measured in isolation on build-14.

sf10 cannot be tested at all: `cThread::invoke() - transfers over 128MB are currently not supported
in Coyote` — its 457.7 MB column exceeds Coyote's per-invoke staging limit. Measured on the two
columns that fit:

| dataset | decoded | `passes` host | `passes` card | slowdown | card bandwidth |
|---|--:|--:|--:|--:|--:|
| tpch_extprice | 48.0 MB | **7.89 ms** | **12,207 ms** | 1547× | 7.9 MB/s |
| taxi_d3 | 104.6 MB | **16.83 ms** | **26,059 ms** | 1548× | 8.0 MB/s |

**~8 MB/s on both, and an almost identical 1547×/1548× factor across a 2.2× size difference.** A
constant ratio means a fixed per-request cost dominates: the card path is moving data in tiny
transfers (the 4 KB/command + sleep behaviour already documented for Coyote's migration DMA), not at
anything resembling HBM bandwidth. `staging` was only ~600 ms of it, so this is the **read** path.

**Consequence.** The HBM branch is closed for good — previously it was shelved for staging cost, now
the read side is independently disqualified. Any design that parks intermediates in card memory and
streams them back is off the table on this shell.

### What remains

| lever | effect | status |
|---|---|---|
| Park the column in card memory | 1548× slower | **dead** (this section) |
| Fuse pass 1 into decode (on-chip) | deletes a whole pass, −38 ms | the only architectural lever left |
| More decoder lanes | linear until PCIe binds | worth it only after fusion |

And the ceiling has to be stated honestly. With pass 1 fused, decode still ships 295.5 MB in +
457.7 MB out and pass 2 re-reads 457.7 MB, so at 8 lanes the operator becomes PCIe-bound near
~98 ms against the CPU's 91.7 ms. Decoding twice instead (never returning values to the host) moves
598 MB and lands near ~88 ms at 8 lanes. **Both are parity, not dominance.**

The reason is §9.16's single number: the FPGA reads at **12.5 GB/s** over PCIe Gen3 x16 while the CPU
reads at **63 GB/s** from DRAM. On PLAIN-encoded data, where the compressed payload is large, no
amount of decoder or IQR optimisation closes a 5× bus gap. The FPGA's durable advantage on this
workload is **host CPU-seconds (2.2–4.2×), not wall clock** — and on dictionary-encoded data (taxi),
where the compressed payload is 17× smaller, it already wins outright.

---

## 9.18 Two benchmark defects fixed — and the headline changes (2026-07-22)

Two problems were found in how this study measured, both of which flattered the FPGA. Both are now
fixed and everything below supersedes the end-to-end numbers in §9.13.

### Defect 1: the benchmark timed DuckDB's table writer, not the operators

`medians.py` ran `CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM ...`. Measured on sf10:

| query | real | minus operator |
|---|--:|--:|
| `count(*) FILTER (WHERE is_outlier)` | 0.209 s | **38 ms** = actual flag emission |
| `CREATE TABLE ... AS SELECT` | 0.647 s | 477 ms |
| difference | | **438 ms = DuckDB's table append** |

**92 % of what §9.7–§9.16 called the "DuckDB emit tax" is DuckDB writing a 60 M-row table** — at
~0.55 cores (user rises only 0.562 → 0.803 across it), identical on both sides, and nothing to do
with FPGA vs CPU. It was a large constant added to both, dragging every ratio toward 1.0. Producing
the flags actually costs 38 ms. `medians.py --consume` now aggregates instead (with `FILTER`, so the
column cannot be projected away).

### Defect 2: the C++ baseline freed its column outside DuckDB

`ReadColumnCpu` allocated the raw column with `new int64_t[]`. Releasing it landed *after* the
`heavy` timer stopped and appeared as CPU-side "tax". Switching to
`Allocator::Get(context).Allocate()` (still no value-initialisation) removed most of it:

| dataset | tax C before | after |
|---|--:|--:|
| taxi_d3 | 19.6 | **5.7** |
| taxi_d4 | 27.0 | **7.3** |
| taxi_d2 | 11.6 | **4.7** |
| tpch_qty | 10.3 | **4.4** |
| extprice | 9.4 | **3.8** |
| **sf10** | 63.8 | **61.4 (unchanged)** |

Correctness unaffected: `cpp_vs_sql = 0` on all seven, 118 M rows.

### The corrected result (medians of 15, `--consume`, build-14, streaming, overlap off)

| dataset | rows | FPGA | C++ | e2e | operator | CPU-work |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 0.012 | 0.019 | **1.58×** | **1.97×** | 3.03× |
| taxi_d2 | 6.0M | 0.018 | 0.023 | **1.28×** | **1.35×** | 3.64× |
| tpch_qty | 6.0M | 0.018 | 0.019 | 1.06× | 1.11× | 3.12× |
| tpch_extprice | 6.0M | 0.025 | 0.026 | 1.04× | 1.09× | 4.26× |
| taxi_d3 | 13.1M | 0.040 | 0.032 | **0.80×** | 0.80× | 2.07× |
| taxi_d4 | 20.3M | 0.058 | 0.044 | **0.76×** | 0.77× | 2.20× |
| tpch_extprice_sf10 | 60.0M | 0.181 | 0.159 | **0.88×** | 0.58× | **6.07×** |

**4 wins / 3 losses on wall clock — not the 7-of-7 of §9.13.** Two of those wins (taxi_d3, taxi_d4)
were artefacts of Defect 2 and reversed once the baseline was made fair.

### What the corrected data actually shows: a crossover at ~10 M rows

Operator cost per million rows:

| dataset | rows | FPGA | CPU |
|---|--:|--:|--:|
| taxi_d1 | 3.0M | 2.74 | **5.37** |
| tpch_qty | 6.0M | 2.28 | 2.52 |
| taxi_d2 | 6.0M | 2.28 | 3.07 |
| extprice | 6.0M | 3.38 | 3.68 |
| taxi_d3 | 13.1M | 2.53 | **2.03** |
| taxi_d4 | 20.3M | 2.42 | **1.87** |
| sf10 | 60.0M | 2.81 | **1.63** |

**The FPGA's cost per row is flat (2.3–3.4 ms/M) at every scale; the CPU's falls monotonically from
5.37 to 1.63.** The CPU carries ~13 ms of fixed cost (32-thread startup, allocation, coordination)
that amortises away, while the FPGA is pinned to PCIe's 12.5 GB/s and cannot improve. They cross near
**10 M rows**, and end-to-end now shows the same crossover as the operator — ≤6 M rows the FPGA wins,
≥13 M it loses. Encoding (PLAIN vs dictionary) is a secondary effect worth 20–40 %, not the driver;
earlier sections overstated it.

**Host CPU-seconds is the claim that survived every change of benchmark today: 2.07–6.07×**, and it is
the only metric unaffected by both defects.

### Open

- **sf10's `tax C` of 61.4 ms did not move.** DuckDB's allocator evidently stops pooling above some
  size and returns large blocks to the OS: taxi_d4 (163 MB) fell 8.8× while sf10 (457.7 MB) fell not
  at all. That is 39 % of sf10's CPU end-to-end and must be identified before publication.
- **C++ spreads are now 20–77 %** (taxi_d3 77 %, extprice 48 %). Allocator pooling misses on the first
  run of a session and hits thereafter. Medians reproduce across independent runs (taxi_d3 0.83 →
  0.80, taxi_d4 0.77 → 0.76), but the spread must be reported alongside them.

---

## 9.19 Fused pass 1 on silicon — build-16 (2026-07-23)

The RTL that tees the decoder output into the IQR histogram (§6 of `compact.md`) is validated on
hardware. **sf10's operator falls 169.6 → 137.0 ms (−19 %) and its end-to-end ratio flips 0.85× →
1.05×, with every correctness number at its documented baseline.**

### The build-15 hang, and what it cost to find

build-15 flashed, `decoder_profiler` answered, and then a fused query **sat silent until `timeout`
with no error at all**. Root cause in `IqrHistogramFeed`: `out.valid` followed `any_head` (ANY lane
has a beat) while the payload came from `sk_data[grant]` — last cycle's winner, i.e. precisely the
lane that had just run dry. Garbage `keep` bits inflated the element count, `fed` overshot
`hist_expected`, `last` fired early, the core left HISTOGRAM, the top's mux parked the feed's ready
at 0, the skids filled, and the tee **stopped the decoder**. The host never reached `finish_fused`,
so its `histogram_total == N` check never ran.

**Invisible at `N_LANES=1`**, where `grant` is always 0 — which is why no prior build caught it.

Three lessons worth keeping:

1. **The poll budget must be wall clock, not spins.** `finish_fused` spun 200 M times on an MMIO
   read (~1 µs each) = ~200 s, longer than any sane `timeout` on the query. The diagnostic existed
   and could never fire. Now 10 s.
2. **A miscount must not be able to deadlock the decoder.** The feed now holds `o_ready` high once
   `done` and drops late beats, so any future miscount degrades to the `histogram_total != N` error
   the host already checks for, instead of a silent hang.
3. **Two sims, written after the fact, would have caught it in seconds** —
   `run_feed_tb.sh` (4 lanes, uneven rates) and `run_fused_integration_tb.sh` (feed → mux →
   IQR_detection, two-pass, vs a reference). Both fail when the fix is reverted, so they are proven,
   not merely passing. They also caught two bugs sim-only: a circular `beat_elems` dependency that
   xsim resolves to X, and `$countones` returning X on the skid slot.

### The window is the whole story

Fusion deletes pass 1 (worth ~0.64 ms/Mrow) but the histogram window must be sized **before the
first beat**, and that sample is a roughly fixed cost. Everything below follows from that tension.

**Sampling on the FPGA beats sampling on the host.** `DeriveWindowSpanning` decompresses 16 groups'
first `DataChunk` on the CPU — ~15 ms wall and ~51 ms host CPU for pages the FPGA is about to decode
anyway. `DeriveWindowFromFpga` decodes the picks on the device instead:

| window source | `win_derive` | sf10 `heavy` | sf10 CPU-work |
|---|--:|--:|--:|
| host sample | 14.93 ms | 145.70 | 4.74× |
| **FPGA sample** | **7.22 ms** | **139.46** | **6.07×** |

The CPU-seconds column is the point: the host sample nearly halved extprice's CPU-work advantage
(4.26× → 2.02×); the FPGA sample gives it back in full.

**Coverage matters, resolution does not.** taxi_d3 is wrong at 16 groups (finds 1,296,479 of
1,328,270). Raising per-group density 2048 → 32768 returned the **identical** answer while
`win_derive` went 4.72 → 20.32 ms. Raising *groups* 16 → 48 fixes it — but every extra group is
another group decoded twice:

| dataset | unfused | fused @16 grp | fused @48 grp |
|---|--:|--:|--:|
| taxi_d3 | 32.9 ms ✅ 162 | 33.0 ms ❌ 31791 | ~42 ms ✅ 162 |
| taxi_d4 | 49.6 ms ✅ | **40.6 ms** ✅ | 51.6 ms ✅ |
| sf10 | 169.6 ms ✅ | **137.2 ms** ✅ | 152.9 ms ✅ |

**48 globally taxes the two columns that benefit in order to fix one that gains nothing from fusion
at any setting.** (`WindowFromSample` now selects with two composed `nth_element` passes instead of
sorting — O(n) for the only two order statistics needed. Kept because it is strictly cheaper, though
it did not unlock the density that turned out not to matter.)

### The two gates, and why conservative won

```
fuse = OASIS_IQR_FUSE && rows > 10M && streaming sink
```

Both read from the **cached footer** (`ReadFooterFacts`), so nothing is decoded to decide them and no
window sample is taken for a fuse that is declined.

- **Row count.** Below ~10 M the fixed window cost exceeds the saving: taxi_d1 1.67× → 1.27×,
  extprice 1.00× → 0.86×. Same arithmetic that keeps `OASIS_IQR_OVERLAP` off (§9.15.1).
- **Streaming sink.** A column the guard rejects uses the memcpy sink, and there `run()` derives the
  window from the *whole decoded column* — free and exact. Fusing replaces that with a sampled
  window, strictly worse.

**taxi_d4 was sacrificed deliberately.** It is accurate at 16 groups and would gain 49.6 → 40.6 ms.
But that accuracy is *observed, not predictable*: taxi_d3 is the same sink and the same shape and
silently loses 2.4 % on identical settings. Non-streaming columns get a perfect window for nothing,
so there is no reason to gamble on them. **Recorded as a known, deliberate ~10 ms left on the table**
— revisit only with a cheap a-priori test for whether a sampled window matches the full-column one.

### Final state (build-16, medians of 15, `--consume`)

| dataset | rows | fused? | FPGA | C++ | e2e | operator | CPU-work |
|---|--:|---|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | no (small) | 0.013 | 0.019 | **1.46×** | **1.70×** | 3.05× |
| tpch_qty | 6.0M | no (small) | 0.019 | 0.019 | 1.00× | **1.07×** | 3.05× |
| taxi_d2 | 6.0M | no (small) | 0.019 | 0.024 | **1.26×** | **1.32×** | 3.61× |
| extprice | 6.0M | no (small) | 0.026 | 0.026 | 1.00× | **1.04×** | 4.16× |
| taxi_d3 | 13.1M | no (memcpy) | 0.041 | 0.032 | 0.78× | 0.78× | 2.12× |
| taxi_d4 | 20.3M | no (memcpy) | 0.059 | 0.043 | 0.73× | 0.72× | 2.21× |
| sf10 | 60.0M | **yes** | 0.149 | 0.157 | **1.05×** | 0.68× | **6.07×** |

sf10, the dataset the fusion targets: **e2e 0.88× → 1.05×, operator 0.58× → 0.68×, CPU-work 6.07×
preserved.** Correctness at baseline everywhere: taxi_d1 1247, taxi_d2 2877, taxi_d3 **162**,
taxi_d4 54921, tpch × 3 zero, and `ov_uniform`/`ov_drift` both exactly **200** (these are 20 M-row
streaming files, so they fuse — the window path stays under test rather than gated out).

**Caveat on reading the table:** FPGA spreads are 2–11 % but **C++ spreads reach 86 %** on
taxi_d3/d4. The taxi_d3/d4 rows are unfused and should equal the §9.13 baseline; their apparent
drift (0.80 → 0.78, 0.76 → 0.73) is C++ noise, not an FPGA change.

### Where the remaining time goes (sf10, fused)

```
heavy 139.46 = win_derive 7.22 + decode 92.49 (fpga_wait 31.5 | fetch 36.8 | submit 19.8) + passes 38.37
```

Pass 1 is gone. **The next wall is decode's host feed**: `fetch` + `submit` = 56.5 ms of the 92.5 ms,
with the FPGA idle for it (`fpga_wait` 31.5). Step 2 (bin indices, §8.2 of `compact.md`) attacks
`passes`; 8 lanes and FPGA-initiated reads attack `fetch`+`submit`. The IQR core itself is still
never the limit — `stalled = 0.0 %`, `starved = 21.5 %`, input at 12.51 GB/s against PCIe's ~12.5.
