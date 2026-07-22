# RESUME DOC — IQR FPGA vs CPU study (updated 2026-07-22, after build-14)

**Read this first after a context compact.** Authoritative numbers live in `bench/RESULTS.md` §9
(§9.1–§9.13 are this work). This file is the state + next actions.

---

## 0. One-paragraph status

The supervisor's critique — *"your CPU baseline is a SQL query, so you're measuring DuckDB's engine,
not the CPU"* — was accepted and fixed. We built `iqr_cpu_flags()`, a C++ CPU operator that is the
apples-to-apples twin of the FPGA's `iqr_flags_only()`. Both are now **one line of SQL**, share the
bind and the emit path, and differ only in where the compute runs. Against that fair baseline the
FPGA is **ahead or tied on 7 of 7 datasets end-to-end** and uses **2.2–4.2× less host CPU**. The
FPGA's losses had all traced to one thing — the ParCore decoder at its spec'd 1.5 GB/s per lane —
and **build-14 (4 lanes) resolved it**: sf10, the study's only remaining loss, went 0.82× → 0.96×
(a tie). See §9.13. The decode bottleneck is now closed; the DuckDB emit tax (68–76 % of every
query, both sides) is what bounds the end-to-end number.

---

## 1. Environment — the gotchas that cost time

| thing | rule |
|---|---|
| **Build node** | `hacc-build-02` — 64 cores, **376 GB RAM**. All Vivado builds go here. |
| **Benchmark node** | `alveo-u55c-10` — 32 threads (16-core EPYC 7302P), **only 62 GB RAM**, has the card. |
| **Never build on alveo** | Two Vivado runs wedged it (sshd died on memory pressure). `free -g` tells them apart: 62 = alveo, 376 = build node. |
| **Vivado** | `module load vivado/2024.2` **before** `synthesize.sh` (it inherits the env into tmux). 2023.2 has an xsim bug. |
| **CLI target** | `cmake --build build/release --target shell` — `--target duckdb` builds `libduckdb.so` and leaves the binary **stale**. Always check `ls -la extension/build/release/duckdb` mtime. |
| **Runtime** | `export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH` (else `libcoyote.so` not found). `medians.py` sets it itself. |
| **Huge pages** | `echo 8 \| sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages` (hdev is a silent no-op). |
| **Home is NFS-shared** | `~/oasis` is the same on both nodes; only tmux/processes are per-node. |

---

## 2. CURRENT RESULT — read §9.18, the numbers below are SUPERSEDED

**2026-07-22: two benchmark defects were found, both of which flattered the FPGA.** (1) the benchmark
timed `CREATE TABLE`, 92 % of which is DuckDB's single-threaded table append — a large constant added
to both sides that dragged every ratio to 1.0; (2) the C++ baseline freed its column with `new[]`
outside DuckDB, charging itself up to 27 ms of teardown. Both fixed (`medians.py --consume`;
`Allocator::Get(context).Allocate()`).

**Corrected, medians of 15:** FPGA wins **4 of 7**, not 7 of 7 —
taxi_d1 1.58×, taxi_d2 1.28×, tpch_qty 1.06×, extprice 1.04×;
loses taxi_d3 0.80×, taxi_d4 0.76×, sf10 0.88×.
**Host CPU-seconds 2.07–6.07× survives both fixes and is the most defensible claim in the study.**

The mechanism is a **crossover at ~10 M rows**: the FPGA costs a flat 2.3–3.4 ms per million rows at
every scale, the CPU falls 5.37 → 1.63 as its ~13 ms fixed startup amortises. ≤6 M rows the FPGA
wins; ≥13 M it loses. Encoding is secondary (20–40 %), not the driver — earlier sections overstated it.

Still open: sf10's C++ `tax` of 61.4 ms did not respond to the allocator fix (DuckDB seems to stop
pooling above some size), and C++ spreads are now 20–77 %.

## 2b. Older configuration notes (end-to-end figures here predate §9.18)

**build-14 (4 decoders) + `OASIS_IQR_STREAM=1` + `OASIS_IQR_DECODE_WINDOW=16`.**
Run it exactly that way — the default window of 8 in-flight groups will not keep 4 lanes fed.
End-to-end, medians of 7 warm runs (`alveo-u55c-07`):

| dataset | rows | FPGA | C++ CPU | ratio | was (N=2) | verdict |
|---|--:|--:|--:|--:|--:|---|
| taxi_d2 | 6.0M | 0.059 | 0.072 | **1.22×** | 1.18× | FPGA |
| taxi_d1 | 3.0M | 0.033 | 0.040 | **1.21×** | 1.15× | FPGA |
| tpch_qty | 6.0M | 0.059 | 0.067 | **1.14×** | 1.10× | FPGA |
| tpch_extprice | 6.0M | 0.066 | 0.070 | 1.06× | 0.93× | tie |
| taxi_d4 | 20.3M | 0.201 | 0.210 | 1.04× | 1.02× | tie |
| taxi_d3 | 13.1M | 0.132 | 0.135 | 1.02× | 1.02× | tie |
| tpch_extprice_sf10 | 60.0M | 0.598 | 0.572 | 0.96× | 0.82× | tie |

CPU-seconds (the headline claim): **2.2–4.2× less host CPU on every dataset**; sf10 0.430 vs 1.825
= 4.24×. Lane count does not change this — streaming buys CPU-seconds, lanes buy wall clock.

Run-to-run spread is 5–18 %, so only differences >~10 % are meaningful. sf10 / taxi_d3 / taxi_d4 /
extprice are honest **ties**, not wins.

**build-13 (2 decoders) is the fallback** and is still on disk; its numbers are in RESULTS.md §9.10.

---

## 3. Correctness — the gate, and how to read it

```bash
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
cd ~/oasis && ./extension/build/release/duckdb < bench/sql/cpu_op_correctness.sql
```

Must reproduce **exactly** (verified identical on build-11, build-13 and **build-14**, with and
without streaming — including the `fpga_vs_cpp` deltas, which is what proves a lane-count change
altered throughput only):

| dataset | n_fpga | fpga_vs_cpp | cpp_vs_sql |
|---|--:|--:|--:|
| taxi_d1 | 317554 | 1247 | **0** |
| taxi_d2 | 625445 | 2877 | **0** |
| taxi_d3 | 1328108 | 162 | **0** |
| taxi_d4 | 2112164 | 54921 | **0** |
| tpch × 3 | 0 | 0 | **0** |

- `cpp_vs_sql = 0` → the C++ operator is **bit-exact** with the SQL baseline (118 M rows).
- `fpga_vs_cpp ≠ 0` is the **hardware's 1024-bin quantisation**, not a bug: 99.73–100 % per-row
  accuracy, bit-exact on 3 of 7, worst case taxi_d4 at 2701 ppm, and it only **over**-flags at the
  fence (misses zero true outliers). Quote it **per-row**, never as "% of the outlier set".
- **TRAP:** tpch datasets have **zero outliers by nature**, so they agree with a totally broken
  implementation. Only taxi can actually fail. Always read the absolute counts, not just mismatches.

---

## 4. Code changes made (all in `extension/src/oasis_iqr.cpp`, uncommitted)

1. **`iqr_cpu_flags(path, col)`** — C++ CPU operator. Same bind (`ResolveIqrColumn`), same packed
   mask layout, same emit (`EmitFlagSlice`) as `iqr_flags_only`. Reads the column via DuckDB's own
   parquet reader (parallel over row groups), then exact quartiles via **iterative histogram
   narrowing** (4096 bins × uint32 = 16 KB, L1-resident; q1 and q3 advanced in one pass; ≤4 levels,
   no sort), fences in `__int128`, flags packed 8/byte.
2. **Streaming path** (`OASIS_IQR_STREAM=1`) — hands the per-row-group decoded buffers straight to
   `IqrRunner::run()` (which already takes a *vector* of chunks) instead of gathering them. Removes
   the memcpy **and** the contiguous allocation. Guarded: flags-only, and every **non-final** chunk
   must be a multiple of 8 elements (FlagBitPacker packs 8 flags/beat); else falls back to memcpy.
   Taxi files fail the guard (odd row groups) and correctly fall back.
3. **Row-count invariant** in `ReadColumnCpu` — throws if row groups yield fewer values than the
   footer promises (this is what would have caught the `column_ids` bug instantly).

### Bugs found and fixed along the way (do not regress)
- **`ParquetReader` needs BOTH `column_ids` and `column_indexes`** pushed in lockstep. Setting only
  `column_indexes` reads **nothing** (`Schedule()` walks `column_ids`) — silently returns zeros.
- `std::vector::resize` value-initialises: it was memsetting 163–480 MB single-threaded (82/229 ms).
  Use `new T[]`. Let the parallel read fault the pages.
- The first quartile implementation *collected* the winning histogram bin into vectors, which
  degenerated on concentrated data (taxi_d4 118 ms vs sf10's 39 ms on 3× the rows).

---

## 5. The decoder story — established by elimination

**The FPGA's losses are entirely the ParCore decoder, and this is now proven three ways:**

1. **§9.8 — compute-bound.** `decoder_profiler()` on sf10: `in_starved = 0.0 %`, `out_stalled = 0.0 %`,
   `in_stalled = 94.5 %`. Not fetch-bound, not downstream-bound: the lane is internally saturated.
2. **§9.12 — matches ParCore's own spec.** One lane = **1.37 GB/s** decoded output. ParCore's
   `vhsnunzip` README lists the **unbuffered single-core at ~1.5 GB/s**, and
   `hardware/src/hdl/vhsnunzip_wrapper.sv:263` instantiates exactly that. sf10 is **PLAIN**-encoded so
   snappy must chew all 480 MB: predicted 319.9 ms vs **measured 351.2 ms** (10 % apart).
3. **§9.11 — nothing on the host.** Prefetching the fetch onto a pool was a **no-op** (decode total
   181.1 → 181.7 ms; the fetch time just migrated into `fpga_wait`). Removing the memcpy (§9.10) also
   left decode unchanged. No host-side lever remains.

4. **§9.13 — confirmed by intervention.** Going 2 → 4 lanes cut operator time **−33.9 % on sf10 and
   −28.9 % on extprice while leaving taxi_d4 flat (−1.0 %)**. Only the PLAIN-encoded datasets moved.
   That is the encoding hypothesis verified causally, not by correlation.

5. **§9.14 — audited and re-measured at N=4.** Two flaws in the §9.8 method were found and checked:
   (i) its percentages excluded `in_idle`, the term where a host-feed shortfall would appear —
   re-measured over the full denominator, **`idle = 0.0 %` on all four lanes**, so the omission was
   benign; (ii) the profilers tap the **ColumnChunkDecoder's outer ports**
   (`column_chunk_decoder.sv:404-424`), so they prove the module is busy but **cannot say which
   internal stage** (snappy / `hybrid_page_decoder` / `run_decoder`) is the limiter — attributing it
   to snappy rests on the §9.12 throughput match, which is inference.
   Reset semantics, for future probes: reading a lane's **last** register asserts `stop`, which
   returns the profiler to WAIT and **holds** the counters; they are zeroed by the **next valid data
   beat** (`stream_profiler.sv:69-77`). So read→run→read is correct, and a double read with no query
   in between returns *the same values*, not zeros.

**The model is pinned.** Fitting `heavy = base + D/N` to the two measured sf10 points (257.9 ms @ N=2,
170.4 ms @ N=4) gives **D ≈ 350 ms of decode work, base ≈ 83 ms**. §9.12 independently predicted
319.9 ms from ParCore's spec and measured 351.2 ms; §9.14's summed lane occupancy (4 × 88 ms) gives
**352 ms**. Four unrelated derivations agree within 10 %.

**Per-unit the FPGA decoder WINS:** 1 lane (1.37 GB/s) vs 1 CPU core (0.425 GB/s) = **3.2× faster**.
At build-13 we were running **1 lane against 16 cores**; ~5 lanes match the CPU's aggregate, and
build-14's 4 lanes essentially get there. Frame it that way — it is not a criticism of ParCore.

**Why taxi wins and tpch loses:** encoding. taxi is `PLAIN_DICTIONARY` → snappy only handles 28 MB of
dictionary indices. tpch is `PLAIN` → snappy handles the full 480 MB. **17× more decompression work.**

---

## 6. Measured lever comparison (no projections — these were run)

| change | wall time | CPU-seconds | status |
|---|---|---|---|
| build-11 → build-13 (1→2 decoders) | sf10 −18 %, extprice −19 % | — | **kept** |
| build-13 → build-14 (2→4 decoders) | sf10 operator **−33.9 %**, e2e −15 % | ~0 | **kept** (§9.13) |
| Streaming (remove memcpy) | operator −7.5 % | **−46 %** (2.24× → 4.14×) | **kept** |
| Host prefetch pool | 0 % | +7 % | **reverted** (§9.11) |
| `DECODE_WINDOW` 8→32 | **0 %** (flat within 1.5 %) | — | **retired** (§9.14.3) |

---

## 6b. Time budget at build-14 (§9.14) — READ BEFORE PICKING A NEXT LEVER

sf10, end-to-end 0.598 s. **The accelerator is a minority of the query:**

| component | ms | share of e2e |
|---|--:|--:|
| **DuckDB emit tax** | **427.5** | **71.5 %** |
| IQR passes (FPGA) | 76.6 | 12.8 % |
| decode — host `fetch`+`submit` | 58.3 | 9.7 % |
| decode — `fpga_wait` | 30.1 | 5.0 % |

Four facts that constrain everything downstream:
1. **Decoder is fully characterised.** D ≈ 350 ms of work, confirmed 4 independent ways. Lanes are
   95 % parallel-efficient and balanced to 1.02×; `idle = 0 %`, `starved = 0 %`.
2. **`fetch`+`submit` = 58.3 ms is a host floor** no lane count can cross (lane-count-invariant:
   42.8/19.8 at N=2, 38.5/19.7 at N=4). Lane occupancy is 88 ms — the margin over the floor is thin,
   so **a 5th+ lane buys little.**
3. **The IQR pass phase is now co-equal with decode** (76.6 vs 92.8 ms; was 78 vs 181 at N=2).
   It is the largest remaining item inside `heavy`.
4. **taxi is a different regime entirely** — decoder `idle` 39–42 %, `out_stalled` 64–82 %. Not
   decode-bound; the sink back-pressures it. Explains why lanes did nothing for taxi.

---

## 7. OPEN THREADS — next actions

### (a) build-14 (4 decoders) — ✅ DONE, flashed and validated 2026-07-22
WNS **−0.773 ns**, 1004 failing paths (worse than build-13's −0.456), **yet bit-identical on
silicon** — same `n_fpga` AND same `fpga_vs_cpp` deltas. LUTs 40.0 %, FFs 29.8 %, BRAM 17.9 %,
URAM 32.2 %. Results in §9.13. Run it as:
```bash
OASIS_IQR_STREAM=1 OASIS_IQR_DECODE_WINDOW=16 python3 bench/medians.py
```

### (a1) Overlap pass 1 with decode — BUILT, CORRECT, and a NET LOSS. Keep it OFF. (§9.15)
`OASIS_IQR_OVERLAP=1`, default off. **Do not enable it for any published number.**

*The mechanism works:* pass 1 hides completely inside decode's slack — `decode` unchanged, `passes`
halved, `heavy` 170.5 → **131.8 ms (−22.7 %)** when the window is free.

*Two rounds of window derivation:*
1. **Prefix window — catastrophically wrong.** Flagged **19,997,999 of 20 M rows vs a true 200** on
   order-drifting data. `bench/overlap_ab.sh gen` builds `ov_drift`/`ov_uniform` to catch exactly this
   (the normal correctness suite is BLIND to it: taxi mostly falls back to memcpy and tpch has zero
   outliers). Any 2026-07-22 median showing sf10 1.01× / taxi_d1 1.30× came from this build — invalid.
2. **`DeriveWindowSpanning()` — correct but too expensive.** Host sample of the first DataChunk of 16
   uniformly-spaced row groups, parallelised. `ov_drift` back to 200, taxi_d1 exact, taxi_d2 improved
   2877 → 2617. **16 groups is the minimum safe count** (8 regresses taxi_d1 to 1348).

*Why it still loses:* `win_derive` is a fixed ~8 ms + 1.3 ms/group paid EVERY query, while the saving
is half of `passes` and scales with N — it only pays above ~40 M rows. **6 of 7 datasets got slower
and host CPU-seconds got worse on all 7** (sf10 4.21× → 3.91×, extprice 3.70× → 1.91×).

*To revisit it, in increasing risk:* (1) skip the window unless the streaming guard will actually
engage — it is computable from the footer, and today taxi_d3/d4 pay it then fall back to memcpy and
never use it; (2) skip the overlap entirely below ~40 M rows; (3) share `BuildParcoreMetadata` (walked
twice) or derive the window on a background thread during decode.

### (a2) NEW top candidate — make streaming accept taxi's row groups
taxi_d4 falls back to `sink=memcpy` because the streaming guard requires every non-final chunk to be
a multiple of 8 elements (FlagBitPacker packs 8 flags/beat). It pays **11.35 ms of `copy` = 45 % of
its whole 24.96 ms decode phase**. Carrying a partial-byte remainder across the chunk boundary would
recover that on all four taxi datasets — **pure software, no bitgen.** Highest value/effort ratio left.

### (b) The 64 KiB-page experiment — NOT YET RUN (10 minutes, decides a bitstream)
`~/datasets/sf10_64k.parquet` was already written (`data_page_size=65536`).
```bash
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH; cd ~/oasis
for F in tpch_extprice_sf10 sf10_64k; do echo "--- $F ---"
  OASIS_IQR_STREAM=1 OASIS_IQR_TIMING=1 ./extension/build/release/duckdb -c \
    "SELECT count(*) FROM iqr_flags_only('/home/myaksi/datasets/$F.parquet','v');" 2>&1 | grep '\[iqr\]'
done
```
Compare `fpga_wait` (~113 ms on the original). **Why it matters:** ParCore's multi-core `vhsnunzip`
is **3.3–5.3× faster** (5-core 5.0 GB/s, 8-core 8.0 GB/s) for only **+2.9 % LUT on 2 lanes** — far
cheaper than the +11.6 % that N=4 costs. **But `vhsnunzip_buffered` has no `LONG_CHUNKS` generic and
is buffer-limited to 64 KiB chunks**, and our column chunks are **960 KiB** (sf10) / 251 KiB
(taxi_d4). Small pages are the only way to make it legal.
- `fpga_wait` roughly unchanged → page overhead is free, **the decompressor swap is worth a bitgen**.
- `fpga_wait` jumps → option dead; decoder lanes remain the only lever.

### (c) Housekeeping
- `git status` shows a stray file literally named `threads=32` (mistyped redirect) — delete it.
- **Nothing since commit `52d6f09` is committed.** `celeris-labs/oasis` is private and this account
  has READ-only, so `git push` 403s. Unresolved: get write access, fork, or `git bundle`.

---

## 8. Files created this session

| file | purpose |
|---|---|
| `bench/medians.py` | **the** benchmark. 7 warm runs/cell, prints end-to-end + operator + CPU-seconds with spreads. `-n`, `-d`, `-t` flags. |
| `bench/sql/cpu_op_correctness.sql` | 3-way FPGA vs C++ vs SQL, `threads=1` + POSITIONAL JOIN. |
| `bench/sql/decoder_bound_check.sql` | is the decoder compute-bound / starved / stalled. |
| `bench/sql/heavy_breakdown.sql` | operator time vs the shared DuckDB tax. |
| `bench/sql/cpp_headtohead.sql` | single-pass 7-dataset × 3-impl timing. |
| `compact.md` | this file. |

---

## 9. Framing for the writeup (agreed with the user)

- **End-to-end is the success metric.** Operator-only is the engineering diagnostic; report both,
  because the DuckDB emit tax is **48–75 % of every query** and near-identical on both sides
  (it compresses wins *and* losses toward 1.0).
- **Lead with CPU-seconds** (2.3–4.1×), which is latency-independent and far outside the noise.
- **Disclose:** the C++ operator pays a 5–13 % larger DuckDB tax because it allocates the raw column
  outside DuckDB's buffer manager — a small handicap that flatters the FPGA end-to-end.
- **Disclose:** the C++ baseline saturates only ~3 cores; two of its four phases are already at memory
  bandwidth (35–40 GB/s), but it is not proven optimal.
- The honest one-liner: *"Against an optimized 32-thread C++ CPU operator the FPGA matches or beats it
  on 6 of 7 datasets end-to-end while using 2.3–4.1× less host CPU; the one loss is a 60 M-row
  PLAIN-encoded column where a single decoder lane faces sixteen cores."*
