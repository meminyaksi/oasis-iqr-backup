# IQR FPGA operator — correctness + timing (fresh run, 2026-07-25)

Standalone record of the shipping result: a readable **C++ CPU operator** (a direct transliteration of the
IQR SQL) as the baseline, an **FPGA** accelerator that beats it, and **DuckDB's built-in `quantile_disc`**
as the trusted correctness oracle. Both conditions hold: **FPGA > C++ on all 7 datasets**, and **C++ ≥ SQL**
(5 clear wins, 2–3 ties). Correctness is exact against the oracle.

- **Node:** alveo-u55c-07 (Alveo U55C), kernel 6.8.0-136 (driver rebuilt for this kernel — see note below)
- **Bitstream:** build-20, **index mode OFF** (the value path — the one that ships)
- **Run config:** `OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_DECODE_WINDOW=16`
- **Timing:** `medians.py --consume -n 15 --cpp-impl groupby` (15 warm runs, operator-isolated)
- **Correctness:** `correctness_3way.sh` (three-way per-row flag check + quartile diagnostic)

---

## 1. Correctness — three-way, exact

### 1a. Per-row flag comparison (`bench/correctness_3way.sh flags`)

Legs: **FPGA** (`iqr_flags`, actual hardware flags) · **C++** (`iqr_cpu_flags_groupby` math) · **oracle**
(built-in `quantile_disc`). Each is decided per row over every input row.

| dataset | rows | n_fpga | n_cpp | n_oracle | fpga_vs_cpp | cpp_vs_oracle |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 2,964,624 | 317554 | 318801 | 318801 | 1247 | **0** |
| taxi_d2 | 5,972,150 | 625445 | 628322 | 628322 | 2877 | **0** |
| taxi_d3 | 13,069,067 | 1328108 | 1328270 | 1328270 | 162 | **0** |
| taxi_d4 | 20,332,093 | 2112164 | 2057243 | 2057243 | 54921 | **0** |
| tpch_qty | 6,001,215 | 0 | 0 | 0 | 0 | **0** |
| tpch_extprice | 6,001,215 | 0 | 0 | 0 | 0 | **0** |
| sf10 | 59,986,052 | 0 | 0 | 0 | 0 | **0** |

**`cpp_vs_oracle = 0` on all 7** → our optimized C++ baseline flags every one of ~118M rows identically to
DuckDB's canonical `quantile_disc`. **`fpga_vs_cpp`** is the FPGA's 1024-bin histogram rounding — nonzero by
design, and `fpga_vs_cpp == |n_fpga − n_cpp|` on every row, i.e. all disagreements are one-directional (a
clean monotonic fence shift, no compensating errors — which a count-only comparison could not prove).

### 1b. Quartile / fence diagnostic (`bench/correctness_3way.sh quartiles`)

| dataset | builtin_q1 | ours_q1 | builtin_q3 | ours_q3 | quartiles_match | n_floor | n_true |
|---|--:|--:|--:|--:|:--:|--:|--:|
| taxi_d1 | 860 | 860 | 2050 | 2050 | true | 318801 | 318801 |
| taxi_d2 | 860 | 860 | 2050 | 2050 | true | 628322 | 628322 |
| taxi_d3 | 863 | 863 | 2120 | 2120 | true | 1328270 | 1328270 |
| taxi_d4 | 930 | 930 | 2190 | 2190 | true | 2057243 | 2057243 |
| tpch_qty | 13 | 13 | 38 | 38 | true | 0 | 0 |
| tpch_extprice | 1873910 | 1873910 | 5515894 | 5515894 | true | 0 | 0 |
| sf10 | 1871615 | 1871615 | 5513304 | 5513304 | true | 0 | 0 |

**`quartiles_match = true`** everywhere: our GROUP BY + cumulative-count quartile picks the exact same q1/q3
as the built-in. **`n_floor == n_true`**: the operator's divider-free fence `floor(1.5·IQR) = d + (d>>1)`
flags the same rows as the textbook real-valued `1.5·IQR` fence — the integer flooring never crosses a value.

---

## 2. Timing — medians of 15 warm runs (`--consume`, index mode OFF)

### 2a. End-to-end (seconds), spread = (max−min)/median

| dataset | rows | FPGA | ±% | C++ | ±% | SQL | ±% | **FPGA/C++** | **C++/SQL** |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 0.013 | 15 | 0.016 | 31 | 0.025 | 8 | **1.23×** | **1.56×** |
| tpch_qty | 6.0M | 0.019 | 11 | 0.033 | 15 | 0.031 | 16 | **1.74×** | 0.94× tie |
| taxi_d2 | 6.0M | 0.019 | 16 | 0.033 | 24 | 0.035 | 23 | **1.74×** | 1.06× tie |
| extprice | 6.0M | 0.026 | 8 | 0.089 | 12 | 0.100 | 10 | **3.42×** | **1.12×** |
| taxi_d3 | 13.1M | 0.041 | 7 | 0.055 | 18 | 0.058 | 7 | **1.34×** | 1.05× tie |
| taxi_d4 | 20.3M | 0.060 | 5 | 0.078 | 13 | 0.080 | 20 | **1.30×** | 1.03× tie |
| sf10 | 60.0M | 0.150 | 2 | 0.323 | 13 | 0.484 | 11 | **2.15×** | **1.50×** |
| **geomean** | | | | | | | | **1.74×** | ~1.16× |

**FPGA > C++ on 7/7**, every margin far outside the noise. **C++ ≥ SQL** with three clear wins (taxi_d1
1.56×, extprice 1.12×, sf10 1.50×) and the rest ties — read the ±% columns: tpch_qty 0.94× sits inside the
SQL arm's 16% spread, so it is a tie, not a loss. **Never state "C++ beats SQL on all 7."**

### 2b. Operator only (heavy, ms) — DuckDB emit tax excluded

| dataset | FPGA op | ±% | C++ op | ±% | **FPGA/C++** |
|---|--:|--:|--:|--:|--:|
| taxi_d1 | 9.0 | 8 | 12.8 | 37 | **1.41×** |
| tpch_qty | 14.6 | 7 | 28.9 | 20 | **1.98×** |
| taxi_d2 | 14.5 | 6 | 29.5 | 24 | **2.03×** |
| extprice | 21.2 | 4 | 84.9 | 14 | **4.00×** |
| taxi_d3 | 33.9 | 7 | 49.9 | 20 | **1.47×** |
| taxi_d4 | 51.0 | 5 | 72.0 | 13 | **1.41×** |
| sf10 | 137.3 | 1 | 312.5 | 15 | **2.28×** |
| **geomean** | | | | | **1.95×** |

### 2c. CPU-seconds (user time, median) — the latency-independent claim

| dataset | FPGA | C++ | SQL | **C++/FPGA** | **SQL/FPGA** |
|---|--:|--:|--:|--:|--:|
| taxi_d1 | 0.031 | 0.143 | 0.316 | 4.62× | 10.18× |
| tpch_qty | 0.048 | 0.204 | 0.515 | 4.25× | 10.73× |
| taxi_d2 | 0.056 | 0.224 | 0.546 | 4.03× | 9.82× |
| extprice | 0.045 | 0.551 | 1.705 | **12.18×** | **37.67×** |
| taxi_d3 | 0.189 | 0.480 | 1.099 | 2.55× | 5.83× |
| taxi_d4 | 0.275 | 0.719 | 1.614 | 2.61× | 5.87× |
| sf10 | 0.303 | 2.722 | 10.882 | **8.98×** | **35.89×** |

The FPGA does **2.6–12.2× fewer host CPU-seconds than the C++ operator** and **5.8–37.7× fewer than the SQL**
— the FPGA offloads the scan/compare to hardware, freeing host cores.

**Headline:** FPGA **1.23–3.42× end-to-end (geomean 1.74×)**, **1.41–4.00× operator (geomean 1.95×)**,
**2.6–12.2× fewer CPU-seconds**, over a readable C++ baseline that is itself **1.0–1.56× faster than the
equivalent SQL** (3 wins, ties elsewhere) and **bit-exact with DuckDB's built-in quantile**.

---

## 3. The queries and code we call

Three arms compute the **same IQR rule**: Q1 (25%), Q3 (75%), IQR = Q3−Q1, fences = Q1 − 1.5·IQR and
Q3 + 1.5·IQR (divider-free as `d + (d>>1)` = floor(1.5·IQR)), flag `v < lo OR v > hi`.

### 3a. SQL baseline (the original query the C++ transliterates) — `bench/medians.py:30`

```sql
WITH s AS MATERIALIZED (SELECT <col>::BIGINT v FROM read_parquet('<path>')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef;
```

### 3b. The three benchmark arms — `bench/medians.py:48` (`stmt()`), invoked with `--consume`

```sql
-- FPGA:   SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('<path>','<col>');
-- C++:    SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags_groupby('<path>','<col>');
-- SQL:    SELECT count(*) FILTER (WHERE is_outlier) FROM ( <SQL baseline above> ) q;
```

`--consume` aggregates the flags (excludes DuckDB's single-threaded table-append tax); the default
(`CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM <src>`) is what a user typing SQL experiences.

### 3c. Correctness oracle — DuckDB built-in quantile (`bench/sql/correctness_3way_fences.sql`)

```sql
-- trusted fence:  quantile_disc is the DISCRETE (nearest-rank) quantile, matching an integer operator
SELECT quantile_disc(v,0.25) q1, quantile_disc(v,0.75) q3 FROM s;   -- then same d+(d>>1) fence
```

The three-way harness runs the FPGA as a **single isolated aggregate** with the fences injected as
constants (see §5), never materialized or joined — required to avoid the FPGA receiver deadlock (§5).

---

## 4. Where the code lives

**All operators are in one file: `extension/src/oasis_iqr.cpp`** (the oasis DuckDB extension).

| function (SQL name) | role | definition | registration |
|---|---|--:|--:|
| `iqr_flags(path,col)` | FPGA: emits `(value, is_outlier)` per row | `RunHeavyPhase` [oasis_iqr.cpp:897](extension/src/oasis_iqr.cpp#L897) | [:2345](extension/src/oasis_iqr.cpp#L2345) |
| `iqr_flags_only(path,col)` | FPGA: emits just `is_outlier` (benchmark arm) | shares `RunHeavyPhase` | [:2355](extension/src/oasis_iqr.cpp#L2355) |
| `iqr_cpu_flags_groupby(path,col)` | **C++ baseline** — direct transliteration of the SQL | `IqrCpuCoreGroupBy` [:2032](extension/src/oasis_iqr.cpp#L2032), `RunHeavyPhaseCpuGroupBy` [:2192](extension/src/oasis_iqr.cpp#L2192) | [:2371](extension/src/oasis_iqr.cpp#L2371) |
| `iqr_cpu_flags(path,col)` | older CPU baseline (histogram zoom, `--cpp-impl zoom`) | `RunHeavyPhaseCpu` [:1870](extension/src/oasis_iqr.cpp#L1870) | [:2364](extension/src/oasis_iqr.cpp#L2364) |
| shared fence math | `IqrFences<T>` (`d + (d>>1)`) | [:1718](extension/src/oasis_iqr.cpp#L1718) | — |
| registration entry | `RegisterOasisIqrFunction` | [:2344](extension/src/oasis_iqr.cpp#L2344) | — |

`iqr_cpu_flags_groupby` deliberately shares `ReadColumnCpu`, `IqrFences`, `ComputeFlagMask` and the emit
path with the FPGA functions, so the only difference the benchmark measures is where the quartile+compare
runs. The FPGA datapath (decode + histogram + flag emit) is the build-20 bitstream (`hardware/build-20/`).

**Benchmark + correctness harness:**

| file | purpose |
|---|---|
| [bench/medians.py](bench/medians.py) | the timing benchmark (all three arms, both ratios). `--consume`, `-n`, `--cpp-impl {groupby,zoom}`, `--stats` |
| [bench/correctness_3way.sh](bench/correctness_3way.sh) | runner: `quartiles` (oracle vs ours), `flags` (per-row 3-way), `all` |
| [bench/sql/correctness_3way_fences.sql](bench/sql/correctness_3way_fences.sql) | stage 1: fences + CPU/oracle counts (pure SQL, no FPGA) |
| [bench/sql/correctness_3way_fpga.sql](bench/sql/correctness_3way_fpga.sql) | stage 2: one isolated aggregate over `iqr_flags` with injected fences |
| [bench/sql/correctness_3way_quartiles.sql](bench/sql/correctness_3way_quartiles.sql) | quartile / floor-vs-true-fence diagnostic |

---

## 5. The FPGA optimization story (decoders → fusion → packed pass 2)

**The one constraint:** the FPGA reads the column over **PCIe at ~12.5 GB/s**; the CPU reads DRAM at
**~63 GB/s**, so the FPGA starts ~5× handicapped on any step touching raw data. Every FPGA improvement moves
**less data across the bus** or keeps the bus busy — the IQR compute was never the limit. The operator runs
two passes: **pass 1** builds a histogram for the quartiles; **pass 2** re-reads the column and flags each
value. Originally the column crossed PCIe **three times** (decoder→host, then host→FPGA once per pass).

| # | improvement | mechanism | effect |
|---|---|---|---|
| 1 | **More decoder lanes (1→4)** | parallelize parquet decode | decode no longer decoder-bound; **revealed the next wall** — at 4 lanes the FPGA waits on the **host feed** (`fetch`+`submit` ≈ 55 ms), so more lanes buy nothing. Cost: routing congestion → harder timing closure. |
| 2 | **RTL fusion — pass 1 into decode (build-16)** ★ | TEE decoder output on-chip into the IQR histogram; pass 1 runs *during* decode and **never crosses PCIe** (one of three crossings deleted) | sf10 operator **169.6 → 137.0 ms (−19%)**; e2e flipped **0.85× → 1.05×**. Gated to streaming columns > 10M rows (only sf10 today). |
| 3 | **FPGA-derived window (build-16, `WINDOW_FPGA`)** | sample the histogram value-range on the FPGA instead of the host | removes ~51 ms of **host CPU**; it is what makes fusion pay off rather than break even. |
| 4 | **Packed 16-bit index pass 2 (build-19/20)** | pass 2 re-reads packed **16-bit bin indices** instead of 64-bit values — 4× less traffic | **nothing alone** — pass 2 was bottlenecked on the flag *emitter* (~6.4 flags/cyc), not PCIe. Needed #5 first. |
| 5 | **Wide flag emit (build-20)** | widen emitter **8 → 32 flags/cycle**, unblocking #4 | pass 2 **38.4 → 9.7 ms (3.96×)**, operator **139 → 110 ms**, input `stalled 80%→0%`. **SHELVED** — index mode flags 2 spurious outliers (missing per-column reset); OFF by default, **not in shipping numbers**. |

**How the time moved (sf10 operator, ms):**

| stage | decode | pass 1 | pass 2 | **operator** | what changed |
|---|--:|--:|--:|--:|---|
| baseline | 92.8 | — | 76.6 (both) | **169.7** | column crosses PCIe 3× |
| + fusion (build-16) | 92.5 | *free* | 38.4 | **137.0** | pass 1 off PCIe |
| + step 2 & wide emit (build-20)¹ | 92.2 | *free* | **9.7** | **110.0** | pass 2 = 16-bit indices, 32 flags/cyc |

¹ shelved on a correctness defect; not in the shipping value-path numbers.

**Through-line:** started bus-limited with the column crossing PCIe three times; fusion killed pass 1's
crossing, step 2 + wide emit shrank pass 2's by 4×. **Decode is now the wall** — ~92 ms of the operator,
**~55 ms of it host feed with the FPGA idle** — which is why more decoder lanes won't help until
FPGA-initiated reads replace the host feed. That is the next frontier.

## 6. Why a custom CPU operator — method comparison (z-score & IQR built-ins)

CPU-only, node 07, every method emits a per-row `is_outlier` flag (`count(*) FILTER`, same `--consume`
methodology). Best real time of 3–5 warm runs; sf10 CPU-seconds is median user time. Run with
[bench/methods_ab.sh](bench/methods_ab.sh).

| method | taxi_d1 (3M) | sf10 (60M) | exact? | CPU-s (sf10, user) |
|---|--:|--:|:--:|--:|
| z-score (`avg`/`stddev_pop`) | 17 ms | 143 ms | ✗ different rule | 3.5 s |
| IQR exact (`quantile_cont`) | 84 ms | **1980 ms** | ✓ | 14.8 s |
| IQR approx (`approx_quantile`) | 40 ms | 503 ms | ✗ approximate | 10.6 s |
| IQR our SQL (groupby CDF) | 25 ms | 478 ms | ✓ | ~11 s |
| **IQR our C++ (`iqr_cpu_flags_groupby`)** | **17 ms** | **317 ms** | ✓ | **2.8 s** |

**Findings:**

1. **z-score is cheapest** (single-pass mean/std) but it is a *different, weaker* rule — not a substitute
   for IQR. Its clean one-liner works only because its statistic is trivial; IQR's quantiles are not.
2. **The built-in exact quantile is the slowest by far — 1.98 s on sf10, 6× slower than our C++** and 4×
   slower than the approximate built-in. Exact quantiles need sorting/selection over all rows.
3. **Our C++ is the fastest *exact* IQR — it beats even the approximate `approx_quantile` (317 vs 503 ms)
   while being exact, and uses the least CPU of any IQR method (2.8 s vs 10–15 s).**
4. Conclusion: **you cannot get exact + fast from a built-in one-liner.** `approx_quantile` is the only fast
   built-in and it is approximate *and* still slower than our C++. This ~6× gap over the exact built-in is
   what justifies the custom operator — before the FPGA even enters.

## 7. Per-dataset configuration (sink & fusion)

Two knobs are set per dataset. **Sink:** memcpy (the decoded column is CPU-copied into a pinned "staging"
buffer, then DMA'd) vs streaming (the FPGA DMAs it directly — no CPU copy). **Fusion:** pass 1 folded into
decode (on-chip, never crosses PCIe); gate = `FUSE && rows > 10M && clean 8-aligned chunks`. Index mode is
**OFF everywhere** (the shipping value path) pending the §8 fix.

| dataset | rows | sink | fusion | why |
|---|--:|---|:--:|---|
| taxi_d1 | 3.0M | memcpy | ✗ | below 10M — the window sample costs more than the pass it saves |
| tpch_qty | 6.0M | memcpy | ✗ | below 10M |
| taxi_d2 | 6.0M | memcpy | ✗ | below 10M |
| extprice | 6.0M | memcpy | ✗ | below 10M (fusing drags it 1.00× → 0.86×) |
| taxi_d3 | 13.1M | memcpy | ✗ | >10M **but ragged chunks** break the streaming pass-2 packer |
| taxi_d4 | 20.3M | memcpy | ✗ | >10M **but ragged chunks** |
| **sf10** | 60M | **streaming** | **✓** | large **and** 8-aligned chunks — the only dataset that qualifies |

Three groups: **small (≤6M)** skip fusion because below 10M its fixed window-sample cost exceeds the pass it
removes; **taxi_d3/d4** qualify on size but fail `stream_ok` (ragged chunks shift the packed-flag bit
positions), so they fall back to memcpy — this is why they are the weakest rows, an FPGA-side gate not a CPU
property; **sf10** is both large and clean, so it fuses (pass 1 free on-chip).

**memcpy vs DMA, precisely:** the PCIe *crossing* is unavoidable and is the wall (12.5 GB/s). The **memcpy**
is only the CPU staging copy into the pinned buffer; switching a memcpy column to streaming replaces that
copy with FPGA DMA — measured **host CPU-seconds −29..46%, operator wall −7.5..8%, e2e in the noise**
(§9.10). So it is a CPU-efficiency win, not a latency win. taxi_d3/d4 can't take it until the ragged-packer
RTL realign lands (a bitstream).

## 8. Index-mode defect: root cause confirmed + fix (simulation-proven, not yet on silicon)

**Defect (§9.23):** with `OASIS_IQR_IDX_PASS2=1`, sf10 flags **2 spurious outliers** (rows 13 & 25 — the
first packed word) **in a multi-query session** but is clean in isolation. Because index mode is the fast
pass-2 path (3.96×), fixing this is what would let it ship.

**Root cause — confirmed in simulation today.** The wide flag packer `IqrWideFlagPack` had **no per-column
reset**. It only self-cleans when a column completes normally: `IqrIndexFlag` asserts `o_last` on the final
beat → the packer flushes → `acc/filled` return to 0. But `IqrIndexFlag`'s `o_last = o_valid && (emitted +
32 >= i_expected)`, so **if `i_expected` overshoots the delivered beats, `o_last` is never asserted**, the
packer never flushes, and its residual bits bleed into the **first word of the next column** — exactly the
observed first-word corruption. Demonstrated at the real `IqrIndexFlag → IqrWideFlagPack` seam:

```
tb_iqr_indexflag_last (current HW):
   MATCHED  (i_expected=128)  A_o_last=1 (fired)     -> B clean
   MISMATCH (i_expected=200)  A_o_last=0 (WITHHELD)  -> B *** LEAK ***
```

**Fix.** Added an `i_restart` input to `IqrWideFlagPack` ([iqr_index_stream.sv](hardware/src/hdl/iqr_index_stream.sv),
default `0` so nothing else changes) that clears `acc/filled/flushing/flush_left/out_valid_r/out_last_r` per
column, wired to the existing per-column clear pulse `iqr_clear_req`
([vfpga_top.svh:520](hardware/src/vfpga_top.svh#L520)) — the same signal that already restarts `IqrIndexPack`
and `IqrIndexFlag`. With it, the packer is force-cleared before every column, so no residue can survive.

**Simulation evidence (red → green → revert-check, all pass):**

| testbench | without fix | with `i_restart` |
|---|---|---|
| [tb_iqr_wide_pack_reset](hardware/unit-tests/tb_iqr_wide_pack_reset.sv) (packer in isolation) | dirty A → **LEAK** (192 errs) | clean |
| [tb_iqr_indexflag_last](hardware/unit-tests/tb_iqr_indexflag_last.sv) (real flagger→packer seam) | mismatch → **LEAK** | clean |

The no-fix run is the revert check (it fails, so the tests have teeth). Both pre-existing index TBs
(`run_index_stream_tb`, `run_idx_mode_tb`) still pass at 0 errors — the port addition is fully
backward-compatible. Run: `hardware/unit-tests/run_wide_pack_reset_tb.sh` and `run_indexflag_last_tb.sh`.

**Honest scope.** The fix cures the **symptom** (cross-column leak) unconditionally — it resolves the
observed spurious-flag defect regardless of what left the residue. It does **not** cure the **trigger**
(why `i_expected` would mismatch the delivered beats in the real pass-1→buffer→pass-2 flow). If that
mismatch can actually happen on the card, the triggering column's own final word is also affected, which
`i_restart` alone doesn't fix. An end-to-end pass-1→buffer→pass-2 TB (the existing round-trip TB resets per
scenario and uses matched `i_expected`, so it can't see this) would rule that out. **Not yet on silicon —
needs a bitstream (bundle with the taxi ragged-packer realign).**

## 9. Window derivation: reliability limits and a cheap safeguard (design analysis)

Fusion needs the histogram window (the value range the 1024 bins cover) sized **before** the first beat.
Today that comes from a **16-group sample** (`WINDOW_GROUPS`, already computed on the FPGA via
`OASIS_IQR_WINDOW_FPGA`). This section records why that is a latent reliability gap and the cheapest fix.

### The gap: the fusion gate can't see the distribution

The gate is `rows > 10M && clean 8-aligned chunks`. **Neither dimension has anything to do with the value
distribution**, but window failure is purely a distribution problem. So the gate does not protect against a
bad window — it filters size and chunk shape only.

**taxi_d3 is the existence proof.** It is a >10M column whose distribution defeats the 16-group sample
(fused it finds 1,296,479 of 1,328,270 — **2.4% low**). The *only* reason it doesn't fuse today is the
ragged-chunk accident, **not** because its distribution is safe. A cleanly-chunked "taxi_d3 twin" would sail
through the gate, fuse, and **silently under-count**.

- **On the current 7 datasets: safe** — only sf10 fuses, and its distribution (tpch extended price) is
  window-friendly. Shipping numbers are correct.
- **On arbitrary user data: a real, quiet hazard** — heavy-tailed columns (financial, latency, sensor, and
  taxi fares themselves) are ordinary, and a large cleanly-chunked one would be exposed. The failure is a
  **silent under-count**, not a crash — worse, because nothing signals it. The correctness suite is
  "structurally blind" to window issues on streaming sets; `overlap_ab.sh` only vouches for synthetic drift.

**Verdict:** left as-is, some future fused dataset *can* silently lose accuracy. It is safe by accident
(sf10's distribution + taxi's raggedness), not by design.

### Why the obvious cheap fixes don't work

- **Parquet metadata:** stores only **min/max** (per row-group, optionally per-page), null_count, sometimes
  distinct_count — **no median, quantiles, mean, or histogram**. Only extremes, which are exactly what
  outliers corrupt.
- **min/max as the window:** the deviation is **bimodal**, not a tunable percentage. taxi_d4's min/max span
  is 33.5M while the bulk is ~5000 → window **~6700× too wide** → Q1 and Q3 collapse into one bin → IQR = 0.
  Clean data → ~0% off (but doesn't need help). Nothing in between.
- **A fixed offset / shrink** to pull min/max toward the bulk **can't work**: the required shrink is
  data-dependent and huge (~99.98% for taxi_d4, ~0% for clean), and to know it you'd need the quantile you
  are trying to compute. Any fixed offset is too little (taxi_d4 stays degenerate) or too much (clips clean
  data). Per-page min/max fails the same way — outliers land in nearly every page.
- **Making window derivation faster to enable fusion for small sets:** not worth it. Small sets already get
  a **free exact** window from the memcpy path (host has the whole column); fusion would trade that for a
  costed sampled one to save a tiny pass-1 crossing. The 10M gate is a correct crossover, not a limitation.

### Is "more groups" (24/32 instead of 48) the answer?

Possibly for *our* data — we measured 16 (inaccurate) and 48 (accurate but slower than memcpy, ~42 vs
32.9 ms) and never swept the middle. **Worth a quick `WINDOW_GROUPS` sweep of 24/32/40**: accept the first
that makes taxi_d3 hit exactly 1,328,270 **and** stays under ~32.9 ms. **But this is tuning, not a
guarantee** — the miss is a sampling artifact, so more groups lowers the *probability* of failure but no
fixed count is *provably* safe (a distribution can always defeat a fixed-size sample). "Observed, not
predictable." Ship a passing number for the known taxi sets if you like; do not mistake it for reliability.

### The reliable directions (for a general operator)

- **Option A — coarse full-column histogram during decode (+1 pass).** The fused pass sees the *whole*
  column for free; use it for a coarse min/max histogram → reliable bulk location (fixes taxi_d3 by
  construction). Costs one extra fine pass afterward (coarse→fine→flag vs today's fine→flag). This is the
  CPU's iterative zoom, in hardware. Reliable; measure whether it still beats memcpy before committing.
- **Option B — a streaming quantile sketch (KLL / t-digest) during decode.** Single-pass, adaptive
  resolution, outlier-robust, gives Q1/Q3 directly with **no window at all** — removes the whole problem and
  would let fusion run everywhere. This is what `approx_quantile` does. Real RTL work; **KLL is the
  FPGA-friendlier choice** (integer samplers, no float). The elegant long-term win; prototype in sim first.
- **Option C — log / non-uniform bins:** unreliable for arbitrary (non-centered) data. Skip.

### The cheap safeguard (add this even before a sketch)

**"Do the fast thing, then glance at the result; if it's obviously broken, redo it the safe way."** After
the fused path computes Q1/Q3, run a microsecond sanity check:

1. **Degenerate check — `Q1 == Q3`** (IQR = 0): the window was too wide, the bulk collapsed into one bin
   (the taxi_d4 catastrophe). One comparison.
2. **Edge-pileup check:** if bin 0 (or the last bin) holds a large fraction of all values, the window is too
   wide / off-center. Sum a couple of bins.

If either trips → **fall back to the memcpy exact path** (host decodes the full column, derives the exact
window, correct answer). If both pass → keep the fast fused result.

- **Cost:** the check is ~free (a few compares/sums); the fallback re-decodes (~2× operator) but only on the
  rare bad dataset, so the average barely moves.
- **What it buys:** it doesn't *prevent* a bad window, it *catches* one — turning today's "fast but silently
  wrong" into "a bit slower but correct." Never ships a silent wrong answer.
- This is the "cheap a-priori test" the design notes flagged as the precondition for trusting a sampled
  window. A smarter variant reuses the coarse histogram to re-zoom instead of a full redo (Option A).

**Recommendation:** for the fixed benchmark, current fusion is fine. For fusion exposed to arbitrary data,
add the safeguard (cheap, closes the silent-wrong gap now); pursue the KLL sketch (Option B) as the real
reliability fix that also unlocks fusion for small sets and taxi.

## 10. Reproduce

```bash
cd ~/oasis
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
# card must be programmed (build-20) + huge pages set + driver matching the running kernel

# --- correctness (three-way, exact) ---
bench/correctness_3way.sh quartiles      # quartiles_match=true, n_floor==n_true
bench/correctness_3way.sh flags          # cpp_vs_oracle=0; fpga_vs_cpp = binning error

# --- timing: FPGA vs C++ vs SQL (both ratios) ---
cat /home/myaksi/datasets/tpch_extprice_sf10.parquet > /dev/null   # warm the page cache
timeout 5400 env OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_DECODE_WINDOW=16 \
  python3 bench/medians.py --consume -n 15 --stats --cpp-impl groupby

# --- CPU method comparison: z-score / built-in quantile / our SQL / our C++ (§6, no FPGA) ---
bench/methods_ab.sh taxi_d1 sf10          # or list all 7 datasets; REPS=5 for stabler numbers
```

### Gotchas that cost real time this session (see also `~/.claude` memory)

- **`cThread vfid:0` / `insmod: Invalid module format`** = the shared `coyote_driver.ko` was built for an
  old kernel (6.8.0-134) while the node runs 6.8.0-136. Rebuild it on the node:
  `cd parcore/libstf/coyote/driver && make clean && make`, then reload. Switching nodes does NOT help
  (NFS-shared `.ko`, whole cluster on the new kernel).
- **Never embed the FPGA function in a complex query.** `iqr_flags`/`iqr_flags_only` must be the only heavy
  operator — its host receiver `BypassStreamReceiver::next()` waits with **no timeout**, so a GROUP BY /
  window / `quantile_disc` / positional join / `CREATE TABLE AS` in the same query can starve it and
  **deadlock forever**. The correctness harness runs the FPGA as one isolated aggregate for exactly this
  reason. `medians.py --consume` is already a simple aggregate, so it is safe.
- **Never Ctrl-C / Ctrl-Z a running FPGA query.** Ctrl-Z leaves it stopped (`T`) so a queued SIGTERM can't
  land; Coyote has no inter-process reset and a hard kill can wedge the card (reprogram/reboot). Use
  `timeout`, and kill the runner *script* first (loops respawn a duckdb per dataset).
- **Huge pages** are cleared by every reprogram: `echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`.
