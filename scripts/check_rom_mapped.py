#!/usr/bin/env python3
"""Verify the ROM contents of a mapped (synth_ecp5) RTLIL netlist against the firmware hex.

Usage: check_rom_mapped.py firmware.hex netlist.il[:cell_prefix] [netlist.il[:cell_prefix] ...]

Decodes the INITVAL_00..3F parameters of the four DP16KD cells named <prefix>rom_mem.0.N (N=0..3) and compares them
word-by-word with the firmware: ROM is 2048 x 32, configured as 4 DP16KD in DATA_WIDTH 9 mode; cell N holds word bits
[9N+8:9N] (cell 3 holds bits 27..31 only). Address a lives at INITVAL bit offset (a//2)*20 + (a%2)*9 (INITVAL_00 is
the least-significant 320 bits of the memory image; layout derived from the saved CI artifact and confirmed with
0 mismatches over 2048 words, see docs/). Words beyond the hex file must be zero in the mapped netlist.
Parsing is scoped to each `cell ... end` block, so the default INITVALs of a following `module \\DP16KD` definition
cannot leak into the last cell (that leak caused the earlier false FAIL).
Exit 0 only if every given netlist decodes to the firmware. Not a timing or FPGA-implementation check."""
import re, sys

def read_hex(path):
    words = []
    for ln in open(path):
        ln = ln.split("//")[0].strip()
        if ln.startswith("@"): raise SystemExit("FAIL: @address in hex not supported")
        words += [int(t, 16) for t in ln.split()]
    return words

def load_cells(path, prefix):
    cells, cur = {}, None
    for ln in open(path):
        s = ln.strip()
        m = re.match(r'cell \\DP16KD (\S+)', s)
        if m:
            n = m.group(1).lstrip("\\")
            cur = cells.setdefault(n, {}) if (n.startswith(prefix + "rom_mem.") ) else None
            continue
        if s == "end" or s.startswith("module "):
            cur = None; continue
        m = re.match(r"parameter \\INITVAL_([0-9A-Fa-f]+) (\d+)'([01xzXZ]+)", s)
        if m and cur is not None:
            if len(m.group(3)) != 320: raise SystemExit("FAIL: INITVAL width %s" % m.group(2))
            cur[int(m.group(1), 16)] = m.group(3)
    return cells

def decode(cell):
    """-> list of 2048 9-bit values; None if the cell does not have all 64 INITVAL params."""
    if sorted(cell) != list(range(64)): return None
    bits = "".join(cell[i][::-1] for i in range(64))  # index 0 = LSB of INITVAL_00
    out = []
    for a in range(2048):
        o = (a // 2) * 20 + (a % 2) * 9
        seg = bits[o:o + 9]
        if set(seg) - set("01"): return None
        out.append(int(seg[::-1], 2))
    return out

def check(hexwords, netlist, prefix):
    cells = load_cells(netlist, prefix)
    names = sorted(cells)
    want = [f"{prefix}rom_mem.0.{i}" for i in range(4)]
    if names != sorted(want):
        return [f"expected cells {want}, found {names}"]
    errs = []
    for i, n in enumerate(want):
        d = decode(cells[n])
        if d is None: errs.append(f"{n}: INITVAL params incomplete/undefined"); continue
        bad = [a for a in range(2048)
               if d[a] != (((hexwords[a] if a < len(hexwords) else 0) >> (9 * i)) & 0x1FF)]
        if bad:
            a = bad[0]
            errs.append(f"{n}: {len(bad)} word mismatches, first at addr {a}: got {d[a]:03x} "
                        f"want {(((hexwords[a] if a < len(hexwords) else 0) >> (9*i)) & 0x1FF):03x}")
    return errs

def main(argv):
    hw = read_hex(argv[0]); rc = 0
    specs = argv[1:]
    if not specs: raise SystemExit(__doc__)
    for spec in specs:
        path, _, prefix = spec.partition(":")
        errs = check(hw, path, prefix)
        print(f"{path} (prefix '{prefix}'): {'OK' if not errs else 'FAIL'} ({len(hw)} firmware words)")
        for e in errs: print("  ", e)
        rc |= bool(errs)
    print("ROM_MAPPED_CONTENT_MATCH" if rc == 0 else "FAIL: mapped ROM contents differ from firmware")
    return rc

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
