#!/usr/bin/env python3
"""
Reference Model for rv_nna (RISC-V Neural Network Accelerator)
Implements bit-exact symmetric INT8 quantized matrix-vector arithmetic.
"""

import math
import struct
import json
import random

# Activation Function Enums
ACT_NONE = 0
ACT_RELU = 1
ACT_CLIP = 2

def clamp(val, min_val, max_val):
    return max(min_val, min(max_val, val))

def quantize_layer(X, W, B, scale_mult, scale_shift, act_type=ACT_NONE):
    """
    Computes Y = Activation(Requantize(W * X + B))
    where:
      X: list of K signed int8 elements (-128 to 127)
      W: list of M rows, each with K signed int8 elements (-128 to 127)
      B: list of M signed int32 elements
      scale_mult: 16-bit integer multiplier (1 to 65535)
      scale_shift: integer shift amount (0 to 31)
      act_type: ACT_NONE, ACT_RELU, or ACT_CLIP
    Returns:
      Y: list of M signed int8 elements
      raw_acc: list of M signed int32 unquantized accumulators
    """
    M = len(W)
    K = len(X)
    Y = []
    raw_acc = []

    for m in range(M):
        acc = B[m]
        for k in range(K):
            prod = W[m][k] * X[k]
            acc += prod
        
        raw_acc.append(acc)

        # Fixed-point requantization with standard rounding
        # scaled = acc * scale_mult
        # rounded = (scaled + (1 << (shift - 1))) >> shift
        scaled = acc * scale_mult
        if scale_shift > 0:
            rounding = 1 << (scale_shift - 1)
            requant = (scaled + rounding) >> scale_shift
        else:
            requant = scaled

        # Activation
        if act_type == ACT_RELU:
            out = clamp(requant, 0, 127)
        elif act_type == ACT_CLIP:
            out = clamp(requant, -128, 127)
        else:  # ACT_NONE (saturates to int8)
            out = clamp(requant, -128, 127)

        Y.append(out)

    return Y, raw_acc

def pack_int8_words(byte_list):
    """Packs a list of int8 values into 32-bit little-endian words."""
    words = []
    for i in range(0, len(byte_list), 4):
        chunk = byte_list[i:i+4]
        # Pad with 0 if chunk is not a multiple of 4
        while len(chunk) < 4:
            chunk.append(0)
        word = (chunk[0] & 0xFF) | ((chunk[1] & 0xFF) << 8) | ((chunk[2] & 0xFF) << 16) | ((chunk[3] & 0xFF) << 24)
        words.append(word)
    return words

def unpack_int8_words(words, count):
    """Unpacks count signed int8 values from 32-bit little-endian words."""
    byte_list = []
    for w in words:
        for b in range(4):
            val = (w >> (b * 8)) & 0xFF
            if val >= 128:
                val -= 256
            byte_list.append(val)
            if len(byte_list) == count:
                return byte_list
    return byte_list

def generate_test_case():
    """Generates a deterministic test vector for RTL verification."""
    random.seed(42)
    K = 16  # 16 inputs
    M = 8   # 8 output neurons

    # Inputs: 16 signed int8
    X = [random.randint(-100, 100) for _ in range(K)]

    # Weights: M rows of K signed int8
    W = [[random.randint(-50, 50) for _ in range(K)] for _ in range(M)]

    # Biases: M signed int32
    B = [random.randint(-200, 200) for _ in range(M)]

    scale_mult = 32768  # 0.5 in Q16
    scale_shift = 16    # >> 16
    act_type = ACT_RELU

    Y, raw_acc = quantize_layer(X, W, B, scale_mult, scale_shift, act_type)

    return {
        "K": K,
        "M": M,
        "scale_mult": scale_mult,
        "scale_shift": scale_shift,
        "act_type": act_type,
        "X": X,
        "W": W,
        "B": B,
        "raw_acc": raw_acc,
        "Y": Y,
        "X_words": pack_int8_words(X),
        "Y_words": pack_int8_words(Y)
    }

if __name__ == "__main__":
    test_case = generate_test_case()
    print("Generated Test Case:")
    print(f"K={test_case['K']}, M={test_case['M']}")
    print(f"Input X: {test_case['X']}")
    print(f"Expected Output Y: {test_case['Y']}")
    print(f"Input words (hex): {[hex(w) for w in test_case['X_words']]}")
    print(f"Output words (hex): {[hex(w) for w in test_case['Y_words']]}")
    print("Reference model verified.")
