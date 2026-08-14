#!/usr/bin/env python3
"""
SIZE SWEEP -- runtime/throughput vs row count, FPGA vs C++ CPU, on synthetic data where ONLY N moves.

MEASUREMENT PROTOCOL (this file's whole reason for existing; deliberately NOT medians.py's):
    run the query 7 times in ONE DuckDB session, report the ARITHMETIC MEAN OF THE LAST 3.
No medians, no spread. The first 4 iterations are warm-up and are discarded.

Why last-3-of-7 is the right shape for this: all 7 run inside a single DuckDB process, and this
project has a documented warm-up artefact -- DuckDB's allocator pooling is absent early in a session,
which made taxi_d3/d4 bimodal (RESULTS.md 9.18). Four discarded iterations put every measurement
firmly in steady state, and averaging 3 of them smooths the residual jitter without hiding a trend
the way a median over a wide, drifting sample would.

WHAT IS HELD CONSTANT so the x-axis really is size (see gen_size_sweep.sh for the generator):
  * cardinality FIXED in absolute terms (default 1e6 distinct, high-card like sf10, NOT low-card)
  * identical value distribution, outlier rate (0.1%) and outlier placement
  * identical row-group geometry (122880, a multiple of 8)
  * FUSION OFF at every point. fuse_min_rows=30M would otherwise switch code path mid-sweep, so a
    naive sweep would show a step at 30M that is a config artefact, not a size effect. Use --fuse to
    measure the fused curve separately (as a SECOND line, never mixed into this one).

CORRECTNESS IS CHECKED AT EVERY POINT, not just timed: the generator places outliers in an empty
value gap far outside the fence, so the expected flag count is exactly rows/1000 regardless of the
FPGA's 4096-bin quantisation. All 7 iterations are checked, which also catches the run-to-run
"wandering" signature of a marginal-hold silicon defect (the failure mode that once cost this project
~10% of histogram counts).

  cd ~/oasis && python3 bench/size_sweep.py
  python3 bench/size_sweep.py --sizes 1 10 100 --csv /tmp/sweep.csv
  python3 bench/size_sweep.py --arms fpga cpp sql      # sql is SLOW at 100M
"""
import argparse, os, re, signal, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import medians  # reuse the EXACT arm definitions, so "operator time" means the same thing here

DSDIR = os.path.expanduser("~/datasets/sizesweep")

RUNS, AVG_LAST = 7, 3          # the protocol: 7 iterations, mean of the final 3

# The FPGA phase breakdown (OASIS_IQR_TIMING=1) explains the SHAPE of the curve, so capture it too.
DECODE = re.compile(r"\[iqr\]\s+decode\s+([\d.]+) ms")
PASSES = re.compile(r"passes\s+([\d.]+)")
COUNT  = re.compile(r"^(\d+)$", re.M)      # bare result line (.mode csv + .headers off)
# Whether fusion ACTUALLY engaged. Essential: without this you cannot tell "fusion did not help" from
# "fusion never ran" -- and the latter is the default outcome below fuse_min_rows.
PASS1  = re.compile(r"pass1=(\w+)")
SINK   = re.compile(r"sink=(\w+)")


def mean_last(xs, k=AVG_LAST):
    return sum(xs[-k:]) / len(xs[-k:]) if xs else float("nan")


def _run_duckdb(sql, env, timeout=None, cmd_prefix=()):
    """Run one DuckDB session. `timeout` is a HARD requirement for any sweep that can wedge an FPGA
    query (e.g. thread_sweep.py at threads=1): the standing project rule is never to interrupt an
    in-flight FPGA query by hand, so the escape hatch has to be an automatic, graceful one.

    Escalation is deliberately SIGTERM-first with a long grace period. A SIGKILL'd DuckDB leaves
    Coyote's pinned pages and any in-flight DMA behind, and Coyote cannot reset user logic between
    host processes -- that is the path that has historically required a node reboot. SIGKILL is
    therefore last-resort only, and it says so loudly.
    """
    p = subprocess.Popen(list(cmd_prefix) + [medians.DUCKDB],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    try:
        out, err = p.communicate(sql, timeout=timeout)
        return out + err
    except subprocess.TimeoutExpired:
        print(f"    !! TIMEOUT after {timeout}s -- sending SIGTERM (never SIGKILL first: pinned "
              f"pages / in-flight DMA)", file=sys.stderr)
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        try:
            out, err = p.communicate(timeout=60)
            return out + err
        except subprocess.TimeoutExpired:
            print("    !! SIGTERM ignored for 60 s -- escalating to SIGKILL. THE CARD MAY BE LEFT "
                  "IN A BAD STATE: re-run the correctness gate before trusting any later number.",
                  file=sys.stderr)
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            out, err = p.communicate()
            return out + err


def run_arm(arm, path, rows, fuse, fuse_min_rows=0, threads=32, timeout=None, col="v",
            cpu_list=None):
    """7 iterations in one session. Returns per-iteration lists; caller averages the last 3.

    `threads` becomes `PRAGMA threads`, which governs BOTH arms' host parallelism: the FPGA arm's
    parquet decode (oasis_scan.cpp sizes its worker budget from TaskScheduler::NumberOfThreads) and
    the C++ baseline's partitioning (CpuThreadCount, oasis_iqr.cpp:1429). Every call is a FRESH
    process, so a thread sweep never has to mutate the pragma mid-session.

    `cpu_list` (e.g. "0-7") additionally pins the process with taskset. NEEDED for an honest
    core-count sweep, because `PRAGMA threads` does NOT bound all host work: three regions size
    themselves from `std::thread::hardware_concurrency()` instead -- the window-sample decode
    (oasis_iqr.cpp:510), the flag-copy stage (:871) and the IqrThreadPool (:1489). Measured on this
    host (glibc 2.35): hardware_concurrency() is NOT affinity-aware, it reports 64 even under
    `taskset -c 0`. So taskset does not shrink those pools -- it CONFINES them, which is what a
    "how many cores does this need" experiment actually wants. Side effect: at low core counts those
    pools are oversubscribed, which costs the FPGA arm a little; the bias is therefore CONSERVATIVE.
    """
    body = medians.stmt(arm, path, col, consume=True)
    sql = (f"PRAGMA threads={threads};\n.mode csv\n.headers off\n.timer on\n" + (body + "\n") * RUNS)

    env = dict(os.environ)
    env["OASIS_IQR_TIMING"] = "1"
    env["LD_LIBRARY_PATH"] = os.path.expanduser("~/opt/lib") + ":" + env.get("LD_LIBRARY_PATH", "")
    # Uniform code path across the sweep unless explicitly asked otherwise -- see module docstring.
    for k in ("OASIS_IQR_IDX_PASS2", "OASIS_IQR_STREAM", "OASIS_IQR_FUSE", "OASIS_IQR_WINDOW_FPGA",
              "OASIS_IQR_FUSE_MIN_ROWS"):
        env.pop(k, None)
    if fuse:
        env.update(OASIS_IQR_STREAM="1", OASIS_IQR_FUSE="1", OASIS_IQR_WINDOW_FPGA="1")
        # MUST lower the row gate too, or fusion silently does NOT engage below its default 30M
        # (oasis_iqr.cpp fuse_min_rows()) and every small-N point would report the value path while
        # looking like a fused measurement. Finding the real crossover requires measuring BELOW the
        # current threshold -- that is the entire purpose of the fused sweep.
        env["OASIS_IQR_FUSE_MIN_ROWS"] = str(fuse_min_rows)

    prefix = ["taskset", "-c", cpu_list] if cpu_list else []
    out = _run_duckdb(sql, env, timeout, prefix)

    reals  = [float(m.group(1)) for m in medians.REAL.finditer(out)]
    users  = [float(m.group(2)) for m in medians.REAL.finditer(out)]
    heavy  = [float(m.group(1)) for m in medians.HEAVY.finditer(out)]
    counts = [int(m.group(1)) for m in COUNT.finditer(out)]
    decode = [float(m.group(1)) for m in DECODE.finditer(out)]
    passes = [float(m.group(1)) for m in PASSES.finditer(out)]
    pass1  = sorted({m.group(1) for m in PASS1.finditer(out)})
    sink   = sorted({m.group(1) for m in SINK.finditer(out)})

    if len(reals) < RUNS:
        print(f"    !! {arm}: expected {RUNS} timed runs, got {len(reals)}", file=sys.stderr)
        if not reals:
            print(out[-900:], file=sys.stderr)
            return None
    return dict(real=reals, user=users, heavy=heavy, counts=counts, decode=decode, passes=passes,
                pass1="/".join(pass1) or "-", sink="/".join(sink) or "-")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", nargs="+", type=int,
                    default=[1, 3, 6, 10, 20, 40, 60, 80, 100], help="millions of rows")
    ap.add_argument("--arms", nargs="+", default=["fpga", "cpp"], choices=["fpga", "cpp", "sql"])
    ap.add_argument("--cpp-impl", choices=sorted(medians.CPP_IMPL), default="groupby",
                    help="groupby = the fair SQL-exact baseline (RESULTS.md 9.35)")
    ap.add_argument("--outlier-every", type=int, default=1000,
                    help="must match gen_size_sweep.sh; sets the expected flag count")
    ap.add_argument("--fuse", action="store_true",
                    help="measure the FUSED curve instead (plot as a separate line, never mixed). "
                         "Also forces OASIS_IQR_FUSE_MIN_ROWS so fusion engages below the 30M default")
    ap.add_argument("--fuse-min-rows", type=int, default=0,
                    help="row gate used with --fuse (default 0 = fuse at every size, which is what "
                         "finding the true crossover requires)")
    ap.add_argument("--dsdir", default=DSDIR)
    ap.add_argument("--csv")
    a = ap.parse_args()

    medians.CPP_FN = medians.CPP_IMPL[a.cpp_impl]

    print(f"SIZE SWEEP -- mean of last {AVG_LAST} of {RUNS} runs (no median, no spread)")
    print(f"arms={a.arms}  cpp={medians.CPP_FN}()  fusion={'ON' if a.fuse else 'OFF'}  "
          f"outliers=1/{a.outlier_every}")
    print(f"datasets: {a.dsdir}\n")

    rowsfmt = "{:>7} {:>10} | {:>9} {:>9} | {:>9} {:>9} | {:>8} {:>8} | {:>7} {:>9} {:>10}"
    print(rowsfmt.format("rows", "expect", "FPGA e2e", "CPU e2e", "FPGA op", "CPU op",
                         "F ms/Mr", "C ms/Mr", "F GB/s", "flags", "pass1"))
    print("-" * 120)

    csv = []
    for m in a.sizes:
        rows = m * 1_000_000
        path = os.path.join(a.dsdir, f"size_{m}M.parquet")
        if not os.path.exists(path):
            print(f"{m:>6}M  MISSING {path} -- run bench/gen_size_sweep.sh", file=sys.stderr)
            continue
        expect = rows // a.outlier_every

        # Warm the page cache: an unwarmed read would be measured as operator time.
        with open(path, "rb") as fh:
            while fh.read(1 << 24):
                pass

        res = {}
        for arm in a.arms:
            r = run_arm(arm, path, rows, a.fuse, a.fuse_min_rows)
            if r is None:
                break
            res[arm] = r
        if len(res) != len(a.arms):
            continue

        f, c = res.get("fpga"), res.get("cpp")
        f_e2e = mean_last(f["real"]) if f else float("nan")
        c_e2e = mean_last(c["real"]) if c else float("nan")
        f_op  = mean_last(f["heavy"]) if f and f["heavy"] else float("nan")
        c_op  = mean_last(c["heavy"]) if c and c["heavy"] else float("nan")
        f_mMr = f_op / m if f_op == f_op else float("nan")
        c_mMr = c_op / m if c_op == c_op else float("nan")
        # Decoded-payload throughput: 8 bytes per INT64 row, over the operator time.
        f_gbs = (8.0 * rows) / (f_op / 1000.0) / 1e9 if f_op == f_op and f_op > 0 else float("nan")

        # Correctness at every point, on EVERY iteration (catches run-to-run wandering).
        bad = ""
        if f:
            fc = [x for x in f["counts"]][-RUNS:]
            if fc and any(x != expect for x in fc):
                bad = f"MISMATCH {sorted(set(fc))}"
            elif fc:
                bad = "ok"

        engaged = f["pass1"] if f else "-"
        # Loud, because a silently-unfused point in a "fused" sweep is a wrong conclusion, not a gap.
        if a.fuse and f and "fused" not in engaged:
            engaged += "!NOTFUSED"

        print(rowsfmt.format(f"{m}M", expect, f"{f_e2e:.4f}", f"{c_e2e:.4f}",
                             f"{f_op:.1f}", f"{c_op:.1f}",
                             f"{f_mMr:.2f}", f"{c_mMr:.2f}", f"{f_gbs:.2f}", bad, engaged))

        csv.append(dict(rows=rows, expect=expect,
                        fpga_e2e_s=f_e2e, cpu_e2e_s=c_e2e,
                        fpga_op_ms=f_op, cpu_op_ms=c_op,
                        fpga_ms_per_mrow=f_mMr, cpu_ms_per_mrow=c_mMr,
                        fpga_gbs=f_gbs,
                        fpga_cpu_speedup=(c_op / f_op) if f_op == f_op and f_op else float("nan"),
                        fpga_decode_ms=mean_last(f["decode"]) if f and f["decode"] else "",
                        fpga_passes_ms=mean_last(f["passes"]) if f and f["passes"] else "",
                        fpga_cpu_seconds=mean_last(f["user"]) if f else "",
                        cpu_cpu_seconds=mean_last(c["user"]) if c else "",
                        pass1=f["pass1"] if f else "", sink=f["sink"] if f else "",
                        fused=bool(a.fuse), flags_ok=bad))

    print()
    print("ms/Mr = operator ms per million rows. FPGA should be FLAT with N (fixed pipeline); the CPU's")
    print("should FALL as its ~13 ms fixed startup amortises -- that divergence is the plot's point.")
    print("flags: 'ok' = all 7 iterations returned exactly the expected count.")

    if a.csv and csv:
        import csv as _csv
        with open(a.csv, "w", newline="") as fh:
            w = _csv.DictWriter(fh, fieldnames=list(csv[0].keys()))
            w.writeheader()
            w.writerows(csv)
        print(f"\ncsv: {a.csv}")


if __name__ == "__main__":
    main()
