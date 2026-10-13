# Remaining Work Assessment and Milestones (after PR 9 merge)

Basis: docs 17-21 and the roadmap. Nothing here is newly measured. Items marked UNVERIFIED have no evidence.

## Done (evidence in repo)
- Architecture, CPU choice (PicoRV32), memory map, accelerator spec, safety layer docs (01-09).
- RTL testbenches, INT8 reference model, closed-loop cosim with 0 LSB discrepancy (docs 14, 16).
- Per-module Yosys ECP5 synthesis (sum of separate runs only, doc 18/19).

## Not done / open
- Whole-SoC synthesis (soc_top never finished); no place-and-route, no Fmax, no timing, no power.
- Old resource claims (2,686 LUT, 4 DSP) in docs 11/12/CHECKPOINT are superseded but unreproduced.
- nna_regs uses distributed RAM (about 82 percent of NNA LUTs); BRAM inference not done.
- nna_core has 4 multipliers plus 4 in nna_mac4: intent unknown.
- Quantization JSON says 3,986 samples; docs say 2,000.
- Policy is imitation learning (DAgger on an APF teacher), not RL; no RL fine-tuning.
- ROM init in synthesis, real firmware image size: unmeasured.
- Nothing on real hardware: no sensor/motor drivers, no FPGA board chosen.
- Safety layer verified only in simulation; no formal or fault-injection evidence; watchdog/e-stop hardware path unverified.

## Milestones
M1 Evidence cleanup (small, 1 session). Resolve 3,986 vs 2,000; correct docs 11/12/CHECKPOINT to point to doc 18; decide the 4+4 multiplier question. Done when: docs consistent, one regression command green.
M2 Whole-SoC synthesis (needs a machine without 120 s call limit). Run flat soc_top with ROM init, record LUT/FF/DSP/BRAM. Done when: stat file in logs/ with tool version.
M3 BRAM inference for nna_regs. Preconditions in doc 19 sec 5 (regression green, latency analysis, since 58-cycle latency will shift). Done when: cosim still 0 LSB, new latency measured, resynth compared.
M4 FPGA target and P&R. Owner picks board (open question; ECP5 via nextpnr is the current default, unverified). Done when: nextpnr Fmax at 50 MHz target reported, bitstream builds.
M5 Safety hardening. Fault-injection tests (NaN-like/saturated outputs, sensor dropout, stuck policy), watchdog and e-stop path, rate/jerk limits, optional formal checks of the filter. Done when: documented test matrix passes.
M6 Policy upgrade. Add genuine RL fine-tuning (or relabel as imitation), richer environment, domain randomization, re-quantize and re-verify bit-exact. Done when: success rate vs teacher reported with fixed seeds.
M7 Board bring-up. UART, timer, ROM/RAM on real FPGA, run firmware, compare outputs to cosim. Needs M4.
M8 Robot I/O (Phase 6). Sensor drivers (distance, IMU, odometry), motor PWM, mechanical e-stop, wheels-off-ground tests first, human safety gate.

Order: M1 -> M2 -> M3 -> M4 -> M7, with M5 and M6 parallel after M1; M8 last.
Decisions needed from owner: FPGA board; machine for long synthesis; whether imitation learning is acceptable or RL is required.
