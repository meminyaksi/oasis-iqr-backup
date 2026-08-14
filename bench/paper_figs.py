#!/usr/bin/env python3
"""
Paper figures for the Experimental Evaluation section (microbenchmarks, Tests 1/3/4).

Emits, into --outdir:
    fig_micro.pdf     3 panels, FULL TEXT WIDTH  -> \\begin{figure*}
    fig_decomp.pdf    1 panel,  SINGLE COLUMN    -> \\begin{figure}
    tab_datasets.tex  synthetic datasets table
    tab_codec.tex     representation matrix table
  (+ .png twins for eyeballing before committing to LaTeX)

Data is EMBEDDED, not read from CSV, so the figures are reproducible from this file alone
after the datasets are gone. Provenance for every number:
    Test 1 -> micro_bench.md "Test 1", bench/size_sweep.csv + size_sweep_fused.csv
    Test 3 -> micro_bench.md "Test 3", bench/thread_sweep_balanced.csv
    Test 4 -> micro_bench.md "Test 4", bench/codec_sweep.csv

COLOR. Two categorical hues only, assigned by ENTITY and never cycled: CPU=blue, FPGA=orange.
Validated (Machado-2009 CVD sim, OKLab dE x100, white paper surface):
    blue/orange  protan 24.7  deutan 31.7  normal 33.6   (gates: >=8 CVD, >=15 normal)
    contrast     4.42:1 and 3.20:1         (gate >=3)
    grayscale Y  0.188 vs 0.278            -> survives B&W printing
A third hue was rejected: aqua #1baf7a is 2.82:1 on white and its gray value (0.323) sits too
close to orange's. The two FPGA configurations (value path vs fused) therefore share the FPGA
hue and are separated by linestyle+marker -- color follows the entity, not the configuration.
The phase decomposition uses an ORDINAL ramp in the FPGA hue (dL 0.164/0.129 >= 0.06 required,
lightest step 2.13:1 >= 2.0 required, gray values 0.100/0.247/0.443).

  python3 bench/paper_figs.py --outdir ~/oasis/paper/figs
"""
import argparse, os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

# ── palette (see module docstring for the validation) ────────────────────────────────────────
CPU, FPGA = "#2a78d6", "#eb6834"
RAMP = ["#a33100", "#e2602b", "#f99977"]      # decode / passes / other -- dark to light
INK, MUTED, GRID = "#0b0b0b", "#52514e", "#d8d7d2"

# ACM acmart sigconf: \columnwidth = 241.14pt = 3.33in, \textwidth = 506pt = 7.00in
COL, TEXT = 3.33, 7.00

# ── data ─────────────────────────────────────────────────────────────────────────────────────
# Test 1 -- size sweep. Operator ms. The two FPGA curves are separate sessions; the CPU series
# plotted is the one measured ALONGSIDE the fused run, so CPU-vs-FPGA(fused) is same-session.
T1_ROWS   = [1, 3, 6, 10, 20, 40, 60, 80, 100]                       # millions
T1_CPU    = [46.8, 48.0, 85.5, 97.4, 124.0, 225.9, 304.8, 391.5, 447.2]
T1_FUSED  = [11.6, 17.7, 23.8, 31.6, 53.4, 97.3, 142.4, 184.7, 229.7]
T1_VALUE  = [7.7, 14.0, 23.7, 36.5, 70.8, 135.1, 204.2, 270.1, 337.3]
T1_XOVER  = 6      # measured fusion crossover, Mrows

# Test 3 -- host-core sweep on the 20M/4.9%-distinct point. Operator ms.
T3_THREADS = [1, 2, 4, 8, 16, 32]
T3_CPU     = [745.4, 385.1, 244.4, 190.9, 157.3, 129.5]
T3_FPGA    = [54.8, 54.9, 53.3, 53.9, 54.4, 53.8]
T3_FLOOR   = 103.9                       # Amdahl serial floor, least-squares over all 6 points
T3_CPUSEC  = [0.631, 0.619, 0.647, 0.686, 0.758, 1.133]
T3_FPGASEC = [0.053, 0.075, 0.068, 0.077, 0.083, 0.105]

# Test 4 -- representation matrix, 20M rows, identical values within a level.
# NOTE the column meanings: `decode` = decode WITH fused pass 1 under it; `passes` = pass 2
# ONLY (transport-bound). They are disjoint spans on one steady_clock and sum to `heavy`
# minus window+staging+copy (33.8+12.8=46.6 vs 53.8 -> 7.2 remainder at the 20M point).
T4 = [   # label,          B/row,  FPGA,  CPU,   decode, passes
    ("PLAIN\nraw",          8.00,  55.6,  62.1,  35.3, 12.8),
    ("PLAIN\nSnappy",       4.71,  51.4,  72.1,  31.6, 12.8),
    ("dict\nraw",           2.55,  31.9,  64.5,  14.2, 12.8),
    ("dict\nSnappy",        2.32,  31.6,  67.8,  14.0, 12.8),
    ("PLAIN\nraw",          8.00,  55.4, 116.5,  35.4, 12.8),
    ("PLAIN\nSnappy",       5.21,  53.3, 125.7,  32.7, 12.8),
    ("dict\nraw",          11.79,  53.0, 131.1,  32.7, 12.8),
    ("dict\nSnappy",        9.16,  57.4, 133.6,  37.0, 12.8),
]
T4_SPLIT = 4        # first 4 rows are the lo level, last 4 the hi level


def style():
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["DejaVu Serif"],
        "font.size": 7, "axes.labelsize": 7, "axes.titlesize": 7.5,
        "xtick.labelsize": 6.5, "ytick.labelsize": 6.5, "legend.fontsize": 6.5,
        "axes.edgecolor": MUTED, "axes.labelcolor": INK,
        "text.color": INK, "xtick.color": MUTED, "ytick.color": MUTED,
        "axes.linewidth": 0.6, "xtick.major.width": 0.6, "ytick.major.width": 0.6,
        "lines.linewidth": 1.4, "lines.markersize": 4,
        "grid.color": GRID, "grid.linewidth": 0.5,
        "legend.frameon": False, "figure.dpi": 200, "savefig.bbox": "tight",
        "savefig.pad_inches": 0.01, "pdf.fonttype": 42,
    })


def recede(ax, axis="y"):
    ax.grid(True, axis=axis, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)


def panel_scale(ax):
    ax.plot(T1_ROWS, T1_CPU, "-o", color=CPU, label="CPU (32 cores)", zorder=3)
    ax.plot(T1_ROWS, T1_FUSED, "-s", color=FPGA, label="FPGA, fused", zorder=3)
    ax.plot(T1_ROWS, T1_VALUE, "--^", color=FPGA, lw=1.0, ms=3.2,
            markerfacecolor="white", markeredgewidth=0.9, label="FPGA, two-pass", zorder=3)
    ax.set_xscale("log"); ax.set_yscale("log")
    ax.set_xlabel("rows (millions)"); ax.set_ylabel("operator time (ms)")
    ax.set_title("(a) Scale", loc="left", fontweight="bold")
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax.set_xticks([1, 3, 10, 30, 100]); ax.set_yticks([10, 30, 100, 300])
    # One direct label, at the endpoint that carries the claim. Placed BELOW-RIGHT of the fused
    # endpoint so it cannot collide with the CPU marker above it.
    ax.set_xlim(0.8, 175)
    ax.annotate(f"{T1_CPU[-1]/T1_FUSED[-1]:.1f}×", xy=(100, T1_FUSED[-1]), xytext=(5, -1),
                textcoords="offset points", ha="left", va="center", fontsize=6.5, color=INK)
    ax.axvline(T1_XOVER, color=MUTED, lw=0.5, ls=":", zorder=1)
    ax.annotate("fusion\ncrossover", xy=(T1_XOVER, 12), xytext=(1.5, 0),
                textcoords="offset points", fontsize=5.8, color=MUTED, va="bottom")
    recede(ax); ax.legend(loc="upper left", handlelength=1.6)


def panel_cores(ax):
    ax.plot(T3_THREADS, T3_CPU, "-o", color=CPU, label="CPU baseline", zorder=3)
    ax.plot(T3_THREADS, T3_FPGA, "-s", color=FPGA, label="FPGA (ours)", zorder=3)
    ax.axhline(T3_FLOOR, color=MUTED, lw=0.8, ls="--", zorder=2)
    ax.annotate("CPU serial floor (Amdahl)", xy=(1.15, T3_FLOOR), xytext=(0, 3),
                textcoords="offset points", fontsize=5.8, color=MUTED)
    ax.set_xscale("log", base=2); ax.set_yscale("log")
    ax.set_xticks(T3_THREADS)
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax.set_yticks([50, 100, 200, 400, 800])
    ax.set_xlabel("host cores")
    ax.set_ylabel("operator time (ms)")
    ax.set_title("(b) Host cores", loc="left", fontweight="bold")
    ax.annotate(f"{T3_CPU[-1]/T3_FPGA[0]:.2f}× at 32 cores\nvs FPGA on 1", xy=(32, 129.5),
                xytext=(-4, 17), textcoords="offset points", ha="right",
                fontsize=6, color=INK)
    recede(ax); ax.legend(loc="lower left", handlelength=1.6)


def panel_repr(ax):
    """HORIZONTAL bars. Eight two-word category labels do not fit on a shared x-axis at
    one-third text width -- the first attempt collided into an unreadable smear. Rotating them
    costs as much height as simply turning the chart, and horizontal keeps them level."""
    sp = [c / f for (_, _, f, c, _, _) in T4]
    labs = [t[0].replace("\n", " · ") for t in T4]
    ys = list(range(len(T4)))[::-1]          # first row at the top
    ax.barh(ys, sp, height=0.66, color=FPGA, edgecolor="white", linewidth=0.8, zorder=3)
    for y, v in zip(ys, sp):
        ax.annotate(f"{v:.2f}×", (v, y), xytext=(2.5, 0), textcoords="offset points",
                    va="center", ha="left", fontsize=5.8, color=INK)
    ax.set_yticks(ys); ax.set_yticklabels(labs, fontsize=6)
    ax.set_xlabel("speedup over CPU (×)")
    ax.set_title("(c) On-disk representation", loc="left", fontweight="bold")
    ax.set_xlim(0, max(sp) * 1.22)
    ax.axvline(1.0, color=MUTED, lw=0.6, zorder=2)
    # The two cardinality levels are a grouping, not a series: separate with a rule + text.
    ax.axhline(T4_SPLIT - 0.5, color=MUTED, lw=0.6, ls=":", zorder=1)
    ax.set_ylim(-0.6, 7.6)
    # Group labels go OUTSIDE the axes, rotated: placed inside they collided with the value
    # labels on the two bars nearest the separator.
    for frac, lab in ((0.744, "10 k distinct"), (0.256, "1 M distinct")):
        ax.text(1.015, frac, lab, transform=ax.transAxes, rotation=270,
                ha="left", va="center", fontsize=6, color=MUTED)
    recede(ax, axis="x")   # single series -> no legend; the x-axis names it


def fig_micro(outdir):
    fig, axes = plt.subplots(1, 3, figsize=(TEXT, 2.15))
    panel_scale(axes[0]); panel_cores(axes[1]); panel_repr(axes[2])
    fig.tight_layout(w_pad=1.6)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(outdir, f"fig_micro.{ext}"))
    plt.close(fig)


def fig_decomp(outdir):
    """Where FPGA operator time goes, per representation. The point is that pass 2 is a flat,
    transport-bound band (identical decoded volume everywhere) while the decode window is not.

    HORIZONTAL, for the same reason as panel (c): eight two-word labels do not fit on a shared
    x-axis at single-column width -- the vertical version collided once the (necessarily longer,
    corrected) legend labels widened the legend and squeezed the axes."""
    fig, ax = plt.subplots(figsize=(COL, 2.35))
    ys = list(range(len(T4)))[::-1]
    dec = [t[4] for t in T4]
    pas = [t[5] for t in T4]
    oth = [t[2] - t[4] - t[5] for t in T4]
    labs = [t[0].replace("\n", " · ") for t in T4]
    # LABELS MATTER HERE. In the fused configuration `decode_ms` spans the decode window with
    # PASS 1 (the histogram) hidden underneath it, and `passes_ms` times PASS 2 ONLY -- see
    # iqr_runner.cpp:509 ("pass 1 was overlapped with decode and is accounted to the decode phase")
    # and iqr_runner.hpp:115 (heavy = max(decode, pass1) + pass2). Calling the second band
    # "statistics" would be wrong: it is a transport-bound data pass (160 MB / 12.5 GB/s = 12.8 ms).
    ax.barh(ys, dec, 0.66, color=RAMP[0], edgecolor="white", lw=0.8,
            label="decode + pass 1 (fused)", zorder=3)
    ax.barh(ys, pas, 0.66, left=dec, color=RAMP[1], edgecolor="white", lw=0.8,
            label="pass 2 (classify + return)", zorder=3)
    ax.barh(ys, oth, 0.66, left=[d + p for d, p in zip(dec, pas)], color=RAMP[2],
            edgecolor="white", lw=0.8, label="window + staging", zorder=3)
    ax.set_yticks(ys); ax.set_yticklabels(labs, fontsize=6)
    ax.set_xlabel("FPGA operator time (ms)")
    ax.set_xlim(0, 66)
    ax.set_ylim(-0.6, 7.6)
    ax.axhline(T4_SPLIT - 0.5, color=MUTED, lw=0.6, ls=":", zorder=1)
    for frac, lab in ((0.744, "10 k distinct"), (0.256, "1 M distinct")):
        ax.text(1.015, frac, lab, transform=ax.transAxes, rotation=270,
                ha="left", va="center", fontsize=6, color=MUTED)
    recede(ax, axis="x")
    ax.legend(loc="lower center", ncol=1, handlelength=1.1,
              bbox_to_anchor=(0.5, 1.01), borderaxespad=0.0)
    fig.tight_layout()
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(outdir, f"fig_decomp.{ext}"))
    plt.close(fig)


# Baseline hardening -- report_2807.md sections 1 and 5. End-to-end ms on the 7 REAL datasets,
# build-23, node alveo-u55c-07. THREE levels of the same computation:
#   naive : DuckDB's quantile_cont(v,0.25/0.75) one-liner -- what a user actually writes
#   ourSQL: the SAME group-by-CDF algorithm expressed in pure SQL (medians.py sql_baseline)
#   ourCPP: the SAME algorithm hand-written in C++ (iqr_cpu_flags_groupby) == the paper's baseline
# The middle column matters: it shows the win is ALGORITHMIC, not "C++ beats SQL".
BASE = [   # dataset, rows(M), naive, ourSQL, ourCPP
    ("taxi\\_d1",  3.0,   73,  24,  16),
    ("tpch\\_qty", 6.0,  153,  30,  29),
    ("taxi\\_d2",  6.0,  128,  34,  31),
    ("extprice",  6.0,  128,  97,  85),
    ("taxi\\_d3", 13.1,  288,  57,  54),
    ("taxi\\_d4", 20.3,  600,  76,  76),
    ("sf10",     60.0, 1831, 498, 320),
]


def tab_baseline(outdir):
    import math
    def geo(xs):
        return math.exp(sum(math.log(x) for x in xs) / len(xs))
    g_naive_cpp = geo([n / c for _, _, n, _, c in BASE])
    g_naive_sql = geo([n / q for _, _, n, q, _ in BASE])
    g_sql_cpp   = geo([q / c for _, _, _, q, c in BASE])
    rows = "\n".join(
        f"{d} & {r:.1f}\\,M & {n} & {q} & {c} & \\textbf{{{n/c:.1f}$\\times$}} \\\\"
        for d, r, n, q, c in BASE)
    tex = r"""% Baseline hardening. Source: report_2807.md SS1 and SS5 (end-to-end, build-23).
\begin{table}[t]
\centering\small
\caption{The CPU baseline is hardened before comparison. All three columns compute \emph{exact}
quartiles on identical data; only the algorithm and language differ. The group-by CDF beats the
naive one-liner by """ + f"{g_naive_sql:.1f}" + r"""$\times$ \emph{in pure SQL}, so the gain is
algorithmic rather than a language effect; C++ adds a further """ + f"{g_sql_cpp:.2f}" + r"""$\times$.
The FPGA is compared against the last column throughout.}
\label{tab:baseline}
\begin{tabular}{@{}lr rrr r@{}}
\toprule
 & & \multicolumn{3}{c}{end-to-end (ms)} & \\
\cmidrule(l){3-5}
Dataset & Rows & naive & group-by & group-by & Speedup \\
        &      & 1-line SQL & in SQL & in C++ & (naive$\rightarrow$C++) \\
\midrule
""" + rows + r"""
\midrule
\multicolumn{5}{@{}l}{\emph{geometric mean}} & \textbf{""" + f"{g_naive_cpp:.1f}" + r"""$\times$} \\
\bottomrule
\end{tabular}
\end{table}
"""
    with open(os.path.join(outdir, "tab_baseline.tex"), "w") as fh:
        fh.write(tex)
    print(f"    geomeans: naive->C++ {g_naive_cpp:.2f}x, naive->ourSQL {g_naive_sql:.2f}x, "
          f"ourSQL->C++ {g_sql_cpp:.2f}x")


def tables(outdir):
    ds = r"""% Synthetic datasets for the microbenchmarks. Generated by bench/gen_*.sh.
\begin{table}[t]
\centering\small
\caption{Synthetic datasets. Every sweep varies \emph{one} property; all others are pinned.
Outliers are placed in an empty value gap far outside the fence, so the expected flag count is
exact and unaffected by the 4096-bin quantisation, and is verified on every run.}
\label{tab:datasets}
\begin{tabular}{@{}llll@{}}
\toprule
Sweep & Varies & Pinned & Files \\
\midrule
Scale (\S\ref{sec:scale}) & $10^6$--$10^8$ rows & $10^6$ distinct, PLAIN/Snappy, & 9 \\
                          &                     & 4.94\,B/row, 122\,880-row groups & \\
Host cores (\S\ref{sec:cores}) & 1--32 cores & $2\times10^7$ rows, $9.8\times10^5$ distinct, & 1 \\
                          &                     & PLAIN/Snappy, 4.94\,B/row & \\
Representation (\S\ref{sec:codec}) & encoding $\times$ & $2\times10^7$ rows; values \emph{identical} & 8 \\
                          & compression         & within a cardinality level & \\
\bottomrule
\end{tabular}
\end{table}
"""
    rows = []
    for i, (lab, brow, f, c, dec, pas) in enumerate(T4):
        lvl = "10\\,k" if i < T4_SPLIT else "1\\,M"
        enc, comp = lab.split("\n")
        enc = enc.replace("dict", "dictionary")
        rows.append(f"{lvl} & {enc} & {comp} & {brow:.2f} & {dec:.1f} & {pas:.1f} & "
                    f"{f:.1f} & {c:.1f} & \\textbf{{{c/f:.2f}$\\times$}} \\\\")
    body = "\n".join(rows[:T4_SPLIT]) + "\n\\midrule\n" + "\n".join(rows[T4_SPLIT:])
    cd = r"""% Representation matrix. Within a cardinality level the four files hold the identical
% multiset of values, verified by an order-independent digest, so `statistics' is a control.
\begin{table}[t]
\centering\small
\caption{Compression and encoding sensitivity at $2\times10^7$ rows. Within each block the four
files contain the \emph{same numbers}; only their on-disk representation differs. The statistics
stage is therefore invariant (12.8\,ms throughout) and all variation is decode.}
\label{tab:codec}
\begin{tabular}{@{}lll r rr rr r@{}}
\toprule
Distinct & Encoding & Compr. & B/row & Dec. & Stat. & FPGA & CPU & Speedup \\
         &          &        &       & (ms) & (ms)  & (ms) & (ms) & \\
\midrule
""" + body + r"""
\bottomrule
\end{tabular}
\end{table}
"""
    for name, txt in (("tab_datasets.tex", ds), ("tab_codec.tex", cd)):
        with open(os.path.join(outdir, name), "w") as fh:
            fh.write(txt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=os.path.expanduser("~/oasis/paper/figs"))
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    style()
    fig_micro(a.outdir)
    fig_decomp(a.outdir)
    tables(a.outdir)
    tab_baseline(a.outdir)
    print("wrote into", a.outdir)
    for f in sorted(os.listdir(a.outdir)):
        print("   ", f)


if __name__ == "__main__":
    main()
