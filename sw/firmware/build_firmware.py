#!/usr/bin/env python3
"""
Bare-metal Firmware Build Script
Compiles RISC-V assembly using riscv-none-elf toolchain and generates:
- .elf (ELF executable)
- .bin (Flat binary)
- .hex (Verilog $readmemh format)
- .dump (Disassembly)
"""

import sys
import os
import subprocess
import struct

def build_firmware(asm_file, out_prefix, linker_script=None):
    if linker_script is None:
        linker_script = os.path.join(os.path.dirname(__file__), "linker.ld")
    
    obj_file = out_prefix + ".o"
    elf_file = out_prefix + ".elf"
    bin_file = out_prefix + ".bin"
    hex_file = out_prefix + ".hex"
    dump_file = out_prefix + ".dump"

    print(f"--- Compiling {asm_file} ---")
    # 1. Assemble
    as_cmd = ["riscv-none-elf-as", "-march=rv32im", "-mabi=ilp32", "-o", obj_file, asm_file]
    res = subprocess.run(as_cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Assembler error:\n{res.stderr}")
        return False

    # 2. Link
    ld_cmd = ["riscv-none-elf-ld", "-T", linker_script, "-o", elf_file, obj_file]
    res = subprocess.run(ld_cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Linker error:\n{res.stderr}")
        return False

    # 3. Objcopy to binary
    oc_cmd = ["riscv-none-elf-objcopy", "-O", binary_target(elf_file), elf_file, bin_file]
    # Standard objcopy binary
    subprocess.run(["riscv-none-elf-objcopy", "-O", "binary", elf_file, bin_file], check=True)

    # 4. Generate disassembly
    res = subprocess.run(["riscv-none-elf-objdump", "-d", elf_file], capture_output=True, text=True)
    with open(dump_file, "w") as f:
        f.write(res.stdout)

    # 5. Convert binary to 32-bit hex words for Verilog $readmemh
    with open(bin_file, "rb") as f:
        bin_data = f.read()

    # Pad to multiple of 4
    if len(bin_data) % 4 != 0:
        bin_data += b"\x00" * (4 - (len(bin_data) % 4))

    num_words = len(bin_data) // 4
    with open(hex_file, "w") as f:
        for i in range(num_words):
            word = struct.unpack("<I", bin_data[i*4 : (i+1)*4])[0]
            f.write(f"{word:08x}\n")

    print(f"Build successful: {hex_file} ({len(bin_data)} bytes, {num_words} words)")
    return True

def binary_target(x):
    return "binary"

if __name__ == "__main__":
    asm_src = sys.argv[1] if len(sys.argv) > 1 else "sw/firmware/soc_firmware.s"
    out_name = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(asm_src)[0]
    success = build_firmware(asm_src, out_name)
    sys.exit(0 if success else 1)
