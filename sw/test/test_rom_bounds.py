#!/usr/bin/env python3
"""Deterministic ROM bounds/truncation check for robot_nav.hex.
Checks: (1) ROM depth from rtl/soc_top.v == linker ROM LENGTH; (2) hex words <= ROM depth;
(3) hex length == ELF .text size rounded up to 4 bytes (i.e. NOT truncated; the $readmemh
'Not enough words' warning is then only the unused ROM tail, which soc_rom.v pre-fills with NOPs);
(4) no word of the image lies beyond ROM; (5) the ELF end symbol/last symbol lies inside the image.
Needs riscv-none-elf-size/nm and robot_nav.elf for (3),(5); otherwise those are reported SKIPPED."""
import os, re, subprocess, shutil, sys
R = os.path.join(os.path.dirname(__file__), '..', '..')
FW = f'{R}/sw/firmware'
def fail(m): print('FAIL', m); sys.exit(1)
depth = int(re.search(r'\.MEM_SIZE_WORDS\s*\(\s*(\d+)', open(f'{R}/rtl/soc_top.v').read().split('soc_rom')[1]).group(1))
ld = re.search(r'ROM\s*\(rx\)\s*:\s*ORIGIN\s*=\s*(\w+),\s*LENGTH\s*=\s*(\d+)K', open(f'{FW}/linker.ld').read())
if int(ld.group(1), 0) != 0: fail('ROM origin not 0')
if int(ld.group(2)) * 1024 != depth * 4: fail(f'linker ROM {ld.group(2)}K != RTL {depth} words')
words = [l.strip() for l in open(f'{FW}/robot_nav.hex') if l.strip() and not l.startswith('//')]
if not all(re.fullmatch(r'[0-9a-f]{8}', w) for w in words): fail('malformed hex word')
n = len(words)
if n > depth: fail(f'image {n} words > ROM {depth}')
print(f'OK   ROM depth {depth} words (RTL == linker {ld.group(2)}K); image {n} words; unused tail {depth-n} words')
if shutil.which('riscv-none-elf-size') and os.path.exists(f'{FW}/robot_nav.elf'):
    sz = subprocess.check_output(['riscv-none-elf-size', '-A', f'{FW}/robot_nav.elf'], text=True)
    text = int(re.search(r'^\.text\s+(\d+)', sz, re.M).group(1))
    if n != (text + 3) // 4: fail(f'hex {n} words != ELF .text {text} bytes -> possible truncation/stale hex')
    nm = subprocess.check_output(['riscv-none-elf-nm', '-n', f'{FW}/robot_nav.elf'], text=True).split()
    last = max(int(l.split()[0], 16) for l in subprocess.check_output(['riscv-none-elf-nm', f'{FW}/robot_nav.elf'], text=True).splitlines() if len(l.split()) == 3)
    if last >= n * 4: fail('symbol beyond image')
    print(f'OK   hex words == ceil(.text {text} B / 4); highest symbol 0x{last:x} inside image ({n*4} B)')
else:
    print('SKIPPED ELF cross-check (toolchain or robot_nav.elf absent)')
