# Microbenchmarks — controlled synthetic sweeps

Companion to `report_2807.md` (which benchmarks the 7 **real** datasets). This file holds
**microbenchmarks on synthetic data where exactly one input property varies at a time**, so an effect
can be attributed to a cause instead of to four confounded variables.

Motivation (supervisor, 2026-08-08): *"put a micro benchmark plot with synthetic data to show
different effects of input data characteristics on runtime/throughput."*

**The paper's three panels are Tests 1, 3 and 4** — size, host cores, and compression/encoding. All
three characterise behaviour **shared** by the IQR and z-score operators, so each figure supports both
halves of the joint paper. **Test 2 (cardinality) is withdrawn**: it is IQR-specific, because only
quartiles make the CPU baseline pay for distinct values. It is retained below as the reason encoding
and byte volume must be pinned in any sweep that varies the data.

**Test 5 (skew) is a CONTROL, not a fourth panel.** Tests 1/3/4 all ran on uniform synthetic data,
which invites the objection *"real data is skewed, so your numbers do not transfer."* Test 5 closes
that objection with a measured invariance statement and costs two sentences of prose, not a figure —
flat lines make a weak panel. It is the control that licenses the other three.

---

## Test 1 — SIZE SWEEP (1M → 100M rows), fusion OFF vs ON

**Date:** 2026-08-08 · **Node:** alveo-u55c-01 · **Harness:** `bench/gen_size_sweep.sh`,
`bench/size_sweep.py` · **Raw:** `bench/size_sweep.csv`, `bench/size_sweep_fused.csv`

### Measurement protocol (NEW — supersedes medians-and-spread for microbenchmarks)

> **Run the query 7 times in ONE DuckDB session; report the arithmetic MEAN OF THE LAST 3.
> No median. No spread.**

The first 4 iterations are discarded as warm-up. All 7 run inside a single DuckDB process, which
matters: DuckDB's allocator pooling is absent early in a session and made taxi_d3/d4 bimodal
(RESULTS.md §9.18). Four discarded iterations put every number firmly in steady state, and averaging
3 smooths residual jitter without hiding a trend the way a median over a drifting sample would.

Both arms use `--consume` (aggregate the flags), so DuckDB's single-threaded `CREATE TABLE` append tax
— ~70% of e2e and identical on both sides — is excluded. CPU arm is `iqr_cpu_flags_groupby()`, the
SQL-exact baseline (RESULTS.md §9.35). `PRAGMA threads=32`.

### Dataset design

Generator: `bench/gen_size_sweep.sh` → `/home/myaksi/datasets/sizesweep/size_<N>M.parquet`

```sql
COPY (SELECT (hash(i) % 1000000)::BIGINT
             + CASE WHEN i % 1000 = 0 THEN 5000000 ELSE 0 END AS v
      FROM range(<N>)) TO '<file>' (FORMAT PARQUET, ROW_GROUP_SIZE 122880);
```

Every property except row count is held constant:

| property | value | why |
|---|---|---|
| cardinality | **~1,000,000 distinct, FIXED** | Deliberately HIGH. Real columns containing outliers are high-card (extprice 934k, sf10 1.35M; only tpch_qty is low at 50). A low-card column lets DuckDB build a small dictionary, turning a *size* sweep into a *dictionary-decode* sweep. |
| distribution | uniform over `[0, 1e6)`, stationary | No drift ⇒ the sampled fused window is valid and results are reproducible. |
| outliers | 0.1% (`i % 1000 == 0`), at `+5e6` | Predictable count = `rows/1000`. |
| row groups | 122880 rows | **Must be a multiple of 8.** A non-final group with `num_values % 8 != 0` makes the host's ragged guard reject streaming and silently fall back to memcpy — a code-path change mid-sweep. |
| generation | from `range()` | `COPY` from an existing parquet preserves the SOURCE row-group layout (how `taxi_d4_dd` got its odd 51449/124849 groups). |

**The sweep self-checks.** The base spans `[0, 1e6)`, so fences land at ≈`[-500k, 1.5e6]`; outliers sit
at `[5e6, 6e6)` — far outside, with **nothing in between**. No value lies near a fence, so the FPGA's
4096-bin quantisation (window resolved to ~610) cannot change any row's verdict. Expected flags is
therefore exactly `rows/1000` at every size: any deviation is a real bug, never a binning artefact.
All 7 iterations are checked at every point, which also soak-tests for the run-to-run "wandering"
signature of a marginal-hold silicon defect.

### Generated datasets — both gates PASS

| file | rows | MB | B/row | distinct~ | groups | min_group | %8 | encoding |
|---|--:|--:|--:|--:|--:|--:|--:|---|
| size_1M | 1,000,000 | 5 | 4.94 | 676,307 | 9 | 16,960 | 0 | PLAIN |
| size_3M | 3,000,000 | 14 | 4.94 | 943,987 | 25 | 50,880 | 0 | PLAIN |
| size_6M | 6,000,000 | 28 | 4.94 | 979,812 | 49 | 101,760 | 0 | PLAIN |
| size_10M | 10,000,000 | 47 | 4.94 | 979,812 | 82 | 46,720 | 0 | PLAIN |
| size_20M | 20,000,000 | 94 | 4.94 | 979,812 | 163 | 93,440 | 0 | PLAIN |
| size_40M | 40,000,000 | 188 | 4.94 | 1,000,053 | 326 | 64,000 | 0 | PLAIN |
| size_60M | 60,000,000 | 282 | 4.94 | 1,000,053 | 489 | 34,560 | 0 | PLAIN |
| size_80M | 80,000,000 | 377 | 4.94 | 1,021,148 | 652 | 5,120 | 0 | PLAIN |
| size_100M | 100,000,000 | 471 | 4.94 | 1,021,148 | 814 | 98,560 | 0 | PLAIN |

**Gate 1: `min_group % 8 == 0` on every file** ✅ — streaming is never rejected.
**Gate 2: encoding is PLAIN on all nine** ✅ — the sweep measures size, not encoding.
Bonus: **bytes/row is identical (4.94) at every size** ✅ — no compressibility drift, so byte volume
scales exactly linearly with N. Total disk 1.5 GB.

⚠️ Cardinality is fixed in **absolute** terms, not as a ratio: at 1M rows the column is ~68% distinct,
at 100M ~1%. Fixing the ratio instead would grow the dictionary with N and eventually flip the
encoding — confounding the very thing being measured.

### Results — fusion OFF (value path, 2 PCIe passes)

| rows | expect | FPGA e2e (s) | CPU e2e (s) | FPGA op (ms) | CPU op (ms) | F ms/Mrow | C ms/Mrow | F GB/s | flags |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| 1M | 1,000 | 0.0110 | 0.0503 | 7.7 | 47.3 | 7.70 | 47.31 | 1.04 | ok |
| 3M | 3,000 | 0.0180 | 0.0517 | 14.0 | 48.7 | 4.65 | 16.24 | 1.72 | ok |
| 6M | 6,000 | 0.0283 | 0.0893 | 23.7 | 84.9 | 3.95 | 14.16 | 2.03 | ok |
| 10M | 10,000 | 0.0420 | 0.0967 | 36.5 | 91.6 | 3.65 | 9.16 | 2.19 | ok |
| 20M | 20,000 | 0.0790 | 0.1330 | 70.8 | 127.0 | 3.54 | 6.35 | 2.26 | ok |
| 40M | 40,000 | 0.1453 | 0.2273 | 135.1 | 218.3 | 3.38 | 5.46 | 2.37 | ok |
| 60M | 60,000 | 0.2173 | 0.3133 | 204.2 | 302.7 | 3.40 | 5.05 | 2.35 | ok |
| 80M | 80,000 | 0.2853 | 0.3820 | 270.1 | 369.1 | 3.38 | 4.61 | 2.37 | ok |
| 100M | 100,000 | 0.3557 | 0.4603 | 337.3 | 444.6 | 3.37 | 4.45 | 2.37 | ok |

### Results — fusion ON (pass 1 rides decode, 1 PCIe pass)

Requires `OASIS_IQR_FUSE_MIN_ROWS=0` as well as `OASIS_IQR_FUSE=1`; the default gate is 30M, so
without lowering it every point below 30M silently runs the value path while *looking* like a fused
measurement. `--fuse` sets both and the harness prints the actual `pass1=` state per point.
**All nine points confirmed `pass1=fused`.**

| rows | expect | FPGA e2e (s) | CPU e2e (s) | FPGA op (ms) | CPU op (ms) | F ms/Mrow | C ms/Mrow | F GB/s | flags | pass1 |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|:--|
| 1M | 1,000 | 0.0150 | 0.0497 | 11.6 | 46.8 | 11.58 | 46.83 | 0.69 | ok | fused |
| 3M | 3,000 | 0.0217 | 0.0513 | 17.7 | 48.0 | 5.90 | 15.99 | 1.36 | ok | fused |
| 6M | 6,000 | 0.0287 | 0.0900 | 23.8 | 85.5 | 3.97 | 14.25 | 2.02 | ok | fused |
| 10M | 10,000 | 0.0360 | 0.1023 | 31.6 | 97.4 | 3.16 | 9.74 | 2.53 | ok | fused |
| 20M | 20,000 | 0.0600 | 0.1300 | 53.4 | 124.0 | 2.67 | 6.20 | 2.99 | ok | fused |
| 40M | 40,000 | 0.1067 | 0.2340 | 97.3 | 225.9 | 2.43 | 5.65 | 3.29 | ok | fused |
| 60M | 60,000 | 0.1543 | 0.3153 | 142.4 | 304.8 | 2.37 | 5.08 | 3.37 | ok | fused |
| 80M | 80,000 | 0.1997 | 0.4050 | 184.7 | 391.5 | 2.31 | 4.89 | 3.46 | ok | fused |
| 100M | 100,000 | 0.2487 | 0.4640 | 229.7 | 447.2 | 2.30 | 4.47 | 3.48 | ok | fused |

⚠️ Do **not** compare the CPU columns across the two tables — that arm moved 3–6% between runs
(40M: 218.3 vs 225.9). Only FPGA-vs-FPGA comparisons are valid across tables.

---

## Analysis

### 1. Everything is affine in N; the FPGA wins on FIXED cost, not per-row rate

Least-squares fit over the linear region (N ≥ 20M):

```
value path (no fusion)   op ≈  3.1 ms +  3.34 ms/Mrow
fused                    op ≈  9.5 ms +  2.20 ms/Mrow
CPU (groupby)            op ≈ 56.5 ms +  3.93 ms/Mrow
```

The FPGA's fixed cost is **18× smaller** than the CPU's (3.1 vs 56.5 ms) but its marginal rate is only
**1.18× better** (3.34 vs 3.93). So on the value path the speedup **decays monotonically** —
6.14× at 1M → 1.32× at 100M — converging toward 1.18×. Neither curve is flat: FPGA ms/Mrow falls
7.70 → 3.37, the same amortisation shape as the CPU, just 18× smaller.

⚠️ This **corrects** the older narrative in `compact.md` §2 ("crossover at ~10M rows; ≥13M the FPGA
loses"). On controlled high-cardinality data the FPGA wins at **every** size 1M–100M; only the
*margin* shrinks. The old crossover was an artefact of comparing 7 datasets that differ in encoding
and cardinality as well as size.

### 2. Fusion changes the SLOPE — this is the paper's thesis, measured

Fusion **costs +6.4 ms fixed** and **saves 1.14 ms/Mrow** (34% of the marginal rate). Break-even:

```
6.4 / 1.14 = 5.6M rows  (predicted)      6M  (measured: 23.7 vs 23.8 ms — a dead tie)
```

Model and measurement agree, so this is a mechanism rather than a fit.

| N | value (ms) | fused (ms) | Δ | verdict |
|--:|--:|--:|--:|:--|
| 1M | 7.7 | 11.6 | +3.9 | fused loses (1.51×) |
| 3M | 14.0 | 17.7 | +3.7 | fused loses (1.26×) |
| **6M** | **23.7** | **23.8** | **+0.1** | **tie ← crossover** |
| 10M | 36.5 | 31.6 | −4.9 | fused wins 1.16× |
| 20M | 70.8 | 53.4 | −17.4 | fused wins 1.33× |
| 40M | 135.1 | 97.3 | −37.8 | fused wins 1.39× |
| 60M | 204.2 | 142.4 | −61.8 | fused wins 1.43× |
| 80M | 270.1 | 184.7 | −85.4 | fused wins 1.46× |
| 100M | 337.3 | 229.7 | −107.6 | fused wins 1.47× |

**The fixed cost is the window sample** (`win_derive`, taken before the first beat: ~7 ms measured
independently on sf10). **The per-row saving is one eliminated PCIe pass** — and the profiler proves it
exactly. `passes` (the IQR pass time) at 100M:

```
value path   127.17 ms      fused   63.80 ms      ratio 1.993x  ≈ EXACTLY 2x
```

Two streamed passes become one. That is the cleanest single piece of evidence in the study that
fusing statistics into the decode pipeline is a real architectural saving, not a constant-factor tweak.

### 3. Fusion is what makes the FPGA advantage DURABLE at scale

Asymptotic marginal advantage over the CPU: **no fusion 1.18× · fused 1.79×.**

| N | speedup, no fusion | speedup, fused |
|--:|--:|--:|
| 1M | 6.14× | 4.03× |
| 3M | 3.48× | 2.71× |
| 6M | 3.58× | 3.59× |
| 10M | 2.51× | 3.08× |
| 20M | 1.79× | 2.32× |
| 40M | 1.62× | 2.32× |
| 60M | 1.48× | 2.14× |
| 80M | 1.37× | 2.12× |
| 100M | **1.32× ↓** | **1.95× →** |

Without fusion the advantage asymptotically evaporates (winning only on fixed cost). With fusion it
**plateaus at ~2×**, because the saving is per-row. Throughput asymptote 2.37 → **3.48 GB/s** (1.47×).

### 4. Fusion halves host CPU-seconds — and wins at EVERY size, including where it loses wall-clock

| N | FPGA CPU-s (value) | FPGA CPU-s (fused) | fused gain | CPU-s vs CPU arm (fused) |
|--:|--:|--:|--:|--:|
| 1M | 0.0193 | 0.0065 | **2.99×** | 39.4× |
| 10M | 0.1197 | 0.0677 | 1.77× | 9.8× |
| 20M | 0.2448 | 0.1122 | 2.18× | 10.0× |
| 40M | 0.4400 | 0.1877 | 2.34× | 10.1× |
| 60M | 0.6863 | 0.2819 | 2.43× | 9.1× |
| 100M | 1.0920 | 0.4496 | 2.43× | **9.21×** |

At 100M the CPU-seconds offload is **9.2× fused vs 3.8× unfused**. Critically, at 1M fusion is
**1.51× WORSE on wall-clock but 2.99× BETTER on CPU-seconds** — so *the wall-clock crossover (6M) and
the CPU-seconds crossover (never; fusion always wins) are different*. Any automatic fusion policy must
therefore choose which metric it optimises; it cannot maximise both.

---

## Consequences / open items

1. **The shipped `fuse_min_rows = 30M` is ~5× too high for this data shape** (measured crossover 6M).
   But do NOT simply lower the constant: 30M was set from **taxi**, where fusion measured a wall-clock
   *loss* at 13M (36→43 ms) and 20M (54→62 ms). Both results are correct — taxi_d3/d4 have odd row
   groups (51449/124849) needing the host ragged stitch, and taxi is tail-heavy/low-card where the
   sampled window is harder. Both raise taxi's fused *fixed* cost, moving its break-even right.
2. **Next measurement:** sweep `OASIS_IQR_FUSE_MIN_ROWS` on taxi_d3/d4 to locate *their* crossover.
   Two shapes bracket the range any policy must cover.
3. **Then the auto-decision.** `FooterFacts` (`oasis_iqr.cpp:560`) currently exposes only `rows` and
   `stream_ok` — enough for a row rule, not enough to distinguish clean from ragged geometry. It
   already walks every group's `num_values`, so adding a "needs ragged stitch" flag and bytes/row is
   cheap. The policy then becomes `break_even ≈ fixed_cost(shape) / marginal_saving` instead of one
   constant, with the metric (wall-clock vs CPU-seconds) an explicit choice.
4. **Still to run** (see the axis survey): cardinality sweep (encoding switch), compression
   (Snappy vs none), distribution shape / outlier fraction (expect FPGA-flat — the data-obliviousness
   claim, and the natural joint panel with the z-score operator), null fraction, row-group size.

## Reproduce

```bash
cd ~/oasis
bash bench/gen_size_sweep.sh                                  # ~1.5 GB; prints both gates
bash bench/gen_size_sweep.sh verify                           # re-check gates only
python3 bench/size_sweep.py        --csv bench/size_sweep.csv
python3 bench/size_sweep.py --fuse --csv bench/size_sweep_fused.csv
```

---

## Test 2 — CARDINALITY SWEEP (10M rows fixed, 10 → 10M distinct values)

> ⚠️ **WITHDRAWN FROM THE PAPER (2026-08-09), measurements retained.** Cardinality is an
> **IQR-specific** axis: the CPU baseline only pays for distinct values because quartiles need a
> GROUP BY. A z-score baseline is count/sum/sum-of-squares, i.e. O(rows) and cardinality-independent,
> so both arms would be flat and the panel would not transfer to the companion operator. The paper's
> three panels are **Test 1 (size)**, **Test 3 (host cores)** and **Test 4 (compression & encoding)**,
> all of which characterise behaviour shared by both operators. This section stays because it is the
> reason encoding and byte volume have to be pinned in any sweep that varies the data — a lesson Test
> 4 is built on — and because deleting measured data only means re-deriving it later.

**Date:** 2026-08-08 · **Node:** alveo-u55c-01 · **Harness:** `bench/gen_card_sweep.sh`,
`bench/card_sweep.py` · **Raw:** `bench/card_sweep_10m_snappy.csv` (primary),
`bench/card_sweep_10m.csv` (uncompressed control)

Same protocol as Test 1: **7 runs in one DuckDB session, mean of the last 3, no median, no spread.**
CPU arm is `iqr_cpu_flags_groupby()` — the SQL-exact GROUP BY transliteration — throughout.
Fusion is left to the shipped policy with the threshold set to Test 1's measured crossover (6M rows);
at 10M rows that means **every point fused automatically**, confirmed by the `pass1` column.

### Isolating cardinality took three attempts — the first two are superseded

Worth recording, because two earlier versions produced *plausible but wrong* trends:

1. **v1 — spread the levels with `level * (RANGE/CARD)`.** That step is highly composite, so every
   value inherited its trailing zero bits: only 512 of 1000 possible low-12-bit patterns at CARD=1000,
   1024 of 4096 at CARD=10000. The C++ baseline uses **radix** aggregation, so this imbalanced its
   partitioning by an amount that *varied with cardinality* — manufacturing a smooth monotonic CPU
   decline (74.3 → 64.8 ms) that looked like a real finding. **Discarded.**
2. **v2 — multiplicative permutation** `((hash(i) % CARD) * 2654435761) % RANGE`. `P` is odd and not
   divisible by 5, so `gcd(P, 10^k) = 1` and the map is a bijection: exactly CARD levels, low bits
   fully spread. The fake decline vanished. But two things still moved with cardinality:
   - **encoding** — Parquet builds a dictionary until the dictionary page exceeds ~128 KB (measured:
     flips between 20k and 30k distinct per row group), then writes PLAIN. The FPGA stepped **1.7×**
     at that boundary: an *encoding* effect wearing a cardinality costume.
   - **bytes/row** — Snappy compresses repeated values well, so bytes/row moved 0.63 → 4.94; the FPGA
     had to fetch 7.8× more data at high cardinality.
3. **v3 (this test) — pin both.** `DICTIONARY_SIZE_LIMIT 0` forces PLAIN at every cardinality;
   `COMPRESSION UNCOMPRESSED` pins bytes/row at exactly 8.00. **Now the FPGA arm's flatness becomes an
   internal check on the sweep itself.** A Snappy variant is then run as the realistic counterpart.

### Dataset design

```sql
COPY (SELECT (((hash(i) % CARD) * 2654435761) % 10000000)::BIGINT
             + CASE WHEN i % 1000 = 0 THEN 50000000 ELSE 0 END AS v
      FROM range(10000000))
TO '<file>' (FORMAT PARQUET, ROW_GROUP_SIZE 122880,
             DICTIONARY_SIZE_LIMIT 0, COMPRESSION {UNCOMPRESSED|SNAPPY});
```

| property | value | why |
|---|---|---|
| rows | **10,000,000 FIXED** | the axis under test is distinct count, not size |
| value range | **`[0, 10^7)` FIXED** | keeps Q1≈2.5e6, Q3≈7.5e6, IQR≈5e6, fence_hi≈1.5e7 identical at every point, so the expected flag count never moves |
| level placement | multiplicative permutation | bijection ⇒ exactly CARD levels, low bits fully spread (see v1 above) |
| outliers | 0.1% at **+5e7** | lands in `[5e7, 6e7)`, far above fence_hi≈1.5e7 with **nothing in between**, so 4096-bin quantisation cannot change any verdict ⇒ expected flags = **10,000** exactly, at every point |
| encoding | **PLAIN pinned** | removes the dictionary→PLAIN step |
| row groups | 122880 (82 groups, min 46720) | multiple of 8, or the ragged guard rejects streaming |

### Generated datasets — gates PASS on both sets

Identical values in both sets; only compression differs (so `distinct~` matches row for row).

**A. Uncompressed (isolation control)** — `~/datasets/cardsweep10m`, 7 files × 76.3 MiB

| card | distinct~ | bytes/row | groups | min_group %8 | encoding | compression |
|--:|--:|--:|--:|--:|:--|:--|
| 10 | 20 | 8.00 | 82 | 0 | PLAIN | UNCOMPRESSED |
| 100 | 204 | 8.00 | 82 | 0 | PLAIN | UNCOMPRESSED |
| 1,000 | 1,969 | 8.00 | 82 | 0 | PLAIN | UNCOMPRESSED |
| 10,000 | 16,048 | 8.00 | 82 | 0 | PLAIN | UNCOMPRESSED |
| 100,000 | 109,254 | 8.00 | 82 | 0 | PLAIN | UNCOMPRESSED |
| 1,000,000 | 1,009,006 | 8.00 | 82 | 0 | PLAIN | UNCOMPRESSED |
| 10,000,000 | 6,181,435 | 8.00 | 82 | 0 | PLAIN | UNCOMPRESSED |

**B. Snappy (realistic, primary)** — `~/datasets/cardsweep10m_snappy`, 258 MB total

| card | distinct~ | file (MB) | bytes/row | groups | min_group %8 | encoding | compression |
|--:|--:|--:|--:|--:|--:|:--|:--|
| 10 | 20 | 19.0 | 1.90 | 82 | 0 | PLAIN | SNAPPY |
| 100 | 204 | 21.3 | 2.13 | 82 | 0 | PLAIN | SNAPPY |
| 1,000 | 1,969 | 31.4 | 3.14 | 82 | 0 | PLAIN | SNAPPY |
| 10,000 | 16,048 | 47.1 | 4.71 | 82 | 0 | PLAIN | SNAPPY |
| 100,000 | 109,254 | 51.6 | 5.16 | 82 | 0 | PLAIN | SNAPPY |
| 1,000,000 | 1,009,006 | 52.1 | 5.21 | 82 | 0 | PLAIN | SNAPPY |
| 10,000,000 | 6,181,435 | 52.1 | 5.21 | 82 | 0 | PLAIN | SNAPPY |

**Why `distinct~` ≠ `card`.** Two effects, and together they predict the observed counts to within the
estimator's error: (1) the **outlier rows contribute their own levels** — that is the ~2× at low
cardinality (10 base + 10 outlier = 20); (2) **coupon collector** — `hash(i) % CARD` does not hit every
level, so 10M draws over 10M levels cover only `1 − e^{−1}` ≈ 63% (6.33M predicted, 6.18M measured),
and the 10,000 outlier rows drawing from 10,000 levels reach only 6,321 distinct.
`card` is the *requested* level count; `distinct~` is what the file actually contains.

### Results — Snappy (primary)

| card | distinct~ | B/row | FPGA op (ms) | CPU op (ms) | **speedup** | GB/s | flags | pass1 |
|--:|--:|--:|--:|--:|--:|--:|:--|:--|
| 10 | 20 | 1.90 | 24.4 | 44.2 | **1.81×** | 3.28 | ok | fused |
| 100 | 204 | 2.13 | 24.4 | 40.3 | **1.65×** | 3.28 | ok | fused |
| 1,000 | 1,969 | 3.14 | 25.8 | 40.2 | **1.56×** | 3.10 | ok | fused |
| 10,000 | 16,048 | 4.71 | 30.9 | 43.2 | **1.40×** | 2.59 | ok | fused |
| 100,000 | 109,254 | 5.16 | 30.1 | 49.1 | **1.63×** | 2.66 | ok | fused |
| 1,000,000 | 1,009,006 | 5.21 | 30.5 | 97.0 | **3.18×** | 2.62 | ok | fused |
| 10,000,000 | 6,181,435 | 5.21 | 30.6 | 357.9 | **11.69×** | 2.61 | ok | fused |

(These are the values in `bench/card_sweep_10m_snappy.csv`. An earlier identical run of the same
command gave 24.6 / 43.1 / 1.75× … 31.2 / 350.3 / 11.23× — i.e. **run-to-run variation is 1–3%**, which
is the right order for this protocol and does not move any conclusion.)

### Results — Uncompressed (isolation control, bytes/row pinned at 8.00)

| card | FPGA op (ms) | CPU op (ms) | speedup | flags |
|--:|--:|--:|--:|:--|
| 10 | 31.0 | 42.2 | 1.36× | ok |
| 100 | 32.0 | 38.1 | 1.19× | ok |
| 1,000 | 32.5 | 38.7 | 1.19× | ok |
| 10,000 | 31.6 | 38.6 | 1.22× | ok |
| 100,000 | 31.1 | 43.9 | 1.41× | ok |
| 1,000,000 | 31.9 | 95.1 | 2.98× | ok |
| 10,000,000 | 32.9 | 342.2 | 10.40× | ok |

Correctness held at **all 7 cardinalities × 2 compressions × 7 iterations = 98 runs**, including
`card=10`, where 10M values pile into a handful of the 4096 histogram bins — the same-bin
read-modify-write collision pathology behind the historical ~10% count-loss bug. Notable at WHS
+0.001 ns.

---

## Analysis (Test 2)

### 1. The isolation gate passes: the FPGA is indifferent to cardinality

With bytes/row, encoding and row count all pinned, the FPGA arm is **flat at 31.0–32.9 ms (6.1%
spread) across six decades of cardinality** (uncompressed control). Nothing in the FPGA's cost depends on how many distinct
values exist — its 4096-bin histogram does identical work whether there are 20 levels or 6.2M.

### 2. The CPU is O(rows) + O(distinct), and the knee is at ~1% of N

GROUP BY always performs 10M probes — one per row — regardless of group count. Cardinality only adds
*per-distinct-value* work (table footprint plus the final sort), which stays negligible until it is a
meaningful fraction of the rows:

| card | C/N | CPU vs card=10k (snappy) | (uncompressed) |
|--:|--:|--:|--:|
| 10,000 | 0.10% | 1.00× | 1.00× |
| 100,000 | 1.00% | 1.14× | 1.14× |
| 1,000,000 | 10.00% | 2.25× | 2.46× |
| 10,000,000 | 100.00% | **8.28×** | **8.87×** |

Flat to 10k, first visible at ~1% of N, dominant at all-distinct. This is the sweep's central result:
**the two arms have different complexity in cardinality, not different constants.** Speedup therefore
runs from **1.4× to 11.7×** on the same operator, same bitstream, same row count.

### 3. Compression: the FPGA has a large byte-independent floor

Comparing the two sets (identical values, only compression differs):

| card | B/row | vs 8.00 | FPGA snappy | FPGA uncomp | time saved |
|--:|--:|--:|--:|--:|--:|
| 10 | 1.90 | 4.21× fewer | 24.4 | 31.0 | 21.3% |
| 1,000 | 3.14 | 2.55× fewer | 25.8 | 32.5 | 20.6% |
| 10,000 | 4.71 | 1.70× fewer | 30.9 | 31.6 | 2.2% |
| 1,000,000 | 5.21 | 1.54× fewer | 30.5 | 31.9 | 4.4% |

A **4.2× reduction in bytes buys only ~21% of operator time**, so the FPGA is *not* simply byte-bound
at this scale — there is a large fixed floor (~24 ms at 10M rows). Snappy nevertheless raises the
speedup at every point (1.81× vs 1.36× at card=10), because the FPGA benefits from fewer bytes more
than the CPU does.

⚠️ **Uncompressed is not representative of production Parquet** (real files are Snappy or ZSTD). It is
used here purely to pin bytes/row so cardinality is genuinely the only variable. **Quote the Snappy
table**; the uncompressed one is a control that validates the isolation.

## Consequences / open items (Test 2)

1. **Cardinality is a first-order axis and belongs in the paper** — an 11.7× vs 1.4× swing from one
   data property, with a mechanistic explanation (differing complexity, not differing constants).
2. **It does not explain the real-dataset residual.** Test 1's size model over-predicts the
   dictionary-encoded real datasets by 1.29–2.54×, and this sweep shows the FPGA gets *faster* on
   low-byte/low-cardinality data, i.e. the effect runs the wrong way. Remaining suspects for taxi:
   **tail-heavy distribution** (all synthetic data so far is uniform) and **odd row groups** needing
   the host ragged stitch. That is the next sweep to design.
3. **Encoding is a separate axis and is now measurable.** `DICTIONARY_SIZE_LIMIT` forces the writer's
   hand in both directions (verified: `0` → PLAIN at card=1,000; `10 MB` → dictionary at card=100,000;
   `50 MB` → dictionary at card=1,000,000, which makes the file *bigger* at 8.91 B/row). So encoding
   can be flipped at **fixed** cardinality — the clean encoding test, when wanted.

## Reproduce (Test 2)

```bash
cd ~/oasis
# primary: realistic Snappy
COMPRESSION=SNAPPY DS=~/datasets/cardsweep10m_snappy bash bench/gen_card_sweep.sh
python3 bench/card_sweep.py --dsdir ~/datasets/cardsweep10m_snappy \
        --csv bench/card_sweep_10m_snappy.csv

# control: uncompressed, bytes/row pinned at 8.00 -> FPGA arm must be flat
bash bench/gen_card_sweep.sh
python3 bench/card_sweep.py --csv bench/card_sweep_10m.csv

bash bench/gen_card_sweep.sh verify        # re-print gates for either set (DS=... to select)
```

⚠️ **Bitstream provenance is UNCONFIRMED for this run.** The tests ran on alveo-u55c-01 on 2026-08-08,
after build-29+physopt (`build-29/bitstreams/cyt_top_b29_po.bit`, WNS −0.518) passed its 4 gates — but
the flash command was not captured, so it is possible the card still held build-28's
`cyt_top_ssi_spreadslls.bit` (−0.657). Both are functionally validated, so the correctness results
stand either way; the *timing* numbers should be re-attributed if the check below says otherwise:

```bash
cat /sys/kernel/coyote_sysfs_0/cyt_attr_cnfg | grep -E "enabled memory|probe shell ID"
#   enabled memory: 0  -> build-29 (HBM out)
#   enabled memory: 1  -> build-28
```

---

## Test 3 — CORE-COUNT SWEEP (1 → 32 host threads), the offload experiment

Tests 1 and 2 both ran at `PRAGMA threads=32`, so they only ever answered *"is the FPGA faster than 32
CPU cores"*. They cannot answer the question the thesis actually rests on: **how much host CPU does the
offloaded path give back?** This sweep holds the dataset fixed and moves the host core count instead.

Run on **alveo-u55c-01, 2026-08-08** (32 CPUs, 1 NUMA node). Correctness `ok` at every point.

### Measurement protocol

Identical to Tests 1 and 2 — **7 runs in one DuckDB session, arithmetic mean of the last 3, no median,
no spread** — reused verbatim from `size_sweep.run_arm`, so "operator time" means the same thing in all
three tests. Each core count gets a **fresh DuckDB process**, so `PRAGMA threads` is never mutated
mid-session and DuckDB's scheduler is sized correctly from startup.

**`PRAGMA threads` alone is NOT sufficient, and this cost a design iteration to discover.** Three host
regions size themselves from `std::thread::hardware_concurrency()` and ignore the pragma entirely:

| region | file:line | what it does |
|---|---|---|
| window-sample decode | `oasis_iqr.cpp:510` | decodes the uniformly-spaced sample groups in parallel |
| flag copy-out | `oasis_iqr.cpp:871` | copies the returned bitmask into DuckDB vectors |
| `IqrThreadPool` | `oasis_iqr.cpp:1489` | the persistent pool behind `ParallelRanges` |

Measured on this host (**glibc 2.35**): `std::thread::hardware_concurrency()` is **not affinity-aware**
— it reports 64 even under `taskset -c 0`. So each point sets `PRAGMA threads=N` **and** pins the
process with `taskset`. Pinning does not shrink those pools; it **confines** their work to N cores,
which is the resource question being asked. Two consequences, stated rather than hidden:

* At low N those fixed-size pools are oversubscribed on few cores and pay scheduling overhead the CPU
  baseline does not. **The bias runs against the FPGA arm, so these results are conservative.**
* `--no-taskset` reproduces the pragma-only measurement, isolating how much of the FPGA arm's host cost
  lives outside DuckDB's scheduler. Not run here.

The CPU list is derived from the real topology (`lscpu -p`), not assumed to be `0..N-1`: one CPU per
**physical** core, the card's NUMA node first (`lspci -d 10ee:` → `numa_node`), SMT siblings last. On
the build node a naive `0-3` spans **four** NUMA nodes (CPU 0→socket 0, CPU 1→socket 1, …), which would
make small-N points measure interconnect latency rather than core count. On alveo-u55c-01 (1 NUMA node)
the picker degenerates to `0..N-1`, so the hazard never fired here — but the guard stays.

### Datasets used — both reused, nothing new generated

Deliberately **not** new data: reusing characterised files from Tests 1 and 2 makes the core-count axis
the only thing that changed relative to a published measurement.

**A. `balanced` (primary)** — `~/datasets/sizesweep/size_20M.parquet`, i.e. Test 1's 20M point.

| property | value | why this point |
|---|---|---|
| rows | 20,000,000 | in the **flat part** of Test 1's curve (2.67 ms/Mrow fused, vs 7.70 at 1M), so fixed startup is not what is being measured — yet a 1-thread CPU run still finishes in ~0.75 s |
| distinct | ~979,812 = **4.9% of N** | **past** Test 2's C≈1% knee but far from all-distinct. The all-distinct point would have inflated every speedup ~5× for reasons unrelated to core count |
| encoding / compression | PLAIN / SNAPPY, 4.94 B/row | realistic; identical to Test 1 |
| row groups | 163, min 93,440, all `%8 == 0` | streaming/fusion is never rejected |
| outliers | 0.1% at `+5e6`, in an empty gap | expected flags = **20,000** exactly, quantisation-proof |
| fusion | **engages by POLICY** (20M > the 6M crossover) | the configuration that would actually ship, not an override |

**B. `knee` (control)** — `~/datasets/cardsweep10m_snappy/card_100000.parquet`, Test 2's card=100,000.

| property | value | why this point |
|---|---|---|
| rows | 10,000,000 | fixed |
| distinct | ~109,254 = **1.1% of N** | Test 2's **least flattering** cardinality (1.63× at 32 threads, near the minimum of the U-shaped speedup curve) |
| encoding / compression | PLAIN / SNAPPY, 5.16 B/row | realistic |
| outliers | 0.1% at `+5e7` | expected flags = **10,000** exactly |

If the conclusion survives on B, it is architectural rather than a cardinality artefact.

### Results — `balanced` (20M rows, 4.9% distinct, fused by policy)

| threads | FPGA op (ms) | CPU op (ms) | ratio | F decode (ms) | F passes (ms) | FPGA cpu-s | CPU cpu-s | offload | flags |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| 1 | 54.8 | 745.4 | **13.61×** | 33.9 | 12.8 | 0.053 | 0.631 | 11.90× | ok |
| 2 | 54.9 | 385.1 | 7.01× | 34.1 | 12.8 | 0.075 | 0.619 | 8.24× | ok |
| 4 | 53.3 | 244.4 | 4.59× | 33.6 | 12.8 | 0.068 | 0.647 | 9.45× | ok |
| 8 | 53.9 | 190.9 | 3.54× | 34.2 | 12.8 | 0.077 | 0.686 | 8.86× | ok |
| 16 | 54.4 | 157.3 | 2.89× | 34.4 | 12.8 | 0.083 | 0.758 | 9.12× | ok |
| 32 | 53.8 | 129.5 | **2.41×** | 33.8 | 12.8 | 0.105 | 1.133 | 10.82× | ok |

`csv: bench/thread_sweep_balanced.csv` · all points `pass1=fused`

### Results — `knee` (10M rows, 1.1% distinct, fused by policy)

| threads | FPGA op (ms) | CPU op (ms) | ratio | F decode (ms) | F passes (ms) | FPGA cpu-s | CPU cpu-s | offload | flags |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| 1 | 32.4 | 272.6 | **8.42×** | 17.9 | 6.5 | 0.031 | 0.230 | 7.37× | ok |
| 2 | 31.0 | 149.7 | 4.82× | 17.7 | 6.5 | 0.034 | 0.236 | 6.93× | ok |
| 4 | 30.7 | 129.9 | 4.23× | 17.3 | 6.5 | 0.039 | 0.257 | 6.55× | ok |
| 8 | 31.0 | 79.3 | 2.56× | 17.6 | 6.5 | 0.049 | 0.279 | 5.65× | ok |
| 16 | 30.7 | 61.6 | 2.01× | 17.4 | 6.5 | 0.041 | 0.337 | 8.23× | ok |
| 32 | 31.5 | 49.1 | **1.56×** | 17.7 | 6.5 | 0.059 | 0.510 | 8.70× | ok |

`csv: bench/thread_sweep_knee.csv` · all points `pass1=fused`

⚠️ Do not compare the two tables' absolute times: different row counts and different bytes/row.

---

## Analysis (Test 3)

### 1. BOTH FPGA phases are flat in host core count — including decode

| quantity | balanced 1→32 | knee 1→32 |
|---|--:|--:|
| FPGA `passes` (the IQR operator) | **1.00×** (spread 0.1%) | **1.00×** (spread 0.5%) |
| FPGA `decode` (parquet decode) | **1.00×** | 1.01× |
| FPGA operator total | 1.02× (spread 3.0%) | 1.03× (spread 5.5%) |
| CPU operator total | **5.76×** | 5.55× |

**A correction worth recording:** the harness was originally written expecting `decode` to *scale*, on
the assumption it was host work. It is not. `DecodeColumnAllGroups` (`oasis_iqr.cpp:1096`) submits row
groups to the **FPGA's** parquet decoders and streams decoded beats back; the host only orchestrates
fetch/submit/copy. So the flatness covers the whole pipeline, not just the statistics operator.

> ⚠️ **WHAT THE TWO PHASE TIMERS ACTUALLY SPAN (corrected 2026-08-09).** In the fused configuration
> `decode` is the decode window **with pass 1 (the histogram) hidden underneath it**, and `passes`
> times **pass 2 only** — the classify re-stream plus flag drain. `iqr_runner.cpp:509` states it:
> *"Only pass 2 is timed here: pass 1 was overlapped with decode and is accounted to the decode
> phase"*, and the design intent is `heavy = max(decode, pass1) + pass2` (`iqr_runner.hpp:115`).
> So **do not read the `passes` band as "the statistics"** — it is a transport-bound data pass, and
> the arithmetic confirms it: 20M rows × 8 B = 160 MB at the separately measured 12.49 GB/s effective
> PCIe rate is **12.81 ms**, which is the 12.8 ms measured. The statistics themselves are inside the
> decode band and are **not** separately measured; `--no-fuse` (where `decode` is pure decode and
> `passes` covers both passes) is how to separate them. The spans are disjoint on one `steady_clock`
> and sum correctly: 33.8 + 12.8 = 46.6 vs `heavy` 53.8, leaving 7.2 ms of window + staging + copy.

This matters because the decode window is the **dominant** phase: 33.9 of 54.8 ms = **62%** of the
operator (knee: 17.9 of 31.5 = 57%), with pass 2 at 23%. The remaining ~8.0 ms is identical on both datasets
(54.8−46.7 and 32.4−24.4) — window derivation, staging and copy-out, i.e. part of the byte-independent
floor Test 2 already identified. **The largest component of FPGA operator time is device work.**

`passes` flatness is the sweep's **internal check**, not a result: identical file, bytes and encoding at
every point means the FPGA has identical work to do. Had it moved, the measurement would have been
contaminated by DMA starvation at low thread counts — a real effect, but a different one, and it must
not be folded into a core-count-independence claim. At 0.1% / 0.5% it is clean.

### 2. The CPU baseline cannot reach the FPGA at ANY core count

Least-squares Amdahl fit `T(n) = S + P/n` over all six points:

| | balanced | knee |
|---|---|---|
| fit | `103.9 ms + 624.3/n` | `51.3 ms + 220.8/n` |
| serial fraction | 14.3% | 18.8% |
| serial floor S (n→∞) | **103.9 ms** | **51.3 ms** |
| FPGA at **one** core | 54.8 ms | 32.4 ms |
| S / FPGA@1core | **1.90×** | **1.58×** |
| parallel efficiency at 32 | **18.0%** | 17.3% |

**Lead with the measured statement, not the extrapolation:** the CPU baseline on **32 cores**
(129.5 ms) is still **2.36× slower than the FPGA on one core** (54.8 ms); on the control, 1.52×. That
needs no model. The fit is then the supporting argument for *why more cores would not close it* — the
serial floor alone is 1.9× the FPGA's one-core time.

Treat the asymptote as an extrapolation from six points: residuals reach 8% at low n (fit 728 vs
measured 745 at n=1, 416 vs 385 at n=2, 260 vs 244 at n=4), so quote S as "≈100 ms" rather than to
0.1 ms. The measured 32-core point is already only 1.25× above the fitted floor, so the shape is not in
doubt even if S is.

Parallel efficiency collapsing from 96.8% at n=2 to **18.0%** at n=32 is the mechanism: the baseline
buys wall-clock with cores at a rapidly worsening exchange rate, while the FPGA path needs none.

### 3. Host CPU actually consumed — the offload claim, quantified honestly

`cpu-s / wall` = how many cores were genuinely busy:

| | FPGA path | CPU baseline |
|---|--:|--:|
| CPU-seconds @1 thread | 0.053 | 0.631 |
| CPU-seconds @32 threads | 0.105 | 1.133 |
| cores busy @1 thread | 0.97 | 0.85 |
| cores busy @32 threads | **1.95** | **8.75** |
| best-case offload (CPU-s) | — | **11.7×** |
| offload at 32 cores | — | **10.8×** |

**The FPGA path is not free** — it costs about one core of orchestration at 1 thread and two at 32. Say
it that way: "**10.8× fewer CPU-seconds and 4.5× fewer busy cores**" is both overwhelming and
defensible, whereas "zero host CPU" is false and a reviewer would catch it.

Note the CPU baseline's *own* CPU-seconds rise 0.619 → 1.133 as threads go 2 → 32 while wall time falls
385 → 129 ms. It is buying 3.0× wall-clock with 1.8× the CPU.

### 4. Giving the offloaded path more cores is close to pure waste

The FPGA arm's CPU-seconds **double** from 1 → 32 threads (0.053 → 0.105 on balanced; 0.031 → 0.059 on
knee) for a **1.8%** wall-clock gain (54.8 → 53.8 ms; knee 2.8%). At `threads=1` the FPGA path runs
within 2% of full speed while leaving **31 of 32 cores free**.

That is the regime where the offload argument actually pays — concurrent queries, multi-tenant hosts —
and it is an actionable configuration finding, not just a measurement: **the operator should cap the
DuckDB thread count it requests.** Not implemented.

### 5. The control confirms it is architectural, not cardinality

The `knee` set — Test 2's least flattering cardinality — reproduces every shape: FPGA flat (1.03×), CPU
scaling 5.55×, efficiency 17.3%, serial floor above the FPGA's one-core time, offload 6.6–8.7×. Only
the magnitude shrinks (headline 1.52× instead of 2.36×). So Test 3's conclusion is a property of the
architecture, and Test 2's cardinality axis multiplies it rather than causing it.

### 6. Cross-session consistency, and a soak result

The `threads=32` point reproduces **Test 1's independent 20M fused measurement**: FPGA 53.8 vs 53.4 ms
(0.7%), CPU 129.5 vs 124.0 ms (4.4%). So the protocol reproduces across sessions, and pinning to 32
physical cores is equivalent to Test 1's unpinned 32 threads on this host.

Correctness held at **12 points × 7 iterations = 84 further clean runs**, all returning the exact
expected flag count — continued soak evidence on a bitstream with **1 ps** of hold margin (`WHS
+0.001`), whose historical failure signature was *wandering* counts across runs.

## Consequences / open items (Test 3)

1. **This is the paper's offload panel.** One table carries both halves of the thesis: the FPGA
   pipeline is core-count-indifferent (decode *and* statistics), and the software baseline cannot reach
   it with any number of cores. It is also the natural **joint** panel with the z-score operator — the
   claim is about the architecture, so two operators supporting the same curve is the argument.
2. **Quote conservative numbers.** 2.36× (FPGA@1core vs CPU@32cores), 10.8× CPU-seconds, ~2 busy cores
   vs ~8.75. Avoid "zero CPU" and avoid the 13.61× ratio at n=1 — the latter compares against a
   single-threaded baseline nobody would deploy.
3. **Thread-cap the operator** (§4). Measured: 1 thread costs 1.8% wall and saves half the CPU-seconds.
4. **One wobble to re-run:** `knee` at `threads=4` (129.9 ms) sits ~22% above its fit, between 149.7 at
   n=2 and 79.3 at n=8. Almost certainly a scheduling artefact; it moves no conclusion, but a re-run
   would settle it.
5. **The topology guard is untested in anger.** alveo-u55c-01 has 1 NUMA node, so `pick_cpus`
   degenerated to `0..N-1` and `fpga_numa_node()` returned unknown (no matching `10ee:` device found
   via lspci). On a multi-socket run node this path decides whether small-N points are meaningful.
6. **`--no-taskset` was not run.** Comparing it against these numbers would quantify how much FPGA-arm
   host cost sits outside DuckDB's scheduler (the three `hardware_concurrency` regions).
7. **Test 4 is still the unexplained residual** — distribution shape and/or ragged row groups. Nothing
   in Test 3 touches it.

## Reproduce (Test 3)

No data generation: both datasets already exist from Tests 1 and 2.

```bash
cd ~/oasis
python3 bench/thread_sweep.py --csv bench/thread_sweep_balanced.csv   # primary
python3 bench/thread_sweep.py --dataset knee --csv bench/thread_sweep_knee.csv
python3 bench/thread_sweep.py --no-taskset                            # pragma-only control (open item 6)
python3 bench/thread_sweep.py --no-fuse                                # value path, 2 PCIe passes
```

The harness prints its own core plan, the `passes`-flatness internal check, the Amdahl-free
iso-performance verdict and the Test 1 cross-check, so a run is self-documenting. `--timeout` is
SIGTERM-first with a 60 s grace before any SIGKILL: a 1-thread fused FPGA run had never been exercised
before this test, and SIGKILLing a process holding pinned pages mid-DMA is the path to a node reboot.

⚠️ **Bitstream provenance: same caveat as Test 2** (see above) — presumed
`build-29/bitstreams/cyt_top_b29_po.bit` (WNS −0.518), not confirmed by the sysfs check. Correctness
stands either way; only timing attribution would change.

---

## Test 4 — COMPRESSION & ENCODING SENSITIVITY (one column, eight on-disk representations)

**This is the paper's third panel.** Tests 1 and 3 vary the workload (rows, host cores). This one
varies nothing about the data at all — it writes the *same 20 million numbers* eight different ways
and measures what the packaging costs.

Run on **alveo-u55c-07, 2026-08-09**, fused by policy, `threads=32`. Correctness `ok` at all 8 points.

### Why this axis, and why it is the one that transfers to z-score

Test 3 measured the split: **decode is 62% of FPGA operator time, the IQR statistics only 23%.** The
decoder is not part of either operator — it is the substrate both sit behind. So characterising it
produces one result that belongs to IQR and z-score equally, whereas Tests 1 and 2 have to be re-run
per operator. That is also why Test 2 was withdrawn: cardinality is IQR-only (see its banner above).

### The design problem: encoding and byte volume are normally collinear

A naive 2×2 (PLAIN/dictionary × raw/Snappy) **cannot** separate *"dictionary decoding costs more per
element"* from *"dictionary moved fewer bytes"*, because at ordinary cardinalities dictionary always
means fewer bytes. The sweep is therefore replicated at two cardinality levels chosen so the
**dictionary's byte effect changes sign**:

| level | cardinality | PLAIN | dictionary | dictionary's effect |
|---|--:|--:|--:|---|
| `lo` | 10,000 | 8.00 B/row | **2.55** | **shrinks** the file 3.1× |
| `hi` | 1,000,000 | 8.00 B/row | **11.79** | **grows** the file 1.47× |

Cardinality is *not* an axis under test here; it is the lever that de-collinearises the design. The
fit `t = f0 + a·(B/row) + b·[snappy] + c·[dict] + d·[hi]` was verified identifiable before the run:
on synthetic data it recovers planted coefficients exactly, and `codec_sweep.fit()` **returns `None`
rather than a confident wrong answer** if only one level is present.

### Hardware envelope — what could NOT be tested, because it cannot be decoded

| layer | supported | source |
|---|---|---|
| compression | **RAW, SNAPPY only** — no ZSTD/GZIP/LZ4/Brotli | `parcore/software/parcore/configuration.cpp:23` |
| encoding | **PLAIN, PLAIN_DICTIONARY, RLE_DICTIONARY only**; DataPage **V2 unsupported** | `parcore/hardware/src/hdl/page_header_parser.sv:194,238` |
| dictionary size | `ID_BITS=19` → ≤524,288 entries / ~2 MiB per **row group** | `parcore/hardware/src/hdl/common.sv:15-31` |

So `DELTA_BINARY_PACKED` and `BYTE_STREAM_SPLIT` — what modern writers pick for ints and floats — are
out of scope, as is any ZSTD file. **RLE/bit-packing is deliberately not an arm**: it is not a
standalone data-page encoding on this path, only the index encoding *inside* a dictionary page.
At `ROW_GROUP_SIZE=122880` a group holds ≤122,880 distinct values (~1 MB), inside the hardware bound
by ~2× — raising the row-group size would break it.

### Dataset design

Generator: `bench/gen_codec_sweep.sh` → `~/datasets/codecsweep/codec_<level>_<enc>_<comp>.parquet`

```sql
COPY (SELECT (((hash(i) % CARD) * 2654435761) % 10000000)::BIGINT
             + CASE WHEN i % 1000 = 0 THEN 50000000 ELSE 0 END AS v
      FROM range(20000000) t(i))
TO '<file>' (FORMAT PARQUET, ROW_GROUP_SIZE 122880,
             DICTIONARY_SIZE_LIMIT {0 | 104857600}, COMPRESSION {UNCOMPRESSED | SNAPPY});
```

`DICTIONARY_SIZE_LIMIT` is the only lever DuckDB exposes over encoding: `0` forces PLAIN; 100 MiB
forces the writer to keep building a dictionary instead of giving up at its ~128 KB default.

| property | value | why |
|---|---|---|
| rows | **20,000,000 FIXED** | matches Test 3's `balanced` point, so the two tests cross-check |
| value range | `[0, 10^7)` FIXED | Q1≈2.5e6, Q3≈7.5e6, fence_hi≈1.5e7 identical everywhere |
| level placement | multiplicative permutation, `gcd(2654435761, 10^7)=1` | bijection; low bits fully spread, so the C++ baseline's radix aggregation is not imbalanced |
| outliers | 0.1% at `+5e7` | lands in `[5e7,6e7)`, far above fence_hi with **nothing between** ⇒ expected flags = **20,000** exactly, quantisation-proof |
| row groups | 122880 → 163 groups, min 93,440 | multiple of 8, or the ragged guard rejects streaming; also keeps the per-group dictionary inside the hardware bound |

### Generated datasets — ALL GATES PASS

| level | card | enc intent | compression | MB | B/row | encodings | groups | min_grp %8 |
|---|--:|---|---|--:|--:|---|--:|--:|
| lo | 10,000 | plain | uncompressed | 160.0 | 8.00 | PLAIN | 163 | 0 |
| lo | 10,000 | plain | snappy | 94.3 | 4.71 | PLAIN | 163 | 0 |
| lo | 10,000 | dict | uncompressed | 51.0 | 2.55 | PLAIN_DICTIONARY | 163 | 0 |
| lo | 10,000 | dict | snappy | 46.4 | 2.32 | PLAIN_DICTIONARY | 163 | 0 |
| hi | 1,000,000 | plain | uncompressed | 160.0 | 8.00 | PLAIN | 163 | 0 |
| hi | 1,000,000 | plain | snappy | 104.1 | 5.21 | PLAIN | 163 | 0 |
| hi | 1,000,000 | dict | uncompressed | **235.8** | **11.79** | PLAIN_DICTIONARY | 163 | 0 |
| hi | 1,000,000 | dict | snappy | 183.3 | 9.16 | PLAIN_DICTIONARY | 163 | 0 |

**The decisive gate — the four files at each level hold the SAME numbers.** An order-independent
digest is computed per file and must match within a level; if it does not, `passes` is not a control
and the generator refuses to bless the run:

| level | rows | `sum(v)` | `sum(hash(v))` | distinct~ |
|---|--:|--:|--:|--:|
| lo | 20,000,000 | 101,039,274,359,468 | 185925587955402077534121838 | 18,491 |
| hi | 20,000,000 | 100,996,377,679,468 | 184267033378404533681901067 | 1,016,996 |

Identical across all four files at each level ✅. Encoding intent honoured on all 8 ✅.
`min_group % 8 == 0` on all 8 ✅. Total on disk **1.04 GB**.

(`distinct~` exceeds `card` because the outlier rows contribute their own levels; it falls short of
1e6 at `hi` by coupon-collector coverage.)

### Results

| level | card | enc | compression | B/row | FPGA op (ms) | CPU op (ms) | **speedup** | F decode | **F passes** | dec GB/s | flags |
|---|--:|---|---|--:|--:|--:|--:|--:|--:|--:|:--|
| lo | 10,000 | plain | uncompressed | 8.00 | 55.6 | 62.1 | **1.12×** | 35.3 | 12.8 | 4.53 | ok |
| lo | 10,000 | plain | snappy | 4.71 | 51.4 | 72.1 | **1.40×** | 31.6 | 12.8 | 5.06 | ok |
| lo | 10,000 | dict | uncompressed | 2.55 | 31.9 | 64.5 | **2.02×** | 14.2 | 12.8 | 11.24 | ok |
| lo | 10,000 | dict | snappy | 2.32 | 31.6 | 67.8 | **2.14×** | 14.0 | 12.8 | 11.46 | ok |
| hi | 1,000,000 | plain | uncompressed | 8.00 | 55.4 | 116.5 | **2.10×** | 35.4 | 12.8 | 4.52 | ok |
| hi | 1,000,000 | plain | snappy | 5.21 | 53.3 | 125.7 | **2.36×** | 32.7 | 12.8 | 4.89 | ok |
| hi | 1,000,000 | dict | uncompressed | 11.79 | 53.0 | 131.1 | **2.47×** | 32.7 | 12.8 | 4.90 | ok |
| hi | 1,000,000 | dict | snappy | 9.16 | 57.4 | 133.6 | **2.33×** | 37.0 | 12.8 | 4.32 | ok |

`csv: bench/codec_sweep.csv` · all points `pass1=fused` · flags = 20,000 on all 7 iterations of all 8

---

## Analysis (Test 4)

### 1. The control held perfectly — the statistics stage is representation-invariant

**`F passes` = 12.8 ms at every one of the eight points** (spread 0.2% at `lo`, 0.3% at `hi`), while
`F decode` moves 14.0 → 37.0 ms, a factor of 2.6. Since the values are provably identical within a
level, this is not an interpretation — it is a measurement with a built-in control:

> **All variation in FPGA operator time is in the decode window. Pass 2 does not move.**

⚠️ `passes` is **pass 2 only**, not the statistics — see the corrected timer note in Test 3's §1. It
is transport-bound (160 MB of decoded column at 12.49 GB/s = 12.81 ms predicted, 12.8 measured), which
is *why* an identical decoded volume forces it constant. The histogram itself rides inside the decode
window by design, so this sweep bounds the statistics' representation-sensitivity only indirectly.

No other sweep in this document can make that statement, because Tests 1–3 all change the values.

### 2. Compression widens the gap, and BOTH arms contribute

At fixed encoding, switching Snappy on:

| | FPGA | CPU | speedup |
|---|--:|--:|--:|
| lo, PLAIN | 55.6 → 51.4 (**−7.6%**) | 62.1 → 72.1 (**+16.1%**) | 1.12× → **1.40×** |
| hi, PLAIN | 55.4 → 53.3 (**−3.8%**) | 116.5 → 125.7 (**+7.9%**) | 2.10× → **2.36×** |
| lo, dict | 31.9 → 31.6 (−0.9%) | 64.5 → 67.8 (+5.1%) | 2.02× → 2.14× |
| hi, dict | 53.0 → 57.4 (+8.3%) | 131.1 → 133.6 (+1.9%) | 2.47× → 2.33× |

On PLAIN data the arms move in **opposite directions** — the FPGA fetches fewer bytes, the host pays
decompression. That is the mechanism, measured on both halves rather than assumed. Note the size of
the CPU's decompression cost is **~9 ms**, not the ~24 ms the first (mis-specified) fit reported; see
§5. On dictionary data the effect is small and mixed, because the dictionary already removed the
redundancy Snappy would have exploited.

### 3. Dictionary is the larger effect — and it wins even when it makes the file BIGGER

At fixed compression:

| | B/row | FPGA | CPU | speedup |
|---|--:|--:|--:|--:|
| lo, uncompressed | 8.00 → 2.55 | **−42.6%** | +3.9% | 1.12× → **2.02×** |
| lo, snappy | 4.71 → 2.32 | −38.5% | −6.0% | 1.40× → 2.15× |
| hi, uncompressed | 8.00 → **11.79** | −4.3% | **+12.5%** | 2.10× → **2.47×** |
| hi, snappy | 5.21 → 9.16 | +7.7% | +6.3% | 2.36× → 2.33× |

The `hi`/uncompressed row is the one to quote. The dictionary makes the file **47% larger**, and the
FPGA *still* got 4.3% faster while the CPU got 12.5% slower. **Even a badly chosen encoding tilts the
comparison toward the FPGA.** This is the row the sign-flip design existed to produce, and it
contradicts the pre-registered prediction (recorded in `codec_sweep.py`) that dictionary would narrow
the gap.

### 4. Representation alone moves the headline by 2.2×

Same 20M numbers. **1.12× (PLAIN, uncompressed, low card) → 2.47× (dictionary, uncompressed, high
card).** Consequences:

* **Quote the worst case too.** 1.12× is the honest floor and belongs in the paper; it is the
  representation that gives the FPGA the least to work with.
* **A speedup figure without a stated encoding is not meaningful.** This is a methodology point in
  our favour, and it retroactively explains Test 1's residual — the size model over-predicted every
  dictionary-encoded real dataset by 1.29–2.54× because encoding was never a term in it.
* Real Parquet is compressed and frequently dictionary-encoded, so the realistic operating points are
  the **upper** half of this range.

### 5. Two corrections to the harness's first output — both now fixed

**(a) The CPU fit was mis-specified.** It omitted a cardinality term, which for the CPU arm is the
dominant cost. The model absorbed a ~55 ms level difference into the byte slope:

| CPU model | rms | bytes | snappy |
|---|--:|--:|--:|
| as first printed (no level term) | **19.33 ms** | 8.01 | **24.15** |
| corrected (with level term) | **2.31 ms** | 1.28 | **9.12** |

The corrected +9.12 ms matches the direct paired measurements (+10.0 ms at `lo`, +9.2 ms at `hi`);
the original 24 ms did not. `codec_sweep.fit()` now always includes the term.

**(b) The dictionary coefficient is NOT a per-element price.** The model is linear in bytes/**row**,
but much of a dictionary file's volume is the dictionary **page**, read once per row group rather
than per row (~160 MB of the 236 MB at `hi`). The −10.38 ms coefficient is mis-specification, not a
measured speedup. The harness no longer prints a verdict on it; read the paired rows in §3 instead.

Corrected fits (all with the level term, n=8):

| | model | rms |
|---|---|--:|
| FPGA operator | `33.18 + 2.71·B/row + 5.50·[snappy] − 10.38·[dict] + 0.94·[hi]` | 2.03 |
| FPGA decode | `15.34 + 2.42·B/row + 4.83·[snappy] − 9.21·[dict] + 0.65·[hi]` | 1.88 |
| CPU operator | `53.84 + 1.28·B/row + 9.12·[snappy] + 5.18·[dict] + 54.78·[hi]` | 2.31 |

The `[hi]` coefficients say it plainly: **+0.94 ms for the FPGA, +54.78 ms for the CPU.** The FPGA is
cardinality-blind; the CPU is not.

### 6. The decoder is not a bytes-per-second pipe

`corr(decode, MB) = +0.78`, and wire throughput spans **2.98 → 7.21 GB/s**:

| MB | decode (ms) | wire GB/s |
|--:|--:|--:|
| 46.4 | 14.0 | 3.31 |
| 51.0 | 14.2 | 3.59 |
| 94.3 | 31.6 | 2.98 |
| 104.1 | 32.7 | 3.18 |
| 160.0 | 35.3 | 4.53 |
| 160.0 | 35.4 | 4.52 |
| 183.3 | 37.0 | 4.95 |
| **235.8** | **32.7** | **7.21** |

The largest file decodes *faster* than a 160 MB PLAIN one. Dictionary-page bytes stream more cheaply
than per-element PLAIN data — they are read once per group as a contiguous array, whereas PLAIN pays
per element. Mechanism plausible but not isolated; do not claim it as measured.

### 7. Cross-node and cross-test consistency

Tests 1–3 ran on **alveo-u55c-01**; Test 4 on **alveo-u55c-07**. Two near-identical files let the
nodes be compared: Test 3's `balanced` (20M rows, 979,812 distinct, Snappy/PLAIN, 4.94 B/row) vs Test
4's `hi`/plain/snappy (20M rows, 1,016,996 distinct, Snappy/PLAIN, 5.21 B/row):

| | Test 3 @u55c-01 | Test 4 @u55c-07 | Δ |
|---|--:|--:|--:|
| FPGA op | 53.8 ms | 53.3 ms | **0.9%** |
| CPU op | 129.5 ms | 125.7 ms | 3.0% |

Within run-to-run noise, so the two nodes are interchangeable for these measurements and results from
the two sessions may be compared.

## Consequences / open items (Test 4)

1. **This is the paper's third panel**, alongside Test 1 (size) and Test 3 (host cores). All three
   characterise behaviour shared by both operators; Test 2 was withdrawn for being IQR-specific.
2. **The headline framing** is *"the statistics module is invariant to representation; the shared
   decoder is where the time goes and where the advantage grows."* Both compression and dictionary
   widen the gap, for different reasons, and dictionary wins even when it enlarges the file.
3. **State the encoding with every speedup number** — 1.12×→2.47× on identical data makes this
   non-negotiable, and it is a methodology point in our favour.
4. **The envelope is a first-class result, not a caveat.** No ZSTD, no DataPage V2, no
   DELTA_BINARY_PACKED — worth stating up front rather than having a reviewer find it. It applies
   identically to the z-score operator.
5. **Not measured: what happens on unsupported input.** Whether a ZSTD or V2-page file is cleanly
   rejected, silently falls back to CPU decode, or errors. That is the first question a reviewer asks
   about a decode-offload claim, and it is one short experiment.
6. **Bitstream provenance still UNCONFIRMED** — presumed `build-29/bitstreams/cyt_top_b29_po.bit`
   (WNS −0.518) on a card programmed 2026-08-09, but the sysfs check was not captured. Correctness
   stands regardless; only timing attribution would change.

## Reproduce (Test 4)

```bash
cd ~/oasis
bash bench/gen_codec_sweep.sh              # 8 files, ~1.04 GB; STOP if the digest gate fails
bash bench/gen_codec_sweep.sh verify       # re-print manifest + gates only
python3 bench/codec_sweep.py --csv bench/codec_sweep.csv
```

The harness prints the `passes`-flatness internal check per level and refuses to report a fit if only
one cardinality level is present (the design would be rank-deficient). `FORCE=1` regenerates existing
files; partial writes land as `*.partial` and are never mistaken for complete ones.

---

## Test 5 — DISTRIBUTION SHAPE / SKEW (20M rows fixed, skewness 0.00 → 3.44)

> ✅ **This is a ROBUSTNESS CONTROL, not a paper panel.** Both arms are flat, so there is no curve to
> plot. Its job is to defend Tests 1/3/4, all of which ran on uniform data. Report it as prose plus
> the small table in §5 below.

**Date:** 2026-08-14 · **Node:** alveo-u55c-07 · **Harness:** `bench/gen_skew_sweep.py`,
`bench/skew_sweep.py` · **Raw:** `bench/skew_sweep.csv` (run 1), `bench/skew_sweep_rep2.csv` (run 2)

Same protocol as Tests 1/3/4 — **7 runs in one DuckDB session, arithmetic mean of the last 3, no
median, no spread** — reused verbatim from `size_sweep.run_arm`. Fused by policy (20M > the 6M
crossover), `threads=32`, CPU arm `iqr_cpu_flags_groupby()`. The card was programmed with
`build-29/bitstreams/cyt_top_b29_po.bit` at the start of this session; the sysfs provenance line was
not captured in the pasted log, so treat provenance as presumed rather than confirmed.

### What varies, and what had to be pinned to let it vary alone

The axis is the **shape of the value distribution**: Fisher skewness 0.00 → 3.44, excess kurtosis
−1.2 → 12.7. Everything else is held fixed by construction:

| property | value | how |
|---|---|---|
| rows | 20,000,000 | same `i`-range at every point |
| cardinality | **1,020,000 distinct EXACTLY** | `r = (i·PERM) mod N` is a bijection; folding `mod CARD` gives every level exactly `N/CARD = 20` rows. Not `hash()` — hash leaves coupon-collector holes and the distinct count would drift with the sweep |
| frequency profile | perfectly flat over levels | consequence of the above ⇒ the skew lives entirely in the value **spacing**, i.e. this is a genuine sample from a continuous right-skewed law quantised to CARD levels, not a frequency-imbalance artefact |
| bytes/row | **exactly 8.00** | PLAIN (`DICTIONARY_SIZE_LIMIT 0`) + UNCOMPRESSED. All six files are byte-identical in size (160,021,337 B), which is itself the proof |
| row groups | 163, min 93,440, all `%8 == 0` | streaming/fusion is never rejected |
| **bins per IQR** | **~579 at every point** | ⬅️ the new one — see below |

Value construction: `V(level) = level + round(9e6 · w(u))`, `u = (level+1)/CARD`, with
`w(u) = u` at `a=0` and `w(u) = (e^{a·u} − 1)/(e^a − 1)` otherwise. The `+ level` term is what makes
`V` strictly increasing and therefore injective, so cardinality survives the warp. `a` is the knob;
**measured skewness is the reported axis**.

### ⚠️ Two confounds this generator exists to kill

**1. The power-of-two bin width.** `derive_window` (`iqr_runner.cpp:107`) sets the histogram window to
`[Q1−2·IQR, Q3+2·IQR]` — exactly **5·IQR** — then rounds the bin width **up to a power of two**
(`iqr_runner.cpp:130`, because the hardware shifts rather than divides). Writing `x = 5·IQR/4096`:

```
bins_per_IQR = (4096/5) · x / 2^ceil(log2 x)        and  x / 2^ceil(log2 x) ∈ (0.5, 1]
             ⇒ sawtooths over (409.6, 819.2]
```

Skew moves the IQR continuously, so a naive sweep walks straight through those octave boundaries and
produces a **2× accuracy sawtooth that has nothing to do with distribution shape**. Every point is
therefore scaled by an integer multiplier chosen so `bins_per_IQR` lands on **579 ± 0.4%** — the
*geometric middle* of the range, deliberately **not** the top: at 819.2 the quantity `5·IQR/4096` is
exactly a power of two, so half of all perturbations tip it into the next octave and halve the
resolution. That matters precisely because the fused window comes from a stride sample whose Q3 error
**grows with skew** — the swept axis is what would push a cliff-edge point over.

**2. Outlier placement collapsing onto whole levels.** `N = 20,000,000 = 1000 × 20,000`, so selecting
outliers with `i % 1000 == 0` makes `(i·PERM) mod N` a multiple of 1000, and folding `mod CARD` leaves
**only multiples of 1000** — 1,000 whole levels (all 20 rows each), which then vanish from the base.
The distinct count still read a plausible 1,000,000 (999,000 base + 1,000 outlier), which is how it
nearly passed. Same low-bit-structure trap as the Test 2 v1 generator. Fixed by selecting on the
permuted index instead: `r % 50 == 0 AND r < CARD` takes **one row from each of 20,000 levels** spaced
50 apart, so the base keeps all 1,000,000 levels and the file holds exactly 1,020,000 distinct values.

### Generated datasets — ALL GATES PASS

| a | skewness | kurtosis | mult | bins/IQR | B/row | distinct | min_grp %8 | natural outliers | expected flags | gate |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| 0 | 0.000 | −1.200 | 1943 | 579.6 | 8.00 | 1,020,000 | 0 | 0 | 20,000 | EXACT |
| 4 | 1.144 | 0.283 | 2843 | 580.6 | 8.00 | 1,020,000 | 0 | 497,902 | 517,902 | MIXED |
| 8 | 1.965 | 3.213 | 179 | 581.7 | 8.00 | 1,020,000 | 0 | 2,258,000 | 2,278,000 | MIXED |
| 12 | 2.566 | 6.392 | 641 | 581.7 | 8.00 | 1,020,000 | 0 | 2,711,586 | 2,731,586 | MIXED |
| 16 | 3.044 | 9.569 | 3653 | 581.2 | 8.00 | 1,020,000 | 0 | 2,679,758 | 2,699,758 | MIXED |
| 20 | 3.445 | 12.693 | 1083 | 580.5 | 8.00 | 1,020,000 | 0 | 2,446,052 | 2,466,052 | MIXED |

`a=0` reports skewness 0.0 and excess kurtosis **−1.2**, the exact theoretical value for a uniform
distribution — a free confirmation that the construction is what it claims to be. Total disk 740 MB.

**Only the uniform point keeps a purely analytic gate.** Any right-skewed distribution has mass beyond
`Q3 + 1.5·IQR` — that is a property of IQR on heavy tails, not a flaw. For the `MIXED` points the
generator computes the expected count **from the written file using the SQL baseline's own
discrete-quantile rule** (`min v such that 4·cumcount ≥ total`), so the harness gate is three-way:
FPGA vs CPU vs expected. A CPU deviation would be a *definition* mismatch; an FPGA-only deviation is
*quantisation*. The CPU column read `+0` at all 6 points in both runs, so the FPGA column is
attributable.

### Results — two independent runs, same node, same session state

| | | run 1 | | | run 2 | | | pooled | |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| **skew** | **FPGA** | **CPU** | **ratio** | **FPGA** | **CPU** | **ratio** | **FPGA** | **CPU** | **ratio** |
| 0.00 | 55.7 | 117.7 | 2.11× | 53.4 | 118.2 | 2.21× | 54.55 | 117.95 | 2.16× |
| 1.14 | 55.0 | 119.7 | 2.18× | 55.3 | 123.0 | 2.22× | 55.15 | 121.35 | 2.20× |
| 1.96 | 56.5 | 125.1 | 2.21× | 55.5 | 116.3 | 2.10× | 56.00 | 120.70 | 2.16× |
| 2.57 | 57.6 | 119.4 | 2.07× | 53.8 | 115.0 | 2.14× | 55.70 | 117.20 | 2.10× |
| 3.04 | 56.4 | 117.2 | 2.08× | 54.2 | 121.9 | 2.25× | 55.30 | 119.55 | 2.16× |
| 3.44 | 55.2 | 120.4 | 2.18× | 55.9 | 125.7 | 2.25× | 55.55 | 123.05 | 2.22× |

`F passes` was **12.8 ms at all 12 measurements** (spread 0.3% / 0.2%) — the internal check.
`F decode` pooled 34.85 → 36.70 ms.

---

## Analysis (Test 5)

### 1. One run could not have established this — the repeat is the result

Within a single run the FPGA spread across skewness is 4.7–4.8%, which is *above* this project's
documented 1–3% run-to-run variation. On one run alone, "flat" would have been an eyeball claim.

The repeat settles it, because **the same-point repeat difference is LARGER than the across-skew
spread**:

| | max repeat |Δ| on one point | across-skew spread within a run |
|---|--:|--:|
| FPGA op | **6.6%** (a=12: 57.6 → 53.8) | 4.7–4.8% |
| CPU op | **7.0%** (a=8: 125.1 → 116.3) | 6.7–9.3% |

And the **rank order completely reshuffled**: `a=12` was the slowest point in run 1 and the
second-fastest in run 2; `a=8` was the slowest CPU point in run 1 and the fastest in run 2. A real
effect does not permute its own ordering between sessions.

Pooling the two runs halves the residual: FPGA spread **2.66%**, i.e. back inside the documented
noise band. Least-squares against skewness gives a slope of **0.26 ms per unit skewness = 0.91 ms
(1.6%) over the entire range** — far below the ±3.8 ms observed on a single repeated point, and not
monotone (the pooled series rises then falls). There is no trend to report.

### 2. The measured statement

> Over Fisher skewness **0.00 → 3.44** and excess kurtosis **−1.2 → 12.7**, with rows, cardinality,
> frequency profile, encoding, byte volume, row-group geometry and quantisation resolution all held
> fixed, FPGA operator time varies by **2.7%** and the speedup stays in **2.10–2.22×** (mean 2.17×).

Both arms are flat, and for different reasons worth stating: the FPGA histograms every row identically
regardless of where the values sit, while the CPU's `GROUP BY` performs N probes over a
fixed-size table regardless of value spacing. Once bytes and cardinality are pinned, **neither arm has
a mechanism for shape to act on.** That is why this is a control and not a panel.

### 3. Accuracy is deterministic — which is a stronger result than "small"

The FPGA's deviation from exact was **bit-identical across the two independent sessions**:

| skewness | expected | FPGA − expected | of flagged | of all rows |
|--:|--:|--:|--:|--:|
| 0.00 | 20,000 | **0** | exact | exact |
| 1.14 | 517,902 | −1,898 | 0.367% | 0.009% |
| 1.96 | 2,278,000 | +3,657 | 0.161% | **0.018%** |
| 2.57 | 2,731,586 | −280 | 0.010% | 0.001% |
| 3.04 | 2,699,758 | +520 | 0.019% | 0.003% |
| 3.44 | 2,466,052 | +2,038 | 0.083% | 0.010% |

Three things follow:

* **It does not grow with skew** — non-monotone, and the largest error is at the *second-lowest*
  skewness. Confirms the pre-registered prediction: the window is IQR-anchored, so resolution per IQR
  is scale-free, and a heavier tail puts *lower* density at the fence.
* **It is deterministic, not flaky.** Two sessions, 14 iterations per point, identical counts to the
  row. On a bitstream with **1 ps of hold margin** whose historical failure signature was *wandering*
  counts, reproducing the exact same numbers is direct evidence that these deviations are pure
  quantisation and the silicon is sound. `!FPGA-WANDERS` never fired.
* **The `a=0` point is exactly 0**, confirming the planted-outlier gate still works: outliers in an
  empty gap far outside the fence are quantisation-proof, as in Tests 1/3/4.

### 4. Cross-test consistency

`a=0` (20M rows, PLAIN, uncompressed, 8.00 B/row) is configuration-identical to Test 4's
`hi/plain/uncompressed`, measured on the same node in a different session:

| | Test 4 | Test 5 (pooled) | Δ |
|---|--:|--:|--:|
| FPGA op | 55.4 | 54.55 | 1.5% |
| CPU op | 116.5 | 117.95 | 1.2% |

### 5. What to put in the paper

Two sentences and, if space allows, this table:

| skewness | 0.00 | 1.14 | 1.96 | 2.57 | 3.04 | 3.44 |
|---|--:|--:|--:|--:|--:|--:|
| FPGA operator (ms) | 54.6 | 55.2 | 56.0 | 55.7 | 55.3 | 55.6 |
| speedup | 2.16× | 2.20× | 2.16× | 2.10× | 2.16× | 2.22× |

Lead with **invariance**, not correctness: *"the speedup is invariant to distribution shape, so the
uniform-data results of §Tests 1/3/4 transfer to skewed real-world columns."* Neutralise the accuracy
question in a single clause — *"flag counts agree with exact arithmetic to within 0.02% of rows at
every point"* — rather than giving it a subsection. Omitting it entirely would be worse: this is an
approximate-quantile design and a reviewer will ask.

## Consequences / open items (Test 5)

1. **Skew is not a performance axis.** With bytes and cardinality pinned there is no mechanism. Any
   real-world "skewed data behaves differently" effect must flow through **encoding/compression**
   (Test 4) or **cardinality** (Test 2), not through shape. This test is what licenses that claim.
2. **This transfers to the z-score operator unchanged as a control** — and the same datasets are
   valid for it, since the planted outliers sit far outside `mean ± kσ` for k ≥ 2 (see
   `microbench_roadmap.md` §2.2 for the arithmetic).
3. **The one skew figure with an actual trend is a JOINT one, and it is not about speed:** `mean ± kσ`
   is not robust, so under right-skew the mean and σ inflate and z-score's flag count drifts with the
   tail while quartile-based IQR does not. On identical data the two operators diverge as skewness
   grows. That is a *semantics* figure answering "why does this system offer both operators" — pure
   SQL over the six files already on disk, no card and no dependency on the companion codebase.
   **Not yet measured.**
4. **Not run:** `--no-fuse` (value path) and `--sample 65536` (which would separate window-sampling
   error from bin-quantisation error). Neither is needed for the invariance claim; both are one
   command if a reviewer pushes on the accuracy mechanism.

## Reproduce (Test 5)

```bash
cd ~/oasis
python3 bench/gen_skew_sweep.py --dry-run     # plan only: quartiles, multipliers, fences. No files.
python3 bench/gen_skew_sweep.py               # 6 files, 740 MB. STOP if any gate fails.
python3 bench/gen_skew_sweep.py verify        # re-print manifest + gates

python3 bench/skew_sweep.py --csv bench/skew_sweep.csv
python3 bench/skew_sweep.py --csv bench/skew_sweep_rep2.csv   # THE REPEAT -- required, see §1
```

⚠️ **Run it twice.** A single run cannot separate the 4.8% across-skew spread from 6.6% repeat noise,
and the invariance claim is exactly the claim that needs that separation.

Generation deliberately uses the **stock python `duckdb` module**, not the extension-linked binary:
it is pure SQL and never touches the FPGA, while the extension binary aborts on any node without
1 GiB huge pages. The module is 1.5.4, the same version the codec sweep was characterised against, so
the parquet writer — and therefore the encoding gates — behave identically.
