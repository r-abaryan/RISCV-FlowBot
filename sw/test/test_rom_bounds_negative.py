#!/usr/bin/env python3
"""Negative controls for sw/test/test_rom_bounds.py (test only, touches no tracked file).

Each case builds a corrupted copy of robot_nav.hex / robot_nav.elf (or a tool wrapper) in a
temp dir and requires test_rom_bounds.py to exit with the expected code AND print the expected
FAIL text. A control that passes unexpectedly, or fails for another reason, is a FAIL here.
Needs riscv-none-elf-{as,ld,readelf,objcopy} and a built robot_nav.elf; exits 2 if absent
(a skip, never a pass)."""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(HERE, '..', '..')
FW = f'{R}/sw/firmware'
T = f'{HERE}/test_rom_bounds.py'
TOOLS = ['riscv-none-elf-as', 'riscv-none-elf-ld', 'riscv-none-elf-readelf', 'riscv-none-elf-objcopy']
if not all(shutil.which(t) for t in TOOLS) or not os.path.exists(f'{FW}/robot_nav.elf'):
    print('SKIPPED: RISC-V binutils or robot_nav.elf absent; negative controls NOT run')
    sys.exit(2)

good = [l.strip() for l in open(f'{FW}/robot_nav.hex') if l.strip()]
td = tempfile.mkdtemp(prefix='rombounds_')


def hexfile(name, ws):
    p = f'{td}/{name}.hex'
    open(p, 'w').write(''.join(w + '\n' for w in ws))
    return p


def run(env_extra, path_prefix=None):
    env = dict(os.environ)
    env.pop('ROM_HEX', None); env.pop('ROM_ELF', None); env.pop('REQUIRE_ELF', None)
    env.update(env_extra)
    if path_prefix is not None: env['PATH'] = path_prefix
    p = subprocess.run([sys.executable, T], env=env, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def wrapper_dir(name, readelf_filter=None, hide=()):
    """PATH dir with binutils wrappers; optionally post-filter readelf -sW output, or hide tools."""
    d = f'{td}/bin_{name}'
    os.makedirs(d)
    for t in TOOLS:
        if t in hide: continue
        real = shutil.which(t)
        if t == 'riscv-none-elf-readelf' and readelf_filter:
            open(f'{d}/{t}', 'w').write(f'#!/bin/sh\n"{real}" "$@" | {readelf_filter}\n')
        else:
            open(f'{d}/{t}', 'w').write(f'#!/bin/sh\nexec "{real}" "$@"\n')
        os.chmod(f'{d}/{t}', 0o755)
    return d  # only the wrappers: hidden tools are really absent


def elf_from(name, asm):
    s, o, e = f'{td}/{name}.s', f'{td}/{name}.o', f'{td}/{name}.elf'
    open(s, 'w').write(asm)
    subprocess.check_call(['riscv-none-elf-as', '-march=rv32im', '-mabi=ilp32', s, '-o', o])
    subprocess.check_call(['riscv-none-elf-ld', '-m', 'elf32lriscv', '-T', f'{FW}/linker.ld', o, '-o', e])
    b = f'{td}/{name}.bin'
    subprocess.check_call(['riscv-none-elf-objcopy', '-O', 'binary', '-j', '.text', e, b])
    d = open(b, 'rb').read(); d += b'\0' * (-len(d) % 4)
    return e, hexfile(name, [f'{int.from_bytes(d[i:i+4], "little"):08x}' for i in range(0, len(d), 4)])


flip = list(good); flip[100] = f'{int(flip[100], 16) ^ 1:08x}'
swap = list(good); swap[10], swap[11] = swap[11], swap[10]
bad_fmt = list(good); bad_fmt[5] = bad_fmt[5].upper() if bad_fmt[5] != bad_fmt[5].upper() else 'xyz00000'
tiny_elf, tiny_hex = elf_from('tiny', '.text\n.globl _start\n_start: addi x0,x0,0\naddi x0,x0,0\n')
data_elf, data_hex = elf_from('data', '.text\n_start: addi x0,x0,0\n.data\n.word 0x12345678\n')
abs_elf, abs_hex = elf_from('abs', '.equ BIGCONST, 0x017d7840\n.globl BIGCONST\n.text\n_start: addi x0,x0,0\n')
older = f'{td}/old.elf'; shutil.copy(f'{FW}/robot_nav.elf', older)

# readelf filter: move the highest .text symbol (case3_sensors) far beyond the image
beyond = f"{shutil.which('sed')} 's/^\\( *[0-9]*: \\)0000086c\\(.*case3_sensors\\)$/\\100001ffc\\2/'"

cases = [
    # name, env, PATH, expected rc, expected text
    ('positive: tracked hex+ELF', {}, None, 0, 'SUMMARY: 7 passed'),
    ('positive: ABS .equ symbol beyond image is excluded', {'ROM_HEX': abs_hex, 'ROM_ELF': abs_elf}, None, 0,
     '1 absolute symbols excluded'),
    ('truncated hex (last word dropped)', {'ROM_HEX': hexfile('trunc', good[:-1])}, None, 1, 'FAIL hex 542 words != ELF .text'),
    ('padded hex (extra NOP)', {'ROM_HEX': hexfile('pad', good + ['00000013'])}, None, 1, 'FAIL hex 544 words != ELF .text'),
    ('one bit flipped', {'ROM_HEX': hexfile('flip', flip)}, None, 1, 'first word 100 (0x190)'),
    ('two words swapped', {'ROM_HEX': hexfile('swap', swap)}, None, 1, 'FAIL hex content != ELF image at 2 word(s); first word 10'),
    ('malformed word', {'ROM_HEX': hexfile('fmt', bad_fmt)}, None, 1, 'FAIL malformed hex word'),
    ('empty hex', {'ROM_HEX': hexfile('empty', [])}, None, 1, 'FAIL empty image'),
    ('image larger than ROM', {'ROM_HEX': hexfile('big', good + ['00000013'] * (2049 - len(good)))}, None, 1,
     'FAIL image 2049 words > ROM 2048'),
    ('hex from a different program', {'ROM_HEX': tiny_hex}, None, 1, 'FAIL hex 2 words != ELF .text'),
    ('ELF with ROM-loaded .data', {'ROM_HEX': data_hex, 'ROM_ELF': data_elf}, None, 1,
     'FAIL section .data (PROGBITS, 4 B) has ROM-loaded contents'),
    ('.text symbol beyond image', {}, wrapper_dir('beyond', beyond), 1, 'FAIL .text symbol case3_sensors at 0x1ffc beyond image'),
    ('toolchain absent, REQUIRE_ELF=1', {'REQUIRE_ELF': '1'}, wrapper_dir('none', hide=TOOLS), 2, 'SKIPPED ELF cross-checks'),
    ('toolchain absent, default', {}, wrapper_dir('none2', hide=TOOLS), 0, '5 SKIPPED'),
]

# Stale ELF: the staleness rule is checked on a scratch copy of the tree (a source made newer
# than robot_nav.elf), so no tracked file is touched. ROM_ELF overrides skip this rule by design.
stale_root = f'{td}/tree'
for sub in ('rtl', 'sw/test'):
    shutil.copytree(f'{R}/{sub}', f'{stale_root}/{sub}')
shutil.copytree(FW, f'{stale_root}/sw/firmware')
t0 = os.path.getmtime(f'{stale_root}/sw/firmware/robot_nav.elf')
os.utime(f'{stale_root}/sw/firmware/nav_weights.inc', (t0 + 10, t0 + 10))

fails = 0
for name, env, path, want_rc, want_txt in cases:
    rc, out = run(env, path)
    ok = rc == want_rc and want_txt in out
    fails += not ok
    print(f'{"PASS" if ok else "FAIL"}  {name}: rc={rc} (want {want_rc}), text {"found" if want_txt in out else "MISSING"}: {want_txt!r}')
    if not ok: print('      output:', out.strip().replace('\n', '\n      '))

env = {k: v for k, v in os.environ.items() if k not in ('ROM_HEX', 'ROM_ELF', 'REQUIRE_ELF')}
p = subprocess.run([sys.executable, f'{stale_root}/sw/test/test_rom_bounds.py'], env=env, capture_output=True, text=True)
want = "FAIL robot_nav.elf older than ['nav_weights.inc']"
ok = p.returncode == 1 and want in p.stdout
fails += not ok
print(f'{"PASS" if ok else "FAIL"}  stale ELF (nav_weights.inc newer): rc={p.returncode} (want 1), text {"found" if want in p.stdout else "MISSING"}: {want!r}')

shutil.rmtree(td)
n = len(cases) + 1
print(f'SUMMARY: {n - fails}/{n} ROM-bounds controls behaved as expected')
sys.exit(1 if fails else 0)
