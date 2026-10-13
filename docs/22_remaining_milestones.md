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

## Owner decisions (PR 10 review, 2026-10-13)
1. Provisional FPGA target: ULX3S 85F (Lattice ECP5). Not final. No board is assumed to be available. Nothing below about the board is verified yet; M4 must check it (see M4 checklist).
2. Whole-SoC synthesis runs as a manually triggered (workflow_dispatch) GitHub Actions job on ubuntu-24.04, not in the sandbox. No automatic deployment or merging.
3. Imitation learning (DAgger on an APF teacher) is accepted as the functional baseline only. The original RL objective stays open; genuine RL fine-tuning and a fixed-seed comparison against the teacher are in M6. Results must be labelled imitation learning.

This PR is documentation only. No implementation, no enabling of workflows, no hardware purchase, no merge without separate authorization.

## Milestones
M1 Evidence discrepancies (small, 1 session). Do not repeat PR 9 corrections. Only the still-unresolved items: 3,986 vs 2,000 samples (trace which script/dataset produced each number), the 4+4 multiplier intent (nna_core vs nna_mac4), and any remaining stale 2,686 LUT / 4 DSP references that PR 9 did not fix (grep first). Done when: each item is resolved or recorded as unresolved with evidence, one regression command green.

M2 Whole-SoC synthesis via GitHub Actions. Baseline before the M3 BRAM refactor; keep its logs as the reference. Workflow: workflow_dispatch only, runs-on ubuntu-24.04, pinned Yosys version (or pinned container image digest, exact version to be chosen and recorded), correct soc_top parameters, ROM initialized from the real firmware hex, explicit timeout-minutes, uploads log and stat JSON as artifacts, no deploy step, no write permissions (contents: read). The workflow file is added in a separate authorized change and is not enabled by this PR. Done when: one run's artifacts show LUT/FF/DSP/BRAM and tool version. Open: exact tool pin and runner time are unknown until a run happens.

M3 BRAM inference for nna_regs, after M2 baseline is recorded. Preconditions in doc 19 sec 5 (regression green, latency analysis, since 58-cycle latency will shift). Done when: cosim still 0 LSB, new latency measured, resynth compared against the M2 baseline.

M4 FPGA target verification and P&R. Provisional board: ULX3S 85F. Checklist to verify from primary sources (vendor/board docs), not from memory: exact FPGA part and LUT/BRAM/multiplier counts; current availability and lead time and price (no purchase without authorization); programming path (USB programmer, openFPGALoader support, flash vs SRAM); on-board clock frequency and PLL use; which external I/O pins (PMOD/GPIO) are exposed, their voltage levels (3.3 V) and current limits; UART via USB; whether SDRAM/other resources are needed (not planned). Then nextpnr-ecp5 Fmax at the 50 MHz target and bitstream build. Done when: checklist filled with sources and P&R report stored.

M5 Safety hardening. Start from the existing RTL adversarial safety tests (inventory them first) and expand coverage: NaN-like/saturated outputs, sensor dropout, stuck policy, watchdog and e-stop path, rate/jerk limits, optional formal checks. Done when: documented test matrix, with existing tests mapped to rows, passes.

M6 Policy upgrade. Genuine RL fine-tuning starting from the imitation policy, richer environment, domain randomization, re-quantize and re-verify bit-exact. Compare against the imitation teacher with fixed seeds and report success/collision rates for both. If RL is not achieved, label the policy imitation learning everywhere.

M7 Board bring-up (needs M4 and an owner-confirmed physical board). UART, timer, ROM/RAM, run firmware, compare to cosim. ELECTRICAL SAFETY GATE (all required before start): board and pin voltages verified against datasheets; no motor, battery or actuator power connected; only USB power; owner sign-off recorded in the repo.

M8 Robot I/O. Sensor drivers, motor PWM, mechanical e-stop. ELECTRICAL SAFETY GATES (all required, each with written owner sign-off): level shifting/isolation between 3.3 V FPGA I/O and sensors/motor drivers reviewed; independent hardware e-stop that cuts motor power without relying on FPGA or CPU; fuse/current limit on motor supply; motor drivers default to off on reset/FPGA unconfigured (pull-downs verified); wheels-off-ground tests first; watchdog verified (M5) to disable outputs; a human present with access to the e-stop; no tethered-free operation until all prior tests pass.

Order: M1 -> M2 -> M3 -> M4 -> M7, with M5 and M6 parallel after M1; M8 last.

## Remaining open questions
- Final board choice and availability (provisional ULX3S 85F, unverified).
- Tool pin and runtime for the CI synthesis job.
- Whether genuine RL will beat or match the imitation teacher.
