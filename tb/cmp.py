# compare ISS and RTL results: final state exactly, commit traces line by line where an ISS value
# of "?" (cycle / time CSR reads) matches any RTL value. Exit status 0 = match.
import sys
d = sys.argv[1] if len(sys.argv) > 1 else '.'
rd = lambda f: open('%s/%s' % (d, f)).read().split('\n')
if rd('iss_out.txt') != rd('rtl_out.txt'): sys.exit(1)
a, b = rd('iss_trace.txt'), rd('rtl_trace.txt')
if len(a) != len(b): sys.exit(1)
for x, y in zip(a, b):
    if x != y and not (x.endswith(' ?') and x.split()[0] == y.split()[0]): sys.exit(1)
