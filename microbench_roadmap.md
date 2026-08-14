# Benchmark roadmap — reproducing Tests 0, 1, 3, 4 and 5 for the z-score operator

**Who this is for.** You (or your Claude) are building the z-score half of a joint workshop paper.
The IQR half has run one real-data benchmark and four microbenchmarks; three of them are the paper's
evaluation panels. This document contains **everything needed to run the same tests on the z-score
operator**: where to download the real datasets and how to rebuild them bit-exactly, the synthetic
dataset recipes, the exact measurement protocols, the harness code, the gates that must pass, the
failure modes that already cost us time, and the reference numbers to check against.

**Give this whole file to Claude and say: "implement this."** It is written to be executable, not
read. Every SQL statement, script and constant below is what actually ran, not a sketch.

> **The point of doing this at all.** These are *not* "our operator is fast" plots. Each test isolates
> ONE input property and holds everything else fixed, so an effect can be attributed to a cause. The
> three axes were chosen specifically because they are **shared** by IQR and z-score — so if both
> operators produce the same curve shape, the claim becomes architectural rather than anecdotal, and
> the two halves of the paper reinforce each other instead of sitting side by side.

---

## 0. The five tests, and what each one proves

| # | Test | Axis | The claim it supports |
|---|---|---|---|
| **0** | **Real datasets** | 7 real columns, everything varying | The table a reviewer believes. Three cardinality tiers, 3M → 60M rows, **ragged row groups**. Not a controlled experiment — the credibility anchor for the controlled ones |
| **1** | Size sweep | rows: 1M → 100M | The FPGA wins at every size; **fusion changes the slope**, not just the constant, so the advantage is durable at scale rather than decaying |
| **3** | Core sweep | host threads: 1 → 32 | The offload claim: the FPGA path is **flat in host core count in both phases**, and the CPU baseline **cannot reach it at any core count** |
| **4** | Compression & encoding | 8 on-disk representations of the *same* numbers | The statistics stage is **representation-invariant**; the shared **decoder** is where the time goes and where the advantage grows. Speedup spans 1.12×–2.47× on identical data ⇒ **a speedup without a stated encoding is meaningless** |
| **5** | Distribution shape | skewness: 0.00 → 3.44 | ⚠️ **A control, not a panel** — both arms come out flat. It exists to defend Tests 1/3/4, which all run on uniform data, against *"real data is skewed, your numbers don't transfer"* |

**Panels: 1, 3, 4.** Test 0 is a table, Test 5 is two sentences. Tests 1/3/4 characterise behaviour
**shared** by both operators, so each figure supports both halves of the joint paper.

### ⛔ Do NOT run a cardinality sweep (our "Test 2" — withdrawn)

We ran it, got a spectacular result (1.4× → 11.7× on one bitstream), and **cut it from the paper**.
Reason: cardinality is **IQR-specific**. Our CPU baseline pays for distinct values because quartiles
need a `GROUP BY`; **your** CPU baseline is count/sum/sum-of-squares, i.e. O(rows) and completely
cardinality-independent. Both of your arms would be flat and the panel would say nothing.

It is mentioned here for one reason only: it is *why* Test 4 has to pin encoding and byte volume so
carefully (§5.2). Read that part; skip the test.

---

## 1. Preconditions — check these before generating a single byte

### 1.1 What your operator must expose

The harness measures **operator time**, not query wall time, so both arms must print a phase line.
Ours look like this under `OASIS_IQR_TIMING=1`:

```
[iqr]        heavy 53.8 ms   decode 33.8 ms   passes 12.8 ms   ... pass1=fused sink=stream
[iqr-cpu-gb] heavy 129.5 ms
```

You need the equivalent. Fill in this table before starting — **everything in §8 keys off it**:

| what | ours | yours |
|---|---|---|
| FPGA table function `(path, col) -> is_outlier` | `iqr_flags_only` | `?` |
| CPU baseline table function | `iqr_cpu_flags_groupby` | `?` |
| timing env var | `OASIS_IQR_TIMING=1` | `?` |
| log tag in `[...]` | `iqr` / `iqr-cpu-gb` | `?` |
| operator-time line | `heavy <ms> ms` | `?` |
| decode-phase line | `decode <ms> ms` | `?` |
| second-pass line | `passes <ms>` | `?` |
| fusion state | `pass1=fused` | `?` |
| fusion env vars | `OASIS_IQR_{STREAM,FUSE,WINDOW_FPGA,FUSE_MIN_ROWS}` | `?` |

**If your CPU arm does not print `heavy`,** add it before benchmarking. Comparing FPGA operator time
against CPU *end-to-end* is not a comparison; DuckDB's emit path is ~70% of e2e on a `CREATE TABLE`
and it is identical on both sides, which drags every ratio toward 1.0.

**If your operator has no fusion**, run Test 1 as a single curve and skip §4.4. Everything else works
unchanged. Say so in the paper rather than leaving a hole.

### 1.2 Environment (ours — adapt paths)

```bash
# the extension-linked duckdb binary, NOT a system duckdb
DB=~/oasis/extension/build/release/duckdb
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH     # libcoyote.so
```

Hard rules from our side that you almost certainly inherit:

* **Never Ctrl-C / Ctrl-Z an in-flight FPGA query.** Pinned pages and in-flight DMA survive the
  process; Coyote cannot reset user logic between host processes. Recovering has needed a node reboot.
  The harness therefore uses `timeout` + **SIGTERM first**, 60 s grace, SIGKILL only as last resort.
* **Re-set hugepages after every card reprogram.**
* Editing anything under `software/` requires `cmake --install` before rebuilding the extension —
  the extension links the **installed** headers in `~/opt/include`, which go stale silently.

---

## 2. The measurement protocol — Tests 1, 3, 4 and 5

> **Run the query 7 times in ONE DuckDB session. Report the arithmetic MEAN OF THE LAST 3.
> No median. No spread.**

⚠️ **Test 0 does NOT use this protocol** — it is medians of 15 warm runs, end-to-end (§3). Keep the two
apart in the paper and label which is which; mixing them silently is worse than having only one.

Rationale, because a reviewer will ask: all 7 run inside one process, and DuckDB's allocator pooling
is absent early in a session — on our tail-heavy real datasets this made the first iterations bimodal.
Four discarded iterations put every measurement firmly in steady state; averaging 3 smooths residual
jitter without hiding a trend the way a median over a drifting sample would.

Further fixed choices — keep them identical or the numbers are not comparable to ours:

* **`--consume`**: the query is `SELECT count(*) FILTER (WHERE is_outlier) FROM <src>;`, i.e. aggregate
  the flags. Not `CREATE TABLE`. Use `FILTER`, not a bare `count(*)`, so the flag column is genuinely
  read and cannot be projected away.
* **`PRAGMA threads=32`** everywhere except Test 3, which sweeps it.
* **Fresh DuckDB process per point.** Never mutate `PRAGMA threads` mid-session.
* **Warm the page cache** by reading the file once before timing. An unwarmed read gets charged to
  operator time — and in Test 3 it would be charged *unevenly* across thread counts, manufacturing a
  fake scaling curve.
* **Check correctness on all 7 iterations of every point**, not just once (§2.1).

### 2.1 Every dataset self-checks — this is non-negotiable

All three tests place outliers **in an empty value gap far outside the decision threshold**, so the
expected flag count is exact and quantisation-proof. Any deviation is a real bug, never an artefact.

This also functions as a **soak test**. Our bitstream ships with 1 ps of hold margin, and the
historical failure signature was *wandering* counts across runs while simulation stayed bit-exact —
which only per-iteration checking catches.

### 2.2 ✅ The gap argument works for z-score too — verified arithmetically

Our datasets were designed around IQR fences. **They are valid for z-score unchanged, for k ≥ 2.**
Here is the check for the size-sweep recipe (§4.1); do the same for your k before trusting it.

Base uniform on `[0, 10^6)`, 0.1% of rows bumped by `+5×10^6` (so outliers land in `[5e6, 6e6)`):

```
contaminated mean = 0.999·5.000e5 + 0.001·5.500e6            = 5.050e5
contaminated  sd  = sqrt(E[X²] − mean²) = sqrt(3.630e11 − 2.550e11) ≈ 3.29e5
threshold(k=3) = 5.050e5 + 3·3.29e5 = 1.492e6
threshold(k=2) = 5.050e5 + 2·3.29e5 = 1.163e6
lower threshold is NEGATIVE at both k ⇒ no base row is ever flagged low
```

Base values stop at `1.0e6`; outliers start at `5.0e6`. **Any threshold anywhere in [1e6, 5e6] gives
the identical answer**, and yours sits at 1.16–1.49e6 with a 3.4–5× margin to the outlier floor. So
no quantisation, sampling or precision effect in your fence computation can flip a single verdict.

**Expected flags = `rows / 1000`, exactly, at every point of every test.**

⚠️ **k = 1 breaks this** (threshold 8.34e5 < 1e6 ⇒ base rows get flagged and the expected count is no
longer exact). If you must run k=1, widen the gap: raise `OUTLIER_OFFSET` and re-run the arithmetic
above. The Test 4 recipe (§6.3) is the same shape scaled 10×, so the same conclusion holds there.

---

## 3. TEST 0 — THE REAL DATASETS (run this FIRST)

Tests 1/3/4/5 are synthetic: each isolates one variable so an effect can be attributed to a cause.
**Test 0 is the opposite** — seven real columns, every property varying at once. It is the table a
reviewer actually believes, and it is the one that says "this works on data we did not design."

Our version is `report_2807.md`. Reproduce it on the z-score operator and the paper gets a
real-data table for both operators side by side.

> ⚠️ **Different protocol from every other test.** Test 0 is **medians of 15 warm runs, END-TO-END**
> (the whole query), not mean-of-last-3 operator time. Do not mix the two: report Test 0 numbers as
> end-to-end seconds/ms and the synthetic tests as operator ms, and say which is which.

### 3.1 The seven datasets

Two families, chosen to span three cardinality tiers and a 20× size range.

| # | name | source | rows | column | distinct | distinct/rows |
|--:|---|---|--:|---|--:|--:|
| 1 | `taxi_d1` | NYC yellow taxi 2024-01 | 2,964,624 | `fare_cents` | 8,970 | 0.30% |
| 2 | `tpch_qty` | TPC-H SF1 `lineitem.l_quantity` | 6,001,215 | `v` | 50 | 0.0008% |
| 3 | `taxi_d2` | NYC yellow taxi 2024-01…02 | 5,972,150 | `fare_cents` | 10,647 | 0.18% |
| 4 | `tpch_extprice` | TPC-H SF1 `lineitem.l_extendedprice` | 6,001,215 | `v` | 933,900 | 15.56% |
| 5 | `taxi_d3` | NYC yellow taxi 2024-01…04 | 13,069,067 | `fare_cents` | 12,991 | 0.10% |
| 6 | `taxi_d4` | NYC yellow taxi 2024-01…06 | 20,332,093 | `fare_cents` | 14,681 | 0.07% |
| 7 | `tpch_extprice_sf10` | TPC-H SF10 `lineitem.l_extendedprice` | 59,986,052 | `v` | 1,351,462 | 2.25% |

**Three cardinality tiers, and this is the point of the selection:** *tiny* (tpch_qty, 50 distinct),
*low/moderate* (the four taxi fare columns, ~9k–15k), and *high* (extprice/sf10, ~0.9–1.35M). The
high-cardinality columns are PLAIN-encoded and decode-heaviest, which is why they gain most from extra
decode lanes and give the FPGA its widest margins. The taxi columns are dictionary-encoded and cheap
to decode. Without all three tiers a real-data table just reports one regime and calls it general.

### 3.2 ⚠️ Real data is RAGGED — six of the seven trip the streaming guard

This is the single most important difference from every synthetic test in this document, and it will
bite you if your operator has a guard like ours:

| dataset | encodings | row groups | min group | **min_group % 8** |
|---|---|--:|--:|--:|
| `taxi_d1` | PLAIN + PLAIN_DICTIONARY | 25 | 15,504 | **0** ✅ |
| `taxi_d2` | PLAIN_DICTIONARY | 49 | 72,742 | **6** ⚠️ |
| `taxi_d3` | PLAIN_DICTIONARY | 107 | 40,881 | **1** ⚠️ |
| `taxi_d4` | PLAIN_DICTIONARY | 166 | 51,449 | **1** ⚠️ |
| `tpch_qty` | PLAIN_DICTIONARY | 49 | 102,975 | **7** ⚠️ |
| `tpch_extprice` | PLAIN | 49 | 102,975 | **7** ⚠️ |
| `tpch_extprice_sf10` | PLAIN | 489 | 20,612 | **4** ⚠️ |

Every synthetic dataset in Tests 1/3/4/5 uses `ROW_GROUP_SIZE 122880` precisely so `num_values % 8 == 0`
and streaming is never rejected. **Real files do not cooperate.** In our stack a non-final row group
with `num_values % 8 != 0` makes the host's ragged guard reject streaming and fall back to the memcpy
path (we later added a host-side stitch, `OASIS_IQR_STREAM_RAGGED`, to lift it). So Test 0 may exercise
a *different code path* than Tests 1/3/4/5 on the same operator.

**Check this on your side before interpreting anything**, and state in the paper which path each row
used. A real-vs-synthetic discrepancy that is really a code-path difference is the easiest way to draw
a wrong conclusion here.

### 3.3 Building the taxi datasets

Source: **NYC TLC Yellow Taxi Trip Records**, monthly Parquet. Landing page (the authority if a URL
404s — TLC has moved these before):
`https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page`

```bash
mkdir -p ~/datasets && cd ~/datasets
for m in 01 02 03 04 05 06; do
  curl -fL -o ytd_2024_${m}.parquet \
    "https://d37ci6vc6kj4l6.cloudfront.net/trip-data/yellow_tripdata_2024-${m}.parquet"
done
```

**Verify the downloads before building** — if TLC has re-issued a month, every number below changes:

| file | rows |
|---|--:|
| `ytd_2024_01.parquet` | 2,964,624 |
| `ytd_2024_02.parquet` | 3,007,526 |
| `ytd_2024_03.parquet` | 3,582,628 |
| `ytd_2024_04.parquet` | 3,514,289 |
| `ytd_2024_05.parquet` | 3,723,833 |
| `ytd_2024_06.parquet` | 3,539,193 |

The four taxi datasets are **cumulative month ranges** of the same column — d1 ⊂ d2 ⊂ d3 ⊂ d4 — which
is deliberate: size grows while distribution shape stays essentially fixed, so the four form a crude
size series *within* the real-data table.

`fare_amount` is a `DOUBLE` in dollars. It is converted to **integer cents** (`BIGINT`), because the
operator is an integer pipeline:

```sql
-- taxi_d1 = 2024-01 ; d2 = 01..02 ; d3 = 01..04 ; d4 = 01..06
COPY (SELECT round(fare_amount * 100)::BIGINT AS fare_cents
      FROM read_parquet(['ytd_2024_01.parquet']))
  TO 'taxi_d1.parquet' (FORMAT PARQUET);

COPY (SELECT round(fare_amount * 100)::BIGINT AS fare_cents
      FROM read_parquet(['ytd_2024_01.parquet','ytd_2024_02.parquet']))
  TO 'taxi_d2.parquet' (FORMAT PARQUET);

COPY (SELECT round(fare_amount * 100)::BIGINT AS fare_cents
      FROM read_parquet(['ytd_2024_01.parquet','ytd_2024_02.parquet',
                         'ytd_2024_03.parquet','ytd_2024_04.parquet']))
  TO 'taxi_d3.parquet' (FORMAT PARQUET);

COPY (SELECT round(fare_amount * 100)::BIGINT AS fare_cents
      FROM read_parquet(['ytd_2024_01.parquet','ytd_2024_02.parquet','ytd_2024_03.parquet',
                         'ytd_2024_04.parquet','ytd_2024_05.parquet','ytd_2024_06.parquet']))
  TO 'taxi_d4.parquet' (FORMAT PARQUET);
```

**NO filtering, no `WHERE` clause** — every row of every month, negatives included. The taxi column
genuinely contains negative fares (refunds) and absurd maxima; `taxi_d4` spans **−128,540 … 33,407,632
cents** (−$1,285 … $334,076) while real fares live in $0…$5,000. That extreme spread is exactly why the
histogram window must be derived from the data's own quartiles rather than from min/max — a min/max
window would crush 99.9% of values into one bin and return IQR = 0. **If your z-score operator sizes
anything from min/max, this dataset is where it breaks**, and that is worth knowing before the paper
rather than after.

⚠️ Do **not** set `ROW_GROUP_SIZE` on these `COPY`s. Leave DuckDB's default — that is what produces the
ragged geometry in §3.2, and it is what makes this a *real* dataset rather than a sanitised one.

### 3.4 Building the TPC-H datasets

DuckDB ships a TPC-H generator, so no `dbgen` build is needed:

```sql
INSTALL tpch; LOAD tpch;
CALL dbgen(sf = 1);
COPY (SELECT l_quantity::BIGINT      AS v FROM lineitem) TO 'tpch_qty.parquet'      (FORMAT PARQUET);
COPY (SELECT (l_extendedprice*100)::BIGINT AS v FROM lineitem) TO 'tpch_extprice.parquet' (FORMAT PARQUET);
```

```sql
-- separate session; SF10 dbgen needs several GB of RAM and a few minutes
INSTALL tpch; LOAD tpch;
CALL dbgen(sf = 10);
COPY (SELECT (l_extendedprice*100)::BIGINT AS v FROM lineitem)
  TO 'tpch_extprice_sf10.parquet' (FORMAT PARQUET);
```

`l_extendedprice` is `DECIMAL(15,2)`, converted to **cents** like the taxi column. `l_quantity` is an
integer 1…50 already, so it casts directly.

💡 **Generate with the stock `duckdb` python module, not the extension-linked binary.** Dataset
generation is pure SQL and never touches the card, and our extension binary aborts at startup on any
node without 1 GiB huge pages. `INSTALL tpch` also needs network, which the compute nodes may not have.

### 3.5 Verification — your files must produce these digests

Order-independent fingerprints of the value multiset. If these match, you have our exact data and your
numbers are directly comparable to ours:

```sql
SELECT count(*), sum(v)::HUGEINT, sum(hash(v))::HUGEINT FROM read_parquet('<file>');
```

| dataset | rows | `sum(v)` | `sum(hash(v))` |
|---|--:|--:|--:|
| `taxi_d1` | 2,964,624 | 5388222476 | 23771653363828416072391791 |
| `taxi_d2` | 5,972,150 | 10815993187 | 47877796711972042078265456 |
| `taxi_d3` | 13,069,067 | 24176275770 | 105615777573860570175254220 |
| `taxi_d4` | 20,332,093 | 38401520485 | 164927167590064631073785560 |
| `tpch_qty` | 6,001,215 | 153078795 | 52808143971739813600599720 |
| `tpch_extprice` | 6,001,215 | 22957731090120 | 55394574992723897575236221 |
| `tpch_extprice_sf10` | 59,986,052 | 229381315677336 | 553670621221086881273073936 |

(Verified on our side: the §3.3 recipe reproduces `taxi_d1` with byte-identical digests, so the recipe
is the real provenance and not a reconstruction.)

Total on disk ≈ **740 MB** for the seven, plus ~340 MB of monthly taxi sources.

### 3.6 What to measure

Three arms, not two — real data is where the **SQL** baseline earns its place, because it shows the
hand-written CPU operator is itself a fair opponent rather than a strawman:

| arm | what |
|---|---|
| `fpga` | your FPGA operator |
| `cpp` | your hand-written CPU operator — the honest baseline |
| `sql` | pure DuckDB SQL computing the same rule — proves the `cpp` arm is not a strawman |

```bash
python3 bench/medians.py -n 15 --consume --cpp-impl groupby
python3 bench/medians.py -n 15 --consume -d taxi_d4 sf10     # subset
```

Report **two** verdict tables: `cpp` vs `sql` (is our CPU baseline fair?) and `fpga` vs `cpp` (the
result). Aggregate with the **geometric** mean — an arithmetic mean of ratios is meaningless.

⚠️ **`--consume` matters more here than anywhere else.** `CREATE TABLE` adds DuckDB's single-threaded
append: measured at 438 ms of sf10's 647 ms, i.e. 92% of the "emit tax", while producing the flags
costs 38 ms. It is identical on both arms and drags every ratio toward 1.0, hiding the difference the
benchmark exists to measure.

### 3.7 Our reference numbers (IQR, build-23, alveo-u55c-07, medians of 15, end-to-end)

**FPGA vs C++:**

| dataset | rows | FPGA (ms) | C++ (ms) | speedup |
|---|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 14 | 16 | 1.14× |
| tpch_qty | 6.0M | 21 | 32 | 1.52× |
| taxi_d2 | 6.0M | 21 | 33 | 1.57× |
| extprice | 6.0M | 28 | 89 | **3.18×** |
| taxi_d3 | 13.1M | 40 | 56 | 1.40× |
| taxi_d4 | 20.3M | 59 | 79 | 1.34× |
| sf10 (fused) | 60.0M | 150 | 332 | **2.21×** |
| **geomean** | | | | **1.67×** |

**C++ vs SQL** — the fairness check: geomean **1.16×**, never slower than SQL, largest on the widest
value spreads (taxi_d1 1.56×, sf10 1.44×); tpch_qty and taxi_d4 are exact ties.

The shape to expect: **the margin tracks how decode-bound the dataset is.** extprice (6M rows but
934k distinct, PLAIN) beats sf10's 60M rows on ratio, because the CPU pays most for exact quartiles
exactly where the FPGA's fixed-size histogram cost does not move. Your z-score CPU baseline does not
pay that, so **expect flatter ratios than ours** — and expect `tpch_qty` (50 distinct) to be your
weakest row rather than your strongest.

### 3.8 Reproduce

```bash
cd ~/datasets
# 1. six monthly taxi files (§3.3), verify row counts
# 2. build taxi_d1..d4                      (§3.3)
# 3. build tpch_qty, tpch_extprice, sf10    (§3.4)
# 4. verify all seven digests               (§3.5)
cd ~/oasis && python3 bench/medians.py -n 15 --consume --cpp-impl groupby
```

---

## 4. TEST 1 — SIZE SWEEP (1M → 100M rows)

### 4.1 Generator

Save as `bench/gen_size_sweep.sh`. ~1.5 GB on disk.

```bash
#!/bin/bash
# Synthetic INT64 columns, 1M..100M rows, EVERYTHING except row count held constant.
set -u
DB="${DB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-$HOME/datasets/sizesweep}"
export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"

SIZES="${SIZES:-1 3 6 10 20 40 60 80 100}"     # millions of rows
CARD="${CARD:-1000000}"                        # distinct base values, FIXED across the sweep
OUTLIER_EVERY="${OUTLIER_EVERY:-1000}"         # 0.1% -> expected flags = rows/1000
OUTLIER_OFFSET="${OUTLIER_OFFSET:-5000000}"    # lands far outside the threshold, in an empty gap
RGS="${RGS:-122880}"                           # row-group size; MUST be a multiple of 8

mkdir -p "$DS"
[[ -x "$DB" ]] || { echo "duckdb not found: $DB" >&2; exit 2; }
(( RGS % 8 == 0 )) || { echo "ROW_GROUP_SIZE $RGS not a multiple of 8 -- refusing" >&2; exit 2; }

metadata_table() {
  for m in $SIZES; do
    f="$DS/size_${m}M.parquet"; [[ -f "$f" ]] || continue
    rows=$(( m * 1000000 )); bytes=$(stat -c %s "$f")
    $DB -noheader -list -c "
      SELECT '$(basename "$f")' || '  rows=$rows' ||
        '  file='       || printf('%.1f', $bytes/1048576.0) || 'MB' ||
        '  bytes/row='  || printf('%.2f', $bytes*1.0/$rows) ||
        '  distinct~'   || (SELECT approx_count_distinct(v)   FROM read_parquet('$f')) ||
        '  groups='     || (SELECT count(*)                   FROM parquet_metadata('$f')) ||
        '  min_group='  || (SELECT min(num_values)            FROM parquet_metadata('$f')) ||
        '  min_group%8='|| (SELECT min(num_values) % 8        FROM parquet_metadata('$f')) ||
        '  enc='        || (SELECT DISTINCT encodings FROM parquet_metadata('$f') LIMIT 1);"
  done
}

if [[ "${1:-}" == "verify" ]]; then metadata_table; exit 0; fi

for m in $SIZES; do
  rows=$(( m * 1000000 )); f="$DS/size_${m}M.parquet"
  if [[ -f "$f" && -z "${FORCE:-}" ]]; then echo "  $f exists -- skipping"; continue; fi
  echo "  writing size_${m}M.parquet ($rows rows) ..."
  $DB -c "
    COPY (SELECT (hash(i) % $CARD)::BIGINT
                 + CASE WHEN i % $OUTLIER_EVERY = 0 THEN $OUTLIER_OFFSET ELSE 0 END AS v
          FROM range($rows) t(i))
    TO '$f' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS);" || { echo "  !! failed on ${m}M" >&2; exit 1; }
done
metadata_table
echo "GATES: min_group%8 must be 0 on EVERY file; enc must be IDENTICAL on all files."
```

### 4.2 Why every constant is what it is

| property | value | why |
|---|---|---|
| cardinality | **1,000,000 distinct, FIXED in absolute terms** | Deliberately HIGH. Real columns containing outliers are high-card (our real sets: 934k, 1.35M). A low-card column lets DuckDB build a small dictionary, turning a *size* sweep into a *dictionary-decode* sweep. |
| distribution | uniform, **stationary** (no drift) | A drifting column invalidates any sampled window and destroys reproducibility. |
| outliers | 0.1% at `+5e6` | Predictable count, and the empty-gap argument of §2.2. |
| row groups | **122,880 — a multiple of 8** | A non-final group with `num_values % 8 != 0` makes our host's ragged guard reject streaming and silently fall back to memcpy — **a code-path change mid-sweep**. Check whether your operator has the same constraint; if it does, this is mandatory. |
| generated from `range()` | not by re-writing an existing parquet | `COPY` from a parquet **preserves the source row-group layout**. That is exactly how one of our real datasets ended up with odd 51449/124849 groups. |
| `hash(i)`, not `i*PRIME` | | A multiplicative step has period exactly `CARD`, which lets Snappy compress the large files unusually well and **drifts bytes/row across the sweep**. |

⚠️ Cardinality is fixed **absolutely**, not as a ratio: at 1M rows the column is ~68% distinct, at
100M ~1%. Fixing the ratio instead would grow the dictionary with N and eventually flip the encoding —
confounding the very thing being measured. State this in the paper; a reviewer will spot it otherwise.

### 4.3 Gates — the run is invalid if these fail

1. `min_group % 8 == 0` on **every** file.
2. `enc` **identical** across all nine files (ours: `PLAIN` throughout).
3. Bonus check we got for free: **bytes/row identical (4.94) at every size** ⇒ no compressibility
   drift, so byte volume is exactly linear in N.

### 4.4 Run it

```bash
python3 bench/size_sweep.py        --csv bench/size_sweep.csv        # fusion OFF (value path)
python3 bench/size_sweep.py --fuse --csv bench/size_sweep_fused.csv  # fusion ON
```

⚠️ **`--fuse` must also lower the fusion row gate.** Ours defaults to 30M rows, so without
`OASIS_IQR_FUSE_MIN_ROWS=0` every point below 30M silently runs the value path *while looking like a
fused measurement*. The harness prints the actual `pass1=` state per point and appends `!NOTFUSED`
if fusion did not engage — copy that check.

⚠️ **Never mix the two curves into one line.** Plot them as two lines.

### 4.5 Our results, for cross-checking shape

Fitted over the linear region (N ≥ 20M):

```
value path (no fusion)   op ≈  3.1 ms + 3.34 ms/Mrow
fused                    op ≈  9.5 ms + 2.20 ms/Mrow
CPU (groupby)            op ≈ 56.5 ms + 3.93 ms/Mrow
```

| rows | FPGA op (ms) | FPGA fused (ms) | CPU op (ms) | speedup (fused) |
|--:|--:|--:|--:|--:|
| 1M | 7.7 | 11.6 | 47.3 | 4.03× |
| 6M | 23.7 | 23.8 | 84.9 | 3.59× |
| 20M | 70.8 | 53.4 | 127.0 | 2.32× |
| 100M | 337.3 | 229.7 | 444.6 | 1.95× |

The two findings to try to reproduce:

* **Fusion costs a fixed amount and saves a per-row amount** — ours: +6.4 ms fixed, −1.14 ms/Mrow,
  break-even **5.6M predicted / 6M measured**. Model and measurement agreeing is what makes it a
  mechanism rather than a fit.
* **`passes` halves exactly**: 127.17 → 63.80 ms at 100M = **1.993×**. Two streamed passes become one.
  That is the single cleanest piece of evidence in the whole study.

**Expect your absolute speedups to be lower than ours**, because your CPU baseline is O(rows) with a
tiny constant while ours pays for a `GROUP BY`. That is not a defect — it is the honest comparison,
and the *shape* is what the joint claim rests on.

---

## 5. TEST 4 — COMPRESSION & ENCODING SENSITIVITY

**Run this before Test 3** if you want, but run it — it is the panel that transfers between the two
operators unchanged, because it characterises the **shared decoder**, not the statistic.

### 5.1 Why this axis is the important one for a joint paper

Our Test 3 measured the phase split: **decode is 62% of FPGA operator time; the second pass is 23%.**
The decoder is not part of either operator — it is the substrate both sit behind. So one measurement
serves both halves of the paper, whereas Tests 1 and 3 must be re-run per operator.

### 5.2 The design problem: encoding and byte volume are normally collinear

A naive 2×2 (PLAIN/dictionary × raw/Snappy) **cannot** separate *"dictionary decoding costs more per
element"* from *"dictionary moved fewer bytes"*, because at ordinary cardinalities dictionary always
means fewer bytes. The fix: **replicate at two cardinality levels chosen so the dictionary's byte
effect changes sign.**

| level | cardinality | PLAIN | dictionary | dictionary's effect |
|---|--:|--:|--:|---|
| `lo` | 10,000 | 8.00 B/row | **2.55** | **shrinks** the file 3.1× |
| `hi` | 1,000,000 | 8.00 B/row | **11.79** | **grows** the file 1.47× |

Cardinality is *not* an axis under test here; it is the lever that de-collinearises the design.
Why dictionary can make a file **bigger**: Parquet dictionaries are **per row group**. At 122,880
rows/group with 1M distinct values, the dictionary holds ~120k entries — essentially a second copy of
the data. Counter-intuitive, legal, and exactly what makes the design identifiable.

### 5.3 Generator

Save as `bench/gen_codec_sweep.sh`. 8 files, ~1.04 GB.

```bash
#!/bin/bash
set -u
DB="${DB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-$HOME/datasets/codecsweep}"
export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"

ROWS="${ROWS:-20000000}"                       # FIXED. 20M == Test 3's `balanced` point.
RANGE="${RANGE:-10000000}"                     # FIXED value range -> thresholds never move
PERM="${PERM:-2654435761}"                     # coprime with RANGE -> bijection (see 4.4)
OUTLIER_EVERY="${OUTLIER_EVERY:-1000}"
OUTLIER_OFFSET="${OUTLIER_OFFSET:-50000000}"
RGS="${RGS:-122880}"
CARD_LO="${CARD_LO:-10000}"                    # dictionary shrinks the file
CARD_HI="${CARD_HI:-1000000}"                  # dictionary GROWS the file (pathological but legal)
DICT_OFF=0
DICT_ON="${DICT_ON:-104857600}"                # 100 MiB

MANIFEST="$DS/manifest.csv"; mkdir -p "$DS"
levels() { echo "lo:$CARD_LO hi:$CARD_HI"; }

write_manifest() {
  echo "level,card,enc_intent,compression,file,rows,bytes,bytes_per_row,encodings,groups,min_group,min_group_mod8,digest_count,digest_sum,digest_hash,distinct" > "$MANIFEST"
  for lv in $(levels); do
    name="${lv%%:*}"; card="${lv##*:}"
    for enc in plain dict; do for comp in uncompressed snappy; do
      f="$DS/codec_${name}_${enc}_${comp}.parquet"; [[ -f "$f" ]] || continue
      bytes=$(stat -c %s "$f"); bpr=$(awk "BEGIN{printf \"%.2f\", $bytes/$ROWS}")
      # digest_* = ORDER-INDEPENDENT fingerprint of the value multiset. All four files at a level
      # must agree, or "only the representation changed" is FALSE and the sweep is invalid.
      row=$($DB -noheader -list -c "
        SELECT (SELECT string_agg(DISTINCT encodings,'+') FROM parquet_metadata('$f')) || ',' ||
               (SELECT count(*)            FROM parquet_metadata('$f')) || ',' ||
               (SELECT min(num_values)     FROM parquet_metadata('$f')) || ',' ||
               (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) || ',' ||
               (SELECT count(*)                     FROM read_parquet('$f')) || ',' ||
               (SELECT sum(v)::HUGEINT              FROM read_parquet('$f')) || ',' ||
               (SELECT sum(hash(v))::HUGEINT        FROM read_parquet('$f')) || ',' ||
               (SELECT approx_count_distinct(v)     FROM read_parquet('$f'));") || row=",,,,,,,"
      echo "$name,$card,$enc,$comp,$f,$ROWS,$bytes,$bpr,$row" >> "$MANIFEST"
    done; done
  done
  column -s, -t "$MANIFEST"
}

check_gates() {
  python3 - "$MANIFEST" <<'PY'
import csv, sys, itertools
rows = list(csv.DictReader(open(sys.argv[1])))
ok = True
def bad(m):
    global ok; ok = False; print(f"  FAIL  {m}")
if not rows: bad("manifest empty")
for r in rows:
    encs = (r["encodings"] or "").upper()
    if (r["enc_intent"] == "dict") != ("DICTIONARY" in encs):
        bad(f"{r['file'].split('/')[-1]}: asked {r['enc_intent']}, got [{encs}]")
    if r["min_group_mod8"] != "0":
        bad(f"{r['file'].split('/')[-1]}: min_group%8={r['min_group_mod8']} (streaming rejected)")
    if r["compression"] not in ("uncompressed", "snappy"):
        bad(f"{r['file'].split('/')[-1]}: compression outside the supported RAW/SNAPPY envelope")
# THE decisive gate: within a level, all four files must be the same numbers.
for lv, grp in itertools.groupby(sorted(rows, key=lambda r: r["level"]), key=lambda r: r["level"]):
    grp = list(grp)
    for key in ("digest_count", "digest_sum", "digest_hash"):
        if len({r[key] for r in grp}) != 1:
            bad(f"level {lv}: {key} differs -> the files do NOT hold the same column, so the "
                f"second-pass control is meaningless and the sweep is INVALID")
    if len(grp) != 4: bad(f"level {lv}: expected 4 files, found {len(grp)}")
print("  ALL GATES PASS" if ok else "  >>> GATES FAILED -- do not run the benchmark <<<")
sys.exit(0 if ok else 1)
PY
}

if [[ "${1:-}" == "verify" ]]; then write_manifest; check_gates; exit $?; fi

for lv in $(levels); do
  name="${lv%%:*}"; card="${lv##*:}"
  for enc in plain dict; do
    [[ "$enc" == plain ]] && dl=$DICT_OFF || dl=$DICT_ON
    for comp in uncompressed snappy; do
      [[ "$comp" == uncompressed ]] && COMP=UNCOMPRESSED || COMP=SNAPPY
      f="$DS/codec_${name}_${enc}_${comp}.parquet"
      [[ -f "$f" && -z "${FORCE:-}" ]] && { echo "  $(basename "$f") exists -- skipping"; continue; }
      echo "  writing $(basename "$f")  (card=$card, DICTIONARY_SIZE_LIMIT=$dl, $COMP) ..."
      # Write to .partial and rename on success: an interrupted write otherwise leaves a TRUNCATED
      # parquet that the "exists -> skip" branch silently accepts on the next run.
      tmp="$f.partial"; rm -f "$tmp"
      $DB -c "
        COPY (SELECT (((hash(i) % $card) * $PERM) % $RANGE)::BIGINT
                     + CASE WHEN i % $OUTLIER_EVERY = 0 THEN $OUTLIER_OFFSET ELSE 0 END AS v
              FROM range($ROWS) t(i))
        TO '$tmp' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS,
                   DICTIONARY_SIZE_LIMIT $dl, COMPRESSION $COMP);" \
        && mv -f "$tmp" "$f" || { echo "  !! failed at $f" >&2; rm -f "$tmp"; exit 1; }
    done
  done
done
write_manifest; check_gates
```

### 5.4 Two constants that are not arbitrary

**`DICTIONARY_SIZE_LIMIT` is the only lever DuckDB exposes over encoding.** `0` forces PLAIN;
100 MiB forces the writer to keep building a dictionary instead of giving up at its ~128 KB default
(which flips dictionary→PLAIN somewhere around 20–30k distinct per row group — measured).

**`PERM = 2654435761` is a multiplicative permutation, and it matters.** It is odd and not divisible
by 5, so `gcd(PERM, 10^7) = 1` and `level·PERM mod 10^7` is a **bijection**: exactly CARD levels with
the low bits fully spread. Our first attempt used `level * (RANGE/CARD)`, a highly composite step that
leaves trailing zero bits on every value — which imbalanced the C++ baseline's **radix** aggregation
by an amount that *varied with cardinality*, manufacturing a smooth monotonic CPU decline that looked
exactly like a real finding. If your baseline does any radix/hash partitioning, you are exposed to the
same trap. **Use the permutation.**

### 5.5 The hardware envelope — state it in the paper as a result, not a caveat

| layer | supported by our decoder | source |
|---|---|---|
| compression | **RAW, SNAPPY only** — no ZSTD/GZIP/LZ4/Brotli | `parcore/software/parcore/configuration.cpp:23` |
| encoding | **PLAIN, PLAIN_DICTIONARY, RLE_DICTIONARY**; DataPage **V2 unsupported** | `parcore/hardware/src/hdl/page_header_parser.sv:194,238` |
| dictionary size | `ID_BITS=19` → ≤524,288 entries / ~2 MiB per **row group** | `parcore/hardware/src/hdl/common.sv:15-31` |

So `DELTA_BINARY_PACKED` and `BYTE_STREAM_SPLIT` — what modern writers actually pick for ints and
floats — are out of scope, as is any ZSTD file. **This applies identically to the z-score operator**,
since it is the same decoder. Verify the line numbers still hold in your tree and cite them.

**RLE/bit-packing is deliberately not an arm**: on this path it is not a standalone data-page
encoding, only the index encoding *inside* a dictionary page. Do not add it as a fifth arm.

⚠️ Raising `ROW_GROUP_SIZE` above 122,880 would push the per-group dictionary past the hardware bound
at `hi`. It is inside the limit by only ~2×.

### 5.6 Our results

| level | enc | compression | B/row | FPGA op | CPU op | **speedup** | F decode | **F pass 2** |
|---|---|---|--:|--:|--:|--:|--:|--:|
| lo | plain | uncompressed | 8.00 | 55.6 | 62.1 | **1.12×** | 35.3 | 12.8 |
| lo | plain | snappy | 4.71 | 51.4 | 72.1 | **1.40×** | 31.6 | 12.8 |
| lo | dict | uncompressed | 2.55 | 31.9 | 64.5 | **2.02×** | 14.2 | 12.8 |
| lo | dict | snappy | 2.32 | 31.6 | 67.8 | **2.14×** | 14.0 | 12.8 |
| hi | plain | uncompressed | 8.00 | 55.4 | 116.5 | **2.10×** | 35.4 | 12.8 |
| hi | plain | snappy | 5.21 | 53.3 | 125.7 | **2.36×** | 32.7 | 12.8 |
| hi | dict | uncompressed | 11.79 | 53.0 | 131.1 | **2.47×** | 32.7 | 12.8 |
| hi | dict | snappy | 9.16 | 57.4 | 133.6 | **2.33×** | 37.0 | 12.8 |

The three results:

1. **The control held perfectly.** Second-pass time is **12.8 ms at all eight points** (spread 0.2–0.3%)
   while decode moves 14.0 → 37.0 ms, a factor of 2.6. Since the values are provably identical within
   a level, this is a measurement with a built-in control, not an interpretation: **all variation in
   FPGA operator time is in the decode window.**
2. **On PLAIN data the two arms move in opposite directions** when Snappy is switched on — the FPGA
   fetches fewer bytes and gets 4–8% faster, the host pays decompression and gets 8–16% slower.
   Mechanism measured on both halves rather than assumed.
3. **The row to quote is `hi`/dictionary/uncompressed.** The dictionary makes the file **47% larger**,
   and the FPGA *still* got 4.3% faster while the CPU got 12.5% slower. **Even a badly chosen encoding
   tilts the comparison toward the FPGA.** This contradicted our own pre-registered prediction — say
   so; it is much stronger evidence than a confirmed guess.

**Representation alone moves the headline by 2.2× (1.12× → 2.47×) on the same 20 million numbers.**
Quote the 1.12× floor too — it is the honest worst case, and its existence is what makes the
methodology point ("always state the encoding") land.

### 5.7 If you fit a model, the level term is mandatory

`t = f0 + a·(B/row) + b·[snappy] + c·[dict] + d·[hi level]`, 8 points, 4 dof. Two traps we hit:

* **Omitting `[hi]` produced a confidently wrong answer.** rms went 2.31 → 19.33 ms and the Snappy
  coefficient 9.12 → 24.15 ms, because the model absorbed a ~55 ms cardinality difference into the
  byte slope. Make the term structural, and have the fit **return nothing** if only one level is
  present (`numpy.linalg.matrix_rank(A) < 5`) rather than emit a rank-deficient answer.
* **The dictionary coefficient is NOT a per-element price.** The model is linear in bytes/**row**, but
  most of a dictionary file's volume is the dictionary **page**, read once per row group (~160 of
  236 MB at `hi`). A negative coefficient there is mis-specification, not a measured speedup. Print no
  verdict on it; read the paired plain-vs-dict rows instead.

Our corrected fits (n=8, level term included):

```
FPGA operator   33.18 + 2.71·B/row + 5.50·[snappy] − 10.38·[dict] +  0.94·[hi]   rms 2.03
FPGA decode     15.34 + 2.42·B/row + 4.83·[snappy] −  9.21·[dict] +  0.65·[hi]   rms 1.88
CPU  operator   53.84 + 1.28·B/row + 9.12·[snappy] +  5.18·[dict] + 54.78·[hi]   rms 2.31
```

`[hi]`: **+0.94 ms for the FPGA, +54.78 ms for the CPU.** For you, *both* should be ~0 — which is
itself a clean, publishable difference between the two operators and worth one sentence in the paper.

---

## 6. TEST 3 — CORE-COUNT SWEEP (1 → 32 host threads)

Tests 1 and 4 both ran at `threads=32`, so they only ever answer *"is the FPGA faster than 32 CPU
cores"*. This one answers the question the thesis actually rests on: **how much host CPU does the
offloaded path give back?**

### 6.1 Datasets — reuse, generate nothing new

* **primary (`balanced`)** = Test 1's `size_20M.parquet`. In the flat part of Test 1's curve, so fixed
  startup is not what is being measured, yet a 1-thread CPU run still finishes in ~0.75 s. Fusion
  engages **by policy**, not by override — the configuration that would actually ship.
* **control (`knee`)** = a 10M-row file at cardinality 100,000. If you skipped our cardinality sweep,
  generate the single file with the Test 4 recipe:

```bash
$DB -c "COPY (SELECT (((hash(i) % 100000) * 2654435761) % 10000000)::BIGINT
              + CASE WHEN i % 1000 = 0 THEN 50000000 ELSE 0 END AS v
        FROM range(10000000) t(i))
        TO '$HOME/datasets/knee/card_100000.parquet'
        (FORMAT PARQUET, ROW_GROUP_SIZE 122880, DICTIONARY_SIZE_LIMIT 0, COMPRESSION SNAPPY);"
```

If the conclusion survives on the control, it is architectural rather than a dataset artefact.

### 6.2 ⚠️ `PRAGMA threads` alone is NOT sufficient — this cost us a design iteration

Three regions of our host code size themselves from `std::thread::hardware_concurrency()` and ignore
the pragma entirely (window-sample decode, flag copy-out, the persistent thread pool). And measured on
this host, **glibc 2.35's `hardware_concurrency()` is not affinity-aware — it reports 64 even under
`taskset -c 0`.**

**Grep your own host code for `hardware_concurrency` before running this test.** If it appears, every
point must set `PRAGMA threads=N` **and** pin with `taskset`. Pinning does not shrink those pools; it
**confines** their work to N cores, which is the resource question being asked.

Two consequences to state in the paper rather than hide:

* At low N those fixed-size pools are oversubscribed on few cores and pay scheduling overhead the CPU
  baseline does not. **The bias runs against the FPGA arm, so the results are conservative.**
* A `--no-taskset` run reproduces the pragma-only measurement and isolates how much FPGA-arm host cost
  lives outside DuckDB's scheduler. Worth one run; not the headline. (We never got to it.)

### 6.3 ⚠️ Do not assume CPU ids are `0..N-1`

Derive the CPU list from `lscpu -p`: **one CPU per physical core, the card's NUMA node first, SMT
siblings last.** On our build node a naive `0-3` spans **four** NUMA nodes (CPU 0→socket 0, CPU 1→
socket 1, …), which would make small-N points measure interconnect latency rather than core count.

```python
def cpu_topology():
    """[(cpu, core, socket, node)] from lscpu -p; [] if unavailable."""
    out = subprocess.run(["lscpu", "-p=CPU,CORE,SOCKET,NODE"],
                         capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        if line.startswith("#") or not line.strip(): continue
        try: rows.append(tuple(int(x) if x else 0 for x in line.split(",")[:4]))
        except ValueError: pass
    return rows

def fpga_numa_node():
    """NUMA node of the Xilinx card, so small core counts sit next to the DMA engine."""
    ids = subprocess.run(["lspci", "-D", "-d", "10ee:"], capture_output=True, text=True).stdout
    for line in ids.splitlines():
        p = f"/sys/bus/pci/devices/{line.split()[0]}/numa_node"
        if os.path.exists(p):
            n = int(open(p).read().strip())
            if n >= 0: return n
    return None

def pick_cpus(n, topo, prefer_node=None):
    if not topo: return f"0-{n-1}" if n > 1 else "0"
    seen, first, sibling = set(), [], []
    def key(r):
        cpu, core, sock, node = r
        return (0 if (prefer_node is not None and node == prefer_node) else 1, node, core, cpu)
    for cpu, core, sock, node in sorted(topo, key=key):
        (first if (node, core) not in seen else sibling).append(cpu)
        seen.add((node, core))
    return ",".join(str(c) for c in (first + sibling)[:n])
```

On a single-NUMA-node run node this degenerates to `0..N-1` and the hazard never fires — but keep the
guard, and **print the core plan in the log**. Pinning is part of the experimental setup, so it has to
be visible, not implied.

### 6.4 The internal check — this is what makes the test trustworthy

**The second-pass time must be FLAT across thread counts.** Same file, same bytes, same encoding at
every point, so the FPGA has identical work to do. If it moves, the measurement is contaminated —
most likely by DMA starvation at low thread counts, which is a real effect but a *different* one and
must not be folded into a core-count-independence claim. Ours: **0.1% / 0.5% spread.** Have the
harness compute the spread and print `FLAT (as required)` or a loud refusal.

Also cross-check `threads=32` against your own Test 1 20M fused row. Ours reproduced within 0.7%
(FPGA) and 4.4% (CPU) across sessions. Widen the tolerance ~5 points when comparing a pinned run
against Test 1's unpinned one — removing SMT siblings is a real difference, not drift.

### 6.5 Our results (`balanced`, 20M rows, fused by policy)

| threads | FPGA op | CPU op | ratio | F decode | F pass 2 | FPGA cpu-s | CPU cpu-s | offload |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 54.8 | 745.4 | **13.61×** | 33.9 | 12.8 | 0.053 | 0.631 | 11.90× |
| 2 | 54.9 | 385.1 | 7.01× | 34.1 | 12.8 | 0.075 | 0.619 | 8.24× |
| 4 | 53.3 | 244.4 | 4.59× | 33.6 | 12.8 | 0.068 | 0.647 | 9.45× |
| 8 | 53.9 | 190.9 | 3.54× | 34.2 | 12.8 | 0.077 | 0.686 | 8.86× |
| 16 | 54.4 | 157.3 | 2.89× | 34.4 | 12.8 | 0.083 | 0.758 | 9.12× |
| 32 | 53.8 | 129.5 | **2.41×** | 33.8 | 12.8 | 0.105 | 1.133 | 10.82× |

**Both FPGA phases are flat 1→32 (1.00×), including decode**, while the CPU scales 5.76×.

> **A correction worth inheriting.** We wrote the harness expecting `decode` to *scale*, assuming it
> was host work. It is not — the decode call submits row groups to the **FPGA's** parquet decoders and
> streams decoded beats back; the host only orchestrates fetch/submit/copy. So the flatness covers the
> whole pipeline, not just the statistics operator. Check which side of the boundary your `decode`
> timer sits on **before** interpreting its curve.

Amdahl fit `T(n) = S + P/n` on the CPU arm: `103.9 ms + 624.3/n`, serial fraction 14.3%, parallel
efficiency collapsing from 96.8% at n=2 to **18.0%** at n=32.

**Lead with the measured statement, not the extrapolation:** the CPU baseline on **32 cores**
(129.5 ms) is still **2.36× slower than the FPGA on one core** (54.8 ms). No model needed. The fit is
then the supporting argument for *why more cores would not close it* — the serial floor alone is 1.9×
the FPGA's one-core time. Quote S as "≈100 ms", not to 0.1 ms: residuals reach 8% at low n.

### 6.6 How to phrase the offload claim honestly

`cpu-seconds / wall` = cores genuinely busy. Ours at 32 threads: **1.95 for the FPGA path vs 8.75 for
the baseline.**

> **"10.8× fewer CPU-seconds and 4.5× fewer busy cores."**

That is overwhelming *and* defensible. **"Zero host CPU" is false** — the FPGA path costs about one
core of orchestration at 1 thread and two at 32 — and a reviewer will catch it. Likewise avoid leading
with the 13.61× at n=1: it compares against a single-threaded baseline nobody would deploy.

One more finding that is actionable rather than merely observed: the FPGA arm's CPU-seconds **double**
from 1 → 32 threads for a **1.8%** wall-clock gain. At `threads=1` the FPGA path runs within 2% of
full speed while leaving **31 of 32 cores free**. ⇒ **the operator should cap the thread count it
requests.** Check whether the same is true of yours; if it is, that is a joint recommendation.

---

## 7. TEST 5 — DISTRIBUTION SHAPE / SKEW (a control, not a panel)

> ✅ **This does not produce a figure.** Both arms come out flat. Its job is to *defend* Tests 1/3/4,
> all of which run on uniform synthetic data, against the obvious objection: *"real data is skewed, so
> your numbers don't transfer."* Budget two sentences and a small table, not a panel.

Run on **alveo-u55c-07, 2026-08-14**, 20M rows, fused by policy, `threads=32`. Full write-up in
`micro_bench.md` §Test 5.

### 7.1 What varies, and what must be pinned

The axis is the **shape** of the value distribution: Fisher skewness **0.00 → 3.44**, excess kurtosis
**−1.2 → 12.7**. Six files. Everything else is fixed by construction:

| property | value | how |
|---|---|---|
| rows | 20,000,000 | same `i`-range everywhere |
| cardinality | **1,020,000 distinct EXACTLY** | `r = (i·PERM) mod N` is a bijection; `mod CARD` gives every level exactly `N/CARD = 20` rows. **Not `hash()`** — hash leaves coupon-collector holes and the distinct count drifts with the sweep |
| frequency profile | perfectly flat over levels | ⇒ the skew lives entirely in the value **spacing**, i.e. a genuine sample from a continuous right-skewed law, not a frequency-imbalance artefact |
| bytes/row | **exactly 8.00** | PLAIN + UNCOMPRESSED. All six files come out byte-identical in size — that *is* the proof |
| row groups | 163, min 93,440, all `%8 == 0` | streaming never rejected |
| quantisation resolution | ~579 bins per IQR everywhere | see §7.2 |

Value construction, where `a` is the skew knob and **measured skewness is the reported axis**:

```
level = ((i·PERM) mod N) mod CARD          PERM = 2654435761
u     = (level + 1) / CARD
w(u)  = u                          if a = 0        (uniform)
      = (exp(a·u) − 1)/(exp(a) − 1) otherwise      (right-skewed)
V     = level + round(9e6 · w(u))          strictly increasing ⇒ injective ⇒ cardinality survives
value = M · V + (planted outlier offset)   M = per-point integer multiplier, see §7.2
```

The `+ level` term is what guarantees injectivity. Without it `round()` collapses thousands of low
levels onto 0 at high `a` and the cardinality control dies silently.

Sanity check that the construction is right: at `a = 0` the file measures skewness **0.0** and excess
kurtosis **−1.2** — the exact theoretical value for a uniform distribution.

### 7.2 ⚠️ Two confounds that will wreck this sweep if you skip them

**1. Power-of-two bin width (only if your operator quantises).** Our window is `[Q1−2·IQR, Q3+2·IQR]`
= exactly 5·IQR, and the bin width is rounded **up to a power of two** because the hardware shifts
instead of dividing. Writing `x = 5·IQR/4096`:

```
bins_per_IQR = (4096/5)·x / 2^ceil(log2 x),   with  x/2^ceil(log2 x) ∈ (0.5, 1]
             ⇒ sawtooths over (409.6, 819.2]
```

Skew moves the IQR continuously, so a naive sweep walks through those octave boundaries and produces a
**2× accuracy sawtooth that has nothing to do with distribution shape**. Fix: scale each point by an
integer multiplier so `bins_per_IQR` lands on **579 ± 0.4%** — the *geometric middle* of the range,
deliberately **not** the top. At 819.2 the quantity `5·IQR/4096` is exactly a power of two, so half of
all perturbations tip it into the next octave and halve the resolution — and the perturbation source is
window-sample error in Q3, which **grows with skew**, i.e. the swept axis is what pushes a cliff-edge
point over. *A z-score operator with no quantisation step can skip this entirely — but check first.*

**2. Outlier placement collapsing onto whole levels.** `N = 20,000,000 = 1000 × 20,000`, so selecting
outliers with `i % 1000 == 0` makes `(i·PERM) mod N` a multiple of 1000, and `mod CARD` leaves **only
multiples of 1000** — 1,000 whole levels (all 20 rows each), which then vanish from the base. The
distinct count still read a plausible 1,000,000 (999,000 base + 1,000 outlier), which is how it nearly
passed unnoticed. Same trap as the withdrawn Test 2 v1 generator. Fix: select on the permuted index —
`r % 50 == 0 AND r < CARD` takes **one row from each of 20,000 levels** spaced 50 apart.

### 7.3 The gate necessarily weakens, and that is fine

Planted outliers (0.1%, at 5× the maximum value) sit in an empty gap and are quantisation-proof, as in
every other test. But **any right-skewed distribution's own upper tail eventually crosses
`Q3 + 1.5·IQR`** — a property of IQR on heavy tails, not a flaw. Only the uniform point keeps a purely
analytic expected count.

So the generator computes the expected count **from the written file using the CPU baseline's own
quantile rule**, and the harness gate becomes three-way: **FPGA vs CPU vs expected**. A CPU deviation
is a *definition* mismatch; an FPGA-only deviation is *quantisation*. Reporting one without the other
cannot tell those apart. (Ours: CPU read `+0` at all 6 points in both runs.)

*This part is IQR-specific* — a z-score fence at `mean ± kσ` is not a quantile and has no binning
error. Your equivalent question is whether the tail inflates `mean` and `σ` enough to move your fence,
which is a **semantics** result rather than an accuracy one (see §7.6).

### 7.4 🔁 RUN IT TWICE — the single most important instruction in this section

Within one run our FPGA spread across skewness was **4.7–4.8%**, *above* the project's documented
1–3% run-to-run noise. On one run alone, "flat" is an eyeball claim a reviewer can push back on.

The repeat settles it, because the **same-point repeat difference turned out LARGER than the
across-skew spread**:

| | max repeat \|Δ\| on one point | across-skew spread within a run |
|---|--:|--:|
| FPGA op | **6.6%** (a=12: 57.6 → 53.8 ms) | 4.7–4.8% |
| CPU op | **7.0%** (a=8: 125.1 → 116.3 ms) | 6.7–9.3% |

The **rank order also completely reshuffled** — `a=12` was the slowest point in run 1 and the
second-fastest in run 2. A real effect does not permute its own ordering between sessions.

Pooling the two runs halves the residual to **2.66%**, back inside the noise band, and the
least-squares slope against skewness is **0.26 ms per unit = 0.91 ms (1.6%) over the whole range**,
non-monotone. There is no trend.

### 7.5 Our results

| skewness | 0.00 | 1.14 | 1.96 | 2.57 | 3.04 | 3.44 |
|---|--:|--:|--:|--:|--:|--:|
| FPGA operator (ms) | 54.6 | 55.2 | 56.0 | 55.7 | 55.3 | 55.6 |
| CPU operator (ms) | 118.0 | 121.4 | 120.7 | 117.2 | 119.6 | 123.1 |
| speedup | 2.16× | 2.20× | 2.16× | 2.10× | 2.16× | 2.22× |

(pooled over both runs; second-pass phase was 12.8 ms at all 12 measurements — the internal check)

**The sentence for the paper:**

> Over Fisher skewness 0.00 → 3.44 and excess kurtosis −1.2 → 12.7, with rows, cardinality, encoding,
> byte volume and row-group geometry held fixed, FPGA operator time varies by 2.7% and the speedup
> stays in 2.10–2.22×.

Both arms are flat for *different* reasons, and saying so is what makes it an argument rather than an
observation: the FPGA histograms every row identically regardless of value placement, while a `GROUP BY`
does N probes over a fixed-size table regardless of value spacing. Once bytes and cardinality are
pinned, **neither arm has a mechanism for shape to act on.**

On accuracy, one clause is enough — *"flag counts agree with exact arithmetic to within 0.02% of rows
at every point"* — but do not omit it. This is an approximate-quantile design and a reviewer will ask;
burying it looks worse than the number is. Ours was additionally **bit-identical across two independent
sessions**, which on a bitstream with 1 ps of hold margin is direct evidence the deviations are pure
quantisation rather than silicon flakiness.

### 7.6 💡 The one skew figure with an actual trend — and it is the JOINT one

Not a performance figure. `mean ± kσ` is **not robust**: under right-skew the tail inflates both the
mean and σ, so the z-score fence drifts with the tail while the quartile-based IQR fence does not. On
**identical data**, the two operators' flag counts diverge as skewness grows.

That is the figure answering *"why does this system offer both operators?"* — a selection-guidance
result that belongs to the joint paper rather than to either half. It is pure SQL over the six files,
needs no card, and needs neither codebase. **Not yet measured on our side.** If you want it, we have
the datasets ready.

### 7.7 Reproduce

```bash
cd ~/oasis
python3 bench/gen_skew_sweep.py --dry-run     # plan only: quartiles, multipliers, fences. No files.
python3 bench/gen_skew_sweep.py               # 6 files, 740 MB. STOP if any gate fails.
python3 bench/gen_skew_sweep.py verify

python3 bench/skew_sweep.py --csv bench/skew_sweep.csv
python3 bench/skew_sweep.py --csv bench/skew_sweep_rep2.csv    # THE REPEAT -- required, see §7.4
```

---

## 8. The shared harness

All three tests use one runner, so "operator time" means the same thing everywhere. Adapt the
`OPERATOR ADAPTATION` block from your §1.1 table and nothing else.

```python
# ---------------- OPERATOR ADAPTATION -- the only part that differs between IQR and z-score -------
DUCKDB     = os.path.expanduser("~/oasis/extension/build/release/duckdb")
FPGA_FN    = "zscore_flags_only"          # (path, col) -> is_outlier
CPU_FN     = "zscore_cpu_flags"           # the fair CPU baseline
TIMING_ENV = "OASIS_ZSCORE_TIMING"
TAG        = "zscore"                     # the [tag] prefix in the timing lines
FUSE_ENV   = dict(stream="OASIS_ZSCORE_STREAM", fuse="OASIS_ZSCORE_FUSE",
                  window="OASIS_ZSCORE_WINDOW_FPGA", min_rows="OASIS_ZSCORE_FUSE_MIN_ROWS")
# --------------------------------------------------------------------------------------------------

RUNS, AVG_LAST = 7, 3       # the protocol: 7 iterations, mean of the final 3

REAL   = re.compile(r"Run Time \(s\): real ([\d.]+) user ([\d.]+) sys ([\d.]+)")
HEAVY  = re.compile(rf"\[{TAG}(?:-cpu\w*)?\]\s+heavy\s+([\d.]+) ms")
DECODE = re.compile(rf"\[{TAG}\]\s+decode\s+([\d.]+) ms")
PASSES = re.compile(r"passes\s+([\d.]+)")
COUNT  = re.compile(r"^(\d+)$", re.M)     # bare result line (.mode csv + .headers off)
PASS1  = re.compile(r"pass1=(\w+)")       # did fusion ACTUALLY engage

def mean_last(xs, k=AVG_LAST):
    return sum(xs[-k:]) / len(xs[-k:]) if xs else float("nan")

def stmt(arm, path, col):
    src = f"{FPGA_FN}('{path}','{col}')" if arm == "fpga" else f"{CPU_FN}('{path}','{col}')"
    # FILTER, not a bare count(*), so the flag column is genuinely read and cannot be projected away.
    return f"SELECT count(*) FILTER (WHERE is_outlier) FROM {src};"

def _run_duckdb(sql, env, timeout=None, cmd_prefix=()):
    """SIGTERM-FIRST, with a 60 s grace period. A SIGKILL'd DuckDB leaves Coyote's pinned pages and
    any in-flight DMA behind, and Coyote cannot reset user logic between host processes -- that is
    the path that has historically required a NODE REBOOT. SIGKILL is last resort only."""
    p = subprocess.Popen(list(cmd_prefix) + [DUCKDB], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         env=env, start_new_session=True)
    try:
        out, err = p.communicate(sql, timeout=timeout); return out + err
    except subprocess.TimeoutExpired:
        print(f"    !! TIMEOUT after {timeout}s -- SIGTERM (never SIGKILL first)", file=sys.stderr)
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        try:
            out, err = p.communicate(timeout=60); return out + err
        except subprocess.TimeoutExpired:
            print("    !! SIGTERM ignored 60 s -- escalating. THE CARD MAY BE IN A BAD STATE: "
                  "re-run the correctness gate before trusting any later number.", file=sys.stderr)
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            out, err = p.communicate(); return out + err

def run_arm(arm, path, fuse, fuse_min_rows=0, threads=32, timeout=None, col="v", cpu_list=None):
    """7 iterations in ONE session; caller averages the last 3. Fresh process every call, so
    `PRAGMA threads` is never mutated mid-session."""
    body = stmt(arm, path, col)
    sql  = f"PRAGMA threads={threads};\n.mode csv\n.headers off\n.timer on\n" + (body + "\n") * RUNS

    env = dict(os.environ)
    env[TIMING_ENV] = "1"
    env["LD_LIBRARY_PATH"] = os.path.expanduser("~/opt/lib") + ":" + env.get("LD_LIBRARY_PATH", "")
    for k in FUSE_ENV.values():          # uniform code path unless explicitly asked otherwise
        env.pop(k, None)
    if fuse:
        env[FUSE_ENV["stream"]] = env[FUSE_ENV["fuse"]] = env[FUSE_ENV["window"]] = "1"
        # MUST lower the row gate too, or fusion silently does NOT engage below the default and every
        # small-N point reports the value path while LOOKING like a fused measurement.
        env[FUSE_ENV["min_rows"]] = str(fuse_min_rows)

    out = _run_duckdb(sql, env, timeout, ["taskset", "-c", cpu_list] if cpu_list else [])

    reals = [float(m.group(1)) for m in REAL.finditer(out)]
    if len(reals) < RUNS:
        print(f"    !! {arm}: expected {RUNS} timed runs, got {len(reals)}", file=sys.stderr)
        if not reals:
            print(out[-900:], file=sys.stderr); return None
    return dict(real=reals,
                user  =[float(m.group(2)) for m in REAL.finditer(out)],
                heavy =[float(m.group(1)) for m in HEAVY.finditer(out)],
                counts=[int(m.group(1))   for m in COUNT.finditer(out)],
                decode=[float(m.group(1)) for m in DECODE.finditer(out)],
                passes=[float(m.group(1)) for m in PASSES.finditer(out)],
                pass1 ="/".join(sorted({m.group(1) for m in PASS1.finditer(out)})) or "-")
```

Per point, the driver then does:

```python
with open(path, "rb") as fh:                    # warm the page cache BEFORE timing
    while fh.read(1 << 24): pass

f  = run_arm("fpga", path, fuse=True,  fuse_min_rows=6_000_000, threads=t, timeout=600, cpu_list=cpus)
c  = run_arm("cpp",  path, fuse=True,  fuse_min_rows=6_000_000, threads=t, timeout=600, cpu_list=cpus)

f_op, c_op = mean_last(f["heavy"]), mean_last(c["heavy"])
flags_ok   = all(x == expect for x in f["counts"][-RUNS:])          # ALL 7, not just one
if fusing and "fused" not in f["pass1"]: mark_row("!NOTFUSED")      # loud, not a footnote
```

---

## 9. Failure modes we already paid for — read before debugging anything

| symptom | cause | fix |
|---|---|---|
| A beautiful monotonic CPU trend that turns out to be fake | Value generator used a **highly composite step**, leaving trailing zero bits and imbalancing the baseline's radix partitioning by an amount varying with the swept variable | Use the multiplicative permutation (§5.4) |
| A 1.7× step in the middle of a sweep | Parquet **flipped dictionary→PLAIN** when the dictionary page passed ~128 KB. An *encoding* effect wearing another variable's costume | Pin encoding with `DICTIONARY_SIZE_LIMIT`, and pin bytes/row with `COMPRESSION UNCOMPRESSED`, whenever the swept variable is not encoding itself |
| A "fused" sweep whose small-N points quietly ran the value path | `fuse_min_rows` gate not lowered | Set it explicitly **and** parse `pass1=`; append `!NOTFUSED` loudly |
| Streaming silently falls back to memcpy mid-sweep | A non-final row group with `num_values % 8 != 0` trips the ragged guard | `ROW_GROUP_SIZE` a multiple of 8, gated per file |
| A truncated parquet silently accepted as complete | Interrupted write + an `exists → skip` branch | Write `$f.partial`, `mv` on success only |
| `libcoyote.so: cannot open shared object file` | Generator relied on the invoking shell's `LD_LIBRARY_PATH` | Export it inside the script |
| `error reading input file: Stale file handle` mid-run | **A file was edited while bash was executing it over NFS.** (Self-inflicted, twice.) | Never edit a running script; re-run after editing |
| Everything looks fine but numbers wander run to run | Marginal **hold** timing on silicon — bit-exact in simulation, wrong on the card | Per-iteration correctness on all 7 runs is the detector; suspect hold, not setup |
| Small-N points in Test 3 measuring interconnect, not cores | `taskset -c 0-3` spanning four NUMA nodes | `pick_cpus()` (§6.3), and print the plan |
| Host code ignores `PRAGMA threads` | `std::thread::hardware_concurrency()`, not affinity-aware on glibc 2.35 | `taskset` in addition to the pragma; state the conservative bias |
| A 2× accuracy sawtooth across a sweep that has nothing to do with the swept variable | Bin width rounded **up to a power of two**, so resolution sawtooths over a 2× range as the IQR moves | Normalise resolution per point with an integer multiplier; target the **geometric middle** of the range, never the edge (§7.2) |
| Outlier rows landing on whole levels instead of scattered rows, while the distinct count still looks right | Arithmetic coincidence between `i % K == 0` and the modulus chain (`N = K × M`) | Select outliers on the **permuted** index, not on `i` (§7.2) |
| A flat curve you cannot defend as flat | One measurement per point: the across-axis spread sits above the run-to-run noise | **Run the sweep twice** and compare same-point repeat spread against across-axis spread (§7.4) |
| Real data taking a different code path than every synthetic test | Real Parquet has ragged row groups (`num_values % 8 != 0`); synthetic ones are built to avoid it | Check `min_group % 8` per file and state which path each row used (§3.2) |

---

## 10. Deliverables — what to hand back so the two operators plot together

Emit one CSV per test with **these exact column names**, so both halves of the paper share plotting
code and the joint figures can be drawn without reconciliation:

```
# Test 0  -- from medians.py; end-to-end SECONDS, medians of 15 (NOT the microbench protocol)
dataset, rows, column, distinct, fpga_e2e_s, cpp_e2e_s, sql_e2e_s, fpga_over_cpp, cpp_over_sql,
fpga_cpu_seconds, cpp_cpu_seconds, min_group_mod8, encodings, path_used

# Test 1  size_sweep{,_fused}.csv
rows, fpga_op_ms, cpu_op_ms, speedup, fpga_decode_ms, fpga_passes_ms,
fpga_cpu_seconds, cpu_cpu_seconds, fpga_e2e_s, cpu_e2e_s, pass1, fused, flags_ok

# Test 3  thread_sweep_{balanced,knee}.csv
threads, rows, dataset, fpga_op_ms, cpu_op_ms, speedup, fpga_decode_ms, fpga_passes_ms,
fpga_cpu_seconds, cpu_cpu_seconds, offload_ratio, fused, cpu_list, pass1, flags_ok

# Test 4  codec_sweep.csv
level, card, enc_intent, compression, encodings, rows, bytes, bytes_per_row,
fpga_op_ms, cpu_op_ms, speedup, fpga_decode_ms, fpga_passes_ms, decoded_gbs, wire_gbs,
fpga_cpu_seconds, cpu_cpu_seconds, pass1, flags_ok

# Test 5  skew_sweep.csv AND skew_sweep_rep2.csv  -- BOTH runs, the repeat is the result
a, skewness, kurtosis, mean_over_median, bins_per_iqr, rows, bytes_per_row, distinct,
gate, natural_outliers, expected_total, fpga_op_ms, cpu_op_ms, speedup,
fpga_decode_ms, fpga_passes_ms, fpga_cpu_seconds, cpu_cpu_seconds,
fpga_count, cpu_count, fpga_err, cpu_err, fpga_wander, cpu_wander, pass1, fused
```

Plus, alongside them:

* the **dataset manifest** (file, rows, bytes/row, encodings, groups, `min_group % 8`, distinct) —
  the paper carries a dataset table and it must be generated, not retyped;
* the **run log** for each test, including the printed gates and internal checks;
* the **node name and bitstream** each test ran on. Ours: Tests 1 & 3 on `alveo-u55c-01`, Test 4 on
  `alveo-u55c-07`; we cross-checked two near-identical files across the nodes and they agreed to 0.9%
  (FPGA) / 3.0% (CPU), so the nodes are interchangeable — but only because we checked.

**Suggested figure layout** (ours is a 3-panel `figure*` at 7.0 in): (a) Test 1 operator time vs rows,
log-x, two FPGA lines (value/fused) + CPU; (b) Test 3 operator time vs threads, both arms, with the
FPGA-at-1-core line extended as a horizontal reference; (c) Test 4 speedup by representation,
**horizontal** bars grouped by level — vertical bars collide at 8 categories, we tried.

---

## 11. Order of work, and a rough budget

1. Fill in the §1.1 adaptation table and confirm both arms print a `heavy` line. *(blocking)*
2. Re-do the §2.2 threshold arithmetic for **your k**. *(5 minutes, blocking)*
3. Download the 6 taxi months + build the 7 real datasets → **verify all 7 digests** → **Test 0**.
   Do this first: it is the table the paper cannot ship without, and the download may need retries.
4. `gen_size_sweep.sh` → check both gates → **Test 1**, two curves.
5. `gen_codec_sweep.sh` → **the digest gate must say ALL GATES PASS** → **Test 4**.
6. Generate the one `knee` control file → **Test 3**, primary + control.
7. `gen_skew_sweep.py` → **Test 5**, and **run it twice** (§7.4).
8. Emit the CSVs and the manifests; send them plus the run logs.

Generation is the long pole (downloading ~340 MB of taxi data, SF10 dbgen, writing 100M-row parquet
files); measurement itself is minutes per test. Disk: ~740 MB (Test 0) + ~340 MB (taxi sources)
+ ~1.5 GB (Test 1) + ~1.04 GB (Test 4) + ~740 MB (Test 5) + ~50 MB (Test 3 control) ≈ **4.4 GB**.

**Do not skip the gates to save time.** Every single one of them exists because it caught something.

---

## 12. Sanity checklist before sending results

- [ ] Test 0: all seven digests match §3.5 — otherwise your data is not ours and no number compares.
- [ ] Test 0: `min_group % 8` recorded per dataset, and the code path each row took is stated.
- [ ] Test 0: reported as end-to-end medians of 15, clearly separated from the operator-ms tests.
- [ ] Test 5: run **twice**, and the same-point repeat spread is compared against the across-skew spread.
- [ ] Every point reported the exact expected flag count on **all 7** iterations.
- [ ] Test 1: `min_group % 8 == 0` and identical encoding on all 9 files; fused points all say `fused`.
- [ ] Test 4: the digest gate passed — the four files at each level provably hold the same numbers.
- [ ] Test 4: the second-pass time is flat within each level (< 10% spread). If not, **stop** — the
      generator's digest gate is the first thing to re-check.
- [ ] Test 3: the second-pass time is flat across thread counts; core plan printed in the log.
- [ ] Test 3: `threads=32` reproduces your own Test 1 20M row within ~15%.
- [ ] No number quoted without its encoding and compression.
- [ ] The offload claim says "N× fewer CPU-seconds", never "zero host CPU".
