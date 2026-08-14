# Restoring this working tree after a cluster wipe

Everything in this directory exists because some of the work does **not** live in a repo we can push
to. Read this first after a reset.

## 1. Clone and check out the exact submodule chain

```bash
git clone https://github.com/celeris-labs/oasis.git ~/oasis
cd ~/oasis
git checkout feature/iqr-integration
git submodule update --init --recursive
```

`patches/SUBMODULE-PINS.txt` records the exact commit of every submodule at capture time. Verify
against it — the chain is four deep and a drift anywhere in it has cost days before:

```
oasis → parcore → libstf → coyote
```

## 2. Re-apply the Coyote P&R patch — THIS IS THE IMPORTANT ONE

`parcore/libstf/coyote` points at **`fpgasystems/Coyote`**, a third-party upstream we cannot push to,
so the change is stored here as a patch instead of as a commit.

```bash
cd ~/oasis/parcore/libstf/coyote
git apply ~/oasis/patches/coyote-pnr_shell-SSI_SpreadSLLs.patch
git diff --stat        # expect: scripts/impl/pnr_shell.tcl.in | 17 +++++++++++++++--
```

**What it does and why it must not be lost.** It adds an `OASIS_PLACE_DIRECTIVE` environment-variable
override to `place_design` in `scripts/impl/pnr_shell.tcl.in`. Vivado's ML predictor otherwise picks
`SSI_BalanceSLRs`, which balances *cells* and is blind to SLR crossings. Forcing `SSI_SpreadSLLs` was
worth **+0.338 ns of WNS**, and it is also what made removing HBM safe — under `BalanceSLRs`, removing
HBM cost 0.66–0.68 ns twice, because HBM had become an accidental floorplan anchor.

`pnr_shell.tcl` is **generated** from this `.tcl.in` at cmake time, so editing `hardware/build-NN/`
does nothing. Every future bitstream must be built with:

```bash
export OASIS_PLACE_DIRECTIVE=SSI_SpreadSLLs
./scripts/synthesize.sh --no-rdma --device u55c --decoders 1
# verify ~2 h in:
grep -m1 "OASIS: place_design" hardware/build-NN/bitgen.log
```

Without the env var the ML predictor reverts and HBM-out re-measures the old wrong ≈ −2.15 ns answer.

## 3. What is NOT in git, and what it costs to rebuild

| artifact | where it was | recovery |
|---|---|---|
| **bitstreams** (`hardware/build-NN/bitstreams/*.bit`, 43 MB each) | gitignored by `build*` | **overnight re-synthesis**, and only correct with the env var above |
| benchmark datasets (`~/datasets/*`, ~4 GB) | never in git | regenerate: `bench/gen_size_sweep.sh`, `bench/gen_card_sweep.sh`, `bench/gen_codec_sweep.sh` (minutes) |
| the 7 real datasets (taxi, tpch, sf10) | `~/datasets/*.parquet` | re-download / re-derive; see `bench/medians.py` `DATASETS` |
| `~/opt` install prefix | built from `software/` | `cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt …` |

Production bitstream at capture time was `hardware/build-29/bitstreams/cyt_top_b29_po.bit`
(WNS −0.518, HBM removed, 4/4 silicon gates).

## 4. Where the state lives

- `compact.md` — the resume doc. **Read it first**; it has the hardware arc, the benchmark protocol
  and the next actions.
- `micro_bench.md` — Tests 1/2/3/4 in full (2 = withdrawn, kept as rationale).
- `report_2807.md` — the 7 real datasets, end-to-end, plus the CPU baseline-hardening tables.
- `IQR_OASIS_PLAYBOOK.md` — repo map, bring-up commands, gotchas.
- `bench/` — every harness and every result CSV.
- `paper/figs/` — generated figures and LaTeX tables (`bench/paper_figs.py` regenerates them from
  embedded data, so they survive the datasets being gone).
