// Standalone verification of IqrRunner::repack_ragged_flags (software/oasis/iqr_runner.cpp).
//
// Obstacle 1 (ragged 8-multiple packer), host-side fix. When pass 2 streams several chunks (one
// Coyote transfer per row group, `last` only on the final chunk), FlagBitPacker shifts in 8 bits per
// beat regardless of keep, so each chunk c lands as 8*ceil(nv_c/8) bits -- its nv_c flags plus up to 7
// zero PAD bits when nv_c is not a multiple of 8. That is dense only if every chunk except the last is
// a multiple of 8; a ragged INTERMEDIATE chunk leaves pad bits mid-stream that shift every later flag.
// IqrRunner repacks that byte-padded-per-chunk buffer back into the dense 1-bit-per-element bitmask the
// emit loop expects. This test builds the device layout from known flags and checks the repack matches.
//
//   Build & run:  g++ -O2 -std=c++17 bench/repack_ragged_flags_test.cpp -o /tmp/repack_test && /tmp/repack_test
//
// IMPORTANT: repack() below MUST stay bit-identical to IqrRunner::repack_ragged_flags. If you change
// one, change the other. (There is no shared header to include without pulling in libstf/coyote.)
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <vector>
#include <random>
#include <cstdio>

// --- Mirror of IqrRunner::repack_ragged_flags (the loop body is identical) -------------------------
static void repack(const uint8_t *src, const std::vector<size_t> &nvs, uint8_t *dst, size_t dst_bytes) {
    std::memset(dst, 0, dst_bytes);
    auto put_bits = [](uint8_t *d, size_t bit, uint8_t bits, int n) {
        for (int j = 0; j < n; j++)
            if ((bits >> j) & 1u) d[(bit + j) >> 3] |= static_cast<uint8_t>(1u << ((bit + j) & 7));
    };
    size_t src_bit = 0, dst_bit = 0;
    for (size_t nv : nvs) {
        const uint8_t *sb   = src + (src_bit >> 3);   // src_bit is a multiple of 8
        size_t         full = nv >> 3;
        int            rem  = static_cast<int>(nv & 7);
        for (size_t b = 0; b < full; b++) { put_bits(dst, dst_bit, sb[b], 8); dst_bit += 8; }
        if (rem) { put_bits(dst, dst_bit, sb[full], rem); dst_bit += static_cast<size_t>(rem); }
        src_bit += ((nv + 7) / 8) * 8;
    }
}

int main() {
    std::mt19937 rng(1234);
    int fails = 0, cases = 0, ragged_cases = 0;

    auto run_trial = [&](const std::vector<size_t> &nvs) {
        size_t total = 0;
        for (size_t nv : nvs) total += nv;
        std::vector<uint8_t> flat(total);
        for (size_t i = 0; i < total; i++) flat[i] = rng() & 1;

        // Device layout: each chunk byte-padded to 8, chunks concatenated, final word padded to 512.
        size_t padded_bits = 0;
        for (size_t nv : nvs) padded_bits += ((nv + 7) / 8) * 8;
        std::vector<uint8_t> src((padded_bits + 511) / 512 * 64, 0);
        { size_t gi = 0, sbit = 0;
          for (size_t nv : nvs) {
              for (size_t k = 0; k < nv; k++, gi++)
                  if (flat[gi]) src[(sbit + k) >> 3] |= uint8_t(1u << ((sbit + k) & 7));
              sbit += ((nv + 7) / 8) * 8;
          } }

        // Truth: dense contiguous.
        size_t dst_bytes = (total + 511) / 512 * 64;
        std::vector<uint8_t> want(dst_bytes, 0);
        for (size_t i = 0; i < total; i++)
            if (flat[i]) want[i >> 3] |= uint8_t(1u << (i & 7));

        std::vector<uint8_t> got(dst_bytes, 0);
        repack(src.data(), nvs, got.data(), dst_bytes);

        bool ok = true;
        for (size_t i = 0; i < total && ok; i++)
            ok = ((got[i >> 3] >> (i & 7)) & 1) == ((want[i >> 3] >> (i & 7)) & 1);
        cases++;
        if (!ok) fails++;
        for (size_t i = 0; i + 1 < nvs.size(); i++) if (nvs[i] % 8) { ragged_cases++; break; }
    };

    // Directed edge cases: single chunk, all-aligned, ragged only on the last, ragged in the middle.
    run_trial({7});
    run_trial({8, 16, 24});
    run_trial({16, 16, 5});
    run_trial({5, 16, 16});         // ragged FIRST -> everything after shifts without the repack
    run_trial({3, 3, 3, 3, 3});
    run_trial({511, 1, 513});
    // Random fuzz.
    for (int t = 0; t < 20000; t++) {
        int n = 1 + int(rng() % 6);
        std::vector<size_t> nvs(n);
        for (int c = 0; c < n; c++) nvs[c] = 1 + rng() % 300;
        run_trial(nvs);
    }

    std::printf("cases=%d (ragged=%d) fails=%d %s\n", cases, ragged_cases, fails,
                fails ? "*** FAIL ***" : "ALL PASS");
    return fails ? 1 : 0;
}
