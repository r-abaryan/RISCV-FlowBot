#!/usr/bin/env python3
"""Static LPF <-> top-level port cross-check (M8C preflight).
Usage: check_lpf_ports.py <netlist.json> <top> <file.lpf>
Fails (exit 1) if a top port has no LOCATE, or a LOCATE names a port the top lacks.
Reports (non-fatal) output port bits driven by a constant: nextpnr's getCellForPinConstraint() returns null
for names absent from the design and the LPF reader then ignores the line SILENTLY (no warning), so an
optimised-away port would lose its pin without notice. Constant-driven output bits that still exist as ports
are expected to keep their IO buffer; the CI log is grepped for them afterwards."""
import json, re, sys
js, top, lpf = sys.argv[1:4]
m = json.load(open(js))["modules"][top]
bits = {}
for n, p in m["ports"].items():
    for i, b in enumerate(p["bits"]):
        bits[n if len(p["bits"]) == 1 else "%s[%d]" % (n, i)] = (p["direction"], b)
loc = set(re.findall(r'LOCATE\s+COMP\s+"([^"]+)"', open(lpf).read()))
rc = 0
for n in sorted(set(bits) - loc):
    print("ERROR: top port %s has no LOCATE in LPF" % n); rc = 1
for n in sorted(loc - set(bits)):
    print("ERROR: LPF LOCATE %s matches no top port" % n); rc = 1
for n, (d, b) in sorted(bits.items()):
    if d == "output" and isinstance(b, str):
        print("NOTE: output %s is driven by constant %s" % (n, b))
print("ports=%d locates=%d status=%s" % (len(bits), len(loc), "FAIL" if rc else "OK"))
sys.exit(rc)
