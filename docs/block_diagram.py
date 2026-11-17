#!/usr/bin/env python3
"""Generate docs/block_diagram.svg (the README block diagram).

    python3 docs/block_diagram.py

Colors follow the logo palette (main / accent / text / surface / background,
dark_main / dark_accent for prefers-color-scheme: dark). The text font is a
subset of Nunito (docs/fonts/nunito-sub.woff2, SIL OFL 1.1, see
docs/fonts/OFL.txt) embedded as a data URI, because an SVG shown through
<img> cannot load external fonts. Edit the numbers here when the
configuration in rtl/mm_pkg.sv changes.
"""
import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "block_diagram.svg")
FONT = os.path.join(HERE, "fonts", "nunito-sub.woff2")

W, H = 1262, 905
X0 = 160             # left edge of the block area
COLW, GAP = 160, 12  # 6 columns
NCOL = 6
X1 = X0 + NCOL * COLW + (NCOL - 1) * GAP   # right edge


def col_x(c):
    return X0 + c * (COLW + GAP)


def col_cx(c):
    return col_x(c) + COLW / 2


def span(c0, c1):
    """x and width of a block spanning columns c0..c1."""
    x = col_x(c0)
    return x, col_x(c1) + COLW - x


out = []


def emit(s):
    out.append(s)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def block(x, y, w, h, title, lines=(), kind="blk", r=14):
    """A block: a soft rounded rectangle with a title and detail lines, centered."""
    emit(f'<rect class="{kind}" x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{r}"/>')
    tcls, dcls = ("tk", "dk") if kind == "key" else ("t", "d")
    n = len(lines)
    total = 17 + n * 16.5
    ty = y + (h - total) / 2 + 13
    cx = x + w / 2
    emit(f'<text class="{tcls}" x="{cx:g}" y="{ty:g}">{esc(title)}</text>')
    for i, ln in enumerate(lines):
        emit(f'<text class="{dcls}" x="{cx:g}" y="{ty + 19 + i * 16.5:g}">{esc(ln)}</text>')


def arrow(d, cls="a"):
    emit(f'<path class="{cls}" d="{d}"/>')


def row_label(y, label):
    """Row label in the left gutter: an accent dot (the logo's i dot) and a lowercase name."""
    emit(f'<circle class="dot" cx="34" cy="{y - 4.5:g}" r="4.5"/>')
    emit(f'<text class="rl" x="48" y="{y:g}">{esc(label)}</text>')


def bracket(x, w, y, label):
    """A thin bracket above a group of blocks (instead of a nested frame)."""
    emit(f'<path class="br" d="M{x + 2:g},{y + 7:g} V{y:g} H{x + w - 2:g} V{y + 7:g}"/>')
    tw = len(label) * 6.6 + 16
    emit(f'<rect class="bg" x="{x + 14:g}" y="{y - 8:g}" width="{tw:g}" height="16"/>')
    emit(f'<text class="bl" x="{x + 22:g}" y="{y + 4:g}">{esc(label)}</text>')


def rounded(points, r=12):
    """Path through axis-aligned points with rounded corners."""
    d = f"M{points[0][0]:g},{points[0][1]:g}"
    for i in range(1, len(points) - 1):
        (px, py), (cx, cy), (nx, ny) = points[i - 1], points[i], points[i + 1]
        def toward(ax, ay, bx, by, dist):
            if ax == bx:
                return ax, ay + (dist if by > ay else -dist)
            return ax + (dist if bx > ax else -dist), ay
        ax, ay = toward(cx, cy, px, py, r)
        bx, by = toward(cx, cy, nx, ny, r)
        d += f" L{ax:g},{ay:g} Q{cx:g},{cy:g} {bx:g},{by:g}"
    d += f" L{points[-1][0]:g},{points[-1][1]:g}"
    return d


def lane_label(x, y, text, cls):
    """Label set along a vertical feedback lane, with a background halo."""
    emit(f'<text class="fb {cls}" transform="translate({x:g},{y:g}) rotate(-90)">{esc(text)}</text>')


# ---------------------------------------------------------------- style
font_b64 = base64.b64encode(open(FONT, "rb").read()).decode()
style = f"""
@font-face {{ font-family: "mmNunito"; font-weight: 500 850;
  src: url(data:font/woff2;base64,{font_b64}) format("woff2"); }}
text {{ font-family: "mmNunito", "Nunito", "Varela Round", "Hiragino Maru Gothic ProN", sans-serif;
  font-variant-numeric: tabular-nums lining-nums; }}
.bg   {{ fill: #FAF8F3; }}
.blk  {{ fill: #E7EFEC; }}
.key  {{ fill: #3E6C6D; }}
.mem  {{ fill: #FAF8F3; stroke: #3E6C6D; stroke-width: 1.5; }}
.t    {{ font-size: 13.5px; font-weight: 800; fill: #263A3B; text-anchor: middle; }}
.d    {{ font-size: 11.5px; font-weight: 550; fill: #4D6869; text-anchor: middle; }}
.tk   {{ font-size: 13.5px; font-weight: 800; fill: #FAF8F3; text-anchor: middle; }}
.dk   {{ font-size: 11.5px; font-weight: 550; fill: #D5E5E1; text-anchor: middle; }}
.rl   {{ font-size: 13px; font-weight: 850; fill: #3E6C6D; letter-spacing: 0.3px; }}
.dot  {{ fill: #B97888; }}
.cap  {{ font-size: 12.5px; font-weight: 600; fill: #4D6869; }}
.capb {{ font-weight: 850; fill: #263A3B; }}
.br   {{ stroke: #9DB8B5; stroke-width: 1.2; fill: none; stroke-linecap: round; stroke-linejoin: round; }}
.bl   {{ font-size: 11.5px; font-weight: 750; fill: #3E6C6D; }}
.a    {{ stroke: #7E9998; stroke-width: 1.4; fill: none; stroke-linecap: round; stroke-linejoin: round; marker-end: url(#ar); }}
.ln   {{ stroke: #7E9998; stroke-width: 1.4; fill: none; stroke-linecap: round; stroke-linejoin: round; }}
.fbk  {{ stroke-width: 2.6; fill: none; stroke-dasharray: 0 6.5; stroke-linecap: round; stroke-linejoin: round; }}
.fr   {{ stroke: #B97888; marker-end: url(#arr); }}
.fg   {{ stroke: #3E6C6D; marker-end: url(#arg); }}
.ft   {{ stroke: #263A3B; marker-end: url(#art); }}
.fb   {{ font-size: 11.5px; font-weight: 800; text-anchor: middle; paint-order: stroke;
         stroke: #FAF8F3; stroke-width: 5px; stroke-linejoin: round; }}
.fbr  {{ fill: #B97888; }} .fbg {{ fill: #3E6C6D; }} .fbt {{ fill: #263A3B; }}
.mk   {{ stroke: #7E9998; }} .mkr {{ stroke: #B97888; }} .mkg {{ stroke: #3E6C6D; }} .mkt {{ stroke: #263A3B; }}
.mks  {{ fill: none; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }}
.rail {{ stroke: #9DB8B5; stroke-width: 2; stroke-linecap: round; }}
.nd   {{ fill: #3E6C6D; }}
.ndo  {{ fill: #FAF8F3; stroke: #3E6C6D; stroke-width: 2; }}
.sn   {{ font-size: 12px; font-weight: 800; fill: #263A3B; text-anchor: middle; }}
.sg   {{ font-size: 11px; font-weight: 650; fill: #6F8A89; text-anchor: middle; }}
@media (prefers-color-scheme: dark) {{
  .bg   {{ fill: #202629; }}
  .blk  {{ fill: #2B3739; }}
  .key  {{ fill: #ADD5CE; }}
  .mem  {{ fill: #202629; stroke: #ADD5CE; }}
  .t    {{ fill: #EAF1EF; }}
  .d    {{ fill: #A9BDBA; }}
  .tk   {{ fill: #202629; }}
  .dk   {{ fill: #3B5354; }}
  .rl, .bl {{ fill: #ADD5CE; }}
  .dot, .fbr {{ fill: #E2A9B7; }}
  .cap  {{ fill: #A9BDBA; }} .capb {{ fill: #EAF1EF; }}
  .br, .rail {{ stroke: #4F6667; }}
  .a, .ln, .mk {{ stroke: #7F9896; }}
  .fr, .mkr {{ stroke: #E2A9B7; }}
  .fg, .mkg {{ stroke: #ADD5CE; }}
  .ft, .mkt {{ stroke: #EAF1EF; }}
  .fb   {{ stroke: #202629; }}
  .fbg  {{ fill: #ADD5CE; }} .fbt {{ fill: #EAF1EF; }}
  .nd   {{ fill: #ADD5CE; }}
  .ndo  {{ fill: #202629; stroke: #ADD5CE; }}
  .sn   {{ fill: #EAF1EF; }}
  .sg   {{ fill: #8BA3A0; }}
}}
"""


def marker(mid, cls):
    return (f'<marker id="{mid}" viewBox="0 0 10 10" refX="8.6" refY="5" markerWidth="9" '
            f'markerHeight="9" markerUnits="userSpaceOnUse" orient="auto-start-reverse">'
            f'<path class="mks {cls}" d="M2.2,1.6 L8.6,5 L2.2,8.4"/></marker>')


emit(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">')
emit('<title>meimei block diagram (8-wide default configuration)</title>')
emit('<!-- generated by docs/block_diagram.py; font: Nunito subset, SIL Open Font License 1.1 (docs/fonts/OFL.txt) -->')
emit('<defs>')
emit(marker("ar", "mk"))
emit(marker("arr", "mkr"))
emit(marker("arg", "mkg"))
emit(marker("art", "mkt"))
emit(f'<style>{style}</style>')
emit('</defs>')
emit(f'<rect class="bg" x="0" y="0" width="{W}" height="{H}"/>')

# caption (the README header already carries the name)
emit(f'<text class="cap" x="{X0}" y="34"><tspan class="capb">8-wide default</tspan>'
     ' · rtl/mm_pkg.sv · +define+MM_SMALL builds the 4-wide core</text>')

# ---------------------------------------------------------------- frontend
FY, FH = 92, 100
fe = [  # (title, lines, width)
    ("s1", ["uBTB 32", "micro-RAS", "0 bubble"], 102),
    ("s2", ["BTB 32 banks", "TAGE 4 × 1024", "path history"], 102),
    ("s3", ["ITTAGE 3 × 64", "RAS 16", "SC (off)"], 102),
    ("FTQ", ["64 blocks", "PC memory"], 86),
    ("F0", ["I-SRAM read", "64 KiB", "32 banks"], 92),
    ("F1", ["boundaries", "RVC expand", "compact"], 92),
    ("F2", ["predecode", "check"], 92),
    ("WB", ["IFU redirect", "to BPU / FTQ"], 92),
    ("IBuffer", ["48 entries", "32 in / 8 out"], 0),
]
inner, outer = 10, 22
gaps = [inner, inner, outer, outer, inner, inner, inner, outer]
fixed = sum(w for _, _, w in fe) + sum(gaps)
fe[-1] = (fe[-1][0], fe[-1][1], X1 - X0 - fixed)
xs = []
x = X0
for i, (t, ls, w) in enumerate(fe):
    xs.append((x, w))
    block(x, FY, w, FH, t, ls)
    if i < len(gaps):
        arrow(f"M{x + w + 2:g},{FY + FH / 2:g} H{x + w + gaps[i] - 2:g}")
        x += w + gaps[i]
row_label(FY + FH / 2 + 4, "frontend")
bracket(xs[0][0], xs[2][0] + xs[2][1] - xs[0][0], FY - 18, "BPU · 3-stage override")
bracket(xs[4][0], xs[7][0] + xs[7][1] - xs[4][0], FY - 18, "IFU · 64 B fetch block, 32 halfword slots")

# IBuffer -> Decode
RY, RH = 236, 66
ib_cx = xs[8][0] + xs[8][1] / 2
arrow(rounded([(ib_cx, FY + FH + 2), (ib_cx, FY + FH + 22), (col_cx(0), FY + FH + 22), (col_cx(0), RY - 3)]))

# ---------------------------------------------------------------- rename
block(col_x(0), RY, COLW, RH, "Decode", ["8 / cycle", "RV64IMFDC + Zicsr"])
x, w = span(1, 2)
block(x, RY, w, RH, "Rename", ["RAT · free lists (int 224 / FP 256) · 4 snapshots",
                                "move elimination · StoreSet · IQ selection"])
block(col_x(3), RY, COLW, RH, "Dispatch", ["busy table", "2 enq / IQ"])
x, w = span(4, 5)
block(x, RY, w, RH, "ROB 352", ["in-order commit, 8 / cycle",
                                 "snapshot restore + walk recovery"], kind="key")
for c in (0, 2, 3):   # Decode -> Rename -> Dispatch -> ROB
    arrow(f"M{col_x(c) + COLW + 2:g},{RY + RH / 2:g} H{col_x(c + 1) - 2:g}")
row_label(RY + RH / 2 + 4, "rename")

# dispatch bus
IY, IH = 346, 54
BUS = RY + RH + 22
emit(f'<path class="ln" d="M{col_cx(3):g},{RY + RH + 2:g} V{BUS:g}"/>')
emit(f'<path class="ln" d="M{col_cx(0):g},{BUS:g} H{col_cx(5):g}"/>')
for c in range(NCOL):
    arrow(f"M{col_cx(c):g},{BUS:g} V{IY - 3:g}")

# ---------------------------------------------------------------- issue
iqs = [("ALU + BJU × 3", "18 entries"), ("ALU × 3", "20 entries"), ("LDU × 3", "20 entries"),
       ("STA × 2", "16 entries"), ("STD × 2", "16 entries"), ("FEX × 4", "20 entries")]
for c, (t, d) in enumerate(iqs):
    block(col_x(c), IY, COLW, IH, t, [d])
row_label(IY + IH / 2 + 4, "issue")

# ---------------------------------------------------------------- read
PY, PH = 432, 54
for c in range(NCOL):
    arrow(f"M{col_cx(c):g},{IY + IH + 2:g} V{PY - 3:g}")
x, w = span(0, 2)
block(x, PY, w, PH, "Integer PRF 224 × 64 b",
      ["12 read ports shared by priority · bypass network"], kind="key")
block(col_x(3), PY, COLW, PH, "Register cache", ["24 ALU + 6 link + 12 load"])
x, w = span(4, 5)
block(x, PY, w, PH, "FP PRF 256 × 64 b", ["bypass network"], kind="key")
row_label(PY + PH / 2 + 4, "read")

# ---------------------------------------------------------------- execute
EY, EH = 518, 74
for c in range(NCOL):
    arrow(f"M{col_cx(c):g},{PY + PH + 2:g} V{EY - 3:g}")
exs = [("ALU × 3 · BJU × 3", ["DIV (SRT) on ALU1", "I2F on ALU2 · CSR"]),
       ("ALU × 3", ["MUL × 2 on ALU4, ALU5", "3-stage Booth / CSA"]),
       ("LDU × 3", ["AGU → MEM", "load-to-use 3 cycles"]),
       ("STA × 2", ["AGU → SC", "order-violation check"]),
       ("STD × 2", ["store data", "into the SQ"]),
       ("FEX × 4", ["FMA (4) · FADD (2)", "FCVT on FEX0 · FDIV × 2"])]
for c, (t, ls) in enumerate(exs):
    block(col_x(c), EY, COLW, EH, t, ls)
row_label(EY + EH / 2 + 4, "execute")

# ---------------------------------------------------------------- memory
MY, MH = 632, 56
DY, DH = 724, 56
for c in (2, 3, 4):
    arrow(f"M{col_cx(c):g},{EY + EH + 2:g} V{MY - 3:g}")
x, w = span(1, 2)
block(x, MY, w, MH, "Load queue 120", ["RAW queue 56 · replay queue 4 / pipe"], kind="mem")
lq_cx = x + w / 2
x, w = span(3, 4)
block(x, MY, w, MH, "Store queue 128", ["byte-granular store-to-load forwarding"], kind="mem")
block(col_x(5), MY, COLW, MH, "Store buffer", ["16 lines × 16 B"], kind="mem")
arrow(f"M{col_x(5) - GAP + 2:g},{MY + MH / 2:g} H{col_x(5) - 2:g}")
emit(f'<text class="sg" x="{col_x(5) - GAP / 2:g}" y="{MY + MH + 16:g}">commit</text>')
block(col_x(0), DY, COLW, DH, "MMIO", ["UART · GPIO · timer"], kind="mem")
x, w = span(1, 5)
block(x, DY, w, DH, "Data SRAM 64 KiB",
      ["2 banks × one copy per load pipe · synchronous read at AGU · 1 line write / cycle"], kind="key")
arrow(f"M{lq_cx:g},{MY + MH + 2:g} V{DY - 3:g}")
arrow(f"M{col_cx(5):g},{MY + MH + 2:g} V{DY - 3:g}")
row_label(MY + MH / 2 + 4, "memory")

# ---------------------------------------------------------------- feedback paths (dotted)
# branch / memory-order redirect: execute col 0 -> left lane -> s1
LANE_L = X0 - 18
pts = [(col_x(0) + 30, EY + EH + 1), (col_x(0) + 30, EY + EH + 16), (LANE_L, EY + EH + 16),
       (LANE_L, FY + FH / 2), (X0 - 4, FY + FH / 2)]
emit(f'<path class="fbk fr" d="{rounded(pts)}"/>')
lane_label(LANE_L, (FY + FH / 2 + EY + EH) / 2 + 40, "redirect", "fbr")

# writeback / wakeup: FEX -> right lane -> FP PRF and ROB
LANE_R1 = X1 + 22
emit(f'<path class="fbk fg" d="{rounded([(X1 + 3, EY + EH / 2), (LANE_R1, EY + EH / 2), (LANE_R1, RY + RH / 2 + 8), (X1 + 4, RY + RH / 2 + 8)])}"/>')
emit(f'<path class="fbk fg" d="M{LANE_R1:g},{PY + PH / 2:g} H{X1 + 4:g}" style="marker-end:url(#arg)"/>')
lane_label(LANE_R1, (RY + EY + EH) / 2 + 20, "writeback · wakeup", "fbg")

# commit -> predictor training: ROB -> outer lane -> BPU
LANE_R2 = X1 + 52
bpu_cx = xs[2][0] + xs[2][1] / 2   # s3, clear of the bracket label
pts = [(X1 + 3, RY + RH - 14), (LANE_R2, RY + RH - 14), (LANE_R2, 52), (bpu_cx, 52), (bpu_cx, FY - 22)]
emit(f'<path class="fbk ft" d="{rounded(pts)}"/>')
lane_label(LANE_R2, (52 + RY + RH) / 2 + 10, "commit → training", "fbt")

# ---------------------------------------------------------------- pipeline rail
RLY = 842
stages = ["BP", "F0", "F1", "F2", "DE", "RN", "DP", "IS", "RR", "EX", "WB", "CM"]
row_label(RLY + 4, "pipeline")
step = (X1 - X0 - 40) / (len(stages) - 1)
nx = [X0 + 20 + i * step for i in range(len(stages))]
emit(f'<path class="rail" d="M{nx[0]:g},{RLY:g} H{nx[-1]:g}"/>')
for i, (sx, sname) in enumerate(zip(nx, stages)):
    cls = "nd" if sname in ("EX",) else "ndo"
    emit(f'<circle class="{cls}" cx="{sx:g}" cy="{RLY:g}" r="6"/>')
    emit(f'<text class="sn" x="{sx:g}" y="{RLY + 26:g}">{sname}</text>')
groups = [(0, 0, "predict"), (1, 3, "fetch"), (4, 6, "decode · rename · dispatch"),
          (7, 8, "issue · read"), (9, 9, "execute"), (10, 11, "complete")]
for a, b, g in groups:
    emit(f'<text class="sg" x="{(nx[a] + nx[b]) / 2:g}" y="{RLY - 16:g}">{g}</text>')
emit(f'<text class="sg" x="{X1:g}" y="{RLY + 48:g}" style="text-anchor:end">'
     'ALU instruction, 12 stages at minimum</text>')

emit('</svg>')
open(OUT, "w").write("\n".join(out) + "\n")
print(OUT)
