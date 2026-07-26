// RESULTS.md 9.30: why iqr_cpu_flags_groupby is SLOWER than the SQL it transliterates.
//
// Replicates the shipped GROUP BY phase from oasis_iqr.cpp and splits it into BUILD (parallel) and
// MERGE (serial), which the operator's single `group` timer hides. Then measures a radix-partitioned
// variant -- the shape DuckDB's hash aggregate actually uses -- to size the fix.
//
//   g++ -O3 -DNDEBUG -pthread -o groupby_ab groupby_ab.cpp && ./groupby_ab 59986052 1351462 32
//   (defaults are sf10's measured row count and distinct count)
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <thread>
#include <unordered_map>
#include <vector>

using clk = std::chrono::steady_clock;
static double ms_since(clk::time_point t) {
    return std::chrono::duration<double, std::milli>(clk::now() - t).count();
}

template <class F> static void par(size_t n, size_t nt, F &&fn) {
    if (n == 0) return;
    const size_t chunk = (n + nt - 1) / nt;
    std::vector<std::thread> ws;
    for (size_t t = 0; t < nt; t++) {
        size_t a = t * chunk; if (a >= n) break;
        ws.emplace_back([&fn, t, a, b = std::min(n, a + chunk)] { fn(t, a, b); });
    }
    for (auto &w : ws) w.join();
}

// ---------- A: exactly what ships -- per-thread unordered_map, then a SERIAL merge ----------
static void variant_shipped(const int64_t *v, size_t n, size_t nt, double &build_ms,
                            double &merge_ms, size_t &distinct) {
    std::vector<std::unordered_map<int64_t, uint64_t>> parts(nt);
    auto t0 = clk::now();
    par(n, nt, [&](size_t t, size_t a, size_t b) {
        auto &m = parts[t];
        m.reserve(1024);
        for (size_t i = a; i < b; i++) m[v[i]]++;
    });
    build_ms = ms_since(t0);

    auto t1 = clk::now();
    std::unordered_map<int64_t, uint64_t> all = std::move(parts[0]);
    for (size_t t = 1; t < nt; t++) {
        for (const auto &kv : parts[t]) all[kv.first] += kv.second;
        parts[t] = {};
    }
    merge_ms = ms_since(t1);
    distinct = all.size();
}

// ---------- B: radix-partitioned, so there is NO merge at all ----------
// Every thread scatters its slice into P partitions by hash; then each partition is aggregated
// independently by one thread. Partitions are disjoint by construction, so the combine step that
// dominates variant A simply does not exist. This is the shape a real hash aggregate uses.
static void variant_radix(const int64_t *v, size_t n, size_t nt, double &scatter_ms,
                          double &agg_ms, size_t &distinct) {
    const size_t P = 256; // partitions; 256 keeps each one well under L2 for D ~ 1.4M
    auto  hash = [](int64_t x) { uint64_t h = (uint64_t)x * 0x9E3779B97F4A7C15ull; return h ^ (h >> 29); };

    // pass 1: per-thread, per-partition counts, so the scatter can write into exact offsets
    auto t0 = clk::now();
    std::vector<std::vector<size_t>> cnt(nt, std::vector<size_t>(P, 0));
    par(n, nt, [&](size_t t, size_t a, size_t b) {
        for (size_t i = a; i < b; i++) cnt[t][hash(v[i]) & (P - 1)]++;
    });
    std::vector<size_t> pstart(P + 1, 0);
    for (size_t p = 0; p < P; p++) {
        size_t s = 0;
        for (size_t t = 0; t < nt; t++) s += cnt[t][p];
        pstart[p + 1] = pstart[p] + s;
    }
    std::vector<std::vector<size_t>> off(nt, std::vector<size_t>(P, 0));
    for (size_t p = 0; p < P; p++) {
        size_t run = pstart[p];
        for (size_t t = 0; t < nt; t++) { off[t][p] = run; run += cnt[t][p]; }
    }
    std::vector<int64_t> buf(n);
    par(n, nt, [&](size_t t, size_t a, size_t b) {
        auto local = off[t];
        for (size_t i = a; i < b; i++) buf[local[hash(v[i]) & (P - 1)]++] = v[i];
    });
    scatter_ms = ms_since(t0);

    // pass 2: one independent hash table per partition, fully parallel, NO merge
    auto t1 = clk::now();
    std::vector<size_t> dper(P, 0);
    std::atomic<size_t> next {0};
    std::vector<std::thread> ws;
    for (size_t t = 0; t < nt; t++) {
        ws.emplace_back([&] {
            std::unordered_map<int64_t, uint64_t> m;
            for (size_t p = next.fetch_add(1); p < P; p = next.fetch_add(1)) {
                m.clear();
                m.reserve((pstart[p + 1] - pstart[p]) / 4 + 16);
                for (size_t i = pstart[p]; i < pstart[p + 1]; i++) m[buf[i]]++;
                dper[p] = m.size();
            }
        });
    }
    for (auto &w : ws) w.join();
    agg_ms   = ms_since(t1);
    distinct = 0;
    for (size_t p = 0; p < P; p++) distinct += dper[p];
}

int main(int argc, char **argv) {
    const size_t n  = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 59986052;  // sf10 rows
    const size_t D  = argc > 2 ? std::strtoull(argv[2], nullptr, 10) : 1351462;   // sf10 distinct
    const size_t nt = argc > 3 ? std::strtoull(argv[3], nullptr, 10) : 32;

    // Values drawn uniformly from exactly D distinct keys, in sf10's measured value range.
    std::vector<int64_t> v(n);
    par(n, std::thread::hardware_concurrency(), [&](size_t t, size_t a, size_t b) {
        std::mt19937_64 rng(1234 + t);
        for (size_t i = a; i < b; i++) v[i] = 90091 + (int64_t)(rng() % D) * 7;
    });

    std::printf("n = %zu  distinct = %zu  threads = %zu\n\n", n, D, nt);

    double bm = 0, mm = 0, sm = 0, am = 0;
    size_t d1 = 0, d2 = 0;
    variant_shipped(v.data(), n, nt, bm, mm, d1);
    std::printf("A: SHIPPED (per-thread unordered_map + serial merge)\n");
    std::printf("   build (parallel) %9.1f ms\n", bm);
    std::printf("   merge  (SERIAL)  %9.1f ms   <-- %.0f%% of the phase\n", mm, 100 * mm / (bm + mm));
    std::printf("   total            %9.1f ms   distinct=%zu\n\n", bm + mm, d1);

    variant_radix(v.data(), n, nt, sm, am, d2);
    std::printf("B: RADIX-PARTITIONED (no merge step exists)\n");
    std::printf("   scatter          %9.1f ms\n", sm);
    std::printf("   aggregate (par)  %9.1f ms\n", am);
    std::printf("   total            %9.1f ms   distinct=%zu\n\n", sm + am, d2);

    if (d1 != d2) std::printf("   !! distinct mismatch %zu vs %zu\n", d1, d2);
    std::printf("B is %.2fx faster than A\n", (bm + mm) / (sm + am));
    return 0;
}
