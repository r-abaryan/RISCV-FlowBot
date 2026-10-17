#!/usr/bin/env python3
"""M10c: C header vs integer mirror on a deterministic grid + independent nonnegative-v properties.
Host-only (no SoC). Does NOT cover wheel-level reverse, stale sensors, or the assembly (see SoC tests)."""
import itertools, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(__file__))
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
import test_safety_c_mirror as m
def main():
    cc = shutil.which("gcc") or shutil.which("cc")
    if not cc: print("FAIL: no C compiler"); return 1
    exe = os.path.join(tempfile.mkdtemp(), "h")
    subprocess.check_call([cc, "-std=c99", "-Wall", "-Werror", "-I", ROOT + "/sw/firmware",
                           ROOT + "/sw/test/safety_driver_harness.c", "-o", exe])
    LV = [-64, -57, -9, -8, -1, 0, 1, 7, 8, 9, 31, 56, 57, 63, 64]
    LW = [-64, -9, 0, 9, 64]
    RV = [-128, -127, -65, -64, -63, -9, -8, -1, 0, 1, 8, 9, 31, 63, 64, 65, 127]
    RW = [-128, -64, -1, 0, 1, 64, 127]
    D = [-50, -1, 0, 1, 24, 25, 26, 27, 30, 33, 40, 64, 100, 127, 128, 255, 300]
    vec = list(itertools.product(LV, LW, RV, RW, D))
    inp = "\n".join(" ".join(map(str, v)) for v in vec) + "\n"
    out = subprocess.run([exe], input=inp, capture_output=True, text=True, check=True).stdout.strip().split("\n")
    assert len(out) == len(vec)
    bad = neg = 0
    for v, line in zip(vec, out):
        c = tuple(map(int, line.split()))
        if c != m.f((v[0], v[1]), v[2], v[3], v[4]): bad += 1
        if c[0] < 0: neg += 1            # property 1 (independent of mirror): C output v >= 0
        if m.f((v[0], v[1]), v[2], v[3], v[4])[0] < 0: neg += 1
    # boundary/state-sequence assertions (mirror); property: v>=0 and slew from CLAMPED state
    assert m.f((0, 0), -64, 0, 300)[0] == 0
    assert m.f((0, 0), -1, 0, 300)[0] == 0
    st = (0, 0); seq = []
    for rv in (-64, 64, 64, -64, 64):
        st = m.f(st, rv, 0, 300); seq.append(st[0])
    assert seq == [0, 8, 16, 8, 16], seq
    assert m.f((0, 0), 64, 0, 33)[0] == 5 and m.f((0, 0), 64, 0, 25)[0] == 0
    sys.path.insert(0, ROOT + "/sw/safety")
    import random, safety_layer as sl
    pf = sl.DeterministicSafetyFilter(); random.seed(1); pyneg = 0
    for _ in range(20000):
        r = pf.filter_action(random.uniform(-2, 2), random.uniform(-3, 3), random.uniform(0, 3))
        pyneg += (r[0] < 0 or pf.v_prev < 0)
    neg += pyneg
    print(f"python_filter_negative={pyneg}")
    print(f"grid cases={len(vec)} c_vs_mirror_mismatches={bad} negative_v_outputs={neg} seq={seq}")
    return 1 if (bad or neg) else 0
if __name__ == "__main__": sys.exit(main())
