# M7 checkpoint (assembly safety parity + ROM layout) - read-only investigation so far
No tests run, no code changed. See session report. Established from source reading only:
- RTL safety_filter regs: 0x00 CTRL(bit0 en, bit1 clear), 0x04 HEARTBEAT (key 0x5AFEC0DE), 0x08 STATUS (read-only), 0x0C TIMEOUT. No 0x10 register.
- robot_nav_firmware.s writes: 0x04=500000 (lands on HEARTBEAT, not key -> no effect), 0x08=pet key (STATUS, ignored), 0x10=clear key (ignored); pets at 0x608 (ignored).
  => asm never actually refreshes the HW watchdog; reset default timeout 2,500,000 cycles; tb_soc_nav runs <=1M cycles so expiry is never exercised.
- soc_regs.h (used by safety_driver.h) disagrees with RTL: TIMEOUT 0x04/HEARTBEAT 0x08/STATUS 0x0C/disarm bit0; RTL is 0x0C/0x04/0x08 and bit0 = enable.
- asm has a critical-obstacle clamp (s2=0) at "safety_pass"; its exact conditions, kinematic clamp, slew limit, proximity cap and invalid-data handling NOT yet confirmed.
- ROM load addresses vs hex contents: NOT yet checked.
