# Bitstream index — what is saved, what is not, and what each one is worth

`hardware/build-NN/` is gitignored (`build*`), so **no bitstream is in git unless force-added.** Two
are, via git-LFS. This file records the rest so that after a cluster wipe you know exactly what you
have, what you lost, and whether losing it matters.

## In git (LFS) — recoverable and flashable

| file | md5 | WNS | status |
|---|---|--:|---|
| `build-29/bitstreams/cyt_top_b29_po.bit` | `11e35b5d31309520855283075de5ee49` | **−0.518** | ⭐ **PRODUCTION.** build-29 + post-route phys_opt ladder. Validated **4/4 on silicon** |
| `build-28/bitstreams/cyt_top_ssi_spreadslls.bit` | `f429afb3fd687bb73ebe396a44bda114` | −0.657 | **FALLBACK.** The only *other* bitstream validated 4/4 on silicon. Kept because production ships with 1 ps of hold margin |

Both were built with **`OASIS_PLACE_DIRECTIVE=SSI_SpreadSLLs`** — see `patches/RESTORE.md`. Without
that override Vivado's ML predictor picks `SSI_BalanceSLRs` and you get a different, worse design.

```bash
# after a fresh clone the LFS smudge filter fetches these automatically; verify before flashing:
md5sum hardware/build-29/bitstreams/cyt_top_b29_po.bit
```

## NOT in git — regenerable only by overnight re-synthesis

Deliberate: each is ~65 MB and GitHub's free LFS tier is 1 GB. Storing all 21 on-disk bitstreams
would be ~1.3 GB and blow the quota. These are recorded rather than stored.

| file | md5 (as built) | WNS | why it existed |
|---|---|--:|---|
| `build-29/bitstreams/cyt_top.bit` | `4d195dc0a1f3785903c7229ad3898de3` | −0.553 | build-29 before the phys_opt ladder |
| `build-28/bitstreams/cyt_top.bit` | `46b6ab77a4fa2ca3fbea0a3ad027c7d0` | −0.995 | build-28 under the ML-chosen `SSI_BalanceSLRs` |
| `build-23/bitstreams/cyt_top.bit` | `a33161334b78a33055a9beb01e6708eb` | −1.879 | the long-time production bitstream; all of `report_2807.md` was measured on it |
| `build-2x/bitstreams/cyt_top_{extratimingopt,ssi_balanceslls,ssi_spreadlogic_high,altspreadlogic_high}.bit` | — | worse | P&R directive sweep arms; superseded, no reason to keep |
| `*_pblock_inst_shell_partial.bit` | — | — | partial-reconfiguration variants; the full `cyt_top*.bit` is what `program_hacc_local.sh` consumes |

⚠️ **`report_2807.md`'s numbers belong to build-23, which is NOT saved.** If those measurements ever
need re-running, the bitstream must be rebuilt from the pinned source — or the report re-measured on
build-29 and re-labelled. The microbenchmarks (`micro_bench.md`, Tests 1–5) are all on build-29.

## Flashing after a restore

The programming script consumes exactly two files: a bitstream and the driver `.ko`. The driver is a
**build artifact and is deliberately not stored** — it is vermagic-pinned (ours: `6.8.0-136-generic`)
and must be rebuilt on any kernel change regardless. Its source is tracked inside the `coyote`
submodule.

```bash
cd ~/oasis && git submodule update --init --recursive
cd parcore/libstf/coyote/driver && make && cd ~/oasis      # ~1 min, builds against running kernel
module load vivado/2024.2
bash parcore/libstf/coyote/util/program_hacc_local.sh \
     hardware/build-29/bitstreams/cyt_top_b29_po.bit \
     parcore/libstf/coyote/driver/build/coyote_driver.ko 1
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages   # reprogram clears them
cat /sys/kernel/coyote_sysfs_0/cyt_attr_cnfg | grep "enabled memory"          # 0 = build-29 (HBM out)
```

`uname -r` must match the driver's vermagic. If it does not, rebuild the driver **on that node** —
do not switch nodes.

## ⚠️ Before any upstream PR

Both LFS commits are marked in their messages as **commits to drop**. A 65 MB LFS object is fine in a
private backup and unacceptable in a pull request to `celeris-labs/oasis`.
