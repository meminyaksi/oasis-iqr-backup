cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../parcore/libstf/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

find_package(CoyoteHW REQUIRED)

# Number of ColumnChunkDecoders. The number of streams is equal to this in local mode. If RDMA is 
# enabled, there will be an additional RDMA bypass stream for the RDMAFileSystem
set(N_DECODERS 1 CACHE STRING "Number of ColumnChunkDecoders (default=1)")

# Include Coyote's RDMA stack during synthesis (disable with -DENABLE_RDMA=OFF)
option(ENABLE_RDMA "Enable RDMA stack" ON)

# Number of vFPGAs (user applications)
set(N_REGIONS 1)
set(EN_STRM 1)

# Enable card-memory (HBM) streams so the IQR passes can read the decoded column from HBM instead
# of re-DMAing it from the host each pass. Adds axis_card_recv/send to the vFPGA + the HBM DMA path
# to the shell (and the EN_MEM-gated card model to the co-sim). N_CARD_AXI defaults to 1.
set(EN_MEM 1)
set(N_CARD_AXI 1)

if(ENABLE_RDMA)
    math(EXPR N_STREAMS "${N_DECODERS} + 1")
    set(EN_RDMA 1)
    set(N_RDMA_AXI ${N_STREAMS})
    set(N_STRM_AXI ${N_STREAMS})
else()
    set(EN_RDMA 0)
    # Local mode (sim): reserve one extra stream past the decoders for the IQR_detection lane.
    math(EXPR N_STRM_AXI "${N_DECODERS} + 1")
endif()

# Build with optimization, since timing closure can be difficult
set(COMP_CORES 64)
set(BUILD_OPT 1)

# Target FPGA device (override with -DFDEV_NAME=v80 for the Alveo V80)
set(FDEV_NAME u55c CACHE STRING "Target FPGA device (u55c, v80, ...)")

# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src iqr_app"
)

create_hw()
