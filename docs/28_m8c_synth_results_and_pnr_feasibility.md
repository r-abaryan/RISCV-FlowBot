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

## 4. Place-and-route feasibility workflow (M8C)
Files: `.github/workflows/pnr-soc-top.yml`, `fpga/ulx3s/ulx3s_top.v`, `fpga/ulx3s/ulx3s_85f.lpf`, `scripts/check_rom_mapped.py`, `scripts/check_lpf_ports.py`, `scripts/pnr_classify.py`, `fpga/ulx3s_feasibility/README.md`.

Experiment (the only one defined): top `ulx3s_top` (wrapper + flat firmware-initialised `soc_top`), device `--85k --package CABGA381 --speed 6` (LFE5U-85F-6BG381C), 25 MHz board clock on pin G2 via the LPF, no PLL, seeds 1, 2, 3 as separate matrix jobs. No bitstream, no hardware, no board validation. 50 MHz is not part of this run.

- Job `synth`: pinned OSS CAD Suite 2026-10-14 (tarball SHA-256 a6ccc6b9...1a11, re-checked in CI), `synth_ecp5 -noabc9`, writes JSON and RTLIL. Steps: metadata, synthesis, **mandatory** mapped-ROM content check, LPF/port cross-check. Artifact `soc_top-json` is uploaded with `if: always()`, so logs, exit-status files and the netlist survive failures.
- Job `pnr` (3 seeds): `nextpnr-ecp5 ... --freq 25 --seed N --timing-allow-fail --report ... --log ...`. Then `scripts/pnr_classify.py` assigns exactly one class and fails the job unless it is TIMING_MET. Artifact `pnr-seedN` is uploaded with `if: always()`.
- The Yosys here is the OSS CAD Suite one, not the Yosys pinned for M8B. Its cell counts must be reported separately from section 1.

### 4.1 Result classes
`--timing-allow-fail` only stops nextpnr from aborting on missed timing. A green nextpnr exit is not timing closure.

| Class | Meaning | Job |
|---|---|---|
| TIMING_MET | routing complete, every constrained clock achieved fmax >= constraint (from report.json), at least one clock constrained | green |
| TIMING_FAILED | placed and routed, at least one clock below constraint | red |
| ROUTING_FAILURE | router started, no completion line (Router1 "Routing complete"/"Router1 time", Router2 "Router2 time") | red |
| SETUP_FAILURE | anything earlier: no log, tool/LPF/JSON error, placement failure, missing report or clock | red; a failed `synth` job also means no `pnr` run |

The classifier was exercised on hand-made fixtures for all four classes (not on real nextpnr output). The log strings were taken from nextpnr master source (router1.cc, router2.cc, timing.cc), not from the exact OSS CAD build used in CI; the first run must confirm them. TIMING_MET is a pre-bitstream STA estimate only.

### 4.2 Mapped-ROM check
Stays mandatory; there is no skip. The prefix `u_soc.u_rom.` was checked against a local Yosys 0.68 RTLIL of this wrapper-hierarchy design (cells `\u_soc.u_rom.rom_mem.0.0` to `.0.3`), and `check_rom_mapped.py` reported 531 firmware words matching. That used a different Yosys than CI, so the CI run is still the confirmation. If it fails, the job prints all DP16KD cell names (`dp16kd_cell_names.txt`) for diagnosis.

### 4.3 LPF handling of optimised-away or constant outputs
From nextpnr master `ecp5/lpf.cc` (read, not run on this design):
- `LOCATE COMP "x"` for a name with no matching port/cell is **ignored silently** (`getCellForPinConstraint` returns null, no warning). A typo or an optimised-away port therefore loses its pin without any message. `scripts/check_lpf_ports.py` closes this by comparing JSON ports to LPF LOCATE names (local run on a pre-mapping netlist: 12 ports, 12 locates, OK).
- Unsupported LPF commands give "ignoring unsupported LPF command" warnings. The LPF holds FREQUENCY and LOCATE lines plus comments; check `lpf_warnings.txt`.
- `led[3]` to `led[7]` are tied to constant 0 in the wrapper. They stay as top-level ports, so each should keep a pin and an output buffer driving 0. Whether nextpnr packs a constant-driven output buffer without a warning is **not verified**; expect possible info/warning lines mentioning these ports or constant nets. They are not errors. If the ports are missing from the post-synth JSON, check_lpf_ports.py fails the job.
- Inputs `btn0`/`sw0` feed synchronisers and are used, so they should not be optimised away.
- Not used: `--lpf-allow-unconstrained`. Any unconstrained IO would be a hard error, which is intended.

### 4.4 Reproducibility
Each artifact records: git SHA/ref, run id and attempt, runner image, uname, tool URL and SHA-256, `yosys -V`, `nextpnr-ecp5 --version`, SHA-256 of the LPF, wrapper, soc_top, firmware hex and check scripts, the SHA-256 of the synthesized JSON, the exact nextpnr command (`command.txt`), seed, and per-seed `nextpnr.log`, `stdout.txt`, `exit.txt`, `report.json`, `timing_report.txt`, `lpf_warnings.txt`, `summary.txt`, `result.txt/json`, plus a copy of the LPF.

**Status: not run.** Nothing in 4 has produced a result. Not verified: nextpnr output formats of the CI build, constant-LED buffer behaviour, pin assignments against a schematic, reset/E-stop polarity.
