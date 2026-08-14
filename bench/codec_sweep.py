#!/usr/bin/env python3
"""
COMPRESSION & ENCODING SENSITIVITY -- how much does the on-disk REPRESENTATION cost?

Companion to bench/gen_codec_sweep.sh (read its header for the design and for the hardware envelope).

WHAT IS BEING MEASURED. Test 3 established the phase split: 62% of FPGA operator time is the DECODE
window (which, when fused, has PASS 1 hidden under it) and 23% is PASS 2 alone -- the classify
re-stream, which is transport-bound (160 MB / 12.5 GB/s = 12.8 ms). Do NOT call the 23% band "the
statistics": iqr_runner.cpp:509 accounts pass 1 to the decode phase by design
(iqr_runner.hpp:115, heavy = max(decode, pass1) + pass2). The decoder is the component the IQR and
z-score operators SHARE. So the
representation axis characterises the shared substrate, not this particular statistic. Within a
cardinality level the four files hold the IDENTICAL multiset of values (gated by an order-independent
digest in the generator), so:

    `passes` (pass 2) is a CONTROL and must not move -- the decoded volume is identical, so a
    transport-bound pass cannot change.  Everything that moves is the decode window.

PROTOCOL -- identical to Tests 1 and 3, reused verbatim from size_sweep.run_arm:
    7 runs in ONE DuckDB session, arithmetic MEAN OF THE LAST 3. No median, no spread.

WHAT THIS CAN AND CANNOT CONCLUDE. Two mechanisms move together in a naive 2x2: bytes fetched over
PCIe, and decoder work per element. The generator breaks that collinearity by replicating at two
cardinality levels where the dictionary's byte effect has OPPOSITE SIGN (lo: 8.00 -> 2.57 B/row;
hi: 8.00 -> 11.79 B/row). With 8 points this script fits

    t = floor + a*(B/row) + b*[snappy] + c*[dictionary] + d*[hi cardinality]

PRE-REGISTERED PREDICTION (written before the first run, kept here as written): "compression may
widen the gap mostly by HELPING the FPGA rather than by hurting the host; and dictionary may NARROW
the gap, because the hardware lookup path costs more than PLAIN's word copy."

OUTCOME (2026-08-09, 20M rows, build-29). Half right, and the dictionary half was WRONG:
  * compression widens the gap and BOTH arms contribute -- at PLAIN the FPGA got 4-8% FASTER (fewer
    bytes) while the CPU got 8-16% SLOWER (decompression). 1.12x -> 1.40x (lo), 2.10x -> 2.36x (hi).
  * dictionary WIDENS the gap in both directions, which the prediction got backwards. Where it
    shrinks the file 3.1x the FPGA gains 42.6% (1.12x -> 2.02x). Where it GROWS the file 47% the FPGA
    still gained 4.3% while the CPU lost 12.5% (2.10x -> 2.47x).
  * `passes` was 12.8 ms at all 8 points (spread 0.2-0.3%), so the control held and every bit of the
    variation is decode.

TWO THINGS THE FIT CANNOT TELL YOU, learned the hard way on that run:
  1. The dictionary coefficient is NOT a per-element price. The model is linear in bytes/ROW, but much
     of a dictionary file's volume is the dictionary PAGE, read once per row group (~160 of 236 MB at
     the hi level). Read the paired plain-vs-dict rows instead.
  2. The decoder is not a bytes/second pipe: corr(decode, MB) = +0.78 and wire throughput spans
     2.98-7.21 GB/s. The 236 MB dictionary file decoded FASTER than the 160 MB PLAIN one.

  cd ~/oasis && python3 bench/codec_sweep.py
  python3 bench/codec_sweep.py --levels lo            # one level only
  python3 bench/codec_sweep.py --no-fuse --csv bench/codec_sweep_nofuse.csv
"""
import argparse, csv as _csv, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import medians
import size_sweep as ss   # run_arm / mean_last / RUNS / AVG_LAST -- one protocol, no duplication

DSDIR = os.path.expanduser("~/datasets/codecsweep")


def read_manifest(dsdir):
    path = os.path.join(dsdir, "manifest.csv")
    if not os.path.exists(path):
        sys.exit(f"no manifest at {path} -- run bench/gen_codec_sweep.sh first")
    with open(path) as fh:
        return list(_csv.DictReader(fh))


def fit(rows, ykey):
    """Least squares  y = f0 + a*(B/row) + b*[snappy] + c*[dict] + d*[hi level].

    The LEVEL TERM IS NOT OPTIONAL. Cardinality is not the axis under test, but it is the CPU arm's
    dominant cost (GROUP BY builds a per-distinct-value table), and omitting it makes the model
    absorb a ~55 ms level difference into the byte slope. Measured on the 2026-08-09 run: dropping
    the term inflated rms from 2.31 -> 19.33 ms and the snappy coefficient from 9.12 -> 24.15 ms,
    i.e. it produced a confidently wrong answer. The FPGA arm is cardinality-blind so the term is
    ~0 there, which is itself worth reporting.

    Returns None if numpy is absent or the design is rank-deficient (one level alone re-collinearises
    encoding with byte volume)."""
    try:
        import numpy as np
    except ImportError:
        return None
    pts = [r for r in rows if r[ykey] == r[ykey]]
    if len(pts) < 5:
        return None
    levels = sorted({r["level"] for r in pts})
    hi = levels[-1] if len(levels) > 1 else None
    A = np.array([[1.0, r["bytes_per_row"], 1.0 if r["compression"] == "snappy" else 0.0,
                   1.0 if r["enc_intent"] == "dict" else 0.0,
                   1.0 if (hi and r["level"] == hi) else 0.0] for r in pts])
    y = np.array([r[ykey] for r in pts])
    if np.linalg.matrix_rank(A) < (5 if hi else 4):
        return None
    if not hi:
        A = A[:, :4]
    coef, *_ = np.linalg.lstsq(A, y, rcond=None)
    resid = y - A @ coef
    return dict(f0=coef[0], per_byte=coef[1], snappy=coef[2], dict=coef[3],
                level=coef[4] if hi else float("nan"),
                rms=float(np.sqrt((resid ** 2).mean())), n=len(pts))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsdir", default=DSDIR)
    ap.add_argument("--levels", nargs="+", default=["lo", "hi"])
    ap.add_argument("--arms", nargs="+", default=["fpga", "cpp"], choices=["fpga", "cpp", "sql"])
    ap.add_argument("--cpp-impl", choices=["groupby"], default="groupby")
    ap.add_argument("--outlier-every", type=int, default=1000)
    ap.add_argument("--threads", type=int, default=32)
    ap.add_argument("--fuse-min-rows", type=int, default=6_000_000)
    ap.add_argument("--no-fuse", action="store_true")
    ap.add_argument("--timeout", type=float, default=600.0)
    ap.add_argument("--csv")
    a = ap.parse_args()

    medians.CPP_FN = medians.CPP_IMPL[a.cpp_impl]
    man = [r for r in read_manifest(a.dsdir) if r["level"] in a.levels]
    if not man:
        sys.exit("manifest has no rows for the requested levels")
    fusing = not a.no_fuse

    print(f"COMPRESSION & ENCODING SENSITIVITY -- mean of last {ss.AVG_LAST} of {ss.RUNS} runs")
    print(f"arms={a.arms}  cpp={medians.CPP_FN}()  threads={a.threads}  "
          f"fusion={'policy (%s rows)' % f'{a.fuse_min_rows:,}' if fusing else 'OFF'}")
    print(f"datasets: {a.dsdir}")
    print("within a level all four files hold the SAME values -> `passes` must be constant\n")

    fmt = "{:>5} {:>9} {:>5} {:>12} {:>6} | {:>8} {:>8} {:>7} | {:>8} {:>7} | {:>7} {:>6}"
    print(fmt.format("level", "card", "enc", "compression", "B/row", "FPGA op", "CPU op", "ratio",
                     "F dec", "F pass", "dec GB/s", "flags"))
    print("-" * 122)

    out = []
    for r in man:
        path = r["file"]
        if not os.path.exists(path):
            print(f"  MISSING {path}", file=sys.stderr)
            continue
        rows = int(r["rows"])
        nbytes = int(r["bytes"])
        expect = rows // a.outlier_every

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
        # Decoder throughput in DECODED bytes: 8 B per int64 row, over the decode phase. This is the
        # number that is comparable across representations -- wire bytes are the independent variable.
        dec_gbs = (8.0 * rows) / (f_dec / 1000.0) / 1e9 if f_dec == f_dec and f_dec > 0 else nan
        wire_gbs = nbytes / (f_dec / 1000.0) / 1e9 if f_dec == f_dec and f_dec > 0 else nan

        bad = ""
        if f:
            fc = f["counts"][-ss.RUNS:]
            bad = "ok" if fc and all(x == expect for x in fc) else \
                  (f"MISMATCH{sorted(set(fc))}" if fc else "")

        engaged = f["pass1"] if f else "-"
        if fusing and f and "fused" not in engaged:
            bad = (bad + " !NOTFUSED").strip()

        print(fmt.format(r["level"], f"{int(r['card']):,}", r["enc_intent"], r["compression"],
                         f"{nbytes/rows:.2f}", f"{f_op:.1f}", f"{c_op:.1f}", f"{ratio:.2f}x",
                         f"{f_dec:.1f}", f"{f_pas:.1f}", f"{dec_gbs:.2f}", bad), flush=True)

        out.append(dict(level=r["level"], card=int(r["card"]), enc_intent=r["enc_intent"],
                        compression=r["compression"], encodings=r["encodings"], rows=rows,
                        bytes=nbytes, bytes_per_row=nbytes / rows,
                        fpga_op_ms=f_op, cpu_op_ms=c_op, speedup=ratio,
                        fpga_decode_ms=f_dec, fpga_passes_ms=f_pas,
                        decoded_gbs=dec_gbs, wire_gbs=wire_gbs,
                        fpga_cpu_seconds=ss.mean_last(f["user"]) if f else "",
                        cpu_cpu_seconds=ss.mean_last(cp["user"]) if cp else "",
                        pass1=f["pass1"] if f else "", flags_ok=bad))

    if not out:
        sys.exit("no points completed")

    print()
    print("=" * 122)

    # ---- INTERNAL CHECK: `passes` is FPGA work on identical values; representation cannot change it.
    for lv in sorted({r["level"] for r in out}):
        p = [r["fpga_passes_ms"] for r in out if r["level"] == lv and r["fpga_passes_ms"] == r["fpga_passes_ms"]]
        if len(p) > 1 and min(p) > 0:
            spread = (max(p) - min(p)) / min(p) * 100.0
            verdict = "FLAT (as required)" if spread < 10.0 else \
                      "NOT FLAT -- the four files are not doing identical statistics work; check the " \
                      "generator's digest gate before reading anything else here"
            print(f"INTERNAL CHECK  level {lv}: `passes` spread {spread:.1f}%  -> {verdict}")

    # ---- the decomposition this sweep exists for -------------------------------------------------
    for label, key in (("FPGA operator", "fpga_op_ms"), ("FPGA decode only", "fpga_decode_ms"),
                       ("CPU operator", "cpu_op_ms")):
        m = fit(out, key)
        if not m:
            print(f"\n{label}: fit unavailable (needs numpy and both cardinality levels -- one level "
                  f"alone re-collinearises encoding with byte volume)")
            continue
        print(f"\n{label}:  t = {m['f0']:.1f} ms  + {m['per_byte']:.2f}*(B/row) "
              f"{m['snappy']:+.2f}*[snappy] {m['dict']:+.2f}*[dictionary] "
              f"{m['level']:+.2f}*[hi card]     (rms {m['rms']:.2f} ms, n={m['n']})")
        print(f"    byte transport : {m['per_byte']:+.2f} ms per B/row")
        print(f"    snappy         : {m['snappy']:+.2f} ms once byte volume is accounted for "
              f"-> {'a real decompression cost' if m['snappy'] > 0.5 else 'essentially free'}")
        # NO verdict string on the dictionary coefficient. The model is linear in bytes/ROW, but a
        # large share of a dictionary file's bytes is the dictionary PAGE, read once per row group
        # rather than per row (~160 of 236 MB at the hi level). So this coefficient is NOT a clean
        # per-element price and a negative value is mis-specification, not a measured speedup.
        print(f"    dictionary     : {m['dict']:+.2f} ms -- NOT a per-element price; the byte-linear "
              f"model mis-handles dictionary-page bytes (per-group, not per-row). Read the paired "
              f"plain-vs-dict rows below instead.")
        print(f"    hi cardinality : {m['level']:+.2f} ms -- ~0 for the FPGA (cardinality-blind); "
              f"large for the CPU (GROUP BY). Omitting this term makes every other coefficient wrong.")

    # ---- speedup summary, which is the paper-facing number ---------------------------------------
    print("\nspeedup by representation:")
    for lv in sorted({r["level"] for r in out}):
        cells = {(r["enc_intent"], r["compression"]): r for r in out if r["level"] == lv}
        base = cells.get(("plain", "uncompressed"))
        for k in sorted(cells):
            r = cells[k]
            rel = f"  ({r['speedup']/base['speedup']:+.0%} vs PLAIN/uncompressed)" if base and base["speedup"] else ""
            print(f"    {lv}  {k[0]:>5}/{k[1]:<12} {r['bytes_per_row']:5.2f} B/row  "
                  f"{r['speedup']:5.2f}x{rel}")

    print("=" * 122)
    print("`passes` is the control (same values everywhere). `F dec` is the shared decoder -- the")
    print("component both the IQR and z-score operators sit behind, so this table is the one result")
    print("that transfers between them unchanged.")

    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = _csv.DictWriter(fh, fieldnames=list(out[0].keys()))
            w.writeheader()
            w.writerows(out)
        print(f"\ncsv: {a.csv}")


if __name__ == "__main__":
    main()
