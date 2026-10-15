# M8D: ULX3S functional bring-up readiness

Status: readiness report. No bitstream built, no hardware used, no CI dispatched, no safety-critical RTL changed.
Environment: iverilog only. Yosys was NOT available in this session, so synthesis-survival statements rely on existing M8C logs or on source reading and are labelled so.

## 1. Verified findings (checked this session)

| # | Finding | Evidence |
|---|---|---|
| V1 | The physical UART pin is constant-high. rtl/periph/soc_uart.v assigns uart_tx only to 1 (reset value, line 33). The data write (offset 0x00) stores tx_byte; the character is printed with a simulation-only block under `ifndef SYNTHESIS`. No shifter, baud divider or start bit exists. | source reading; simulation below: 654 UART data writes, 0 start bits on ftdi_rxd |
| V2 | Consequence: on the ULX3S the FTDI line stays idle. No firmware text reaches a terminal. Not a toolchain bug. The RTL has no serial transmitter. | same |
| V3 | led[7:3] are tied to 0 in fpga/ulx3s/ulx3s_top.v. Only led[0]=disarm, led[1]=pwm_l, led[2]=pwm_r carry signals. | wrapper source |
| V4 | The 32 pwm_*_cmd monitor outputs are unconnected in the wrapper. Their only effect is that logic feeding only them may be pruned. PWM and disarm logic still drives LEDs, so it survives. | source reading (not confirmed from a netlist) |
| V5 | In the wrapper-level simulation, with the real firmware ROM: reset held gives disarm LED on and CPU idle. After release, firmware executes (654 UART data writes in 3.2 ms sim time) and LEDs change (5 edges). | sim/tb_ulx3s_top.v, 6 checks passed, fails=0 |
| V6 | The firmware ROM contents survive mapping: 531 words matched in the M8C netlist. | logs/pnr_m8c/rom_mapped_check.txt (earlier session, not rerun) |
| V7 | LPF sites used by the wrapper agree with the emard ulx3s_v20.lpf: clk_25mhz G2, ftdi_rxd L4 ("FPGA transmits to ftdi"), btn0 D6 ("BTN_PWRn, inverted logic"), sw0 E8 (SW1), led[0..7] B2,C2,C1,D2,D1,E2,E1,H3 start. Checked for clk, ftdi_rxd, btn0, sw0, led[0], led[7]. led[1] to led[6] were not individually compared. | /tmp copy of the upstream LPF vs fpga/ulx3s/ulx3s_85f.lpf |
| V8 | UART direction naming is board-relative: upstream says ftdi_rxd is "FPGA transmits to ftdi", so the wrapper's use of ftdi_rxd as our TX output is correct. | upstream LPF comment; schematic text shows FTDI_RXD on L4 |

Test command (from repo root; the ROM path is root-relative):
`iverilog -g2012 -Irtl -o /tmp/u.vvp fpga/ulx3s/ulx3s_top.v sim/tb_ulx3s_top.v rtl/cpu/*.v rtl/nna/*.v rtl/safety/*.v rtl/periph/*.v rtl/bus/*.v rtl/mem/*.v rtl/soc_top.v && vvp /tmp/u.vvp`
Runtime is slow in this sandbox (about 2 minutes). It is not yet in the Makefile or CI.
Note: this testbench asserts the UART gap as a pass ("KNOWN GAP"). When a real UART is added, that check must be inverted.

## 2. Board-documentation audit

Verified against upstream files only (LPF, manual, schematic text extraction):
- Pin names and sites above.
- btn0 is BTN_PWRn with "inverted logic" per LPF comment. The manual also describes BTN0 as the power/boot-related button, with a diode option that makes BTN0 force a multiboot reload via PROGRAMN. That is relevant: a reset button that can also reconfigure the FPGA.
- Our LPF gives btn0 PULLMODE=UP and sw0 PULLMODE=DOWN.

NOT verified (assumptions):
- A1: btn0 reads high when released and low when pressed. The wrapper assumes this. Schematic text extraction was too garbled to confirm the pull network. Needs a look at the schematic image or a scope or multimeter.
- A2: Which DIP position for sw0 gives logic high. The wrapper treats sw0=0 as E-stop tripped. If the "ON" position pulls low, the robot would stay disarmed, which is fail-safe but confusing. This is not a polarity hazard in that direction. The opposite hazard is an E-stop wired as a real normally-closed loop: a DIP switch is NOT a real E-stop and must not be treated as one for motor tests.
- A3: Whether DRIVE=4 on ftdi_rxd and the FTDI side behave at 3.3 V as the LPF suggests. Not measured.
- A4: Real board-level E-stop input: none is assigned. GPIO headers are not yet mapped. No motor pins exist in the LPF, which is appropriate for now.
- A5: Reset: the wrapper synchronises btn0 and sw0 with 2-FF synchronisers, initialised to 0 (reset held at power-up). The reset release happens only after the button reads high. Power-up init of the registers relies on FPGA configuration; assumed to work on ECP5, not tested.

## 3. Risks

R1 (high for bring-up usefulness): no real UART output. Highest-value next fix, as it is the only way to see firmware progress on hardware.
R2 (medium): LED-only observability is weak. 5 of 8 LEDs are constant zero.
R3 (medium): btn0 may double as a reconfiguration button if D28 is fitted. A user press can reload the bitstream.
R4 (medium): DIP switch as E-stop is a bring-up stand-in, not a safety device.
R5 (low): the testbench relies on hierarchical names (dut.u_soc.u_uart..., dut.rst_n_s). Renaming an instance breaks it.
R6 (info): simulation of the firmware reached UART writes only to prove execution. It does not prove that the safety filter behaves identically on hardware.

## 4. Proposed minimal simulation (implemented as a draft)

sim/tb_ulx3s_top.v covers: reset hold, CPU idle in reset, UART idle high, firmware reaching UART writes, LED activity, and the known pin gap. Missing: baud-timed decode (needs the UART TX), button/E-stop polarity checks, timing closure.

## 5. Smallest safe next implementation step (needs owner approval)

Add a synthesizable UART TX (8N1, divider from a parameter, 25 MHz / 115200 about 217 clocks per bit) to rtl/periph/soc_uart.v, with a one-byte busy flag and a status read. This changes a peripheral, not the safety filter or actuator path, but it changes bus behaviour (firmware that writes bytes back to back would need to poll busy or the byte would be lost). Then:
1. Extend tb_ulx3s_top.v to decode the first characters from ftdi_rxd and compare with the firmware banner text.
2. Invert the KNOWN GAP check.
3. Only then consider a bitstream, and a first hardware test with no motors attached.

Alternative considered: a smaller step, a heartbeat on the LEDs driven from a counter, which needs no bus change. It confirms clock and reset on the board but nothing about the firmware. Recommended only as an optional first hardware test.

## 6. Not done

- No Yosys re-run, so V4 and any statement about pruned logic is source-based.
- No hardware, no scope, no schematic image inspection.
- No Makefile or CI target added for tb_ulx3s_top.
- LED sites led[1..6] not individually compared.
