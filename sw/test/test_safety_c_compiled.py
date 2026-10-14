#!/usr/bin/env python3
"""Compiles sw/firmware/safety_driver.h with the host C compiler and compares
safety_filter_command() with the integer mirror (the Python integer mirror) on random
stateless vectors. SKIPs (exit 0, loud message) if no C compiler is found."""
import os, random, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(__file__))
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
import test_safety_c_mirror as m
def main():
    cc = shutil.which("gcc") or shutil.which("cc")
    if not cc:
        print("SKIP: no C compiler; compiled-C check NOT run"); return 0
    exe = os.path.join(tempfile.mkdtemp(), "h")
    subprocess.check_call([cc, "-std=c99", "-Wall", "-Werror", "-I", ROOT + "/sw/firmware",
        ROOT + "/sw/test/safety_driver_harness.c", "-o", exe])
    random.seed(7); vec = []
    for _ in range(20000):
        vec.append((random.randint(-64, 64), random.randint(-64, 64), random.randint(-128, 127),
                    random.randint(-128, 127), random.randint(-50, 300)))
    inp = "\n".join(" ".join(map(str, v)) for v in vec) + "\n"
    out = subprocess.run([exe], input=inp, capture_output=True, text=True, check=True).stdout.split("\n")
    bad = 0
    for v, line in zip(vec, out):
        exp = m.f((v[0], v[1]), v[2], v[3], v[4])
        if tuple(map(int, line.split())) != exp: bad += 1
    if bad: print("FAIL: %d mismatches C vs mirror" % bad); return 1
    print("compiled C safety driver matches integer mirror on %d vectors" % len(vec)); return 0
if __name__ == "__main__": sys.exit(main())
