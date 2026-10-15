# 32. M8E: synthesis and place-and-route results with UART TX (verified from CI artifacts)

Hardware validation: NOT DONE. No bitstream, no board, no UART bytes observed on a pin. Everything below is a Yosys/nextpnr pre-bitstream estimate.

## 1. Evidence
- Workflow run 38733498294 (`pnr-soc-top`, run #2), conclusion success, 2m35s, commit 2f34909c7f105ecf5b290fab2429c41b36e7bbac, branch `flowbot/m8e-uart-tx`.
  https://github.com/r-abaryan/RISCV-FlowBot/actions/runs/38733498294
- Artifacts (downloaded, sha256 compared with the GitHub digest: all four match):
  | Artifact | id | sha256 |
  |---|---|---|
  | soc_top-json | 11971458384 | 4d582e9b4ceb9755e901501c950768bd341b9aaeb82c2c07d5795acfc4d5908f |
  | pnr-seed3 | 11971314285 | 8c559afaf057675792ee72d9402325f8402a1fe732aa1a4dcbc569d9f71a1221 |
  | pnr-seed2 | 11970819481 | 11cf8d2af5119360bcdf8028bf787e494d1652b154018146ad779717c0668b3d |
  | pnr-seed1 | 11970674213 | 381a644b8786b459a99b3d3718363c0fb6369b96c8fcc82cd8ff315629e3b03d |
  Artifact URLs are of the form https://github.com/r-abaryan/RISCV-FlowBot/actions/runs/38733498294/artifacts/ID and need a GitHub login to download. GitHub retention may expire them. Small text extracts are kept in `logs/pnr_m8e/`. The full netlist (soc_top.json) is not committed.
- Tools (tool_versions.txt): Yosys 0.70+16 (git 3bb533450), nextpnr-0.11.1-63-g44a6c739, OSS CAD Suite 2026-10-14. Same as M8C.
- Target: LFE5U-85F-6BG381C, speed 6, 25 MHz constraint, seeds 1-3, `--timing-allow-fail`, classified by scripts/pnr_classify.py.

## 2. Results
| Seed | Result | Fmax final | Fmax post-placement |
|---|---|---|---|
| 1 | TIMING_MET, routed | 31.73 MHz | 28.69 MHz |
| 2 | TIMING_MET, routed | 35.59 MHz | 33.03 MHz |
| 3 | TIMING_MET, routed | 34.02 MHz | 30.84 MHz |

Margin over 25 MHz: 6.7 to 10.6 MHz. Seed-to-seed spread is 3.9 MHz, so 3 seeds is a small sample and no average is claimed.
Checks passed: Yosys exit 0, OSS tarball sha OK, ROM_MAPPED_CONTENT_MATCH (531 firmware words), LPF ports=12 locates=12 status=OK.
The critical path was not analysed.

## 3. Comparison with M8C (docs/28, commit dac57fb, run 38706204639)
| Metric | M8C | M8E | Delta |
|---|---|---|---|
| Yosys LUT4 | 8,753 | 8,739 | -14 |
| Yosys CCU2C | 579 | 591 | +12 |
| Yosys TRELLIS_FF | 2,682 | 2,706 | +24 |
| TRELLIS_DPR16X4 | 352 | 352 | 0 |
| DP16KD | 38 | 38 | 0 |
| MULT18X18D | 12 | 12 | 0 |
| nextpnr TRELLIS_COMB | 12,183 (14%) | 12,205 (14%) | +22 |
| nextpnr TRELLIS_FF | 2,682 (3%) | 2,706 (3%) | +24 |
| nextpnr RAMW | 352 | 352 | 0 |
| Fmax final, seeds 1/2/3 | 33.00 / 32.94 / 32.93 | 31.73 / 35.59 / 34.02 | -1.27 / +2.65 / +1.09 |

Notes. The +24 FF is plausible for a divider counter, shift register and state bits, but I did not itemise them. The LUT4 count went down by 14 despite new logic, which I did not explain (likely different optimisation of unrelated logic, a guess). Utilisation was identical on all three M8E seeds. M8C values are taken from docs/28, not re-derived here. The Fmax differences are within what seed variation could produce; I make no claim that the UART changed timing.

## 4. UART TX is no longer constant-driven (checked on the synthesized netlist)
Method: python3 over soc_top.json from artifact soc_top-json (see logs/pnr_m8e/ftdi_rxd_netlist_check.txt).
- Port `ftdi_rxd` (net bit 5) is driven by a TRELLIS_FF (`ftdi_rxd_TRELLIS_FF_Q`, REGSET=SET so idle is high). Its D input comes through a PFUMX from two LUT4 cells that take non-constant nets, including the FF's own output.
- M8C `lpf_port_check` reported "ftdi_rxd is driven by constant 1". The M8E check reports constants only for led[3] to led[7] (constant 0), and no longer for ftdi_rxd.
Limits: this shows the pin is driven by sequential logic, not that the logic is correct on the wire. Correct framing is covered by the simulation tests, and no hardware waveform exists. The FTDI direction naming (ftdi_rxd is the FPGA output to the FTDI RX pin) follows the existing LPF, not verified against the board schematic.

## 5. Not verified
Hardware operation, bitstream generation, real UART output at 115200 baud, IO timing, power, critical path content, multi-clock relations, anything beyond 25 MHz.
