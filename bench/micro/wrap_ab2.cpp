// v2: faithful model of a real sf10 SelectQuartiles run, wrap vs traditional membership test.
//
// Three measured passes, matching what AdvanceRankQueries actually does:
//   minmax   : the ParallelMinMax pass (identical in both variants -- the memory-bandwidth reference)
//   level 1  : nh == 1, whole range, EVERY element in range  -> the specialized flat loop
//   level 2  : nh == 2, Q1's bin (25th pct) and Q3's bin (75th pct), both refined to width 1
//              -> the GENERAL loop, two membership tests per element in ONE pass
// Plus a pure-read bandwidth ceiling for this machine, so it is clear whether the loops are at the wall.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <random>
#include <thread>
#include <vector>

using U   = uint64_t;
using clk = std::chrono::steady_clock;
static double ms_since(clk::time_point t) {
    return std::chrono::duration<double, std::milli>(clk::now() - t).count();
}
constexpr size_t BINS = 1u << 12;
constexpr size_t MAXH = 4;

template <class F>
static double timed(size_t n, size_t nt, F &&body) {
    const size_t chunk = (n + nt - 1) / nt;
    auto t0 = clk::now();
    std::vector<std::thread> ws;
    ws.reserve(nt);
    for (size_t t = 0; t < nt; t++) {
        size_t a = t * chunk; if (a >= n) break;
        ws.emplace_back([&, t, a] { body(t, a, std::min(n, a + chunk)); });
    }
    for (auto &w : ws) w.join();
    return ms_since(t0);
}

static double med(std::vector<double> x) { std::sort(x.begin(), x.end()); return x[x.size()/2]; }

int main(int argc, char **argv) {
    const size_t n    = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 59986052;
    const int    reps = argc > 2 ? std::atoi(argv[2]) : 7;
    const size_t NT   = argc > 3 ? std::strtoull(argv[3], nullptr, 10) : 32; // study uses threads=32
    // Runtime-opaque: in the real AdvanceRankQueries these come out of the q[] array, so neither
    // variant may fold them into immediates. volatile forces a genuine load.
    volatile int64_t vmin_v = argc > 4 ? std::strtoll(argv[4], nullptr, 10) : 90091;
    volatile int64_t vmax_v = argc > 5 ? std::strtoll(argv[5], nullptr, 10) : 10494950;
    const int64_t vmin = vmin_v, vmax = vmax_v;

    std::vector<int64_t> v(n);
    std::vector<uint64_t> sink(NT, 0);
    {
        size_t nt = std::thread::hardware_concurrency(), chunk = (n + nt - 1) / nt;
        std::vector<std::thread> ws;
        for (size_t t = 0; t < nt; t++) {
            size_t a = t * chunk; if (a >= n) break;
            size_t b = std::min(n, a + chunk);
            ws.emplace_back([&, t, a, b] {
                std::mt19937_64 rng(0x9E3779B97F4A7C15ull + t);
                std::uniform_int_distribution<int64_t> d(vmin, vmax);
                for (size_t i = a; i < b; i++) v[i] = d(rng);
            });
        }
        for (auto &w : ws) w.join();
    }

    unsigned sh1 = 0;
    { U range = (U)vmax - (U)vmin; while ((range >> sh1) >= BINS) sh1++; }
    const size_t nb1 = (size_t)(((U)vmax - (U)vmin) >> sh1) + 1;

    // Q1's and Q3's level-1 bins for uniform data: 25 % and 75 % through the range.
    const int64_t q1lo = vmin + (int64_t)((U)(nb1 / 4) << sh1);
    const int64_t q3lo = vmin + (int64_t)((U)(3 * nb1 / 4) << sh1);

    std::printf("n = %zu (%.1f MB)  reps = %d  threads = %zu  bins = %zu  level-1: shift %u, %zu bins\n",
                n, n * 8.0 / 1e6, reps, NT, BINS, sh1, nb1);
    std::printf("level-2 ranges: Q1 [%ld, %ld]  Q3 [%ld, %ld]  (width %d, shift 0 -> exact)\n\n",
                q1lo, q1lo + (1 << sh1) - 1, q3lo, q3lo + (1 << sh1) - 1, 1 << sh1);

    const double MB = n * 8.0 / 1e6;

    // ---------- pure read: this machine's ceiling for a streaming scan ----------
    std::vector<double> t_read;
    for (int r = 0; r < reps; r++)
        t_read.push_back(timed(n, NT, [&](size_t t, size_t a, size_t b) {
            uint64_t s = 0; for (size_t i = a; i < b; i++) s += (uint64_t)v[i]; sink[t] += s;
        }));
    double read_ms = med(t_read);

    // ---------- minmax: identical in both variants ----------
    std::vector<double> t_mm;
    for (int r = 0; r < reps; r++)
        t_mm.push_back(timed(n, NT, [&](size_t t, size_t a, size_t b) {
            int64_t mn = std::numeric_limits<int64_t>::max(), mx = std::numeric_limits<int64_t>::lowest();
            for (size_t i = a; i < b; i++) { int64_t x = v[i]; mn = x < mn ? x : mn; mx = x > mx ? x : mx; }
            sink[t] += (uint64_t)mn ^ (uint64_t)mx;
        }));
    double mm_ms = med(t_mm);

    std::printf("%-34s %9s %9s\n", "reference pass", "ms", "GB/s");
    std::printf("%-34s %9.2f %9.1f\n", "pure read (sum) = the ceiling", read_ms, MB / read_ms);
    std::printf("%-34s %9.2f %9.1f\n\n", "min/max (same in both)", mm_ms, MB / mm_ms);

    // ---------- level 1: nh == 1, all in range ----------
    const U b1 = (U)vmin;
    const U s1 = ((U)(nb1 - 1) << sh1) | ((U(1) << sh1) - 1);
    std::vector<std::vector<uint32_t>> sc(NT, std::vector<uint32_t>(BINS * MAXH, 0));
    std::vector<int64_t> l1lo {vmin}, l1hi {vmax};   // heap-backed: not foldable

    std::vector<double> l1w, l1t;
    for (int r = 0; r < reps; r++) {
        l1w.push_back(timed(n, NT, [&](size_t t, size_t a, size_t b) {
            uint32_t *sp = sc[t].data();
            for (size_t i = a; i < b; i++) { const U off = (U)v[i] - b1; if (off <= s1) sp[off >> sh1]++; }
        }));
        l1t.push_back(timed(n, NT, [&](size_t t, size_t a, size_t b) {
            uint32_t *sp = sc[t].data();
            for (size_t i = a; i < b; i++) {
                const int64_t x = v[i];
                if (x >= l1lo[0] && x <= l1hi[0]) sp[((U)x - b1) >> sh1]++;
            }
        }));
    }
    double l1w_ms = med(l1w), l1t_ms = med(l1t);

    // ---------- level 2: nh == 2, general loop, Q1 and Q3 bins ----------
    U    base2[2] = {(U)q1lo, (U)q3lo};
    U    span2[2] = {(U)((1 << sh1) - 1), (U)((1 << sh1) - 1)};
    int64_t lo2[2] = {q1lo, q3lo};
    int64_t hi2[2] = {q1lo + (1 << sh1) - 1, q3lo + (1 << sh1) - 1};
    const unsigned sh2 = 0;

    std::vector<double> l2w, l2t;
    for (int r = 0; r < reps; r++) {
        l2w.push_back(timed(n, NT, [&](size_t t, size_t a, size_t b) {
            uint32_t *sp = sc[t].data();
            for (size_t i = a; i < b; i++) {
                const int64_t x = v[i];
                for (size_t h = 0; h < 2; h++) {
                    const U off = (U)x - base2[h];
                    if (off <= span2[h]) sp[h * BINS + (size_t)(off >> sh2)]++;
                }
            }
        }));
        l2t.push_back(timed(n, NT, [&](size_t t, size_t a, size_t b) {
            uint32_t *sp = sc[t].data();
            for (size_t i = a; i < b; i++) {
                const int64_t x = v[i];
                for (size_t h = 0; h < 2; h++) {
                    if (x >= lo2[h] && x <= hi2[h])
                        sp[h * BINS + (size_t)(((U)x - base2[h]) >> sh2)]++;
                }
            }
        }));
    }
    double l2w_ms = med(l2w), l2t_ms = med(l2t);

    std::printf("%-34s %9s %9s %9s\n", "histogram pass", "wrap ms", "trad ms", "trad/wrap");
    std::printf("%-34s %9.2f %9.2f %8.2fx\n", "level 1  (nh=1, all in range)", l1w_ms, l1t_ms, l1t_ms / l1w_ms);
    std::printf("%-34s %9.2f %9.2f %8.2fx\n", "level 2  (nh=2, Q1+Q3 bins)", l2w_ms, l2t_ms, l2t_ms / l2w_ms);

    const double qw = mm_ms + l1w_ms + l2w_ms, qt = mm_ms + l1t_ms + l2t_ms;
    std::printf("\n%-34s %9.2f %9.2f %8.2fx   (+%.1f ms)\n", "=> quart total (minmax+L1+L2)", qw, qt,
                qt / qw, qt - qw);

    uint64_t keep = 0; for (auto s : sink) keep ^= s;
    std::printf("\n(checksum %llu)\n", (unsigned long long)keep);
    return 0;
}
