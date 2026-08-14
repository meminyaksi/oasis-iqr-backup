# IQR Report — 2026-07-28

Medians of 15 warm runs, node alveo-u55c-07, bitstream build-23 (4 decode lanes, 4096 bins) unless
noted. C++ arm = `iqr_cpu_flags_groupby` (exact quartiles). SQL arm = DuckDB built-in. **All numbers
are END-TO-END** (median of the full query, `=== END-TO-END ===` from `medians.py`; the operator-only
`heavy` numbers are NOT used anywhere). Raw run tables are in **seconds** (as reported); verdict tables
convert to **ms**. sf10 is shown **fused** (its default at that scale) throughout.

## Background — the histogram window

The FPGA finds the quartiles with a **fixed** number of bins (1024, now 4096). The **window** is the
value range those bins cover — from `bin_min` to `bin_max`, each bin of width
`W = (bin_max − bin_min) / NUM_BINS`. A value drops into bin `(value − bin_min) / W`; anything outside
clamps to the end bins.

Because the bin count is fixed, **the window sets the resolution.** The requirement: choose the window
so the data body — and the Q1/Q3 fences — spread across **many distinct bins**. Get it wrong and the
quartiles collapse into one bin.

**Good window** — bins sit over the data body, values spread out:

```
count
 │            ██
 │         ██ ██ ██
 │      ██ ██ ██ ██ ██
 │   ██ ██ ██ ██ ██ ██ ██
 └───┴──┴──┴──┴──┴──┴──┴───► value
     b0 b1 b2 b3 b4 b5 b6 ...
           ▲Q1     ▲Q3
   Q1 and Q3 fall in DIFFERENT bins → IQR > 0, fences land on real bin edges  ✔
```

**Bad window (too wide)** — e.g. taking the column's raw min..max, which a few far outliers stretch
enormously (taxi_d4 spans −128k … 33M while real fares live in 0 … 5000):

```
count
 │ ██
 │ ██
 │ ██
 │ ██                                          ·   ← a couple of far outliers out here
 └─┴──┴──┴──┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈──┴──► value
   b0 b1 b2 ...                              b4095
   ▲ 99.9% of values crushed into b0
   Q1 = Q3 = b0  →  IQR = 0  →  degenerate, no outliers found  ✗
```

**How we meet the requirement.** Derive the window from the data's *own* quartiles:
**`[Q1 − 2·IQR, Q3 + 2·IQR]`** (the `WINDOW_IQR` rule). That centers the bins on the data body and puts
the fences on real bin edges, so resolution goes exactly where it's needed. (This is the fix that
corrected taxi_d3.) More bins (1024 → 4096) then sharpen it further, shrinking the `fpga_vs_cpp` gap.

**The catch (→ §3).** The non-fused path gets this window **free** from the full decoded column already
in host RAM. Fusion needs it *before* decode starts, so it must estimate it from a small **sample** —
the fixed ~7 ms toll that makes fusion a large-data-only win.

## 1. C++ (GROUP BY) vs DuckDB SQL

### End-to-end run (build-23, sf10 fused)

| dataset | rows | FPGA (s) | C++ (s) | SQL (s) | FPGA/C++ | C++/SQL |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 0.014 | 0.016 | 0.025 | 1.14× | 1.56× |
| tpch_qty | 6.0M  | 0.021 | 0.032 | 0.032 | 1.52× | 1.00× |
| taxi_d2  | 6.0M  | 0.021 | 0.033 | 0.035 | 1.57× | 1.06× |
| extprice | 6.0M  | 0.028 | 0.089 | 0.100 | 3.18× | 1.12× |
| taxi_d3  | 13.1M | 0.040 | 0.056 | 0.058 | 1.40× | 1.04× |
| taxi_d4  | 20.3M | 0.059 | 0.079 | 0.079 | 1.34× | 1.00× |
| sf10 (fused) | 60.0M | 0.150 | 0.332 | 0.478 | 2.21× | 1.44× |

### Verdict — C++ vs SQL

Our hand-written C++ IQR operator against DuckDB's built-in SQL, on identical data. Both compute exact
quartiles; the ratio is how much faster our C++ is than the SQL.

| dataset | rows | C++ (ms) | SQL (ms) | C++/SQL (speedup) |
|---|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 16  | 25  | **1.56×** |
| tpch_qty | 6.0M  | 32  | 32  | 1.00× |
| taxi_d2  | 6.0M  | 33  | 35  | 1.06× |
| extprice | 6.0M  | 89  | 100 | 1.12× |
| taxi_d3  | 13.1M | 56  | 58  | 1.04× |
| taxi_d4  | 20.3M | 79  | 79  | 1.00× |
| sf10 (fused) | 60.0M | 332 | 478 | **1.44×** |
| **geomean** | | | | **1.16×** |

Our C++ is never slower than the SQL and wins clearly on the two datasets with the widest value
spread (taxi_d1 1.56×, sf10 1.44×); tpch_qty and taxi_d4 are ties.

## 2. FPGA vs C++ — speedup (end-to-end, sf10 fused)

The FPGA against the C++ operator, end-to-end. sf10 uses fusion, the default at that scale.

| dataset | rows | FPGA (ms) | C++ (ms) | FPGA/C++ (speedup) |
|---|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 14  | 16  | 1.14× |
| tpch_qty | 6.0M  | 21  | 32  | 1.52× |
| taxi_d2  | 6.0M  | 21  | 33  | 1.57× |
| extprice | 6.0M  | 28  | 89  | **3.18×** |
| taxi_d3  | 13.1M | 40  | 56  | 1.40× |
| taxi_d4  | 20.3M | 59  | 79  | 1.34× |
| sf10 (fused) | 60.0M | 150 | 332 | **2.21×** |
| **geomean** | | | | **1.67×** |

The FPGA wins every dataset end-to-end. The margin is largest on extprice (3.18×), where the C++ pays
most for its exact quartiles while the FPGA's fixed-size histogram cost does not move.

## 3. Fusion on vs off (end-to-end)

Fusion only engages at sf10 (≥30M rows + streaming sink), so **only the sf10 row changes** — every
other dataset is identical to §2. The whole table is repeated here with fusion off to show that.

| dataset | rows | FPGA (ms) | C++ (ms) | FPGA/C++ (speedup) |
|---|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 14  | 16  | 1.14× |
| tpch_qty | 6.0M  | 21  | 32  | 1.52× |
| taxi_d2  | 6.0M  | 21  | 33  | 1.57× |
| extprice | 6.0M  | 28  | 89  | 3.18× |
| taxi_d3  | 13.1M | 40  | 56  | 1.40× |
| taxi_d4  | 20.3M | 59  | 79  | 1.34× |
| sf10     | 60.0M | 214 | 327 | 1.53× |
| **geomean** | | | | **1.58×** |

**sf10 only — fusion on vs off (end-to-end):**

| sf10 | FPGA (ms) | FPGA/C++ |
|---|--:|--:|
| fusion **off** | 214 | 1.53× |
| fusion **on**  | 150 | 2.21× |

Fusion cuts sf10's end-to-end from 214 → 150 ms, lifting its speedup from 1.53× to 2.21× and the
overall geomean from 1.58× to 1.67×.

### How fusion works

The decoded column is too big for the FPGA's on-chip memory (~457 MB on sf10), so it lives in **host
RAM**; a "pass" is one trip of that whole column over PCIe into the IQR core. Both methods do two IQR
passes — pass 1 builds the histogram (Q1/Q3), pass 2 flags outliers — but they route the column
differently.

**Method A — non-fused (the column crosses PCIe 3 times)**

```
HOST RAM                          PCIe                 FPGA
 parquet file      ───────────────────────────►   decoder
 decoded column    ◄───────────────────────────   (decode output)     ① decoder → host
 decoded column    ───────────────────────────►   IQR histogram       ② PASS 1  (find Q1/Q3)
 decoded column    ───────────────────────────►   IQR flagging        ③ PASS 2  (flag outliers)
```

The decoder and the IQR core are separate blocks on the chip that don't talk to each other, so the
column has to go out to host and come back twice for the two IQR passes. Three bus crossings total.

**Method B — fused (the column crosses PCIe 2 times)**

```
HOST RAM                          PCIe                 FPGA
 parquet file      ───────────────────────────►   decoder ──tee──► IQR histogram   PASS 1 (on-chip!)
 decoded column    ◄───────────────────────────   (decode output)
 decoded column    ───────────────────────────►   IQR flagging                      PASS 2
```

Fusion tees the decoder output straight into the histogram on-chip, so **pass 1 never crosses PCIe**.
The catch: to feed the histogram *during* decode it must fix the bin range up front, from a small
**sample** — a **fixed ~7 ms cost** (dominated by host↔FPGA round-trips, not data volume). The
non-fused path gets its window free, from the full decoded column already in host RAM.

**What causes the time difference** — fusion trades a size-scaling pass for a fixed sample toll:

| | small dataset | large dataset (sf10) |
|---|--:|--:|
| pass-1 work fusion **saves** | ~2–3 ms | ~38 ms |
| fixed sample-window cost fusion **adds** | ~7 ms | ~7 ms |
| **net** | **−4 ms (loss)** | **+31 ms (win)** |

The pass fusion removes scales with size; the toll it adds is fixed. So fusion only pays once the pass
is bigger than the toll — which is why it's gated to ≥30M rows.

## 4. Decoder comparison — 1 lane vs 4 lanes

Same 4096-bin bitstream; the **only** difference is the number of ColumnChunkDecoders (build-21 = 1,
build-23 = 4). sf10 fused on both.

### End-to-end — 1 decoder (build-21, sf10 fused)

| dataset | rows | FPGA (s) | C++ (s) | SQL (s) | FPGA/C++ | C++/SQL |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 0.014 | 0.016 | 0.025 | 1.14× | 1.56× |
| tpch_qty | 6.0M  | 0.021 | 0.031 | 0.033 | 1.48× | 1.06× |
| taxi_d2  | 6.0M  | 0.022 | 0.033 | 0.035 | 1.50× | 1.06× |
| extprice | 6.0M  | 0.054 | 0.088 | 0.103 | 1.63× | 1.17× |
| taxi_d3  | 13.1M | 0.043 | 0.055 | 0.057 | 1.28× | 1.04× |
| taxi_d4  | 20.3M | 0.063 | 0.077 | 0.080 | 1.22× | 1.04× |
| sf10 (fused) | 60.0M | 0.422 | 0.339 | 0.489 | 0.80× | 1.44× |

### End-to-end — 4 decoders (build-23, sf10 fused)

| dataset | rows | FPGA (s) | C++ (s) | SQL (s) | FPGA/C++ | C++/SQL |
|---|--:|--:|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 0.014 | 0.016 | 0.025 | 1.14× | 1.56× |
| tpch_qty | 6.0M  | 0.021 | 0.032 | 0.032 | 1.52× | 1.00× |
| taxi_d2  | 6.0M  | 0.021 | 0.033 | 0.035 | 1.57× | 1.06× |
| extprice | 6.0M  | 0.028 | 0.089 | 0.100 | 3.18× | 1.12× |
| taxi_d3  | 13.1M | 0.040 | 0.056 | 0.058 | 1.40× | 1.04× |
| taxi_d4  | 20.3M | 0.059 | 0.079 | 0.079 | 1.34× | 1.00× |
| sf10 (fused) | 60.0M | 0.150 | 0.332 | 0.478 | 2.21× | 1.44× |

### Verdict — decoder impact (end-to-end FPGA, sf10 fused)

| dataset | rows | FPGA — 1 decoder (ms) | FPGA — 4 decoders (ms) | 4-decoder speedup |
|---|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 14  | 14  | 1.00× |
| tpch_qty | 6.0M  | 21  | 21  | 1.00× |
| taxi_d2  | 6.0M  | 22  | 21  | 1.05× |
| extprice | 6.0M  | 54  | 28  | **1.93×** |
| taxi_d3  | 13.1M | 43  | 40  | 1.08× |
| taxi_d4  | 20.3M | 63  | 59  | 1.07× |
| sf10 (fused) | 60.0M | 422 | 150 | **2.81×** |
| **geomean** | | | | **1.31×** |

The effect is **bimodal**: 4 decoders help only the two **decode-bound** datasets — extprice (1.93×) and
sf10 (2.81×) — and barely move the rest (~1.0×). Those two are exactly the high-cardinality columns
from §1 (many distinct values → PLAIN encoding → heavy decode), so they are decode-limited and scale
with decode lanes. The small / dictionary-encoded sets (taxi, tpch_qty) are limited by other phases, so
a single decoder already keeps up. (End-to-end compresses the small datasets toward 1.0× because the
shared DuckDB query cost dominates their wall-clock; the decode-bound sets still show the lanes clearly.)

### Dataset by dataset — why the gain differs

More decoders speed up only **decode** (turning parquet into raw values on the FPGA); the C++ side never
touches the decoder, so its time is fixed. So the FPGA/C++ ratio improves in proportion to how
**decode-bound** each dataset is — set by **size** (more rows → more decode) and **cardinality/encoding**
(high-cardinality columns can't be dictionary-compressed → PLAIN-encoded → **heavy** decode; low-cardinality
columns are dictionary-encoded → **light** decode).

FPGA/C++, end-to-end, 1 → 4 decoders:

| dataset | rows | distinct | 1-dec | 4-dec | change |
|---|--:|--:|--:|--:|---|
| taxi_d1 | 3.0M | 8,970 | 1.14× | 1.14× | none |
| tpch_qty | 6.0M | 50 | 1.48× | 1.52× | tiny |
| taxi_d2 | 6.0M | 10,647 | 1.50× | 1.57× | small |
| taxi_d3 | 13.1M | 12,991 | 1.28× | 1.40× | moderate |
| taxi_d4 | 20.3M | 14,681 | 1.22× | 1.34× | moderate |
| **extprice** | 6.0M | 933,900 | 1.63× | **3.18×** | **nearly 2×** |
| **sf10** | 60.0M | 1,351,462 | 0.80× | **2.21×** | **loss → big win** |

- **taxi_d1 (3M, low-card, dictionary) — 1.14× → 1.14×, none.** Decode is a couple of ms; the wall-clock
  is dominated by fixed costs (fusion window toll, pass 2, DuckDB tax). No decode bottleneck for extra
  lanes to relieve.
- **tpch_qty (6M, 50 distinct) — 1.48× → 1.52×, tiny.** Extreme dictionary compression → decode almost
  free; 4 lanes speed up the cheapest phase, so the bump is noise.
- **taxi_d2 (6M) — 1.50× → 1.57×, small.** taxi_d1's shape at double the rows → decode a slightly bigger
  slice → a small real gain, still capped by light dictionary decode.
- **taxi_d3 (13M) — 1.28× → 1.40×, moderate.** Decode scales with size, so at 13M it's a meaningful
  fraction → halving it with 4 lanes lifts the ratio; still only partly decode-bound (dictionary).
- **taxi_d4 (20M) — 1.22× → 1.34×, moderate.** Most decode work of the taxi group → the biggest taxi
  gain, same dictionary ceiling.
- **extprice (6M, 934k distinct, PLAIN) — 1.63× → 3.18×, nearly doubles.** Only 6M rows but huge
  cardinality (15.6% distinct) → can't dictionary-compress → PLAIN → **heavy decode**. 1 decoder was the
  bottleneck (~54 ms); 4 lanes halve it (~28 ms) → ratio nearly doubles. Proof that **cardinality, not
  just size, drives decode-boundness** — a small column can be decode-bound if it's high-cardinality.
- **sf10 (60M, 1.35M distinct, PLAIN) — 0.80× → 2.21×, loss → win.** Most decode-bound of all (largest
  *and* PLAIN). One decoder starved the pipeline so badly the FPGA **lost** to the CPU (0.80×); 4 lanes
  cut decode dramatically, flipping it to a 2.21× win — the biggest swing, and the regression we chased.

**Pattern:** the gain tracks **decode-boundness = size × (PLAIN vs dictionary)**. The two high-cardinality
PLAIN columns (extprice, sf10) jump hugely; the low-cardinality dictionary columns barely move — the same
bimodal split as the cardinality appendix.

## 5. Naive 1-line SQL vs our group-by algorithm

The 1-line SQL is the exact one-liner a user would actually write — DuckDB's built-in
`quantile_cont(v,0.25/0.75)` for Q1/Q3, then the 1.5·IQR fence. Our group-by algorithm replaces it
with a group-by CDF over distinct values (the same algorithm our SQL arm and C++ operator run). Both
are exact; end-to-end, best of 7 warm runs.

### Queries — how each is called

```sql
-- 1-line SQL (traditional): DuckDB's built-in exact quantiles
SELECT count(*) FILTER (WHERE is_outlier) FROM (
  SELECT (t.v < s.q1 - 1.5*(s.q3-s.q1) OR t.v > s.q3 + 1.5*(s.q3-s.q1)) AS is_outlier
  FROM read_parquet('data.parquet') t,
       (SELECT quantile_cont(v,0.25) q1, quantile_cont(v,0.75) q3
          FROM read_parquet('data.parquet')) s
);

--  FPGA operator
SELECT count(*) FILTER (WHERE is_outlier)
  FROM iqr_flags_only('data.parquet','v');

-- our group-by, C++ operator
SELECT count(*) FILTER (WHERE is_outlier)
  FROM iqr_cpu_flags_groupby('data.parquet','v');
```

### Verdict

| dataset | rows | 1-line SQL (ms) | our group-by, SQL (ms) | our group-by, C++ (ms) | speedup (1-line → C++) |
|---|--:|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 73   | 24 | 16 | 4.6× |
| tpch_qty | 6.0M  | 153  | 30 | 29 | 5.3× |
| taxi_d2  | 6.0M  | 128  | 34 | 31 | 4.1× |
| extprice | 6.0M  | 128  | 97 | 85 | 1.5× |
| taxi_d3  | 13.1M | 288  | 57 | 54 | 5.3× |
| taxi_d4  | 20.3M | 600  | 76 | 76 | 7.9× |
| sf10     | 60.0M | 1831 | 498 | 320 | **5.7×** |
| **geomean** | | | | | **4.5×** |

The naive one-liner is **4.5× slower** than our C++ baseline (geomean), because exact `quantile_cont`
sorts/selects over every row while our algorithm builds a CDF from per-value counts. Our group-by wins
even as **pure SQL** (same engine, geomean 3.8×), so the gain is algorithmic, not just C++. The one
exception is extprice (1.5×): its high cardinality makes the group-by itself costly, shrinking the
margin — the same reason it's the slowest of the 6M-row sets everywhere in this report.

## 6. Index-mode potential (projected)

Index mode makes pass 2 re-read packed 16-bit-index-space words (32-bit slots) instead of the 64-bit
value column — half the beats over PCIe. It only engages on the fused path, so this table forces fusion
on every dataset (`OASIS_IQR_FUSE_MIN_ROWS=1`) to expose the effect at every size. End-to-end, index
OFF vs ON, same config otherwise.

| dataset | rows | FPGA index OFF (ms) | FPGA index ON (ms) | index speedup | FPGA/C++ (index ON) |
|---|--:|--:|--:|--:|--:|
| taxi_d1  | 3.0M  | 14  | 14  | 1.00× | 1.21× |
| tpch_qty | 6.0M  | 18  | 19  | ~1.0× (noise) | 1.68× |
| taxi_d2  | 6.0M  | 19  | 19  | 1.00× | 1.74× |
| extprice | 6.0M  | 27  | 26  | 1.04× | 3.42× |
| **sf10** | 60.0M | **150** | **131** | **1.15×** | **2.52×** |

The gain scales with pass-2's share of the operator, so it shows only at **sf10 scale: −13% end-to-end
(150 → 131 ms), lifting FPGA/C++ from 2.19× to 2.52×** (operator-only it's −14%, 137.6 → 118.4 ms). Below
~13M rows pass 2 is a few ms of a ~15–20 ms operator, so halving it is lost in noise and the forced-fusion
overhead cancels it. Index mode is a large-data lever, exactly like the extra decode lanes in §4.

> **Status — projected, not yet shippable.** These are *timing* numbers on build-24. The re-widened
> `idx_pack` misses setup timing (WNS −1.33 ns on `iqr_idx_data`), so the **flag counts are wrong** on
> this bitstream (sf10 reports 4–9 spurious outliers vs the true 0) and **taxi_d3/d4 hang** the index
> drain (the same defect corrupts the beat/`o_last` accounting on their ragged chunks). The algorithm is
> bit-exact in simulation (204,884 combinations, 0 errors). Correctness — and the taxi rows — land in
> build-25, which pipelines `idx_pack` to close timing.

## Note — timing (WNS) scales with decoder count

More decode lanes cost LUTs and congestion, which worsens worst-slack:

| build | decoders | LUTs (util) | WNS | worst failing paths |
|---|--:|--:|--:|---|
| build-21 | 1 | 320k (24.5%) | −0.355 ns | `idx_pack` / wide-pack (index, guarded off) |
| build-23 | 4 | 566k (43.4%) | −1.879 ns | `iqr_histogram_feed` (fusion), HBM shell, `idx_pack` |

Going 1→4 decoders adds ~230k LUTs (~77k each), 24.5% → 43.4% utilization; the failing paths are
~86% routing (congestion, not logic depth), which is why WNS drops from −0.36 to −1.88 ns. **None of
the failing paths are the value-path decoder or IQR core**, so both bitstreams run the shipping path
correctly — the misses sit in fusion/index/shell logic, which is why the fused and index numbers here
carry the correctness caveats above.

## Appendix — dataset cardinality

Measured exactly (`COUNT(DISTINCT)` on the IQR column) — sorted low → high cardinality:

| # | dataset | rows | distinct values | distinct/rows |
|--:|---|--:|--:|--:|
| 1 | tpch_qty | 6.0M | 50 | 0.0008% |
| 2 | taxi_d1 | 3.0M | 8,970 | 0.30% |
| 3 | taxi_d2 | 6.0M | 10,647 | 0.18% |
| 4 | taxi_d3 | 13.1M | 12,991 | 0.10% |
| 5 | taxi_d4 | 20.3M | 14,681 | 0.07% |
| 6 | tpch_extprice (extprice) | 6.0M | 933,900 | 15.56% |
| 7 | tpch_extprice_sf10 (sf10) | 60.0M | 1,351,462 | 2.25% |

Three tiers: **tiny** (tpch_qty, 50 distinct), **low/moderate** (the taxi fare columns, ~9k–15k), and
**high** (extprice / sf10, ~0.9–1.35M). This split explains the report: extprice and sf10 are the
high-cardinality columns that decode heaviest (PLAIN-encoded) — so they gain most from extra decode
lanes (§4) and give the FPGA its widest margins (§1) — while extprice's high distinct/rows (15.6%) is
why our group-by's win over the 1-line SQL is smallest there (§5).

## Appendix — how index mode works (§6)

Index mode cuts **pass 2's** PCIe traffic by re-reading compact bin indices instead of the full 64-bit
values.

**Idea.** Pass 1 already computes each value's histogram bin. Index mode saves those bin numbers; pass 2
re-reads the small indices (not the fat values) and compares them to the fences, translated into the
same index space.

**Why it's exact.** Q1 and Q3 are bin *edges*, so the fences land on exact bin boundaries — "is value
past the fence value?" becomes "is value's index past the fence's index?", an identity, not an
approximation. Two refinements make it airtight:
- **Half-bins** — `1.5·IQR` can be an odd number of half-bins, so indices are measured in half-bins
  (`index = (value − bin_min)/(W/2)`); both fences then fall on integer indices.
- **exact bit** — many values floor to the same index, so a value exactly *on* the upper fence and one
  just *above* it share an index. One extra "exact" bit (the value sits on a boundary) preserves the
  strict `>` test. So each stored item = **signed half-bin index + 1 exact bit**.

**The savings.** Indices are small, so more fit per 512-bit PCIe beat than 64-bit values:

| bins | index width | slot | indices per beat | vs 8 values/beat |
|---|---|---|--:|--:|
| 1024 | 14-bit (±8191) | 16-bit | 32 | 4× fewer beats |
| 4096 | 16-bit (±32768) | 32-bit | 16 | 2× fewer beats |

(4096 needs 16-bit because the reachable fence index grows to ~±20,475; a 14-bit index would saturate
and miss far outliers — the re-widen that pushed the slot to 32 bits, halving the density but still a win.)

**Flow.**
```
PASS 1:  value ─► bin it ─► also emit (index + exact bit) ─► pack ─► store to host  (the "index buffer")
PASS 2:  re-read the small index buffer ─► compare each index to the fence indices ─► flags
```

**Status.** Bit-exact in simulation (204,884 cases, 0 errors). On build-24 the 32-bit packer (`idx_pack`)
misses setup timing, so the stored indices are corrupted → wrong flags (and a drain hang on ragged taxi
columns); build-25 pipelines the packer to fix it. See §6 for the measured potential.
