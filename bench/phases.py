#!/usr/bin/env python3
"""
Full phase-by-phase breakdown of BOTH operators, every dataset, in one table.

Why this exists: medians.py reports `heavy` and end-to-end only, and the detailed phase numbers we
have (RESULTS.md 9.16) are sf10-only. A roadmap needs to know where the time goes on every dataset
and at every scale, on both sides, with the post-9.18 code (fair CPU allocator, consuming query).

Runs 1 warm-up + N timed iterations per (dataset, impl) in one DuckDB session and reports MEDIANS of:

  FPGA   fetch    host reads compressed bytes from the page cache
         submit   host builds+enqueues the decode flows
         wait     host blocked on the FPGA (the only phase that is genuinely "the card")
         copy     host memcpy of decoded values (0 on the streaming path)
         passes   BOTH IQR passes: the column crosses PCIe twice more
         heavy    operator total
  CPU    read     DuckDB parquet decode of the column (32 threads)
         quart    min/max + histogram narrowing -> Q1/Q3
         flags    fence compare into the packed bitmask
         heavy    operator total
  both   tax      end-to-end minus heavy (emit + aggregate + teardown)

and the derived numbers the roadmap actually turns on:
  ms/Mrow    scale behaviour -- FPGA is flat, CPU amortises its fixed startup (9.18)
  PCIe GB/s  bytes the FPGA moves over the bus / time, vs the CPU's DRAM bandwidth

  cd ~/oasis && python3 bench/phases.py           # N=7, all datasets
  python3 bench/phases.py -n 3 -d sf10 taxi_d4
"""
import argparse, os, re, statistics, subprocess, sys

DUCKDB = os.path.expanduser("~/oasis/extension/build/release/duckdb")
DSDIR  = os.path.expanduser("~/datasets")

DATASETS = [
    ("taxi_d1",  f"{DSDIR}/taxi_d1.parquet",            "fare_cents",  2_964_624),
    ("tpch_qty", f"{DSDIR}/tpch_qty.parquet",           "v",           6_001_215),
    ("taxi_d2",  f"{DSDIR}/taxi_d2.parquet",            "fare_cents",  5_972_150),
    ("extprice", f"{DSDIR}/tpch_extprice.parquet",      "v",           6_001_215),
    ("taxi_d3",  f"{DSDIR}/taxi_d3.parquet",            "fare_cents", 13_069_067),
    ("taxi_d4",  f"{DSDIR}/taxi_d4.parquet",            "fare_cents", 20_332_093),
    ("sf10",     f"{DSDIR}/tpch_extprice_sf10.parquet", "v",          59_986_052),
]

REAL = re.compile(r"Run Time \(s\): real ([\d.]+) user ([\d.]+) sys ([\d.]+)")
FDEC = re.compile(r"\[iqr\]\s+decode\s+([\d.]+) ms\s+\(fpga_wait ([\d.]+) \| fetch ([\d.]+) \| "
                  r"submit ([\d.]+) \| copy ([\d.]+)\)")
FIQR = re.compile(r"\[iqr\]\s+iqr\s+([\d.]+) ms\s+\(staging ([\d.]+) \| passes ([\d.]+)\)")
FHVY = re.compile(r"\[iqr\]\s+heavy\s+([\d.]+) ms")
CRD  = re.compile(r"\[iqr-cpu\]\s+read\s+([\d.]+) ms")
CQT  = re.compile(r"\[iqr-cpu\]\s+quart\s+([\d.]+) ms")
CFL  = re.compile(r"\[iqr-cpu\]\s+flags\s+([\d.]+) ms")
CHVY = re.compile(r"\[iqr-cpu\]\s+heavy\s+([\d.]+) ms")

def med(xs): return statistics.median(xs) if xs else float("nan")

def run(impl, path, col, n, threads):
    src  = f"iqr_flags_only('{path}','{col}')" if impl == "fpga" else f"iqr_cpu_flags('{path}','{col}')"
    # Consume, do not materialise: CREATE TABLE is 92 % DuckDB table-append (RESULTS.md 9.18).
    body = f"SELECT count(*) FILTER (WHERE is_outlier) FROM {src};"
    sql  = f"PRAGMA threads={threads};\n.timer on\n" + (body + "\n") * (n + 1)
    env  = dict(os.environ)
    env["OASIS_IQR_TIMING"] = "1"
    env["LD_LIBRARY_PATH"]  = os.path.expanduser("~/opt/lib") + ":" + env.get("LD_LIBRARY_PATH", "")
    p   = subprocess.run([DUCKDB], input=sql, capture_output=True, text=True, env=env)
    out = p.stdout + p.stderr
    g   = lambda rx, i=1: [float(m.group(i)) for m in rx.finditer(out)][1:]  # drop warm-up
    d   = {"real": [x * 1000 for x in g(REAL)], "user": g(REAL, 2)}
    if impl == "fpga":
        d.update(decode=g(FDEC, 1), wait=g(FDEC, 2), fetch=g(FDEC, 3), submit=g(FDEC, 4),
                 copy=g(FDEC, 5), passes=g(FIQR, 3), heavy=g(FHVY))
    else:
        d.update(read=g(CRD), quart=g(CQT), flags=g(CFL), heavy=g(CHVY))
    if not d["real"]:
        print(f"  !! {impl}: no timings\n{out[-500:]}", file=sys.stderr)
        return None
    return {k: med(v) for k, v in d.items()}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=7)
    ap.add_argument("-t", "--threads", type=int, default=32)
    ap.add_argument("-d", "--datasets", nargs="*", default=None)
    a = ap.parse_args()

    sel, res = [d for d in DATASETS if a.datasets is None or d[0] in a.datasets], {}
    for name, path, col, rows in sel:
        if not os.path.exists(path):
            print(f"skip {name}"); continue
        print(f"running {name} ...", flush=True)
        res[name] = (run("fpga", path, col, a.n, a.threads),
                     run("cpp",  path, col, a.n, a.threads),
                     os.path.getsize(path), rows)

    print(f"\n=== FPGA phases (ms, median of {a.n}) ===")
    print(f"{'dataset':<10}{'rows':>7} | {'fetch':>7}{'submit':>7}{'wait':>7}{'copy':>7}{'decode':>8} | "
          f"{'passes':>8} | {'heavy':>8}{'tax':>7}{'e2e':>8}")
    for name, _, _, rows in sel:
        if name not in res or not res[name][0]: continue
        f = res[name][0]
        print(f"{name:<10}{rows/1e6:>6.1f}M | {f['fetch']:>7.1f}{f['submit']:>7.1f}{f['wait']:>7.1f}"
              f"{f['copy']:>7.1f}{f['decode']:>8.1f} | {f['passes']:>8.1f} | "
              f"{f['heavy']:>8.1f}{f['real']-f['heavy']:>7.1f}{f['real']:>8.1f}")

    print(f"\n=== CPU phases (ms, median of {a.n}) ===")
    print(f"{'dataset':<10}{'rows':>7} | {'read':>8}{'quart':>8}{'flags':>8} | {'heavy':>8}{'tax':>7}{'e2e':>8}")
    for name, _, _, rows in sel:
        if name not in res or not res[name][1]: continue
        c = res[name][1]
        print(f"{name:<10}{rows/1e6:>6.1f}M | {c['read']:>8.1f}{c['quart']:>8.1f}{c['flags']:>8.1f} | "
              f"{c['heavy']:>8.1f}{c['real']-c['heavy']:>7.1f}{c['real']:>8.1f}")

    print(f"\n=== HEAD TO HEAD: matched phases (ms) and scale behaviour (ms per Mrow) ===")
    print(f"{'dataset':<10} | {'decode':>7}{'read':>7}{'  x':>6} | {'passes':>7}{'q+f':>7}{'  x':>6} | "
          f"{'F/Mrow':>7}{'C/Mrow':>7} | {'e2e x':>6}")
    for name, _, _, rows in sel:
        if name not in res or not res[name][0] or not res[name][1]: continue
        f, c = res[name][0], res[name][1]
        qf, m = c['quart'] + c['flags'], rows / 1e6
        print(f"{name:<10} | {f['decode']:>7.1f}{c['read']:>7.1f}{c['read']/f['decode']:>5.2f}x | "
              f"{f['passes']:>7.1f}{qf:>7.1f}{qf/f['passes']:>5.2f}x | "
              f"{f['heavy']/m:>7.2f}{c['heavy']/m:>7.2f} | {c['real']/f['real']:>5.2f}x")

    print(f"\n=== BUS: what the FPGA moves over PCIe vs what the CPU moves in DRAM ===")
    print(f"{'dataset':<10} | {'compr':>7}{'decod':>7}{'PCIe tot':>9} | {'dec GB/s':>9}{'pass GB/s':>10}"
          f"{'op GB/s':>9} | {'CPU GB/s':>9}")
    for name, _, _, rows in sel:
        if name not in res or not res[name][0] or not res[name][1]: continue
        f, c, size = res[name][0], res[name][1], res[name][2]
        comp, dec = size / 1e6, rows * 8 / 1e6                     # MB
        pcie = comp + dec + 2 * dec + rows / 8 / 1e6               # in, back out, 2 passes, flags
        print(f"{name:<10} | {comp:>7.0f}{dec:>7.0f}{pcie:>9.0f} | "
              f"{(comp+dec)/f['decode']:>9.2f}{2*dec/f['passes']:>10.2f}{pcie/f['heavy']:>9.2f} | "
              f"{dec/c['read']:>9.2f}")
    print("  MB and GB/s; 'CPU GB/s' is decoded bytes / read time = its DRAM-side decode rate.")

if __name__ == "__main__":
    main()
