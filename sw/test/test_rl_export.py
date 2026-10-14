#!/usr/bin/env python3
"""Verify the weights ACTUALLY in the firmware (sw/firmware/nav_weights.inc, parsed
independently here, not via export_weights.py) equal the RL seed-1 JSON, and that the
independent integer reference model gives identical outputs for both. Also runs a
self-test: a deliberately perturbed firmware weight set MUST be detected."""
import json, os, random, re, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT + "/sw/model")
import reference_model as rm

def s8(b): return b - 256 if b > 127 else b
def s32(w): return w - (1 << 32) if w & 0x80000000 else w

def parse_inc(text):
    consts = {k: int(v) for k, v in re.findall(r"\.equ\s+(\w+),\s*(-?\d+)", text)}
    blocks, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^(l[12]_(?:weights|biases)):", line)
        if m: cur = m.group(1); blocks[cur] = []; continue
        m = re.match(r"\s*\.word\s+(0x[0-9a-fA-F]+)", line)
        if m and cur: blocks[cur].append(int(m.group(1), 16))
    return consts, blocks

def fw_layer(consts, blocks, n):
    K, M = consts["L%d_K_DIM" % n], consts["L%d_M_DIM" % n]
    by = []
    for w in blocks["l%d_weights" % n]:
        by += [s8((w >> (8 * i)) & 0xFF) for i in range(4)]
    assert len(by) >= K * M, "weight block too short"
    W = [by[r * K:(r + 1) * K] for r in range(M)]
    B = [s32(w) for w in blocks["l%d_biases" % n]][:M]
    return dict(weights=W, biases=B, scale_mult=consts["L%d_SCALE_MULT_VAL" % n],
                scale_shift=consts["L%d_SCALE_SHIFT_VAL" % n], act=consts["L%d_ACT_VAL" % n])

def run(layers, x):
    for L in layers:
        x, _ = rm.quantize_layer(x, L["weights"], L["biases"], L["scale_mult"], L["scale_shift"], L["act"])
    return x

def compare(fw, ref):
    errs = []
    for n in (0, 1):
        for key in ("weights", "biases", "scale_mult", "scale_shift", "act"):
            if fw[n][key] != ref[n][key]: errs.append("layer%d %s differs" % (n + 1, key))
    random.seed(11)
    for _ in range(500):
        x = [random.randint(-128, 127) for _ in range(16)]
        if run(fw, x) != run(ref, x): errs.append("output mismatch for %s" % x); break
    return errs

def main():
    ref_json = json.load(open(ROOT + "/sw/policy/rl_seed1_policy.json"))
    ref = [ref_json["l1"], ref_json["l2"]]
    consts, blocks = parse_inc(open(ROOT + "/sw/firmware/nav_weights.inc").read())
    fw = [fw_layer(consts, blocks, 1), fw_layer(consts, blocks, 2)]
    errs = compare(fw, ref)
    if errs: print("FAIL: firmware != RL seed 1 export:", errs[:5]); return 1
    print("PASS: firmware nav_weights.inc == rl_seed1_policy.json (weights, biases, scales, act; 500 random outputs)")
    # negative controls
    import copy
    for name, mut in (("weight", lambda f: f[0]["weights"][3].__setitem__(5, f[0]["weights"][3][5] ^ 1)),
                      ("bias", lambda f: f[1]["biases"].__setitem__(0, f[1]["biases"][0] + 1)),
                      ("scale", lambda f: f[0].__setitem__("scale_mult", f[0]["scale_mult"] + 1))):
        bad = copy.deepcopy(fw); mut(bad)
        if not compare(bad, ref):
            print("FAIL: mismatched %s NOT detected" % name); return 1
        print("PASS: deliberately mismatched %s detected" % name)
    return 0
if __name__ == "__main__": sys.exit(main())
