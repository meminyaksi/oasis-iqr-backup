package oasis;

import libstf::vaddress_t;
import libstf::size_t;

parameter longint unsigned OASIS_SYSTEM_ID = 64'h0A515;

parameter int NUM_READ_REQ_CONFIG_REGS = 2;
parameter longint unsigned READ_REQ_CONFIG_ID = 64'h2f966a70f04c0e93;

// IQR_detection config block. ID bytes spell "IQRDETCT" and MUST equal the SW oasis::IQR_CONFIG_ID
// (software/oasis/iqr_config.hpp). 7 read regs: [0]=id, [1..4]=profiler cycles, [5]=dbg_total,
// [6]=clear_seq. 4 write regs: [0]=bin_min, [1]=bin_shift, [2]=is_signed, [3]=clear pulse.
parameter int NUM_IQR_CONFIG_REGS = 7;
parameter longint unsigned IQR_CONFIG_ID = 64'h4951524445544354;

typedef struct packed {
    vaddress_t vaddr;
    size_t     len;
} read_req_t;

endpackage
