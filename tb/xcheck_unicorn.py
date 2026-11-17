# cross-check the Python ISS against Unicorn (QEMU-based RV64 emulator), whole programs
#   usage: xcheck_unicorn.py N [mode]     (mode: '' | loop | rvc, optionally +c for RVC re-layout)
# FP programs use single precision (NaN-boxing, which QEMU 5.0 predates): see xcheck_fp_unicorn.py
import sys
from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV64
from unicorn.riscv_const import UC_RISCV_REG_X1, UC_RISCV_REG_F0, UC_RISCV_REG_MSTATUS
import gen
mode = sys.argv[2] if len(sys.argv) > 2 else ''
bad = 0
for seed in range(1, int(sys.argv[1]) + 1):
    code, dinit = gen.build(seed, mode)
    x, mem, n, _, f = gen.iss(code, dmem_init=dinit)
    halt = gen.iss.last_pc
    uc = Uc(UC_ARCH_RISCV, UC_MODE_RISCV64)
    uc.mem_map(0, 0x10000)
    uc.mem_write(0, code)
    # program data lives at 0x400..0x7ff (code is below 0x400)
    uc.mem_write(0x400, b''.join(v.to_bytes(8, 'little') for v in dinit)[0x400:2048])
    uc.reg_write(UC_RISCV_REG_MSTATUS, uc.reg_read(UC_RISCV_REG_MSTATUS) | (1 << 13))   # FS = Initial
    uc.emu_start(0, halt)
    ux = [0] + [uc.reg_read(UC_RISCV_REG_X1 + i - 1) for i in range(1, 32)]
    uf = [uc.reg_read(UC_RISCV_REG_F0 + i) for i in range(32)]
    um = uc.mem_read(0x400, 2048 - 0x400)
    im = b''.join(v.to_bytes(8, 'little') for v in mem)[0x400:2048]
    if ux != x or uf != f or bytes(um) != im:
        bad += 1; print('mismatch seed', seed)
        for i in range(32):
            if ux[i] != x[i]: print('  x%d iss %016x uc %016x' % (i, x[i], ux[i]))
            if uf[i] != f[i]: print('  f%d iss %016x uc %016x' % (i, f[i], uf[i]))
print(f'{int(sys.argv[1]) - bad}/{sys.argv[1]} seeds ({mode or "rand"}): ISS == Unicorn')
