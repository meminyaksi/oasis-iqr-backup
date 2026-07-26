// Does the wrap test's over-extension (span > range at intermediate levels) ever change q1/q3?
// The SHIPPED SelectQuartiles/AdvanceRankQueries are pasted in verbatim from oasis_iqr.cpp and
// checked against a brute-force sort. Adversarial by design: wide ranges (3+ levels), ranks pushed
// into the LAST bin, clustered/skewed data, signed ranges straddling zero.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <random>
#include <thread>
#include <type_traits>
#include <vector>
template <class F> void ParallelRanges(size_t n, size_t nthreads, F &&fn) {
    if (n == 0) return;
    if (nthreads <= 1) { fn(size_t(0), size_t(0), n); return; }
    const size_t chunk = (n + nthreads - 1) / nthreads;
    std::vector<std::thread> workers;
    for (size_t t = 0; t < nthreads; t++) {
        size_t lo = t * chunk; if (lo >= n) break;
        size_t hi = std::min(n, lo + chunk);
        workers.emplace_back([&fn, t, lo, hi] { fn(t, lo, hi); });
    }
    for (auto &w : workers) w.join();
}
template <class T> void ParallelMinMax(const T *v, size_t n, size_t nt, T &out_min, T &out_max) {
    std::vector<T> mins(nt, std::numeric_limits<T>::max()), maxs(nt, std::numeric_limits<T>::lowest());
    ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
        T mn = std::numeric_limits<T>::max(), mx = std::numeric_limits<T>::lowest();
        for (size_t i = lo; i < hi; i++) { T x = v[i]; mn = x < mn ? x : mn; mx = x > mx ? x : mx; }
        mins[t] = mn; maxs[t] = mx;
    });
    out_min = *std::min_element(mins.begin(), mins.end());
    out_max = *std::max_element(maxs.begin(), maxs.end());
}
#include "shipped_core.inc"

template <class T> bool one(std::vector<T> v, size_t nt, const char *tag) {
    const size_t n = v.size();
    const size_t k1 = (n + 3) / 4, k3 = (3 * n + 3) / 4;
    T q1, q3;
    SelectQuartiles<T>(v.data(), n, k1 - 1, k3 - 1, nt, q1, q3);
    std::vector<T> s = v; std::sort(s.begin(), s.end());
    if (q1 != s[k1 - 1] || q3 != s[k3 - 1]) {
        std::printf("  FAIL %s n=%zu nt=%zu: q1 %lld vs %lld, q3 %lld vs %lld\n", tag, n, nt,
                    (long long)q1, (long long)s[k1-1], (long long)q3, (long long)s[k3-1]);
        return false;
    }
    return true;
}
int main() {
    std::mt19937_64 rng(4242);
    size_t trials = 0; bool ok = true;
    for (size_t nt : {1ul, 4ul, 32ul}) {
        // 3+ level ranges: span-over-extension is possible at every intermediate level
        for (int rep = 0; rep < 60; rep++) {
            size_t n = 1000 + rng() % 400000;
            int64_t lo = (int64_t)rng(), width = (int64_t)1 << (30 + rng() % 32);
            std::vector<int64_t> v(n);
            for (auto &x : v) x = lo + (int64_t)(rng() % (uint64_t)width);
            ok &= one<int64_t>(v, nt, "wide range"); trials++;
        }
        // ranks pushed into the LAST bin: 95 % of mass at the very top of the range
        for (int rep = 0; rep < 60; rep++) {
            size_t n = 1000 + rng() % 200000;
            int64_t lo = -(int64_t)1 << 40, hi = (int64_t)1 << 40;
            std::vector<int64_t> v(n);
            for (auto &x : v) x = (rng() % 100 < 95) ? hi - (int64_t)(rng() % 4096) : lo + (int64_t)(rng() % 1000);
            ok &= one<int64_t>(v, nt, "mass at top"); trials++;
        }
        // clustered just below/above a bin edge, straddling zero
        for (int rep = 0; rep < 60; rep++) {
            size_t n = 500 + rng() % 100000;
            std::vector<int64_t> v(n);
            for (auto &x : v) x = (int64_t)(rng() % 8) - 4 + (int64_t)((rng() % 3) * ((int64_t)1 << 33));
            ok &= one<int64_t>(v, nt, "clustered"); trials++;
        }
        // unsigned, above INT64_MAX
        for (int rep = 0; rep < 40; rep++) {
            size_t n = 500 + rng() % 100000;
            std::vector<uint64_t> v(n);
            for (auto &x : v) x = ((uint64_t)1 << 63) + (rng() % ((uint64_t)1 << 45));
            ok &= one<uint64_t>(v, nt, "unsigned high"); trials++;
        }
    }
    std::printf("%s  (%zu trials)\n", ok ? "ALL EXACT vs brute-force sort" : "FAILURES ABOVE", trials);
    return ok ? 0 : 1;
}
