#!/usr/bin/env python3
"""
TEST 5 -- DISTRIBUTION-SHAPE (SKEW) SWEEP: harness.

Companion to bench/gen_skew_sweep.py (read its header for the design and for the two confounds it
controls). Six files, 20M rows each, IDENTICAL in row count, cardinality (1,020,000 exactly),
frequency profile, encoding (PLAIN), compression (none, so 8.00 B/row exactly), row-group geometry
and -- the one this generator adds -- quantisation resolution (~579 bins per IQR at every point).
The ONLY thing that moves is the shape of the value distribution: Fisher skewness 0.00 -> 3.44.

WHY THIS TEST EXISTS. It is the last unexplained residual in the study. Test 1's size model
over-predicts the dictionary-encoded REAL datasets by 1.29-2.54x, worst on tail-heavy taxi; Test 2
showed the FPGA gets FASTER on low-byte data, so encoding runs the wrong way to explain it. Two
suspects were left: distribution shape and ragged row groups. This isolates the first.

TWO THINGS ARE MEASURED, and they are different claims:

  1. SPEED -- is the FPGA indifferent to distribution shape? Expected YES: the histogram does
     identical work regardless of where the values sit, and decode is byte-driven with bytes pinned.
     If the FPGA arm is flat while the CPU arm moves, that is the data-obliviousness claim, and it is
     the panel that TRANSFERS to the z-score operator unchanged.

  2. ACCURACY -- does the 4096-bin histogram still agree with exact arithmetic as the tail grows?
     This one is IQR-specific (a z-score baseline needs no quantiles, so it has no binning error at
     all) but it is the one that explains taxi_d3's residual 104 mismatches, and it is where the
     interesting risk lives.

PRE-REGISTERED PREDICTIONS (written before the first run -- keep them here as written, whatever
happens, the way codec_sweep.py kept its half-wrong one):

  P1. The FPGA arm is FLAT in skewness. Bytes, cardinality and row geometry are pinned, so there is
      nothing left for shape to act on.
  P2. The CPU arm is also roughly flat, but for a DIFFERENT reason (GROUP BY does N probes over a
      fixed 1.02M-entry table regardless of value spacing). If it moves, suspect cache locality: a
      skewed column keeps the hot part of the aggregate table resident.
  P3. Accuracy HOLDS or IMPROVES with skew. The window is [Q1-2*IQR, Q3+2*IQR], so resolution per
      IQR is scale-free and the generator pins it at ~579 bins; meanwhile a heavier tail puts LOWER
      density at the fence, so fewer rows sit within one bin of the decision boundary. The taxi_d3
      pathology was a dense CLUSTER at the fence, which is a different shape from smooth skew --
      so if accuracy degrades smoothly here, that hypothesis is wrong and worth saying so.
  P4. The `passes` phase is flat -- same decoded volume at every point. This is the INTERNAL CHECK,
      not a result; if it moves, the measurement is contaminated and nothing else here is readable.

THE CORRECTNESS GATE IS THREE-WAY, which is what makes the accuracy number trustworthy:
    FPGA count   vs   CPU baseline count   vs   the generator's SQL-exact expected_total
The generator computed expected_total from the file using the SQL baseline's own discrete-quantile
rule, so a disagreement between the CPU arm and expected_total is a DEFINITION mismatch, while a
disagreement between the FPGA and both is a QUANTISATION measurement. Reporting one number without
the other cannot distinguish those.

PROTOCOL -- identical to Tests 1/3/4, reused verbatim from size_sweep.run_arm:
    7 runs in ONE DuckDB session, arithmetic MEAN OF THE LAST 3. No median, no spread.

  cd ~/oasis && python3 bench/skew_sweep.py --csv bench/skew_sweep.csv
  python3 bench/skew_sweep.py --no-fuse --csv bench/skew_sweep_nofuse.csv
  python3 bench/skew_sweep.py --sample 65536      # bigger window sample: isolates window error
"""
import argparse, csv as _csv, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import medians
import size_sweep as ss   # run_arm / mean_last / RUNS / AVG_LAST -- one protocol, no duplication

DSDIR = os.path.expanduser("~/datasets/skewsweep")


def read_manifest(dsdir):
    path = os.path.join(dsdir, "manifest.csv")
    if not os.path.exists(path):
        sys.exit(f"no manifest at {path} -- run bench/gen_skew_sweep.py first")
    rows = list(_csv.DictReader(open(path)))
    return sorted(rows, key=lambda r: float(r["skewness"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsdir", default=DSDIR)
    ap.add_argument("--arms", nargs="+", default=["fpga", "cpp"], choices=["fpga", "cpp", "sql"])
    ap.add_argument("--cpp-impl", choices=["groupby"], default="groupby")
    ap.add_argument("--threads", type=int, default=32)
    ap.add_argument("--fuse-min-rows", type=int, default=6_000_000,
                    help="6M = Test 1's measured crossover; at 20M every point fuses by policy")
    ap.add_argument("--no-fuse", action="store_true", help="value path, 2 PCIe passes")
    ap.add_argument("--sample", type=int, default=0,
                    help="OASIS_IQR_SAMPLE: window-sample size. The fused window is derived from a "
                         "stride sample, and its Q3 error GROWS with skew (density at Q3 falls). "
                         "Raising this separates WINDOW error from BIN quantisation error.")
    ap.add_argument("--timeout", type=float, default=600.0)
    ap.add_argument("--csv")
    a = ap.parse_args()

    medians.CPP_FN = medians.CPP_IMPL[a.cpp_impl]
    man = read_manifest(a.dsdir)
    fusing = not a.no_fuse
    if a.sample:
        os.environ["OASIS_IQR_SAMPLE"] = str(a.sample)

    print(f"SKEW SWEEP (Test 5) -- mean of last {ss.AVG_LAST} of {ss.RUNS} runs (no median/spread)")
    print(f"arms={a.arms}  cpp={medians.CPP_FN}()  threads={a.threads}  "
          f"fusion={'policy (%s rows)' % f'{a.fuse_min_rows:,}' if fusing else 'OFF'}"
          f"{'  OASIS_IQR_SAMPLE=' + str(a.sample) if a.sample else ''}")
    print(f"datasets: {a.dsdir}")
    print("all six files: 20M rows, 1,020,000 distinct, PLAIN/uncompressed 8.00 B/row, ~579 "
          "bins/IQR.\nONLY the distribution shape moves.\n")

    fmt = "{:>4} {:>8} {:>9} {:>7} | {:>8} {:>8} {:>7} | {:>8} {:>7} | {:>12} {:>9} {:>8}"
    print(fmt.format("a", "skew", "kurtosis", "bins/IQR", "FPGA op", "CPU op", "ratio",
                     "F dec", "F pass", "expected", "FPGA-exp", "CPU-exp"))
    print("-" * 130)

    out = []
    for r in man:
        path = r["file"]
        if not os.path.exists(path):
            print(f"  MISSING {path}", file=sys.stderr)
            continue
        rows = int(r["rows"])
        expected = int(r["expected_total"])

        with open(path, "rb") as fh:                     # warm the page cache
            while fh.read(1 << 24):
                pass

        res = {}
        for arm in a.arms:
            got = ss.run_arm(arm, path, rows, fuse=fusing, fuse_min_rows=a.fuse_min_rows,
                             threads=a.threads, timeout=a.timeout, col="v")
            if got is None:
                break
            res[arm] = got
        if len(res) != len(a.arms):
            print(f"  FAILED {os.path.basename(path)} -- see stderr", file=sys.stderr)
            continue

        f, cp = res.get("fpga"), res.get("cpp")
        nan = float("nan")
        f_op = ss.mean_last(f["heavy"]) if f and f["heavy"] else nan
        c_op = ss.mean_last(cp["heavy"]) if cp and cp["heavy"] else nan
        f_dec = ss.mean_last(f["decode"]) if f and f["decode"] else nan
        f_pas = ss.mean_last(f["passes"]) if f and f["passes"] else nan
        ratio = c_op / f_op if f_op == f_op and f_op else nan

        # THREE-WAY correctness. The counts are whole-run results, one per iteration, so take the
        # steady-state ones and require they agree with each other before comparing to `expected`:
        # a WANDERING count across iterations is the marginal-hold silicon signature and must not be
        # averaged away into a plausible-looking single number.
        fc = f["counts"][-ss.RUNS:] if f else []
        cc = cp["counts"][-ss.RUNS:] if cp else []
        f_cnt = fc[-1] if fc else None
        c_cnt = cc[-1] if cc else None
        f_wander = len(set(fc)) > 1
        c_wander = len(set(cc)) > 1
        f_err = (f_cnt - expected) if f_cnt is not None else None
        c_err = (c_cnt - expected) if c_cnt is not None else None

        engaged = f["pass1"] if f else "-"
        note = ""
        if fusing and f and "fused" not in engaged:
            note += " !NOTFUSED"
        if f_wander:
            note += f" !FPGA-WANDERS{sorted(set(fc))}"
        if c_wander:
            note += f" !CPU-WANDERS{sorted(set(cc))}"

        print(fmt.format(r["a"], r["skewness"], r["kurtosis"], r["bins_per_iqr"],
                         f"{f_op:.1f}", f"{c_op:.1f}", f"{ratio:.2f}x",
                         f"{f_dec:.1f}", f"{f_pas:.1f}",
                         f"{expected:,}",
                         f"{f_err:+,}" if f_err is not None else "-",
                         f"{c_err:+,}" if c_err is not None else "-") + note, flush=True)

        out.append(dict(a=int(r["a"]), skewness=float(r["skewness"]),
                        kurtosis=float(r["kurtosis"]),
                        mean_over_median=float(r["mean_over_median"]),
                        bins_per_iqr=float(r["bins_per_iqr"]), rows=rows,
                        bytes_per_row=float(r["bytes_per_row"]), distinct=int(r["distinct"]),
                        gate=r["gate"], natural_outliers=int(r["natural_outliers"]),
                        expected_total=expected,
                        fpga_op_ms=f_op, cpu_op_ms=c_op, speedup=ratio,
                        fpga_decode_ms=f_dec, fpga_passes_ms=f_pas,
                        fpga_e2e_s=ss.mean_last(f["real"]) if f else "",
                        cpu_e2e_s=ss.mean_last(cp["real"]) if cp else "",
                        fpga_cpu_seconds=ss.mean_last(f["user"]) if f else "",
                        cpu_cpu_seconds=ss.mean_last(cp["user"]) if cp else "",
                        fpga_count=f_cnt, cpu_count=c_cnt,
                        fpga_err=f_err, cpu_err=c_err,
                        fpga_rel_err=(abs(f_err) / expected if f_err is not None and expected else ""),
                        fpga_wander=f_wander, cpu_wander=c_wander,
                        pass1=f["pass1"] if f else "", fused=fusing))

    if not out:
        sys.exit("no points completed")

    print()
    print("=" * 130)

    # ---- INTERNAL CHECK (P4): same decoded volume everywhere, so pass 2 cannot legitimately move.
    p = [r["fpga_passes_ms"] for r in out if r["fpga_passes_ms"] == r["fpga_passes_ms"]]
    if len(p) > 1 and min(p) > 0:
        spread = (max(p) - min(p)) / min(p) * 100.0
        print(f"INTERNAL CHECK  `passes` spread {spread:.1f}%  -> " +
              ("FLAT (as required)" if spread < 10.0 else
               "NOT FLAT -- shape is somehow reaching a transport-bound pass; do NOT read anything "
               "else in this table until that is explained"))

    # ---- P1/P2: flatness of each arm across the swept axis --------------------------------------
    def spread_of(key):
        v = [r[key] for r in out if r[key] == r[key]]
        return (max(v) - min(v)) / min(v) * 100.0 if v and min(v) > 0 else float("nan")

    lo, hi = out[0], out[-1]
    print(f"SPEED           skewness {lo['skewness']:.2f} -> {hi['skewness']:.2f}:  "
          f"FPGA op {hi['fpga_op_ms']/lo['fpga_op_ms']:.2f}x (spread {spread_of('fpga_op_ms'):.1f}%)   "
          f"CPU op {hi['cpu_op_ms']/lo['cpu_op_ms']:.2f}x (spread {spread_of('cpu_op_ms'):.1f}%)   "
          f"decode {hi['fpga_decode_ms']/lo['fpga_decode_ms']:.2f}x")
    print(f"                speedup {lo['speedup']:.2f}x -> {hi['speedup']:.2f}x")

    # ---- P3: accuracy vs skew --------------------------------------------------------------------
    print("\nACCURACY (FPGA vs SQL-exact, computed by the generator with the baseline's own rule):")
    for r in out:
        rel = (abs(r["fpga_err"]) / r["expected_total"] * 100.0) if r["fpga_err"] is not None and r["expected_total"] else float("nan")
        tag = "EXACT" if r["fpga_err"] == 0 else f"{rel:.4f}% of flagged"
        cpu_tag = "" if r["cpu_err"] in (0, None) else f"   [CPU also off by {r['cpu_err']:+,} -- " \
                                                       f"that is a DEFINITION mismatch, not the FPGA]"
        print(f"    skew {r['skewness']:5.2f}  gate={r['gate']:<5}  expected {r['expected_total']:>10,}  "
              f"FPGA {r['fpga_err']:+,} ({tag}){cpu_tag}")

    worst = max((r for r in out if r["fpga_err"] is not None),
                key=lambda r: abs(r["fpga_err"]) / max(1, r["expected_total"]), default=None)
    if worst is not None:
        print(f"    worst relative error: {abs(worst['fpga_err'])/max(1,worst['expected_total'])*100:.4f}% "
              f"at skewness {worst['skewness']:.2f}")

    print("=" * 130)
    print("`passes` is the internal check (identical decoded volume). `F dec` is the shared decoder.")
    print("FPGA-exp / CPU-exp are SIGNED deviations from the SQL-exact expected count: the CPU column")
    print("must be 0 everywhere -- if it is not, the disagreement is a quantile DEFINITION mismatch")
    print("and the FPGA column cannot be read as quantisation error until that is resolved.")

    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = _csv.DictWriter(fh, fieldnames=list(out[0].keys()))
            w.writeheader()
            w.writerows(out)
        print(f"\ncsv: {a.csv}")


if __name__ == "__main__":
    main()
