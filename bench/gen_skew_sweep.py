#!/usr/bin/env python3
"""
TEST 5 -- DISTRIBUTION-SHAPE (SKEW) SWEEP: generator.

THE QUESTION. Every synthetic dataset in this study so far is UNIFORM. The one residual the study has
never explained is that Test 1's size model over-predicts the dictionary-encoded REAL datasets by
1.29-2.54x, and taxi -- the tail-heavy one -- is the worst offender. Test 2 showed the FPGA gets
*faster* on low-byte data, so encoding runs the WRONG WAY to explain it. Two suspects remain:
tail-heavy DISTRIBUTION SHAPE and ragged row groups. This sweep isolates the first.

WHAT MOVES: the shape of the value distribution, from uniform (skewness ~0) to strongly right-skewed.
WHAT IS PINNED, and how:

  rows                 20,000,000 exactly            same i-range at every point
  cardinality          1,020,000 distinct EXACTLY    1,000,000 base levels + 20,000 planted. The
                                                     level map r = (i*PERM) % N is a bijection onto
                                                     0..N-1, folded mod CARD, so every level occurs
                                                     EXACTLY N/CARD = 20 times. Not hash() -- hash
                                                     leaves coupon-collector holes and the distinct
                                                     count would drift with the sweep.
  frequency profile    perfectly flat over levels    consequence of the above. So the skew lives
                                                     entirely in the value SPACING, i.e. this is a
                                                     genuine sample from a continuous right-skewed
                                                     law, quantised to CARD levels -- not a
                                                     frequency-imbalance artefact.
  bytes/row            EXACTLY 8.00 everywhere       PLAIN (DICTIONARY_SIZE_LIMIT 0) + UNCOMPRESSED.
                                                     Test 2's lesson: if bytes/row moves with the
                                                     swept variable you are measuring transport, not
                                                     the variable.
  row-group geometry   122880, 163 groups, %8 == 0   or the ragged guard rejects streaming and the
                                                     code path changes mid-sweep
  bins per IQR         ~579 at EVERY point           <-- THE NEW ONE. See below.

>>> THE CONFOUND THIS GENERATOR EXISTS TO KILL <<<

derive_window() (iqr_runner.cpp:107) sets the histogram window to [Q1-2*IQR, Q3+2*IQR] -- exactly
5*IQR wide -- and then rounds the bin width UP TO A POWER OF TWO (iqr_runner.cpp:130, because the
hardware shifts rather than divides):

    binw = 2^ceil(log2(ceil(5*IQR / 4096)))        bins_per_IQR = IQR / binw

Writing x = 5*IQR/4096, this is (4096/5) * x / 2^ceil(log2 x), and x/2^ceil(log2 x) lies in (0.5, 1].
So bins_per_IQR is NOT constant: it sawtooths over (409.6, 819.2] depending on where 5*IQR happens to
fall relative to a power of two. Skew changes the IQR continuously, so a naive skew sweep would walk
straight through those octave boundaries and produce a 2x accuracy sawtooth that has NOTHING to do
with distribution shape. Same class of bug as the first two cardinality generators (Test 2 v1/v2).

FIX: every point is scaled by an integer multiplier M chosen so bins_per_IQR lands on ~579 for that
point's own IQR. Multiplying all values by an integer is shape-preserving -- skewness is
scale-invariant, cardinality is preserved (the map is injective), and bytes/row is 8.00 regardless.
579 is the GEOMETRIC MIDDLE of (409.6, 819.2], deliberately NOT the top of the range: at 819.2 the
quantity 5*IQR/4096 is exactly a power of two, so half of all perturbations tip it into the next
octave and HALVE the resolution to ~410. That matters because the fused path derives its window from
a few thousand stride-samples, and the sampling error in Q3 GROWS with skew (the density at Q3
falls) -- i.e. the very axis being swept is what would push a cliff-edge point over. The middle is
the only choice robust to that.

VALUE CONSTRUCTION

    level = ((i * PERM) % N) % CARD                         PERM=2654435761, gcd(PERM, 2e7)=1
    u     = (level + 1) / CARD                              in (0, 1]
    w(u)  = u                             if a == 0         (uniform)
          = (exp(a*u) - 1) / (exp(a) - 1)  otherwise        (log-uniform-ish, right-skewed)
    V     = level + round(STRETCH * w(u))                   STRICTLY INCREASING in level  =>
                                                            injective => cardinality is EXACTLY CARD
    r     = (i * PERM) % N                                  bijection on 0..N-1
    value = M * V(r % CARD) + (r % 50 == 0 AND r < CARD ? OFFSET : 0)

The outlier predicate is on r, NOT on i. `i % 1000 == 0` looks equivalent and is not: N = 1000 *
20,000, so for such i the product (i*PERM) mod N is itself a multiple of 1000 and folding mod CARD
leaves only multiples of 1000 -- it selects 1,000 WHOLE LEVELS (all 20 rows each), which then vanish
from the base. `r % 50 == 0 AND r < CARD` instead takes ONE row from each of 20,000 levels spaced 50
apart, so the base keeps all 1,000,000 levels and the file holds exactly 1,020,000 distinct values.

The `+ level` term is what guarantees injectivity: V(j+1) - V(j) = 1 + (non-negative) >= 1. Without
it, round() collapses thousands of low levels onto 0 at high `a` and the cardinality control dies.

`a` is the skew dial: a=0 is exactly uniform, a=20 is strongly right-skewed. The reported x-axis is
the MEASURED Fisher skewness, not `a` -- `a` is a knob, skewness is the physical quantity.

THE SELF-CHECK, AND WHERE IT NECESSARILY WEAKENS

Planted outliers (0.1% at +OFFSET, five times the maximum value) are far outside the fence with
nothing in between, so they are quantisation-proof and contribute exactly N/OUTLIER_EVERY flags at
every point -- the same gate as Tests 1/3/4.

But a right-skewed distribution's OWN upper tail eventually crosses fence_hi = Q3 + 1.5*IQR. That is
not a flaw, it is a property of IQR on heavy tails and it is half of what this test is for. So the
generator computes, per point and EXACTLY (same discrete-quantile rule as the SQL baseline):

    q1, q3, fence_lo, fence_hi, natural_outliers, expected_total = natural + planted

and labels each point:
    EXACT  -- natural == 0, so expected_total is analytic and the strong gate applies
    MIXED  -- the tail self-flags; the gate becomes FPGA == expected_total, and any deviation is a
              QUANTISATION measurement (the taxi_d3=104 phenomenon), which is the accuracy result.

  python3 bench/gen_skew_sweep.py --dry-run     # plan only: no files written, ~1 min
  python3 bench/gen_skew_sweep.py               # ~960 MB, 6 files
  python3 bench/gen_skew_sweep.py verify        # re-print manifest + gates
"""
import argparse, csv, math, os, subprocess, sys

DB   = os.environ.get("DB", os.path.expanduser("~/oasis/extension/build/release/duckdb"))
DS   = os.environ.get("DS", os.path.expanduser("~/datasets/skewsweep"))

N              = 20_000_000
CARD           = 1_000_000
PERM           = 2654435761          # odd, not divisible by 5 => gcd(PERM, 2e7) = 1 => bijection
STRETCH        = 9_000_000
OUTLIER_EVERY  = 1000                # 0.1% => 20,000 planted flags
RGS            = 122880              # multiple of 8
NUM_BINS       = 4096                # must match IQR_HW_NUM_BINS / iqr_runner.hpp
TARGET_BPI     = 579.0               # geometric middle of (409.6, 819.2] -- see module docstring
A_VALUES       = [0, 4, 8, 12, 16, 20]

MANIFEST = os.path.join(DS, "manifest.csv")


# Generation is PURE SQL -- it never touches the FPGA -- so it deliberately uses the stock python
# duckdb module rather than the extension-linked binary. That binary aborts at startup on any node
# without 1 GiB huge pages ("The FPGA support requires 1GiB huge pages"), which would force dataset
# generation onto an alveo node for no reason. The module is 1.5.4, the same version the codec sweep
# was characterised against, so the parquet WRITER behaviour (and therefore the encoding gates) is
# identical.
_CON = None


def duck(sql):
    global _CON
    if _CON is None:
        import duckdb as _d
        _CON = _d.connect()
    try:
        rows = _CON.execute(sql).fetchall()
    except Exception as e:
        sys.exit(f"duckdb failed:\n{sql[:400]}\n---\n{e}")
    if not rows:
        return ""
    return "\n".join(",".join("" if c is None else str(c) for c in r) for r in rows)


def w_expr(a):
    """The skew warp, as SQL. a == 0 is exactly linear (uniform), no exp() rounding involved."""
    return "u" if a == 0 else f"(exp({a}.0 * u) - 1.0) / (exp({a}.0) - 1.0)"


def level_value_cte(a, mult=1):
    """CTE producing one row per LEVEL (not per row of the dataset) -- 1e6 rows, cheap. Used to pick
    the multiplier and to compute the exact quantiles before writing 160 MB."""
    return f"""
    WITH lv AS (
      SELECT j, (j + 1) / {CARD}.0 AS u FROM range({CARD}) t(j)
    ), v AS (
      SELECT (j + round({STRETCH}.0 * ({w_expr(a)}))::BIGINT) * {mult} AS val FROM lv
    )"""


def bins_per_iqr(iqr):
    """Mirror of derive_window(): window is 5*IQR wide, bin width rounded UP to a power of two."""
    if iqr <= 0:
        return float("nan"), 0
    width = (5 * iqr + NUM_BINS - 1) // NUM_BINS
    shift = max(0, (width - 1).bit_length())
    binw  = 1 << shift
    return iqr / binw, binw


def pick_multiplier(iqr0):
    """Smallest integer M making bins_per_IQR land closest to TARGET_BPI.

    bins_per_IQR(M) is self-similar under M -> 2M (the width doubles, the shift increments), so one
    octave of M covers the whole achievable range and a small search suffices."""
    best, best_err = 1, float("inf")
    for m in range(1, 4097):
        bpi, _ = bins_per_iqr(iqr0 * m)
        err = abs(math.log(bpi / TARGET_BPI))
        if err < best_err - 1e-12:
            best, best_err = m, err
    return best


def plan_point(a):
    """Everything computable WITHOUT writing the file: quartiles, fence, multiplier, tail crossing."""
    # Exact discrete quantiles over the LEVEL values. Frequencies are flat by construction (every
    # level occurs exactly N/CARD times), so the quantile of the dataset equals the quantile of the
    # level set -- which is 1e6 rows instead of 20e6. Same discrete rule the SQL baseline uses.
    row = duck(f"""{level_value_cte(a)}
        SELECT quantile_disc(val, 0.25)::BIGINT || ',' ||
               quantile_disc(val, 0.75)::BIGINT || ',' ||
               max(val)::BIGINT || ',' || min(val)::BIGINT || ',' ||
               count(DISTINCT val)::BIGINT
        FROM v;""")
    q1, q3, vmax, vmin, ndist = (int(x) for x in row.split(","))
    iqr0 = q3 - q1
    if ndist != CARD:
        sys.exit(f"a={a}: level map is NOT injective ({ndist} != {CARD}) -- cardinality control lost")

    mult = pick_multiplier(iqr0)
    q1, q3, vmax, vmin = q1 * mult, q3 * mult, vmax * mult, vmin * mult
    iqr = q3 - q1
    bpi, binw = bins_per_iqr(iqr)
    fence_lo = q1 - (iqr + (iqr >> 1))          # Q1 - 1.5*IQR, integer, as the operator computes it
    fence_hi = q3 + (iqr + (iqr >> 1))
    offset = 5 * vmax                            # planted outliers: 5x the maximum, empty gap below

    return dict(a=a, mult=mult, q1=q1, q3=q3, iqr=iqr, binw=binw, bins_per_iqr=bpi,
                fence_lo=fence_lo, fence_hi=fence_hi, vmin=vmin, vmax=vmax, offset=offset,
                tail_crosses=vmax > fence_hi)


def measure_point(p, path):
    """Facts that need the written file: the AUTHORITATIVE fence, the exact expected flag count,
    the shape statistics and the footer geometry.

    The quartiles here are recomputed FROM THE FILE using the SQL baseline's own discrete-quantile
    rule (min v such that 4*cumcount >= total), not from the level set that plan_point() used. Two
    reasons the level-set answer is not good enough to gate on:
      * the planted outliers move 0.1% of the rows out of the body, which shifts every empirical
        rank slightly -- small, but this number is the correctness gate, so it must be exact;
      * it must be THE SAME RULE the CPU baseline applies, or a disagreement between the generator's
        expectation and the operator would be a definition mismatch masquerading as a bug.
    """
    fence = duck(f"""
        WITH s    AS (SELECT v FROM read_parquet('{path}')),
             ecnt AS (SELECT v, count(*) c FROM s GROUP BY v),
             etot AS (SELECT sum(c) t FROM ecnt),
             ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt),
             eq   AS (SELECT (SELECT min(v) FROM ecum, etot WHERE cc * 4 >= t)     q1,
                             (SELECT min(v) FROM ecum, etot WHERE cc * 4 >= 3 * t) q3),
             ef   AS (SELECT q1 - ((q3 - q1) + ((q3 - q1) >> 1)) lo,
                             q3 + ((q3 - q1) + ((q3 - q1) >> 1)) hi FROM eq)
        SELECT eq.q1, eq.q3, ef.lo, ef.hi,
               (SELECT count(*) FROM s, ef WHERE s.v < ef.lo OR s.v > ef.hi),
               (SELECT count(*) FROM s, ef
                WHERE (s.v < ef.lo OR s.v > ef.hi) AND s.v < {p['offset']})
        FROM eq, ef;""")
    q1, q3, flo, fhi, total_flagged, natural = (int(x) for x in fence.split(","))

    # `skewness` is the SWEPT AXIS, so it must describe the BASE distribution: the planted outliers
    # are a constant 0.1% spike common to every point, and skewness is not robust -- including them
    # reports 3.50 for the a=0 point, which is exactly uniform. So the axis excludes them and
    # skewness_all is kept alongside for transparency.
    # count(DISTINCT) is EXACT, not approx_count_distinct: cardinality is a CONTROL here, and HLL's
    # error on ~1e6 distinct scattered over +-12%, which fired the gate on clean data.
    stats = duck(f"""
        SELECT round(skewness(v) FILTER (WHERE v < {p['offset']}), 4),
               round(kurtosis(v) FILTER (WHERE v < {p['offset']}), 4),
               round(avg(v) FILTER (WHERE v < {p['offset']})
                     / nullif(median(v) FILTER (WHERE v < {p['offset']}), 0), 4),
               count(DISTINCT v),
               round(skewness(v), 4),
               (SELECT count(*)            FROM parquet_metadata('{path}')),
               (SELECT min(num_values)     FROM parquet_metadata('{path}')),
               (SELECT min(num_values) % 8 FROM parquet_metadata('{path}')),
               (SELECT string_agg(DISTINCT encodings, '+') FROM parquet_metadata('{path}')),
               (SELECT count(*) FROM read_parquet('{path}'))
        FROM read_parquet('{path}');""")
    skew, kurt, mean_med, distinct, skew_all, groups, min_grp, mod8, encs, rows = stats.split(",")

    iqr = q3 - q1
    bpi, binw = bins_per_iqr(iqr)
    return dict(skewness=float(skew), kurtosis=float(kurt), mean_over_median=float(mean_med),
                skewness_all=float(skew_all),
                distinct=int(distinct), groups=int(groups), min_group=int(min_grp),
                min_group_mod8=int(mod8), encodings=encs, rows=int(rows),
                q1=q1, q3=q3, iqr=iqr, binw=binw, bins_per_iqr=bpi,
                fence_lo=flo, fence_hi=fhi,
                natural_outliers=natural, planted_outliers=N // OUTLIER_EVERY,
                expected_total=total_flagged)


def write_file(p, path):
    a, mult, off = p["a"], p["mult"], p["offset"]
    tmp = path + ".partial"
    if os.path.exists(tmp):
        os.remove(tmp)
    # OUTLIER SELECTION -- do NOT use `i % OUTLIER_EVERY = 0`. N = 20,000,000 = 1000 * 20,000, so for
    # i a multiple of 1000 the product (i*PERM) mod N is itself a multiple of 1000, and folding mod
    # CARD leaves ONLY multiples of 1000. That selects 1,000 WHOLE LEVELS (20 rows each) instead of
    # 20,000 scattered rows: those levels then disappear from the base entirely, and the arithmetic
    # structure is exactly the low-bit-pattern trap that invalidated the Test 2 v1 generator.
    # Instead select on the permuted index r: `r % 50 = 0 AND r < CARD` picks exactly 20,000 rows
    # lying on 20,000 DISTINCT levels spaced 50 apart across the whole level range, taking one of
    # each level's 20 rows. Base cardinality stays 1,000,000; total becomes exactly 1,020,000.
    stride = CARD // (N // OUTLIER_EVERY)        # 1e6 / 20000 = 50
    sql = f"""
      COPY (
        SELECT ((lvl + round({STRETCH}.0 * ({w_expr(a)}))::BIGINT) * {mult})
               + CASE WHEN r % {stride} = 0 AND r < {CARD} THEN {off} ELSE 0 END AS v
        FROM (
          SELECT r, r % {CARD} AS lvl, ((r % {CARD}) + 1) / {CARD}.0 AS u
          FROM (SELECT (i * {PERM}) % {N} AS r FROM range({N}) t(i))
        )
      ) TO '{tmp}' (FORMAT PARQUET, ROW_GROUP_SIZE {RGS},
                    DICTIONARY_SIZE_LIMIT 0, COMPRESSION UNCOMPRESSED);"""
    duck(sql)
    os.replace(tmp, path)


FIELDS = ["a", "file", "rows", "mult", "skewness", "skewness_all", "kurtosis",
          "mean_over_median", "distinct",
          "bytes", "bytes_per_row", "encodings", "groups", "min_group", "min_group_mod8",
          "q1", "q3", "iqr", "binw", "bins_per_iqr", "fence_lo", "fence_hi", "vmin", "vmax",
          "offset", "tail_crosses", "natural_outliers", "planted_outliers", "expected_total",
          "gate"]


def gates(rows):
    ok = True
    def bad(m):
        nonlocal ok
        ok = False
        print(f"  FAIL  {m}")

    for r in rows:
        n = os.path.basename(r["file"])
        if int(r["rows"]) != N:
            bad(f"{n}: rows={r['rows']} != {N}")
        if abs(float(r["bytes_per_row"]) - 8.0) > 0.01:
            bad(f"{n}: bytes/row={r['bytes_per_row']} != 8.00 -- byte volume is NOT pinned")
        if "DICTIONARY" in (r["encodings"] or "").upper():
            bad(f"{n}: encodings={r['encodings']} -- PLAIN was not forced")
        if int(r["min_group_mod8"]) != 0:
            bad(f"{n}: min_group%8={r['min_group_mod8']} -- streaming would be rejected")
        # EXACT count. The level map is injective (asserted in plan_point), so the file holds
        # exactly CARD base values plus one per planted outlier that did not collide mod CARD --
        # ~20k more. Anything outside this band means the value construction lost injectivity.
        if int(r["distinct"]) != CARD + N // OUTLIER_EVERY:
            bad(f"{n}: distinct={r['distinct']} != {CARD + N // OUTLIER_EVERY} "
                f"({CARD} base + {N // OUTLIER_EVERY} planted) -- cardinality is not pinned, or the "
                f"outlier selection is landing on whole levels instead of scattered rows")

    bpis = [float(r["bins_per_iqr"]) for r in rows]
    if bpis:
        spread = (max(bpis) - min(bpis)) / min(bpis) * 100.0
        if spread > 15.0:
            bad(f"bins_per_IQR spread {spread:.1f}% across the sweep -- the power-of-two bin-width "
                f"confound is NOT controlled; accuracy differences would be unattributable")
        else:
            print(f"  bins_per_IQR {min(bpis):.0f}..{max(bpis):.0f} (spread {spread:.1f}%) -- "
                  f"quantisation resolution is held constant across the sweep")

    skews = [float(r["skewness"]) for r in rows]
    if skews and max(skews) - min(skews) < 1.0:
        bad(f"skewness only spans {min(skews):.2f}..{max(skews):.2f} -- the axis barely moves")
    elif skews:
        print(f"  skewness {min(skews):.2f} .. {max(skews):.2f} -- the swept axis")

    nexact = sum(1 for r in rows if r["gate"] == "EXACT")
    print(f"  {nexact}/{len(rows)} points keep the analytic gate (tail does not self-flag); "
          f"{len(rows)-nexact} are MIXED (accuracy measurement)")
    print("  ALL GATES PASS" if ok else "  >>> GATES FAILED -- do not run the benchmark <<<")
    return ok


def print_table(rows):
    cols = ["a", "skewness", "kurtosis", "mult", "bins_per_iqr", "bytes_per_row", "distinct",
            "min_group_mod8", "fence_hi", "vmax", "natural_outliers", "expected_total", "gate"]
    w = {c: max(len(c), max((len(str(r.get(c, ""))) for r in rows), default=0)) for c in cols}
    print("  " + "  ".join(c.rjust(w[c]) for c in cols))
    for r in rows:
        print("  " + "  ".join(str(r.get(c, "")).rjust(w[c]) for c in cols))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", nargs="?", choices=["generate", "verify"], default="generate")
    ap.add_argument("--dry-run", action="store_true",
                    help="compute and print the plan (quartiles, multipliers, fences, whether the "
                         "tail self-flags) WITHOUT writing any parquet")
    ap.add_argument("--a", nargs="+", type=int, default=A_VALUES)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    os.makedirs(DS, exist_ok=True)
    if not os.access(DB, os.X_OK):
        sys.exit(f"duckdb not found/executable: {DB}")

    if args.mode == "verify":
        if not os.path.exists(MANIFEST):
            sys.exit(f"no manifest at {MANIFEST}")
        rows = list(csv.DictReader(open(MANIFEST)))
        print(f"=== skew-sweep manifest ({DS}) ===")
        print_table(rows)
        print("\nGATES:")
        sys.exit(0 if gates(rows) else 1)

    print(f"=== TEST 5: distribution-shape (skew) sweep -> {DS} ===")
    print(f"    N={N:,} (FIXED)  CARD={CARD:,} distinct EXACTLY  freq flat ({N//CARD} rows/level)")
    print(f"    PLAIN + UNCOMPRESSED => bytes/row pinned at 8.00   ROW_GROUP_SIZE={RGS}")
    print(f"    outliers 1/{OUTLIER_EVERY} planted at 5x max value (empty gap)")
    print(f"    bins_per_IQR normalised to ~{TARGET_BPI:.0f} at every point via an integer "
          f"multiplier\n")

    print("--- planning (no files written yet) ---", flush=True)
    plans = []
    for a in args.a:
        p = plan_point(a)
        plans.append(p)
        print(f"  a={a:<3} mult={p['mult']:<6} Q1={p['q1']:<14,} Q3={p['q3']:<14,} "
              f"IQR={p['iqr']:<14,} binw={p['binw']:<10,} bins/IQR={p['bins_per_iqr']:7.1f}  "
              f"fence_hi={p['fence_hi']:<15,} max={p['vmax']:<15,} "
              f"{'TAIL CROSSES -> MIXED' if p['tail_crosses'] else 'exact gate'}", flush=True)

    if args.dry_run:
        print("\n--dry-run: stopping before any file is written.")
        return

    print("\n--- writing ---", flush=True)
    rows = []
    for p in plans:
        path = os.path.join(DS, f"skew_a{p['a']:02d}.parquet")
        if os.path.exists(path) and not args.force:
            print(f"  {os.path.basename(path)} exists (--force to regenerate) -- skipping",
                  flush=True)
        else:
            print(f"  writing {os.path.basename(path)} (a={p['a']}, mult={p['mult']}) ...",
                  flush=True)
            write_file(p, path)

        m = measure_point(p, path)
        nbytes = os.path.getsize(path)
        rows.append(dict(a=p["a"], file=path, rows=m["rows"], mult=p["mult"],
                         skewness=m["skewness"], skewness_all=m["skewness_all"],
                         kurtosis=m["kurtosis"],
                         mean_over_median=m["mean_over_median"], distinct=m["distinct"],
                         bytes=nbytes, bytes_per_row=round(nbytes / N, 2),
                         encodings=m["encodings"], groups=m["groups"], min_group=m["min_group"],
                         min_group_mod8=m["min_group_mod8"],
                         q1=m["q1"], q3=m["q3"], iqr=m["iqr"], binw=m["binw"],
                         bins_per_iqr=round(m["bins_per_iqr"], 1),
                         fence_lo=m["fence_lo"], fence_hi=m["fence_hi"],
                         vmin=p["vmin"], vmax=p["vmax"], offset=p["offset"],
                         tail_crosses=m["natural_outliers"] > 0,
                         natural_outliers=m["natural_outliers"],
                         planted_outliers=m["planted_outliers"],
                         expected_total=m["expected_total"],
                         gate="MIXED" if m["natural_outliers"] else "EXACT"))

    with open(MANIFEST, "w", newline="") as fh:
        wr = csv.DictWriter(fh, fieldnames=FIELDS)
        wr.writeheader()
        wr.writerows(rows)

    print("\n=== manifest ===")
    print_table([{k: str(v) for k, v in r.items()} for r in rows])
    print("\nGATES:")
    ok = gates([{k: str(v) for k, v in r.items()} for r in rows])
    print(f"\nmanifest: {MANIFEST}")
    print(f"next: python3 bench/skew_sweep.py --csv bench/skew_sweep.csv")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
