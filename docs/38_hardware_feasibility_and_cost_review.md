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

Lower-cost trade-off: a ULX3S 45F would hold this design on paper (M8C routed 12,183 of 83,640 LUT4, about 14 percent; 45F has about 44k LUT, UNVERIFIED fit) but the Crowd Supply page lists only 12F (USD 155, pre-order, ships Dec 15 2026) and 85F. The 12F (about 12k LUT) does NOT fit: 12,183 combinational cells already exceed it (INCOMPATIBLE by M8C numbers). The owner's stated target is 85F, so keep it.

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
| T3 SoC bring-up on ULX3S | board, USB cable | bitstream loads via openFPGALoader; LED heartbeat at expected rate; the UART banner decoded by the host equals the firmware banner string (the UART TX was merged in PR 17, simulated only) | no banner, wrong characters, or timing not met at 25 MHz (M8C routed Fmax was 32.9 to 33.0 MHz on 3 seeds, a pre-bitstream estimate) |
| T4 Motor-control outputs, motors DISCONNECTED | logic analyser or scope | PWM pin shows the commanded duty at 0, 25, 50, 100 percent within the tolerance TBD; actuator_disarm and E-stop force both outputs low within a measured time; watchdog stop when firmware halts | any output active while disarmed, or stop time above the safety-spec bound (TBD in docs/37 and not approved) |

Known gap blocking T4: in fpga/ulx3s/ulx3s_85f.lpf only clock, UART RX, one button, one switch and eight LEDs have pins. The PWM and disarm outputs have no pin assignments (VERIFIED in repo). The pins are copied from emard's constraints and were not checked against a schematic. Adding them changes the wrapper, which is out of scope here and needs approval.

## 4. Assumption register

| # | Assumption | Status |
|---|---|---|
| A1 | ULX3S 85F is LFE5U-85F-6BG381C, 84k LUT, 56 GPIO, 25 MHz clock | VERIFIED (Crowd Supply page) |
| A2 | ULX3S 85F in stock at USD 275 plus USD 18 shipping | VERIFIED 2026-10-17; may change |
| A3 | UK delivered price GBP 270 to 285 | UNVERIFIED |
| A4 | The SoC fits the 85F and routes at 25 MHz | Routed in simulation of PnR (nextpnr, 3 seeds, 14 percent comb LUT, margin about 8 MHz). Not board-tested |
| A5 | Pins in ulx3s_85f.lpf are right | UNVERIFIED (copied, not schematic checked) |
| A6 | Pi 5 4GB GBP 105.60, Camera Module 3 GBP 24, PSU GBP 11.50, cooler GBP 4.80 | VERIFIED (Pi Hut listing) |
| A7 | Pi 5 needs the mini (22-pin) camera cable, not the 15-pin one that ships with older cameras | UNVERIFIED, confirm on the Pi Hut product page before ordering |
| A8 | Pi 5 and ULX3S GPIO are both 3.3 V so no level shifter is needed | UNVERIFIED for the Pi side (not looked up this session); ULX3S bank voltage VERIFIED |
| A9 | ULX3S GPIO headers are fitted | UNVERIFIED (the listing does not say, may need soldering or header pins) |
| A10 | openFPGALoader programs the ULX3S over the FT231X | UNVERIFIED here (widely reported, not checked), test on arrival |
| A11 | 12F ULX3S can hold this SoC | INCOMPATIBLE by M8C counts |
| A12 | A second 85F board has a UK price and stock | TBD (suppliers blocked) |
| A13 | Pi 5 2GB is enough for the chosen vision model | TBD (decided by T1) |
| A14 | The first prototype safety limits | TBD, owner approval (docs/37, PR 21) |
| A15 | Large RL training stays paused and virtual experiments do not change the baseline | CONFIRMED by owner instruction |

## 5. Top compatibility risks

1. Budget: the ULX3S import VAT and exchange rate can consume the whole contingency.
2. Output pins missing: motor-control outputs have no constraints, so T4 cannot run until an approved wrapper change exists.
3. Timing margin: routed Fmax is about 33 MHz versus a 25 MHz clock, estimate only, and the M8C numbers were taken before the UART TX was added to the flat design (re-run needed).
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
- Pi 5 camera cable: SKU not confirmed, owner or I should confirm before ordering (A7)

## 7. Not done

No second 85F UK price. No board schematic check. No exchange rate source. No Pi 5 GPIO voltage check. No tool run. No change to RTL, firmware, constraints or CI.
