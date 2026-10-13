#!/bin/sh
# Synthesize picorv32_wb with EXACTLY the parameters soc_top.v passes (RV32IM: MUL, FAST_MUL, DIV, IRQ, barrel shifter).
# Top name is picorv32_wb_soc so its checkpoints do not collide with a default-parameter run; chparam is applied to picorv32_wb.
# Keep the table below in sync with rtl/soc_top.v (u_cpu).  STACKADDR 0x2000F000 = 536932352, PROGADDR_IRQ 0x10 = 16.
set -e
P=""
for kv in ENABLE_COUNTERS=1 ENABLE_COUNTERS64=1 ENABLE_REGS_16_31=1 ENABLE_REGS_DUALPORT=1 TWO_STAGE_SHIFT=1 BARREL_SHIFTER=1 \
  TWO_CYCLE_COMPARE=0 TWO_CYCLE_ALU=0 COMPRESSED_ISA=0 CATCH_MISALIGN=1 CATCH_ILLINSN=1 ENABLE_PCPI=0 ENABLE_MUL=1 \
  ENABLE_FAST_MUL=1 ENABLE_DIV=1 ENABLE_IRQ=1 ENABLE_IRQ_QREGS=1 ENABLE_IRQ_TIMER=0 ENABLE_TRACE=0 REGS_INIT_ZERO=1 \
  MASKED_IRQ=0 LATCHED_IRQ=4294967295 PROGADDR_RESET=0 PROGADDR_IRQ=16 STACKADDR=536932352; do
  P="$P chparam -set ${kv%=*} ${kv#*=} picorv32_wb;"
done
exec scripts/synth_staged.sh picorv32_wb "$P" rtl/cpu/picorv32.v
