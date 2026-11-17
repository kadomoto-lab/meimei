#!/usr/bin/env python3
# replace Verilog escaped identifiers of module names ("\$paramod...\name ") by plain names
import re, sys, hashlib
def plain(m):
    n = m.group(1)
    parts = n.split('\\')
    base = re.sub(r'[^A-Za-z0-9_]', '_', parts[-1] if n.startswith('$paramod$') else parts[1])
    if n.startswith('$paramod'):
        base = base + '_' + hashlib.md5(n.encode()).hexdigest()[:6]
    return base
for f in sys.argv[1:]:
    t = open(f).read()
    t = re.sub(r'\\(\$paramod\S*)\s', lambda m: plain(m) + ' ', t)
    open(f.replace('.v', '_s.v'), 'w').write(t)
