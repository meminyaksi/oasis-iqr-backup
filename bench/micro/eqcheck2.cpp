// Where exactly do the two membership tests differ? Everything derived with the SHIPPED formulas:
//   sh: while ((range >> sh) >= BINS) sh++;   nbins = (range >> sh) + 1
//   span = ((nbins-1) << sh) | ((1<<sh) - 1)
#include <cstdint>
#include <cstdio>
#include <random>
#include <type_traits>
#include <vector>
constexpr size_t BINS = 1u << 12;
template <class T> static void probe(const char *name, T lo, T hi) {
    using U = typename std::make_unsigned<T>::type;
    const U base = (U)lo, range = (U)hi - (U)lo;
    unsigned sh = 0; while ((range >> sh) >= BINS) sh++;
    const size_t nbins = (size_t)(range >> sh) + 1;
    const U span = ((U)(nbins - 1) << sh) | ((U(1) << sh) - 1);
    const U over = span - range;                       // width of the window ABOVE hi that wrap admits

    std::vector<uint32_t> a(nbins, 0), b(nbins, 0);
    size_t n_extra = 0;
    std::mt19937_64 rng(99);
    for (int i = 0; i < 3000000; i++) {
        // deliberately oversample the [hi, hi+over] window so the difference cannot be missed by luck
        T x = (i % 2) ? (T)rng() : (T)((U)hi - 32 + (rng() % (over + 64)));
        const U off = (U)x - base;
        if (off <= span) a[(size_t)(off >> sh)]++;
        if (x >= lo && x <= hi) b[(size_t)(((U)x - base) >> sh)]++;
        if (off > range && off <= span) n_extra++;
    }
    size_t first_diff = nbins;
    for (size_t i = 0; i < nbins; i++) if (a[i] != b[i]) { first_diff = i; break; }
    std::printf("  %-30s sh=%2u nbins=%5zu  over=%6llu  extra_counted=%7zu  first_diff_bin=%s\n",
                name, sh, nbins, (unsigned long long)over, n_extra,
                first_diff == nbins ? "none" : (first_diff == nbins - 1 ? "LAST only" : "!! NOT LAST !!"));
}
int main() {
    probe<int64_t>("sf10 level 1", 90091, 10494950);
    probe<int64_t>("taxi level 1 (straddles 0)", -89900, 500000);
    probe<int64_t>("all negative", -1000000, -900000);
    probe<int64_t>("level 2, width-4096 bin", 2691051, 2695146);
    probe<uint64_t>("unsigned above INT64_MAX", (uint64_t)1 << 63, ((uint64_t)1 << 63) + 40950);
    probe<int64_t>("full 64-bit range", INT64_MIN, INT64_MAX);
    probe<int64_t>("3-level case (range 2^40)", 0, (int64_t)1 << 40);
    std::printf("\nover = span - range = how many values ABOVE hi the wrap test admits.\n"
                "Differences are confined to the LAST bin in every case; over==0 whenever sh==0.\n");
    return 0;
}
