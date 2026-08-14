#!/usr/bin/env python3
"""
CARDINALITY SWEEP -- runtime/throughput vs number of distinct values, at FIXED row count.

Reuses size_sweep.py's runner verbatim, so the protocol is identical:
    7 runs in one DuckDB session, arithmetic MEAN OF THE LAST 3, no median, no spread.

FUSION IS LEFT TO THE POLICY, not forced per point. `--fuse-min-rows` (default 6,000,000 = the
crossover measured in Test 1) is handed to the shipped decision in oasis_iqr.cpp, which then fuses iff
rows > threshold. At the default 20M rows that means fusion engages automatically at every point, by
policy rather than by override -- which is what we want to characterise. The harness prints the actual
`pass1=` state per point and flags `!NOTFUSED` if the policy declined, so a silently-unfused point can
never be mistaken for a fused measurement.

Note the shipped default threshold is 30M (oasis_iqr.cpp fuse_min_rows()), which at 20M rows would
never fuse. 6M is the MEASURED crossover from micro_bench.md Test 1; passing it here is a preview of
the auto-decision policy, not a change to the shipped default.

WHAT MOVES AND WHAT DOES NOT: only the number of distinct levels changes. The value range is held at
[0, 1e6) by the generator, so the quartiles, IQR and fences -- and therefore the expected flag count
(rows/1000) -- are identical at every point. See gen_card_sweep.sh for why that matters.

The generator pins encoding (PLAIN) and compression (UNCOMPRESSED), so bytes/row is exactly 8.00 at
every cardinality and the decoded and wire throughputs coincide. That is deliberate: it makes the FPGA
arm's flatness an internal correctness check on the sweep itself.

  cd ~/oasis && python3 bench/card_sweep.py
  python3 bench/card_sweep.py --csv bench/card_sweep.csv
  python3 bench/card_sweep.py --no-fuse            # value-path curve for comparison
"""
import argparse, csv as _csv, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import medians
import size_sweep as ss   # run_arm / mean_last / RUNS / AVG_LAST -- identical protocol, no duplication

DSDIR = os.path.expanduser("~/datasets/cardsweep10m")


def read_manifest(dsdir):
    """Generation-time facts (encoding, distinct, bytes) travel with the data, not re-derived here."""
    path = os.path.join(dsdir, "manifest.csv")
    if not os.path.exists(path):
        return {}
    out = {}
    with open(path) as fh:
        for r in _csv.DictReader(fh):
            try:
                out[int(r["card"])] = r
            except (KeyError, ValueError):
                continue
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cards", nargs="+", type=int,
                    default=[10, 100, 1000, 10000, 100000, 1000000, 10000000])
    ap.add_argument("--arms", nargs="+", default=["fpga", "cpp"], choices=["fpga", "cpp", "sql"])
    # groupby ONLY. iqr_cpu_flags_groupby is the SQL-exact transliteration and the single
    # baseline this study reports; the histogram-zoom variant is deliberately not used.
    ap.add_argument("--cpp-impl", choices=["groupby"], default="groupby",
                    help="fixed: the SQL-exact GROUP BY baseline")
    ap.add_argument("--outlier-every", type=int, default=1000)
    ap.add_argument("--fuse-min-rows", type=int, default=6_000_000,
                    help="threshold handed to the shipped fusion policy (default 6M = the crossover "
                         "measured in Test 1). Fusion engages iff rows > this.")
    ap.add_argument("--no-fuse", action="store_true",
                    help="disable fusion entirely, to measure the value-path curve for comparison")
    ap.add_argument("--dsdir", default=DSDIR)
    ap.add_argument("--csv")
    a = ap.parse_args()

    medians.CPP_FN = medians.CPP_IMPL[a.cpp_impl]
    man = read_manifest(a.dsdir)

    print(f"CARDINALITY SWEEP -- mean of last {ss.AVG_LAST} of {ss.RUNS} runs (no median, no spread)")
    print(f"arms={a.arms}  cpp={medians.CPP_FN}()  "
          f"fusion={'OFF' if a.no_fuse else f'policy (threshold {a.fuse_min_rows:,} rows)'}")
    print(f"datasets: {a.dsdir}\n")

    fmt = "{:>9} {:>10} {:>7} {:>7} | {:>9} {:>9} {:>7} | {:>8} {:>7} | {:>6} {:>9}"
    print(fmt.format("card", "distinct~", "enc", "B/row", "FPGA op", "CPU op", "ratio",
                     "dec GB/s", "wire", "flags", "pass1"))
    print("-" * 118)

    rows_out = []
    for c in a.cards:
        path = os.path.join(a.dsdir, f"card_{c}.parquet")
        if not os.path.exists(path):
            print(f"{c:>9}  MISSING {path} -- run bench/gen_card_sweep.sh", file=sys.stderr)
            continue

        m = man.get(c, {})
        rows = int(m.get("rows") or 0)
        if not rows:
            print(f"{c:>9}  no manifest row -- run bench/gen_card_sweep.sh verify", file=sys.stderr)
            continue
        nbytes = int(m.get("bytes") or os.path.getsize(path))
        expect = rows // a.outlier_every

        with open(path, "rb") as fh:              # warm the page cache
            while fh.read(1 << 24):
                pass

        res = {}
        for arm in a.arms:
            r = ss.run_arm(arm, path, rows, fuse=not a.no_fuse, fuse_min_rows=a.fuse_min_rows)
            if r is None:
                break
            res[arm] = r
        if len(res) != len(a.arms):
            continue

        f, cp = res.get("fpga"), res.get("cpp")
        f_op = ss.mean_last(f["heavy"]) if f and f["heavy"] else float("nan")
        c_op = ss.mean_last(cp["heavy"]) if cp and cp["heavy"] else float("nan")
        ratio = c_op / f_op if f_op == f_op and f_op else float("nan")
        dec_gbs = (8.0 * rows) / (f_op / 1000.0) / 1e9 if f_op == f_op and f_op > 0 else float("nan")
        wire_gbs = nbytes / (f_op / 1000.0) / 1e9 if f_op == f_op and f_op > 0 else float("nan")

        bad = ""
        if f:
            fc = f["counts"][-ss.RUNS:]
            bad = "ok" if fc and all(x == expect for x in fc) else \
                  (f"MISMATCH{sorted(set(fc))}" if fc else "")

        engaged = f["pass1"] if f else "-"
        if not a.no_fuse and f and "fused" not in engaged:
            engaged += "!NOTFUSED"

        print(fmt.format(f"{c:,}", m.get("distinct", "?"), (m.get("encoding") or "?")[:7],
                         f"{nbytes/rows:.2f}", f"{f_op:.1f}", f"{c_op:.1f}", f"{ratio:.2f}x",
                         f"{dec_gbs:.2f}", f"{wire_gbs:.2f}", bad, engaged))

        rows_out.append(dict(card=c, rows=rows, distinct=m.get("distinct", ""),
                             encoding=m.get("encoding", ""), bytes=nbytes,
                             bytes_per_row=nbytes / rows,
                             fpga_op_ms=f_op, cpu_op_ms=c_op, speedup=ratio,
                             decoded_gbs=dec_gbs, wire_gbs=wire_gbs,
                             fpga_e2e_s=ss.mean_last(f["real"]) if f else "",
                             cpu_e2e_s=ss.mean_last(cp["real"]) if cp else "",
                             fpga_decode_ms=ss.mean_last(f["decode"]) if f and f["decode"] else "",
                             fpga_passes_ms=ss.mean_last(f["passes"]) if f and f["passes"] else "",
                             fpga_cpu_seconds=ss.mean_last(f["user"]) if f else "",
                             cpu_cpu_seconds=ss.mean_last(cp["user"]) if cp else "",
                             pass1=f["pass1"] if f else "", flags_ok=bad))

    print()
    print("INTERNAL CHECK: encoding, compression and bytes/row are pinned by the generator, so the")
    print("FPGA arm MUST be flat across every cardinality. If it is not, the sweep is not single-variable.")
    print("EXPECTED RESULT: CPU op RISES with cardinality (GROUP BY builds and sorts a per-distinct-value")
    print("table) while FPGA op stays flat (fixed 4096-bin pipeline, indifferent to distinct count).")

    if a.csv and rows_out:
        with open(a.csv, "w", newline="") as fh:
            w = _csv.DictWriter(fh, fieldnames=list(rows_out[0].keys()))
            w.writeheader()
            w.writerows(rows_out)
        print(f"\ncsv: {a.csv}")


if __name__ == "__main__":
    main()
