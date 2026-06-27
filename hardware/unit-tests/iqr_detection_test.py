import random
from typing import List, Tuple

from coyote_test import fpga_test_case, fpga_register, fpga_stream, simulation_time

# Default operator parameters (match the defaults in vfpga-tops/iqr_detection_test.sv).
DEF_NUM_BINS = 16
DEF_BIN_SHIFT = 0
DEF_BIN_MIN = 0
DEF_IS_SIGNED = 0   # 0 = unsigned (non-negative data); 1 = signed (negatives allowed)


# ------------------------------------------------------------------------------
# Reference model -- mirrors IQR_detection bit-for-bit (integer math, no div/mul).
# Q1: first bin with 4*cumulative >= total. Q3: first bin with 4*cumulative >= 3*total.
# Fences use 1.5*IQR as IQR + (IQR>>1), exactly like the hardware.
# ------------------------------------------------------------------------------
def value_to_bin(value: int, num_bins: int, bin_shift: int, bin_min: int) -> int:
    shifted = (value - bin_min) >> bin_shift
    if shifted < 0:
        return 0
    if shifted >= num_bins:
        return num_bins - 1
    return shifted


def compute_histogram(values: List[int], num_bins: int, bin_shift: int, bin_min: int) -> List[int]:
    hist = [0] * num_bins
    for v in values:
        hist[value_to_bin(v, num_bins, bin_shift, bin_min)] += 1
    return hist


def bin_value(bin_index: int, bin_shift: int, bin_min: int) -> int:
    """Representative (lower-edge) value of a bin."""
    return bin_min + (bin_index << bin_shift)


def quartiles(hist: List[int], bin_shift: int, bin_min: int) -> Tuple[int, int]:
    num_bins = len(hist)
    total = sum(hist)
    q1 = bin_value(num_bins - 1, bin_shift, bin_min)
    q3 = bin_value(num_bins - 1, bin_shift, bin_min)
    q1_found = q3_found = False
    cumulative = 0
    for b, count in enumerate(hist):
        cumulative += count
        if not q1_found and cumulative * 4 >= total:
            q1, q1_found = bin_value(b, bin_shift, bin_min), True
        if not q3_found and cumulative * 4 >= 3 * total:
            q3, q3_found = bin_value(b, bin_shift, bin_min), True
    return q1, q3


def iqr_fences(values: List[int], num_bins: int, bin_shift: int, bin_min: int) -> Tuple[int, int]:
    hist = compute_histogram(values, num_bins, bin_shift, bin_min)
    q1, q3 = quartiles(hist, bin_shift, bin_min)
    iqr = q3 - q1
    lower = q1 - iqr - (iqr >> 1)   # 1.5*IQR = IQR + IQR>>1 (matches hardware)
    upper = q3 + iqr + (iqr >> 1)
    return lower, upper


def flags(values: List[int], num_bins: int, bin_shift: int, bin_min: int) -> List[int]:
    lower, upper = iqr_fences(values, num_bins, bin_shift, bin_min)
    return [1 if (v < lower or v > upper) else 0 for v in values]


def outliers(values: List[int], num_bins: int, bin_shift: int, bin_min: int) -> List[int]:
    f = flags(values, num_bins, bin_shift, bin_min)
    return [v for v, flag in zip(values, f) if flag]


# libstf type_t the StreamConfig decodes (BYTE_T=0, INT32_T=1, INT64_T=2, ...).
def _libstf_type_byte(stream_type: fpga_stream.StreamType) -> int:
    nbytes = fpga_stream.get_bytes_for_stream_type(stream_type)
    if nbytes == 4:
        return 1   # INT32_T
    if nbytes == 8:
        return 2   # INT64_T
    raise AssertionError("IQR_detection supports only 32- and 64-bit columns")


class IqrDetectionTest(fpga_test_case.FPGATestCase):
    """
    IQR_detection operator (histogram -> quartiles -> outlier flags), oasis sim port.

    The host streams the value column in TWICE: pass 1 builds the banked histogram and derives the
    Q1/Q3 fences in hardware, pass 2 re-streams the column and the operator emits one flag per
    element (1 = outlier, 0 = normal). The output is a same-length 0/1 column.
    """

    alternative_vfpga_top_file = "vfpga-tops/iqr_detection_test.sv"
    debug_mode = True

    def _run(
        self,
        data: List[int],
        stream_type: fpga_stream.StreamType = fpga_stream.StreamType.SIGNED_INT_64,
        num_bins: int = DEF_NUM_BINS,
        bin_shift: int = DEF_BIN_SHIFT,
        bin_min: int = DEF_BIN_MIN,
        is_signed: int = DEF_IS_SIGNED,
    ):
        assert len(data) > 0, "IQR_detection needs a non-empty column"
        assert is_signed or min(data) >= 0, "unsigned mode (is_signed=0) needs non-negative data"

        # The two-pass design (clear sweep + NUM_BINS quartile scan + column streamed twice) can
        # exceed the default sim window for large inputs; run until the operator actually finishes.
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())

        # Only emit defines for non-default params so default-window tests share one compilation.
        defines = {}
        if num_bins != DEF_NUM_BINS:
            defines["IQR_NUM_BINS_OVERWRITE"] = str(num_bins)
        if bin_shift != DEF_BIN_SHIFT:
            defines["IQR_BIN_SHIFT_OVERWRITE"] = str(bin_shift)
        if bin_min != DEF_BIN_MIN:
            defines["IQR_BIN_MIN_OVERWRITE"] = str(bin_min)
        if is_signed != DEF_IS_SIGNED:
            defines["IQR_IS_SIGNED_OVERWRITE"] = str(is_signed)
        if defines:
            self.set_system_verilog_defines(defines)

        # Data type in the StreamConfig's first register (offset 3: GlobalConfig reserves 0..2).
        type_reg = _libstf_type_byte(stream_type)
        self.write_register(fpga_register.vFPGARegister(3, bytearray([type_reg])))

        # Two identical transfers: pass 1 -> histogram, pass 2 -> flags.
        self.set_stream_input(0, fpga_stream.Stream(stream_type, data))
        self.set_stream_input(0, fpga_stream.Stream(stream_type, data))

        lower, upper = iqr_fences(data, num_bins, bin_shift, bin_min)
        print(
            f"\n[IQR_detection] NUM_BINS={num_bins} BIN_SHIFT={bin_shift} BIN_MIN={bin_min}"
            f"\n                N={len(data)}  fences=({lower}, {upper})"
            f"\n                outliers={outliers(data, num_bins, bin_shift, bin_min)}\n"
        )

        expected = flags(data, num_bins, bin_shift, bin_min)
        self.set_expected_output(0, fpga_stream.Stream(stream_type, expected))
        return super().simulate_fpga()

    # -- Functional cases ------------------------------------------------------
    def test_two_clear_outliers(self):
        # Cluster around 7..9 with two clear outliers (0 and 15). fences=(4,12).
        data = [0] + [7, 8, 8, 9, 7, 8, 9, 8, 7, 9, 8, 7, 8, 9] + [15]
        self._run(data)
        self.assert_simulation_output()

    def test_no_outliers(self):
        data = [8, 8, 9, 8, 9, 8, 9, 8, 8, 9, 8, 9, 8, 8, 9, 8]
        self._run(data)
        self.assert_simulation_output()

    def test_outliers_scattered(self):
        data = [8, 0, 8, 9, 15, 7, 8, 9, 0, 8, 7, 9, 8, 15, 8]
        self._run(data)
        self.assert_simulation_output()

    # -- Edge cases ------------------------------------------------------------
    def test_single_element(self):
        self._run([7])
        self.assert_simulation_output()

    def test_all_equal(self):
        self._run([8] * 32)
        self.assert_simulation_output()

    def test_partial_last_beat(self):
        # 19 elements -> last ndata beat is partial (trailing keep), with outliers.
        data = [0] + [7, 8, 9, 8, 7, 9, 8, 8, 9, 7, 8, 9, 8, 7, 9, 8, 8] + [15]
        self._run(data)
        self.assert_simulation_output()

    def test_clamp_high_values(self):
        # Values >= NUM_BINS-1 clamp into the last bin, but the flag compare uses the true value.
        data = list(range(0, 16)) + [20, 40, 100]
        self._run(data)
        self.assert_simulation_output()

    # -- Stress ----------------------------------------------------------------
    def test_multi_beat(self):
        random.seed(9)
        data = [random.randint(6, 10) for _ in range(0, 200)]
        for pos in (5, 50, 120, 199):
            data[pos] = 15 if pos % 2 == 0 else 0
        self._run(data)
        self.assert_simulation_output()
