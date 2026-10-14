#!/usr/bin/env python3
"""Compare ROM block-RAM initial contents between a reference soc_rom synthesis and the flat soc_top synthesis.
Usage: check_rom_mapped.py ref_netlist.il top_netlist.il [top_cell_prefix=u_rom.]
Collects the INITVAL_xx parameter sets of every DP16KD cell whose name contains 'rom_mem' (ref: all such cells;
top: those starting with the prefix) and requires the sorted lists to be identical and to contain nonzero data.
Limitation: structural comparison of mapped INITVALs; not a functional read-back. Exit 0 only on a match."""
import re, sys
def load(path, prefix):
    cells = {}; cur = None
    for ln in open(path):
        m = re.match(r'\s*cell \\DP16KD (\S+)', ln)
        if m:
            n = m.group(1).lstrip("\\")
            cur = n if ("rom_mem" in n and n.startswith(prefix)) else None
            if cur: cells[cur] = {}
            continue
        m = re.match(r"\s*parameter \\INITVAL_([0-9A-Fa-f]+) (\d+)'([01xz]+)", ln)
        if m and cur: cells[cur][m.group(1)] = m.group(3)
    return sorted(tuple(sorted(v.items())) for v in cells.values()), len(cells)
ref, nr = load(sys.argv[1], "")
top, nt = load(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "u_rom.")
nz = sum(1 for c in top for _, b in c if "1" in b)
print(f"ref_cells={nr} top_rom_cells={nt} nonzero_initval_params_in_top={nz}")
ok = nr > 0 and nr == nt and nz > 0 and ref == top
print("ROM_INIT_MAPPED_MATCH" if ok else "FAIL: mapped ROM INITVALs missing or different")
sys.exit(0 if ok else 1)
