#!/usr/bin/env python3
"""Firmware ROM-image provenance check (M2 C4 closure, test only).

Read-only with respect to the repository: everything is regenerated into a
temporary directory and compared word-for-word with the TRACKED hex files.
Nothing under sw/firmware is written.

Per image (the check matches how that image is actually produced):
  robot_nav, soc_cosim : ELF/binary/HEX consistency. The on-disk ELF and BIN
      produced by `make -C sim firmware` are REQUIRED (missing = setup error,
      not a skip): objcopy(ELF) must equal the on-disk BIN, and
      make_hex(BIN) must equal the tracked HEX. In addition the image is
      rebuilt from source in a temp dir and must equal the tracked HEX
      (detects an ELF/BIN/HEX set that is consistent but stale vs source).
  firmware             : deterministic regeneration with assemble.py (the tool
      `make firmware` uses) into a temp file; must equal the tracked HEX.
      A GNU-toolchain build of the same source is made only to obtain an ELF
      symbol table for the scanner's labels, and must ALSO equal the tracked
      HEX word-for-word, otherwise those labels are not trusted.
  conv_test            : regenerated from source via its test ELF and binary
      (same as-/ld-/objcopy-/make_hex commands as `make test_motor_conv`) in
      a temp dir; the regenerated HEX must equal the tracked HEX. If an
      on-disk conv_test.elf/.bin exists it must also be consistent with it.

prepare(image, tmpdir, check=True) returns the path of an ELF whose words are
verified identical to the hex being scanned (for labels). Raises
ProvenanceError(msg, rc) with rc 1 = mismatch/stale, rc 2 = missing
prerequisite or tool.

CLI: fw_provenance.py [IMAGE...]   exit 0 pass, 1 mismatch, 2 setup error.
"""
import os, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FW = os.path.join(ROOT, 'sw', 'firmware')
TOOLS = ['riscv-none-elf-as', 'riscv-none-elf-ld', 'riscv-none-elf-objcopy',
         'riscv-none-elf-nm']
SOURCES = {
    'robot_nav': 'robot_nav_firmware.s',
    'soc_cosim': 'soc_cosim_firmware.s',
    'firmware': 'soc_firmware.s',
    'conv_test': 'conv_test_firmware.s',
}
IMAGES = list(SOURCES)


class ProvenanceError(Exception):
    def __init__(self, msg, rc=1):
        super().__init__(msg)
        self.rc = rc


def _run(cmd, cwd=FW):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    except OSError as e:
        raise ProvenanceError(f'cannot run {cmd[0]}: {e}', 2)
    if r.returncode != 0:
        raise ProvenanceError(f'{" ".join(cmd)} failed rc={r.returncode}: '
                              f'{(r.stderr or r.stdout).strip()[:300]}', 2)
    return r.stdout


def _hex_words_from_bin(data):
    # identical to sw/firmware/make_hex.py (little-endian words, zero pad)
    out = []
    for i in range(0, len(data), 4):
        c = data[i:i + 4].ljust(4, b'\x00')
        out.append(f'{c[0] | (c[1] << 8) | (c[2] << 16) | (c[3] << 24):08x}')
    return out


def _read_hex(path):
    if not os.path.isfile(path):
        raise ProvenanceError(f'{path} missing', 2)
    with open(path) as f:
        return [ln.strip() for ln in f if ln.strip()]


def _need(path):
    if not os.path.isfile(path):
        raise ProvenanceError(f'required prerequisite {path} missing '
                              f'(run make -C sim firmware); not a pass', 2)


def _cmp(a, b, what):
    if a != b:
        n = min(len(a), len(b))
        i = next((k for k in range(n) if a[k] != b[k]), n)
        raise ProvenanceError(f'{what}: differ ({len(a)} vs {len(b)} words, '
                              f'first difference at word {i})', 1)


def gnu_build(image, tmpdir):
    """Build SOURCES[image] in tmpdir; return (elf, bin) paths."""
    src = os.path.join(FW, SOURCES[image])
    _need(src)
    o, elf, bn = (os.path.join(tmpdir, f'{image}.{e}') for e in ('o', 'elf', 'bin'))
    _run(['riscv-none-elf-as', '-march=rv32im', '-mabi=ilp32', '-I', FW, src, '-o', o])
    _run(['riscv-none-elf-ld', '-m', 'elf32lriscv', '-T', os.path.join(FW, 'linker.ld'),
          o, '-o', elf])
    _run(['riscv-none-elf-objcopy', '-O', 'binary', elf, bn])
    return elf, bn


def _bin_words(path):
    with open(path, 'rb') as f:
        return _hex_words_from_bin(f.read())


def _elf_words(elf, tmpdir, tag):
    bn = os.path.join(tmpdir, f'{tag}.objcopy.bin')
    _run(['riscv-none-elf-objcopy', '-O', 'binary', elf, bn])
    return _bin_words(bn)


def check_tools():
    for t in TOOLS:
        _run([t, '--version'])


def prepare(image, tmpdir, check=True, log=print):
    """Verify provenance of the tracked hex (if check) and return a label ELF
    whose words equal the tracked hex."""
    if image not in SOURCES:
        raise ProvenanceError(f'unknown image {image}', 2)
    tracked_hex = os.path.join(FW, f'{image}.hex')
    tracked = _read_hex(tracked_hex)
    sub = os.path.join(tmpdir, image)
    os.makedirs(sub, exist_ok=True)
    elf, bn = gnu_build(image, sub)
    regen = _bin_words(bn)
    if image in ('robot_nav', 'soc_cosim'):
        dele, debn = (os.path.join(FW, f'{image}.{e}') for e in ('elf', 'bin'))
        _need(dele); _need(debn)
        if check:
            _cmp(_elf_words(dele, sub, 'disk'), _bin_words(debn),
                 f'{image}: objcopy(on-disk ELF) vs on-disk BIN')
            _cmp(_bin_words(debn), tracked, f'{image}: make_hex(on-disk BIN) vs tracked HEX')
            _cmp(regen, tracked, f'{image}: rebuild from source vs tracked HEX (stale?)')
            log(f'[PROV] {image}: on-disk ELF == BIN == tracked HEX ({len(tracked)} words); '
                f'source rebuild identical')
        return dele
    if image == 'firmware':
        if check:
            out = os.path.join(sub, 'firmware.assemble_py.hex')
            _run([sys.executable, os.path.join(FW, 'assemble.py'),
                  os.path.join(FW, 'soc_firmware.s'), out])
            _cmp(_read_hex(out), tracked, 'firmware: assemble.py regeneration vs tracked HEX')
        # label ELF only trusted if its words equal the tracked hex
        _cmp(regen, tracked, 'firmware: GNU label ELF vs tracked HEX (labels untrusted)')
        if check:
            log(f'[PROV] firmware: assemble.py regeneration == tracked HEX ({len(tracked)} words); '
                f'GNU label ELF identical')
        return elf
    # conv_test
    if check:
        _cmp(regen, tracked, 'conv_test: ELF/BIN regeneration vs tracked HEX')
        extra = ''
        dele, debn = (os.path.join(FW, f'conv_test.{e}') for e in ('elf', 'bin'))
        if os.path.isfile(dele) and os.path.isfile(debn):
            _cmp(_elf_words(dele, sub, 'disk'), _bin_words(debn),
                 'conv_test: objcopy(on-disk ELF) vs on-disk BIN')
            _cmp(_bin_words(debn), tracked, 'conv_test: on-disk BIN vs tracked HEX')
            extra = '; on-disk ELF/BIN also identical'
        log(f'[PROV] conv_test: ELF/BIN regeneration == tracked HEX ({len(tracked)} words){extra}')
    return elf


def main():
    names = sys.argv[1:] or IMAGES
    rc = 0
    with tempfile.TemporaryDirectory(prefix='fwprov_') as td:
        try:
            check_tools()
        except ProvenanceError as e:
            print(f'[PROV-FAIL] {e}'); sys.exit(e.rc)
        for nm in names:
            try:
                prepare(nm, td)
            except ProvenanceError as e:
                print(f'[PROV-FAIL] {e}'); rc = max(rc, e.rc)
    print('[PROV-PASS]' if rc == 0 else '[PROV-FAIL]')
    sys.exit(rc)


if __name__ == '__main__':
    main()
