# 28. M8c: ULX3S 85F place-and-route results (CI run 38706204639)

Source: GitHub Actions run 38706204639, commit dac57fb on flowbot/m8c-ulx3s-pnr-workflow.
Artifacts (owner-downloaded, sha256 verified against the run page digests): pnr-seed1/2/3, soc_top-json.
Raw extracts: logs/pnr_m8c/.

Tool: Yosys 0.70+16 (git 3bb533450), nextpnr-0.11.1-63-g44a6c739, OSS CAD Suite 2026-10-14 (sha256 a6ccc6b96b2d9853...457881a11).
Target: LFE5U-85F, CABGA381, speed 6, 25 MHz constraint. Pre-bitstream STA estimate only. No hardware, no bitstream.

## Results
| Seed | Result | Fmax (final) | Fmax (post-placement) |
|---|---|---|---|
| 1 | TIMING_MET, routed | 33.00 MHz | 31.18 MHz |
| 2 | TIMING_MET, routed | 32.94 MHz | 30.22 MHz |
| 3 | TIMING_MET, routed | 32.93 MHz | 29.50 MHz |

Fmax is only 7.9 to 8.0 MHz above the 25 MHz constraint.
Only one clock domain was reported. The critical path location was not analysed (I did not verify it).

## Utilization (nextpnr, seed 1)
TRELLIS_COMB 12183/83640 (14%), TRELLIS_FF 2682 (3%), TRELLIS_RAMW 352, DP16KD 38/208 (18%), MULT18X18D 12/156 (7%), IO 12/365.
Yosys pre-PnR (stat_summary): LUT4 8753, CCU2C 579, TRELLIS_FF 2682, TRELLIS_DPR16X4 352, DP16KD 38, MULT18X18D 12.
The 2,686 LUT4 / 4 DSP claim in docs 11/12 is refuted: the flat count is about 8.8k LUT4 plus 579 carry cells, 12 multipliers.
(2,686 is close to the FF count 2,682 - possibly a mislabel, but that is speculation.)

## Checks
- ROM: ROM_MAPPED_CONTENT_MATCH, 531 firmware words in the mapped netlist (u_soc.u_rom.).
- LPF: ports=12 locates=12 status=OK. Notes: ftdi_rxd and led[3..7] driven by constants.
- Yosys exit 0, OSS tarball sha OK.

## Caveats
- Seeds ran with --timing-allow-fail; classification was done by scripts/pnr_classify.py.
- Estimate only: not a bitstream, no hardware run, no power or IO timing verification.
- The temporary push trigger has already been removed (commit bad69f1); the workflow now has only workflow_dispatch.
