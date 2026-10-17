# M11 ULX3S bring-up checklist and risk register

Status: PLAN ONLY. Nothing here was run on hardware, and no board is in hand. Target: ULX3S 85F (provisional per owner). Each step records an evidence class when executed: simulated, synthesized, routed, board-tested. Today only routed (pre-bitstream STA, docs/28) exists.

## 1. Preconditions (not met)
- UART TX implemented and simulated in PR #24 (RTL commit a42f89a; PR 24 is merged into main; docs/39 is the superseded plan). Simulation only, not board-tested. Without it the FTDI line shows nothing.
- Owner decision on who runs the bring-up. Motors, driver and battery are NOT connected during any step below.
- Board revision identified from silkscreen (the LPF is copied for v2.x/v3.0.x and is not checked against the schematic).

## 2. Bounded checklist
| # | Step | Pass criterion | Failure handling |
|---|---|---|---|
| 0 | Visual check, USB power only, no expansion headers populated | no heat, power LED on | stop |
| 1 | Toolchain: open-source flow (Yosys, nextpnr-ecp5, ecppack, openFPGALoader) versions recorded | versions logged | |
| 2 | Blink test: separate trivial design, LED counter from 25 MHz | LED toggles at the expected rate (stopwatch) | confirms clock, JTAG load, LED pins only |
| 3 | Pin polarity probe design: show btn0 and sw0 on LEDs | measured polarity of BTN_PWRn and DIP matches the LPF notes | update the wrapper comments; fix polarity |
| 4 | FTDI loopback or constant-char test on L4 at 115200 | terminal shows expected character | check baud, wrong pin, FTDI mode |
| 5 | soc_top with UART TX, firmware banner | banner readable, repeatable over 10 resets | log capture saved |
| 6 | Watchdog behaviour: with heartbeat stopped, disarm LED asserts; E-stop DIP asserts disarm | LEDs match; measure time with a stopwatch or logic analyser against the claimed timeout | timeout in seconds is only recorded, not approved |
| 7 | PWM pins to header, observed with scope or logic analyser, no load | duty and frequency as programmed; outputs low while disarmed | |
Stop after step 7. Motor driver connection is M12 and needs the hardware safety design.

## 3. Risk register
| ID | Risk | Evidence | Mitigation |
|---|---|---|---|
| C1 | Clock: 25 MHz oscillator used directly, no PLL. Firmware comments and the watchdog default (2,500,000 counts) assume 50 MHz, which would be 50 ms. At 25 MHz it is 100 ms | CONFIRMED from rtl/safety and wrapper comments | measure in step 6; derive t_wd from the confirmed clock (D7) |
| C2 | Timing margin: Fmax 33.0 MHz (seed 1) against 25 MHz, margin about 8 MHz, pre-bitstream estimate, three seeds | docs/28 | re-run PnR after every RTL change; do not add a PLL without a plan |
| C3 | Resource figure drift: flat estimate about 8.8k LUT4, 12 multipliers; earlier 2,686 claim refuted | docs/28 | cite only docs/28 |
| P1 | PWM outputs are not on header pins; wrapper shows them on LEDs. 32 command bits unconnected | CONFIRMED wrapper and LPF | pin allocation per docs/38 proposal, then LPF review |
| P2 | Pin map copied from the community LPF, not the schematic | LPF header comment | check each used site against the schematic PDF before header use |
| P3 | BTN_PWRn polarity and DIP E-stop polarity unverified. DIP sw0 reads low when off, so default state is E-stop tripped (fail-safe) | wrapper comments | step 3 |
| P4 | 3.3 V only IO, not 5 V tolerant; level shifting needed for 5 V sensors and drivers | docs/38 (manual, unchecked) | shifter in the design before any connection |
| P5 | Shared pins (ESP32 on J1 11-13, ADC on J2 14-17) | docs/38 | avoid |
| P6 | Header pin state while unconfigured and during configuration: motor driver could see a floating or pulled input | NOT CHECKED | read the ECP5 datasheet on configuration IO state; driver enable must default OFF through an external pull-down/pull-up chosen for safe state |
| S1 | RTL watchdog and E-stop only disable PWM within the FPGA. They do not cut motor power | docs/37 P10 | independent hardware E-stop and power cut, not yet designed |
| S2 | DIP switch is not a physical E-stop | | M12 design |
| S3 | A bitstream flashed to SPI persists; a bad build could power up and run | | use volatile SRAM load via JTAG for early tests |
| S4 | No RX or link to the Pi yet; no sensor or encoder interfaces in soc_top | docs/38 | later milestone, new RTL needs approval |
| S5 | Safety margins (25 cm, 40 cm) are unapproved; physical thresholds TBD | docs/37 | no motion until derived |

## 4. Deliverables for M11 (when approved)
Logged tool versions, bitstream hash, serial captures, a photo or measurement record per step, an updated evidence table. Estimated effort once board and UART exist: half a day for steps 0 to 5, one day with steps 6 and 7 (estimate).
