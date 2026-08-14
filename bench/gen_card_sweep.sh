#!/bin/bash
# CARDINALITY SWEEP GENERATOR -- fixed 10M rows. THE ONLY THING THAT VARIES IS THE NUMBER OF
# DISTINCT VALUES. Everything else is pinned, including the two things that leaked in earlier versions.
#
# WHAT LEAKED BEFORE AND HOW IT IS PINNED NOW
#   1. ENCODING. Parquet's writer derives encoding from cardinality: it builds a dictionary while the
#      dictionary page stays under ~128 KB (measured: it flips to PLAIN between 20k and 30k distinct
#      per row group), then gives up and writes PLAIN. So a cardinality sweep silently crossed an
#      encoding boundary and the FPGA arm stepped 1.7x there -- an encoding effect masquerading as a
#      cardinality effect. FIX: `DICTIONARY_SIZE_LIMIT 0` forces PLAIN at EVERY cardinality.
#   2. BYTES/ROW. Snappy compresses repeated values well, so bytes/row moved 0.63 -> 4.94 across the
#      sweep: the FPGA had to fetch 7.8x more data at high cardinality, which is a byte-volume effect,
#      not a cardinality effect. FIX: `COMPRESSION UNCOMPRESSED` pins bytes/row at EXACTLY 8.00
#      everywhere (verified).
#   Consequence: the FPGA arm MUST now be flat across the whole sweep -- identical bytes, identical
#   encoding, identical row count. If it is not flat, something is wrong. That is the internal check.
#   The CPU arm is then free to show the pure cardinality trend.
#
# VALUE CONSTRUCTION -- CARD levels scattered over a FIXED range [0, RANGE):
#
#     base = ((hash(i) % CARD) * 2654435761) % RANGE
#
# 2654435761 (Knuth) is odd and not divisible by 5, so gcd(P, 10^7) = 1 and `level*P mod RANGE` is a
# BIJECTION: exactly CARD distinct levels, no collisions, low bits fully spread.
#   * A fixed RANGE keeps Q1~2.5e6, Q3~7.5e6, IQR~5e6 and fence_hi~1.5e7 IDENTICAL at every
#     cardinality, so the expected flag count never moves.
#   * NOT `level * (RANGE/CARD)`: that step is highly composite, so every value inherits its trailing
#     zero bits. It left only 512 of 1000 possible low-12-bit patterns at CARD=1000, imbalancing the
#     C++ baseline's RADIX aggregation by an amount that VARIED WITH CARDINALITY -- and it produced a
#     spurious monotonic CPU decline that vanished once this permutation replaced it.
#
# RANGE is 1e7 (= ROWS) so cardinality can run all the way to ~all-distinct. hash() collisions mean
# CARD=1e7 delivers ~63% coverage (~6.3M distinct); the manifest reports what was actually achieved.
#
# SELF-CHECK: outliers sit at +5e7, i.e. in [5e7, 6e7), far above fence_hi ~1.5e7 with NOTHING in
# between, so the FPGA's 4096-bin quantisation cannot change any row's verdict. Expected flags is
# exactly ROWS/OUTLIER_EVERY at every point. Any deviation is a real bug.
#
# NOTE: uncompressed data means the FPGA fetches 8 B/row rather than ~4.94, so absolute times are NOT
# comparable with micro_bench.md Test 1 (which used Snappy). This sweep is self-contained.
#
# CARD starts at 10, never 1: a single distinct value makes IQR=0 and the fences degenerate.
#
# Usage:
#   bench/gen_card_sweep.sh                            # 10M rows, CARD = 10 .. 10M
#   CARDS="10 1000 10000000" bench/gen_card_sweep.sh
#   ROWS=20000000 RANGE=20000000 bench/gen_card_sweep.sh
#   bench/gen_card_sweep.sh verify                     # re-print the manifest only
set -u

DB="${DB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-/home/myaksi/datasets/cardsweep10m}"

ROWS="${ROWS:-10000000}"                       # FIXED across the sweep
CARDS="${CARDS:-10 100 1000 10000 100000 1000000 10000000}"
RANGE="${RANGE:-10000000}"                     # FIXED value range -> fences never move
PERM="${PERM:-2654435761}"                     # coprime with RANGE -> bijection
OUTLIER_EVERY="${OUTLIER_EVERY:-1000}"         # 0.1% -> expected flags = ROWS/1000
OUTLIER_OFFSET="${OUTLIER_OFFSET:-50000000}"   # >> fence_hi (~1.5e7), in an empty gap
RGS="${RGS:-122880}"                           # must be a multiple of 8
# The two pins. Override only if you deliberately want encoding/bytes to move again.
DICT_LIMIT="${DICT_LIMIT:-0}"                  # 0 => force PLAIN at every cardinality
COMPRESSION="${COMPRESSION:-UNCOMPRESSED}"     # => bytes/row pinned at exactly 8.00

MANIFEST="$DS/manifest.csv"
mkdir -p "$DS"
[[ -x "$DB" ]] || { echo "duckdb not found/executable: $DB" >&2; exit 2; }
if (( RGS % 8 != 0 )); then echo "ROW_GROUP_SIZE $RGS is not a multiple of 8 -- refusing" >&2; exit 2; fi

write_manifest() {
    echo "card,rows,file,bytes,bytes_per_row,distinct,groups,min_group,min_group_mod8,encoding,compression" > "$MANIFEST"
    for c in $CARDS; do
        f="$DS/card_${c}.parquet"
        [[ -f "$f" ]] || continue
        bytes=$(stat -c %s "$f")
        bpr=$(awk "BEGIN{printf \"%.2f\", $bytes/$ROWS}")
        row=$($DB -noheader -list -c "
          SELECT (SELECT approx_count_distinct(v) FROM read_parquet('$f')) || ',' ||
                 (SELECT count(*) FROM parquet_metadata('$f')) || ',' ||
                 (SELECT min(num_values) FROM parquet_metadata('$f')) || ',' ||
                 (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) || ',' ||
                 (SELECT DISTINCT encodings FROM parquet_metadata('$f') LIMIT 1) || ',' ||
                 (SELECT DISTINCT compression FROM parquet_metadata('$f') LIMIT 1);") || row=",,,,,"
        echo "$c,$ROWS,$f,$bytes,$bpr,$row" >> "$MANIFEST"
    done
    column -s, -t "$MANIFEST"
}

if [[ "${1:-}" == "verify" ]]; then
    echo "=== cardinality-sweep manifest ($DS) ==="
    write_manifest
    echo
    echo "GATES (all must hold, or the sweep is not single-variable):"
    echo "  * encoding      == PLAIN on every row"
    echo "  * compression   == UNCOMPRESSED on every row"
    echo "  * bytes_per_row == 8.00 on every row"
    echo "  * min_group_mod8 == 0 on every row"
    exit 0
fi

echo "=== generating cardinality sweep into $DS ==="
echo "    ROWS=$ROWS (FIXED)   RANGE=[0,$RANGE) (FIXED)   outliers=1/$OUTLIER_EVERY (+$OUTLIER_OFFSET)"
echo "    encoding pinned PLAIN (DICTIONARY_SIZE_LIMIT=$DICT_LIMIT), compression=$COMPRESSION"
echo "    CARDS=$CARDS   ROW_GROUP_SIZE=$RGS"
echo

for c in $CARDS; do
    if (( c > RANGE )); then
        echo "  !! card $c > RANGE $RANGE: permutation cannot be injective -- skipping" >&2; continue
    fi
    f="$DS/card_${c}.parquet"
    if [[ -f "$f" && -z "${FORCE:-}" ]]; then
        echo "  card_${c}.parquet exists (FORCE=1 to regenerate) -- skipping"; continue
    fi
    echo "  writing card_${c}.parquet   ($c levels scattered over [0,$RANGE)) ..."
    $DB -c "
      COPY (SELECT (((hash(i) % $c) * $PERM) % $RANGE)::BIGINT
                   + CASE WHEN i % $OUTLIER_EVERY = 0 THEN $OUTLIER_OFFSET ELSE 0 END AS v
            FROM range($ROWS) t(i))
      TO '$f' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS,
               DICTIONARY_SIZE_LIMIT $DICT_LIMIT, COMPRESSION $COMPRESSION);" \
      || { echo "  !! failed at card=$c" >&2; exit 1; }
done

echo
echo "=== manifest ==="
write_manifest
echo
echo "GATES: encoding PLAIN everywhere, compression UNCOMPRESSED everywhere, bytes_per_row 8.00"
echo "       everywhere, min_group_mod8 0 everywhere. Then cardinality is the ONLY variable."
echo "EXPECT: FPGA arm FLAT across all cardinalities (identical bytes/encoding/rows -- if it is not"
echo "        flat, something is wrong). CPU arm RISING with cardinality (GROUP BY builds and sorts a"
echo "        per-distinct-value table, so its cost grows while the FPGA's fixed pipeline does not)."
echo
echo "disk used: $(du -sh "$DS" | cut -f1)"
echo "next: python3 bench/card_sweep.py --dsdir $DS"
