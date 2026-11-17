#!/usr/bin/env python3
# summarize sta_end.rpt: endpoint, arrival (ps), FO4 count; and the worst path's start/end
import re, sys
FO4 = float(sys.argv[1]) if len(sys.argv) > 1 else 19.5
rows = []
for l in open('sta_end.rpt'):
    m = re.match(r'^(\S+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)', l)
    if m and m.group(1) not in ('Endpoint',):
        req, arr = float(m.group(2)), float(m.group(3))
        rows.append((arr, m.group(1)))
rows.sort(reverse=True)
seen = set()
for arr, ep in rows:
    k = re.sub(r'\[\d+\]|_\d+_|\d+', '#', ep)
    if k in seen: continue
    seen.add(k)
    print(f"{arr:8.1f} ps {arr/FO4:6.1f} FO4  {ep}")
    if len(seen) >= int(sys.argv[2] if len(sys.argv) > 2 else 30): break
