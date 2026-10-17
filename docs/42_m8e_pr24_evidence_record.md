# M8E PR 24: evidence record (documentation only)

Status: record of existing evidence at head a42f89a. No new builds, CI runs or experiments were made for this document. No RTL, firmware or safety logic was changed. Nothing here is board-tested or robot-tested.

## 1. CI synthesis and place-and-route (GitHub Actions run 39029631056, SHA a42f89a)

Source: figures supplied by the owner from the existing run. The artifact zips were not downloaded or re-read in this session, so they are not independently re-checked here.

| Resource (Yosys, flat soc_top, ECP5) | Count |
| :--- | ---: |
| LUT4 | 8710 |
| TRELLIS_FF | 2692 |
| CCU2C (carry) | 586 |
| DP16KD (block RAM) | 38 |
| MULT18X18D | 12 |

Place-and-route Fmax estimate, one run per seed, constraint 25 MHz: 33.74, 34.74 and 34.77 MHz.

Class: SYNTHESIZED and ROUTED (timing estimate from nextpnr). Not a hardware measurement. No bitstream was loaded on a board. Margin over 25 MHz is an estimate only. These numbers replace the pre-UART figures in docs/28 (8,753 LUT4, 32.93 to 33.00 MHz) as the current-head estimate; the differences are not analysed here.

## 2. Local simulation results at a42f89a

| Test | Result |
| :--- | :--- |
| test_uart | fails=0, TB_SOC_UART PASS (W1C clear while busy; drop after clear re-sets overrun; simultaneous clear and drop keeps overrun; reset mid-frame) |
| test_trained_nna | 25 of 25 vectors, 0 LSB error, 58 cycles per inference |
| test_cosim (--steps 10) | ends at the step limit by design; SoC matches Python bit-exact; 8 safety interventions; says nothing about navigation success |
| test_py | exit code 0, PARTIAL (see section 3) |

## 3. Skipped checks (not passes)

Two checks in sw/test/test_rom_bounds.py were SKIPPED because the RISC-V toolchain (ELF) is not available in the sandbox:
1. firmware hex against the ELF;
2. symbols inside the ROM image.

Two other ROM bounds checks passed. The ELF-dependent checks must be run in an environment with the toolchain before ROM-image integrity can be claimed for this head.

## 4. Raw negative-velocity commands in test_py (v = -0.504)

Observation (logs/test_py.log): all three scenarios print raw v=-0.504.

Classification from existing code and docs:
- The scenarios come from `sw/model/robot_policy_e2e.py` `__main__`. `RobotPolicyE2E(seed=42)` builds its weights with `random.randint` (w3 in -40..40, b3 in -50..50). It is a randomly initialised demonstration network, not the trained policy. A constant raw v of -0.504 is therefore an artifact of those arbitrary weights and fixed inputs (v_raw = out[0]/127 * 0.5, so out[0] is about -128, saturated).
- It is not evidence about the trained policy, and not evidence that reverse is handled safely.
- The filter does NOT block reverse. In scenario 1 the raw -0.504 becomes a safe v=-0.020 (slew-limited, reason NORMAL). In scenario 2 (obstacle at 0.10 m) the safe v is -0.040 with reason CRITICAL_OBSTACLE_BRAKE: the reverse command passes through, only slew-limited. This agrees with docs/37 (on the PR 21 branch): at or below the margin, `v = min(0, v)` and reverse is allowed. The watchdog scenario correctly outputs 0.
- Scenario 3 print statement shows `w=` using the v variable (a print typo, `w_s3` is not used). Cosmetic, not fixed here.
- The test scenarios assert only that they ran ("Passed"); they do not check the sign or value of the command.

Conclusion: reverse motion is unresolved. docs/37 D3 requires future physical operation to prohibit reverse until rear sensing and safety validation exist; this is a documentation requirement, not implemented in the filter. No filter change is made here (needs owner approval).

## 5. Limits
- Not board-tested, not robot-tested.
- Yosys/nextpnr results rely on the CI run above; UART TX timing on a real FTDI line is unverified.
