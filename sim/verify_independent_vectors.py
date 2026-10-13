#!/usr/bin/env python3
"""
sim/verify_independent_vectors.py
Independent verification of the 25 authentic RTL test vectors against a
genuinely independent integer arithmetic oracle (no imports from reference_model.py).

This script independently validates:
1. Layer 1 GEMV (16 inputs -> 8 hidden neurons) with bias, scaling, shift-rounding, and ReLU.
2. Layer 2 GEMV (8 hidden inputs -> 2 output neurons) with bias, scaling, shift-rounding, and Clip.
3. Bit-exact match (0 LSB error) against both expected hidden states (h1) and actions (y).
"""

import json
import os
import sys

def independent_gemv_requant(inputs, weights, biases, scale_mult, scale_shift, act_type):
    """
    Completely independent integer GEMV + requantization oracle.
    Directly models the mathematical integer behavior specified for rv_nna RTL:
      acc = bias + sum(w_i * in_i)
      scaled = acc * scale_mult
      rounded = scaled + (1 << (scale_shift - 1)) if scale_shift > 0 else 0
      shifted = rounded >> scale_shift
      activation: ReLU [0, 127] or Clip [-128, 127]
    """
    num_out = len(weights)
    num_in = len(inputs)
    results = []

    for m in range(num_out):
        acc = int(biases[m])
        for k in range(num_in):
            acc += int(weights[m][k]) * int(inputs[k])

        # Scaling with 16-bit multiplier
        scaled = acc * int(scale_mult)

        # Symmetrical rounding
        rounding = (1 << (scale_shift - 1)) if scale_shift > 0 else 0
        rounded = scaled + rounding
        shifted = rounded >> scale_shift

        # Activation clamping
        if act_type == "relu":
            val = max(0, min(127, shifted))
        elif act_type == "clip":
            val = max(-128, min(127, shifted))
        else:
            val = shifted

        results.append(int(val))

    return results

def verify_vectors():
    sim_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.abspath(os.path.join(sim_dir, ".."))
    weights_path = os.path.join(root_dir, "sw", "policy", "trained_policy_weights.json")
    vec_path = os.path.join(sim_dir, "test_vectors_trained.json")

    if not os.path.exists(weights_path):
        print(f"Error: {weights_path} not found")
        sys.exit(1)
    if not os.path.exists(vec_path):
        print(f"Error: {vec_path} not found")
        sys.exit(1)

    with open(weights_path, "r") as f:
        wdata = json.load(f)
    with open(vec_path, "r") as f:
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
    print(f"Independent Integer Oracle Verification ({len(vectors)} Authentic Vectors)")
    print("Standalone arithmetic: ZERO imports from sw/model/reference_model.py")
    print(f"Layer 1 (16->8, ReLU): Mult={l1_mult}, Shift={l1_shift}")
    print(f"Layer 2 ( 8->2, Clip): Mult={l2_mult}, Shift={l2_shift}")
    print("=" * 80)

    all_passed = True
    for v in vectors:
        idx = v["sample_index"]
        x = v["x_int8"]
        golden_h1 = v["h1_int8"]
        golden_y = v["y_int8"]

        # 1. Independent forward pass for Layer 1 (ReLU)
        calc_h1 = independent_gemv_requant(x, w1, b1, l1_mult, l1_shift, "relu")

        # 2. Independent forward pass for Layer 2 (Clip)
        calc_y = independent_gemv_requant(calc_h1, w2, b2, l2_mult, l2_shift, "clip")

        # Compare both layers
        err_h1 = max(abs(c - g) for c, g in zip(calc_h1, golden_h1))
        err_y = max(abs(c - g) for c, g in zip(calc_y, golden_y))

        if err_h1 > 0 or err_y > 0:
            print(f"[FAIL] Vector {idx}: err_h1={err_h1}, err_y={err_y}")
            all_passed = False
        else:
            print(f"[PASS] Vector {idx:4d}: Layer 1 H1 exact match, Layer 2 Action [v={calc_y[0]:4d}, w={calc_y[1]:4d}] exact match (0 LSB error)")

    print("-" * 80)
    if all_passed:
        print(f"SUCCESS: All {len(vectors)} vectors independently verified bit-exact (0 LSB error).")
        return 0
    else:
        print("FAILED: Discrepancy detected.")
        return 1

if __name__ == "__main__":
    sys.exit(verify_vectors())
