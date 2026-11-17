#!/usr/bin/env python3
# merge Liberty files of one corner into one library: the header of the first file, the table
# templates of all files (deduplicated by name) and the cells of all files
import gzip, re, sys
out, ins = sys.argv[1], sys.argv[2:]
def rd(p):
    return (gzip.open(p, 'rt') if p.endswith('.gz') else open(p)).read()
def groups(t, kw):
    res = []
    for m in re.finditer(r'\n[ \t]*' + kw + r'\s*\(\s*([^)]*)\)\s*\{', t):
        d, k = 0, m.end() - 1
        while True:
            c = t[k]
            if c == '{': d += 1
            elif c == '}':
                d -= 1
                if d == 0: break
            k += 1
        res.append((m.group(1).strip(), m.start(), t[m.start():k+1]))
    return res
TK = r'(?:lu_table_template|power_lut_template|output_current_template|normalized_driver_waveform)'
first = rd(ins[0])
cells0 = groups(first, 'cell')
head = first[:cells0[0][1]]
have = {n for n, _, _ in groups(head, TK)}
extra, body = [], []
for f in ins:
    t = rd(f)
    for n, _, g in groups(t, TK):
        if n not in have:
            have.add(n); extra.append(g)
    body += [g for _, _, g in groups(t, 'cell')]
open(out, 'w').write(head + ''.join(extra) + ''.join(body) + '\n}\n')
print(out, len(body), 'cells', len(extra), 'extra templates')
