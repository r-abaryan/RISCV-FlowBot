# FlowBot: From Silicon to Motion. Physical robot hardware architecture proposal

Status: PROPOSAL for owner review. Not a purchase order. Nothing has been bought, wired or tested. Simulation results (docs/30 to 35) are not approval for physical deployment, and risks R1 to R7 (docs/35) remain open.

Component status labels used below:
- CONFIRMED: decided by the owner or verified from a repository file.
- ASSUMED: my design choice or a typical value, not verified against a datasheet or a vendor listing.
- NOT SELECTED: open choice; options are listed.

Prices and availability are NOT verified (no vendor lookup was done). Cost figures are rough order-of-magnitude placeholders in USD and must be replaced with real quotes.

## 1. What is confirmed vs not

| Item | Status | Basis |
| :--- | :---: | :--- |
| ULX3S 85F (LFE5U-85F) as the FPGA board | CONFIRMED (owner decision, provisional per earlier note) | owner |
| SoC clock 25 MHz, estimated Fmax about 33 MHz | CONFIRMED as pre-bitstream estimate only | docs/28 |
| Current RTL top-level I/O: ext_estop_n, uart_tx, pwm_left_out, pwm_right_out, actuator_disarm | CONFIRMED | rtl/soc_top.v |
| Differential drive, low speed, indoor | CONFIRMED (owner) | owner |
| Everything else (chassis, motors, sensors, battery) | ASSUMED or NOT SELECTED | this document |

## 2. Gaps between current RTL and a real robot (important)

The current SoC cannot yet drive a real robot. Missing, and to be designed in later milestones:
1. **No motor direction output.** soc_pwm has only a 16-bit duty per side and one PWM pin per side. A DC motor driver needs direction (or two PWM pins per motor). Needs an RTL or pin-mapping change.
2. **No encoder input peripheral** (quadrature counters).
3. **No distance-sensor input peripheral.** Today the Python/firmware safety filter takes distances as numbers; there is no RTL path from a real sensor. Which bus (I2C, SPI, GPIO echo, UART) depends on the sensor choice.
4. **No IMU interface** (I2C/SPI controller) and no UART RX (only TX exists).
5. **No distance-based avoidance in RTL.** The only hardware safety is the heartbeat/E-stop watchdog (actuator_disarm). The hardware safety path must not rely on firmware or the neural net (R-series risks).
6. Margin mismatch: 40 cm in Python vs 25 cm in firmware (R-series, docs/35). Must be reconciled against real stopping distance before any motor test on the floor.

## 3. Platform proposal (all ASSUMED)

- **Chassis:** two-wheel differential drive plus one passive ball caster, flat 3 mm acrylic or 3D-printed PLA/PETG plates, two stacked decks. Target footprint about 220 mm long x 200 mm wide, height about 150 mm, mass under 2 kg. Note the simulator robot radius is 0.25 m (diameter 0.5 m), much larger than this proposal; the sim must be rescaled (or the real robot's dimensions fed into the env) before any policy is transferred. This mismatch is a risk.
- **Wheels:** 65 mm diameter rubber tyres on the motor shafts. Wheel track about 170 mm.
- **Speed limit:** PROPOSED cap of 0.3 m/s for first floor tests (a proposal, not a decided value: v_max is TBD in docs/37 and the first-test maximum speed is an open owner decision in docs/46; firmware and hardware limit), versus 0.8 m/s in the simulator. A policy trained for sim speeds is not validated at this speed or on real friction.
- **Motors:** two 6 V to 12 V brushed DC gearmotors with integrated magnetic quadrature encoders (Pololu 25D-class or N20-class). Suggested gearbox ratio around 30:1 to 50:1, giving a no-load wheel speed of order 100 to 200 rpm; at 65 mm wheel diameter, 0.3 m/s is about 88 rpm, so there is headroom. Stall current must be checked against the driver rating (NOT SELECTED, datasheet required).
- **Encoders:** magnetic quadrature (hall) on the motor shaft, 3.3 V logic compatible, supply 3.3 V to 5 V depending on the part. ASSUMED. Resolution after gearing needs a calculation once the motor is chosen.
- **Motor drivers:** dual H-bridge, 2 channels, logic compatible with 3.3 V inputs, current rating at least 2x motor stall current. Options: TB6612FNG-class module (1.2 A continuous, small motors), DRV8833-class, or a Pololu-style higher-current driver for 25D motors. NOT SELECTED. Needs an enable pin that can be cut by hardware (see section 6).

## 4. Sensors

- **Obstacle distance (NOT SELECTED).** The trained policy assumes 8 rays over -90 to +90 degrees, i.e. front half-plane only, with zero rear rays and ideal range (docs/35 R: unknown real sensor coverage). Options:
  a. 5 to 8 VL53L1X/VL53L0X-class ToF sensors on I2C (needs XSHUT lines or address changes; narrow cone of order 15 to 27 degrees, so 8 rays at 30 degree spacing would need about 6 sensors for the front plus coverage gaps).
  b. 1 rotating or 2D LiDAR (e.g. LD06/RPLIDAR-class), UART, a better match to the 8-ray model but more expensive and needing a UART RX plus a ray reducer.
  c. Ultrasonic HC-SR04-class: cheap, wide, noisy, 5 V logic (level shifting needed).
  Recommendation (ASSUMED): start with option (a) at 7 front sensors plus 2 rear sensors for reverse/blind-spot safety, then evaluate. Real field of view, minimum range, and mounting must be measured; no claims made here.
- **Rear coverage:** at least 2 rear-facing distance sensors, since the policy has none. A mechanical bumper switch ring wired to the hardware stop path is recommended as a last-resort contact sensor (NOT SELECTED).
- **IMU (optional):** MPU-6050 or ICM-20948-class on I2C, 3.3 V. The policy's required IMU features must be checked against the exact input vector before wiring it.
- **Others, optional:** battery voltage and current monitoring (INA219-class on I2C), wheel odometry from encoders, a cliff sensor if stairs exist.

## 5. Power (all ASSUMED, to be calculated)

- Battery: 2S Li-ion/LiPo (7.4 V nominal) pack, protected, with a fuse. Alternative: 6x AA NiMH (7.2 V), safer for early indoor tests but heavier.
- Motors fed from the battery via the driver, through a fuse and the E-stop contactor path.
- Logic: a separate buck regulator to 5 V (at least 2 A) feeding the ULX3S 5 V input and sensors, with the 3.3 V from the ULX3S board for logic. I have not verified from the ULX3S documentation what input voltage range and current the board's VIN or USB pins accept; this must be checked on the board schematic before connecting. Until then power the ULX3S from USB.
- Protection: inline fuse, reverse-polarity protection, undervoltage cutoff (Li-ion), bulk capacitor at the driver, and ground star point. Motor current spikes must not reset the FPGA: separate regulators and decoupling.
- Power budget: not computed. Needs motor stall current, ULX3S draw and sensor draw from datasheets.

## 5a. Raspberry Pi 5 companion computer (clarification, 2026-10-17; NOT selected or purchased)

- **Included in this BOM?** No. The Pi 5 is not in the section 8 table and not in its USD 130 to 350 sum. docs/38 (PR 22) plans a Pi 5 (4GB or 2GB) with a camera for the vision and sensing experiments (its Stage 1) and prices it in GBP (about GBP 173 for Pi, camera, PSU, cooler, SD card). Whether the Pi is part of the robot is an owner decision; if included, add that cost on top of section 8.
- **Role:** untrusted, advisory only. It may run camera or planning software and send advisory motion requests to the FPGA over a 3.3 V UART. It must not drive motors, clear an E-stop, or disarm. The firmware safety filter, RTL watchdog and physical E-stop stay on the FPGA/hardware side and do not depend on the Pi. The link protocol is a specification only (docs/38 section 8.5); UART RX is NOT implemented in RTL, and PR 24 added only UART TX (simulation evidence only).
- **Power requirements (not computed, ASSUMED):** the Pi 5 is specified by its maker for a 5 V supply of up to 5 A (27 W official PSU); a robot supply must handle load peaks without a brown-out and must be separate from the motor supply path, or sufficiently isolated and decoupled. The 2 A buck regulator in section 5 is NOT enough for a Pi 5 plus the ULX3S and sensors; a larger 5 V converter (or a separate Pi supply and battery) is needed. Pi 5 pad drive current and the exact figures are unverified: check the Raspberry Pi documentation and a measured power budget before wiring. A Pi brown-out or reboot must not affect safety stop behaviour.
- **Common ground and levels:** 3.3 V logic UART with a shared ground. The Pi is powered separately, so a ground and level check is required.
- **Link-loss fail-safe (design intent, values TBD, not implemented):** a command expires after a timeout (200 ms proposed, TBD, must be shorter than the stopping-time budget from docs/37); on expiry the firmware commands zero speed; after a second longer timeout (500 ms proposed, TBD) it requests disarm. Recovery needs several consecutive valid frames and an explicit re-arm from the physical side. Pi crash, reboot, cable pull and hung Pi all appear as no valid frames. A corrupted frame never refreshes the timeout. Independently, the RTL watchdog trips if firmware stops, and the physical E-stop overrides all. Test with a host script and loopback only after approval.

## 6. Emergency stop and watchdog (design intent)

1. **Physical E-stop:** a mushroom or large push-to-break switch that interrupts the motor power path (battery to driver), normally closed, independent of the FPGA and firmware. This is the primary stop and must work with the FPGA powered off, hung or misprogrammed.
2. **Driver enable hardware gate:** driver enable = (FPGA enable) AND (E-stop circuit healthy), implemented in discrete logic or a relay/MOSFET, with pull-down so the default state is disabled.
3. **FPGA path:** ext_estop_n input (already in RTL) feeds actuator_disarm; heartbeat watchdog in safety RTL disables outputs when the CPU stops refreshing the 0x5AFE_C0DE key. The ULX3S DIP switch E-stop used in bring-up is not a safety device (docs/29 R4).
4. Safe state: outputs low, drivers disabled, brakes (driver short-brake) only if verified acceptable.
5. Open question: independent hardware obstacle stop. Options: distance comparator on a stop-critical front sensor feeding the enable gate, or RTL distance check (not yet designed).

## 7. FPGA interfaces (ASSUMED; pins not assigned)

The ULX3S has a 40-pin GPIO header and other headers, with 3.3 V LVCMOS I/O in the repo's constraint file (IO_TYPE=LVCMOS33 in fpga/ulx3s/*.lpf, from emard/ulx3s). I did not verify which GPIO pins are free versus shared with other board functions, nor their current drive limits. Pin assignment is deferred until the schematic is read.

| Function | Signals | Count | Level | Notes |
| :--- | :--- | :---: | :---: | :--- |
| Motor PWM | pwm_left, pwm_right | 2 | 3.3 V | exists in RTL |
| Motor direction | dir_left, dir_right (or 2nd PWM) | 2 | 3.3 V | RTL change needed |
| Driver enable | enable gate | 1 | 3.3 V | with hardware AND gate |
| Encoders | A/B per wheel | 4 | 3.3 V (check supply) | new quadrature RTL; 5 V encoder outputs would need level shifting |
| E-stop sense | ext_estop_n | 1 | 3.3 V | exists in RTL; debounce/pull-up |
| I2C (ToF, IMU, power monitor) | SCL, SDA | 2 | 3.3 V | new I2C master RTL |
| ToF XSHUT | one per sensor | about 9 | 3.3 V | or I2C multiplexer |
| UART TX/RX debug or LiDAR | tx, rx | 2 | 3.3 V | TX exists, RX missing |
| Status LEDs / buzzer | | 2 to 3 | 3.3 V | optional |

Rough total: 25 to 30 I/O. Whether that many free header pins exist is UNVERIFIED. Any 5 V sensor needs level shifting; never wire 5 V into FPGA pins.

## 8. Preliminary bill of materials (costs are unverified placeholders)

| Item | Qty | Status | Option / alternative | Rough cost, USD |
| :--- | :---: | :---: | :--- | :---: |
| ULX3S 85F board | 1 | CONFIRMED (provisional) | none | owner to supply price |
| Chassis plates + standoffs | 1 set | ASSUMED | 3D-printed, acrylic kit, or off-the-shelf 2WD kit | 15 to 40 |
| Gearmotors with encoders | 2 | NOT SELECTED | N20 w/ encoder; Pololu 25D | 20 to 60 |
| Wheels 65 mm | 2 | ASSUMED | match motor shaft | 5 to 15 |
| Ball caster | 1 | ASSUMED | | 3 |
| Motor driver | 1 | NOT SELECTED | TB6612/DRV8833/higher-current | 5 to 20 |
| ToF sensors | 7 to 9 | NOT SELECTED | VL53L0X/L1X; or LiDAR; or ultrasonic | 20 to 60 (ToF); 80 to 150 (LiDAR) |
| IMU | 1 | NOT SELECTED | MPU-6050 / ICM-20948 | 3 to 15 |
| Battery + charger | 1 | NOT SELECTED | 2S Li-ion or NiMH | 20 to 40 |
| Buck regulator 5 V | 1 | NOT SELECTED | | 5 to 10 |
| Fuse, E-stop switch, relay or MOSFET gate, wiring | 1 set | NOT SELECTED | | 15 to 30 |
| Bumper switches | 2 to 4 | NOT SELECTED | | 5 |
| Level shifters, connectors, perfboard | 1 set | ASSUMED | | 10 to 20 |

Sum of placeholders (excluding the board): roughly 130 to 350 USD depending on the sensor choice. This is an unverified estimate, not a quote.

Currency and scope reconciliation with docs/38: this table is in USD and is robot parts only (no board, no Pi). docs/38 is in GBP and is electronics only (ULX3S, Pi 5, camera, PSU, accessories). The two have never been summed until docs/38 section 10, which converts these lines at 0.7508 GBP per USD (2026-10-17 rate, UNVERIFIED for the actual purchase date) and shows the complete robot does not fit GBP 500 on these placeholders. The E-stop, cutoff and fuse line (USD 15 to 30) is unselected, and no brown-out or undervoltage supervisor is priced here (placeholder GBP 2 to 10 in docs/38). Nothing is selected or purchased.

## 9. Risks and integration dependencies

- Software gap: R1 to R7 (docs/35). Real sensors differ from the ideal 8-ray sim; the policy may not transfer. Sim-to-real is untested.
- Margin 40 cm vs 25 cm must be reconciled with measured stopping distance at 0.3 m/s.
- Side-obstacle stalls (min over all 8 rays): the filter is conservative; a direction-aware filter is not yet tested (hypothesis).
- Timing: the older docs/28 estimate was about 8 MHz of margin at 25 MHz; PR 24 CI (run 39029631056, a42f89a) gives pre-bitstream Fmax estimates of 33.74, 34.74 and 34.77 MHz (see docs/38 section 9); adding I2C, encoders, UART RX may change timing. No bitstream has been made.
- RTL has no on-FPGA distance check. Hardware E-stop is the only independent stop.
- Electrical noise from motors; brown-outs; ground loops.
- Mass/size mismatch with the simulated 0.25 m radius robot.

## 10. Staged bench-test plan (proposal)

0. Pre-requisites: owner approval, component selection, safety review, wheels lifted off the ground for all early tests.
1. Bench 1: flash ULX3S with the existing SoC over USB, read the UART banner (first real FPGA evidence; none exists today).
2. Bench 2: E-stop and watchdog tests on a LED load only, no motors: verify actuator_disarm on E-stop, on heartbeat loss, on reset.
3. Bench 3: motor driver with a current-limited bench supply, wheels off the ground, add direction/enable RTL; verify the physical E-stop cuts motor power with the FPGA running and with it unpowered.
4. Bench 4: encoders: count test by hand rotation and at several PWM duties.
5. Bench 5: distance sensors on the bench: measure real FOV, range, noise, latency; record against the 8-ray assumption.
6. Bench 6: firmware loop with safety filter and a fixed (non-neural) policy, wheels lifted.
7. Bench 7: neural policy in the loop with wheels lifted, outputs logged and compared with the Python model.
8. Floor test, tethered, speed limited to 0.3 m/s, soft barriers, a person holding the E-stop; only after R1 to R7 are resolved.

## 11. Open questions for the owner
- Budget ceiling, and whether the board is already owned.
- Preferred sensor family (ToF array vs LiDAR vs ultrasonic).
- Motor size and desired payload.
- Whether to rescale the simulator robot to the real dimensions and retrain.
- Who verifies the electrical design before first power-up.
