cmake_minimum_required(VERSION 3.16)
project(oasis_iqr_sim VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Run IqrRunner against the Coyote software-in-the-loop simulation (no FPGA).
#   cmake -S examples/iqr_sim -B examples/iqr_sim/build -DEN_SIMULATION=ON -DCMAKE_PREFIX_PATH=$HOME/opt
#   cmake --build examples/iqr_sim/build -j
#   COYOTE_SIM_DIR=$PWD/hardware/build-sim ./examples/iqr_sim/build/iqr_sim
option(EN_SIMULATION "Link against the Coyote simulation cThread (no FPGA required)" OFF)

if(EN_SIMULATION)
    # The sim cThread starts Vivado in the background and talks to the RTL over named pipes.
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../parcore/libstf/coyote/sim/sw coyote)
    add_compile_definitions(EN_SIMULATION)
else()
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../parcore/libstf/coyote/sw coyote)
endif()

# Pulls in libstf + parcore (and links them against whichever Coyote target is already defined).
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../software oasis)

add_executable(iqr_sim src/main.cpp)
target_link_libraries(iqr_sim PRIVATE Coyote libstf parcore oasis)
