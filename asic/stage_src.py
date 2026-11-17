#!/usr/bin/env python3
# worst arrival per pipeline register, classified by the RTL line of the endpoint flop (its src attribute)
#   usage: stage_src.py <netlist written without -noattr> <sv2v output the netlist came from> [sta_stage_end.rpt]
# (flop Q nets are anonymous after mapping, so stage_sum.py's D-net names often say nothing; the src attribute
#  points at the always block that holds the register, shown with the next lines of that block)
import re, sys
net = open(sys.argv[1]).read()
lines = open(sys.argv[2]).read().split('\n')
rpt = sys.argv[3] if len(sys.argv) > 3 else 'sta_stage_end.rpt'
src = {}
for m in re.finditer(r'\(\* src = "([^"]+)" \*\)\s*(DFF\w+)\s+(\S+)\s*\(', net):
    src[m.group(3)] = m.group(1)
best = {}
for l in open(rpt):
    m = re.match(r'^(\S+)\s+\(.*?\)\s+([-\d.]+)\s+([-\d.]+)', l)
    if not m or m.group(1) == 'Endpoint': continue
    ep, arr = m.group(1), float(m.group(3))
    inst = ep.rsplit('/', 1)[0]
    if inst in src:
        ln = int(src[inst].split('|')[0].split(':')[1].split('.')[0])
        key = ' / '.join(x.strip() for x in lines[ln-1:ln+2])[:100]
    else:
        key = re.sub(r'\[\d+\]', '', inst)          # output ports
    if key not in best or arr > best[key]: best[key] = arr
for g, a in sorted(best.items(), key=lambda x: -x[1])[:20]:
    print(f"{a:7.1f} ps {a/19.5:6.1f} FO4  {g}")
