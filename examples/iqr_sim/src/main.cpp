// Drives the IQR_detection operator end-to-end through OasisContext + IqrRunner, against either a
// real FPGA or the Coyote software-in-the-loop simulation (EN_SIMULATION). The cThread is swapped
// transparently, so this is the exact production software path. Validates the co-resident IQR lane
// added to vfpga_top.svh (S2).

#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <vector>

#include <libstf/memory_pool.hpp>

#include "oasis/iqr_runner.hpp"
#include "oasis/oasis_context.hpp"

// ---- reference model: mirrors IQR_detection (256 bins; Q1/Q3 + 1.5*IQR fences, integer math) ----
static int value_to_bin(int64_t v, int nb, int bs, int64_t bmin) {
    int64_t s = (v - bmin) >> bs;
    if (s < 0) return 0;
    if (s >= nb) return nb - 1;
    return static_cast<int>(s);
}

static std::vector<int> model_flags(const std::vector<int64_t> &d, int nb, int bs, int64_t bmin) {
    std::vector<int64_t> hist(nb, 0);
    for (auto v : d) hist[value_to_bin(v, nb, bs, bmin)]++;
    int64_t total = static_cast<int64_t>(d.size());
    auto    binval = [&](int b) { return bmin + (static_cast<int64_t>(b) << bs); };
    int64_t q1 = binval(nb - 1), q3 = binval(nb - 1), cum = 0;
    bool    q1f = false, q3f = false;
    for (int b = 0; b < nb; b++) {
        cum += hist[b];
        if (!q1f && cum * 4 >= total) { q1 = binval(b); q1f = true; }
        if (!q3f && cum * 4 >= 3 * total) { q3 = binval(b); q3f = true; }
    }
    int64_t iqr = q3 - q1, lo = q1 - iqr - (iqr >> 1), hi = q3 + iqr + (iqr >> 1);
    std::vector<int> f;
    for (auto v : d) f.push_back((v < lo || v > hi) ? 1 : 0);
    return f;
}

int main() {
    using namespace oasis;

    // 1. Context. In sim use a SimpleMemoryPool (host/card memory is simulated); on hardware the
    //    huge-page pool. OasisContext::init builds the (sim or real) cThread transparently.
#ifdef EN_SIMULATION
    auto pool = std::make_shared<libstf::SimpleMemoryPool>();
#else
    auto pool = std::make_shared<libstf::HugePageMemoryPool>();
#endif
    OasisContext::init(pool);
    auto &ctx = OasisContext::ctx();

    std::cout << "IQR present: " << (ctx.isIQRPresent() ? "yes" : "no")
              << ", IQR stream = " << ctx.iqrStream() << std::endl;
    if (!ctx.isIQRPresent()) {
        std::cerr << "Bitstream has no IQR config block -- did the design build with the IQR lane?\n";
        return 2;
    }

    // 2. Test column: a tight cluster (7..9) with two clear outliers (0 and 15).
    std::vector<int64_t> data = {0, 7, 8, 8, 9, 7, 8, 9, 8, 7, 9, 8, 7, 8, 9, 15};
    const size_t         n    = data.size();

    // 3. DMA-mapped input buffer holding the column.
    void *in  = nullptr;
    auto  st = ctx.memory_pool()->allocate(n * sizeof(int64_t), &in);
    if (!st.ok()) {
        std::cerr << "input allocation failed: " << st.message() << std::endl;
        return 1;
    }
    ctx.tlb_manager()->ensure_tlb_mapping(in, n * sizeof(int64_t));
    std::memcpy(in, data.data(), n * sizeof(int64_t));

    // 4. Run IQR: explicit window (bin_min=0, bin_shift=0), unsigned -- matches the model below.
    IqrRunner runner(ctx, /*is_signed=*/false, /*auto_window=*/false, /*bin_min=*/0, /*bin_shift=*/0);
    auto      res = runner.run({{in, n * sizeof(int64_t)}});

    // Count-loss diagnostics: the chain N >= accepted >= committed >= total pinpoints any loss
    // stage on silicon (input/DMA, coalescing, or the BRAM read-after-write hazard). On a clean
    // run all four equal N and collisions == 0.
    std::cout << "histogram_total = " << res.histogram_total << "  (expect " << n << ")\n"
              << "diagnostics: accepted=" << res.accepted << " committed=" << res.committed
              << " total=" << res.histogram_total << " (expect " << n << ")"
              << "  flushes=" << res.flushes << " collisions=" << res.collisions << "\n";
    if (res.accepted   < n)             std::cout << "  -> LOSS at input/DMA (accepted < N)\n";
    if (res.committed  < res.accepted)  std::cout << "  -> LOSS in coalescing (committed < accepted)\n";
    if (res.histogram_total < res.committed)
        std::cout << "  -> LOSS in BRAM read-modify-write hazard (total < committed), collisions="
                  << res.collisions << "\n";
    std::cout << std::flush;

    // 5. Unpack the packed flag bitmask: element i -> byte i/8, bit i%8 (LSB-first).
    const uint8_t   *mask = static_cast<const uint8_t *>(res.flags->ptr);
    std::vector<int> dev(n);
    for (size_t i = 0; i < n; i++) {
        dev[i] = (mask[i >> 3] >> (i & 7)) & 1u;
    }

    // 6. Compare against the reference model (1024 bins, the production NUM_BINS).
    auto exp      = model_flags(data, 1024, 0, 0);
    int  mismatch = 0;
    for (size_t i = 0; i < n; i++) {
        if (dev[i] != exp[i]) {
            mismatch++;
            std::cout << "  mismatch i=" << i << " v=" << data[i] << " device=" << dev[i]
                      << " model=" << exp[i] << std::endl;
        }
    }
    std::cout << "Mismatches: " << mismatch << std::endl;
    std::cout << (mismatch == 0 ? "PASSED: IQR runs end-to-end against the simulated FPGA"
                                : "FAILED: device flags do not match the model")
              << std::endl;
    return mismatch == 0 ? 0 : 1;
}
