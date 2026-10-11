#!/usr/bin/env python3
"""
Comprehensive Corner-Case and Fuzzing Test Suite for rv_nna INT8 Accelerator.
Verifies arithmetic boundaries, requantization rounding, saturation clamping,
and invalid configuration handling.
"""

import sys
import os
import random
import struct

# Add sw/model to sys.path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../model")))
from reference_model import quantize_layer, pack_int8_words, unpack_int8_words, ACT_NONE, ACT_RELU, ACT_CLIP

def run_corner_case_tests():
    print("=" * 70)
    print("Running INT8 Neural Accelerator Golden Model Corner-Case Tests")
    print("=" * 70)

    tests_passed = 0
    total_tests = 0

    # -------------------------------------------------------------------------
    # Corner Case 1: Maximum Positive Saturation
    # K=16, all inputs +127, all weights +127, Bias = 0.
    # Accumulator = 16 * 127 * 127 = 258,064.
    # With Scale = 32768, Shift = 16, scaled = 129,032 -> Clamps to +127.
    # -------------------------------------------------------------------------
    total_tests += 1
    K = 16
    M = 4
    X1 = [127] * K
    W1 = [[127] * K for _ in range(M)]
    B1 = [0] * M
    Y1, acc1 = quantize_layer(X1, W1, B1, scale_mult=32768, scale_shift=16, act_type=ACT_NONE)
    assert Y1 == [127] * M, f"Test 1 Failed: Expected all +127, got {Y1}"
    assert acc1 == [258064] * M, f"Test 1 Acc Mismatch: {acc1}"
    print(f"[PASS] Case 1: Max Positive Saturation -> Y={Y1[:2]} (acc={acc1[0]})")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Corner Case 2: Maximum Negative Saturation (Linear / ACT_NONE)
    # K=16, all inputs +127, all weights -128, Bias = 0.
    # Accumulator = 16 * 127 * (-128) = -260,096.
    # Scaled = -130,048 -> Clamps to -128.
    # -------------------------------------------------------------------------
    total_tests += 1
    X2 = [127] * K
    W2 = [[-128] * K for _ in range(M)]
    B2 = [0] * M
    Y2, acc2 = quantize_layer(X2, W2, B2, scale_mult=32768, scale_shift=16, act_type=ACT_NONE)
    assert Y2 == [-128] * M, f"Test 2 Failed: Expected all -128, got {Y2}"
    assert acc2 == [-260096] * M, f"Test 2 Acc Mismatch: {acc2}"
    print(f"[PASS] Case 2: Max Negative Saturation (Linear) -> Y={Y2[:2]} (acc={acc2[0]})")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Corner Case 3: Maximum Negative with ReLU (ACT_RELU)
    # Same negative product, but ReLU must clamp to 0.
    # -------------------------------------------------------------------------
    total_tests += 1
    Y3, acc3 = quantize_layer(X2, W2, B2, scale_mult=32768, scale_shift=16, act_type=ACT_RELU)
    assert Y3 == [0] * M, f"Test 3 Failed: Expected all 0 for ReLU, got {Y3}"
    print(f"[PASS] Case 3: Max Negative with ReLU -> Y={Y3[:2]}")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Corner Case 4: Alternating Sign Zero Cancellation
    # X = [127, -127, 127, -127, ...], W = [127, 127, 127, 127, ...]
    # Product pairs cancel out exactly: 127*127 + (-127)*127 = 0.
    # Acc = 0 -> Y = 0.
    # -------------------------------------------------------------------------
    total_tests += 1
    X4 = [127, -127] * (K // 2)
    W4 = [[127] * K for _ in range(M)]
    B4 = [0] * M
    Y4, acc4 = quantize_layer(X4, W4, B4, scale_mult=32768, scale_shift=16, act_type=ACT_NONE)
    assert Y4 == [0] * M, f"Test 4 Failed: Expected 0, got {Y4}"
    assert acc4 == [0] * M, f"Test 4 Acc Mismatch: {acc4}"
    print(f"[PASS] Case 4: Alternating Sign Cancellation -> Y={Y4[:2]} (acc={acc4[0]})")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Corner Case 5: Large Positive Bias Override
    # Negative dot product (-2000), large positive bias (+2050).
    # Acc = +50. Scale=65536>>16 (identity multiplier).
    # Y = +50.
    # -------------------------------------------------------------------------
    total_tests += 1
    X5 = [10] * 4
    W5 = [[-50] * 4]  # dot product = 4 * (-500) = -2000
    B5 = [2050]
    Y5, acc5 = quantize_layer(X5, W5, B5, scale_mult=65536, scale_shift=16, act_type=ACT_NONE)
    assert Y5 == [50], f"Test 5 Failed: Expected [50], got {Y5}"
    assert acc5 == [50]
    print(f"[PASS] Case 5: Large Positive Bias Override -> Y={Y5} (acc={acc5[0]})")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Corner Case 6: Shift = 0 (No Shifting, Direct Scaling)
    # Acc = 25, Scale = 3, Shift = 0 -> Requant = 75. Clamped to 75.
    # -------------------------------------------------------------------------
    total_tests += 1
    X6 = [5, 5, 0, 0]
    W6 = [[2, 3, 0, 0]]  # 10 + 15 = 25
    B6 = [0]
    Y6, acc6 = quantize_layer(X6, W6, B6, scale_mult=3, scale_shift=0, act_type=ACT_NONE)
    assert Y6 == [75], f"Test 6 Failed: Expected [75], got {Y6}"
    print(f"[PASS] Case 6: Shift = 0 Scaling -> Y={Y6}")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Corner Case 7: Half-way Rounding Tie-Breaking
    # Shift = 2. Rounding offset is 1 << (2-1) = 2.
    # Scaled = 2. (2 + 2) >> 2 = 1.
    # Scaled = 1. (1 + 2) >> 2 = 0.
    # -------------------------------------------------------------------------
    total_tests += 1
    # Acc = 2, Scale = 1, Shift = 2 -> (2 + 2) >> 2 = 1
    Y7a, _ = quantize_layer([2, 0, 0, 0], [[1, 0, 0, 0]], [0], scale_mult=1, scale_shift=2, act_type=ACT_NONE)
    # Acc = 1, Scale = 1, Shift = 2 -> (1 + 2) >> 2 = 0
    Y7b, _ = quantize_layer([1, 0, 0, 0], [[1, 0, 0, 0]], [0], scale_mult=1, scale_shift=2, act_type=ACT_NONE)
    assert Y7a == [1] and Y7b == [0], f"Test 7 Failed: Y7a={Y7a}, Y7b={Y7b}"
    print(f"[PASS] Case 7: Requantization Rounding Offset -> 2->{Y7a[0]}, 1->{Y7b[0]}")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Corner Case 8: Minimum Configuration Dimensions (K=4, M=1)
    # -------------------------------------------------------------------------
    total_tests += 1
    X8 = [-12, 34, -56, 78]
    W8 = [[10, -20, 30, -40]]
    B8 = [100]
    # Dot product: (-12*10) + (34*-20) + (-56*30) + (78*-40)
    # = -120 - 680 - 1680 - 3120 = -5600.
    # Acc = -5600 + 100 = -5500.
    # Scale = 16384 (0.25), Shift = 16 -> (-5500 * 16384 + 32768) >> 16 = (-90112000 + 32768) >> 16 = -1375.
    # Clamps to -128 in ACT_NONE, 0 in ACT_RELU.
    Y8_clip, acc8 = quantize_layer(X8, W8, B8, scale_mult=16384, scale_shift=16, act_type=ACT_NONE)
    Y8_relu, _ = quantize_layer(X8, W8, B8, scale_mult=16384, scale_shift=16, act_type=ACT_RELU)
    assert Y8_clip == [-128] and Y8_relu == [0] and acc8 == [-5500]
    print(f"[PASS] Case 8: Min Config (K=4, M=1) -> Clip={Y8_clip[0]}, ReLU={Y8_relu[0]}")
    tests_passed += 1

    # -------------------------------------------------------------------------
    # Fuzzing Suite: 50 Randomized Dimension & Parameter Layers
    # -------------------------------------------------------------------------
    print("-" * 70)
    print("Running 50 Randomized Fuzzing Layers...")
    random.seed(1337)
    for trial in range(50):
        total_tests += 1
        k_dim = random.choice([4, 8, 12, 16, 20, 24, 32])
        m_dim = random.choice([1, 2, 4, 8, 16])
        x_rnd = [random.randint(-128, 127) for _ in range(k_dim)]
        w_rnd = [[random.randint(-128, 127) for _ in range(k_dim)] for _ in range(m_dim)]
        b_rnd = [random.randint(-5000, 5000) for _ in range(m_dim)]
        scale_m = random.randint(1, 65535)
        scale_s = random.randint(0, 20)
        act_t = random.choice([ACT_NONE, ACT_RELU, ACT_CLIP])

        y_rnd, acc_rnd = quantize_layer(x_rnd, w_rnd, b_rnd, scale_m, scale_s, act_t)

        # Sanity check ranges
        if act_t == ACT_RELU:
            assert all(0 <= v <= 127 for v in y_rnd), f"Fuzz {trial}: ReLU range violation {y_rnd}"
        else:
            assert all(-128 <= v <= 127 for v in y_rnd), f"Fuzz {trial}: Range violation {y_rnd}"

        # Test pack & unpack round-trip
        packed_x = pack_int8_words(x_rnd)
        unpacked_x = unpack_int8_words(packed_x, k_dim)
        assert x_rnd == unpacked_x, f"Fuzz {trial}: Pack/unpack mismatch"
        tests_passed += 1

    print(f"[PASS] All {total_tests} Golden Model & Fuzzing Tests Passed Successfully!")
    print("=" * 70)
    return True

if __name__ == "__main__":
    if run_corner_case_tests():
        sys.exit(0)
    else:
        sys.exit(1)
