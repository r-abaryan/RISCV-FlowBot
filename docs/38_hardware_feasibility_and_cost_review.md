# Hardware feasibility and cost review (planning only, GBP 500 ceiling)

Status: PLANNING DOCUMENT for owner approval. Nothing bought, wired, built or tested. No RTL, firmware, safety behaviour or CI was touched. This is a separate workstream from PR 20 (docs/36 architecture) and PR 21 (docs/37 safety spec). It does not approve any safety threshold.

Lookups were made on 2026-10-17 from this sandbox. Several suppliers (Mouser, DigiKey, Farnell, GroupGets, Tindie) blocked automated access (HTTP 403 or bot check), so those prices are NOT VERIFIED.

Labels: VERIFIED (read from a vendor page or repo file this session), UNVERIFIED (plausible, not checked), INCOMPATIBLE, TBD (needs owner decision or a test).

## 1. Board comparison (ECP5-85F class)

| Item | ULX3S 85F | OrangeCrab 85F | Lattice ECP5 Versa / Evaluation board | Colorlight i5/i9 style |
|---|---|---|---|---|
| FPGA | LFE5U-85F-6BG381C, 84k LUT (VERIFIED, Crowd Supply) | ECP5-85F in csfBGA285 (VERIFIED, GitHub README) | ECP5 85F per Crowd Supply comparison table (listed price about USD 250 to 1000, NOT precise) | 25F or 45F, not 85F (UNVERIFIED) |
| Package vs our CI target | CABGA381, matches fpga/ulx3s and the M8C nextpnr runs (VERIFIED in repo) | different package: new LPF and PnR needed | not checked | different |
| User I/O | 56 GPIO on headers, 28 diff pairs, PMOD-friendly (VERIFIED) | feather format, few pins (UNVERIFIED count) | 178 (VERIFIED, comparison table) | UNVERIFIED |
| Power | USB 5 V in; 3.3 V at 1 A and 2.5 V at 1.5 A available for external use (VERIFIED) | USB-C | 12 V supply | UNVERIFIED |
| Clock | 25 MHz onboard (VERIFIED) | UNVERIFIED | 12, 50, 200 MHz | UNVERIFIED |
| Memory | 32 MB SDRAM, 4 to 16 MB QSPI flash, SD slot (VERIFIED). Our SoC uses only on-chip ROM/RAM. | DDR3 on board (UNVERIFIED size) | no RAM on board in the table | UNVERIFIED |
| Programming | USB (FT231X JTAG 500 kbit and 3 Mbit serial), external JTAG, ESP32 Wi-Fi/SD (VERIFIED). openFPGALoader support is TBD, check on arrival. | DFU | FT2232H USB-JTAG | UNVERIFIED |
| Open toolchain | Yes (Yosys/nextpnr, VERIFIED per vendor table) | Yes | Yes | Yes |
| Price | USD 275 + USD 18 worldwide shipping, listed IN STOCK (VERIFIED, Crowd Supply) | UNVERIFIED (GroupGets blocked) | UNVERIFIED (distributors blocked) | UNVERIFIED |
| UK delivered | see section 2 | UNVERIFIED | UNVERIFIED | UNVERIFIED |

Conclusion: ULX3S 85F is the only candidate whose pins, package and constraints already exist in the repo and whose price and stock I could read. I could not verify a second 85F board's UK price. Treat the alternatives as TBD, not as comparison results. A genuine comparison needs the owner to open the blocked supplier pages, or to say which alternative to price.

Lower-cost trade-off: a ULX3S 45F would hold this design on paper (older M8C figure 12,183 LUT4 of 83,640, about 14 percent, superseded by section 9; 45F has about 44k LUT, UNVERIFIED fit) but the Crowd Supply page lists only 12F (USD 155, pre-order, ships Dec 15 2026) and 85F. The 12F (about 12k LUT) does NOT fit: 12,183 combinational cells already exceed it (INCOMPATIBLE by M8C numbers). The owner's stated target is 85F, so keep it.

## 2. Realistic cost estimate

Prices are GBP incl. VAT from The Pi Hut Shopify listings read 2026-10-17 unless stated.

| Item | Model | Price | Status |
|---|---|---|---|
| FPGA board | ULX3S 85F (Crowd Supply) | USD 275 + USD 18 shipping = USD 293. At an ASSUMED rate of 1.30 USD per GBP: about GBP 225 | rate UNVERIFIED |
| UK import VAT and courier fees on the above | 20 percent VAT, possible carrier handling fee | about GBP 45 to 60 extra, so GBP 270 to 285 delivered | UNVERIFIED (Crowd Supply may or may not collect VAT) |
| Pi 5 | 4GB, Pi Hut | 105.60, in stock | VERIFIED |
| Camera | Camera Module 3 Standard | 24.00, in stock (Wide 33.60) | VERIFIED |
| Pi 5 camera cable | 22-pin to 15-pin, Pi 5 uses the mini connector. Pi Hut listing shows cables from 0.90 | about 2 to 4 | UNVERIFIED which SKU |
| Power supply | Raspberry Pi 27W USB-C, UK | 11.50 | VERIFIED |
| Active cooler | Pi 5 Active Cooler | 4.80 | VERIFIED |
| microSD | Pi Hut 32GB with Raspberry Pi OS | 27.50 (64GB 30.60) | VERIFIED. Plain cards may be cheaper |
| USB-A to micro-USB or USB-C cable for ULX3S | check connector on arrival | 5 | UNVERIFIED |
| Jumper wires, header pins, 3 to 4 resistors, breadboard | assorted | 10 to 15 | UNVERIFIED |
| 8-channel USB logic analyser (generic clone) for output checks | about 10 | 10 | UNVERIFIED |
| Subtotal | | about 460 to 500 | |
| Contingency | | 0 to 40 | |

Honest reading: with the ULX3S 85F the GBP 500 ceiling is TIGHT. The estimate range is roughly 460 to 500 and contingency ranges from zero to 40 pounds. The largest uncertainty is import VAT and the USD rate, which together move the result by about GBP 50. Ways to gain headroom: Pi 5 2GB (GBP 74.40, saves 31.20; the camera inference test is the thing that decides whether 2GB is enough, TBD), skip the official SD preload, skip the logic analyser and use the ULX3S LEDs for the first tests. The Pi 5 8GB and 16GB are not needed. No motors, driver, battery, chassis or sensors are included; those are the future robot.

## 3. Cheapest meaningful tests and pass/fail criteria

Each test is hardware, so each is "board-tested" only after it actually runs. None is done.

| Test | Needs | Pass criterion | Fail criterion |
|---|---|---|---|
| T1 Camera inference on Pi 5 | Pi, camera, cable, PSU | rpicam-hello detects the camera; a fixed set of N=50 stored test images yields reproducible top-1 labels on two runs; measured frames per second and latency recorded with the exact model name | camera not detected; results not reproducible; model fps below the value the owner sets (TBD, none set) |
| T2 Pi-to-FPGA link | Pi 5 GPIO UART or SPI, ULX3S GPIO header, common ground, 3.3 V logic (both sides 3.3 V, VERIFIED for ULX3S header banks, jumper selectable 3.3 or 2.5 V, so check the jumper) | 10,000 bytes at an agreed baud rate loop back with 0 errors; command frame rejected when CRC or length is wrong; link loss for longer than a timeout makes the FPGA side go to the stopped state (needs a defined firmware or RTL feature that DOES NOT exist yet) | any byte error; no timeout behaviour |
| T3 SoC bring-up on ULX3S | board, USB cable | bitstream loads via openFPGALoader; LED heartbeat at expected rate; the UART banner decoded by the host equals the firmware banner string (the UART TX was merged in PR 17, simulated only) | no banner, wrong characters, or timing not met at 25 MHz (earlier M8C pre-bitstream Fmax estimate was 32.9 to 33.0 MHz; PR 24 estimates are 33.74, 34.74 and 34.77 MHz, see section 9) |
| T4 Motor-control outputs, motors DISCONNECTED | logic analyser or scope | PWM pin shows the commanded duty at 0, 25, 50, 100 percent within the tolerance TBD; actuator_disarm and E-stop force both outputs low within a measured time; watchdog stop when firmware halts | any output active while disarmed, or stop time above the safety-spec bound (TBD in docs/37 and not approved) |

Known gap blocking T4: in fpga/ulx3s/ulx3s_85f.lpf only clock, UART RX, one button, one switch and eight LEDs have pins. The PWM and disarm outputs have no pin assignments (VERIFIED in repo). The pins are copied from emard's constraints and were not checked against a schematic. Adding them changes the wrapper, which is out of scope here and needs approval.

## 4. Assumption register

| # | Assumption | Status |
|---|---|---|
| A1 | ULX3S 85F is LFE5U-85F-6BG381C, 84k LUT, 56 GPIO, 25 MHz clock | VERIFIED (Crowd Supply page) |
| A2 | ULX3S 85F in stock at USD 275 plus USD 18 shipping | VERIFIED 2026-10-17; may change |
| A3 | UK delivered price GBP 270 to 285 | UNVERIFIED. Rebuilt in section 8 from the 2026-10-17 exchange rate (0.7508 GBP per USD, open.er-api.com); VAT and courier fee rules could not be fetched from gov.uk, so the VAT and fee terms stay UNVERIFIED |
| A4 | The SoC fits the 85F and routes at 25 MHz | Synthesised in CI and given a pre-bitstream nextpnr timing estimate (not a routed, bitstream-proven or board-tested result). Current figures are in section 9 (PR 24, run 39029631056 at a42f89a). Older M8C figures (about 12k LUT, 32.9 to 33.0 MHz, 14 percent) predate the UART TX and use a different counting basis, so they are superseded |
| A5 | Pins in ulx3s_85f.lpf are right | UNVERIFIED (copied, not schematic checked) |
| A6 | Pi 5 4GB GBP 105.60, Camera Module 3 GBP 24, PSU GBP 11.50, cooler GBP 4.80 | VERIFIED (Pi Hut listing) |
| A7 | Pi 5 needs the Standard-to-Mini camera cable (15-pin camera end, 22-pin Pi 5 end) | VERIFIED on the Pi Hut pages 2026-10-17. Camera Module 3 Standard lists both cables in the box (length not stated); Wide does not. Separate cable: Pi Hut 'Camera Adapter Cable for Raspberry Pi 5', 200mm SC1128, listed price 90 in the shop data (read as GBP 0.90, to confirm on the page), in stock |
| A8 | Pi 5 and ULX3S GPIO are both 3.3 V | VERIFIED for logic levels: Raspberry Pi documentation (GPIO pins are 3.3 V, inputs 3.3 V tolerant) and the ULX3S manual (GPIO 3.3 V, not 5 V tolerant). 5 V sensors or motor drivers DO need level shifting. Pi 5 pad drive current not checked |
| A9 | ULX3S GPIO headers are fitted | UNVERIFIED (the listing does not say, may need soldering or header pins) |
| A10 | openFPGALoader programs the ULX3S over the FT231X | UNVERIFIED here (widely reported, not checked), test on arrival |
| A11 | 12F ULX3S can hold this SoC | INCOMPATIBLE by M8C counts |
| A12 | A second 85F board has a UK price and stock | OrangeCrab 85F: listed USD 178 on 1BitSquared but the page is marked Discontinued and the variants show unavailable (2026-10-17). No UK price. Not a purchasable alternative. Lattice Versa board not priced (TBD) |
| A13 | Pi 5 2GB is enough for the chosen vision model | TBD (decided by T1) |
| A14 | The first prototype safety limits | TBD, owner approval (docs/37, PR 21) |
| A15 | Large RL training stays paused and virtual experiments do not change the baseline | CONFIRMED by owner instruction |

## 5. Top compatibility risks

1. Budget: the ULX3S import VAT and exchange rate can consume the whole contingency.
2. Output pins missing: motor-control outputs have no constraints, so T4 cannot run until an approved wrapper change exists.
3. Timing margin: the pre-bitstream Fmax estimate is about 33.7 to 34.8 MHz versus a 25 MHz clock (section 9, includes the UART TX); this is an estimate only, no bitstream exists.
4. Link-loss behaviour between Pi and FPGA is not specified or implemented. The Pi must be treated as an untrusted advisory source; the safety filter and watchdog stay on the FPGA side.
5. Camera cable and connector mismatch on Pi 5 (A7).
6. Crowd Supply is a US shipper; customs delay and returns for a faulty board are slower than a UK reseller.
7. Pi 5 power: undervoltage from a weak supply causes camera and USB faults, so use the 27W supply.

## 6. Recommended purchase sequence (for approval, nothing ordered)

Stage 1 (about GBP 150 to 190): Pi 5 4GB, Camera Module 3 Standard, correct Pi 5 camera cable, 27W PSU, active cooler, SD card. Run T1. Only this stage can reduce the Pi memory choice. Do this stage first because it is UK-stocked and has low delivery risk.
Stage 2 (about GBP 270 to 285): ULX3S 85F. Order only after the owner accepts the VAT uncertainty (ask Crowd Supply support, or check the checkout total before paying; the owner pays, I do not). Run T3 on arrival, with an LED heartbeat as a fallback.
Stage 3 (about GBP 15 to 30): jumper wires, header pins, logic analyser. Run T2 and T4 once an approved wrapper adds the output pins.
Hold the remaining contingency until after T3. If Stage 1 plus Stage 2 exceed GBP 480, drop to Pi 5 2GB.

Exact order lines:
- Raspberry Pi 5 4GB, https://thepihut.com/products/raspberry-pi-5 (4GB variant)
- Raspberry Pi Camera Module 3 Standard, https://thepihut.com/products/raspberry-pi-camera-module-3
- Raspberry Pi 27W USB-C Power Supply, UK, https://thepihut.com/products/raspberry-pi-27w-usb-c-power-supply
- Active Cooler for Raspberry Pi 5, https://thepihut.com/products/active-cooler-for-raspberry-pi-5
- Raspberry Pi Micro SD with OS, 32GB, listed at Pi Hut (choose in the SD card collection)
- ULX3S with ECP5 85F, https://www.crowdsupply.com/radiona/ulx3s
- Pi 5 camera cable: included with Camera Module 3 Standard per Pi Hut; if a known 200 mm bench length is wanted, add Pi Hut Camera Adapter Cable for Raspberry Pi 5, 200mm, SKU SC1128 (A7)

## 7. Not done

No UK price for any second 85F board. No board schematic check (pin data below comes from the ULX3S manual and emard constraints file, not schematics). No gov.uk VAT rule text. No Pi 5 pad drive current check. No tool run. No change to RTL, firmware, constraints or CI.

## 8. Update 2026-10-17 after owner decisions (planning only)

Evidence labels: VERIFIED means read from a vendor or project page on 2026-10-17. UNVERIFIED means estimate. Nothing here is board-tested.

### 8.1 Board comparison and recommendation

| Item | ULX3S 85F | OrangeCrab 85F |
|---|---|---|
| FPGA | LFE5U-85F, 84k LUT (VERIFIED) | LFE5U-85F (listed as 85F variant) |
| Availability | In stock, Crowd Supply (VERIFIED) | DISCONTINUED, variants unavailable on 1BitSquared (VERIFIED) |
| List price | USD 275 plus USD 18 shipping | USD 178 (not purchasable) |
| User I/O | 56 GPIO on two 40-pin headers, 3.3 V | Feather-style, about 13 numbered GPIO plus 4 analog-pin GPIO in the r0.2.1 docs (my count of the pinout table) |
| Fit for this SoC | LUT headroom; older M8C estimate about 12k LUT; PR 24 synthesis gives LUT4 8710 (section 9) | Same FPGA size; I/O too few for motors, encoders, sensors and Pi link |
| UK price | Not found; estimate in 8.3 | TBD, stop as instructed |

Recommendation: ULX3S 85F. The only alternative checked is discontinued and has far fewer pins. Versa board unpriced (TBD). ULX3S 12F stays INCOMPATIBLE.

### 8.2 Camera

Camera Module 3 Standard (Pi Hut SKU SC1223, GBP 24): the product page says it ships with both the 15-pin and the 22-pin Pi 5/Zero cables. Wide-angle does not include the Pi 5 cable. Cable length in the box is not stated. For a known 200 mm bench length order SC1128 (GBP 0.90, listed price 90 in shop data; confirm on page).

### 8.3 Delivered cost and budget (GBP, electronics prototype only: no chassis, motors or battery)

Assumptions: USD to GBP 0.7508 (open.er-api.com, 2026-10-17). Import VAT 20 percent on goods plus shipping, plus a courier handling fee of GBP 8 to 15: both UNVERIFIED (gov.uk page could not be read). Customs duty assumed zero: UNVERIFIED. Pi Hut prices assumed to include UK VAT: UNVERIFIED.

ULX3S: USD 293 x 0.7508 = GBP 220.0; with 20 percent VAT 264.0; with fee 272 to 279. Add 3 to 5 percent card or exchange margin: about 280 to 293. Range for planning: GBP 270 to 295.

| Line | Low | Central | High |
|---|---|---|---|
| Pi 5 4GB, camera, PSU, cooler, SD card (105.60 + 24 + 11.50 + 4.80 + 27.50) | 173.40 | 173.40 | 173.40 |
| Camera cable SC1128 (optional) | 0 | 0.90 | 0.90 |
| ULX3S 85F delivered | 270 | 280 | 295 |
| Headers, wires, level shifters, logic analyser, USB cables | 15 | 30 | 45 |
| Subtotal | 458 | 484 | 514 |
| Contingency 10 percent | 46 | 48 | 51 |
| Total | 504 | 532 | 565 |

Result: with a meaningful 10 percent contingency the plan EXCEEDS GBP 500 by about 4 to 65 pounds. Pi 5 2GB saves about GBP 31 (T1 decides), which gives central total about 501. The 500 ceiling holds only if the ULX3S arrives near the low estimate or the owner treats part of the contingency as outside the ceiling.

### 8.4 Proposed FPGA pin allocation (PROPOSAL, no RTL or constraint change made)

Source: ULX3S manual and emard ulx3s_v20.lpf (PCB v2.x and v3.0.x). Not checked against the schematic; confirm the board revision when it arrives. The manual says GPIO is 3.3 V and not 5 V tolerant. Restrictions: GP/GN 11 to 13 are shared with ESP32 WiFi (v2.0 and later); GP/GN 14 to 17 are shared with the ADC; J2 also carries 5 V in and out; SD card pins are shared with the ESP32 and some WiFi GPIO. Avoid those for first use. GP/GN 0 to 7 are single-ended; 8 to 13 are differential-capable pairs and still usable as single-ended GPIO.

Counts in the current design: ports in soc_top are clk, rst_n, ext_estop_n, uart_tx, pwm_left_out, pwm_right_out, actuator_disarm (plus 16-bit command monitor buses, which should NOT go to pins). There is NO UART RX, direction output, encoder input or sensor input in soc_top today. Those are gaps, not implemented.

| Function | Signals | Proposed header pins | FPGA sites (from lpf) |
|---|---|---|---|
| Pi link UART (FPGA TX, FPGA RX) | 2 | GP0, GN0 | B11, C11 |
| Motor PWM left, right | 2 | GP1, GN1 | A10, A11 |
| Motor direction left, right | 2 | GP2, GN2 | A9, B10 |
| Encoders A and B, left and right | 4 | GP3, GN3, GP4, GN4 | B9, C10, A7, A8 |
| Motor driver enable (hardware disable, driven by actuator_disarm) | 1 | GP5 | C8 |
| Physical E-stop input (active low, external pull-up) | 1 | GN5 | B8 |
| Range sensors (4 ultrasonic trigger and echo pairs, or I2C ToF: 2 pins) | up to 8 | GP6 to GP9, GN6 to GN9 | C6, A6, A4, A2, C7, B6, A5, B1 |
| Spare, same safe bank | 1 | GP10 / GN10 (C4, B4) | 2 left |
| Expansion on J2 | 10 pairs | GP18 to GP27, GN18 to GN27 | 20 pins free, not assigned |

Used: 20 of the 22 pins in GP/GN 0 to 10; J2 GP/GN 18 to 27 give 20 more; 14 pins (11 to 13, 14 to 17) held back for sharing. Total header GPIO 56. The FTDI USB UART stays for diagnostics and loading and uses no header pins.

Pin-budget risks:
1. 5 V sensors (HC-SR04 echo) and 5 V motor-driver inputs need level shifting. Not 5 V tolerant.
2. soc_top has no direction, encoder, sensor or UART RX logic. Pins reserved here need new RTL, outside this task.
3. Header pins must be fitted and the row chosen against the J1/J2 pinout silk screen (A9 UNVERIFIED).
4. Sensor count depends on the sensor-coverage decision in docs/37.
5. Motor-driver disable must fail safe when the FPGA is unconfigured: use external pull resistors (design item, not verified). During FPGA configuration pins may float; the E-stop chain should cut motor power in hardware independent of the FPGA.

### 8.5 Pi to FPGA interface specification (SPECIFICATION ONLY, not implemented, values TBD for owner approval)

Principle: the Pi is an untrusted advisory source. The firmware safety filter, RTL watchdog and E-stop remain on the FPGA side and the Pi cannot clear an E-stop or disarm.

- Physical: UART, 3.3 V, 8N1, 115200 baud proposed, on GP0/GN0 (separate from the FTDI diagnostic UART). 115200 gives a 13-byte frame in about 1.1 ms.
- Frame (little endian): SOF 0xA5, version (1 byte), type (1), sequence (1), length (1), payload (0 to 8 bytes), CRC-16/CCITT-FALSE over version through payload (2 bytes). Maximum frame 16 bytes.
- Types: 0x01 advisory motion command (payload: forward and turn request as signed 16-bit, units TBD with docs/37); 0x02 heartbeat; 0x03 status request. FPGA to Pi: 0x81 status (state, last accepted sequence, fault flags).
- Validity: a frame is accepted only if SOF, version, length bound and CRC are correct and the sequence is newer (modulo 256, not repeated). Invalid bytes are dropped and the parser re-syncs on the next SOF. Out-of-range values are clamped or rejected, then the safety filter still applies.
- Rate and timeout: Pi sends commands at 20 Hz (proposed). A command is valid for 200 ms (TBD: must be shorter than the stopping-time budget from docs/37) and then reverts to zero command. 
- Link loss: after the timeout the firmware commands zero speed; after a second longer timeout (TBD, for example 500 ms) it requests disarm. Recovery needs several consecutive valid frames plus an explicit re-arm request from the physical side. A framing or CRC error never refreshes the timeout. Pi reboot, cable pull or a hung Pi all look the same: no valid frames.
- Independence: the RTL watchdog still trips if firmware stops; the E-stop overrides everything.
- Gaps: no UART RX in RTL, no parser, no sequence logic. Test with a host script and a UART loopback only after approval.

### 8.6 Purchase go / no-go recommendation (the owner buys; I buy nothing)

- GO (Stage 1): Pi 5 4GB (or 2GB), Camera Module 3 Standard, 27W PSU, cooler, SD card, about GBP 173 to 175. Low risk, UK stocked, independent of the FPGA decision, enables T1.
- NO-GO for ULX3S until: the owner has seen the Crowd Supply checkout total in GBP including VAT and fees; the owner decides whether the 500 ceiling includes contingency (central plan is about 532 with 10 percent contingency); and header fitting is confirmed.
- NO-GO for motors, chassis, battery and sensors: out of scope for this budget and sensor choice is open.

### 8.7 Still unresolved

UK VAT, duty and handling fee terms (A3); exact included cable length; second 85F board prices; schematic check of pin allocation; Pi 5 pad drive current; Fmax after the UART TX addition is now estimated in section 9 (pre-bitstream only); full-robot cost items in section 10 are unverified; sensor type and count.

## 9. Verified synthesis and timing figures (PR 24, 2026-10-17 update)

Source: CI run 39029631056 at RTL commit a42f89a (branch flowbot/m8e-uart-tx-db). A later documentation-only commit 6304406 (docs/42) changed no RTL. These are CI synthesis (Yosys) counts and nextpnr timing estimates. They are NOT a bitstream, NOT board-tested. The figures below are as supplied by the owner and recorded in docs/42; I did not re-read the CI artifacts.

| Resource | Count | Note |
|---|---|---|
| LUT4 | 8710 | synthesis count |
| FF (TRELLIS_FF) | 2692 | |
| BRAM (DP16KD) | 38 | |
| DSP (MULT18X18D) | 12 | |
| CCU2C (carry) | 586 | reported by synthesis |

Pre-bitstream Fmax estimates (nextpnr, three runs) against the 25 MHz constraint: 33.74, 34.74 and 34.77 MHz. This is a pre-bitstream estimate: wording such as "routed in simulation of PnR" in older text should be read as this. It says nothing about I/O timing, board behaviour or timing after adding I2C, encoder, direction or UART RX logic.

## 10. Complete robot cost (GBP ranges, planning only, nothing selected or bought)

The earlier table (section 8.3) covers electronics only. The full robot adds the parts below. Prices for these lines are UNVERIFIED placeholders taken from docs/36 (USD), converted at 0.7508 GBP per USD (open.er-api.com, 2026-10-17, as in 8.3), rounded. docs/36 and this document were previously never summed.

| Line | USD (docs/36) | GBP range | Status |
|---|---|---|---|
| Chassis plates, standoffs | 15 to 40 | 11 to 30 | UNVERIFIED, not selected |
| Gearmotors with encoders (2) | 20 to 60 | 15 to 45 | UNVERIFIED, not selected |
| Wheels and ball caster | 8 to 18 | 6 to 14 | UNVERIFIED |
| Motor driver | 5 to 20 | 4 to 15 | UNVERIFIED, not selected |
| Battery and charger | 20 to 40 | 15 to 30 | UNVERIFIED, not selected |
| 5 V buck regulator (and Pi 5 supply path, see docs/36 section 5a) | 5 to 10 | 4 to 8 | UNVERIFIED; Pi 5 needs a robust 5 V supply, may need a larger converter |
| Range sensors, ToF array (7 to 9) | 20 to 60 | 15 to 45 | UNVERIFIED, sensor type undecided |
| (alternative) LiDAR instead of ToF | 80 to 150 | 60 to 113 | UNVERIFIED |
| IMU | 3 to 15 | 2 to 11 | UNVERIFIED |
| Bumper switches | 5 | 4 | UNVERIFIED |
| Independent physical E-stop, battery cutoff (relay or MOSFET), fuse, wiring | 15 to 30 | 11 to 23 | UNVERIFIED, not selected; required by the safety requirements |
| Brown-out / undervoltage supervisor | not priced in docs/36 | 2 to 10 | PLACEHOLDER by me, no part chosen |
| Level shifters, connectors, perfboard | 10 to 20 | 8 to 15 | UNVERIFIED; may overlap the 15 to 45 accessories line in 8.3 |

Robot parts subtotal (ToF case): about GBP 97 to 250. With LiDAR instead of ToF: about GBP 142 to 318. These use rounded line values and may double count accessories.

| Case | Electronics (8.3 subtotal) | Robot parts | Total before contingency | With 10 percent contingency |
|---|---|---|---|---|
| Low (ToF) | 458 | 97 | about 555 | about 610 |
| High (ToF) | 514 | 250 | about 764 | about 840 |
| High (LiDAR) | 514 | 318 | about 832 | about 915 |

Conclusion: on these unverified numbers the complete robot does NOT fit GBP 500, even with the low case and no contingency. The shortfall is roughly GBP 55 to 330 before contingency. I have not forced the budget under GBP 500. Options for the owner (not decided): raise the ceiling, phase the build (electronics first, as 8.6 Stage 1 and 2), or reduce scope. The E-stop, cutoff and brown-out lines are safety items and must not be dropped to save money. Pi 5 2GB saves about GBP 31 only if T1 allows. Currencies: docs/36 USD and this document GBP are now reconciled at the 0.7508 rate above; VAT, courier fee and exchange margin remain UNVERIFIED.
