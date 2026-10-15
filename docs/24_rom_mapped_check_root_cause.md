# ROM mapped-netlist check: root cause and replacement

Evidence: CI run 38646347121, artifact 11932674688 (rom_ref_syn/netlist.il, soc_top_syn/netlist.il). No Yosys re-run.

## Root cause (established from the netlists)
- Both netlists have 4 ROM DP16KD cells with identical configuration (DATA_WIDTH 9, 64 INITVAL params each, 17 non-zero params per cell).
- The standalone reference is **not** zero-initialised. The old checker's parser did not stop at the end of a cell: in the reference
  netlist the cell `rom_mem.0.1` is the last cell before `module \DP16KD` (the cell library definition), whose default INITVALs are all zero. These
  overwrote or were appended to that cell's parameters (66 params seen, 0 non-zero). That is a **checker parsing bug**, not a synthesis difference.
- Differences in connectivity between the two netlists are only net names (`wb_stb_i_LUT4_D_Z` vs `u_rom.wb_cyc_i` for CEA) and
  were not analysed further; no check of address/output wiring was done.

## Content check (independent of either netlist being authoritative)
Layout decoded: cell N holds word bits [9N+8:9N]; address a is at INITVAL bit offset (a//2)*20 + (a%2)*9 (LSB of INITVAL_00 = bit 0).
Decoding both netlists against `sw/firmware/robot_nav.hex` (531 words, zero-filled to 2048): **0 mismatching words in all 4 cells of both netlists.**
Cell 0 matches byte 0 over all 531 words (an independent sanity check of the layout), and words 531..2047 decode to zero.
Caveat: the layout was inferred from the data (it gave 0 mismatches over 8192 cell-words, so a chance fit is implausible), not taken from Lattice documentation.
Not verified: that addressing/output wiring of the DP16KD ports delivers these bits to the Wishbone bus correctly.

## Replacement
`scripts/check_rom_mapped.py firmware.hex netlist[:prefix] ...` decodes and compares against the firmware directly, with cell-scoped parsing.
Tests: `python3 tests/rom_check/test_check_rom_mapped.py` (fixtures are ROM-cell excerpts of the artifact; 8 tests: positive for both netlists, the
module-default regression, and negatives: flipped bit, zeroed cell, missing cell, wrong firmware, nonzero tail).
