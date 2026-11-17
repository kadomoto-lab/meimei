#!/usr/bin/env python3
# Split a flat $readmemh image into the per-bank files read by mm_imem / mm_dmem on the FPGA.
#   split_hex.py <image.hex> <words> <banks>   ->  <image.hex>.b00.hex, .b01.hex, ...
# word w goes to bank w % banks, row w // banks (missing words are 0)
import sys
src, words, banks = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
img, addr = {}, 0
width = 0
for tok in open(src).read().split():
    if tok.startswith('@'):
        addr = int(tok[1:], 16)
        continue
    img[addr] = tok
    width = max(width, len(tok))
    addr += 1
for b in range(banks):
    with open('%s.b%02d.hex' % (src, b), 'w') as f:
        for r in range(words // banks):
            f.write(img.get(r * banks + b, '0' * width).rjust(width, '0') + '\n')
