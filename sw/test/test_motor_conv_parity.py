#!/usr/bin/env python3
"""V-CONV parity (M11b M2 step 3a): firmware motor_cmd_conv (run on the SoC sim,
dumped by sim/tb_motor_conv.v) == Python motor_cmd, exhaustively over all 512
v_wheel values -256..255. Also checks, in Python only, all 65,536 (v_safe, w_raw)
pairs in -128..127 map into the tested domain and the contract examples.

--perturb : negative control. Uses a 1-LSB perturbed reference; must FAIL.
Exit 0 = PASS, 1 = FAIL. Simulation only.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from motor_cmd_ref import motor_cmd, pwm_high_cycles  # noqa: E402


def main():
    args = sys.argv[1:]
    perturb = "--perturb" in args
    args = [a for a in args if a != "--perturb"]
    if len(args) != 1:
        print("usage: test_motor_conv_parity.py [--perturb] DUMP_FILE")
        return 2
    ref = motor_cmd
    if perturb:
        # 1-LSB error at a single input (v = +1 -> 8 instead of 7)
        ref = lambda v: motor_cmd(v) + (1 if v == 1 else 0)  # noqa: E731
    fw = {}
    with open(args[0]) as f:
        for line in f:
            v, c = line.split()
            fw[int(v)] = int(c)
    errors = []
    if sorted(fw) != list(range(-256, 256)):
        errors.append("dump does not contain exactly v=-256..255 (%d entries)" % len(fw))
    mism = [(v, fw[v], ref(v)) for v in range(-256, 256) if v in fw and fw[v] != ref(v)]
    for v, a, b in mism[:10]:
        errors.append("mismatch v=%d firmware=%d python=%d" % (v, a, b))
    # contract examples (v2 sec. 9)
    ex = {0: 0, 1: 7, -1: -7, 127: 992, -127: -992, -128: -1000, 128: 1000, 254: 1000, -256: -1000}
    for v, c in ex.items():
        if motor_cmd(v) != c:
            errors.append("contract example v=%d expected %d got %d" % (v, c, motor_cmd(v)))
    # reachable pair domain (Python only)
    pairs = 0
    for vs in range(-128, 128):
        for w in range(-128, 128):
            for vw in (vs - w, vs + w):
                if not -256 <= vw <= 255 or not -1000 <= motor_cmd(vw) <= 1000:
                    errors.append("pair out of domain vs=%d w=%d" % (vs, w))
            pairs += 1
    distinct = len({fw[v] for v in fw})
    # PWM high-cycle mirror sanity
    for p in (1000, 1250):
        assert pwm_high_cycles(0, p) == 0 and pwm_high_cycles(1000, p) == p
        assert pwm_high_cycles(-1000, p) == p
    print("[V-CONV] firmware values=%d mismatches=%d distinct=%d pairs_checked=%d perturbed_ref=%s"
          % (len(fw), len(mism), distinct, pairs, perturb))
    if errors:
        for e in errors[:20]:
            print("FAIL:", e)
        print("[V-CONV-FAIL]")
        return 1
    print("[V-CONV-PASS] 512/512 firmware == Python")
    return 0


if __name__ == "__main__":
    sys.exit(main())
