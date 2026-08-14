# RESUME DOC — IQR FPGA vs CPU (updated 2026-08-08: **WNS ARC DONE at −0.518 ns, HBM REMOVED, PRODUCTION = `build-29/bitstreams/cyt_top_b29_po.bit`** (4/4 silicon gates). Focus has MOVED to **microbenchmarks → `micro_bench.md`** (Test 1 size sweep, Test 2 cardinality sweep both complete). Next: Test 3.)

> 💾 **BACKUP / RECOVERY (2026-08-14) — read this FIRST if the cluster home directory was wiped.**
>
> `meminyaksi` has **READ-only** on `celeris-labs/oasis` and `celeris-labs/celeris`, so `git push
> origin` fails 403. Everything is mirrored to two **private** repos instead, each wired as a
> `backup` remote beside `origin`:
>
> | repo | what it is | files |
> |---|---|--:|
> | `meminyaksi/celeris-backup` → `~/celeris`, branch `feature/mehmet` | the **FPGA hardware** project: RTL operators, unit tests | 703 |
> | `meminyaksi/oasis-iqr-backup` → `~/oasis`, branch `feature/iqr-integration` | the **DuckDB extension** project: host SW, benchmarks, paper, bitstream | 302 |
>
> **Both are required.** oasis contains celeris as a submodule but pins it at `c317559`, while
> `~/celeris` is 4 commits beyond that — restoring oasis alone gives you an older hardware tree.
>
> ```bash
> git clone -b feature/mehmet           https://github.com/meminyaksi/celeris-backup.git   ~/celeris
> git clone -b feature/iqr-integration  https://github.com/meminyaksi/oasis-iqr-backup.git ~/oasis
> cd ~/oasis && git submodule update --init --recursive && git lfs pull
> ```
>
> Then follow **`patches/RESTORE.md`**: re-apply the two submodule patches (the `SSI_SpreadSLLs`
> override lives in third-party `fpgasystems/Coyote` and CANNOT be committed anywhere reachable),
> regenerate the datasets with `bench/gen_*.sh`, and rebuild `~/opt`.
>
> **The VSCode workspace is saved too**: open `oasis/software/celeris-oasis.code-workspace` — it
> points at `../../celeris` and `..`, so cloning both side by side reproduces the exact tree.
>
> **Rescued from `.gitignore` and now tracked** (these were one wipe from gone): `hardware/pnr/` —
> the four P&R sweep harnesses that drove the whole timing arc, plus build-29's WNS/utilisation/
> directive evidence; `report_2807_*.log` + `bench/e2e_sweep_*.log` — the raw runs behind the
> paper's numbers; celeris `hardware/pnr-evidence/`. The 43 MB production bitstream is in the oasis
> backup **via git-LFS** (that commit is marked to drop before any upstream push).
>
> ⚠️ **`git add <dir>` silently skips ignored contents.** It bit twice here: `build*` matches
> *filenames*, so `hardware/pnr/evidence/build-29-*.txt` vanished from a directory that had just
> been staged, and `*.log` dropped the run logs. **Verify with `git ls-files <dir>`, not
> `git status`.**
>
> Recovery was **verified by performing it**: fresh clone → all docs present, bitstream
> md5-identical, `bench/paper_figs.py` regenerated every figure with no datasets on disk.
>
> ➡️ **When Jonas grants Write**, the work moves upstream in one command per repo:
> `git push origin feature/mehmet` and `git push origin feature/iqr-integration`.

**Read this first after a compact.** Three companion docs, each with a distinct job:
- **`micro_bench.md`** — ⬅️ **CURRENT WORK.** Controlled synthetic sweeps, one variable at a time.
- **`report_2807.md`** — the 7 REAL datasets, all END-TO-END/consume (numbers from build-23).
- `bench/RESULTS.md` §9 — authoritative historical numbers. `results_new.md` §11 — prior session.

This file is state + next actions.

> 🔬 **NEWEST (2026-08-08). TWO THINGS HAPPENED: the WNS arc FINISHED at −0.518 with HBM finally
> removed, and the work moved to MICROBENCHMARKS (`micro_bench.md`). Read that file before proposing a
> new test.**
>
> ## A. Hardware: production is now `build-29` + phys_opt ladder, **WNS −0.518 ns**, HBM OUT
>
> **USE `hardware/build-29/bitstreams/cyt_top_b29_po.bit`.** Validated 4/4 on silicon
> (correctness 0/0/104/0/0/0/0 · overlap 200/200 both sets · value-path perf within noise of build-23 ·
> fused sf10 count=0, heavy 138.6 ms). Fallback chain: `build-29/cyt_top.bit` (−0.553) →
> `build-28/cyt_top_ssi_spreadslls.bit` (−0.657) → `build-28/cyt_top.bit` (−0.995) → build-23 (−1.879).
>
> **Full arc −1.879 → −0.518 = +1.361 ns**, performance unchanged throughout. What each lever gave:
>
> | change | gain | note |
> |---|---|---|
> | index mode retired (`EN_INDEX=0`) | +0.383 | `idx_pack` cluster deleted |
> | diag reduction pipelined (8→4→2→1) | +0.501 | 683 LUTs; latency-insensitive CSR readback |
> | **`place_design -directive SSI_SpreadSLLs`** | **+0.338** | P&R only. ML had picked `SSI_BalanceSLRs` (balances CELLS, blind to crossings) |
> | **HBM removed (`EN_MEM=0`)** | **+0.104** | −40k LUTs / −66k FFs; 42.5% → **39.4%** LUT |
> | phys_opt `AggressiveFanoutOpt` + `AlternateReplication` | +0.035 | post-route ladder, hold-checked |
>
> **⚠️ TWO THINGS THAT MUST NOT BE LOST:**
> 1. **`OASIS_PLACE_DIRECTIVE=SSI_SpreadSLLs` must be exported for EVERY future build.** The override
>    lives in `parcore/libstf/coyote/scripts/impl/pnr_shell.tcl.in` (a *generated* file — build dirs
>    regenerate it, so editing `build-NN/pnr_shell.tcl` does nothing). Without the env var the ML
>    predictor picks `BalanceSLRs` again and HBM-out re-measures the OLD WRONG ~−2.15 answer.
>    Verify ~2 h in: `grep -m1 "OASIS: place_design" hardware/build-NN/bitgen.log`.
> 2. **HBM removal was only safe BECAUSE of SpreadSLLs.** Under `BalanceSLRs` removing HBM cost
>    0.66–0.68 ns twice (it was an accidental floorplan anchor). Do not re-test HBM under BalanceSLRs
>    and conclude anything.
>
> **⚠️ HOLD MARGIN IS 1 ps.** `WHS +0.001` (was +0.004). Replication eats hold. Precedent: the
> `IqrWideFlagPack` forwarding regs sat at **+0.021** and lost ~10% of histogram counts on silicon while
> being bit-exact in sim. So if anything ever looks flaky, **suspect hold, not setup**, and re-run —
> the historical signature was *wandering* results across runs, not a clean failure.
>
> **Timing is now a FLAT WALL and directives are EXHAUSTED.** 11 P&R runs across all three axes bought
> +0.021 in total beyond SpreadSLLs. `SSI_HighUtilSLRs` is UNROUTABLE (14,525 unrouted signals, 5 h
> wasted). Both route directives tried were WORSE. The only lever left that can reach −0.5 is
> **`EN_UCLK=1` + `UCLK_F=225`** (+0.444 ns of period, arithmetic not luck) — ⚠️ `EN_UCLK` and `UCLK_F`
> MUST move together: `user_clk_tmplt.txt` constrains the user region from `uclk_p` unconditionally, so
> `UCLK_F=225` with `EN_UCLK=0` relaxes the CONSTRAINT while the hardware still runs at 250 MHz = a
> beautiful report and a broken bitstream. Use 225 not 200 (measured `eff` is 12.49 GB/s; 200 MHz gives
> only 12.8). **Not needed — the design is correct and fast as-is.**
>
> Harnesses that now exist: `hardware/build-28/pnr_reseed.tcl` (place-directive sweep),
> `build-28/route_sweep.tcl` (route sweep from a fixed placement),
> `build-29/physopt_iterate.tcl` (post-route ladder, re-opens best checkpoint per attempt, REJECTS any
> directive that breaks hold, writes the bitstream as soon as anything improves),
> `build-28/reseed/status.sh` (multi-run status; filters Vivado echoing the .tcl source).
>
> ## B. Microbenchmarks — `micro_bench.md`, the CURRENT thread
>
> **NEW MEASUREMENT PROTOCOL (supersedes medians+spread for microbenchmarks, user's instruction):**
> **run 7 times in ONE DuckDB session, report the arithmetic MEAN OF THE LAST 3. No median. No spread.**
> First 4 iterations are warm-up (kills the §9.18 allocator-pooling bimodality).
>
> **CPU arm is `iqr_cpu_flags_groupby()` ONLY. NEVER use or report `--cpp-impl zoom`** — user's explicit
> instruction; `card_sweep.py` no longer accepts it.
>
> Harnesses: `bench/gen_size_sweep.sh` + `bench/size_sweep.py`, `bench/gen_card_sweep.sh` +
> `bench/card_sweep.py` (imports `size_sweep.run_arm`, so the protocol is shared, and `medians.py` for
> the arm definitions). Every sweep SELF-CHECKS: outliers are placed in an empty value gap far outside
> the fence, so expected flags is exact and quantisation-proof, and all 7 iterations are verified.
>
> **Test 1 — size sweep 1M→100M, fusion off vs on.** Everything affine in N:
> `value ≈ 3.1 ms + 3.34 ms/Mrow` · `fused ≈ 9.5 + 2.20` · `CPU ≈ 56.5 + 3.93`.
> - FPGA wins at EVERY size (this **corrects** §2's old "crossover at 10M, FPGA loses above 13M" — that
>   was an artefact of 7 datasets differing in encoding AND cardinality AND size).
> - **Fusion costs +6.4 ms fixed, saves 1.14 ms/Mrow ⇒ break-even 5.6M predicted / 6M measured.**
>   `passes` halves EXACTLY (127.17 → 63.80 ms at 100M = 1.993×) — two streamed passes become one.
> - Fusion changes the ASYMPTOTE: marginal advantage 1.18× → 1.79×, so speedup plateaus at ~2× instead
>   of decaying to 1.3×. **Fusion is what makes the FPGA advantage durable at scale.**
> - Fusion halves host CPU-seconds and wins at EVERY size — at 1M it is 1.51× WORSE on wall-clock but
>   2.99× BETTER on CPU-seconds. **So the wall-clock and CPU-seconds crossovers differ; an auto-fusion
>   policy must CHOOSE which metric it optimises.**
>
> **Test 2 — cardinality sweep, 10M rows fixed, 10 → 10M distinct.** Took THREE generator attempts;
> the first two produced plausible-but-wrong trends and are documented as superseded in `micro_bench.md`:
> v1 `level*(RANGE/CARD)` left low-bit structure that imbalanced the CPU's RADIX aggregation and
> manufactured a fake monotonic decline; v2 fixed that with a multiplicative permutation but encoding
> and bytes/row still moved with cardinality. **v3 pins both** (`DICTIONARY_SIZE_LIMIT 0` forces PLAIN
> everywhere; `COMPRESSION UNCOMPRESSED` pins bytes/row at exactly 8.00), which makes **the FPGA arm's
> flatness an internal check on the sweep itself**.
> - **FPGA is INDIFFERENT to cardinality** — flat 31.0–32.9 ms over six decades (uncompressed control).
> - **CPU is O(rows) + O(distinct); the knee is at C ≈ 1% of N** — 1.00× at 10k, 1.14× at 100k,
>   2.25× at 1M, **8.28×** at all-distinct. GROUP BY always does N probes; cardinality only adds
>   per-distinct-value table + sort work.
> - **Speedup runs 1.4× → 11.7×** on one bitstream, same row count. The arms differ in COMPLEXITY, not
>   in constants — the strongest single result so far.
> - Compression: a 4.2× byte reduction buys only ~21% of operator time ⇒ the FPGA has a large
>   byte-independent floor (~24 ms at 10M rows). **Quote the SNAPPY table** (realistic); uncompressed is
>   the isolation control.
> - `distinct~` ≠ `card` by design: outlier rows add their own levels, and coupon-collector coverage
>   caps the top point at `1−e⁻¹` ≈ 63%.
>
> **Datasets on disk:** `~/datasets/sizesweep` (1.5 GB) · `~/datasets/cardsweep10m` (uncompressed) ·
> `~/datasets/cardsweep10m_snappy` · plus superseded `cardsweep`, `cardsweep_scatter` (v1/v2, can delete).
>
> ## C. ➡️ NEXT: Test 3, and two open threads
>
> 1. **Test 3 = distribution shape and/or ragged row groups.** Neither Test 1 nor Test 2 explains the
>    real-dataset residual: Test 1's size model predicts the two PLAIN high-card real datasets almost
>    exactly (extprice 0.99×, sf10 0.90×) but OVER-predicts every dictionary-encoded one by 1.29–2.54×
>    (taxi_d1 3.48 predicted vs 1.37 measured). Test 2 shows the FPGA gets *faster* on low-byte data, so
>    encoding/cardinality runs the WRONG WAY to explain it. Remaining suspects: **tail-heavy
>    distribution** (every synthetic set so far is uniform) and **odd row groups** needing the host
>    ragged stitch (taxi has 51449/124849). Expect the distribution sweep to show FPGA-flat — that is
>    the data-obliviousness claim and the natural joint panel with the friend's z-score operator.
> 2. **Auto-fusion policy.** Shipped `fuse_min_rows()` is **30M** (`extension/src/oasis_iqr.cpp:296`,
>    env `OASIS_IQR_FUSE_MIN_ROWS`); measured crossover is **6M** on clean high-card data. Do NOT just
>    lower the constant — 30M was set from taxi, where fusion LOST wall-clock at 13M and 20M because of
>    the ragged stitch + tail-heavy window. Measure taxi's own crossover first, then make the policy a
>    function of shape. `FooterFacts` (`oasis_iqr.cpp:560`) exposes only `rows` and `stream_ok` today; it
>    already walks every group's `num_values`, so adding a ragged flag + bytes/row is cheap.
> 3. **Encoding test is now possible at FIXED cardinality.** `DICTIONARY_SIZE_LIMIT` forces the writer
>    both ways (verified: `0` → PLAIN at card=1k; `10 MB` → dictionary at card=100k; `50 MB` →
>    dictionary at card=1M, which makes the file BIGGER at 8.91 B/row). DuckDB's default flips
>    dictionary→PLAIN at a ~128 KB dictionary page ≈ 20–30k distinct per row group (measured).
>
> **UNCOMMITTED (nothing committed across this whole arc — commit was offered repeatedly, never done):**
> `hardware/CMakeLists.txt` (EN_MEM→0 + rationale), `hardware/src/vfpga_top.svh`,
> `hardware/iqr_app/hdl/IQR_detection.sv` (EN_INDEX + diag pipeline),
> `parcore/libstf/coyote/scripts/impl/pnr_shell.tcl.in` (**the directive override — most important to
> keep**), the 4 P&R harnesses, `bench/{gen_,}size_sweep.*`, `bench/{gen_,}card_sweep.*`,
> `bench/reseed/status.sh`, `micro_bench.md`, and the sweep CSVs. Plus prior-session uncommitted:
> index re-widen, `report_2807.md`, bench logs.
>
> ⚠️ **Bitstream provenance for the microbenchmarks is UNVERIFIED** — the flash command was never
> captured before those runs. Presumed `build-29/cyt_top_b29_po.bit`. Confirm with
> `cat /sys/kernel/coyote_sysfs_0/cyt_attr_cnfg | grep "enabled memory"` → **0** = build-29 (HBM out),
> **1** = a build-28 bitstream. Correctness stands either way; only timing attribution changes.

> 🥇 **NEWEST (2026-08-06). THE PLACER WAS OPTIMIZING THE WRONG THING. `place_design -directive
> SSI_SpreadSLLs` takes build-28 from −0.995 → **−0.657 ns** (+0.338) with NO RTL change, NO HBM change
> and NO Pblocks — P&R only, resumed from `shell_opted.dcp`. PRODUCTION =
> `hardware/build-28/bitstreams/cyt_top_ssi_spreadslls.bit`, VALIDATED 4/4 ON SILICON.**
>
> **1. The directive sweep (P&R-only, ~4 h each, 3 run in parallel on hacc-build-02).**
> Harness: `hardware/build-28/pnr_reseed.tcl` (tagged checkpoints/reports/bitstream, never clobbers the
> originals; needs `export TERM=xterm` for base.tcl's `tput` colors; run each from its OWN cwd so
> `vivado.jou/log` don't collide; `-tclargs <DIRECTIVE> <maxThreads>`).
>
> | place directive | WNS | note |
> |---|---|---|
> | `SSI_BalanceSLRs` | −0.995 | build-28 default — **ML-auto-picked**, `Place 30-1947` |
> | `SSI_BalanceSLLs` | −0.997 | byte-identical SLL table → placed the same, no gain |
> | **`SSI_SpreadSLLs`** | **−0.657** | ✅ **WINNER**, TNS −63k→**−22k**, failing endpoints 209k→**111k** |
> | `SSI_HighUtilSLRs` | ❌ FAILED | unroutable after 5 h10: `Route 35-162` 14,525 signals unrouted, 16,688 node overlaps |
>
> **2. WHY (and my first hypothesis was WRONG — don't repeat it).** I predicted SLL *column congestion*:
> build-28's route log shows `Estimated SLL Demand Per Column` with **column 12 at 1793/1440 = 125%** while
> overall SLL use is only 32–35%. **That was NOT the lever.** The winner has column 12 at **142%** and MORE
> total SLL demand (18,923 vs 15,592) — more crossings, worse column, 0.338 ns BETTER. What actually
> changed is the route/logic split on the critical path: build-28 was 28.7% logic / **71.3% route** with
> 8× CARRY8 (`histogram_feed`→`iqr_detection`, crossing SLR 1→2 on a **1.390 ns** net); SpreadSLLs is
> 47.8% logic / **52.2% route**, 4× CARRY8, worst path now INSIDE one decoder. `SSI_SpreadSLLs`
> ("allocate extra area for regions of higher connectivity") gave the four ~77k-LUT decoders room to sit
> compactly, so their INTERNAL paths stopped detouring. **Lesson: judge a placement by the route/logic
> ratio on the critical path, not by aggregate crossing counts.**
>
> **3. The design needs SPACE, not density — proven both directions.** `SSI_HighUtilSLRs` ("place logic
> closer together in each SLR") blew up into 14.5k unroutable signals; `SSI_SpreadSLLs` (spread) won.
> Two opposite directives, unambiguous answer: this design is **connectivity/area-limited**. This is the
> strongest argument yet for finally removing HBM (point 5).
>
> **4. ✅ 4/4 GATES PASS on `cyt_top_ssi_spreadslls.bit`** (node alveo-u55c-01, 2026-08-06). A re-placed
> design does NOT inherit another build's validation — always re-run all four.
> - Correctness: `fpga_vs_cpp` = **0/0/104/0/0/0/0** exact, `cpp_vs_sql` = 0 on all 7.
> - Window/accuracy: **200/200** ov_uniform + ov_drift, serial + overlapped.
> - Value path (`e2e_sweep.sh`): sf10 **199.5** ms (b28 200.9, b23 200.0), extprice **23.0 → 3.67×**,
>   taxi_d2 1.78×, sf10 1.59×, CPU-seconds 2.8–8.5×. All 7 within noise of build-23/28.
> - Fused: `pass1=fused`, **count = 0**, `heavy` **139.08** ms (b28 139.42, b23 137), `passes` 38.42,
>   `decode` 92.15 / `fpga_wait` 33.05, **eff 12.49 GB/s**, INPUT `stalled=0.0%`.
>
> **5. ➡️ NEXT.** (a) Two untested "spread"-family variants — **`SSI_SpreadLogic_high`** and
> **`SSI_SpreadLogic_Explore`** — are free (P&R only, ~4 h, no RTL/HBM) and in the proven-correct
> direction; watch for `Route 35-162` and kill early rather than waiting 5 h for a HighUtilSLRs-style
> failure. (b) **Then the clean HBM-out build** (`EN_MEM 0`, `N_CARD_AXI 1`) with the winning directive
> **FORCED** in `pnr_shell.tcl` — ⚠️ **the override is mandatory**, otherwise the ML predictor picks
> `SSI_BalanceSLRs` again and you re-measure the OLD, WRONG HBM-out answer (the −0.66 ns penalty in the
> 2026-08-05 banner's 2×2 was measured ONLY under `SSI_BalanceSLRs`, so it is no longer decisive).
> (c) **Expectation-setting:** the wall is now FLATTER THAN EVER — top 10 clusters span **0.004 ns**
> (−0.653…−0.657), 5 of them decoder-internal at **47.8% logic**. Logic depth is becoming the floor and
> placement cannot fix logic depth, so HBM-out plausibly reaches ~−0.4/−0.5, but not 0 without pipelining
> inside the parcore decoder or lowering the clock (`EN_UCLK`, 2026-08-05 banner point 7).
>
> 🏆 **PREVIOUS (2026-08-05). WNS ARC: `build-28` = WNS −0.995 ns
> (build-23 was −1.879 → **+0.884 ns**), and it is VALIDATED ON SILICON on all four gates with
> performance IDENTICAL to build-23. ⚠️ **SUPERSEDED 2026-08-06 by the re-placed
> `cyt_top_ssi_spreadslls.bit` at −0.657 (top banner); `cyt_top.bit` is the fallback, build-23 the
> second fallback. Everything below about RTL/HBM/EN_UCLK still applies — only the placement changed.**
>
> **1. ✅ ALL FOUR GATES PASS (node alveo-u55c-01, 2026-08-05).** Do not re-litigate these.
> - **Correctness** (`bench/sql/cpu_op_correctness.sql`): `fpga_vs_cpp` = **0 / 0 / 104 / 0 / 0 / 0 / 0**
>   — EXACT match to the documented 4096-bin gate; `cpp_vs_sql` = 0 on all 7. Absolute counts reconcile
>   against the old 1024-bin table (318801−1247, 628322−2877, 1328270−162, 2057243+54921).
> - **Window/accuracy** (`bench/overlap_ab.sh accuracy`): **200/200** on ov_uniform AND ov_drift, both
>   serial and overlapped (`pass1=overlapped` confirmed, so the guard did not silently reject).
> - **Value-path perf** (`bench/e2e_sweep.sh`): every dataset within **±2%** of build-23 — taxi_d1 10.1,
>   tpch_qty 16.4, taxi_d2 16.2, extprice 23.1, taxi_d3 33.5, taxi_d4 50.5, **sf10 200.9** (b23: 200.0).
>   extprice **3.65×**, sf10 1.60×, CPU-seconds 2.9–7.6×.
> - **Fused path** (the timing-stressing one — 4 decoder lanes driving the feed at full rate, which is
>   where the worst path lives): `pass1=fused`, **count = 0 (CORRECT)**, `heavy` **139.4 ms** (b23: 137),
>   `passes` 38.43, `decode` 92.36 / `fpga_wait` 31.79 (= build-20's best 4-decoder figures),
>   **eff 12.49 GB/s**, INPUT `stalled=0.0%`.
> ⚠️ **`e2e_sweep.sh:20` `unset`s `OASIS_IQR_FUSE`/`STREAM`/`WINDOW_FPGA` → it measures the VALUE path.**
> sf10's 200.9 ms must be compared to build-23's **200.0** value path, NOT to the 137 ms fused number.
> Misreading 200-vs-137 looks like a 47% regression that does not exist.
>
> **2. What actually bought the +0.884 ns (a clean 2×2 factorial, no interaction).**
>
> | | index **IN** | index **OUT** |
> |---|---|---|
> | **HBM IN** | −1.879 (b23) | −1.496 (b27) → **−0.995 (b28, +diag fix)** |
> | **HBM OUT** | −2.562 (b25) | −2.154 (b26) |
>
> HBM-in is worth **+0.683 / +0.658 ns** (two independent paired tests, agreeing to 0.025 ns); index-out
> is worth **+0.383 / +0.408 ns**. Independent and additive. Then the **diag-reduction pipeline** (point 3)
> added **+0.501 ns** on top.
>
> **3. ✅ THE build-28 FIX: pipeline the `dbg_*` diagnostic reduction** (`IQR_detection.sv` ~line 537).
> The flat `always_comb` Σ over the 8 per-bank `diag_*` counters into the config CSR was the build-27
> critical path (−1.496, 15 levels, 76% route). Replaced with a **registered 8→4→2→1 adder tree** (mirrors
> the scan-merge pipeline below it) for all four sums. These feed ONLY the host CSR readback, sampled after
> a run, so the 3-cycle latency is invisible. **Cost: 683 LUTs. Gain: +0.501 ns WNS, TNS −159k→−63k (2.5×),
> failing endpoints 322k→209k.** `inst_read_regs` fell from the #1 worst path to the #6 cluster. Sim PASS
> (`run_fused_integration_tb`: diags settle to accepted=committed=96=N; `run_bins4096_tb` 0 errors).
>
> **4. ⚠️ THE WALL IS NOW FLAT — stop hunting single paths.** Top 12 failing clusters all sit between
> **−0.971 and −0.995** (0.024 ns spread) across completely unrelated modules: `inst_iqr_detection` (53
> paths), shell `inst_duplicator`/skid buffers, vhsnunzip `long_decoder`, `run_decoder` on decoders 0/1/3
> (139+35+33), `inst_read_regs` (41), `output_writer` FIFOs, dictionary crossbar. That is a **global
> routing/congestion limit**, not a dominant path — fixing the current worst path would buy **~0.008 ns**.
> **949 of 1000 failing paths are entirely inside user logic**; LUT is only **42.5%**, so it is congestion
> + SLR crossings, NOT capacity. (Calibration: the fix that bought +0.501 ns cost 683 LUTs. Area and WNS
> are nearly decoupled in this design.)
>
> **5. The current worst path (−0.995), for the record.** `iqr_histogram_feed/sk_occ` → round-robin arbiter
> → `keep` popcount → **`(fed + beat_elems) >= i_expected`** (a flat 64-bit add+compare = **8× CARRY8**) →
> `out.last` → `iqr_detection` FSM next-state → **SLR crossing 1→2 (one net burning 1.390 ns)** →
> `FSM_onehot_state_reg[0]/CE`. 17 levels, 71% route, +0.268 ns inter-SLR penalty. Feed placed at Y401
> (SLR1), FSM reg at Y481 (SLR2). This is the `i_expected` end-of-dataset mechanism. **PROVEN BENIGN** by
> the fused gate (count=0 under full 4-lane load). Cheap RTL fix IF another build ever happens (do NOT
> spend a build on it alone): keep a **registered `remaining = i_expected − fed`** and compare
> `beat_elems >= remaining[3:0]` — valid because `beat_elems ≤ 8` — which deletes all 8 CARRY8 levels.
>
> **6. ❌ DO NOT retry removing HBM.** Measured TWICE with proper pairing (point 2): it costs
> **0.66–0.68 ns**. The mechanism is **floorplan anchoring** (the HBM controller pins a block in SLR0;
> without it the placer scatters the four ~77k-LUT decoders across SLRs — build-26's worst path crossed
> **4** boundaries inside one decoder), NOT area pressure. HBM costs 40,010 LUTs = **3.1% of the device**
> at 42.5% utilization, so freeing it relieves nothing. Placement luck was ruled out by the reseed
> (`-directive ExtraTimingOpt` → −2.582). The only viable version of the idea is "remove HBM AND explicitly
> Pblock each decoder into one SLR" — upside bounded to ~0.1–0.2 ns, not worth 9 h.
>
> **7. ➡️ IF you ever need to actually MEET timing: `EN_UCLK=1` + `UCLK_F=200` (or 225).** This is the
> right lever for a flat wall and it is **OPTIONAL** — build-28 is correct and fast as-is. Put the user
> logic in its own slower clock domain: it targets exactly the right region (99.8% of failing paths are
> user logic) and leaves the **locked 250 MHz static-layer checkpoint** untouched (lowering `ACLK_F`
> needs `BUILD_STATIC=1`). Config lives in `parcore/libstf/coyote/cmake/FindCoyoteHW.cmake:191-194`
> (`EN_UCLK` default 0, `UCLK_F` default 250). 200 MHz → period 4.0→5.0 ns = covers the whole −0.995 wall;
> 225 MHz → +0.44 ns. **Throughput caveat now measured:** the fused run shows **eff 12.49 GB/s**, and
> 512-bit @ 200 MHz = 12.8 GB/s — that is cutting it close, so **prefer 225 MHz (14.4 GB/s)**. Costs: CDC
> FIFOs, new crossing paths, a config never yet built. **Pblocks are now LESS attractive than the old plan
> assumed** — they would fix the decoder clusters but leave IQR, the shell converters, vhsnunzip and
> output_writer all at −0.99.
>
> **Build inventory (WNS, config):** build-21 (1 dec, −0.355, report §4 1-lane) · build-23 (4 dec, HBM in,
> index in, −1.879 — previous production, report_2807; known-good fallback) · build-24 (index re-widen,
> −1.31, index mode BROKEN idx_pack) · build-25 (HBM out, index in, −2.562; reseed −2.582) · build-26 (HBM
> out, index out, −2.154, 513k LUTs) · build-27 (HBM in, index out, −1.496, 553k LUTs) · **build-28 (HBM in,
> index out, +diag pipeline, −0.995, 553,744 LUTs / 42.5% — PRODUCTION, silicon-validated 4/4 gates).**
> All .bit present on disk.
>
> **UNCOMMITTED (nothing committed across this arc — commit was offered, not done):**
> `hardware/CMakeLists.txt` (EN_MEM→1 + the anchor rationale comment), `hardware/src/vfpga_top.svh`
> (`ifdef EN_MEM` card tie-offs + `IQR_EN_INDEX` gating + `iqr_idx_on` output steering),
> `hardware/iqr_app/hdl/IQR_detection.sv` (`EN_INDEX` param + 3 gated index regions + the pipelined diag
> reduction), `hardware/build-25/pnr_reseed.tcl` (new P&R reseed harness). Plus prior-session uncommitted:
> index re-widen (RTL + host), `report_2807.md`, bench logs.

> 🏁 **NEWEST (2026-08-04). WNS-FIX ARC on build-23. Two levers tried to beat build-23's WNS −1.879:
> (A) remove the unused HBM stack, (B) remove index mode. Verdict: (A) BACKFIRED (HBM was a floorplan
> anchor), (B) WORKED (+0.408 ns, index-mode logic gone, sim-proven). Net still short of build-23 because
> the DECODERS straddle SLRs. Now rebuilding build-27 = HBM back IN + index OUT; Pblocks are the fallback.**
>
> **Baseline: build-23 = −1.879 ns**, worst path `iqr_histogram_feed → iqr_detection/idx_pack` (1 SLR
> crossing). This is the design report_2807 was measured on — bit-exact value path, HBM in, index in
> (index unused by the numbers). ⚠️ **SUPERSEDED 2026-08-05: use `build-28` (see the top banner);
> build-23 is now only the known-good fallback.**
>
> **1. ⚠️ HBM removal BACKFIRED (EN_MEM 0 → build-25/26).** The HBM controller pins a block in SLR0 and
> was acting as a FLOORPLAN ANCHOR; removing it un-anchored the placer → the four ColumnChunkDecoders
> scattered across SLRs. **build-23 (HBM in) −1.879 → build-25 (HBM out) −2.562** (−0.68 ns), worst path
> became decoder-INTERNAL crossing 2–4 SLR boundaries. Reseed (place `-directive ExtraTimingOpt`, P&R-only
> from `shell_opted.dcp`) → **−2.582** = NOT placement luck, it's structural. Lesson: WNS here is dominated
> by SLR crossings, NOT capacity (LUTs only ~40%); "lighter" ≠ better timing. **HBM kept IN going forward.**
>
> **2. ✅ Index mode RETIRED (RTL) + SIM-PROVEN.** Supersedes the old build-25 "pipeline `IqrIndexPack`"
> plan — index mode is REMOVED, not fixed. Compile-time `parameter bit EN_INDEX=1'b0` in
> `IQR_detection.sv` gates `IqrIndexEncode/IqrFenceIndex/IqrIndexPack/IqrIndexFlag` behind `generate if`
> (else-branches tie off `o_idx_*`/`o_flagw_*`/fences/`idx_pack_ready`); `wire idx_mode = EN_INDEX &
> i_idx_mode` folds every FSM/ready/out branch to the value path. `vfpga_top.svh`: `localparam
> IQR_EN_INDEX=1'b0`, threads `.EN_INDEX`, gates `IqrWideFlagPack`, folds output steering via `iqr_idx_on`.
> Value path BIT-IDENTICAL to build-23. **Sim PASS:** `run_fused_integration_tb` (96 flags match,
> dbg_total==N, mux OK), `run_bins4096_tb` (300 outliers, 0 errors). `iqr_index*.sv` module files kept
> (uninstantiated → not synthesized; their standalone unit TBs still pass; `tb_iqr_idx_mode` now obsolete).
>
> **3. build-26 (HBM out + index out): WNS −2.154.** Index removal recovered **+0.408 ns** (−2.562→−2.154)
> and the `idx_pack` failing cluster is GONE. LUTs 565k→**513k**. BUT still 0.275 ns worse than build-23,
> and **100% of top failing clusters are now DECODERS** (`inst_run_decoder` ×4 lanes + `inst_typed_dictionary`);
> worst path crosses **4** SLR boundaries inside one decoder. So the decoders straddling SLRs are the sole
> remaining obstacle.
>
> **4. ➡️ NOW BUILDING: build-27 = HBM back IN (EN_MEM 1) + index OUT.** Config in tree: `EN_MEM 1`,
> `N_CARD_AXI 1`, `EN_INDEX 0`. THE BET: build-23's limiting −1.879 path WAS `histogram_feed→idx_pack`,
> which is now deleted; restoring the HBM anchor + keeping index out should land **better than −1.879**,
> possibly MEET timing, with zero floorplanning. `scripts/synthesize.sh --no-rdma --decoders 4 --cores 32`
> (full ~9 h, netlist change). Check `analysis.txt` WNS + confirm no `idx_pack` and whether the worst path
> is still a decoder SLR crossing.
>
> **5. FALLBACK if build-27 still short: Pblock the decoders per-SLR.** Pin each of the 4
> `genblk1[N].inst_column_chunk_decoder` into a single SLR so no decoder-internal path crosses a boundary
> (100% of failing paths are decoder-internal). P&R-from-linked ≈ 7 h. Reseed harness exists:
> `hardware/build-25/pnr_reseed.tcl` (resumes `shell_opted.dcp`, varies place `-directive`, writes tagged
> checkpoints/reports, prints WNS). Reference: pre-route phys_opt "Estimated Timing Summary" is UNRELIABLE
> (±0.5–1.5 ns) — only trust POST-ROUTE WNS.
>
> **Build inventory (WNS, config):** build-21 (1 dec, −0.355, report §4 1-lane) · **build-23 (4 dec, HBM
> in, index in, −1.879 — PRODUCTION, report_2807, bit-exact; USE THIS)** · build-24 (4 dec + index re-widen,
> −1.31, index mode BROKEN idx_pack) · build-25 (HBM out, index in, −2.562; reseed −2.582) · build-26 (HBM
> out, index out, −2.154, 513k LUTs) · build-27 (HBM in + index out, building/next). All .bit present on disk.
>
> **UNCOMMITTED this session:** `hardware/CMakeLists.txt` (EN_MEM→1, anchor comment), `vfpga_top.svh`
> (`ifdef EN_MEM` card tie-offs + `IQR_EN_INDEX` gating), `IQR_detection.sv` (EN_INDEX param + 3 gated
> regions). Plus prior-session uncommitted: index re-widen, report_2807.md, bench logs. Nothing committed.

> 🏁 **NEWEST (2026-07-28, node alveo-u55c-07/-10). build-23 [4 decode lanes, 4096 bins] VALIDATED ON
> SILICON — the 1-decoder regression is GONE. Index mode re-widened for 4096 and built (build-24): it's
> FAST but WRONG on silicon — `idx_pack` misses timing → build-25 must pipeline it.**
>
> **1. build-23 = production bitstream.** `hardware/build-23/bitstreams/cyt_top.bit` (4 lanes, 4096).
> Decoder fix confirmed: sf10 `decode` **360→126 ms**, `fpga_wait` **246→27 ms**. sf10 back to a win:
> value path op **200 ms (1.58×)**, **fused op 137 ms (2.33× op / 2.26× e2e)**. Correctness gate clean
> (taxi_d3=104, sf10=0). Full sweep (consume, geomean **1.67× e2e**, extprice **3.21×**) in report_2807.
>
> **2. Index re-widen DONE (RTL + host), committed to the working tree, NOT yet correct on silicon.**
> `IDX_W` 14→16, `IDX_BITS` 16→32, `o_flagw_data`/`IQR_FLAGW_LANES` `/16`→`/32`, host `IDX_PER_BEAT`
> 32→16, guard `NUM_BINS>1024`→`>4096` (`iqr_runner.hpp`). Sim-clean: `tb_iqr_index` (204,884 combos, 0
> err at 4096/16), `tb_iqr_index_stream` (32/16), leak TB, `tb_iqr_bins4096`. **build-24** =
> `hardware/build-24/bitstreams/cyt_top.bit` (4 lanes + re-widen, bitgen OK, WNS −1.31).
>
> **3. ⚠️ build-24 index mode: FAST but INCORRECT — `idx_pack` timing defect.** Index mode engages ONLY
> on the FUSED path (`set_idx_mode` is in `begin_fused`), so on our datasets only sf10 fuses. Fused+idx
> on sf10: **SPEED WORKS** — `passes` **38.4→19.2 ms (2×)**, heavy **140.9→122.3 (−13%)**, INPUT beats
> halved (N/8→N/16). **BUT count = 9 (then stable 4) vs true 0** = spurious flags. Root cause found:
> build-24 failing paths are `inst_iqr_detection/inst_idx_pack/iqr_idx_data[...]` (WNS ≈ −1.33 ns) — the
> 32-bit packer's 512-bit shift/output register misses setup → corrupts indices. Deterministic within a
> session, varies across (classic setup-timing signature). **taxi_d3/d4 HANG** the index drain (same
> defect corrupts beat/`o_last` accounting on ragged chunks). Algorithm is sim-exact; this is pure
> timing. **FIX = pipeline `IqrIndexPack`** (split the 512-bit `shift_in→o_data` into 2 hops; it runs in
> pass 1, not throughput-critical, so +1 cycle is free) → **build-25**. Optionally drop `EN_MEM` (unused
> HBM, 2 of build-23's top failing clusters) to relieve congestion.
>
> **4. Index-mode POTENTIAL (projected, build-24, forced fusion all sizes).** Only sf10 gains: e2e
> **150→131 ms (−13%)**, FPGA/C++ **2.19→2.52×**; ≤13M flat (pass 2 too small a share). Numbers are
> timing-only (counts wrong); taxi_d3/d4 unmeasurable (hang). In report_2807 §6, labeled projected.
>
> **5. `report_2807.md` is today's deliverable** (all END-TO-END, consume, NO materialization — the right
> metric for the in-memory-array/filter use case; `CREATE TABLE` adds a ~70% single-threaded append tax
> that dilutes ratios toward 1.0 and is NOT our use case). Sections: window background (scheme), §1 C++
> vs SQL (geomean 1.16×), §2 FPGA vs C++ (1.67×), §3 fusion on/off + how-fusion-works, §4 decoder 1-vs-4
> + per-dataset, §5 1-line SQL vs group-by (4.5×), §6 index potential, WNS-vs-decoders note, cardinality
> + index-mode appendices. Cardinality measured: tpch_qty 50, taxi ~9–15k, extprice 934k, sf10 1.35M —
> the high-card PLAIN columns (extprice/sf10) are decode-bound → gain most from lanes.
>
> **➡️ NEXT (in order):** (1) **build-25** = pipeline `IqrIndexPack` (RTL + re-run the 4 index TBs), then
> synth on hacc-build-02 `--decoders 4` (~10–11 h), flash, re-test fused+idx correctness (sf10 count must
> = 0) + speed (passes ~19 ms) + taxi_d3/d4 no-hang. (2) then index mode ships. **UNCOMMITTED:** index
> re-widen (RTL + host), report_2807.md, all today's bench logs. Nothing committed this session.

> 🏁 **NEWEST (2026-07-27, node alveo-u55c-07). build-21 (4096-bin) ON SILICON: taxi accuracy CLOSED,
> obstacle-1 per-row proven, defaults flipped. ONE build mistake: it was synthesized with 1 decode lane
> instead of 4 (regressed decode-bound sf10/extprice) → build-23 (4 lanes, same RTL) is rebuilding.**
>
> **build-21** = `hardware/build-21/bitstreams/cyt_top.bit` (WNS −0.355 ns; failing clusters are
> `iqr_wide_packer`/`idx_pack` = index-mode logic, guarded OFF at 4096 — value path clean). LUTRAM
> 10240→40960 confirms 4096 bins really synthesized (4×). ⚠️ **Built `--decoders 1` (CMake default) — a
> flag omission, not a choice; build-20 used `--decoders 4`. See point 4.**
>
> **1. 4096 bins + IQR-window rule → taxi is now correct AND fast on the MEMCPY (shipping) path.**
> `fpga_vs_cpp` (per-row vs C++-exact, `correctness_3way.sh flags`), memcpy path, DEFAULTS:
> taxi_d1 **0**, taxi_d2 **0**, taxi_d3 **104** (0.0008%), taxi_d4 **0** exact, tpch/extprice/sf10 **0**.
> vs build-20 (1024): 1247 / 2877 / 162 / 54921. **Every taxi set improved.** The lever was NOT bin count
> — 4096 alone on the old p1/p99 window REGRESSED taxi_d3 to 31,496; the fix was porting the
> `WINDOW_IQR` rule ([Q1−2·IQR, Q3+2·IQR]) into `IqrRunner::derive_window` (the memcpy window). Overlap
> gate 200/200 on ov_uniform + ov_drift.
>
> **2. Obstacle-1 (ragged stitch) FIXED and PER-ROW PROVEN.** With `STREAM_RAGGED` taxi_d3/d4 fuse
> (`sink=stream pass1=fused`, no deadlock). Per-row check (`bench/fused_perrow.sh` +
> `bench/compare_dumped_flags.py`, via new `OASIS_IQR_DUMP_FLAGS`): `net_diff == per_row_mismatch`
> exactly (d3 104/104, d4 0/0) → **zero row swaps**, no bit-shift mislabel. The repack is real.
>
> **3. Fusion is a wall-clock LOSS at taxi sizes, a CPU-seconds WIN.** medians (`--cpp-impl groupby`):
> memcpy op 36.1/54.1 ms (FPGA/C++ **1.43×/1.33×**) vs fused 43/62 ms (1.19×/1.16×) — fusion +7 ms op,
> but CPU-seconds C++/FPGA **2.7× → 4.9×**. Dropping WINDOW_FPGA doesn't recover latency (it's fusion
> overhead, not the window pass) and hurts CPU-s. So: **taxi stays memcpy for latency; fusion only wins
> wall-clock at sf10 scale (§9.19).** Therefore `fuse_min_rows` RAISED **10M → 30M** — taxi_d3/d4 stay
> memcpy; sf10+ (and any >30M taxi-shaped column) fuses, and fusion is proven per-row exact when it does.
>
> **4. ⚠️ DECODER REGRESSION (the build mistake) — 1 lane vs build-20's 4.** e2e sweep (index OFF, 4096,
> 1 lane) vs build-20 (4 lanes): decode-bound rows regressed hard — sf10 op **136 → 436 ms (0.74×, now
> LOSES to CPU)**, extprice 21.7 → 49 ms; taxi/tpch_qty ~flat. `OASIS_IQR_TIMING` isolates it: sf10
> `decode` **92 → 360 ms**, `fpga_wait` **31 → 246 ms** (host idle on the single decoder), `passes`/
> `win_derive` unchanged. Confirmed structural: `N_DECODERS` CMake default = 1; build-20 cache = 4,
> build-21 = 1; decoder LUTs 307,988 → 76,417. **Fix = rebuild same 4096 RTL with `--decoders 4`:**
> **build-23** running on hacc-build-02 (`scripts/synthesize.sh --no-rdma --decoders 4`, full opt ~9h,
> started ~11:12, ETA ~20:00). Expect sf10 `decode` → ~90–110, `heavy` → ~170 (memcpy)/~137 (fused),
> sf10 back to a win. Even at 1 lane the FPGA still wins **6/7 operator** and **7/7 CPU-seconds**
> (2.6–8.1×). Full 1-decoder tables (the compare-against baseline) in **results_new.md §11c**.
>
> **5. Index mode — RTL healthy (5/5 sim TBs), dormant at 4096.** Re-ran all index TBs: index≡value
> (0 err), core match (7 scen), `o_last` drain (7 scen), and the two leak TBs go RED→GREEN (`i_restart`
> `run_wide_pack_reset_tb` LEAK 192→CLEAN; `run_indexflag_last_tb` LEAK 128→CLEAN) — the §9.23 multi-query
> defect fix is proven and rides build-21/23. Still guarded off at 4096 (14-bit index saturates: fence
> idx ~+20475 vs ±8191). Speedup already measured (build-20/1024): pass 2 **38.41→9.69 ms (3.96×)**, sf10
> heavy 139→110 (−21%). To run index live at 4096: re-widen (`IDX_W` 14→16, `IDX_BITS` 16→32, 3× `/16`
> sites) → **build-24 after build-23 validates**. Do NOT revert to 1024 (throws away the taxi accuracy).
>
> **DEFAULTS FLIPPED ON (build-21):** `OASIS_IQR_WINDOW_IQR` (memcpy+fused window rule),
> `OASIS_IQR_STREAM_RAGGED` (host stitch), `fuse_min_rows=30M`. All env-overridable (`=0` to disable).
> Index mode still OFF (guarded — throws >1024 bins). New tooling: `bench/fused_perrow.sh`,
> `bench/compare_dumped_flags.py`, `bench/e2e_sweep.sh`, `OASIS_IQR_DUMP_FLAGS`. **Host rebuilt
> (software+install+shell).** Verify shipping default: `bench/correctness_3way.sh flags` NO env → d3 104.
>
> **➡️ NEXT (in order):** (1) build-23 finishes → `head -20 hardware/build-23/analysis.txt` (ship if
> failing paths are index-mode `iqr_wide_packer`/`idx_pack`; worry only if value-path decoder/IQR).
> (2) flash build-23 + hugepages, re-run `bench/e2e_sweep.sh` → confirm sf10 `decode` 360→~90–110 and
> op back to a win (compare vs §11c 1-decoder table). (3) `bench/correctness_3way.sh flags` NO env → taxi
> still correct. (4) then build-24 = index re-widen at 4096. **UNCOMMITTED:** default flips + derive_window
> IQR rule (`oasis_iqr.cpp`, `iqr_runner.cpp`) + tooling + these docs; RTL 4096 is committed `2fbea51` on
> `feature/iqr-integration`. Commit was offered, not yet done.

> 🟢 **NEWEST (2026-07-26, later session). Implemented two changes the previous banner planned; both are
> code-complete and offline-verified, NEITHER is on silicon/hardware yet. Nothing committed.**
>
> **A. 4096 histogram bins — DONE (value/histogram path) + cocotb tests written & offline-verified.**
> Changed `NUM_BINS` 1024→4096 at both tops (`hardware/src/vfpga_top.svh:460`,
> `hardware/src/iqr_cosim_top.svh:290`) and both host constants (`iqr_runner.hpp` NUM_BINS,
> `oasis_iqr.cpp` IQR_HW_NUM_BINS). `BIN_IDX_WIDTH`/scan widths auto-derive via `$clog2` — nothing else
> in `IQR_detection.sv` needed touching. Debug ILA is compiled out, so `init_ip.tcl` probe widths are
> inert (unused IP) — left alone. **Index mode NOT re-widened** (its 14-bit index saturates >1024 bins):
> instead GUARDED — `IqrRunner::enable_index_pass2` throws for NUM_BINS>1024, with a comment at
> `IQR_detection.sv` IDX_W. That re-widen (IDX_W→16, IDX_BITS→32, the `/16` sites in `o_flagw_data` +
> `IQR_FLAGW_LANES` + host `IDX_PER_BEAT`) is deferred with index mode (still shelved). **Tests:** two new
> methods in `hardware/unit-tests/iqr_detection_test.py` — `test_bins_above_1024_resolved` (Q1/Q3 in
> high bins: 4096→6 outliers vs a clamped 1024→384) and `test_fence_cluster_1024_misses_4096_resolves`
> (taxi_d3 in miniature: exact=300, 4096→300, 1024→**0**, i.e. 1024 misses the whole cluster), both
> **verified offline** against the file's own reference model.
>
> **✅ FUNCTIONALLY SIM-VERIFIED ON NODE (hacc-build-02):** the cocotb `iqr_detection_test.py` path is
> blocked by a PRE-EXISTING coyote AXI-monitor incompatibility (strict `tvalid`/`tready` X-checks fatal
> even the STOCK 16-bin tests on a freshly-regenerated `build-sim`; added the missing card-stream
> tie-off to `vfpga-tops/iqr_detection_test.sv`, which cleared `tvalid` but a `tready` X-check on
> `axis_host_recv[0]` remains — infra, not the change). So I proved the RTL the reliable way instead: a
> **standalone xsim TB** `hardware/unit-tests/tb_iqr_bins4096.sv` (+ `run_bins4096_tb.sh`) drives the
> full `IQR_detection` core at NUM_BINS=4096 through raw ndata (no shell). **red→green→revert PASSED:**
> at 4096 (shift 2) it flags exactly the 300 cluster rows and nothing else; flip NUM_BINS→1024 (shift 4,
> auto-derived) and it flags **0** — reproducing 1024→0 / 4096→300 on silicon RTL. Elaboration is clean
> at BIN_IDX_WIDTH=12; the histogram loses no counts (dbg_total==N). **Run:**
> `source /tools/Xilinx/Vivado/2024.2/settings64.sh && bash hardware/unit-tests/run_bins4096_tb.sh`.
>
> **B. Obstacle-1 (ragged 8-multiple packer) — REFRAMED to a HOST-SIDE fix (NO bitstream) and DONE.**
> Traced it to the bit level: `stream_pass` sends one Coyote transfer per chunk with `last` only on the
> final one, and FlagBitPacker shifts 8 bits/beat regardless of keep → each chunk lands byte-padded
> (8·ceil(nv/8) bits). If transfers are beat-aligned (the streaming-guard comment says they are), the
> flags are byte-aligned per chunk and the host just mis-read them as one contiguous stream. **Fix
> (approved by user over the RTL word-flush alt): `IqrRunner` sizes the flag drain for the padded
> footprint (`padded_flag_bytes`) and folds it back to a dense bitmask (`repack_ragged_flags`), so the
> extension emit path is UNCHANGED.** Wired into `run`/`finish_fused`/`finish_overlapped`
> (`has_intermediate_ragged` gate — no-op unless a chunk before the last is not a multiple of 8; idx/card
> single-chunk paths unaffected). Guard-lift is env-gated **OFF by default**: new
> `OASIS_IQR_STREAM_RAGGED=1` (`oasis_iqr.cpp`) lifts the two ragged guards the CORRECT way (distinct
> from the test-only `OASIS_IQR_FORCE_STREAM`, which only preserves the count). **Test:** the repack
> algorithm is unit-tested standalone in `bench/repack_ragged_flags_test.cpp` (20,006 cases, 16,228
> ragged, 0 fails — build: `g++ -O2 -std=c++17 bench/repack_ragged_flags_test.cpp -o /tmp/rt && /tmp/rt`).
> `iqr_runner.cpp` passes `-fsyntax-only`. **Assumes beat-aligned transfers — validate on hardware with
> the taxi 3-way correctness test + `OASIS_IQR_STREAM_RAGGED=1` before making it default.** The stitch is
> bin-count-independent, BUT the host now carries IQR_HW_NUM_BINS=4096, which only matches a 4096-bin
> bitstream — so validate it on the NEW bitstream (both changes together). To check the stitch in
> isolation on the CURRENT 1024-bin card first, temporarily set both host bin constants back to 1024.
>
> **⚠️ Build gotcha (both changes):** the runner edits are in `software/oasis/*`, but the extension links
> the INSTALLED headers in `~/opt/include/oasis` (stale). Order: rebuild `software/build`,
> `cmake --install .`, THEN `cmake --build extension/build/release --target shell`. (Confirmed: a naive
> syntax-check picked up the stale `~/opt` header until `-Isoftware` was put first.)
>
> **➡️ Next-bitstream is now smaller:** just the **4096-bin** RTL. Obstacle-1 no longer needs a bitstream
> (host-side). Index-mode **i_restart fix STILL RIDES this bitstream** (`IqrWideFlagPack.i_restart` +
> its `vfpga_top.svh` wiring are untouched) — but **dormant**, since index mode is guarded off at 4096
> bins (`enable_index_pass2` throws). It costs nothing and is ready if index mode is later re-widened.
>
> **🎯 taxi_d3 (and taxi_d4) fusion needs THREE INDEPENDENT pieces — miss any one and it's wrong:**
> (1) **STREAM_RAGGED** host stitch → lets taxi's odd-sized row groups *stream* (the precondition to
> fuse); without it taxi falls to memcpy and never fuses. (2) **4096 bins** → correct count at the fence
> (kills the −31,791); a *resolution* fix. (3) **WINDOW_IQR** (`OASIS_IQR_WINDOW_IQR`, Q1..Q3 window) →
> a *stable* fused window; the default p1/p99 sampled rule is **bistable** on tail-heavy taxi (count
> flipped 1296479↔1328108). These are ORTHOGONAL: WINDOW_IQR alone stabilized taxi_d3 on the WRONG value
> (fence miss still there); 4096 alone can't cure the bistability (it's p1/p99 power-of-2 rounding, not
> bin count). **Fusion's window is sample-based** (it can't see the full column); the non-fused/memcpy
> path uses the robust full-column `derive_window`, which is why taxi has been correct on memcpy and only
> shows window trouble WHEN fused. Today only sf10 fuses (not tail-heavy → sampled window fine). **PLAN:
> make BOTH `STREAM_RAGGED` and `WINDOW_IQR` default alongside the 4096 bitstream**, then validate taxi
> fused with the 3-way test. (Currently both are env flags, default OFF.)
>
> **✅ COMMITTED (2fbea51 on `feature/iqr-integration`), tree clean.** The commit also carries prior
> uncommitted work (i_restart TBs, correctness_3way/methods_ab/window benches, RESULTS/results_new docs).
> NOTE: `build-sim` was regenerated on-node (old one stale/broken); `setup_simulation.sh` needs
> `source /tools/Xilinx/Vivado/2024.2/settings64.sh` + `export TERM=xterm` (cmake FindVivado / a `tput`
> color proc both fail without them).

> ⚡ **NEWEST (2026-07-26, node alveo-u55c-07). Re-verified the study end to end and designed the next
> bitstream. NOTHING NEW IS ON SILICON — all RTL work below is simulation/emulation-proven only, and the
> source tree + built `duckdb` binary carry uncommitted, mostly test-only changes.**
>
> **1. Correctness re-verified 3-way** (`bench/correctness_3way.sh`, new): FPGA vs C++ `iqr_cpu_flags_groupby`
> vs DuckDB built-in `quantile_disc`. **cpp_vs_oracle = 0 on all 7** (our GROUP BY quartile == built-in,
> exact), fpga_vs_cpp = the documented binning gaps (1247/2877/162/54921/0/0/0). quartiles_match=true,
> floor-fence == textbook-1.5×-fence everywhere. **Timing re-run** (medians of 15): FPGA/C++ geomean **1.74×**
> e2e / **1.95×** operator, C++/SQL **1.16×**, CPU-seconds **2.6–12×**. Method A/B (`bench/methods_ab.sh`):
> our C++ is the **fastest EXACT IQR** — beats built-in `quantile_disc` ~6× and even `approx_quantile`.
>
> **2. Index-mode `i_restart` fix — DONE in RTL + SIM-PROVEN, not on silicon.** Root-caused the §9.23
> 2-spurious-flag defect: `IqrWideFlagPack` had no per-column reset, so a column left un-flushed leaks its
> bits into the next column's first word. **Confirmed suspect #2**: `IqrIndexFlag` withholds `o_last` when
> `i_expected` overshoots the delivered beats → packer never flushes → leak. Fix: added `i_restart` to
> `IqrWideFlagPack` (`hardware/src/hdl/iqr_index_stream.sv`, default 0) + wired to `iqr_clear_req`
> (`hardware/src/vfpga_top.svh`). Two new TBs (`tb_iqr_wide_pack_reset`, `tb_iqr_indexflag_last`) go
> red→green→revert-check; existing index TBs still pass. **Needs a bitstream to reach silicon.**
>
> **3. Fusion window reliability — diagnosed, half-fixed in SW, needs 4096 bins in RTL.** Fusion's 16-group
> sampled window is **bistable** for taxi_d3 (count flips 1296479↔1328108 across group counts) — traced to
> the p1/p99 **power-of-2 bin_shift rounding** in `WindowFromSample`. Added `OASIS_IQR_WINDOW_IQR=1` (sizes
> the window from Q1..Q3, `[Q1-2·IQR, Q3+2·IQR]`) — **removes the bistability** (stable across all group
> counts). BUT taxi_d3 still undercounts by 31,791: a **fence-vs-cluster quantization** issue — ~30k-row
> fare spikes (4010, 4080, 4150) sit within one 8¢ bin of the ~4005 fence, and the binned fence lands on
> the wrong side. **Proven in faithful emulation** (1024-bin emul reproduces the exact silicon fused count
> 1296479): **1024→Δ−31791, 4096→Δ−104, 8192→Δ0**. **➡️ WE WILL IMPLEMENT 4096 BINS** — it fixes taxi_d3
> to 8 ppm and makes the FPGA more accurate on *every* dataset. Runtime impact ~0 (decode-bound); cost is
> RTL: `NUM_BINS` in `hardware/src/init_ip.tcl` + host constants (`oasis_iqr.cpp:238`,
> `iqr_runner.hpp:192`) must move together, `BIN_IDX_WIDTH` 10→12, index-mode `IDX_W` 14→16 (maybe
> `IDX_BITS` 16→32), 4× histogram BRAM on a timing-tight design.
>
> **4. ⚠️ REMEMBER — Obstacle 1 (ragged 8-multiple packer) is NOT fixed; we only bypassed it to measure.**
> taxi_d3/d4 fall to memcpy because a non-final chunk with `num_values % 8 != 0` mis-aligns the streaming
> pass-2 flag packer. To *measure* fused taxi we added a **TEST-ONLY** `OASIS_IQR_FORCE_STREAM=1`
> (`oasis_iqr.cpp`, default off) that skips the ragged guard. **It produces MISLABELED per-row flags
> (correct COUNTS only) — it is NOT a shipping fix. NEVER ship with it on.** The real fix is the RTL
> **flag-packer byte-realign** (byte-align at each chunk `last`, FSM stays in FLAG until the final chunk,
> host stitches per-chunk offsets) — a bitstream. So taxi still runs on memcpy in reality.
>
> **➡️ THE NEXT BITSTREAM BUNDLES THREE RTL FIXES:** (1) flag-packer byte-realign (obstacle 1 → taxi can
> stream/fuse), (2) **4096 bins** + keep the IQR-window rule as default (obstacle 2 → fusion accurate &
> reliable), (3) index-mode `i_restart` (enable index mode by default). After it: taxi_d4 fuses (a win,
> ~45–48 vs 51 ms memcpy, accurate at 16 groups); taxi_d3 fuses accurately; index mode ships.
>
> **UNCOMMITTED / carried in the tree (nothing committed this session):** `oasis_iqr.cpp`
> (`OASIS_IQR_FORCE_STREAM`, `OASIS_IQR_WINDOW_IQR` — both gated off by default), the RTL `i_restart` fix +
> 2 TBs + run scripts, bench scripts (`correctness_3way.sh` + 3 sql, `methods_ab.sh`, `window_groups_sweep.sh`),
> and `results_new.md`. The `duckdb` binary was **rebuilt** (has FORCE_STREAM + WINDOW_IQR). **The Coyote
> driver was rebuilt for kernel 6.8.0-136** (the NFS-shared `.ko` — see the driver-mismatch gotcha in §1).

> ✅ **2026-07-24 FINAL (RESULTS.md §9.35). The CPU baseline is now the GROUP BY transliteration
> (`iqr_cpu_flags_groupby`) and BOTH conditions hold: the FPGA beats it on all 7, and it beats the SQL
> on 5 with 2 ties.** Config: radix aggregation + `new[]` scatter buffer + thread pool + pooled
> allocator + parallel `order` sort ("A"). **No B, no C** — §9.34 has the argument for why no
> configuration reaches 7/7 on both conditions (taxi_d3/d4 bands are 1.36–1.41× against ±19–26 % noise).
> Headline: **FPGA 1.31–3.42× e2e (geomean 1.77×), 1.43–3.88× operator (geomean 1.95×), 2.6–12.0× fewer
> CPU-seconds**, over a baseline that is itself **1.00–1.53× faster than the SQL** (geomean 1.16×).
> **Never write "7/7 C++ beats SQL"** — tpch_qty 1.00× and taxi_d4 1.01× are ties; the prior run had the
> same C++ numbers reading 0.94× / 0.99×. `--cpp-impl zoom` still selects the old histogram baseline;
> `OASIS_IQR_CPU_RAW_ALLOC=1` restores raw `new[]`/`delete[]`.

> ⚠ **2026-07-24: the whole
> matrix re-measured on silicon (§9.27).** `quart` 25.2 -> 39.63 ms (1.57x) is confirmed, but the WARM
> operator median moved only +3.9 % (143.8 -> 149.4) — less than predicted and **not yet explained**;
> see §9.27's flag before attributing anything to the geometry. **§9.27 supersedes §2's table.**
> Headline now: **5 wins / 2 losses on e2e in both index modes**, sf10 e2e **1.10x** (idx OFF) /
> **1.36x** (idx ON), CPU-seconds **1.88–6.31x**.
>
> ⚠ **The index-mode defect ESCALATED (§9.27):** it now reproduces in a **fresh single-query process**
> (not just multi-query sessions) **and the accuracy gate fails** (ov_uniform overlap=0 -> 201 vs 200,
> was 200/200). Surviving process exit means it is **card state** -> suspect #1 (`IqrWideFlagPack` has
> no `i_restart`) is now strongly indicated, not merely likely.

> **NEWEST FIRST (2026-07-24): build-20 ON SILICON. The wide flag emit delivered. One open defect.**
>
> **1. WIN — pass 2 is 3.96× faster.** sf10 index mode: `passes` **38.41 → 9.69 ms**, `heavy`
> **139.00 → 110.05 ms**. The profiler proves the mechanism: input **`stalled` 80 % → 0 %**, `eff`
> 3.19 → **12.38 GB/s**. Pass 2 is now PCIe-bound at the same rate as the value path while moving 4×
> fewer beats. §9.21's diagnosis was right and removing the throttle gave exactly the predicted 4×.
> **Step-1 regression reproduced build-16/19 exactly** (139.00 / 38.41 / count 0) → the −2.131 ns
> `--fast` miss is benign.
>
> **2. WIN — the `o_last` hang fix is validated.** `overlap_ab.sh accuracy` = **200/200 on BOTH**
> ov_uniform (N=20,000,000 = a multiple of 32 — the case that WEDGED the card) and ov_drift, both
> configs, no timeout. The multiple-of-32 drain deadlock is gone.
>
> **3. Medians improved (with the §9.18 Defect-3 CPU fairness fix):** **sf10 e2e 1.05× → 1.31×**,
> **operator 0.68× → 1.33×** (FPGA now wins operator: 108.3 vs C++ 143.8 ms), **CPU-seconds 6.34×**.
> Surviving claim range **CPU-seconds 2.1–6.3×**. Full table in §2.
>
> **4. ⚠️ OPEN DEFECT — index mode flags 2 spurious outliers in MULTI-QUERY SESSIONS.**
> `cpu_op_correctness.sql` with `OASIS_IQR_IDX_PASS2=1` gives sf10 `n_fpga=2` (gate is 0); the other six
> datasets are exact. **Isolated: 0 (5/5 stable). In a session after other queries: 2.** Sequence
> dependent — NOT threads, NOT run-to-run noise, NOT the window (both windows give 2), NOT the value
> path (clean). **The 2 rows are `rn`=13 and 25 — inside the FIRST 32 elements** = first index beat /
> first packed word ⇒ **state-leakage signature.** Leading suspect: **`IqrWideFlagPack` has no
> `i_restart`** (I gave `IqrIndexPack` one but not the wide packer), so residual `acc`/`filled` bits
> survive into the next column's first word. Second suspect: the index-buffer round-trip.
> **NOT root-caused yet. Index mode stays OFF by default — nothing shipped is affected.** Do NOT
> treat "2 rows / 0.033 ppm" as a bound: it is a sample, and first-word corruption is not a bounded
> approximation the way bin-edge quartiles are. Details + the reproduction command: **§9.23**.

> **PREVIOUS (2026-07-23, eve): build-19 TESTED ON SILICON. Two verdicts, both against step 2.**
> 1. **Step 2 gives NO speedup.** sf10 `passes` **38.4 → 37.7 ms** (index mode ON), not the projected
>    ~10 ms. The 4× traffic cut is REAL (input beats 7,498,257 → **1,874,565** = exact ceil(N/32)), but
>    the profiler shows pass 2 is **flag-emit-bound, not PCIe-bound**: input stalls 80 % (`starved 0 %`),
>    the core emits only ~6.4 flags/cycle in BOTH modes. Cutting PCIe traffic buys nothing until the
>    flag emit is widened (~32 flags/cycle). **Step-1 regression reproduced build-16 EXACTLY**
>    (heavy 139.5, passes 38.4) → the −2.124 ns `--fast` timing miss is benign.
> 2. **Step 2 HUNG on ov_uniform** (N=20,000,000 = 625,000×32). Root-caused, fixed, sim-proven (below).
>    `IqrIndexPack` asserted `o_last` only on its flush beat, so a column whose element count makes the
>    final beat FULL (no partial to flush — every multiple of 32, and more) left the index DMA unclosed
>    → host `drain_to_buffer` → `BypassStreamReceiver::next()` (no timeout) hung → 120 s. sf10 (N mod
>    32 = 4) survived only because its flush supplied the `last`; the 200 outliers were a red herring.
>    **Fix committed to RTL + TB** (`iqr_index_stream.sv` gains `i_expected`; final full beat carries
>    `o_last`). `tb_iqr_index_stream` now checks the packer's `o_last` (the blind spot that let it ship)
>    — fails 5 scenarios reverted, passes 12 fixed. NOT on silicon; index mode stays OFF by default.
> **Verdict: index mode is RTL-correct-once-reflashed but pays nothing until the flag emit is widened —
> SHELVED. Do not spend a bitstream on it alone.** Full write-up: **RESULTS.md §9.21**.

> **NEWEST FIRST (2026-07-23, 12:00): build-16 IS VALIDATED ON SILICON. The fusion works and is
> DONE.** sf10's operator **169.6 → 137.0 ms (−19 %)**, end-to-end **0.85× → 1.05×**, CPU-work
> **6.07× preserved**, and **every correctness number at its documented baseline** (taxi_d3 back to
> 162, `ov_drift` exactly 200). Full write-up: **`bench/RESULTS.md` §9.19**.
>
> Getting there: build-15 hung the decoder silently (arbiter bug in `IqrHistogramFeed` — payload from
> last cycle's granted lane while `valid` followed *any* lane → early `last` → deadlock). Fixed, and
> proved with two xsim testbenches that both fail when the fix is reverted.
>
> Shipping config — fusion is **gated**, and that is deliberate:
> ```
> OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_DECODE_WINDOW=16
> ```
> `fuse = FUSE && rows > 10M && streaming sink` → **only sf10 fuses today.** Both gates read the
> cached footer, so no decode is wasted deciding. See §3 for why.
>
> **IN FLIGHT — build-19 (`--fast`, ~4–5 h).** Carries TWO new changes, both simulation-proven but
> **NOT yet on silicon**: **step 2** (pass 2 re-reads packed 16-bit bin indices instead of 64-bit
> values, `OASIS_IQR_IDX_PASS2=1`, expect sf10 `heavy` ~139.5 → ~115–120, e2e → ~1.21×) and the
> **FlagBitPacker** shift-register rewrite (timing only). Design + all sim evidence: **RESULTS.md
> §9.20**. Validation commands: §6.
>
> **DO NOT set `OASIS_IQR_IDX_PASS2=1` on build-16 or earlier** — CSR register 7 does not exist
> there, so pass 2 would read indices as values and `histogram_total` would NOT catch it. The host
> now detects this in 10 s with a named error, but only because the counter it polls (register 17)
> also needs build-19.

---

## 0. Status in one paragraph

The supervisor's critique ("your CPU baseline is a SQL query, so you're measuring DuckDB") was fixed
long ago: `iqr_cpu_flags()` is a C++ CPU operator, bit-exact with the SQL on 118 M rows. Since then
**two of our own benchmark defects were found and fixed, both of which had flattered the FPGA**
(§9.18). Against the corrected baseline the FPGA **wins 4 of 7 datasets on wall clock, not 7 of 7**,
and the mechanism is a clean **crossover at ~10 M rows**. Host CPU-seconds (2.07–6.07×) survived
every change and is the study's most defensible claim. The remaining wall-clock gap is a **bus
limit** — the FPGA reads at 12.5 GB/s over PCIe, the CPU at 63 GB/s from DRAM. Card memory was
disqualified as a workaround (8 MB/s). The redundant PCIe traffic was removed instead: **RTL that
fuses IQR pass 1 into decode is DONE and validated on silicon (build-16, §9.19)** — on sf10 the operator
fell 169.6 → 137.0 ms and end-to-end flipped 0.85× → 1.05× with CPU-work held at 6.07×.

**Then build-20 (2026-07-24, §9.23) went further.** Step 2 (pass 2 re-reads packed 16-bit bin indices)
plus a **wide flag emit** (32 flags/cycle instead of 8) cut sf10's `passes` **38.41 → 9.69 ms (3.96×)**
and `heavy` to **110.05 ms**; a third benchmark fairness defect was fixed (the CPU's column-free now
counted inside its operator timer, §9.18 Defect 3). Result on sf10: **e2e 1.05× → 1.31×, operator
0.68× → 1.33×, CPU-seconds 6.34×**; surviving claim range **CPU-seconds 2.1–6.3×**. A drain deadlock
found on build-19 was root-caused and fixed (validated: accuracy 200/200 on the case that wedged the
card). **⚠️ Index mode remains OFF by default because of one open defect: in multi-query sessions it
flags 2 spurious outliers on sf10 (rows 13 & 25 — first index beat), suspected missing per-column reset
on `IqrWideFlagPack`. Not root-caused. The shipping (value) path is clean at baseline everywhere.**
The next wall for the value path is still **decode's host feed** (`fetch`+`submit` ≈ 55 of 92 ms) — §8.

---

## 1. Environment — the gotchas that cost time

| thing | rule |
|---|---|
| **Build node** | `hacc-build-02` — 64 cores, 376 GB. All Vivado builds. `free -g`: 376 = build node, 62 = alveo. |
| **Bench node** | `alveo-u55c-10` (used for all of §9.13–§9.18). `-07` also works but had a wedge. |
| **Never build on alveo** | Two Vivado runs wedged it (sshd died on memory pressure). (A C++ extension rebuild via `cmake … --target shell` is fine on alveo — that's not Vivado.) |
| **Driver ↔ kernel mismatch** | `cThread vfid:0` / `insmod Invalid module format` = the NFS-shared `coyote_driver.ko` was built for a different kernel. Cluster is on **6.8.0-136**; rebuild on the node: `cd parcore/libstf/coyote/driver && make clean && make`, then reload via `program_hacc_local.sh … 1`. Switching nodes does NOT help. (Rebuilt this session.) |
| **Vivado** | `module load vivado/2024.2` **before** `synthesize.sh`. |
| **CLI target** | `cmake --build extension/build/release --target shell` — `--target duckdb` builds the .so and leaves the binary **stale**. Check its mtime. |
| **`~/opt` is stale-prone** | The extension compiles against `~/opt/include/oasis/*`. After editing `software/oasis/*`: rebuild `software/build`, `cmake --install .`, **then** rebuild the shell. |
| **Runtime** | `export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH`. |
| **Huge pages** | `echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`, **after** any reprogram (it clears them). `hdev set hugepages` is a silent no-op. |
| **NEVER Ctrl-C an FPGA query** | It leaves pinned pages + enqueued buffers; Coyote has no inter-process reset and the node may need a reboot. Use `timeout`. |
| **tmux** | detach = `Ctrl-b` then `d`. `Ctrl-C` goes to Vivado and cancels the run. |
| **Home is NFS-shared** | `~/oasis` identical on all nodes; only processes are per-node. |

---

## 2. THE RESULT (medians of 15, `--consume`, **build-20, value path, CPU arm = GROUP BY**)

Two benchmark defects were fixed on 2026-07-22 (§9.18); **all end-to-end numbers older than that are
void**:

1. **`medians.py` timed `CREATE TABLE`**, and 92 % of that is DuckDB's single-threaded table append
   (438 ms of 647 ms on sf10) — a big constant added to *both* sides that dragged every ratio to 1.0.
   Producing the flags costs only 38 ms. → `medians.py --consume` aggregates instead.
2. **The C++ baseline freed its column with `new[]`** outside DuckDB, so releasing 457.7 MB landed
   after the `heavy` timer as CPU-side "tax" (up to 27 ms). → `Allocator::Get(context).Allocate()`.

**CURRENT — §9.35, 2026-07-24, index mode OFF, CPU arm = `iqr_cpu_flags_groupby`.**
Medians of 15, `--consume`, node alveo-u55c-01.

| dataset | rows | FPGA | C++ | SQL | **FPGA/C++** | **C++/SQL** | FPGA op | C++ op | op ratio | CPU-s ratio |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 0.013 | 0.017 | 0.026 | **1.31×** | **1.53×** | 9.2 | 13.4 | 1.45× | 4.75× |
| tpch_qty | 6.0M | 0.019 | 0.032 | 0.032 | **1.68×** | 1.00× tie | 14.7 | 27.8 | 1.90× | 4.52× |
| taxi_d2 | 6.0M | 0.019 | 0.033 | 0.035 | **1.74×** | 1.06× | 14.5 | 29.0 | 2.00× | 4.60× |
| extprice | 6.0M | 0.026 | 0.089 | 0.102 | **3.42×** | **1.15×** | 21.7 | 84.0 | **3.88×** | **11.98×** |
| taxi_d3 | 13.1M | 0.041 | 0.056 | 0.057 | **1.37×** | 1.02× tie | 34.2 | 50.6 | 1.48× | 2.67× |
| taxi_d4 | 20.3M | 0.059 | 0.079 | 0.080 | **1.34×** | 1.01× tie | 50.8 | 72.5 | 1.43× | 2.64× |
| sf10 | 60.0M | 0.149 | 0.337 | 0.496 | **2.26×** | **1.47×** | 136.4 | 325.5 | 2.39× | 9.78× |
| **geomean** | | | | | **1.77×** | **1.16×** | | | **1.95×** | |

**FPGA > C++ on 7/7, all margins far outside the noise.** Mean and median agree to two decimals on every
row, no verdict flips, FPGA spreads 1–7 %.

**The sf10 row is the VALUE path (index mode OFF).** Index mode is faster (0.121 / operator 108) but it
**deadlocks the host and can cost a card reflash** — see the banner and §9.23/§9.27. Do not publish it.

⚠️ **Do not claim C++ > SQL on all 7.** tpch_qty 1.00×, taxi_d3 1.02×, taxi_d4 1.01× are ties: the run
before this one had identical C++ numbers reading 0.94× / 1.04× / 0.99×, the difference being the SQL
arm's ±11–19 % spread. Correct wording: **five clear wins, two-to-three ties.**

**taxi_d3/d4 are the weakest rows on both metrics** because they are the only large datasets on
`sink=memcpy` with no fusion and no index mode — an FPGA-side gate, not a CPU property. The host-only
streaming fix (9–11 ms measured, no bitstream) is the one change left that widens the margin **without**
touching the baseline.

**Read the spreads before believing a delta.** FPGA 1–7 %, C++ 8–34 %, SQL 9–19 %. Any ratio within
~15 % of 1.0 is a tie, not a result.

**Report BOTH benchmarks.** `--consume` isolates the operators; the default (`CREATE TABLE`) is what
a user typing SQL experiences. Quoting only one invites a fair objection either way.

**FAIRNESS FIX (RESULTS §9.18 "Defect 3") — SHIPPED and reflected in the table above.** The CPU must hold
the 457 MB column in RAM; freeing it (~52 ms measured on sf10) used to land *after* the `heavy` timer, so
`heavy` was ~complete for the FPGA but partial for the CPU (92 % vs 58 % of e2e). `RunHeavyPhaseCpu` now
calls `values.Reset()` **inside** the timer and prints a `free` line. Effect: sf10 C++ operator
91.7 → **143.8 ms**, so the operator ratio went 0.68× → **1.33×**. **e2e and CPU-seconds were always fair
and did NOT change** (e2e is real wall-clock and always included the free). Needs an extension rebuild
(`cmake --build extension/build/release --target shell`); independent of the bitstream.

**Two other fairness questions settled (§9.23):** DuckDB does **not** cache the decoded column across
runs (~100 ms every time), so no session-cache advantage; and using DuckDB's `quantile_disc` instead of
our hand-written histogram-zoom would be **~70× slower** (~1790 ms vs ~25 ms), making the CPU look 20×
worse and handing the FPGA a fake win — which is exactly why the baseline is hand-written.

### Why: a crossover at ~10 M rows (operator ms per Mrow)

| | 3.0M | 6.0M | 13.1M | 20.3M | 60.0M |
|---|--:|--:|--:|--:|--:|
| FPGA | 2.74 | 2.28 | 2.53 | 2.42 | 2.81 |
| CPU | **5.37** | 2.52–3.68 | **2.03** | **1.87** | **1.63** |

**FPGA cost per row is flat at every scale; the CPU's falls as its ~13 ms fixed startup (32 threads,
allocation) amortises.** ≤6 M rows the FPGA wins, ≥13 M it loses. Encoding (PLAIN vs dictionary) is
secondary, worth 20–40 % — **earlier sections overstated it; size is the driver.**

---

## 3. Correctness gates

```bash
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
cd ~/oasis && ./extension/build/release/duckdb < bench/sql/cpu_op_correctness.sql
```

| dataset | n_fpga | fpga_vs_cpp | cpp_vs_sql |
|---|--:|--:|--:|
| taxi_d1 | 317554 | 1247 | **0** |
| taxi_d2 | 625445 | 2877 | **0** |
| taxi_d3 | 1328108 | 162 | **0** |
| taxi_d4 | 2112164 | 54921 | **0** |
| tpch × 3 | 0 | 0 | **0** |

**These exact values are reproduced by build-16 with fusion on, and again by build-20 with index mode
OFF** (2026-07-24) — they are the gate. `fpga_vs_cpp` is non-zero by design: the FPGA's quartiles come
from a 1024-bin histogram, the C++ reference is exact. `cpp_vs_sql = 0` is what proves the reference.

**⚠️ WITH `OASIS_IQR_IDX_PASS2=1` THIS GATE FAILS: sf10 gives `n_fpga=2` (should be 0).** Open defect,
§9.23 — sequence-dependent, the 2 flags land at rows 13 & 25 (first index beat), suspect a missing
per-column reset on `IqrWideFlagPack`. **Run this gate with index mode OFF until fixed.** Index mode is
off by default, so the shipping path is clean.

### Why fusion is gated (§9.19) — do not "fix" this by widening it

```
fuse = OASIS_IQR_FUSE && rows > 10M && streaming sink
```

The fused path must size the histogram window **before the first beat**, from a sample. That sample
is a fixed cost, and a sampled window is worse than one derived from the whole column:

- **rows > 10M** — below it the window costs more than the pass it saves: taxi_d1 1.67× → 1.27×,
  extprice 1.00× → 0.86×.
- **streaming sink** — a memcpy-sink column gets a **free, exact** full-column window from `run()`.
  Fusing throws that away. taxi_d3 fused finds 1,296,479 of 1,328,270 (2.4 % low), and the 48-group
  fix that corrects it makes taxi_d3 *slower than not fusing* (~42 vs 32.9 ms).
- **taxi_d4 is a deliberate ~10 ms sacrifice.** It is accurate at 16 groups and would gain
  49.6 → 40.6 ms, but that accuracy is *observed, not predictable* — taxi_d3 is the same sink and
  shape and silently loses 2.4 %. Revisit only with a cheap a-priori test that a sampled window
  matches the full-column one.
- **Window knobs:** `WINDOW_GROUPS=16` is the floor (8 regresses taxi_d1 to 1348) and raising it is
  a bad global trade. **Density is not a lever at all** — 2048 → 32768 per group gave the *identical*
  answer while `win_derive` went 4.72 → 20.32 ms. Coverage matters, resolution does not.

- **TRAP:** the tpch sets have zero outliers by nature and taxi_d2/d3/d4 mostly use the memcpy sink,
  so this suite is **structurally blind** to anything touching the histogram window. It caught
  nothing when a prefix window flagged 20 M of 20 M rows.
- **The real window gate** is `bench/overlap_ab.sh accuracy` → `ov_uniform` and `ov_drift` must both
  return **200**. `ov_drift` (values rise with row order) is the adversarial case. Build them once
  with `bench/overlap_ab.sh gen`.
- With overlap enabled taxi_d2 legitimately shifts to 2617 (better). Restate the gate if so.

---

## 4. Where the time goes (sf10, measured)

```
BEFORE (§9.16)   FPGA heavy 169.7 = decode 92.8 (fetch 38.5 | submit 19.9 | fpga_wait 30.1) + passes 76.6
build-16 (§9.19) FPGA heavy 139.5 = win_derive 7.2 + decode 92.5 (fetch 36.8 | submit 19.8 | fpga_wait 31.5) + passes 38.4
build-20 (§9.23) FPGA heavy 110.0 = win_derive 6.6 + decode 92.2 (fetch 38.1 | submit 16.9 | fpga_wait 32.8) + passes 9.7   <- index mode
                 CPU  heavy 143.8 = read 58.9 + quart 25.2 + flags 7.6 + free ~52   (free now counted, §9.18 Defect 3)
```

**Both passes are now effectively free: pass 1 is fused into decode, pass 2 is 9.7 ms.** `decode` is
92.2 ms of the 110 — i.e. **84 % of the operator is now decode**, and `fetch`+`submit` = 55 ms of that
is host work with the FPGA idle. **Decode is THE wall; nothing else is worth optimising until it moves.**
The table below is the pre-fusion decomposition, still the right way to see WHY.

| phase | CPU | FPGA | |
|---|--:|--:|---|
| decode / read | 58.9 | 92.8 | CPU 1.6× |
| quartiles | 25.2 | 38.3 | CPU 1.5× |
| flags | 7.6 | 38.3 | **CPU 5.1×** |

**The flags row is the whole architecture.** Comparing 60 M values to two constants takes the CPU
7.6 ms and the FPGA 38.3 ms — because the FPGA must ship 457.7 MB across PCIe to look at them.
**FPGA 12.5 GB/s (PCIe Gen3 x16) vs CPU 63 GB/s (DRAM).** Every phase touching the raw column is
~5× handicapped before any computation. The IQR core itself is never the limit: its profiler shows
`stalled = 0.0 %`, `starved = 21.4 %`.

**PCIe traffic today: 1676 MB to produce 7.3 MB of flags.** The decoded column crosses the bus three
times (decoder→host, then host→FPGA twice) because `vfpga_top.svh` wires the decoder lanes and the
IQR lane as separate streams that never meet on-chip.

---

## 5. Dead ends — do not re-attempt

| thing | evidence |
|---|---|
| **Card memory / HBM** | `use_card` = **8 MB/s**, a size-independent **~1548×** penalty on the READ path (§9.17). Fixed per-request cost, not slow memory. sf10 can't even be staged: Coyote caps `invoke` at 128 MB. **The RTL card datapath is now deleted.** |
| **Prefix-derived histogram window** | Flagged **19,997,999 of 20 M rows** vs a true 200 on order-drifting data (§9.15). |
| **Footer min/max as the window** | taxi_d4 spans −128540..33407632 → 1024 bins are 32768 wide while fares live in 0..5000. Everything lands in bin 0 ⇒ q1 = q3 ⇒ degenerate. A percentile over per-group extremes fails too (outliers are in nearly every group). |
| **Host prefetch pool** | No-op, +7 % CPU (§9.11). |
| **`DECODE_WINDOW` tuning** | Flat within 1.5 % from 8 to 32 (§9.14.3). Keep 16. |
| **`OASIS_IQR_OVERLAP` (software)** | Correct after `DeriveWindowSpanning`, but the window costs ~18 ms/query → **net loss below ~40 M rows; 6 of 7 datasets got slower.** Superseded by the RTL fusion. Keep OFF. |

---

## 6. build-20 is CURRENT (wide emit + o_last, both validated); build-16/19 history below

**Flash this:** `hardware/build-20/bitstreams/cyt_top.bit`. Carries the wide flag emit (§9.22/§9.23) and
the `o_last` drain fix. WNS −2.131 ns (Coyote shell width-converter only — benign, proven by the clean
step-1 regression). **Validation sequence that was actually run and passed:** step-1 regression (index
OFF) → step-2 index ON (`passes` 9.69 ms) → `overlap_ab.sh accuracy` (200/200 both datasets) →
`cpu_op_correctness.sql` **with index OFF** (all 7 at baseline) → `medians.py --consume -n 15`.

**The one thing NOT clean: `cpu_op_correctness.sql` with index mode ON** → sf10 `n_fpga=2`. Open defect,
see the banner and §9.23. Reproduction (this is the regression test):

```bash
# 6 other datasets first (threads=1), THEN sf10 with row numbers -- expect 0 flags, got 2 at rn 13,25
OASIS_IQR_IDX_PASS2=1 OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 timeout 1200 \
  ./extension/build/release/duckdb -c "PRAGMA threads=1;
  SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('/home/myaksi/datasets/taxi_d1.parquet','fare_cents');
  -- ... repeat for taxi_d2/d3/d4 (fare_cents), tpch_qty, tpch_extprice (v) ...
  CREATE OR REPLACE TABLE f AS SELECT row_number() OVER () rn, is_outlier
    FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');
  SELECT count(*) FILTER (WHERE is_outlier) FROM f; SELECT rn FROM f WHERE is_outlier ORDER BY rn;"
```

### Historical: build-16 fusion DONE on silicon; build-19 (step 2 + packer)

**build-15 hung the decoder on silicon.** Flashed fine, `decoder_profiler` returned 0–3, but a fused
query sat SILENT until `timeout` — no error at all. **build-15 is dead; use build-16.**
`git reset --hard pre-rtl-fusion` reverts the whole fusion line if ever needed.

**The bug (in `iqr_histogram_feed.sv`).** The arbiter drove `out.valid` off `any_head` (ANY lane has
a beat) while the payload came from `sk_data[grant]` — last cycle's winner, i.e. the lane that just
ran dry. When that lane emptied while another had data, it asserted valid over an empty slot; garbage
`keep` bits inflated the element count, `fed` overshot `hist_expected`, `last` fired early, the core
left HISTOGRAM, the top's mux parked the feed's ready at 0, the skids filled, and the tee **stopped
the decoder**. The host never reached `finish_fused`, so its `histogram_total==N` check never ran —
hence silent. **Invisible at N_LANES=1** (`grant` always 0), which is why nothing caught it before.

**The fix (commits `9e5592d`, `4b7339e`, `01e1632`, `2db6c41`):**
- drive `out.data/keep` and `pop` from **`next_grant`** (the lane selected *this* cycle), not `grant`.
- **safety valve:** hold `o_ready` high once `done` and drop late beats — so any *future* miscount is
  a `histogram_total != N` error (which the host reads in 10 s) instead of a deadlocked decoder.
- `beat_elems` now counts off the skid slot, not `out.keep` (that was a circular comb dependency that
  xsim resolved to X); explicit keep-sum instead of `$countones` (returned X here).
- `IqrRunner::finish_fused` poll is now a **10 s wall-clock deadline**, not 200 M spins (~200 s) —
  each `feed_done()` is a PCIe MMIO read, so the old budget always outlived the query's `timeout`,
  which is *why build-15 presented as a pure hang with nothing printed*.

**PROVEN IN SIM (both run in seconds; need `module load vivado/2024.2`):**
- `hardware/unit-tests/run_feed_tb.sh` — feed alone, 4 lanes at uneven rates. 5 scenarios pass;
  all 5 FAIL with DUPLICATE EMISSION when the fix is reverted, so it demonstrably catches the bug.
- `hardware/unit-tests/run_fused_integration_tb.sh` — feed→mux→IQR_detection connected (the seam no
  prior test touched), real two-pass flow vs a reference: `dbg_total==N`, 96/96 flags bit-exact, mux
  switches correctly. Inverting the mux's `take_feed` deadlocks it → TIMEOUT, so it has teeth.
- **Sim can't reach:** CSR-vs-DMA ordering / the clear fence, and −0.4 ns timing closure. Those are
  what the morning gates below settle.

**build-16 has the fix — verified:** `iqr_histogram_feed.sv` mtime 00:00 < build-16 start 00:37, and
the on-disk file has `next_grant][0]` ×3 + the safety valve. Watch: `scripts/util/watch_build.sh -w`.

**What fusion does (unchanged):** the decoder output is TEE'd on-chip into the IQR histogram, so pass
1 runs *during* decode and never crosses PCIe. Pass 2 is untouched (needs final Q1/Q3). Register map:
`IqrConfig` +`fuse_enable`(5) +`hist_expected`(6) +`fed_elements`(15) +`feed_done`(16),
`NUM_IQR_CONFIG_REGS` 17. `OASIS_IQR_FUSE=1`, off by default; works with either sink.

**Target: `heavy` ~150 ms vs today's 169.7.** Do NOT validate against 131 — that figure (§9.15) used
the *free prefix* window (wrong answers). The correct spanning window costs ~18 ms, which build-16
pays too: `169.7 − 38 (pass 1 deleted) + 18 (window) ≈ 150`. ~150 = RTL right; 169 = fuse never
engaged. The window tax is why fusion only pays above ~20 M rows — the §8.1b follow-up removes it.

### When build-19 finishes — validate in THIS order

```bash
head -14 ~/oasis/hardware/build-19/analysis.txt        # WNS negative is OK (build-14 shipped -0.773)
cd ~/oasis && bash parcore/libstf/coyote/util/program_hacc_local.sh \
  hardware/build-19/bitstreams/cyt_top.bit parcore/libstf/coyote/driver/build/coyote_driver.ko 1
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages   # AFTER flashing
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
cat /home/myaksi/datasets/tpch_extprice_sf10.parquet > /dev/null   # warm the page cache first!
timeout 60 ./extension/build/release/duckdb -c "SELECT decoder FROM decoder_profiler();"

# 1. REGRESSION FIRST: index mode OFF must reproduce build-16 (heavy ~139, passes ~38)
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_TIMING=1 \
  timeout 120 ./extension/build/release/duckdb -c \
  "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');"

# 2. index mode ON: look for pass1=fused+idx, passes ~10, heavy ~115-120
OASIS_IQR_IDX_PASS2=1 OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 \
  OASIS_IQR_TIMING=1 timeout 120 ./extension/build/release/duckdb -c \
  "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');"

# 3. the gates -- EVERY number must equal build-16's exactly (the claim is bit-identity)
OASIS_IQR_IDX_PASS2=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 bench/overlap_ab.sh accuracy
OASIS_IQR_IDX_PASS2=1 OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 \
  ./extension/build/release/duckdb < bench/sql/cpu_op_correctness.sql

# 4. numbers, both configs
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_DECODE_WINDOW=16 \
  python3 bench/medians.py --consume -n 15
OASIS_IQR_IDX_PASS2=1 OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 \
  OASIS_IQR_DECODE_WINDOW=16 python3 bench/medians.py --consume -n 15
```

**Step 1 before step 2, always.** If index mode misbehaves you need to know whether the bitstream
itself regressed. **If step 2 throws `index stream incomplete (... beats)`** the index emit or the
transfer ordering is wrong — that error is deliberate and arrives in 10 s (§9.20); read the beat
count against ceil(N/32) = 1,874,565 for sf10.

**Only sf10 fuses today**, so only sf10 exercises step 2 until the taxi streaming-guard work (§8.1)
lands. Do not expect the other six rows to move.

### Historical: build-16 validation (fusion, already done)

```bash
head -12 ~/oasis/hardware/build-16/analysis.txt          # WNS negative is OK (build-14 shipped -0.773)
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
cd ~/oasis && bash parcore/libstf/coyote/util/program_hacc_local.sh \
  hardware/build-16/bitstreams/cyt_top.bit parcore/libstf/coyote/driver/build/coyote_driver.ko 1
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages   # reprogram clears them
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
cd ~/oasis && timeout 60 ./extension/build/release/duckdb -c "SELECT decoder FROM decoder_profiler();"
```

Then, in order (leave `OASIS_IQR_WINDOW_FPGA` UNSET — validate the RTL against the trusted window):
```bash
# 1. does it engage and hit the target?  look for pass1=fused and heavy ~150 (NOT 131)
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_DECODE_WINDOW=16 OASIS_IQR_TIMING=1 \
  timeout 120 ./extension/build/release/duckdb -c \
  "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('/home/myaksi/datasets/tpch_extprice_sf10.parquet','v');"

# 2. window gate (the correctness suite cannot see this)
OASIS_IQR_FUSE=1 bench/overlap_ab.sh accuracy      # both must be 200

# 3. full gates + numbers
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 ./extension/build/release/duckdb < bench/sql/cpu_op_correctness.sql
OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_DECODE_WINDOW=16 python3 bench/medians.py --consume -n 15
```

**If it hangs again** (should not — sim proved the datapath): it's now bounded, so `finish_fused`
throws `histogram_total != N` within 10 s. `fed_elements()` shows how far pass 1 got. The remaining
unsimulated suspects are the CSR clear-fence timing and closure, not the arbiter.

---

## 7. Also in flight — 07_perf_fpga (Coyote example)

Building on hacc-build-02 (tmux `perf`). Modified to sweep **host or card** memory in one bitstream:
`BENCH_STRM_REG`(8) → `sq_rd/sq_wr.strm`, `EN_MEM 1`, `--card/-c` flag. Coyote has no card alloc type
(REG/THP/HPF/GPU) — residency comes from a one-off `LOCAL_OFFLOAD`, done before the sweep; and the
benchmark's per-iteration re-randomisation is skipped for card buffers or the pages migrate back.

```bash
cd ~/oasis/parcore/libstf/coyote
bash util/program_hacc_local.sh examples/07_perf_fpga/hw/build_hw/bitstreams/cyt_top.bit driver/build/coyote_driver.ko
cd examples/07_perf_fpga/sw/build_sw
./test -o 0 -c 0 -x 64 -X 4194304    # read host   <- the useful one now
./test -o 1 -c 0 -x 64 -X 4194304    # write host
```

**Its purpose has shifted.** HBM is no longer needed (see §8), so the card sweep is only for the
record. The *host* sweep matters: at 8 lanes the bottleneck becomes **`fetch`+`submit` = 60.4 ms of
host work** inside the 92 ms decode, and FPGA-initiated reads (what this example demonstrates) are
the candidate replacement. **Flashing it replaces the IQR bitstream** — reflash afterwards.

---

## 8. Next steps, in priority order

**Fusion is done (§6, §9.19). Steps 1 and 1b of the old plan are COMPLETE and shipped.** What they
changed: pass 1 no longer crosses PCIe, and the window sample runs on the FPGA rather than burning
~51 ms of host CPU. What they did NOT change: `decode`, which is now the wall.

1. **Reclaim taxi_d3/d4 — needs RTL, NOT pure software. Two dead ends ruled out 2026-07-23.**
   They fall back to `sink=memcpy` (excludes them from fusion, §3), so they are §2's worst rows at
   0.78×/0.73×. **Measured raggedness (pyarrow):** taxi_d3 has **2** ragged non-final groups of 107;
   taxi_d4 **4** of 166 (e.g. 123942, 123556 — vs the clean 122880). The rest are exact multiples of 8.
   - **The trap: raggedness PROPAGATES.** One non-final chunk with `num_values % 8 != 0` shifts the
     packed-flag bit position for *every* downstream chunk (the FLAG packer packs a continuous bit
     stream). Only pass 2 (the packer) cares — pass 1 histogram tolerates ragged chunks via `keep`.
   - **DEAD END A — "pad the ragged chunk":** wrong, because the shift propagates (can't fix chunks
     independently).
   - **DEAD END B — "re-block the input into 8-aligned transfers on the host, no RTL":** ALSO wrong.
     It needs to DMA sub-ranges starting mid-chunk (`base+48 B` after a bridge takes 6 head elements),
     i.e. **unaligned DMA sources** — but Coyote requires 64-byte alignment (`memory_pool.hpp:141`
     "required by Coyote anyway"; every existing stream transfer starts at a 64-aligned base, no
     unaligned precedent). The alignment-SAFE variant degenerates to a whole-column copy, because
     taxi's post-ragged chunks are all mult-of-8 so the ≤7 carry **never self-heals** — you'd copy
     every downstream chunk's head, i.e. the memcpy again. Confirmed by reading `cThread::invoke`
     (posts raw `sg.addr`, no SW alignment enforcement, but the data mover is 512-bit/64 B wide).
   - **THE ACTUAL FIX IS RTL (a bitstream):** teach the FLAG packer to byte-realign at each chunk's
     `last` while the FSM stays in FLAG until the FINAL chunk, and have the host stitch per-chunk byte
     offsets. **Bundle it with the next build** (which should also carry the step-2 `o_last` fix already
     in the tree). Payoff is CPU-seconds not wall clock (§9.10: memcpy→stream is operator −7.5..8.1 %,
     e2e inside noise, host **CPU-s −29..46 %**) — so taxi CPU-work ~2.1× → ~3×, e2e barely moves.
   - **Or just accept memcpy:** the headline CPU-seconds claim (2.0–3.9×) already survives with
     taxi_d3/d4 where they are. Lowest-effort, costs nothing currently claimed.

2. **⭐ TOP PRIORITY: root-cause the index-mode session defect (§9.23).** Step 2 + the wide emit are
   VALIDATED FAST on build-20 (`passes` 38.41 → **9.69 ms**, 3.96×; heavy → 110.05; `stalled` 80 %→0 %)
   and the `o_last` hang fix is VALIDATED (accuracy 200/200 incl. the multiple-of-32 case). **The only
   thing blocking index mode from being enabled by default is the 2-spurious-flag defect** — sequence
   dependent, flags at rows 13 & 25 (first index beat), reproduced reliably (command in §6).
   - **Suspect #1: `IqrWideFlagPack` has no `i_restart`.** `IqrIndexPack` got one (tied to `clear_req`)
     so it re-arms per column; the wide packer did NOT — residual `acc`/`filled` bits can survive into
     the next column's first word. Fix = add `i_restart` and reset `acc/filled/flushing/out_valid_r`.
     Pin it in sim by running two columns back-to-back WITHOUT a hardware reset between them (the
     existing TBs reset per scenario, which is exactly why they missed this).
   - **Suspect #2:** the index-buffer round-trip (`drain_to_buffer` → re-stream as pass-2 input) leaving
     a stale/partially-landed first beat.
   - Both are off-card work (RTL read + a testbench). Once fixed it needs a bitstream — **bundle with
     the taxi packer-realign RTL (item 1)**, since that needs a build too.
   - **DO NOT enable `OASIS_IQR_IDX_PASS2` by default until this is closed.** And do not treat
     "2 rows / 0.033 ppm" as a bound — it is one sample of an unexplained state bug, unlike the
     bin-edge quartile error which IS bounded and principled.
   **TWO CORRECTIONS to what this section used to say** — both found by working the algebra and then
   confirmed with negative tests, and both would have shipped silent wrong answers:
   - **16 bits/element, not 13.** In *half*-bins the fence indices span −3069..+5115, so 13-bit
     signed (±4096) cannot reach +5115. At `IDX_W=13`: **844 mismatches**. It is 14-bit signed.
   - **An `exact` bit is required.** Floor division collapses every value in
     `(upper_fence, upper_fence + W/2)` onto the fence's own index, so an index-only compare reports
     those as INSIDE. Dropping it: **5618 mismatches**. Hence 14 + 1 = 16 bits.
   So the saving is **4x, not the 6.4x** an index-only 10-bit scheme suggested.
3. **HOST MEMORY IS ENOUGH — do not build HBM for this.** With bin indices the intermediate is
   71.5 MB, so host round-trip costs ~5.7 ms vs HBM's ~4.5 ms. **HBM is worth ~1 ms.** And host
   writes/reads already exist (`OutputWriter` → `axis_host_send`, `LocalRead` → `axis_host_recv`), so
   Step 2 needs **no new data-movement machinery at all**.
4. **The host feed is the wall now — `fetch` + `submit` = 56.5 ms of decode's 92.5**, with the FPGA
   idle (`fpga_wait` 31.5). Prefetching was already measured as a NO-OP (§9.11). The candidate is
   FPGA-initiated reads (what `07_perf_fpga` demonstrates — §7), and **more decoder lanes are
   pointless until this is fixed**: at 4 lanes the device already waits on the host.
5. **Timing closure — deliberately NOT chased.** build-16 ships at WNS −0.559 (build-14 shipped
   −0.773 and was bit-exact). The cause is decoder replication, not the fusion: build-11 with **1**
   decoder MET timing at 0.000 while 2 decoders already missed at −0.456. It is congestion (74 %
   route / 26 % logic), and `iqr_flag_packer` tops the failing clusters only because it is where the
   congestion lands. If it ever needs fixing: pblock one decoder per SLR (free), and rewrite
   `FlagBitPacker`'s `acc_next[slot*8 +: 8]` variable-position write as a fixed shift register.
6. **Build time — `BUILD_OPT`.** `hardware/CMakeLists.txt:39` hardcodes `set(BUILD_OPT 1)`, which is
   what turns on `AggressiveExplore` everywhere *and* the post-route `phys_opt_design` — together
   worth ~9 h vs ~4–5 h. **Agreed plan: make it overridable, use `-DBUILD_OPT=0` for test builds and
   `1` for the final one.** A `BUILD_OPT=1` rebuild places and routes differently, so it needs its
   own pass through the §3 gates rather than inheriting the test build's.

**Projected ceiling: `heavy` ~109 after step 2, then bounded by the host feed until step 4. The CPU is
at ~92, so step 2 alone does not win outright on sf10 — the two together are what would.**

---

## 9. Files

| file | purpose |
|---|---|
| `bench/medians.py` | main benchmark. **`--consume`** excludes DuckDB's table append. `-n`, `-d`, `-t`. |
| `bench/phases.sh` | raw per-phase timings, both operators, all datasets. No parsing. `phases.sh 3 [dataset]`. |
| `bench/phases.py` | same, but medians + derived GB/s tables. |
| `bench/overlap_ab.sh` | `gen` builds ov_uniform/ov_drift; `accuracy` is **the window gate**; `time` is the A/B. |
| `bench/sql/cpu_op_correctness.sql` | 3-way FPGA/C++/SQL, `threads=1`, POSITIONAL JOIN. |
| `bench/sql/decoder_probe.sql` | per-lane decoder profilers, all four terms + load balance. |
| `hardware/unit-tests/run_feed_tb.sh` | xsim, feed arbiter alone, 4 lanes uneven. Seconds. |
| `hardware/unit-tests/run_fused_integration_tb.sh` | xsim, feed→mux→IQR_detection connected. Seconds. |
| `hardware/unit-tests/run_index_tb.sh` | xsim, index vs value compare, 204884 combos. **Step 2's core proof.** |
| `hardware/unit-tests/run_index_stream_tb.sh` | xsim, index pack → **wide** flag → **wide pack**, packed bitmask bit-exact vs the value path (14 scenarios incl. multi-word). Also checks the packer's `o_last` fires exactly once (the §9.21 hang gate). |
| `hardware/unit-tests/run_idx_mode_tb.sh` | xsim, **same column both modes in the core → identical flags**, index routed through the real `o_flagw_*` → `IqrWideFlagPack` seam. The step-2 gate. |
| `hardware/src/hdl/iqr_index_stream.sv` | `IqrIndexPack` (pass 1, has `i_restart`+`i_expected`), `IqrIndexFlag` (**32-wide zero-buffer emitter**), `IqrWideFlagPack` (32 bits/beat → 512-bit words; **MISSING `i_restart` — suspect #1 for the §9.23 defect**). |
| `hardware/unit-tests/run_flag_packer_tb.sh` | xsim, the bitmask packer. Old impl passes it too = bit-identical. |
| `scripts/util/watch_build.sh` | `[-w]` watch a `hardware/build-*` without touching Vivado. |
| `extension/src/oasis_iqr.cpp` | `DeriveWindowFromFpga` (§8.1b, `OASIS_IQR_WINDOW_FPGA=1`, off). CPU baseline = `SelectQuartiles`/`AdvanceRankQueries` (iterative histogram zoom, 4096 L1-resident bins) + `ComputeFlagMask`. |
| **RESULTS.md §9.24** | **the CPU-baseline optimization ledger — all 16 steps, what each was worth, and the correctness backing. Read this when asked "is the baseline fair?".** |
| `bench/micro/` | standalone CPU microbenchmarks, no DuckDB/FPGA. `groupby_ab` (serial-merge vs radix), `scatter_ab` (the scatter is already at 50 GB/s), `threads_ab` (spawn vs pool, 4.95 -> 0.61 ms), `bins_ab`/`build_bins_ab.sh` (histogram geometries), and three GATES: `groupby_exact` (120 trials), `sort_test` (180), `pool_test` (70). Regenerate the `*_core.inc` includes from `oasis_iqr.cpp` first. §9.25–§9.35. |
| `bench/medians.py` flags | `--cpp-impl {groupby,zoom}` picks the CPU arm — **use `groupby` ONLY; `zoom` is BANNED as of 2026-08-08 (top banner §B) and `card_sweep.py` rejects it**. `--stats` prints mean-vs-median with a FLIPS detector, `--drop K` discards leading iterations. |
| `bench/measure_all.sh` | whole campaign in ~5 min. **Index mode is opt-in** (`IQR_MEASURE_IDX=1`) because it deadlocks the card; aborts if a duckdb is already running. |

## 10. Framing for the writeup

- **Lead with host CPU-seconds (2.07–6.07×)** — unaffected by both benchmark defects, latency-independent.
- **Report both benchmarks** (`--consume` and materialised) and say which is which.
- **The story is the crossover at ~10 M rows**, not encoding.
- **The fusion is the constructive result**: a measured, bit-exact −19 % on the operator by deleting a
  redundant PCIe pass, which is the evidence that the remaining gap is addressable rather than
  fundamental. Disclose that it is **gated to streaming columns above 10 M rows** and why (§3) — the
  gate is a finding, not a limitation to hide.
- **Disclose:** the FPGA's remaining loss is a bus limit (12.5 vs 63 GB/s), not an operator limit —
  and the redundant PCIe pass we removed in RTL is the measured proof that it's addressable.
- **Disclose:** the C++ baseline saturates ~3 cores and is not proven optimal; C++ spreads are 20–77 %.
- **Methodology worth stating:** every RTL change since build-15 is gated by a testbench that FAILS
  when the change is reverted, and where a rewrite claims equivalence, the OLD implementation is run
  against the same testbench (FlagBitPacker, and index-vs-value mode). This exists because build-15
  shipped an arbiter bug invisible at 1 decoder that hung the decoder silently — and because on this
  operator a wrong flag still yields a plausible outlier count, so end-to-end benchmarks do not
  catch correctness. Two of step 2's design parameters (14-bit width, the `exact` bit) were fixed by
  negative tests, not by reasoning alone.
