#!/usr/bin/env python3
"""tb_v80.sv -> tb_gl.sv: the same AXI host model around the netlist top.

    mk_tb.py <tb_v80.sv> <tb_gl.sv> [top]   top: top_meimei_top_0 (BD cell DCP, default) or mm_v80_top_bd (synth.tcl)
"""
import sys
src, dst = sys.argv[1], sys.argv[2]
top = sys.argv[3] if len(sys.argv) > 3 else "top_meimei_top_0"
s = open(src).read()
for old, new in (
    ("    import mm_pkg::*;\n    import mm_soc_pkg::*;\n", "    localparam int IMEM_WORDS = 16384, DMEM_WORDS = 8192;\n"),
    ("mm_v80_top #() u_top (", "glbl glbl();\n    " + top + " u_top ("),
    ("        if (ec != 32'd0) $fatal(1, \"exit code %0d\", ec);\n", ""),   # the probes exit with codes != 0
    ("        repeat (10) @(posedge s_axi_aclk);\n        #1;\n        s_axi_aresetn = 1'b1;",
     "        repeat (20) @(posedge s_axi_aclk);\n        #1;\n        s_axi_aresetn = 1'b1;"),   # after GSR (100 ns)
):
    assert old in s, old
    s = s.replace(old, new)
open(dst, "w").write(s)
