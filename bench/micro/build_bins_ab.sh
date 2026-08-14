#!/usr/bin/env bash
# RESULTS.md 9.26: A/B the histogram table geometry using the SHIPPED SelectQuartiles.
# Builds two binaries from identical driver code, differing only in bins/counter width.
set -euo pipefail
cd "$(dirname "$0")"
REPS=${1:-7}; NT=${2:-32}

gen() {  # gen <bins> <counter-type> <outfile>
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
bins, ctr, out = sys.argv[1], sys.argv[2], sys.argv[3]
s = open('../../extension/src/oasis_iqr.cpp').read()
a = s.index('constexpr size_t IQR_CPU_HIST_BINS'); b = s.index('// lo/hi for the 1.5*IQR rule')
core = s[a:b]
core = re.sub(r'constexpr size_t IQR_CPU_HIST_BINS = [^;]+;',
              'constexpr size_t IQR_CPU_HIST_BINS = %s;' % bins, core)
core = re.sub(r'using IqrHistCount = [^;]+;', 'using IqrHistCount = %s;' % ctr, core)
if 'IqrHistCount' not in core:      # source predates the typedef
    core = core.replace('constexpr size_t IQR_CPU_HIST_BINS',
                        'using IqrHistCount = %s;\nconstexpr size_t IQR_CPU_HIST_BINS' % ctr, 1)
    core = core.replace('std::vector<std::vector<uint32_t>>', 'std::vector<std::vector<IqrHistCount>>')
    core = core.replace('uint32_t *sp', 'IqrHistCount *sp')
open(out, 'w').write(core)
PY
}

build() {  # build <bins> <ctr> <tag>
  gen "$1" "$2" "shipped_core.inc"
  g++ -O3 -DNDEBUG -pthread -o "bins_ab_$3" bins_ab.cpp
}

echo "=== A: current oasis_iqr.cpp setting ==="
python3 -c "
import re;s=open('../../extension/src/oasis_iqr.cpp').read()
print(' ', re.search(r'constexpr size_t IQR_CPU_HIST_BINS = [^;]+;',s).group(0))
m=re.search(r'using IqrHistCount = [^;]+;',s); print(' ', m.group(0) if m else 'using IqrHistCount = uint32_t;  (implicit)')"
python3 -c "
import re;s=open('../../extension/src/oasis_iqr.cpp').read()
a=s.index('constexpr size_t IQR_CPU_HIST_BINS');b=s.index('// lo/hi for the 1.5*IQR rule')
open('shipped_core.inc','w').write(s[a:b])"
g++ -O3 -DNDEBUG -pthread -o bins_ab_cur bins_ab.cpp
./bins_ab_cur "$REPS" "$NT"

echo; echo "=== B: 65536 bins x uint64 (512 KB/thread) ==="
build "1u << 16" "uint64_t" alt1 && ./bins_ab_alt1 "$REPS" "$NT"

echo; echo "=== C: 4096 bins x uint32 (16 KB/thread) ==="
build "1u << 12" "uint32_t" alt2 && ./bins_ab_alt2 "$REPS" "$NT"

echo; echo "=== D: 65536 bins x uint32 (256 KB/thread) -- isolates bins from counter width ==="
build "1u << 16" "uint32_t" alt3 && ./bins_ab_alt3 "$REPS" "$NT"

echo; echo "=== E: 4096 bins x uint64 (32 KB/thread) -- isolates counter width from bins ==="
build "1u << 12" "uint64_t" alt4 && ./bins_ab_alt4 "$REPS" "$NT"

# leave shipped_core.inc matching the real source, so exactness.cpp tests what ships
python3 -c "
s=open('../../extension/src/oasis_iqr.cpp').read()
a=s.index('constexpr size_t IQR_CPU_HIST_BINS');b=s.index('// lo/hi for the 1.5*IQR rule')
open('shipped_core.inc','w').write(s[a:b])"
echo; echo "(shipped_core.inc restored to match oasis_iqr.cpp)"
