#!/usr/bin/env python3
"""Generate sim/test_vectors_rl_seed1.json (25 vectors) for the RL seed-1 NNA test.
Inputs: the 25 INT8 observation vectors of the IL test (sim/test_vectors_trained.json, x_int8).
Expected outputs: computed with the independent integer oracle (sim/verify_independent_vectors.py)
using the weights PARSED FROM sw/firmware/nav_weights.inc, after asserting they equal
sw/policy/rl_seed1_policy.json. Fully deterministic; no randomness."""
import json, os, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT + "/sw/test"); sys.path.insert(0, ROOT + "/sw/model"); sys.path.insert(0, ROOT + "/sim")
import test_rl_export as t
import reference_model as rm
from verify_independent_vectors import independent_gemv_requant as oracle

def main():
    ref = json.load(open(ROOT + "/sw/policy/rl_seed1_policy.json"))
    consts, blocks = t.parse_inc(open(ROOT + "/sw/firmware/nav_weights.inc").read())
    fw = [t.fw_layer(consts, blocks, 1), t.fw_layer(consts, blocks, 2)]
    errs = t.compare(fw, [ref["l1"], ref["l2"]])
    assert not errs, "nav_weights.inc != rl_seed1_policy.json: %s" % errs[:3]
    assert (fw[0]["act"], fw[1]["act"]) == (1, 2), "TB hardcodes L1=ReLU, L2=Clip"
    names = {1: "relu", 2: "clip"}
    il = json.load(open(ROOT + "/sim/test_vectors_trained.json"))
    out = []
    for i, v in enumerate(il):
        x = v["x_int8"]
        h = oracle(x, fw[0]["weights"], fw[0]["biases"], fw[0]["scale_mult"], fw[0]["scale_shift"], names[fw[0]["act"]])
        y = oracle(h, fw[1]["weights"], fw[1]["biases"], fw[1]["scale_mult"], fw[1]["scale_shift"], names[fw[1]["act"]])
        assert y == t.run(fw, x)  # second implementation (reference_model) agrees
        out.append({"sample_index": i, "x_int8": x, "h1_int8": h, "y_int8": y,
                    "x_words_raw": rm.pack_int8_words(list(x)),
                    "h1_words_raw": rm.pack_int8_words(list(h)),
                    "y_words_raw": rm.pack_int8_words(list(y))})
    json.dump(out, open(ROOT + "/sim/test_vectors_rl_seed1.json", "w"), indent=1)
    print("wrote %d vectors" % len(out))
main()
