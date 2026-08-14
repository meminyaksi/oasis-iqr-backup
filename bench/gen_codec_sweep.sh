#!/bin/bash
# COMPRESSION & ENCODING SENSITIVITY -- generator.
#
# THE POINT: the FPGA operator's dominant phase is DECODE (62% of operator time, Test 3), and the
# decoder is the component the IQR and z-score operators SHARE. This sweep varies only the on-disk
# REPRESENTATION of one fixed logical column and measures what the representation costs.
#
# WHY THIS IS THE CLEANEST SWEEP WE CAN BUILD
#   Encoding and compression change the bytes, not the numbers. Within a cardinality level all four
#   files contain the IDENTICAL multiset of values, so the quartiles, the fences and the expected flag
#   count are identical by construction. That makes the FPGA's `passes` phase a CONTROL: it must not
#   move. Anything that does move is decode. Neither a size nor a cardinality sweep can do that,
#   because both of them change the values themselves.
#
# THE DESIGN PROBLEM THIS SOLVES -- collinearity.
#   A naive 2x2 (PLAIN/dictionary x raw/snappy) cannot tell "dictionary decoding costs more per
#   element" from "dictionary moved fewer bytes", because at ordinary cardinalities dictionary always
#   means fewer bytes. Measured with DuckDB 1.5.4 at 2M rows:
#
#       cardinality  encoding     UNCOMPRESSED   SNAPPY
#            10,000  PLAIN            8.00        4.71   B/row
#            10,000  dictionary       2.57        2.34   <- dictionary SHRINKS the file 3.1x
#         1,000,000  PLAIN            8.00        5.20
#         1,000,000  dictionary      11.79        9.16   <- dictionary GROWS the file 1.5x
#
#   So the sweep is replicated at TWO cardinality levels chosen to make the sign of the dictionary's
#   byte effect FLIP. Cardinality is not the axis under test here (that is a separate, IQR-specific
#   question); it is the lever that de-collinearises encoding from byte volume. With 8 points the
#   model  t = floor + a*(B/row) + b*[snappy] + c*[dictionary]  is identifiable with 4 dof.
#
# WHAT THE HARDWARE ACTUALLY SUPPORTS -- the envelope, and it is narrow:
#   * compression: RAW and SNAPPY only. parcore/software/parcore/configuration.cpp:23 -- "Only RAW (0)
#     and SNAPPY (1) are supported by ParCore". ZSTD / GZIP / LZ4 / BROTLI cannot be offloaded at all.
#   * encoding: PLAIN(0), PLAIN_DICTIONARY(2), RLE_DICTIONARY(8) only, and DataPageV2 is NOT supported
#     (parcore/hardware/src/hdl/page_header_parser.sv:194,238). DELTA_BINARY_PACKED and
#     BYTE_STREAM_SPLIT -- what modern writers pick for ints and floats -- are out.
#   * hardware dictionary bound: ID_BITS=19 -> <=524,288 entries / ~2 MiB per dictionary page
#     (parcore/hardware/src/hdl/common.sv:15-31). Dictionaries are PER ROW GROUP, so at
#     ROW_GROUP_SIZE=122880 a group holds at most 122,880 distinct values (~1 MB) even at
#     cardinality 1e6 -- inside the limit, but only by ~2x. Raising ROW_GROUP_SIZE would break it.
#   RLE/bit-packing is deliberately NOT an arm: it is not a standalone data-page encoding on this path,
#   it exists only as the index encoding inside a dictionary page.
#
# VALUE CONSTRUCTION (identical to the size sweep's, so results stay comparable):
#     base = ((hash(i) % CARD) * 2654435761) % 10000000       + outlier bump
# 2654435761 is odd and not divisible by 5, so gcd(P, 1e7)=1 and level*P mod 1e7 is a BIJECTION: the
# low bits are fully spread, which matters because a highly composite step leaves trailing zero bits
# and imbalances the C++ baseline's radix aggregation.
#
# SELF-CHECK: outliers sit at +5e7, i.e. in [5e7, 6e7), far above fence_hi ~1.5e7 with NOTHING in
# between, so the FPGA's 4096-bin quantisation cannot change any row's verdict. Expected flags is
# exactly ROWS/OUTLIER_EVERY for every one of the 8 files.
#
# Usage:
#   bench/gen_codec_sweep.sh                 # 20M rows x 8 files (~1.0 GB)
#   ROWS=10000000 bench/gen_codec_sweep.sh
#   bench/gen_codec_sweep.sh verify          # re-print the manifest + gates only
set -u

DB="${DB:-$HOME/oasis/extension/build/release/duckdb}"
DS="${DS:-/home/myaksi/datasets/codecsweep}"

# The duckdb binary links libcoyote.so from the local install prefix. Export it here rather than
# relying on the invoking shell -- the older generators silently depended on it already being set.
export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"

ROWS="${ROWS:-20000000}"                       # FIXED. 20M == Test 3's `balanced` point.
RANGE="${RANGE:-10000000}"                     # FIXED value range -> fences never move
PERM="${PERM:-2654435761}"                     # coprime with RANGE -> bijection
OUTLIER_EVERY="${OUTLIER_EVERY:-1000}"         # 0.1% -> expected flags = ROWS/1000
OUTLIER_OFFSET="${OUTLIER_OFFSET:-50000000}"   # >> fence_hi (~1.5e7), in an empty gap
RGS="${RGS:-122880}"                           # multiple of 8, and keeps the per-group dictionary
                                               # under the hardware's ~2 MiB / 524288-entry bound

# The two replication levels. Chosen so the dictionary's byte effect changes SIGN between them.
CARD_LO="${CARD_LO:-10000}"                    # dictionary shrinks the file
CARD_HI="${CARD_HI:-1000000}"                  # dictionary GROWS the file (pathological but legal)

# DICTIONARY_SIZE_LIMIT is the only lever DuckDB exposes over encoding. 0 forces PLAIN; a large limit
# forces the writer to keep building a dictionary instead of giving up (its default cap is ~128 KB,
# which flips dictionary->PLAIN somewhere around 20-30k distinct per row group).
DICT_OFF=0
DICT_ON="${DICT_ON:-104857600}"                # 100 MiB

MANIFEST="$DS/manifest.csv"
mkdir -p "$DS"
[[ -x "$DB" ]] || { echo "duckdb not found/executable: $DB" >&2; exit 2; }
if (( RGS % 8 != 0 )); then echo "ROW_GROUP_SIZE $RGS is not a multiple of 8 -- refusing" >&2; exit 2; fi

levels() { echo "lo:$CARD_LO hi:$CARD_HI"; }

write_manifest() {
    echo "level,card,enc_intent,compression,file,rows,bytes,bytes_per_row,encodings,groups,min_group,min_group_mod8,digest_count,digest_sum,digest_hash,distinct" > "$MANIFEST"
    for lv in $(levels); do
        name="${lv%%:*}"; card="${lv##*:}"
        for enc in plain dict; do
            for comp in uncompressed snappy; do
                f="$DS/codec_${name}_${enc}_${comp}.parquet"
                [[ -f "$f" ]] || continue
                bytes=$(stat -c %s "$f")
                bpr=$(awk "BEGIN{printf \"%.2f\", $bytes/$ROWS}")
                # digest_* is an ORDER-INDEPENDENT fingerprint of the value multiset. All four files
                # at a level must agree, or "only the representation changed" is false and the whole
                # sweep is invalid.
                row=$($DB -noheader -list -c "
                  SELECT (SELECT string_agg(DISTINCT encodings, '+') FROM parquet_metadata('$f')) || ',' ||
                         (SELECT count(*) FROM parquet_metadata('$f')) || ',' ||
                         (SELECT min(num_values) FROM parquet_metadata('$f')) || ',' ||
                         (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) || ',' ||
                         (SELECT count(*) FROM read_parquet('$f')) || ',' ||
                         (SELECT sum(v)::HUGEINT FROM read_parquet('$f')) || ',' ||
                         (SELECT sum(hash(v))::HUGEINT FROM read_parquet('$f')) || ',' ||
                         (SELECT approx_count_distinct(v) FROM read_parquet('$f'));") || row=",,,,,,,"
                echo "$name,$card,$enc,$comp,$f,$ROWS,$bytes,$bpr,$row" >> "$MANIFEST"
            done
        done
    done
    column -s, -t "$MANIFEST"
}

check_gates() {
    python3 - "$MANIFEST" <<'PY'
import csv, sys, itertools
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    print("  !! manifest empty"); sys.exit(1)
ok = True
def bad(msg):
    global ok; ok = False; print(f"  FAIL  {msg}")

for r in rows:
    encs = (r["encodings"] or "").upper()
    want_dict = r["enc_intent"] == "dict"
    got_dict  = "DICTIONARY" in encs
    if want_dict != got_dict:
        bad(f"{r['file'].split('/')[-1]}: asked for {r['enc_intent']}, got encodings=[{encs}]")
    if r["min_group_mod8"] != "0":
        bad(f"{r['file'].split('/')[-1]}: min_group % 8 = {r['min_group_mod8']} (streaming would be rejected)")
    if r["compression"] not in ("uncompressed", "snappy"):
        bad(f"{r['file'].split('/')[-1]}: compression outside the supported RAW/SNAPPY envelope")

# THE decisive gate: within a level, all four files must be the same numbers.
for lv, grp in itertools.groupby(sorted(rows, key=lambda r: r["level"]), key=lambda r: r["level"]):
    grp = list(grp)
    for key in ("digest_count", "digest_sum", "digest_hash"):
        vals = {r[key] for r in grp}
        if len(vals) != 1:
            bad(f"level {lv}: {key} differs across the 4 files {sorted(vals)} -- the files do NOT "
                f"contain the same column, so `passes` is not a control and the sweep is invalid")
    if len(grp) != 4:
        bad(f"level {lv}: expected 4 files, found {len(grp)}")

print("  ALL GATES PASS" if ok else "  >>> GATES FAILED -- do not run the benchmark <<<")
sys.exit(0 if ok else 1)
PY
}

if [[ "${1:-}" == "verify" ]]; then
    echo "=== codec-sweep manifest ($DS) ==="
    write_manifest
    echo
    echo "GATES:"
    check_gates
    exit $?
fi

echo "=== generating compression/encoding matrix into $DS ==="
echo "    ROWS=$ROWS (FIXED)   RANGE=[0,$RANGE)   outliers=1/$OUTLIER_EVERY (+$OUTLIER_OFFSET)"
echo "    levels: lo=$CARD_LO (dictionary shrinks) · hi=$CARD_HI (dictionary grows)"
echo "    2 encodings x 2 compressions x 2 levels = 8 files   ROW_GROUP_SIZE=$RGS"
echo

for lv in $(levels); do
    name="${lv%%:*}"; card="${lv##*:}"
    for enc in plain dict; do
        [[ "$enc" == plain ]] && dl=$DICT_OFF || dl=$DICT_ON
        for comp in uncompressed snappy; do
            [[ "$comp" == uncompressed ]] && COMP=UNCOMPRESSED || COMP=SNAPPY
            f="$DS/codec_${name}_${enc}_${comp}.parquet"
            if [[ -f "$f" && -z "${FORCE:-}" ]]; then
                echo "  $(basename "$f") exists (FORCE=1 to regenerate) -- skipping"; continue
            fi
            echo "  writing $(basename "$f")   (card=$card, DICTIONARY_SIZE_LIMIT=$dl, $COMP) ..."
            # Write to a temp name and rename only on success. Without this, an interrupted or failed
            # write leaves a TRUNCATED parquet that the "exists -> skip" branch above would silently
            # accept on the next run. The gates would eventually catch it via the digest, but by then
            # you are debugging a benchmark instead of a half-written file.
            tmp="$f.partial"
            rm -f "$tmp"
            $DB -c "
              COPY (SELECT (((hash(i) % $card) * $PERM) % $RANGE)::BIGINT
                           + CASE WHEN i % $OUTLIER_EVERY = 0 THEN $OUTLIER_OFFSET ELSE 0 END AS v
                    FROM range($ROWS) t(i))
              TO '$tmp' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS,
                         DICTIONARY_SIZE_LIMIT $dl, COMPRESSION $COMP);" \
              && mv -f "$tmp" "$f" \
              || { echo "  !! failed at $f" >&2; rm -f "$tmp"; exit 1; }
        done
    done
done

echo
echo "=== manifest ==="
write_manifest
echo
echo "GATES:"
check_gates
gate_rc=$?
echo
echo "disk used: $(du -sh "$DS" | cut -f1)"
echo "next: python3 bench/codec_sweep.py --dsdir $DS"
exit $gate_rc
