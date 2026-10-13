# 18. Yosys in the sandbox: installation, execution, and per-module results

Date: 2026-10-13. Everything below was run in this sandbox; logs are in `logs/synth_per_module/`.

## 1. Can Yosys be installed and run? Yes, with a workaround

| Route | Result |
|---|---|
| Alpine `apk add yosys` | Not in the Alpine 3.23 index. |
| Build from source (`apk add g++`/`build-base`) | `apk` hangs at the musl-dev trigger. Failed repeatedly. |
| PyPI `yowasp-yosys` | The wheel downloads, but it needs a glibc wasmtime library. It fails to import on musl, even with gcompat. |
| Prebuilt binary under `/opt/y` | Works. `. /opt/y/env.sh` sets `LD_LIBRARY_PATH`, `PATH` and `YOSYS_DATDIR`. |

Version that runs: `Yosys 0.68+post (git sha1 c12172fb, Release, g++ 15.2.0)`. This is the same version the earlier sessions reported.
The `/opt/y` directory is not part of the repository. A fresh sandbox has to recreate it, and I did not document how `/opt/y` was populated. That is an open reproducibility item.

## 2. Why per-module and staged runs

The sandbox kills any call after 120 s. A flat `synth_ecp5 -top soc_top` did not finish in one call.
I split it into stages (`-run begin:coarse`, `coarse:map_ram`, and so on) with RTLIL checkpoints between them.
- The first four stages of the flat SoC completed (about 6 min in total).
- The ABC LUT-mapping stage of the flat SoC did not finish within 115 s, with ABC9 on or off.
- I therefore synthesized each module separately with `scripts/synth_staged.sh`, which is resumable. All 9 modules finished.
- Flat `soc_top` synthesis has NOT been completed. No whole-SoC number exists from this session.

## 3. Per-module results (Yosys `synth_ecp5`, `-noabc9`, no place and route)

| Module | LUT4 | PFUMX | L6MUX21 | CCU2C (carry) | TRELLIS_FF | DPR16X4 (distributed RAM) | DP16KD (BRAM) | MULT18X18D |
|---|---|---|---|---|---|---|---|---|
| picorv32_wb (as parameterized by the defaults of `picorv32.v`) | 1294 | 238 | 20 | 177 | 677 | 32 | 0 | 0 |
| nna_top | 5393 | 620 | 138 | 146 | 1222 | 352 | 0 | 8 |
| safety_filter | 179 | 23 | 12 | 16 | 67 | 0 | 0 | 0 |
| soc_interconnect | 372 | 114 | 38 | 0 | 1 | 0 | 0 | 0 |
| soc_timer | 318 | 108 | 3 | 64 | 163 | 0 | 0 | 0 |
| soc_pwm | 67 | 4 | 1 | 24 | 66 | 0 | 0 | 0 |
| soc_uart | 16 | 1 | 0 | 0 | 17 | 0 | 0 | 0 |
| soc_ram | 7 | 0 | 0 | 0 | 1 | 0 | 32 | 0 |
| soc_rom | 2 | 0 | 0 | 0 | 1 | 0 | 0 | 0 |
| Sum of the above | 7648 | 1108 | 212 | 427 | 2215 | 384 | 32 | 8 |

Raw statistics: `logs/synth_per_module/*.stat.txt`.

## 4. What this means for earlier claims

- Earlier documents (11, 12, CHECKPOINT_REPORT) claim 2,686 LUTs and 4 DSPs for the SoC. Those numbers are NOT reproduced here, and no log supports them.
- The per-module sum above is about 7,650 LUT4 and 8 MULT18X18D, almost 3x higher than the claim.
- The largest contributor is `nna_top`, at 5,393 LUT4 plus 352 distributed-RAM primitives.
  Its buffers (`in_buf`, `bias_buf`, `weight_buf`, `out_buf`) are register arrays with combinational or multi-port reads. Yosys mapped them into LUT RAM and multiplexers rather than block RAM.
  That is a design finding. The buffers should be restructured as synchronous single-read-port memories if BRAM inference is wanted.
- The earlier claims should be treated as unverified and replaced by the table above, with the caveats in section 5.

## 5. Caveats (do not over-read the table)

1. The modules were synthesized separately, with no flattening. A flat run could differ because of cross-boundary optimization.
2. `soc_rom` shows 2 LUTs because no `INIT_FILE` is passed under `SYNTHESIS`, so the contents are not in the netlist. The real ROM would map to BRAM.
3. `-noabc9` is used. Numbers may differ slightly with the default flow.
4. This is Yosys mapping only. There is no place and route, no timing and no Fmax. No device utilization percentage is claimed. I could not verify the nextpnr availability or the target device.
5. Per-module statistics do not include the cell counts of submodules where a module instantiates others. `nna_top` appears to have been flattened by `synth_ecp5` before the statistics were taken, so its figure includes its children. I did not confirm this beyond reading the `stat.txt` header.

## 6. Reproduce

```
. /opt/y/env.sh
scripts/synth_staged.sh safety_filter "" rtl/safety/safety_filter.v   # repeat until DONE
scripts/synth_staged.sh nna_top "" rtl/nna/nna_core.v rtl/nna/nna_mac4.v rtl/nna/nna_regs.v rtl/nna/nna_top.v
scripts/synth_staged.sh picorv32_wb "" rtl/cpu/picorv32.v
```
`syn/synth_ecp5.ys` from earlier work remains the flat-run script, but it did not complete here within the call limit.
