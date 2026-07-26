# CPU-baseline microbenchmarks (RESULTS.md §9.25)

Standalone — no DuckDB, no oasis, no FPGA. Build with the **shipping** flags so the codegen matches
what `oasis_iqr.cpp` actually gets (`-O3 -DNDEBUG`, deliberately **no** `-march=native`).

```sh
g++ -O3 -DNDEBUG -pthread -o wrap_ab2   wrap_ab2.cpp   && ./wrap_ab2 59986052 7 32   # [rows reps threads]
g++ -O3 -DNDEBUG          -o eqcheck2   eqcheck2.cpp   && ./eqcheck2
g++ -O3 -DNDEBUG -pthread -o exactness  exactness.cpp  && ./exactness                # exit 0 = all exact
```

| file | what it answers |
|---|---|
| `wrap_ab2.cpp` | step 11 A/B: unsigned-wrap vs traditional two-compare membership, in the shape of `AdvanceRankQueries`. Also prints the machine's pure-read ceiling, so it is visible whether a loop is at the memory wall. |
| `eqcheck2.cpp` | characterises where the two tests disagree: `span − range` per level, and that differences are confined to the **last bin** and vanish when `sh == 0`. |
| `exactness.cpp` | pastes the **shipped** `SelectQuartiles`/`AdvanceRankQueries` in verbatim (extracted from `oasis_iqr.cpp` into `shipped_core.inc`) and checks them against a brute-force sort on adversarial inputs. Regenerate the include with the snippet at the top of §9.25's notes if the source moves. |

`exactness.cpp` needs `shipped_core.inc`, which is the region of `oasis_iqr.cpp` from
`constexpr size_t IQR_CPU_HIST_BINS` to `// lo/hi for the 1.5*IQR rule`:

```sh
python3 - <<'PY'
src = open('../../extension/src/oasis_iqr.cpp').read()
a = src.index('constexpr size_t IQR_CPU_HIST_BINS'); b = src.index('// lo/hi for the 1.5*IQR rule')
open('shipped_core.inc','w').write(src[a:b])
PY
```

**Caveat:** these were run on `hacc-build-02` (pure-read ceiling 45.2 GB/s), not on the benchmark node
`alveo-u55c-10` (63 GB/s, §9.16). Ratios transfer; absolute ms do not.
