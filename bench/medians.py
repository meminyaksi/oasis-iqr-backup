#!/usr/bin/env python3
"""
Repeated-run benchmark: FPGA vs C++ CPU vs SQL, medians over N warm runs.

For every (dataset, implementation) it runs 1 warm-up + N timed iterations in a single DuckDB
session, then reports the MEDIAN of:
  * real   -- end-to-end query wall time (.timer)
  * heavy  -- operator time only, i.e. everything before DuckDB emits a row
              (printed by OASIS_IQR_TIMING=1; the SQL baseline has no such phase)
and the spread (min-max), so it is visible whether a median is trustworthy.

  cd ~/oasis && python3 bench/medians.py            # N=7, all datasets
  python3 bench/medians.py -n 5 -d taxi_d4 sf10     # subset
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

def sql_baseline(path, col):
    return f"""(WITH s AS MATERIALIZED (SELECT {col}::BIGINT v FROM read_parquet('{path}')),
  ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
  etot AS (SELECT sum(c) t FROM ecnt),
  ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
  eq   AS (SELECT (SELECT min(v) FROM ecum,etot WHERE cc*4>=t)   q1,
                  (SELECT min(v) FROM ecum,etot WHERE cc*4>=3*t) q3),
  ef   AS (SELECT q1-((q3-q1)+((q3-q1)>>1)) lo, q3+((q3-q1)+((q3-q1)>>1)) hi FROM eq)
  SELECT (s.v < ef.lo OR s.v > ef.hi) AS is_outlier FROM s, ef)"""

def stmt(impl, path, col, consume=False):
    if impl == "fpga":
        src = f"iqr_flags_only('{path}','{col}')"
    elif impl == "cpp":
        src = f"iqr_cpu_flags('{path}','{col}')"
    else:
        src = sql_baseline(path, col) + " q"
    if consume:
        # AGGREGATE the flags instead of storing them. Measured on sf10 (2026-07-22): CREATE TABLE
        # costs 0.647 s of which 0.438 s is DuckDB's single-threaded table append -- 92 % of what we
        # had been calling the "emit tax" -- while actually producing the flags costs 38 ms. That
        # 438 ms is identical on both sides and drags every ratio toward 1.0, so it hides the very
        # difference this benchmark exists to measure. FILTER (not a bare count(*)) so the flag
        # column is genuinely read and cannot be projected away.
        return f"SELECT count(*) FILTER (WHERE is_outlier) FROM {src};"
    return f"CREATE OR REPLACE TABLE m AS SELECT is_outlier FROM {src};"

REAL  = re.compile(r"Run Time \(s\): real ([\d.]+) user ([\d.]+) sys ([\d.]+)")
HEAVY = re.compile(r"\[iqr(?:-cpu)?\]\s+heavy\s+([\d.]+) ms")

def run(impl, path, col, n, threads, consume=False):
    body = stmt(impl, path, col, consume)
    sql  = f"PRAGMA threads={threads};\n.timer on\n" + body * 1 + "\n" + (body + "\n") * n
    env  = dict(os.environ)
    env["OASIS_IQR_TIMING"] = "1"
    env["LD_LIBRARY_PATH"]  = os.path.expanduser("~/opt/lib") + ":" + env.get("LD_LIBRARY_PATH", "")
    p = subprocess.run([DUCKDB], input=sql, capture_output=True, text=True, env=env)
    out = p.stdout + p.stderr
    reals = [float(m.group(1)) for m in REAL.finditer(out)]
    users = [float(m.group(2)) for m in REAL.finditer(out)]
    heavy = [float(m.group(1)) for m in HEAVY.finditer(out)]
    if len(reals) < n + 1:
        print(f"    !! {impl}: expected {n+1} runs, got {len(reals)}", file=sys.stderr)
        if not reals:
            print(out[-800:], file=sys.stderr)
            return None
    return {"real": reals[1:], "user": users[1:], "heavy": heavy[1:] if heavy else []}

def med(xs):  return statistics.median(xs) if xs else float("nan")
def spread(xs): return (max(xs) - min(xs)) / statistics.median(xs) * 100 if xs else float("nan")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=7, help="timed iterations per cell (default 7)")
    ap.add_argument("-t", "--threads", type=int, default=32)
    ap.add_argument("-d", "--datasets", nargs="*", default=None)
    ap.add_argument("--consume", action="store_true",
                    help="aggregate the flags instead of CREATE TABLE (excludes DuckDB's "
                         "single-threaded 438 ms table append, which is identical on both sides)")
    a = ap.parse_args()

    sel = [d for d in DATASETS if a.datasets is None or d[0] in a.datasets]
    res = {}
    for name, path, col, rows in sel:
        if not os.path.exists(path):
            print(f"skip {name}: missing {path}"); continue
        print(f"running {name} ...", flush=True)
        res[name] = {i: run(i, path, col, a.n, a.threads, a.consume) for i in ("fpga", "cpp", "sql")}

    print(f"\n=== END-TO-END, median of {a.n} warm runs (s), spread = (max-min)/median ===")
    print(f"{'dataset':<10}{'rows':>8} | {'FPGA':>8}{'±%':>5} {'C++':>8}{'±%':>5} {'SQL':>8}{'±%':>5} | {'FPGA/C++':>9} {'C++/SQL':>8}")
    for name, path, col, rows in sel:
        if name not in res: continue
        r = res[name]
        f, c, s = med(r['fpga']['real']), med(r['cpp']['real']), med(r['sql']['real'])
        print(f"{name:<10}{rows/1e6:>7.1f}M | {f:>8.3f}{spread(r['fpga']['real']):>5.0f} "
              f"{c:>8.3f}{spread(r['cpp']['real']):>5.0f} {s:>8.3f}{spread(r['sql']['real']):>5.0f} | "
              f"{c/f:>8.2f}x {s/c:>7.2f}x")

    print(f"\n=== OPERATOR ONLY (heavy, ms) -- DuckDB emit tax excluded ===")
    print(f"{'dataset':<10} | {'FPGA op':>8}{'±%':>5} {'C++ op':>8}{'±%':>5} | {'FPGA/C++':>9} | {'tax F':>7}{'tax C':>7}{'tax%':>6}")
    for name, path, col, rows in sel:
        if name not in res: continue
        r = res[name]
        fh, ch = med(r['fpga']['heavy']), med(r['cpp']['heavy'])
        fr, cr = med(r['fpga']['real']) * 1000, med(r['cpp']['real']) * 1000
        print(f"{name:<10} | {fh:>8.1f}{spread(r['fpga']['heavy']):>5.0f} {ch:>8.1f}{spread(r['cpp']['heavy']):>5.0f} | "
              f"{ch/fh:>8.2f}x | {fr-fh:>7.1f}{cr-ch:>7.1f}{100*(fr-fh)/fr:>5.0f}%")

    print(f"\n=== CPU-SECONDS (user, median) ===")
    print(f"{'dataset':<10} | {'FPGA':>8}{'C++':>8}{'SQL':>9} | {'C++/FPGA':>9}{'SQL/FPGA':>9}")
    for name, path, col, rows in sel:
        if name not in res: continue
        r = res[name]
        f, c, s = med(r['fpga']['user']), med(r['cpp']['user']), med(r['sql']['user'])
        print(f"{name:<10} | {f:>8.3f}{c:>8.3f}{s:>9.3f} | {c/f:>8.2f}x{s/f:>8.2f}x")

if __name__ == "__main__":
    main()
