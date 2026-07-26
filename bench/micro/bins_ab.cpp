// RESULTS.md 9.26 -- what the histogram table geometry costs, measured on the REAL code.
//
// Drives the shipped SelectQuartiles / AdvanceRankQueries verbatim (via shipped_core.inc), so the
// timing covers everything the operator actually does per level: the histogram pass, the per-thread
// table clear, and the SERIAL cross-thread merge loop -- not just the inner loop.
//
// Build two binaries from the same driver and diff them:
//   ./build_bins_ab.sh          (writes bins_ab_cur and bins_ab_alt, runs both)
//
// -DIQR_BINS_OVERRIDE=<n> -DIQR_COUNT_OVERRIDE=<type> patch the geometry; with neither, the current
// oasis_iqr.cpp setting is measured as-is.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <random>
#include <thread>
#include <type_traits>
#include <vector>

using clk = std::chrono::steady_clock;
static double ms_since(clk::time_point t) {
    return std::chrono::duration<double, std::milli>(clk::now() - t).count();
}

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

static double med(std::vector<double> x) { std::sort(x.begin(), x.end()); return x[x.size() / 2]; }

struct DS { const char *name; int64_t lo, hi; size_t n; };

int main(int argc, char **argv) {
    const int    reps = argc > 1 ? std::atoi(argv[1]) : 7;
    const size_t NT   = argc > 2 ? std::strtoull(argv[2], nullptr, 10) : 32;

    // Ranges are the measured min/max of the real columns; sizes are the real row counts.
    const DS sets[] = {
        {"taxi_d1  (3.0M, range 5.9e5)",  -89900,    500000,     2964624},
        {"tpch_qty (6.0M, range 49)",      1,        50,         6001215},
        {"taxi_d4  (20.3M, range 5.9e5)", -89900,    500000,     20332093},
        {"sf10     (60.0M, range 1.0e7)",  90091,    10494950,   59986052},
    };

    std::printf("bins = %zu   counter = %zu B   table/thread = %.0f KB   threads = %zu   reps = %d\n\n",
                IQR_CPU_HIST_BINS, sizeof(IqrHistCount),
                IQR_CPU_HIST_BINS * sizeof(IqrHistCount) / 1024.0, NT, reps);
    std::printf("%-32s %10s %10s\n", "dataset", "quart ms", "GB/s");

    for (const auto &d : sets) {
        std::vector<int64_t> v(d.n);
        {
            size_t nt = std::thread::hardware_concurrency(), chunk = (d.n + nt - 1) / nt;
            std::vector<std::thread> ws;
            for (size_t t = 0; t < nt; t++) {
                size_t a = t * chunk; if (a >= d.n) break;
                size_t b = std::min(d.n, a + chunk);
                ws.emplace_back([&, t, a, b] {
                    std::mt19937_64 rng(0x9E3779B97F4A7C15ull + t);
                    std::uniform_int_distribution<int64_t> dist(d.lo, d.hi);
                    for (size_t i = a; i < b; i++) v[i] = dist(rng);
                });
            }
            for (auto &w : ws) w.join();
        }
        const size_t k1 = (d.n + 3) / 4, k3 = (3 * d.n + 3) / 4;
        std::vector<double> ts;
        int64_t q1 = 0, q3 = 0;
        for (int r = 0; r < reps; r++) {
            auto t0 = clk::now();
            SelectQuartiles<int64_t>(v.data(), d.n, k1 - 1, k3 - 1, NT, q1, q3);
            ts.push_back(ms_since(t0));
        }
        double ms = med(ts);
        std::printf("%-32s %10.2f %10.1f   (q1=%lld q3=%lld)\n", d.name, ms,
                    d.n * 8.0 / 1e6 / ms, (long long)q1, (long long)q3);
    }
    return 0;
}
