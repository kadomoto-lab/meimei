# Embench-IoT on the meimei SoC

Embench is not vendored. Clone it and check out the 1.0 release (the one with published baseline data):

```sh
git clone https://github.com/embench/embench-iot ~/opt/src/embench/embench-iot
git -C ~/opt/src/embench/embench-iot worktree add ../embench-1.0 embench-1.0
make -C software/embench                      # build/<bench>/{app.elf,code.hex,data.hex}, EMBENCH=<tree> to override
software/embench/run_v80.py                   # all 19 on the V80, prints cycles / IPC / relative speed / score
make -C sim run CONFIG=small PROG=../software/embench/build/st   # same cycle counts in the RTL sim
```

- Build: Embench's `support/main.c` + `beebsc.c` + the benchmark sources + `boardsupport.c` (this directory), with the
  normal `software_tools` runtime (`-O2`, newlib-nano). `-DCPU_MHZ=1 -DWARMUP_HEAT=1` (Embench's defaults) and
  `-std=gnu17` (Embench predates C23: wikisort does `typedef uint8_t bool`)
- `start_trigger` / `stop_trigger` read the `cycle` / `instret` CSRs; `stop_trigger` prints
  `EMBENCH cycles=N instret=M`. The program exits with 0 when `verify_benchmark` passes
- Relative speed = `baseline_ms * 1000 / cycles` (Cortex-M4 baseline in `baseline-data/speed.json`, CPU_MHZ = 1 build),
  score = geometric mean
- **The Embench score is the geometric mean over the whole suite, so all 19 have to count.** With GCC 15.1, nbody is not
  measured as intended: `bodies_energy()` is pure, GCC 15 hoists it out of the 100-iteration loop and the benchmark runs
  772 instructions (speed 3,450, score 6.84 with a geometric SD of 5.4). GCC 14.4 does the same (`make COMP=gcc14`, full
  toolchain in `~/opt/riscv64-gcc14`): newer GCC proves the `sqrt` argument non-negative, drops the errno-setting libcall
  and then finds the function pure (GCC 12 does it too with `-fno-math-errno`). GCC 12.2 and clang 21 keep the loop, so for a
  full-suite score compile the benchmarks with one of them:

  ```sh
  make -C software/embench COMP=gcc12      # Vitis 2024.1's riscv64-unknown-elf-gcc 12.2 -> build-gcc12/
  make -C software/embench COMP=clang      # clang 21 (--target=riscv64-unknown-elf, newlib headers) -> build-clang/
  software/embench/run_v80.py --all --build build-gcc12
  ```

  Only the benchmark sources, `main.c`, `beebsc.c` and `boardsupport.c` use the other compiler; crt0, syscalls,
  newlib / libm and the link stay with GCC 15.1 (Vitis' GCC has no medany newlib-nano for 0x8000_0000).
  `run_v80.py` without `--all` leaves nbody out of the score
- The FP-heavy benchmarks (cubic, minver, st, nbody) score high because the M4 baseline has no double-precision FPU
