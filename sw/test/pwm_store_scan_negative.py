#!/usr/bin/env python3
"""Negative controls for pwm_store_scan.py (C4). Each control mutates one word
of a copy of the real ROM hex and requires the scan to FAIL (rc=1) with the
expected diagnostic. Mutation sites are found from the scan itself (not
hard-coded addresses), so they follow firmware changes. A control that passes
means the scanner is blind to that class of error.
Controls per image (robot_nav, soc_cosim, firmware): NC1 removed store, NC2
retargeted offset, NC3 changed value source, NC4 unresolved base, NC5 indirect
jump (robot_nav, soc_cosim; firmware.hex has no ret), NC6 ecall, NC10 sb / sh /
unaligned sw into the PWM window. Global: NC7 tracking bound forced to 64 on
conv_test (512-trip loop -> widened pointer -> UNRESOLVED), NC8 store through
an unknown sp (no sp exemption), NC9 state cap lowered -> incomplete scan.
NC7/NC9 use the PWM_SCAN_WIDEN_AFTER / PWM_SCAN_MAX_STATES test hooks.
Exit 0 = all controls detected, 1 = a control was missed, 2 = setup error.
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pwm_store_scan as P  # noqa: E402

SCAN = os.path.join(HERE, 'pwm_store_scan.py')
NOP = 0x00000013


def enc_s(f3, rs1, rs2, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | 0x23


def enc_i(op, f3, rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def run(name, words, image, expect, env=None):
    with tempfile.NamedTemporaryFile('w', suffix='.hex', delete=False) as f:
        f.write(''.join(f'{w:08x}\n' for w in words))
        path = f.name
    try:
        r = subprocess.run([sys.executable, SCAN, '--image', image],
                           env=dict(os.environ, PWM_SCAN_HEX=path, **(env or {})),
                           capture_output=True, text=True)
    finally:
        os.unlink(path)
    ok = r.returncode == 1 and expect in r.stdout
    print(f'  {"DETECTED" if ok else "MISSED  "} {image}:{name} (rc={r.returncode}, want "{expect}")')
    if not ok:
        print('    ' + r.stdout.strip().replace('\n', '\n    '))
    return ok


def main():
    allok = True
    n = 0
    for image in ('robot_nav', 'soc_cosim', 'firmware'):
        hexf = os.path.join(P.FW, P.IMAGES[image][0])
        if not os.path.exists(hexf):
            print(f'{hexf} missing: run make -C sim firmware'); sys.exit(2)
        words = P.load_words(hexf)
        stores, bad, _ = P.scan(words)
        if bad:
            print(f'baseline scan of {image} not clean: {bad}'); sys.exit(2)
        pwm = sorted(pc for pc, s in stores.items()
                     if P.U not in s[4] and all(P.PWM_LO <= a <= P.PWM_HI for a in s[4]))
        other = sorted(pc for pc, s in stores.items()
                       if P.U not in s[4] and not any(P.PWM_LO <= a <= P.PWM_HI for a in s[4])
                       and s[1] != 'sp')
        last = pwm[-1]
        d = P.decode(words[last // 4])
        # NC1: remove an allowlisted PWM store -> missing site
        w = list(words); w[last // 4] = NOP
        allok &= run('remove_last_pwm_store', w, image, 'allowlisted PWM store missing')
        # NC2: same store, new PWM register offset (+0x10) -> extra site
        w = list(words); w[last // 4] = enc_s(d['f3'], d['rs1'], d['rs2'], d['s'] + 0x10)
        allok &= run('retarget_pwm_offset', w, image, 'PWM store NOT in allowlist')
        # NC3: a non-PWM store (e.g. UART) redirected to the PWM base register
        #      by giving it the same base register/offset as a PWM store,
        #      but placed where that base holds the PWM address is hard to
        #      guarantee; instead rewrite a PWM store's source register.
        w = list(words); src = 7 if d['rs2'] != 7 else 6  # t2 / t1
        w[last // 4] = enc_s(d['f3'], d['rs1'], src, d['s'])
        allok &= run('change_pwm_value_source', w, image, 'PWM store NOT in allowlist')
        # NC4: base register of a non-PWM, non-stack store comes from a load
        #      -> address unknown -> UNRESOLVED
        o = other[0]; od = P.decode(words[o // 4])
        w = list(words)
        w[o // 4 - 1] = enc_i(0x03, 2, od['rs1'], 2, 0)  # lw base, 0(sp)
        allok &= run('unresolved_store_base', w, image, 'UNRESOLVED store base')
        # NC5: replace a ret with an indirect jump through t1 -> unverifiable
        rets = [i for i, x in enumerate(words) if x == 0x00008067]
        if rets:
            w = list(words); w[rets[0]] = enc_i(0x67, 0, 0, 6, 0)  # jalr x0,0(t1)
            allok &= run('indirect_jump', w, image, 'unverifiable jalr')
            n += 1
        # NC6: ecall in reachable code -> SYSTEM rejected
        w = list(words); w[pwm[0] // 4] = 0x00000073
        allok &= run('ecall_inserted', w, image, 'SYSTEM instruction')
        n += 5
        # NC10: PWM store narrowed to sb / sh, and an unaligned sw into the
        #       window -> rejected (firmware-image rule; HW does not block it)
        for f3, tag in ((0, 'sb'), (1, 'sh')):
            w = list(words); w[last // 4] = enc_s(f3, d['rs1'], d['rs2'], d['s'])
            allok &= run(f'pwm_store_as_{tag}', w, image, 'narrow/unaligned PWM store')
            n += 1
        w = list(words); w[last // 4] = enc_s(2, d['rs1'], d['rs2'], d['s'] + 2)
        allok &= run('pwm_sw_unaligned', w, image, 'narrow/unaligned PWM store')
        n += 1

    rn = P.load_words(os.path.join(P.FW, 'robot_nav.hex'))
    st, _, _ = P.scan(rn)
    # NC7: tracking bound. conv_test runs a 512-trip loop; forcing the bound
    #      back to 64 widens its RAM pointer -> UNRESOLVED store, fail closed
    allok &= run('tracking_bound_exceeded', P.load_words(os.path.join(P.FW, 'conv_test.hex')),
                 'conv_test', 'UNRESOLVED store base', {'PWM_SCAN_WIDEN_AFTER': '64'})
    # NC8: no sp exemption. A store rebased onto sp after sp is reloaded from
    #      memory (unknown) must be UNRESOLVED and fail (was exempt before).
    o = sorted(pc for pc, s_ in st.items() if P.U not in s_[4]
               and not any(P.PWM_LO <= a <= P.PWM_HI for a in s_[4]))[0]
    od = P.decode(rn[o // 4])
    w = list(rn)
    w[o // 4 - 1] = enc_i(0x03, 2, 2, 2, 0)          # lw sp, 0(sp)
    w[o // 4] = enc_s(od['f3'], 2, od['rs2'], od['s'])  # store via sp
    allok &= run('unknown_sp_store', w, 'robot_nav', 'UNRESOLVED store base')
    # NC9: state cap. Lowering MAX_STATES must give an incomplete-scan FAIL,
    #      never a silent pass.
    allok &= run('state_cap_exceeded', rn, 'robot_nav', 'state explosion',
                 {'PWM_SCAN_MAX_STATES': '1000'})
    n += 3
    print(f'[PWM-SCAN-NC {"PASS" if allok else "FAIL"}] {n} controls')
    sys.exit(0 if allok else 1)


if __name__ == '__main__':
    main()
