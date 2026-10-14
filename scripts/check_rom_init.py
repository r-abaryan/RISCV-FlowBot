#!/usr/bin/env python3
"""Check firmware words are present in the soc_rom memory INIT of a Yosys RTLIL dump taken after `proc; memory_collect`
(cell $mem_v2, parameter INIT, 2048 x 32). Usage: check_rom_init.py dump.il firmware.hex
Words covered by the hex file must match exactly. Under SYNTHESIS soc_rom does NOT NOP-fill, so uncovered words are
undefined (x); they are counted, not failed (documented limitation). Exit 0 only on exact match.
Limitation: this checks the pre-technology-mapping memory. Preservation into ECP5 DP16KD INITVAL_xx is only checked
as 'nonzero INITVAL present' by the caller (the INITVAL bit layout is not decoded here)."""
import re, sys
il, hx = sys.argv[1], sys.argv[2]
words = [None] * 2048; i = 0
for ln in open(hx):
    ln = ln.split("//")[0].strip()
    if not ln: continue
    if ln.startswith("@"): i = int(ln[1:], 16); continue
    for t in ln.split(): words[i] = int(t, 16); i += 1
ms = [m for m in re.finditer(r"parameter \\INIT (\d+)'([01xzXZ]+)", open(il).read()) if m.group(1) == str(2048 * 32)]
if len(ms) != 1: print(f"FAIL: expected exactly one 2048x32 memory INIT, found {len(ms)}"); sys.exit(1)
m = ms[0]
if not m: print("FAIL: no memory INIT parameter found"); sys.exit(1)
b = m.group(2)
if len(b) != 2048 * 32: print("FAIL: INIT width", len(b)); sys.exit(1)
bad = 0; unc = 0
for a, w in enumerate(words):
    if w is None: unc += 1; continue
    got = b[len(b) - 32 * (a + 1): len(b) - 32 * a]
    if got != format(w, "032b"):
        bad += 1
        if bad <= 5: print(f"MISMATCH word {a}: got {got} want {w:08x}")
nw = len(words) - unc
print(f"hex_words={nw} uncovered_x_words={unc} mismatches={bad}")
if nw == 0: bad = 1
sys.exit(0 if bad == 0 else 1)
