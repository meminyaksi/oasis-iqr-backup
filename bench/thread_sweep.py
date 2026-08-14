#!/usr/bin/env python3
"""
THREAD SWEEP (Test 3) -- runtime/throughput vs HOST CORE COUNT, at fixed dataset.

This is the OFFLOAD experiment, not another speed experiment. Tests 1 and 2 both ran at
`PRAGMA threads=32`, i.e. they answered "is the FPGA faster than 32 CPU cores". They cannot answer
the question the paper's thesis actually rests on: *how much host CPU does the FPGA path give back*.
Sweeping the core count answers both halves at once:

  * the CPU baseline should scale with cores (its decode and its GROUP BY are both parallel), so its
    curve tells us how many cores it needs to reach the FPGA;
  * the FPGA arm should be FLAT in BOTH its phases. `passes` is the IQR operator (a fixed-rate
    pipeline); `decode` is the phase where row groups are submitted to the FPGA's parquet DECODERS and
    decoded beats stream back (DecodeColumnAllGroups, oasis_iqr.cpp:1096) -- also device work, with
    the host only orchestrating fetch/submit/copy. So neither phase should buy anything from more
    host cores. That double flatness is the claim.

**The internal check is `passes`.** Same file, same bytes, same encoding at every point, so the FPGA
operator has identical work to do regardless of how many host threads DuckDB was given. If `passes`
moves with thread count, the measurement is contaminated (most likely by DMA starvation at low thread
counts -- which is itself a finding, but a different one, and it must not be silently folded into a
"the FPGA does not need cores" claim).

MEASUREMENT PROTOCOL -- identical to Tests 1 and 2, reused verbatim from size_sweep.run_arm:
    7 runs in ONE DuckDB session, arithmetic MEAN OF THE LAST 3. No median, no spread.
Each thread count gets a FRESH DuckDB process, so `PRAGMA threads` is never mutated mid-session and
DuckDB's scheduler is sized correctly from the start.

HOW THE CORE COUNT IS ENFORCED -- and why `PRAGMA threads` alone is NOT enough
-----------------------------------------------------------------------------
Each point sets `PRAGMA threads=N` **and** pins the process with `taskset -c 0-(N-1)`. Both are
required, because three host regions size themselves from `std::thread::hardware_concurrency()` and
ignore the pragma entirely: the window-sample decode (oasis_iqr.cpp:510), the flag-copy stage (:871)
and the IqrThreadPool (:1489). Measured on this host (glibc 2.35): `hardware_concurrency()` is NOT
affinity-aware -- it still reports 64 under `taskset -c 0`. So taskset does not shrink those pools,
it CONFINES their work to N cores, which is exactly the resource question being asked.

Two consequences to state in the paper rather than hide:
  * At low N those fixed-size pools are oversubscribed on few cores, so they pay scheduling overhead
    the CPU baseline does not. The bias runs AGAINST the FPGA arm, so the result is conservative.
  * `--no-taskset` reproduces the pragma-only measurement. Comparing the two isolates how much of the
    FPGA arm's host cost lives outside DuckDB's scheduler -- worth one run, but not the headline.

⚠️ TOPOLOGY: `0-(N-1)` assumes CPU ids enumerate cores before SMT siblings. If the run node numbers
siblings adjacently, the small-N points land on two threads of one physical core and understate both
arms. Check `lscpu -e` on the run node once; use `--cpu-list` to override per point if needed.

WHICH DATASET, AND WHY (default `balanced`)
------------------------------------------
Reusing Test 1's `size_20M.parquet` -- 20M rows, ~979,812 distinct (4.9% of N), Snappy, PLAIN,
4.94 B/row, 163 row groups all with `num_values % 8 == 0`. Chosen over the alternatives because:

  * **Size is in the flat part of Test 1's curve.** At 20M the FPGA's per-row cost has converged
    (3.54 ms/Mrow value / 2.67 fused, vs 7.70 at 1M), so fixed startup is not what is being measured
    -- but it is still small enough that a 1-thread CPU run finishes in ~1 s.
  * **Cardinality is past Test 2's knee but nowhere near the extreme.** 4.9% of N sits between the
    C=1% knee (1.63x) and all-distinct (11.69x). Picking the all-distinct point would have inflated
    every speedup here by ~5x for reasons that have nothing to do with core count.
  * **Fusion engages by POLICY, not by override** -- 20M > the 6M crossover measured in Test 1 -- so
    the configuration under test is the one that would actually ship.
  * **It cross-checks against an independent test.** At `threads=32` this sweep must reproduce Test
    1's 20M fused row (FPGA op 53.4 ms, CPU op 124.0 ms). If it does not, something drifted between
    the two sessions and nothing else here is trustworthy. That gate is printed automatically.

`--dataset knee` runs the control: `cardsweep10m_snappy/card_100000.parquet`, 10M rows and 109,254
distinct = 1.1% of N, i.e. Test 2's LEAST flattering point (1.63x at 32 threads). If the scaling
conclusion survives there too, it is a property of the architecture and not of the cardinality.

  cd ~/oasis && python3 bench/thread_sweep.py                    # balanced, fusion by policy
  python3 bench/thread_sweep.py --dataset knee
  python3 bench/thread_sweep.py --no-fuse                        # value path, for comparison
  python3 bench/thread_sweep.py --threads 1 4 16 32 --csv bench/thread_sweep.csv
"""
import argparse, csv as _csv, os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import medians
import size_sweep as ss   # run_arm / mean_last / RUNS / AVG_LAST -- one protocol, no duplication

# Named datasets, so the choice above is recorded in code rather than retyped on the command line.
# (rows, distinct, note) are generation-time facts from micro_bench.md, printed for provenance.
DATASETS = {
    "balanced": dict(path=os.path.expanduser("~/datasets/sizesweep/size_20M.parquet"),
                     col="v", rows=20_000_000, distinct=979_812, compression="SNAPPY",
                     note="Test 1's 20M point: 4.9% distinct, 4.94 B/row, fusion by policy"),
    "knee":     dict(path=os.path.expanduser("~/datasets/cardsweep10m_snappy/card_100000.parquet"),
                     col="v", rows=10_000_000, distinct=109_254, compression="SNAPPY",
                     note="Test 2's least-flattering point: C = 1.1% of N, 5.16 B/row"),
}

# Test 1's fused 20M measurement, used as the threads=32 cross-check for --dataset balanced.
XCHECK = {"balanced": dict(fpga_op=53.4, cpu_op=124.0, tol=0.15)}


def cpu_topology():
    """[(cpu, core, socket, node)] from lscpu -p. Empty list if lscpu is unavailable."""
    try:
        out = subprocess.run(["lscpu", "-p=CPU,CORE,SOCKET,NODE"], capture_output=True, text=True,
                             check=True).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split(",")
        try:
            rows.append(tuple(int(x) if x else 0 for x in f[:4]))
        except ValueError:
            continue
    return rows


def fpga_numa_node():
    """Best-effort NUMA node of the Xilinx/Coyote card, so small core counts sit next to the DMA
    engine instead of across an interconnect. Returns None if it cannot be determined."""
    try:
        ids = subprocess.run(["lspci", "-D", "-d", "10ee:"], capture_output=True, text=True).stdout
        for line in ids.splitlines():
            bdf = line.split()[0]
            p = f"/sys/bus/pci/devices/{bdf}/numa_node"
            if os.path.exists(p):
                with open(p) as fh:
                    n = int(fh.read().strip())
                if n >= 0:
                    return n
    except Exception:
        pass
    return None


def pick_cpus(n, topo, prefer_node=None):
    """N CPU ids as a taskset list, chosen from the real topology instead of assuming `0-(N-1)`.

    Why this exists: on the build node `lscpu -e` enumerates CPU 0 -> socket 0, CPU 1 -> socket 1,
    ... so a naive `0-3` spans FOUR NUMA nodes. For a DMA-bound measurement that is not a 4-core
    configuration, it is a 4-socket one, and the small-N points would be measuring interconnect
    latency. Order of preference here:
      1. the FPGA's own NUMA node first (DMA locality), then the remaining nodes in order;
      2. one CPU per PHYSICAL core before using any SMT sibling -- N=2 must mean two real cores,
         not two hyperthreads of one;
      3. within that, ascending cpu id, so the choice is deterministic and reproducible.
    """
    if not topo:
        return f"0-{n-1}" if n > 1 else "0"
    seen_core, first, sibling = set(), [], []
    def key(r):
        cpu, core, sock, node = r
        return (0 if (prefer_node is not None and node == prefer_node) else 1, node, core, cpu)
    for cpu, core, sock, node in sorted(topo, key=key):
        (first if (node, core) not in seen_core else sibling).append(cpu)
        seen_core.add((node, core))
    order = first + sibling
    return ",".join(str(c) for c in order[:n])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", choices=sorted(DATASETS), default="balanced")
    ap.add_argument("--path", help="override the dataset path (then --rows is required)")
    ap.add_argument("--col", default=None)
    ap.add_argument("--rows", type=int, default=None)
    ap.add_argument("--threads", nargs="+", type=int, default=[1, 2, 4, 8, 16, 32],
                    help="PRAGMA threads values. 32 is the reference: every earlier test used it.")
    ap.add_argument("--arms", nargs="+", default=["fpga", "cpp"], choices=["fpga", "cpp", "sql"])
    # groupby ONLY -- the SQL-exact baseline. The histogram-zoom variant is not used by this study.
    ap.add_argument("--cpp-impl", choices=["groupby"], default="groupby")
    ap.add_argument("--outlier-every", type=int, default=1000)
    ap.add_argument("--fuse-min-rows", type=int, default=6_000_000,
                    help="threshold handed to the shipped fusion policy (6M = Test 1's crossover)")
    ap.add_argument("--no-fuse", action="store_true", help="value path, 2 PCIe passes")
    # A 1-thread fused FPGA run is the one configuration here that has never been exercised, so the
    # runner gets a hard timeout. See size_sweep._run_duckdb for why it is SIGTERM-first.
    ap.add_argument("--timeout", type=float, default=600.0,
                    help="per-session wall limit in seconds (SIGTERM first, never SIGKILL first)")
    ap.add_argument("--no-taskset", action="store_true",
                    help="do NOT pin with taskset; measures PRAGMA threads alone, which leaves the "
                         "hardware_concurrency-sized regions unbounded (see module docstring)")
    ap.add_argument("--cpu-list", help="explicit taskset list for EVERY point (e.g. '0-15'), "
                                       "overriding the per-point 0-(N-1) default")
    ap.add_argument("--csv")
    a = ap.parse_args()

    medians.CPP_FN = medians.CPP_IMPL[a.cpp_impl]

    ds = DATASETS[a.dataset]
    path = a.path or ds["path"]
    col  = a.col or ds["col"]
    rows = a.rows or (ds["rows"] if not a.path else None)
    if not os.path.exists(path):
        sys.exit(f"missing dataset: {path}")
    if not rows:
        sys.exit("--rows is required when --path is given")

    ncpu = os.cpu_count() or 1
    over = [t for t in a.threads if t > ncpu]
    if over:
        print(f"!! requested {over} threads but this host has {ncpu} CPUs -- those points measure "
              f"oversubscription, not scaling", file=sys.stderr)

    expect = rows // a.outlier_every
    fusing = not a.no_fuse

    print(f"THREAD SWEEP -- mean of last {ss.AVG_LAST} of {ss.RUNS} runs (no median, no spread)")
    print(f"dataset : {a.dataset}  {path}")
    print(f"          {rows:,} rows · ~{ds['distinct']:,} distinct "
          f"({100.0*ds['distinct']/rows:.1f}% of N) · {ds['compression']} · {ds['note']}")
    print(f"arms={a.arms}  cpp={medians.CPP_FN}()  "
          f"fusion={'policy (threshold %s rows)' % f'{a.fuse_min_rows:,}' if fusing else 'OFF'}")
    # Build the per-point CPU plan up front, from the real topology, and PRINT it. The pinning is
    # part of the experimental setup, so it has to be visible in the log, not implied.
    topo = cpu_topology()
    fnode = fpga_numa_node()
    plan = {}
    if not a.no_taskset:
        for t in a.threads:
            plan[t] = a.cpu_list or pick_cpus(t, topo, fnode)

    nodes = len({r[3] for r in topo}) if topo else 0
    print(f"host has {ncpu} CPUs, {nodes} NUMA node(s); "
          f"FPGA NUMA node: {fnode if fnode is not None else 'unknown'}")
    if a.no_taskset:
        print("taskset pinning: OFF -- PRAGMA threads only, hardware_concurrency regions unbounded")
    else:
        print("core plan (one CPU per physical core, FPGA's NUMA node first):")
        for t in a.threads:
            print(f"    threads={t:<3} -> taskset -c {plan[t]}")
    print(f"expected flags = {expect:,} at every point\n")

    fmt = "{:>7} | {:>8} {:>8} {:>7} | {:>8} {:>8} | {:>9} {:>9} {:>7} | {:>6} {:>9}"
    print(fmt.format("threads", "FPGA op", "CPU op", "ratio", "F dec", "F pass",
                     "F cpu-s", "C cpu-s", "offload", "flags", "pass1"))
    print("-" * 118, flush=True)

    # Warm the page cache once: an unwarmed read would be charged to operator time, and at low thread
    # counts it would be charged UNEVENLY (fewer readers), manufacturing a fake scaling curve.
    with open(path, "rb") as fh:
        while fh.read(1 << 24):
            pass

    out_rows = []
    for t in a.threads:
        cpus = plan.get(t)
        res = {}
        for arm in a.arms:
            r = ss.run_arm(arm, path, rows, fuse=fusing, fuse_min_rows=a.fuse_min_rows,
                           threads=t, timeout=a.timeout, col=col, cpu_list=cpus)
            if r is None:
                break
            res[arm] = r
        if len(res) != len(a.arms):
            print(f"{t:>7}   FAILED -- see stderr", file=sys.stderr)
            continue

        f, cp = res.get("fpga"), res.get("cpp")
        nan = float("nan")
        f_op = ss.mean_last(f["heavy"]) if f and f["heavy"] else nan
        c_op = ss.mean_last(cp["heavy"]) if cp and cp["heavy"] else nan
        ratio = c_op / f_op if f_op == f_op and f_op else nan
        f_dec = ss.mean_last(f["decode"]) if f and f["decode"] else nan
        f_pas = ss.mean_last(f["passes"]) if f and f["passes"] else nan
        f_cpu = ss.mean_last(f["user"]) if f else nan
        c_cpu = ss.mean_last(cp["user"]) if cp else nan
        offl  = c_cpu / f_cpu if f_cpu == f_cpu and f_cpu else nan

        bad = ""
        if f:
            fc = f["counts"][-ss.RUNS:]
            bad = "ok" if fc and all(x == expect for x in fc) else \
                  (f"MISMATCH{sorted(set(fc))}" if fc else "")

        engaged = f["pass1"] if f else "-"
        if fusing and f and "fused" not in engaged:
            engaged += "!NOTFUSED"

        print(fmt.format(t, f"{f_op:.1f}", f"{c_op:.1f}", f"{ratio:.2f}x",
                         f"{f_dec:.1f}", f"{f_pas:.1f}",
                         f"{f_cpu:.3f}", f"{c_cpu:.3f}", f"{offl:.2f}x", bad, engaged),
              flush=True)

        out_rows.append(dict(threads=t, rows=rows, dataset=a.dataset,
                             fpga_op_ms=f_op, cpu_op_ms=c_op, speedup=ratio,
                             fpga_decode_ms=f_dec, fpga_passes_ms=f_pas,
                             fpga_e2e_s=ss.mean_last(f["real"]) if f else "",
                             cpu_e2e_s=ss.mean_last(cp["real"]) if cp else "",
                             fpga_cpu_seconds=f_cpu, cpu_cpu_seconds=c_cpu,
                             offload_ratio=offl, fused=fusing, cpu_list=cpus or "",
                             pass1=f["pass1"] if f else "", flags_ok=bad))

    if not out_rows:
        sys.exit("no points completed")

    # ---- derived analysis: the three numbers this test exists to produce ------------------------
    by_t = {r["threads"]: r for r in out_rows}
    lo, hi = min(by_t), max(by_t)
    print()
    print("=" * 118)

    def scal(key):
        a_, b_ = by_t[lo][key], by_t[hi][key]
        return a_ / b_ if b_ else float("nan")

    print(f"SCALING {lo} -> {hi} threads:  FPGA op {scal('fpga_op_ms'):.2f}x   "
          f"CPU op {scal('cpu_op_ms'):.2f}x   FPGA decode {scal('fpga_decode_ms'):.2f}x   "
          f"FPGA passes {scal('fpga_passes_ms'):.2f}x")

    # INTERNAL CHECK. `passes` is FPGA-side work on identical bytes; it must not move with host cores.
    pas = [r["fpga_passes_ms"] for r in out_rows if r["fpga_passes_ms"] == r["fpga_passes_ms"]]
    if pas and min(pas) > 0:
        spread = (max(pas) - min(pas)) / min(pas) * 100.0
        verdict = "FLAT (as required)" if spread < 10.0 else \
                  "NOT FLAT -- the FPGA is being starved at low thread counts, do NOT read this as " \
                  "a core-count-independence result"
        print(f"INTERNAL CHECK  `passes` spread across thread counts: {spread:.1f}%  -> {verdict}")

    # The headline: how many cores does the software baseline need to catch the offloaded path?
    f_at_lo = by_t[lo]["fpga_op_ms"]
    match = [t for t in sorted(by_t) if by_t[t]["cpu_op_ms"] <= f_at_lo]
    if match:
        print(f"ISO-PERFORMANCE  the CPU baseline needs {match[0]} thread(s) to match the FPGA arm "
              f"running at {lo} thread(s) ({f_at_lo:.1f} ms)")
    else:
        print(f"ISO-PERFORMANCE  the CPU baseline NEVER matches the FPGA arm at {lo} thread(s) "
              f"({f_at_lo:.1f} ms) -- not even at {hi} threads ({by_t[hi]['cpu_op_ms']:.1f} ms)")
    print(f"HEADLINE         FPGA at {lo} thread(s) vs CPU at {hi} threads: "
          f"{by_t[hi]['cpu_op_ms'] / f_at_lo:.2f}x")

    # Cross-check against the independent Test 1 measurement, where one exists.
    xc = XCHECK.get(a.dataset)
    if xc and hi in by_t and fusing:
        # Test 1 measured threads=32 UNPINNED, so a pinned run here is not a like-for-like replay:
        # pinning to exactly the physical cores removes the SMT siblings DuckDB could otherwise use.
        # Widen the tolerance in that case and say so, rather than flag a false drift.
        pinned = bool(plan)
        tol = xc["tol"] + (0.05 if pinned else 0.0)
        how = "pinned here vs UNPINNED in Test 1" if pinned else "both unpinned"
        for k, ref in (("fpga_op_ms", xc["fpga_op"]), ("cpu_op_ms", xc["cpu_op"])):
            got = by_t[hi][k]
            off = abs(got - ref) / ref
            tag = "ok" if off <= tol else f"DRIFT {off*100:.0f}% -- investigate before using"
            print(f"XCHECK vs Test 1 @{hi} threads ({how})  {k}: "
                  f"{got:.1f} vs {ref:.1f} ms  -> {tag}")

    print("=" * 118)
    print("F dec / F pass = the FPGA arm's decode and PCIe-pass phases (OASIS_IQR_TIMING). BOTH are")
    print("device work -- parquet decode is offloaded too -- so both should be FLAT in core count;")
    print("the host only orchestrates. cpu-s = process CPU-seconds (.timer user), so `offload` is how")
    print("much host CPU the FPGA path gives back at equal cores.")

    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = _csv.DictWriter(fh, fieldnames=list(out_rows[0].keys()))
            w.writeheader()
            w.writerows(out_rows)
        print(f"\ncsv: {a.csv}")


if __name__ == "__main__":
    main()
