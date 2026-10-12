#!/usr/bin/env python3
"""
sim/verify_independent_vectors.py
Independent verification of the 25 RTL test vectors against pure-integer reference model.
"""

import json
import os
import sys

# Add repository root to path
sim_dir = os.path.dirname(os.path.abspath(__file__))
root_dir = os.path.abspath(os.path.join(sim_dir, ".."))
sys.path.append(root_dir)

from sw.model.reference_model import quantize_layer, ACT_RELU, ACT_CLIP

def verify_vectors():
    weights_path = os.path.join(root_dir, "sw", "policy", "trained_policy_weights.json")
    vec_path = os.path.join(sim_dir, "test_vectors_trained.json")

    if not os.path.exists(weights_path):
        print(f"Error: {weights_path} not found")
        sys.exit(1)
    if not os.path.exists(vec_path):
        print(f"Error: {vec_path} not found")
        sys.exit(1)

    with open(weights_path) as f:
        wdata = json.load(f)
    with open(vec_path) as f:
        vectors = json.load(f)

    w1 = wdata["l1"]["weights"]
    b1 = wdata["l1"]["biases"]
    w2 = wdata["l2"]["weights"]
    b2 = wdata["l2"]["biases"]
    l1_mult = wdata["l1"]["scale_mult"]
    l1_shift = wdata["l1"]["scale_shift"]
    l2_mult = wdata["l2"]["scale_mult"]
    l2_shift = wdata["l2"]["scale_shift"]

    print("=" * 80)
    print(f"Independent Verification of {len(vectors)} Trained Policy Vectors")
    print(f"Layer 1 (16->8, ReLU): Mult={l1_mult}, Shift={l1_shift}")
    print(f"Layer 2 ( 8->2, Clip): Mult={l2_mult}, Shift={l2_shift}")
    print("=" * 80)

    all_passed = True
    for v in vectors:
        idx = v["sample_index"]
        x = v["x_int8"]
        golden_h1 = v["h1_int8"]
        golden_y = v["y_int8"]

        # Forward pass using reference integer model
        calc_h1, _ = quantize_layer(x, w1, b1, l1_mult, l1_shift, ACT_RELU)
        calc_y, _ = quantize_layer(calc_h1, w2, b2, l2_mult, l2_shift, ACT_CLIP)

        err_h1 = max(abs(c - g) for c, g in zip(calc_h1, golden_h1))
        err_y = max(abs(c - g) for c, g in zip(calc_y, golden_y))

        if err_h1 > 0 or err_y > 0:
            print(f"[FAIL] Vector {idx}: err_h1={err_h1}, err_y={err_y}")
            all_passed = False
        else:
            print(f"[PASS] Vector {idx:4d}: H1 exact match, Action [v={calc_y[0]:4d}, w={calc_y[1]:4d}] exact match (0 LSB error)")

    print("-" * 80)
    if all_passed:
        print(f"SUCCESS: All {len(vectors)} vectors verified bit-exact with 0 LSB error.")
        return 0
    else:
        print("FAILED: Vector discrepancy detected.")
        return 1

if __name__ == "__main__":
    sys.exit(verify_vectors())
