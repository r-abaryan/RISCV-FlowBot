#!/usr/bin/env python3
"""
Simple two-pass RISC-V RV32IM Assembler for Mobile Robot SoC Boot ROM.
Translates assembly instructions in soc_firmware.s to 32-bit hex words.
"""

import sys
import re

REGS = {
    'zero': 0, 'x0': 0,
    'ra': 1, 'x1': 1,
    'sp': 2, 'x2': 2,
    'gp': 3, 'x3': 3,
    'tp': 4, 'x4': 4,
    't0': 5, 'x5': 5,
    't1': 6, 'x6': 6,
    't2': 7, 'x7': 7,
    's0': 8, 'fp': 8, 'x8': 8,
    's1': 9, 'x9': 9,
    'a0': 10, 'x10': 10,
    'a1': 11, 'x11': 11,
    'a2': 12, 'x12': 12,
    'a3': 13, 'x13': 13,
    'a4': 14, 'x14': 14,
    'a5': 15, 'x15': 15,
    'a6': 16, 'x16': 16,
    'a7': 17, 'x17': 17,
    's2': 18, 'x18': 18,
    's3': 19, 'x19': 19,
    's4': 20, 'x20': 20,
    's5': 21, 'x21': 21,
    's6': 22, 'x22': 22,
    's7': 23, 'x23': 23,
    's8': 24, 'x24': 24,
    's9': 25, 'x25': 25,
    's10': 26, 'x26': 26,
    's11': 27, 'x27': 27,
    't3': 28, 'x28': 28,
    't4': 29, 'x29': 29,
    't5': 30, 'x30': 30,
    't6': 31, 'x31': 31,
}

def parse_val(v):
    v = v.strip()
    if v.startswith('0x') or v.startswith('0X'):
        return int(v, 16)
    return int(v)

def parse_mem_operand(op):
    m = re.match(r'([+-]?(?:0x[0-9a-fA-F]+|\d+))\s*\(\s*([a-zA-Z0-9]+)\s*\)', op.strip())
    if not m:
        raise ValueError(f"Invalid memory operand: {op}")
    offset = parse_val(m.group(1))
    reg = m.group(2).strip()
    return offset, reg

def expand_pseudo(line):
    tokens = re.split(r'[\s,]+', line.strip())
    op = tokens[0]
    args = [t for t in tokens[1:] if t]

    if op == 'nop':
        return [('addi', ['zero', 'zero', '0'])]
    elif op == 'mv':
        return [('addi', [args[0], args[1], '0'])]
    elif op == 'bnez':
        return [('bne', [args[0], 'zero', args[1]])]
    elif op == 'beqz':
        return [('beq', [args[0], 'zero', args[1]])]
    elif op == 'ble':
        return [('bge', [args[1], args[0], args[2]])]
    elif op == 'j':
        return [('jal', ['zero', args[0]])]
    elif op == 'li':
        rd = args[0]
        imm = parse_val(args[1])
        if -2048 <= imm <= 2047:
            return [('addi', [rd, 'zero', str(imm)])]
        else:
            imm32 = imm & 0xFFFFFFFF
            lower = imm32 & 0xFFF
            if lower >= 2048:
                lower -= 4096
            upper = ((imm32 - lower) >> 12) & 0xFFFFF
            if lower == 0:
                return [('lui', [rd, hex(upper)])]
            else:
                return [
                    ('lui', [rd, hex(upper)]),
                    ('addi', [rd, rd, str(lower)])
                ]
    else:
        return [(op, args)]

def encode_inst(op, args, pc, labels):
    if op == 'lui':
        rd = REGS[args[0]]
        imm = parse_val(args[1]) & 0xFFFFF
        return ((imm << 12) | (rd << 7) | 0x37) & 0xFFFFFFFF

    elif op == 'addi':
        rd = REGS[args[0]]
        rs1 = REGS[args[1]]
        imm = parse_val(args[2])
        if not (-2048 <= imm <= 2047):
            raise ValueError(f"Immediate out of 12-bit range [-2048, 2047]: {imm}")
        imm = imm & 0xFFF
        return ((imm << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13) & 0xFFFFFFFF

    elif op == 'andi':
        rd = REGS[args[0]]
        rs1 = REGS[args[1]]
        imm = parse_val(args[2])
        if not (-2048 <= imm <= 2047):
            raise ValueError(f"Immediate out of 12-bit range [-2048, 2047]: {imm}")
        imm = imm & 0xFFF
        return ((imm << 20) | (rs1 << 15) | (7 << 12) | (rd << 7) | 0x13) & 0xFFFFFFFF

    elif op == 'slli':
        rd = REGS[args[0]]
        rs1 = REGS[args[1]]
        shamt = parse_val(args[2]) & 0x1F
        return ((shamt << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13) & 0xFFFFFFFF

    elif op == 'srai':
        rd = REGS[args[0]]
        rs1 = REGS[args[1]]
        shamt = parse_val(args[2]) & 0x1F
        return ((0x20 << 25) | (shamt << 20) | (rs1 << 15) | (5 << 12) | (rd << 7) | 0x13) & 0xFFFFFFFF

    elif op == 'add':
        rd = REGS[args[0]]
        rs1 = REGS[args[1]]
        rs2 = REGS[args[2]]
        return ((0 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33) & 0xFFFFFFFF

    elif op == 'mul':
        rd = REGS[args[0]]
        rs1 = REGS[args[1]]
        rs2 = REGS[args[2]]
        return ((1 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33) & 0xFFFFFFFF

    elif op == 'lw':
        rd = REGS[args[0]]
        offset, rs1_name = parse_mem_operand(args[1])
        rs1 = REGS[rs1_name]
        if not (-2048 <= offset <= 2047):
            raise ValueError(f"Memory offset out of 12-bit range [-2048, 2047]: {offset}")
        imm = offset & 0xFFF
        return ((imm << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03) & 0xFFFFFFFF

    elif op == 'sw':
        rs2 = REGS[args[0]]
        offset, rs1_name = parse_mem_operand(args[1])
        rs1 = REGS[rs1_name]
        if not (-2048 <= offset <= 2047):
            raise ValueError(f"Memory offset out of 12-bit range [-2048, 2047]: {offset}")
        imm = offset & 0xFFF
        imm_11_5 = (imm >> 5) & 0x7F
        imm_4_0 = imm & 0x1F
        return ((imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | (imm_4_0 << 7) | 0x23) & 0xFFFFFFFF

    elif op in ('beq', 'bne', 'blt', 'bge'):
        rs1 = REGS[args[0]]
        rs2 = REGS[args[1]]
        target_name = args[2]
        if target_name not in labels:
            raise ValueError(f"Unknown branch label: {target_name}")
        target = labels[target_name]
        offset = target - pc
        funct3 = {'beq': 0, 'bne': 1, 'blt': 4, 'bge': 5}[op]
        imm_12 = (offset >> 12) & 1
        imm_11 = (offset >> 11) & 1
        imm_10_5 = (offset >> 5) & 0x3F
        imm_4_1 = (offset >> 1) & 0xF
        return ((imm_12 << 31) | (imm_10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_1 << 8) | (imm_11 << 7) | 0x63) & 0xFFFFFFFF

    elif op == 'jal':
        rd = REGS[args[0]]
        target_name = args[1]
        if target_name not in labels:
            raise ValueError(f"Unknown jump label: {target_name}")
        target = labels[target_name]
        offset = target - pc
        imm_20 = (offset >> 20) & 1
        imm_10_1 = (offset >> 1) & 0x3FF
        imm_11 = (offset >> 11) & 1
        imm_19_12 = (offset >> 12) & 0xFF
        return ((imm_20 << 31) | (imm_10_1 << 21) | (imm_11 << 20) | (imm_19_12 << 12) | (rd << 7) | 0x6F) & 0xFFFFFFFF

    else:
        raise ValueError(f"Unsupported instruction: {op} {' '.join(args)}")

def assemble_file(src_path, dst_path):
    with open(src_path, 'r') as f:
        content = f.read()

    # Strip multiline C comments
    content = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)
    lines = content.splitlines()

    # Pass 1: Parse labels and expand pseudo-instructions
    instructions = []
    labels = {}
    pc = 0

    for line_num, line in enumerate(lines, 1):
        line = re.sub(r'#.*$', '', line)
        line = re.sub(r'//.*$', '', line)
        line = line.strip()

        if not line or line.startswith('.'):
            continue

        # Check for label
        if ':' in line:
            parts = line.split(':', 1)
            label = parts[0].strip()
            labels[label] = pc
            line = parts[1].strip()
            if not line:
                continue

        # Expand pseudo instructions
        expanded = expand_pseudo(line)
        for inst in expanded:
            instructions.append((pc, inst[0], inst[1]))
            pc += 4

    # Pass 2: Encode instructions
    hex_words = []
    for cur_pc, op, args in instructions:
        word = encode_inst(op, args, cur_pc, labels)
        hex_words.append(f"{word:08x}")

    with open(dst_path, 'w') as f:
        for w in hex_words:
            f.write(w + '\n')

    print(f"Assembled {len(hex_words)} instructions ({len(hex_words)*4} bytes) successfully.")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: assemble.py <input.s> <output.hex>")
        sys.exit(1)
    assemble_file(sys.argv[1], sys.argv[2])
