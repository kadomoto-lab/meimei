#!/usr/bin/env python3
"""Run the Embench-IoT builds (build/<name>/) on the V80 one after another and tabulate them.

Each image prints "EMBENCH cycles=N instret=M" from stop_trigger and exits with 0 when its
verify_benchmark() passes.  The speed column is Embench's per-MHz relative speed for a
CPU_MHZ=1 build: baseline_ms * 1000 / cycles (baseline = Cortex-M4 reference in
<EMBENCH>/baseline-data/speed.json); the score is the geometric mean over the benchmarks.

    ./run_v80.py                    # all of build/*
    ./run_v80.py crc32 nbody        # some
"""
import argparse, contextlib, io, json, math, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "fpga", "v80"))
import load_coremark as lc  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("bench", nargs="*")
ap.add_argument("--embench", default=os.path.expanduser("~/opt/src/embench/embench-1.0"))
ap.add_argument("--dev", default=lc.DEF_DEV)
ap.add_argument("--build", default="build", help="build directory (build, build-gcc12, build-clang)")
ap.add_argument("--all", action="store_true", help="score every benchmark (nbody included)")
ap.add_argument("--json", default=None, help="write the results here")
args = ap.parse_args()

base = json.load(open(os.path.join(args.embench, "baseline-data", "speed.json")))
names = args.bench or sorted(d for d in os.listdir(os.path.join(HERE, args.build))
                                if os.path.isfile(os.path.join(HERE, args.build, d, "code.hex")))
win = lc.Window(args.dev, lc.DEF_BASE)
res = {}
try:
    for n in names:
        d = os.path.join(HERE, args.build, n)
        with tempfile.NamedTemporaryFile("r", suffix=".txt") as t:
            with contextlib.redirect_stdout(io.StringIO()):
                lc.load_image(win, os.path.join(d, "code.hex"), os.path.join(d, "data.hex"), quiet=True)
                code = lc.run_and_spool(win, t.name)
            uart = open(t.name).read()
        m = re.search(r"EMBENCH cycles=(\d+) instret=(\d+)", uart)
        cyc, ins = (int(m.group(1)), int(m.group(2))) if m else (None, None)
        r = {"exit": code, "cycles": cyc, "instret": ins}
        if cyc:
            r["ipc"] = ins / cyc
            if n in base:
                r["speed"] = base[n] * 1000 / cyc
        res[n] = r
        print(f"{n:16s} exit={code} cycles={cyc} instret={ins}"
              + (f" IPC={r['ipc']:.3f}" if cyc else "") + (f" speed={r['speed']:.2f}" if "speed" in r else ""),
              flush=True)
finally:
    win.close()

# GCC 15 hoists nbody's pure bodies_energy() out of its loop (772 instructions): not a valid measurement
NOSCORE = {"nbody"}
ok = [r for r in res.values() if r["exit"] == 0 and "speed" in r]
noscore = set() if args.all else NOSCORE
sc = [r["speed"] for n, r in res.items() if r in ok and n not in noscore]
print(f"\n{len(ok)}/{len(res)} passed")
if sc:
    gm = math.exp(sum(map(math.log, sc)) / len(sc))
    print(f"Embench speed score (per MHz, geomean of {len(sc)}, without {', '.join(sorted(noscore)) or 'none'}) = {gm:.3f}")
if args.json:
    json.dump(res, open(args.json, "w"), indent=1)
sys.exit(0 if len(ok) == len(res) else 1)
