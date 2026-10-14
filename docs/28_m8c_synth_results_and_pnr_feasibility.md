# 28. M8C: measured flat synthesis, ULX3S 85F capacity, and place-and-route feasibility workflow

## 1. Measured synthesis result (M8B, verified)
Evidence: GitHub Actions run 38651365256 (workflow `synth-soc-top`, run number 6, `workflow_dispatch`, conclusion success), repository commit 545f0c0848c9cf6210ac4584bd40c88b26ae83c2, branch `flowbot/m8b-flat-synth-workflow`. Yosys 0.68+post, git c12172fb (pinned, built in CI).
Flat `synth_ecp5` of firmware-initialised `soc_top` (ROM_INIT_FILE = `sw/firmware/robot_nav.hex`, 531 words):

| Cell | Count |
|---|---|
| LUT4 | 8,837 |
| TRELLIS_FF | 2,678 |
| DP16KD | 38 |
| MULT18X18D | 12 |
| CCU2C | 589 |
| TRELLIS_DPR16X4 | 352 |

Synthesis exit code 0, status COMPLETED. ROM pre-mapping and mapped-content checks passed (531 words, 0 mismatches; see docs/24_rom_mapped_check_root_cause.md).
Source of these numbers: the owner's independent inspection of the artifact, as reported to me in chat. In this session I confirmed through the GitHub API only that run 38651365256 exists, is on commit 545f0c0 and concluded success; I did not re-download the artifact.
Scope: cell counts only. No timing, no Fmax, no place-and-route, no board result.

## 2. Status of older numbers
- 2,686 LUT4 / 2,130 FF / 4 DSP / 38 MHz (commit dffa1c2, old docs 11, 12, README, CHECKPOINT): **retired as unsupported**. There was no log and no script, and the synthesis script it cited never existed. Do not cite it.
- About 7,650 LUT4 and 8 MULT18X18D (doc 18): a **sum of separately synthesised modules** (per-module staged runs, no flat optimisation, ROM not firmware-initialised). It is an estimate, not a measurement of the SoC. The measured flat result is about 15 percent higher in LUT4 and has 12 rather than 8 multipliers. I have not investigated why (candidates: the flat run includes the firmware ROM and top-level glue; the per-module sum may omit modules). That is unexplained.

## 3. ULX3S 85F capacity
Device per the ULX3S README: LFE5U-85F-6BG381C (read from the emard/ulx3s README, not from a board schematic). Capacity from the Lattice ECP5/ECP5-5G data sheet, Table 1.1, LFE5U-85 column (values as printed, nominal, extracted from the PDF text):
- LUTs: 84 k
- sysMEM blocks (18 kb): 208 (3,744 kb embedded)
- Distributed RAM: 669 kb
- 18x18 multipliers: 156
- PLLs/DLLs: 4/4

Rough fit of the measured synthesis counts (nominal capacities, so approximate):

| Resource | Used | Capacity | Share |
|---|---|---|---|
| LUT4 | 8,837 | about 84,000 | about 10.5 percent |
| TRELLIS_FF | 2,678 | about 84,000 (one FF per LUT site, not checked against nextpnr) | about 3.2 percent |
| DP16KD | 38 | 208 | about 18.3 percent |
| MULT18X18D | 12 | 156 | about 7.7 percent |

CCU2C (carry) and TRELLIS_DPR16X4 (distributed RAM, 352) occupy slice logic; I did not work out how many slices they consume, and the LUT4 line may not capture it. 352 DPR16X4 is probably the PicoRV32 register file or similar, not verified. Synthesis counts are not utilisation: only nextpnr reports real slice packing.
Conclusion: by raw counts the design is far below the device capacity. Whether it routes and meets 25 or 50 MHz is unknown until the workflow below is run.

## 4. Place-and-route feasibility workflow
Files: `.github/workflows/pnr-soc-top.yml`, `fpga/ulx3s_feasibility/README.md`.
- Job `synth`: OSS CAD Suite 2026-10-14 (tarball SHA-256 a6ccc6b9...1a11, computed by me from the downloaded 747,842,179 byte file and re-checked in CI), `synth_ecp5 -noabc9` on flat `soc_top` with ROM init, writes JSON, runs the ROM mapped-content check, and records cell counts. Its Yosys differs from the M8B pinned Yosys, so counts may differ. They are reported separately and must not be mixed into section 1.
- Job `pnr` (matrix 25 MHz and 50 MHz): `nextpnr-ecp5 --85k --package CABGA381 --speed 6 --freq N --seed 1 --lpf-allow-unconstrained`. Logs and report JSON are uploaded even on failure.
- I/O: no pin constraints. Pins are placed arbitrarily, so I/O timing is meaningless. Single seed, so any result is one sample.
- Not done: bitstream, pin LPF, PLL, board wrapper (proposed only, in the fpga README), hardware.

**Update (wrapper+LPF+3 seeds added, see fpga/ulx3s_feasibility/README.md): the workflow now targets ulx3s_top with the ULX3S LPF at 25 MHz only.** Earlier text about no LPF and 25/50 MHz is superseded.

**Status: not run.** I did not run nextpnr here: the sandbox lacks a usable nextpnr (Alpine edge package needs libpython3.12, unavailable) and the OSS CAD Suite tarball (748 MB) was only downloaded for hashing. Not yet checked: that the `-DSYNTHESIS`/include flags and the `u_rom.` instance prefix in the workflow match the M8B workflow, and the YAML has not been parsed here (no PyYAML). Treat the first CI run as the test. No placement, routing, utilisation or timing results exist yet.
