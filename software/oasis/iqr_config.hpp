#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <cstdint>
#include <memory>

namespace oasis {

// Config id the IQR_detection vFPGA region advertises (register 0 of its
// ConfigReadRegisterFile). This is the HARDWARE <-> SOFTWARE contract: the IQR region in the
// co-resident oasis bitstream must report this exact value, or GlobalConfig::get_config<IqrConfig>()
// will not bind. The bytes spell "IQRDETCT" (I,Q,R,D,E,T,C,T) so it is unique and self-documenting.
//
// (In standalone celeris the IQR block reused CELERIS_SYSTEM_ID as its config id because IQR was the
// whole design. In oasis IQR is one config block among several -- ParCore decoder, MemConfig,
// ReadReq -- so it gets its own id, like READ_REQ_CONFIG_ID does.)
constexpr uint64_t IQR_CONFIG_ID = 0x4951524445544354ull;

/**
 * Host-side control panel for the IQR_detection vFPGA operator (the histogram + quartile outlier
 * detector). A thin libstf::Config: every accessor is a single CSR register read/write.
 *
 * Register map (matches hardware/src/hdl/aggregation/IQR_detection.sv via its config block):
 *
 *   READ side (StreamProfiler counters + debug):
 *     reg 0 = config id (== IQR_CONFIG_ID, checked by GlobalConfig)
 *     reg 1 = handshake cycles (productive input beats)
 *     reg 2 = starved cycles   (input valid low mid-stream)
 *     reg 3 = stalled cycles   (input backpressured: QUARTILES + FLAG)
 *     reg 4 = idle cycles      (gap between the two passes)
 *     reg 5 = histogram grand total of the last run (debug: == N iff banks were zeroed)
 *     reg 6 = clear-completion counter (advances once per finished host clear sweep)
 *
 *   WRITE side (runtime window + control):
 *     reg 0 = bin_min   (raw 64-bit pattern; HW interprets signed when set_signed(true))
 *     reg 1 = bin_shift (bin width = 2**bin_shift)
 *     reg 2 = is_signed (1/0)
 *     reg 3 = clear pulse (re-arm the histogram clear sweep before a run)
 *
 * The FPGA computes Q1/Q3 and the 1.5*IQR fences itself between the two passes -- the host never
 * touches the histogram. Its only jobs are: write the window (bin_min/bin_shift/is_signed), pulse
 * the clear, and read back the profiler/debug counters.
 */
class IqrConfig : public libstf::Config {
  public:
    IqrConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
        : libstf::Config(cthread, addr_offset, num_regs) {}

    // -- read side: StreamProfiler cycle counters (free-running, cumulative since load) ----------
    uint64_t handshake_cycles() { return read_register(1).value(); }
    uint64_t starved_cycles()   { return read_register(2).value(); }
    uint64_t stalled_cycles()   { return read_register(3).value(); }
    uint64_t idle_cycles()      { return read_register(4).value(); }

    // Debug: histogram grand total of the last run (== element count iff the banks were properly
    // zeroed; > N reveals cross-run residue).
    uint64_t histogram_total()  { return read_register(5).value(); }

    // Clear-completion counter: advances once per completed host clear sweep. Used to fence the
    // posted clear write ahead of the input DMA (see IqrRunner::run).
    uint64_t clear_seq()        { return read_register(6).value(); }

    // -- write side: runtime window parameters + control -----------------------------------------
    // bin_min is sent as its raw 64-bit pattern (the HW interprets it signed when set_signed(true)).
    void set_bin_min(int64_t bin_min)  { write_register(libstf::ConfigRegister(0, static_cast<uint64_t>(bin_min))); }
    void set_bin_shift(uint64_t shift) { write_register(libstf::ConfigRegister(1, shift)); }
    void set_signed(bool is_signed)    { write_register(libstf::ConfigRegister(2, is_signed ? 1u : 0u)); }

    // Re-arm the histogram clear sweep so the next run starts from a zeroed histogram.
    void clear_histogram()             { write_register(libstf::ConfigRegister(3, 1u)); }

    static constexpr uint64_t ID = IQR_CONFIG_ID;
};

} // namespace oasis
