# M11b M2: motor-command contract v3.1 (soc_pwm). SIMULATION ONLY

Status: implemented in RTL (rtl/periph/soc_pwm.v) and simulated. Not synthesized for this change, not board-tested, not robot-tested.
B1 (timing budget), B2 (driver/EN/PWM frequency), B3 stay open. STALE_CYCLES = 1,250,000 is a simulation-only placeholder, not a physical safety value.
The 25 cm firmware and 40 cm simulation margins are not approved for deployment.

## v3.1 changes vs v3 (owner decisions 2026-11-05, review of 55e35f3)
a. CTRL writes that set both ARM_REQ and FAULT_CLR (0x5, or 0x7 with DISARM) are a request error: neither ARM_REQ nor FAULT_CLR acts.
   ARM_REJECTED is set with reject reason 7 (COMBINED). In 0x7, DISARM still acts (the kill path is never suppressed).
   A latched fault stays latched. Firmware must write FAULT_CLR (0x4) and ARM_REQ (0x1) as separate writes (all three firmware images already do).
b. Reason 7 wins over every other reject reason on that edge.
c. CTRL bits 31:3 are reserved and ignored (for example 0xFFFFFFF9 acts as ARM_REQ).
d. STATUS bit3 WDT_TRIP is a live mirror of the safety_filter watchdog-expired state (status only; the safety_filter stop/disable path is unchanged).
   In v3 as pushed at 55e35f3 this bit was tied to 0 (defect, fixed in 4c8bc5e).

Reject reasons (STATUS bits 14:12): 1 KILL_EDGE, 2 FAULT, 3 DISARM_IN, 4 ARMED, 5 ACTIVE_NZ, 6 CMD_NZ, 7 COMBINED.

## Verification (simulation)
- make -C sim test_soc_pwm_unit: F1a-F1e (0x5 clean, 0x5 with fault latched, separate 0x4 then 0x1 arms, 0x7 while armed, reserved bits).
- make -C sim test_m2_integration: W1-W3 WDT_TRIP visibility.
- make -C sim m2_gate: the M2 regression set, including the safety targets.
- make -C sim test_pwm_refmodel (Stage 1, part of m2_gate): see below.

Stage 1 reference model (`sw/test/pwm_refmodel.py`, `sw/test/test_pwm_refmodel.py`, `sim/tb_pwm_refmodel.v`). A Python cycle model, written from the section 3 priority table, the v3.1 changes and R1-R4, replays the same per-cycle vector file as the RTL TB. All 22 observable fields are compared after every edge: pins, DIR, EN, monitor outputs, ARMED, the three fault latches, ARM_REJECTED, reason, CMD/ACTIVE/SHADOW, stale counter, PWM counter and registered read data. X/Z never compares equal.
- Suite A (PERIOD=3, STALE_CYCLES=4): BFS of the model over every reachable abstract state (all registers except reject/read data) with 72 actions. The actions are 9 bus operations x 4 input classes. The 9 bus operations: all 8 CTRL values plus 0xFFFFFFF9, CMD_L/R in {0, +-1000, +-1001}, COMMIT, STATUS read and idle. The 4 input classes: clear, WDT trip, E-stop, !enable. Result: 150 states, 10,800 transitions, each replayed in RTL as reset -> shortest path -> action -> idle. Invariants checked on every reachable state: never armed with a fault latched; ACTIVE/SHADOW nonzero only while armed and always in range; stale counter in 1..STALE iff armed.
- Suite B (PERIOD=10, STALE=25): CMD pairs from {0, +-1, +-999, +-1000, +-1001, -32768, 32767}^2, committed armed and disarmed. Also: COMMIT at every PWM phase; COMMIT at stale counter 2/1/0; every CTRL value x input class from armed and from range-faulted states; WDT/E-stop pulses while moving.
- Suite C (PERIOD=7, STALE=40): 60,000-cycle walk with a fixed LCG seed (deterministic).
- Suites B/C also drive "E-stop live with disarm_in=0". This is unit-level only: in soc_top the E-stop feeds actuator_disarm combinationally, so it cannot occur there.
- Negative controls, all must be detected (14/14). 11 RTL mutants, as temporary copies: kill keeps CMD, COMMIT beats stale, combined request allowed, range check off, FAULT_CLR ignores CMD, SAFE ignores disarm_in, FAULT_CLR ignores E-stop, E-stop not latched, PWM off-by-one, rollover drops same-edge COMMIT, ARM ignores CMD. Plus 3 model mutants.
- Excluded mutant (equivalent on reachable states, not hidden): ARM_REQ ignoring ACTIVE/SHADOW nonzero. Nonzero ACTIVE/SHADOW implies ARMED (BFS invariant), and ARMED is checked first (reason 4).
- Limits: the same author wrote the model and the RTL, so independence is partial. The BFS is exhaustive only for the small parameters and the chosen value classes; it is not a formal proof for PERIOD=1000 / STALE=1.25M. Not covered: soc_top/firmware interaction (covered by other m2_gate targets), synthesis, board.

C4 static PWM-write allowlist (`make -C sim test_pwm_store_scan`, part of `m2_gate`): `sw/test/pwm_store_scan.py` decodes four ROM images (robot_nav.hex, soc_cosim.hex, firmware.hex from soc_firmware.s, conv_test.hex) as RV32IM and runs a path-sensitive constant propagation from reset. Calls and returns are matched and stack words are tracked. Values widen after 64 distinct values, or 600 for conv_test, whose 512-trip loop needs it. Every store into the PWM window must be an allowlisted (ELF label, register offset, source register) site and an aligned 32-bit `sw`. The window 0x5000_0200..02FF is re-derived from the `is_periph`/`is_pwm` decode in `rtl/bus/soc_interconnect.v` on every run. Any unresolved store base fails closed, with no base-register (sp) exemption. A SYSTEM instruction, an unverifiable jalr or a hit on the state cap also fails. Allowlists: robot_nav 9 sites (arming at `_start`/`arm_wait_shadow`, DISARM at `arm_ok`, CMD_L/CMD_R/COMMIT at `safety_pass`). soc_cosim 9 (same arming, `safety_pass`, DISARM at `cosim_shutdown`). firmware 9 (arming at `banner_wait3`/`arm_wait_shadow`, CMD_L/CMD_R/COMMIT/DISARM at `apply_motor`). conv_test 0, because it is not authorized to write PWM. Provenance runs before each scan (`sw/test/fw_provenance.py`). robot_nav and soc_cosim need on-disk ELF == BIN == tracked HEX and a temp-dir source rebuild that matches. firmware.hex must regenerate exactly from `assemble.py`. conv_test.hex must regenerate exactly from its ELF/BIN, built in a temp dir. A missing or stale prerequisite or tool gives rc 2, never a pass. The target does not depend on `firmware`, and it hashes the tracked hex files before and after the run so they must stay unchanged. 29 negative controls must all fail: NC1-NC6 and NC10 (sb/sh/unaligned sw into the window) per image, plus NC7 tracking bound, NC8 store through an unknown sp and NC9 state cap. Limits: this is a static check of the image only. The narrow-store rule is a firmware-image rule. It is not hardware memory protection: soc_pwm receives byte selects and nothing in hardware blocks a narrow store, and PicoRV32 has no MPU. The check cannot see RAM-executed or corrupted code. The RTL interlocks remain the real protection.

## Appendix: contract v3 as approved 2026-11-03 (unchanged text)
Its "DESIGN ONLY" header and branch/path lines are historical. Where v3.1 above differs, v3.1 wins.

### M11b Milestone 2: motor-command contract v3 (2026-11-03). DESIGN ONLY, NOT IMPLEMENTED

v3 = v2 (M2_CONTRACT_V2.md, kept unchanged) + owner decisions F/G + the three clarifications asked for under H.
Where v3 and v2 disagree, v3 wins. Everything here is a specification. Nothing is implemented, simulated, synthesized or board-tested.
Branch: flowbot/m11b-wdt-budget-and-motor-contract @ 36e7dea (no functional changes since; sim/tb_pwm_period.v still untracked).
B1 (timing budget), B2 (driver/EN/brake), B3 (physical stop/power) stay OPEN. M11a bitstream provenance is untouched (section 7).

#### 0. Decisions recorded
- F (APPROVED): an out-of-range COMMIT is rejected (no clamping), outputs are disabled and FAULT_RANGE is latched. It needs explicit recovery (section 4 of v2).
  v3 detail: the range check applies to every COMMIT write, armed or not, so a firmware bug is latched even while disarmed
  (v2 said a disarmed COMMIT is ignored without a fault. That changes here for out-of-range values only).
- G (APPROVED, sim only): STALE_CYCLES = 1,250,000 is a simulation-only placeholder. It is NOT a physical safety value. B1 and the control-loop period remain open.
- H: conditional. Clarifications below. No implementation until final approval.

#### 1. Clarification H1: why 511, and what gets verified exhaustively
The two numbers describe different interfaces:
- 511 = the INPUT domain of the firmware conversion: v_wheel = v_safe -/+ w_raw. In the current firmware it is bounded by [-256, 254]
  (v range [-128,127] x w range [-128,127]), and that's 511 integers. (M10c makes v_safe >= 0, so the reachable set is smaller: [-128, 255] across L/R
  = 384 values. The test covers the full 511-value range plus 255, i.e. -256..255 = 512, so it does not rely on M10c.)
- 2,001 = the OUTPUT/register domain: CMD_L/CMD_R valid range -1000..+1000 at the new signed RTL interface.
- The conversion cmd = sign(v)*min(1000, (|v|*1000)>>7) maps those 512 inputs onto only 257 distinct values (checked in Python today:
  257 distinct, min -1000, max +1000). Firmware therefore never produces most of the 2,001 values. That is why testing the conversion
  alone cannot verify the interface. The RTL has to be verified directly over its whole input space.
Required verification (all simulation):
- V-IF1 (RTL, exhaustive valid): for each side separately and for both together, every value -1000..+1000 (2,001) committed through the bus;
  measured high cycles in a full period == floor(|cmd|*PERIOD/1000) exactly, DIR == sign (DIR=0 for 0), other side unaffected. 0 mismatches.
- V-IF2 (RTL, exhaustive invalid): every 16-bit value outside -1000..+1000 (65,536 - 2,001 = 63,535 values, including -32768, -1001, +1001, 32767)
  on L with R valid, and on R with L valid -> COMMIT rejected (ACTIVE and SHADOW unchanged/0), FAULT_RANGE latched, outputs inhibited
  from the next edge. The TB runs the recovery sequence between values. 0 escapes.
- V-IF3 (RTL boundary pairs): (L,R) in {-1001,-1000,-1,0,1,1000,1001}^2 = 49 pairs, accepted iff both are in range.
- V-CONV (firmware == Python, new conversion): all 512 v_wheel values -256..255 through the firmware conversion routine (run on the SoC sim via a
  test ROM that calls the same routine as robot_nav), compared with the single Python reference. 0 mismatches. In addition, every reachable (v_safe, w_raw) pair
  (v_safe 0..127 x w_raw -128..127 = 32,768) is checked in Python against the reference, and on the SoC sim for a sampled subset plus all corners
  (full SoC exhaustive costs too much, so the firmware is covered exhaustively at the conversion-routine level).
- V-LEG (legacy, separate): (a) baseline: the existing offset-binary mapping duty=clamp(((v+128)*1000)>>8, 0, 1000) at 36e7dea, Python vs firmware over
  all 511 v_wheel values, recorded BEFORE the change as the reference. (b) the new vs legacy relationship over the same 511 inputs, checked in Python
  today: sign agrees for all 511 values (0 mismatches), and |new/1000 - (legacy-500)/500| <= 0.002 (max observed 0.002). Legacy 500 ("stop") <-> new 0.
  (c) after the change: no code path writes the removed legacy duty registers (single-writer monitor + grep test).
- NC: a 1-LSB perturbed Python reference must FATAL (V-CONV, V-IF1). An RTL build with the range check disabled must FATAL V-IF2.
PERIOD: an RTL parameter. Its default (PWM frequency) is OPEN, tied to the driver choice (B2). Tests run PERIOD=1000 (1 clk per LSB, exact)
and PERIOD=1250 (example only, 20 kHz at 25 MHz nominal, not approved). Runtime for V-IF1/V-IF2 is not measured yet.

#### 2. Clarification H2: E-stop path, latching, inhibit timing; FPGA logic vs physical isolation
Signal path today (read from source at 36e7dea, unchanged by v3 except item 5):
1. Board input: ulx3s_top sw0 (a slide switch used as a placeholder input). Active level and wiring to a real E-stop are UNVERIFIED (B3).
2. ulx3s_top: 2-FF synchronizer estop_sync, init 2'b00 => reads as "tripped" from configuration until 2 clocks after a released level.
3. soc_top: estop_tripped = !ext_estop_n -> safety_filter.pin_estop_button.
4. safety_filter: actuator_disarm = !rst_n | !reg_enable | flag_tripped | pin_estop_button, a COMBINATIONAL OR of the live synced level, so it does not wait for the latch.
   Latch: flag_tripped <= 1 on the next edge, BUT only if reg_enable && !flag_tripped (existing code). With reg_enable=0 the E-stop
   is not latched by safety_filter (outputs are still inhibited, since !reg_enable also disarms).
   Clear: SAFETY_CTRL write with bit1, refused while pin_estop_button=1.
5. NEW soc_pwm (v3): input disarm_in = actuator_disarm, plus a new input estop_live (the synced level). On any edge with disarm_in=1:
   ARMED<=0, ACTIVE<=0, SHADOW<=0, CMD_L/R staged <=0. The E-stop latches STATUS.ESTOP_SEEN regardless of reg_enable (this closes the gap in item 4).
   ESTOP_SEEN is cleared only by FAULT_CLR while estop_live=0.
6. Output stage: pwm_x_out = !SAFE & (counter < high(SHADOW)), en_out = !SAFE (polarity parameter, default not approved),
   SAFE = !rst_n | disarm_in | !ARMED | FAULT_STALE | FAULT_RANGE | ESTOP_SEEN. This is combinational from registered/synced signals. There is no register between SAFE and the pins.
Logic timing (FPGA logic only, nominal 25 MHz, B1 open for the real clock):
- Input level change -> pins low/EN inactive: <= 3 clock edges (<= 1 edge to be sampled by sync FF1, +1 to FF2, then combinational) = <= 120 ns plus
  combinational/IO delay (not characterized; no timing report covers this path yet). Latching (flag_tripped, ESTOP_SEEN, ARMED<=0) happens on the edge after that.
- A pulse shorter than one clock period may be missed by the synchronizer. A real E-stop is a held contact, but this is still a limitation.
- The logic path needs: FPGA configured, clock running, synchronizer clocked. If the clock stops, the FPGA is unconfigured/reconfiguring, or the logic
  has a fault, the logic E-stop DOES NOT act. During configuration the pin state is set by ECP5 IO defaults and board pulls. That is NOT verified.
Physical isolation (required, NOT designed here, B3):
- The E-stop must remove motor power through a path independent of the FPGA, firmware and clock (e.g. a latching mushroom switch breaking motor supply
  via contactor/relay or the driver's power input). It must stay latched until a manual reset.
- Driver EN/STBY needs an external pull to the disabled state, so an unconfigured/tri-stated FPGA cannot enable it (B2).
- A second E-stop contact (or an auxiliary contact) feeds the FPGA input only for status/latching. The FPGA path is a secondary, not the primary, stop.
- No stopping distance or time is claimed. The <= 3 clk number is logic latency only.

#### 3. Clarification H3: simultaneous events, priority and timing
Facts: there is one Wishbone master (PicoRV32), so at most ONE bus write (CTRL, CMD_L, CMD_R or COMMIT) per clock. A write takes effect at the edge
that sets wb_ack_o. Reset asserts asynchronously and releases synchronously (rst_sync, 2 FF). All other state changes on rising clk.
Per edge, soc_pwm evaluates (highest first). The first matching row decides ARMED/ACTIVE; the fault bits are ORed (all applicable causes latch, STATUS shows all):
| P | Condition at this edge | Effect at this edge |
|---|---|---|
| 0 | rst_n=0 (async) | everything reset: ARMED=0, ACTIVE=SHADOW=CMD=0, counter=0, faults cleared, stale counter idle |
| 1 | KILL = disarm_in or stale_hit or range_bad or CTRL.DISARM write or any fault already latched | ARMED<=0, ACTIVE<=0, SHADOW<=0, CMD_L/R<=0; latch FAULT_STALE if stale_hit, FAULT_RANGE if range_bad, ESTOP_SEEN if estop_live. Any COMMIT/ARM_REQ/FAULT_CLR on the same edge is discarded (ARM_REQ/FAULT_CLR set ARM_REJECTED). Exception: FAULT_CLR is evaluated when the only KILL term is "fault already latched" (row 2) |
| 2 | FAULT_CLR write, no other KILL term | clears FAULT_STALE/FAULT_RANGE/ESTOP_SEEN iff disarm_in=0, estop_live=0, ARMED=0, ACTIVE=0, CMD_L=CMD_R=0; else ARM_REJECTED. Never sets ARMED |
| 3 | ARM_REQ write | ARMED<=1 iff no fault, disarm_in=0, ACTIVE=0, CMD_L=CMD_R=0; stale counter <= STALE_CYCLES; else ARM_REJECTED |
| 4 | COMMIT write, ARMED, in range | ACTIVE_L/R <= CMD_L/R (both, same edge); stale counter <= STALE_CYCLES |
| 5 | COMMIT write, not ARMED, in range | ignored, no fault |
| - | PWM rollover (counter == PERIOD-1) | SHADOW <= (row 1 ? 0 : ACTIVE_next). A COMMIT on the rollover edge takes effect from the next period |
Definitions: range_bad = COMMIT write && (CMD_L or CMD_R outside -1000..1000), evaluated armed or not (decision F).
stale_hit = ARMED && stale counter == 1 && no accepted reload on this edge. The counter decrements every clock while ARMED.
Pairwise outcomes (each is a directed test, section 5):
- COMMIT + stale expiry, same edge: stale wins (FAULT_STALE, ACTIVE=0). A COMMIT does not rescue an expiring timer on the exact expiry edge.
- COMMIT + E-stop/WDT/disable (disarm_in=1): kill wins, the COMMIT is discarded and CMD is cleared.
- COMMIT + rollover: accepted value loads into SHADOW at that edge, so it starts with the next period. The current pulse is never altered.
- Kill + rollover: SHADOW <= 0, and the pin was already low from SAFE.
- DISARM write + rollover: as kill.
- Reset during anything: row 0 (async).
- FAULT_CLR + E-stop still held: rejected. FAULT_CLR + stale_hit can't happen (ARMED must be 0 for FAULT_CLR to succeed, and stale only counts while ARMED).
- ARM_REQ in the same edge as disarm_in: rejected.
Pending commands can never become active after a fault:
(a) the kill edge zeroes ACTIVE, SHADOW and the staged CMD_L/R; (b) ACTIVE can only be written by row 4, which requires ARMED; (c) ARMED is cleared by
every fault and can only be set by row 3, which requires no fault, ACTIVE=0 and staged CMD=0; (d) FAULT_CLR never arms. So any command staged or
committed before the fault is gone, and motion needs fresh CMD writes + COMMIT after the explicit FAULT_CLR -> ARM_REQ sequence.
Output timing: P1 causes from registered flags (stale, range, DISARM) -> pins low from the kill edge (<= 1 clk after the event is registered).
disarm_in -> pins low combinationally in the same cycle (section 2). Stale: last accepted reload at edge t0 -> FAULT_STALE at edge t0+STALE_CYCLES.

#### 4. Unchanged from v2
Register map (sections 1-2) except the STATUS additions ESTOP_SEEN and ARM_REJECTED reasons, the arm sequence (section 4), output gating (5), stale bounds (8),
conversion (9). The safety_filter RTL is NOT modified.

#### 5. Verification matrix (simulation only; criteria fixed in advance; NC must FATAL)
| ID | Requirement | Method | Pass criterion |
|---|---|---|---|
| T1 | reset state | RTL TB | ARMED=0, ACTIVE=SHADOW=0, pins low, EN inactive for >= 2 periods after release |
| T2 | zero cmd | RTL TB | 0 high cycles over 3 periods, both sides, both DIR |
| V-IF1 | all 2,001 valid values | RTL exhaustive, PERIOD 1000 and 1250 | high cycles == floor(|c|*PERIOD/1000), DIR correct, 0 mismatches |
| V-IF2 | all 63,535 invalid values, per side | RTL exhaustive | rejected, FAULT_RANGE, outputs inhibited from kill edge, 0 escapes |
| V-IF3 | 49 boundary pairs | RTL | accepted iff both in range |
| T4 | atomic L/R + mid-period commit | RTL | both sides change at the same rollover, current pulse unaltered |
| T5 | in-range commit while disarmed/faulted | RTL | no pin effect, no fault |
| T6 | range fault while disarmed | RTL | FAULT_RANGE latched (decision F) |
| T7 | stale exact timing | RTL, STALE override 2000 + one run at 1,250,000 | FAULT_STALE at edge t0+STALE_CYCLES exactly, pins low from that edge |
| T8 | stale independent of heartbeat | RTL/SoC | heartbeats continue, no COMMIT -> trips |
| T9 | no auto-resume | RTL | COMMIT after any fault -> still SAFE, ACTIVE=0 |
| T10 | recovery sequence | RTL | only CMD=0 -> FAULT_CLR -> ARM_REQ arms; each skipped/reordered step -> ARM_REJECTED |
| T11 | FAULT_CLR preconditions | RTL | rejected with E-stop held, non-zero staged cmd, ACTIVE!=0, or disarm_in |
| S1..S9 | section 3 pairwise cases (COMMIT+stale, COMMIT+disarm, COMMIT+rollover, kill+rollover, DISARM+rollover, reset mid-pulse, FAULT_CLR+E-stop, ARM+disarm, COMMIT+E-stop on rollover) | RTL directed, cycle-exact stimulus | outcome as the section 3 table, at the stated edge |
| P1 | pending cmd never activates after fault | RTL directed + random (seeded, >= 10k events, seeds logged) | assertion: ACTIVE!=0 implies ARMED and an accepted COMMIT since the last ARM; 0 violations |
| E1 | E-stop path ulx3s_top -> pins | ulx3s_top TB | pins low <= 3 edges after the input change; ESTOP_SEEN latched with reg_enable=0 and =1; clear refused while held |
| E2 | E-stop at power-up | ulx3s_top TB | outputs inhibited from the first clock (sync init 00) |
| V-CONV | firmware == Python new conversion | SoC sim test ROM + Python | 512/512 match; 32,768 pairs in Python; corners on SoC |
| V-LEG | legacy baseline + sign relation + no legacy writes | SoC sim at 36e7dea, Python, monitor | 511/511 baseline match; 0 sign mismatches; 0 legacy writes |
| T16-T18 | SoC nav regressions, char_pwm_idle, full div217 | existing targets, updated expectations | rc=0, SUCCESS lines, WDT margin reported |
| ROM | strict ROM bounds | make -C sim test_rom_bounds | rc=0, 0 SKIPPED (section 6) |
| NC1-4 | v2 negative controls (stale monitor off, foreign writer, out-of-range accepted, 1-LSB ref) | as v2 | each FATALs |
| NC5 | range check disabled build | V-IF2 | FATAL |
| NC6 | kill not clearing staged CMD (mutant) | P1 | FATAL |
| NC7 | COMMIT allowed to win over stale_hit (mutant) | S1 | FATAL |
Not covered: synthesis/PnR/timing of the new RTL (M11a follow-up, needs approval), board, physical E-stop, driver behaviour.

#### 6. Strict ROM-bounds gate, run independently of test_py (2026-11-03 22:37 UTC, HEAD 36e7dea)
- Command: make -C sim test_rom_bounds, alone (no test_py). Log: rom_bounds_strict_2026-11-03d.out (sha256 26661a2d...).
- Result: EXIT=0; "SUMMARY: 7 passed ... 0 SKIPPED (none)" with REQUIRE_ELF=1; "15/15 ROM-bounds controls behaved as expected".
- Same target with riscv binutils hidden from PATH: EXIT=2, "FAIL test_rom_bounds: riscv-none-elf binutils missing (not a pass)".
  Log rom_bounds_no_toolchain_2026-11-03d.out (sha256 30eda7b2...). Worktree before/after: only sim/tb_pwm_period.v untracked.

#### 7. Preserved
- M11a: /workspace/m11a_provenance/ulx3s_top.bit sha256 73c761bf...57ae == bit.sha256 (rechecked today); archive m11a-bitstream.zip sha256 3cdac680...d7d2.
  UNVALIDATED, not board-tested. No fpga/ changes on the M11b branch.
- B1/B2/B3 open. 25 cm / 40 cm margins and STALE_CYCLES are not approved for deployment.

#### 8. For final approval
H-final: approve v3 (sections 1-5) for implementation on the existing branch, including the v3 additions: range check while disarmed,
staged CMD cleared on kill, ESTOP_SEEN latch in soc_pwm, and "stale wins over a same-edge COMMIT".
