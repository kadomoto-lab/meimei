#!/usr/bin/env python3
# insert buffer trees on high-fanout nets of a mapped netlist (written with -noexpr)
#   usage: fanout_buf.py <in.v> <out.v> [max fanout, default 8]
# ABC buffers only the logic it maps; flop outputs (state, valid, ...) stay unbuffered and a flop driving a few hundred
# loads shows a clk->Q of ~45 FO4, which hides the real depth of the stage. A placed design would get a buffer tree.
import re, sys
src, dst = sys.argv[1], sys.argv[2]
F = int(sys.argv[3]) if len(sys.argv) > 3 else 8
BUF = 'BUFx4f_ASAP7_75t_R'
OUT_PINS = {'Y', 'Q', 'QN', 'CON', 'SN', 'H', 'L'}
txt = open(src).read()
inst_re = re.compile(r'^(\s*)(\w+) (\S+) \(\n(.*?)\n\s*\);', re.S | re.M)
pin_re = re.compile(r'\.(\w+)\(([^()]*)\)')
insts = []                      # [cell, name, [[pin, net], ...]]
loads = {}                      # net -> [(inst index, pin index)]
for m in inst_re.finditer(txt):
    pins = [[p, n.strip()] for p, n in pin_re.findall(m.group(4))]
    insts.append([m.group(2), m.group(3), pins, m.span()])
    for k, (p, n) in enumerate(pins):
        if p not in OUT_PINS and p != 'CLK' and n and not n.startswith("1'"):
            loads.setdefault(n, []).append((len(insts) - 1, k))
new_wires, new_cells, cnt = [], [], 0
for net, ld in loads.items():
    if len(ld) <= F: continue
    level = ld
    while len(level) > F:
        nxt = []
        for c in range(0, len(level), F):
            cnt += 1
            w = f'_fb{cnt}_'
            new_wires.append(w)
            for (i, k) in level[c:c + F]:
                if i >= 0: insts[i][2][k][1] = w
                else: new_cells[-i - 1][1] = w
            new_cells.append([f'_fbi{cnt}_', None, w])      # [name, input net (set by the next level), output net]
            nxt.append((-len(new_cells), 0))
        level = nxt
    for (i, k) in level:
        if i >= 0: insts[i][2][k][1] = net
        else: new_cells[-i - 1][1] = net
# rebuild the instances (input nets of the new buffers were filled in as the levels went up)
out, pos = [], 0
for cell, name, pins, (a, b) in insts:
    out.append(txt[pos:a])
    body = ',\n'.join(f'    .{p}({n}{" " if n.startswith(chr(92)) else ""})' for p, n in pins)   # escaped names end with a space
    out.append(f'  {cell} {name} (\n{body}\n  );')
    pos = b
tail = txt[pos:]
bufs = ''.join(f'  {BUF} {n} (\n    .A({i}),\n    .Y({o})\n  );\n' for n, i, o in new_cells)
tail = tail.replace('endmodule', bufs + 'endmodule', 1)
head = ''.join(out)
head = re.sub(r'(\n\s*wire )', '\n' + ''.join(f'  wire {w};\n' for w in new_wires) + r'\1', head, count=1)
open(dst, 'w').write(head + tail)
print(f'{len(new_cells)} buffers on {sum(1 for l in loads.values() if len(l) > F)} nets', file=sys.stderr)
