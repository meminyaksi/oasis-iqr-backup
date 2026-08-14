#!/usr/bin/env python3
# Offline per-row validation of the FUSED path (obstacle-1). Compares the flag bitmask dumped by
# OASIS_IQR_DUMP_FLAGS against the C++-exact fence decision computed here from the parquet column.
#
# The fused/streaming FPGA output cannot be materialized in SQL without deadlocking the no-timeout
# receiver, and iqr_flags_only emits no value column -- so we dump the raw bitmask from the extension
# and diff it here, in file order (the fused path emits row groups in order; pyarrow reads them in
# order). A bit-shift mislabel is count-preserving, so net_diff alone can't catch it: per_row_mismatch
# is the real test.
#
#   1) FPGA (ON the card, single clean aggregate -- no breaker, safe):
#        OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 \
#        OASIS_IQR_STREAM_RAGGED=1 OASIS_IQR_WINDOW_IQR=1 OASIS_IQR_DUMP_FLAGS=/tmp/d3.bin \
#          ./extension/build/release/duckdb -c \
#          "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('$HOME/datasets/taxi_d3.parquet','fare_cents');"
#   2) offline (anywhere):
#        bench/compare_dumped_flags.py /tmp/d3.bin $HOME/datasets/taxi_d3.parquet fare_cents
import sys, struct
import numpy as np
import pyarrow.parquet as pq

def main():
    if len(sys.argv) != 4:
        sys.exit("usage: compare_dumped_flags.py <dump.bin> <parquet> <column>")
    dump, path, col = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(dump, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        mask = np.frombuffer(f.read((n + 7) // 8), dtype=np.uint8)
    # Unpack LSB-first (element i -> byte i>>3, bit i&7), matching EmitFlagSlice / IQR_detection.sv.
    fpga = np.unpackbits(mask, bitorder="little")[:n].astype(bool)

    # Column values in FILE ORDER (read row groups in order, do not reshuffle).
    v = pq.read_table(path, columns=[col]).column(0).to_numpy(zero_copy_only=False).astype(np.int64)
    if v.shape[0] != n:
        sys.exit(f"row count mismatch: dump N={n}, parquet rows={v.shape[0]}")

    # C++-exact fence: GROUP BY value + cumulative count quartiles, divider-free 1.5*IQR (q + (iqr+iqr>>1)).
    # Identical to correctness_3way_fences.sql's `gf`.
    vals, counts = np.unique(v, return_counts=True)   # sorted ascending, with per-value counts
    cum = np.cumsum(counts)
    total = int(cum[-1])
    q1 = int(vals[np.searchsorted(cum * 4, total,     side="left")])   # first v where cc*4 >= total
    q3 = int(vals[np.searchsorted(cum * 4, 3 * total, side="left")])   # first v where cc*4 >= 3*total
    iqr = q3 - q1
    step = iqr + (iqr >> 1)                                            # 1.5*IQR, floor, divider-free
    lo, hi = q1 - step, q3 + step
    cpu = (v < lo) | (v > hi)

    n_fpga = int(fpga.sum())
    n_cpu  = int(cpu.sum())
    mism   = fpga != cpu
    per_row_mismatch = int(mism.sum())
    net_diff = abs(n_fpga - n_cpu)

    print(f"rows              = {n}")
    print(f"q1 / q3           = {q1} / {q3}   IQR={iqr}   fence=[{lo}, {hi}]")
    print(f"n_fpga            = {n_fpga}")
    print(f"n_cpu (exact)     = {n_cpu}")
    print(f"net_diff          = {net_diff}")
    print(f"per_row_mismatch  = {per_row_mismatch}")

    if per_row_mismatch <= net_diff + 4:
        print("VERDICT: threshold-consistent (binning at the fence only) -- obstacle-1 FIXED, taxi fuses correctly.")
    else:
        print("VERDICT: per_row_mismatch >> net_diff -> row swaps / bit-shift mislabel -- obstacle-1 NOT fixed.")
        # Show where: how far are mismatched rows from the fence? Swaps land far; binning lands adjacent.
        mv = v[mism]
        near = int((((mv >= lo - 4) & (mv <= lo + 4)) | ((mv >= hi - 4) & (mv <= hi + 4))).sum())
        print(f"  of {per_row_mismatch} mismatches, {near} are within 4 of a fence (binning), "
              f"{per_row_mismatch - near} are far from both (swaps)")
        idx = np.flatnonzero(mism)[:10]
        print("  first mismatches (row, value, fpga, cpu):")
        for i in idx:
            print(f"    {int(i):>10}  v={int(v[i]):>10}  fpga={bool(fpga[i])}  cpu={bool(cpu[i])}")

if __name__ == "__main__":
    main()
