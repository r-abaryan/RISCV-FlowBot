# ULX3S 85F place-and-route feasibility (M8C)

Status: **workflow not run. Nothing here is a result.**

Target (fixed in `.github/workflows/pnr-soc-top.yml`):
- Device: `--85k --package CABGA381 --speed 6` (LFE5U-85F-6BG381C per emard/ulx3s README; no schematic seen).
- Top: `fpga/ulx3s/ulx3s_top.v` wrapping flat `soc_top` (firmware ROM initialised).
- Clock: `clk_25mhz` at pin G2, `--freq 25` (board oscillator, no PLL). 50 MHz is dropped for this run: it needs a PLL and is not the board clock.
- I/O: `fpga/ulx3s/ulx3s_85f.lpf`, pins copied from emard's `ulx3s_v20.lpf` (clk, ftdi_rxd, btn0=D6, sw0=E8, led0..7). The 32 `*_cmd` monitor bits are unconnected.
- Seeds 1, 2, 3 as separate jobs (still a small sample, not a distribution).
- `--timing-allow-fail` only keeps reports; each seed is classified TIMING_MET / TIMING_FAILED / ROUTING_FAILURE / SETUP_FAILURE and only TIMING_MET is green. Uploads use `if: always()`. See docs/28 section 4.
- Toolchain: OSS CAD Suite 2026-10-14, SHA-256 checked in CI. Its Yosys differs from the M8B-pinned one; counts reported separately.

Unverified assumptions (wrapper):
- BTN_PWRn polarity (assumed high when released) and DIP-switch polarity (sw0=0 treated as E-stop tripped) are not checked on hardware.
- LPF has only the reset/E-stop/clock/UART/LED pins; no motor outputs are on pins yet. Pins not checked against a schematic.
- Reset/E-stop inputs go through 2-FF synchronisers; reset is not a clean async-assert design.
- The wrapper compiles with iverilog (elaboration check only here). Not simulated, not synthesised locally (no Yosys/nextpnr in this sandbox).
- ROM check prefix `u_soc.u_rom.` matched a local Yosys 0.68 netlist (531 words); the check is mandatory and is confirmed only by the CI run.
- YAML parsed and `bash -n` checked locally; nothing executed in CI.
- Constant LEDs led[3..7]: see docs/28 section 4.3 for expected warnings.
