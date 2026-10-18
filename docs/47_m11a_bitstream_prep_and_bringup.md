# M11a: ULX3S 85F bitstream preparation and bring-up procedure

Status: PREPARED, NOT BUILT. No bitstream exists. No board validation. No motors or drivers may be connected during M11.

## 0. PR #28 review-fix revision
- PR #28 ADDS a new manual workflow, `.github/workflows/m11a-bitstream.yml` (workflow_dispatch only; not yet run, not to be dispatched until owner approval). It builds with a clean single `all`-mode run.
- Gates, each recorded independently in out_m11a/status/: synth, ROM mapped check, LPF port check, timing (scripts/pnr_classify.py must return TIMING_MET at 25 MHz; nextpnr exit 0 alone is insufficient; classifier criteria unchanged, the script writes exit.txt/stdout.txt/report.json/nextpnr.log in out_m11a/pnr/), pack. Missing or failed gate => nonzero exit, no later stage. Standalone pnr/pack reject missing or stale intermediates (inputs.sha256 vs HEAD/source hashes).
- Artifact and job summary include source SHA, firmware hash, tool versions, bitstream SHA-256, PASS/FAIL per gate; artifact uploaded with if: always().
- Any bitstream produced is an UNVALIDATED bitstream CANDIDATE: not board-tested, not a validated design, not a hardware result.
- Verification of this revision: mocked failure-path test only (tests/test_m11a_build_failpaths.sh, fake tools). Yosys, nextpnr, ecppack and GitHub Actions were NOT run.

## 1. Build result (honest)
- Script added: scripts/build_ulx3s_bitstream.sh (synth, pnr, pack, all). Same commands as .github/workflows/pnr-soc-top.yml, seed fixed to 1, 25 MHz, plus ecppack with --compress --idcode 0x41113043. The script has not been run to completion.
- Attempt: one synth run in the agent sandbox with the pinned OSS CAD Suite 2026-10-14 (tarball sha256 a6ccc6b9...1a11, matches CI pin; Yosys 0.70+16 git 3bb533450, nextpnr 0.11.1-63-g44a6c739, ecppack 1.4-86-ga31ff70).
- Outcome: Yosys was killed by the kernel out-of-memory killer (cgroup limit, about 458 MB RAM) during synth_ecp5 LUT mapping. This is an environment blocker, not a design result. Not retried, per instructions. No PNR, no bitstream, no resource or timing figure from this run.
- Metadata of the attempt: logs/m11a/metadata.txt.
- Available evidence remains the CI run 39029631056 (docs/42): synthesized and routed estimates only, Fmax 33.74/34.74/34.77 MHz at 25 MHz constraint, not board measurements.
- Minimum way to finish: run `OSS=<oss-cad-suite> scripts/build_ulx3s_bitstream.sh all` on a machine with enough RAM (several GB), or ask owner to approve a manual CI job that calls it. 

## 2. Inputs checked
- Source commit: 199390a9fa7c408c1eac0cd1dddbfa6a8158a83b (main after PR 22 merge; PRs 23-25 merged).
- sw/firmware/robot_nav.hex sha256 1f5de89445ebf7753cba1caf8c17b72289319749053aa51a19f03300cabb1464, last changed by 56435fd (M10c nonnegative velocity rebuild, merged in PR 25). 533 words. The build script records this hash and runs scripts/check_rom_mapped.py (mapped-ROM check) and scripts/check_lpf_ports.py (LPF vs port check); neither was executed on a fresh netlist here.
- fpga/ulx3s/ulx3s_85f.lpf sha256 470b8860...9533; ulx3s_top.v sha256 0228fc90...1c31; rtl/soc_top.v sha256 badeaeeb...0481.
- No source or pin change was made.

## 3. Banner expected on UART (decoded from the committed robot_nav.hex, 148 bytes)
```
\n=== RISC-V Mobile Robot Navigation SoC Online ===\n
[CORE] RV32IM CPU @ 50MHz\n
[ACCEL] rv_nna INT8 4-way SIMD\n
[SAFETY] Deterministic Interlock Armed\n
\n
```
Hex starts: 0a 3d 3d 3d 20 52 49 53 43 2d 56 ... and ends 41 72 6d 65 64 0a 0a. Settings 115200 8N1. The existing sim/tb_ulx3s_top.v checks only the first 51 bytes.
Note: the banner text says 50MHz but the board clock in this design is 25 MHz (217 clocks per bit). The text is firmware content; it was not changed. Treat as a known documentation inconsistency, not a failure.
Interlock text "Armed" is a string only; it is not evidence of safety function.

## 4. Bring-up procedure (future, motor-free)
1. Disconnect everything from GPIO: no motor drivers, motors, actuators. Only the USB cable.
2. Connect the ULX3S US1 USB port to the host. Power LED should light.
3. Identify the FPGA: `openFPGALoader --detect` (or `-b ulx3s --detect`). Expect an ECP5 with IDCODE 0x41113043 (LFE5U-85F). A different IDCODE means stop.
4. Load to SRAM (volatile, no flash write): `openFPGALoader -b ulx3s ulx3s_top.bit`. Do not write flash in first bring-up.
5. Capture UART: find the FTDI port (/dev/ttyUSB0 or similar), then `stty -F /dev/ttyUSB0 115200 raw -echo; timeout 5 cat /dev/ttyUSB0 | tee capture.bin | xxd`, with the reset/E-stop inputs set as in sim/tb_ulx3s_top.v. Check the input polarity of btn0 and sw0 against the board schematic first; the testbench marks the E-stop DIP polarity as assumed.
6. Compare: `cmp capture.bin <(python3 expected)` against the 148 bytes above (sha256 of expected bytes to be computed from the hex and stored with the result).
7. Record: bitstream sha256, openFPGALoader version, board revision, capture file, photo of setup.

## 5. Pass/fail criteria
Levels (never merge them):
- Pre-bitstream synthesis (CI/sandbox): Yosys exit 0, ROM mapped check passes, LPF port check passes. Currently achieved only in CI, estimate level.
- Bitstream generation: PNR exit 0, ecppack exit 0, bit sha256 recorded, timing report at 25 MHz recorded (a TIMING_FAILED verdict blocks the board test unless owner decides). NOT achieved.
- Physical-board validation (all must hold): IDCODE read as 0x41113043; SRAM load reports success; the captured bytes begin with the 51-byte banner line and match all 148 bytes, no framing errors, over at least 3 power cycles; LEDs behave as in simulation; nothing hot or unstable. FAIL on: wrong IDCODE, no output, garbled bytes (check baud/clock), partial banner, any mismatch. Capture-only; no claim about safety function, E-stop wiring or motors.

## 6. Unresolved (unchanged)
B1/B2/B3, wheel-level reverse behaviour, sensor coverage, unapproved stopping margins, physical safety readiness, UART RX (not implemented), E-stop input polarity, board-level clock and FTDI timing. Prices and board availability are outside this document.
