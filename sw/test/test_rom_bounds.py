#!/usr/bin/env python3
"""Deterministic ROM bounds/truncation check for robot_nav.hex (test only).

Checks:
 (1) ROM depth from rtl/soc_top.v == linker ROM LENGTH, ROM origin 0;
 (2) every hex line is one 8-digit lowercase word and the image fits the ROM;
 (3) hex length == ELF .text size rounded up to 4 bytes (not truncated, not padded);
 (4) hex content == the ELF ROM image (objcopy -O binary, little-endian words), word by word,
     so a stale or corrupted hex is caught, not just a wrong length;
 (5) no ROM-loaded section other than .text carries bytes (.data size 0), so .text IS the image;
 (6) every symbol defined in .text lies inside the image (0 <= value <= image bytes).
     Absolute symbols (.equ constants such as CLK_HZ) are NOT addresses and are excluded;
     the earlier version counted them and failed spuriously on CLK_HZ = 0x017d7840.

Checks (3)-(6) need robot_nav.elf and riscv-none-elf-{readelf,objcopy}. Without them they are
reported SKIPPED (never as passes). REQUIRE_ELF=1 turns any skip into exit 2.
ROM_HEX / ROM_ELF override the file paths (used only by the negative controls).
"""
import os, re, subprocess, shutil, sys, tempfile

R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
FW = f'{R}/sw/firmware'
HEX = os.environ.get('ROM_HEX', f'{FW}/robot_nav.hex')
ELF = os.environ.get('ROM_ELF', f'{FW}/robot_nav.elf')
READELF, OBJCOPY = 'riscv-none-elf-readelf', 'riscv-none-elf-objcopy'
passed, skipped = [], []


def fail(m):
    print('FAIL', m)
    sys.exit(1)


src = open(f'{R}/rtl/soc_top.v').read()
m = re.search(r'soc_rom\s*#\s*\(\s*\.MEM_SIZE_WORDS\s*\(\s*(\d+)\s*\)', src)
if not m: fail('cannot find soc_rom MEM_SIZE_WORDS in rtl/soc_top.v')
depth = int(m.group(1))
ld = re.search(r'ROM\s*\(rx\)\s*:\s*ORIGIN\s*=\s*(\w+),\s*LENGTH\s*=\s*(\d+)K', open(f'{FW}/linker.ld').read())
if not ld: fail('cannot find ROM region in linker.ld')
if int(ld.group(1), 0) != 0: fail('ROM origin not 0')
if int(ld.group(2)) * 1024 != depth * 4: fail(f'linker ROM {ld.group(2)}K != RTL {depth} words')
passed.append('depth/linker match')

lines = [l.rstrip('\n') for l in open(HEX)]
words = [l.strip() for l in lines if l.strip() and not l.lstrip().startswith('//')]
bad = [w for w in words if not re.fullmatch(r'[0-9a-f]{8}', w)]
if bad: fail(f'malformed hex word {bad[0]!r}')
if any(l.lstrip().startswith('@') for l in lines): fail('address directive in hex (not supported)')
n = len(words)
if n == 0: fail('empty image')
if n > depth: fail(f'image {n} words > ROM {depth}')
passed.append('image fits ROM')
print(f'OK   ROM depth {depth} words (RTL == linker {ld.group(2)}K); image {n} words; unused tail {depth-n} words')

if shutil.which(READELF) and shutil.which(OBJCOPY) and os.path.exists(ELF):
    secs = {}
    for l in subprocess.check_output([READELF, '-SW', ELF], text=True).splitlines():
        mm = re.match(r'\s*\[\s*(\d+)\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)\s+\S+\s+([A-Za-z]*)', l)
        if mm and mm.group(3) != 'NULL':
            secs[mm.group(2)] = (int(mm.group(1)), mm.group(3), int(mm.group(4), 16), int(mm.group(5), 16), mm.group(6))
    srcs = [f'{FW}/robot_nav_firmware.s', f'{FW}/linker.ld'] + [f'{FW}/{i}' for i in re.findall(
        r'\.include\s+"([^"]+)"', open(f'{FW}/robot_nav_firmware.s').read())]
    stale = [os.path.basename(x) for x in srcs if os.path.exists(x) and os.path.getmtime(x) > os.path.getmtime(ELF)]
    if stale and 'ROM_ELF' not in os.environ: fail(f'robot_nav.elf older than {stale}: stale ELF, run make firmware first')
    passed.append('ELF not older than sources')
    if '.text' not in secs: fail('ELF has no .text')
    tidx, _, taddr, text, _ = secs['.text']
    if taddr != 0: fail(f'.text at 0x{taddr:x}, not ROM origin 0')
    if n != (text + 3) // 4: fail(f'hex {n} words != ELF .text {text} bytes -> truncation/padding/stale hex')
    passed.append('hex length == ELF .text')
    print(f'OK   hex words == ceil(.text {text} B / 4)')

    # (5) any other allocated section with file contents would also be loaded from ROM
    for name, (_, typ, addr, size, flags) in secs.items():
        if name != '.text' and 'A' in flags and typ != 'NOBITS' and size:
            fail(f'section {name} ({typ}, {size} B) has ROM-loaded contents not covered by the .text check')
    passed.append('no other ROM-loaded bytes')

    # (4) content: objcopy binary == hex words
    with tempfile.TemporaryDirectory() as td:
        b = os.path.join(td, 'rom.bin')
        subprocess.check_call([OBJCOPY, '-O', 'binary', '-j', '.text', ELF, b])
        data = open(b, 'rb').read()
    data += b'\x00' * (-len(data) % 4)
    ref = [f'{int.from_bytes(data[i:i+4], "little"):08x}' for i in range(0, len(data), 4)]
    if len(ref) != n: fail(f'objcopy image {len(ref)} words != hex {n} words')
    diff = [i for i in range(n) if ref[i] != words[i]]
    if diff:
        i = diff[0]
        fail(f'hex content != ELF image at {len(diff)} word(s); first word {i} (0x{4*i:x}): hex {words[i]} elf {ref[i]}')
    passed.append('hex content == ELF image')
    print(f'OK   all {n} hex words equal the ELF .text image')

    # (6) symbols defined in .text only (absolute .equ constants are not addresses)
    syms, n_abs = [], 0
    for l in subprocess.check_output([READELF, '-sW', ELF], text=True).splitlines():
        f = l.split()
        if len(f) >= 7 and f[0].endswith(':') and f[3] in ('NOTYPE', 'FUNC', 'OBJECT'):
            if f[6] == 'ABS': n_abs += 1
            elif f[6] == str(tidx): syms.append((int(f[1], 16), f[7] if len(f) > 7 else ''))
    if not syms: fail('no .text symbols found (cannot check)')
    hi = max(syms)
    if hi[0] > n * 4: fail(f'.text symbol {hi[1]} at 0x{hi[0]:x} beyond image ({n*4} B)')
    passed.append('.text symbols inside image')
    print(f'OK   {len(syms)} .text symbols, highest {hi[1]} 0x{hi[0]:x} <= image end 0x{n*4:x}; '
          f'{n_abs} absolute symbols excluded (constants, not addresses)')
else:
    skipped.extend(['ELF not older than sources', 'hex length == ELF .text', 'no other ROM-loaded bytes', 'hex content == ELF image',
                    '.text symbols inside image'])
    print('SKIPPED ELF cross-checks (riscv-none-elf-readelf/objcopy or robot_nav.elf absent): NOT verified, NOT counted as pass')

print(f'SUMMARY: {len(passed)} passed ({"; ".join(passed)}); {len(skipped)} SKIPPED ({"; ".join(skipped) or "none"})')
if skipped:
    print('WARNING: result is PARTIAL. Skipped checks are not passes. Set REQUIRE_ELF=1 to make skips a failure.')
    if os.environ.get('REQUIRE_ELF') == '1': sys.exit(2)
