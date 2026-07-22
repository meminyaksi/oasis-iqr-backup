#!/usr/bin/env bash
# A/B for OASIS_IQR_OVERLAP (pass 1 hidden under decode). Run from ~/oasis.
#
#   bench/overlap_ab.sh time      -- timing on sf10 (the objective)
#   bench/overlap_ab.sh gen       -- build the two accuracy datasets (once)
#   bench/overlap_ab.sh accuracy  -- accuracy A/B on those datasets
#
# Why the accuracy datasets are needed: the overlap only engages on the STREAMING path, which today
# is exactly the three tpch files -- and all three have ZERO outliers by nature. The four taxi files
# are the only ones with outliers and they all fall back to sink=memcpy (odd-sized row groups), so
# cpu_op_correctness.sql cannot see this change at all. These two files stream AND have outliers.
set -uo pipefail
export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"
DB=./extension/build/release/duckdb
DS=/home/myaksi/datasets

case "${1:-time}" in

time)
  # timeout on every FPGA call: a wedged card (e.g. after a Ctrl-C mid-transfer -- Coyote has no
  # inter-process reset) blocks forever in get_next_batch(), and killing THAT wedges it further.
  for OV in 0 1; do
    echo "=== overlap=$OV ==="
    OASIS_IQR_STREAM=1 OASIS_IQR_OVERLAP=$OV OASIS_IQR_DECODE_WINDOW=16 OASIS_IQR_TIMING=1 \
      timeout 120 $DB -c "SELECT count(*) FROM iqr_flags_only('$DS/tpch_extprice_sf10.parquet','v');" 2>&1 \
      | grep '\[iqr\]'
    [ "${PIPESTATUS[0]}" = "124" ] && echo "  TIMED OUT -- card is wedged; see the recovery steps."
  done
  ;;

gen)
  # Generated from range() rather than re-written from an existing parquet: COPY preserves the source
  # row-group layout when reading one, which is why taxi_d4_dd came out with the original's odd
  # 51449/124849 groups. From range() DuckDB uses ROW_GROUP_SIZE, giving clean 122880 (mult. of 8).
  #
  # ov_uniform: stationary distribution -> a prefix sample and a full stride sample should agree.
  # ov_drift:   values grow with row order -> the ADVERSARIAL case for a prefix-derived window,
  #             which is the honest test of what this change trades away.
  echo "writing ov_uniform.parquet ..."
  $DB -c "
    COPY (SELECT ((i * 2654435761) % 10000)::BIGINT
                 + CASE WHEN i % 100000 = 0 THEN 5000000 ELSE 0 END AS v
          FROM range(20000000) t(i))
    TO '$DS/ov_uniform.parquet' (FORMAT PARQUET, ROW_GROUP_SIZE 122880);"
  echo "writing ov_drift.parquet ..."
  $DB -c "
    COPY (SELECT (i / 2000)::BIGINT + ((i * 2654435761) % 1000)::BIGINT
                 + CASE WHEN i % 100000 = 0 THEN 5000000 ELSE 0 END AS v
          FROM range(20000000) t(i))
    TO '$DS/ov_drift.parquet' (FORMAT PARQUET, ROW_GROUP_SIZE 122880);"
  $DB -c "
    SELECT 'ov_uniform' f, encodings, count(*) groups, min(num_values) mn, max(num_values) mx
    FROM parquet_metadata('$DS/ov_uniform.parquet') GROUP BY 1,2
    UNION ALL
    SELECT 'ov_drift', encodings, count(*), min(num_values), max(num_values)
    FROM parquet_metadata('$DS/ov_drift.parquet') GROUP BY 1,2;"
  echo "mn must be a multiple of 8 on every non-final group, else the guard rejects and this tests nothing."
  ;;

accuracy)
  # NOTE: CLI output flags must precede -c, else duckdb ignores them and prints a duckbox table.
  for F in ov_uniform ov_drift; do
    echo "########## $F ##########"
    REF=$(timeout 300 $DB -noheader -list \
          -c "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags('$DS/$F.parquet','v');" \
          2>/dev/null | tail -n 1)
    echo "exact (C++ CPU): $REF"
    for OV in 0 1; do
      OUT=$(OASIS_IQR_STREAM=1 OASIS_IQR_OVERLAP=$OV OASIS_IQR_TIMING=1 \
            timeout 120 $DB -noheader -list \
            -c "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('$DS/$F.parquet','v');" \
            2>&1)
      if [ $? = 124 ]; then echo "overlap=$OV  TIMED OUT -- card wedged"; continue; fi
      MODE=$(echo "$OUT" | grep -o 'pass1=[a-z]*' | head -n 1)
      N=$(echo "$OUT" | grep -v '\[iqr\]' | tail -n 1)
      echo "overlap=$OV  ${MODE:-pass1=?}  n_fpga=$N   (exact $REF)"
    done
  done
  echo
  echo "pass1=overlapped must appear for overlap=1, else the guard rejected and nothing was tested."
  ;;

*) echo "usage: $0 {time|gen|accuracy}"; exit 1 ;;
esac
