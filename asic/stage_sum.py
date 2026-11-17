#!/usr/bin/env python3
# worst arrival per pipeline-register group (classified by the D net name of the endpoint flop)
import re, sys
net = open(sys.argv[1]).read()
dn = {}
for m in re.finditer(r'(DFF\w+)\s+(\S+)\s*\((.*?)\);', net, re.S):
    d = re.search(r'\.D\(([^)]*)\)', m.group(3))
    dn[m.group(2)] = d.group(1).strip() if d else '?'
best = {}
for l in open('sta_stage_end.rpt'):
    m = re.match(r'^(\S+)\s+\(.*?\)\s+([-\d.]+)\s+([-\d.]+)', l)
    if not m or m.group(1) == 'Endpoint': continue
    ep, arr = m.group(1), float(m.group(3))
    inst = ep.rsplit('/', 1)[0]
    name = dn.get(inst, ep)
    g = re.sub(r'\s*\[\d+\]', '', name).replace('\\', '')
    g = re.sub(r'\.(nrm1|be1)$', '', g)
    if g not in best or arr > best[g][0]: best[g] = (arr, name)
for g, (a, n) in sorted(best.items(), key=lambda x: -x[1][0])[:25]:
    print(f"{a:7.1f} ps {a/19.5:6.1f} FO4  {g}")
