#!/usr/bin/env python3
# ELF64 -> memory images for the meimei SoC
#   code.hex: 32-bit words of IMEM (0x80000000..), data.hex: 64-bit words of DMEM (0x80010000..)
#   usage: elf2hex.py app.elf [outdir]
import struct, sys, os
IMEM, IMEM_SIZE = 0x80000000, 0x10000
DMEM, DMEM_SIZE = 0x80010000, 0x10000

def sections(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'\x7fELF' and d[4] == 2, 'not an ELF64 file'
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum = struct.unpack_from('<HH', d, 0x3a)
    for i in range(shnum):
        name, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', d, shoff + i * shentsize)
        if flags & 2 and typ != 8 and size:          # SHF_ALLOC, not SHT_NOBITS
            yield addr, d[off:off + size]

def main():
    elf = sys.argv[1]; out = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(elf))
    im, dm = bytearray(IMEM_SIZE), bytearray(DMEM_SIZE)
    iu = du = 0
    for addr, data in sections(elf):
        if IMEM <= addr and addr + len(data) <= IMEM + IMEM_SIZE:
            im[addr - IMEM:addr - IMEM + len(data)] = data; iu = max(iu, addr - IMEM + len(data))
        elif DMEM <= addr and addr + len(data) <= DMEM + DMEM_SIZE:
            dm[addr - DMEM:addr - DMEM + len(data)] = data; du = max(du, addr - DMEM + len(data))
        else:
            sys.exit('section at %#x (%d bytes) is outside IMEM / DMEM' % (addr, len(data)))
    iu = (iu + 3) // 4 * 4; du = (du + 7) // 8 * 8
    with open(os.path.join(out, 'code.hex'), 'w') as f:
        f.write(''.join('%08x\n' % struct.unpack_from('<I', im, a)[0] for a in range(0, max(iu, 4), 4)))
    with open(os.path.join(out, 'data.hex'), 'w') as f:
        f.write(''.join('%016x\n' % struct.unpack_from('<Q', dm, a)[0] for a in range(0, max(du, 8), 8)))
    print('%s: IMEM %d bytes, DMEM image %d bytes' % (elf, iu, du))

if __name__ == '__main__':
    main()
