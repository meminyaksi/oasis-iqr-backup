# P&R sweep harnesses

These four scripts drove the timing-closure arc that took WNS from **−1.879 ns to −0.518 ns**. They
originally lived inside `hardware/build-NN/`, which is **gitignored by `build*`** — so they were one
cluster wipe away from being lost, even though `compact.md` refers to them. They live here now
because they are reusable tools, not build outputs.

**To use one, copy it into the build directory you want to sweep and run it there** — they resolve
checkpoints (`shell_opted.dcp`, `shell_placed_*.dcp`) relative to the working directory:

```bash
cp hardware/pnr/pnr_reseed.tcl hardware/build-NN/
cd hardware/build-NN && vivado -mode batch -source pnr_reseed.tcl
```

| script | what it does |
|---|---|
| `pnr_reseed.tcl` | place-directive sweep from `shell_opted.dcp`. Tagged output per directive, `set_param general.maxThreads`, writes a tagged bitstream automatically when a run improves. |
| `route_sweep.tcl` | route-directive sweep from a **fixed** placement (`shell_placed_ssi_spreadslls.dcp`), so routing is the only variable. |
| `physopt_iterate.tcl` | post-route phys_opt ladder. Re-opens the best checkpoint per attempt, **rejects any directive that breaks hold** (WHS < 0), and writes the bitstream immediately after the ladder summary. This is the build-29 version — build-28's crashed before its end-of-script `write_bitstream`. |
| `status.sh` | multi-run status across concurrent sweeps. Filters lines containing `$` because Vivado echoes the `.tcl` source, which otherwise produces nonsense like `WNS = $wns ns`; reads only `reseed.log` / `physopt.log`, never `vivado_*.backup.log` (those go stale and were once misread as a live run). |

## ⚠️ Every future build needs the directive override

```bash
export OASIS_PLACE_DIRECTIVE=SSI_SpreadSLLs
```

Without it Vivado's ML predictor picks `SSI_BalanceSLRs`, which balances *cells* and is blind to SLR
crossings. `SSI_SpreadSLLs` was worth **+0.338 ns**, and it is also what made removing HBM safe —
under `BalanceSLRs`, removing HBM cost 0.66–0.68 ns twice. The override itself lives in a third-party
submodule and is stored as `patches/coyote-pnr_shell-SSI_SpreadSLLs.patch`; see `patches/RESTORE.md`.

Verify roughly 2 h into a build:

```bash
grep -m1 "OASIS: place_design" hardware/build-NN/bitgen.log
```

## `evidence/`

Kept because the paper cites these numbers and the build directories do not survive a wipe.

| file | why |
|---|---|
| `build-29-analysis.txt` | the timing summary for the production bitstream (WNS −0.518, WHS +0.001) |
| `build-29-utilization.txt` | LUT/FF/BRAM utilisation — the resource numbers for the paper |
| `build-29-place-directive.txt` | proof the `SSI_SpreadSLLs` override actually took effect in build-29 |

The full `timing_report.txt` (17 MB) is deliberately **not** kept — `analysis.txt` carries the summary,
and the detail is regenerable from the checkpoint.

⚠️ **Hold margin is 1 ps** (`WHS +0.001`). If silicon ever looks flaky, suspect hold, not setup: the
historical signature was *wandering* results across runs, and the precedent
(`IqrWideFlagPack` at +0.021 ns) lost ~10 % of histogram counts while being bit-exact in simulation.
