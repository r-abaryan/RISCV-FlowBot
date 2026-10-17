#!/usr/bin/env python3
"""M7D: SoC-executed boundary tests of the assembly safety filter (robot_nav_firmware.s).
Each scenario patches the three sensor frames in the firmware, assembles it (RV32 target
assembler), runs it on the full soc_top RTL (iverilog), parses the real NNA raw outputs and
PWM writes from the testbench log, and compares the PWM with test_safety_c_mirror.f().
Negative controls: mutated firmware (a protection disabled) MUST fail the same checks.
Note: tb_soc_nav's own hard-coded asserts may $fatal for patched frames; only its log is used.
Needs: riscv-none-elf-as/ld/objcopy, iverilog, vvp."""
import os, re, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(__file__))
from test_safety_c_mirror import f
R = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FW = R + '/sw/firmware'
def s8(x): return x-256 if x > 127 else x
def dist_cm(w0, w1):
    q = [s8((w0 >> (8*i)) & 255) for i in (2, 3)] + [s8((w1 >> (8*i)) & 255) for i in (0, 1)]
    return max(0, ((min(q)+127)*403) >> 8)
def duty(x): return max(0, min(1000, ((x+128)*1000) >> 8))
def frame(d3=0x64):
    """open corridor (all 0x64) except one front sensor (d3, byte 3 of word0) set to d3.
    Only one sensor is changed so the policy still wants to drive forward (raw v>0)."""
    return (d3 << 24 | 0x00646464, 0x64646464)
SCEN = {
 'proximity_cap':   [frame(0x94)]*3,                 # q=-108 -> 30 cm: cap=(30-25)*5>>3=3
 'invalid_sensor':  [frame(0x80)]*3,                 # q=-128 (invalid) -> contact
 'slew_open':       [frame(0x64)]*3,                 # far: only slew/clamp limit v
}
MUT = {   # name -> (old, new, scenario that must detect it)
 'no_proximity_cap': ('ble  s2, t5, 15f', 'j    15f', 'proximity_cap'),
 'no_stop_zone':     ('li   s2, 0                /* within stop', 'nop                       /* within stop', 'invalid_sensor'),
 'invalid_as_far':   ('addi t4, t4, 127', 'addi t4, t4, 255', 'invalid_sensor'),
 'no_slew':          ('ble  t3, t5, 9f\n    add  s2, t1, t5', 'ble  t3, t5, 9f\n    nop', 'slew_open'),
}
# ---- M10c: nonnegative chassis-velocity tests (TEST-ONLY raw-v injection) ----------------------
# The injection exists only in a generated copy of the assembly built inside a temp dir; production
# robot_nav_firmware.s / firmware.hex are never modified. It replaces s2 (v_raw) after NNA readback
# with a per-tick value from INJ[name]; w_raw stays the real policy output.
INJ = {   # name -> (frames, injected raw v per tick)
 'rev_clear':   ([frame(0x64)]*3, (-64, -64, -64)),   # open space, reverse requested: must stay 0
 'rev_blocked': ([frame(0x80)]*3, (-64, -64, -64)),   # contact + brake/reverse request: must stay 0
 'rev_state':   ([frame(0x64)]*3, (-64, 64, 64)),     # clamped state 0 -> slew 8 -> 16 (pre-clamp state would give 0 -> 8)
}
INJ_EXPECT_V = {'rev_clear': (0, 0, 0), 'rev_blocked': (0, 0, 0), 'rev_state': (0, 8, 16)}
INJ_SRC_OLD = 'sra  s2, s2, 24           /* s2 = v_raw (-128..127) */'
INJ_ZERO_OLD = '    sw   zero, 4(t0)\n'
def inject(src, seq):
    assert src.count(INJ_SRC_OLD) == 1 and src.count(INJ_ZERO_OLD) == 1
    a, b, c = seq
    code = (INJ_SRC_OLD + "\n    /* TEST-ONLY raw-v injection */\n    li a1, 0x20003F10\n    lw a2, 0(a1)\n"
            "    addi a3, a2, 1\n    sw a3, 0(a1)\n    li s2, %d\n    beqz a2, 1f\n    li s2, %d\n"
            "    li a3, 1\n    beq a2, a3, 1f\n    li s2, %d\n1:\n") % (a, b, c)
    src = src.replace(INJ_SRC_OLD, code)
    return src.replace(INJ_ZERO_OLD, INJ_ZERO_OLD + '    sw   zero, 16(t0)\n')
_DUTY = {duty(x): x for x in range(-128, 128)}
assert len(_DUTY) == 256            # duty() is injective on -128..127, so PWM decodes exactly
def decode_v(L, Rr):
    """Independent of the mirror: recover chassis v from PWM duties (left=v-w, right=v+w)."""
    xl, xr = _DUTY.get(L), _DUTY.get(Rr)
    if xl is None or xr is None or (xl + xr) % 2: return None
    return (xl + xr) // 2
def check_inj(name, raw, pwm):
    frames, seq = INJ[name]; errs = []
    if len(raw) != 3 or len(pwm) != 3: return [f'expected 3 ticks, got raw={len(raw)} pwm={len(pwm)}']
    st = (0, 0); exp = INJ_EXPECT_V[name]; prev = 0
    for k, ((w0, w1), (_, rw), (L, Rr)) in enumerate(zip(frames, raw, pwm)):
        st = f(st, seq[k], s8(rw), dist_cm(w0, w1))
        eL, eR = duty(st[0]-st[1]), duty(st[0]+st[1])
        v = decode_v(L, Rr)
        if (L, Rr) != (eL, eR): errs.append(f'tick{k}: pwm=({L:04x},{Rr:04x}) mirror=({eL:04x},{eR:04x})')
        if v is None: errs.append(f'tick{k}: PWM not decodable'); continue
        if v < 0: errs.append(f'tick{k}: decoded chassis v={v} < 0')
        if v != exp[k]: errs.append(f'tick{k}: decoded v={v} expected {exp[k]}')
        if st[0] != exp[k]: errs.append(f'tick{k}: mirror v={st[0]} expected {exp[k]}')
        if abs(v - prev) > 8: errs.append(f'tick{k}: slew violated {prev}->{v}')
        prev = v
    return errs
RMUT = {   # M10c negative controls, applied on top of the fixed firmware; scenario that must detect
 'no_clamp':      ('bgez s2, 16f', 'j    16f', 'rev_clear'),
 'store_preclamp': ('15: bgez s2, 16f              /* M10c: final linear velocity is never negative */\n    li   s2, 0\n16: sw   s2, 0(t0)            /* last_v = v_safe (already clamped) */',
                    '15: sw   s2, 0(t0)\n    bgez s2, 16f\n    li   s2, 0\n16:', 'rev_state'),
}
def sh(cmd, **k): return subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True, **k)
def build(src, out):
    d = os.path.dirname(out)
    open(d+'/fw.s', 'w').write(src)
    sh(f'cd {d} && riscv-none-elf-as -I {FW} -march=rv32im -mabi=ilp32 fw.s -o fw.o && '
       f'riscv-none-elf-ld -m elf32lriscv -T {FW}/linker.ld fw.o -o fw.elf && '
       f'riscv-none-elf-objcopy -O binary fw.elf fw.bin && python3 {FW}/make_hex.py fw.bin {out}')
def patch_frames(src, frames):
    for i, (a, b) in enumerate(frames, 1):
        pat = re.compile(r'(case%d_sensors:\s*\n\s*\.word )0x[0-9A-Fa-f]+(.*\n\s*\.word )0x[0-9A-Fa-f]+' % i)
        src, n = pat.subn(lambda m: f'{m.group(1)}0x{a:08X}{m.group(2)}0x{b:08X}', src); assert n == 1
    return src
def run(tmp, src, frames):
    hexf = tmp+'/fw.hex'; build(patch_frames(src, frames), hexf)
    # stop vvp as soon as the 3 ticks (+ initial PWM write) are logged: saves simulation time
    pr = subprocess.Popen(['vvp', tmp+'/tb.vvp'], stdout=subprocess.PIPE, text=True, cwd=tmp)
    r = ''
    for line in pr.stdout:
        r += line
        if r.count('PWM Duty Cycle Written') >= 4: break
    pr.kill(); pr.wait()
    raw = [(int(a, 16), int(b, 16)) for a, b in re.findall(r'v_raw=0x([0-9a-f]+), w_raw=0x([0-9a-f]+)', r)]
    pwm = [(int(a, 16), int(b, 16)) for a, b in re.findall(r'Left=0x([0-9a-f]+) \(\d+\), Right=0x([0-9a-f]+)', r)]
    return raw, pwm[1:]   # [0] is the PWM init write
def check(frames, raw, pwm):
    """Return list of failures comparing PWM with the reference filter on the real raw outputs."""
    errs = []
    if len(raw) != 3 or len(pwm) != 3: return [f'expected 3 ticks, got raw={len(raw)} pwm={len(pwm)}']
    st = (0, 0)
    for k, ((w0, w1), (rv, rw), (L, Rr)) in enumerate(zip(frames, raw, pwm)):
        d = dist_cm(w0, w1); st = f(st, s8(rv), s8(rw), d)
        eL, eR = duty(st[0]-st[1]), duty(st[0]+st[1])
        if (L, Rr) != (eL, eR): errs.append(f'tick{k}: pwm=({L:04x},{Rr:04x}) expected=({eL:04x},{eR:04x}) d={d} raw=({s8(rv)},{s8(rw)})')
    return errs
def states(name, raw):
    st = (0, 0); out = []
    for (w0, w1), (rv, rw) in zip(SCEN[name], raw):
        st = f(st, s8(rv), s8(rw), dist_cm(w0, w1)); out.append(st[0])
    return out
def exercised(name, raw):
    """Guard against a vacuous reference: the raw policy output must actually demand
    something the filter has to restrict."""
    v = states(name, raw); rv = [s8(r[0]) for r in raw]
    if name == 'proximity_cap':  return max(rv) > 3 and max(v) <= 3
    if name == 'invalid_sensor': return max(rv) > 0 and max(v) <= 0
    if name == 'slew_open':      return v[0] == 8 and rv[0] > 8
    return True
def setup():
    tmp = tempfile.mkdtemp()
    srcs = sh(f'find {R}/rtl -name "*.v" ! -name "ibex_wb_adapter.v" | sort').stdout.split()
    sh(f'iverilog -I{R}/rtl -DROM_INIT_FILE=\\"{tmp}/fw.hex\\" -o {tmp}/tb.vvp {" ".join(srcs)} {R}/sim/tb_soc_nav.v')
    return tmp, open(FW+'/robot_nav_firmware.s').read()
def main(args):
    """args: scen:NAME | mut:NAME | rev:NAME | revbase:NAME | revmut:NAME | (none = everything; ~50 s of simulation per item)"""
    tmp, base = setup()
    todo = args or ['scen:'+n for n in SCEN] + ['mut:'+n for n in MUT]
    fails = 0
    for a in todo:
        kind, name = a.split(':')
        if kind in ('rev', 'revbase', 'revmut'):
            if kind == 'revmut':
                old, new, scen = RMUT[name]; assert old in base, name
                src = base.replace(old, new, 1)
            elif kind == 'revbase':   # pre-fix firmware from BASE_REV (default 082fd98 = main before M10c) (baseline-first proof)
                scen = name; src = sh(f'cd {R} && git show {os.environ.get("BASE_REV", "082fd98")}:sw/firmware/robot_nav_firmware.s').stdout
            else:
                scen = name; src = base
            raw, pwm = run(tmp, inject(src, INJ[scen][1]), INJ[scen][0])
            e = check_inj(scen, raw, pwm)
            ok = (not e) if kind == 'rev' else bool(e)
            lab = {'rev': 'scenario', 'revbase': 'BASELINE must fail', 'revmut': 'negative control'}[kind]
            print(f'[{"PASS" if ok else "FAIL"}] {lab} {name} ({scen}): pwm={pwm}', *(e[:3]), flush=True)
            fails += (not ok); continue
        if kind == 'scen':
            raw, pwm = run(tmp, base, SCEN[name]); e = check(SCEN[name], raw, pwm)
            if not e and not exercised(name, raw): e = ['scenario does not exercise the protection']
            print(f'[{"PASS" if not e else "FAIL"}] {name}: raw={[(s8(x), s8(y)) for x, y in raw]} pwm={pwm}', *e, flush=True)
            fails += bool(e)
        else:
            old, new, scen = MUT[name]; assert old in base, name
            raw, pwm = run(tmp, base.replace(old, new, 1), SCEN[scen]); e = check(SCEN[scen], raw, pwm)
            print(f'[{"PASS" if e else "FAIL"}] negative control {name} (on {scen}): {"detected: "+e[0] if e else "NOT DETECTED"}', flush=True)
            fails += (not e)
    print('RESULT', 'FAIL' if fails else 'PASS'); return 1 if fails else 0
if __name__ == '__main__': sys.exit(main(sys.argv[1:]))
