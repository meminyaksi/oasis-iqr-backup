// Validates the shipped ParallelSortPairs against std::sort: exact same ordering AND the same
// multiset of (value,count) pairs, across sizes that straddle every internal threshold (the 1<<15
// serial cutoff, run counts that don't divide n, odd tails in the merge tree).
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>
#include <random>
#include <thread>
#include <utility>
#include <vector>
#include "sort_core.inc"

int main() {
    std::mt19937_64 rng(20260724);
    bool ok = true; size_t cases = 0;
    std::vector<size_t> sizes = {0,1,2,3,4095,4096,4097,32767,32768,32769,
                                 100000,262144,262145,933900,1351462};
    for (size_t nt : {1ul, 4ul, 32ul}) for (size_t n : sizes) {
        for (int mode = 0; mode < 4; mode++) {
            std::vector<std::pair<int64_t,uint64_t>> a(n);
            for (size_t i = 0; i < n; i++) {
                int64_t key;
                switch (mode) {
                    case 0: key = (int64_t)rng(); break;                    // full range
                    case 1: key = (int64_t)(rng() % 1000) - 500; break;     // many duplicate keys
                    case 2: key = (int64_t)i; break;                        // already sorted
                    default: key = (int64_t)(n - i); break;                 // reverse sorted
                }
                a[i] = {key, 1 + (rng() % 100)};
            }
            auto b = a;
            ParallelSortPairs<int64_t>(a.data(), a.size(), nt);
            std::stable_sort(b.begin(), b.end(),
                [](const auto &x, const auto &y){ return x.first < y.first; });
            // keys must be in the same order
            bool bad = false;
            for (size_t i = 0; i < n; i++) if (a[i].first != b[i].first) { bad = true; break; }
            // and no pair may be lost or duplicated: compare full multisets
            if (!bad) {
                auto sa = a, sb = b;
                std::sort(sa.begin(), sa.end()); std::sort(sb.begin(), sb.end());
                if (sa != sb) bad = true;
            }
            if (bad) { std::printf("FAIL n=%zu nt=%zu mode=%d\n", n, nt, mode); ok = false; }
            cases++;
        }
    }
    std::printf("%s  (%zu cases)\n", ok ? "PARALLEL SORT OK: order + multiset identical to std::sort"
                                       : "FAILURES", cases);
    return ok ? 0 : 1;
}
