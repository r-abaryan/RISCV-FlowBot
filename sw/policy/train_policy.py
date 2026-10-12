"""
Pure NumPy Policy Training & Quantization Pipeline for RISC-V Neural SoC
Trains 2-Layer MLP (16 -> 8 -> 2) Navigation Policy using DAgger + Adam.
Performs symmetric INT8 quantization matching rv_nna accelerator arithmetic.
Zero PyTorch dependency, executes in < 40s on 1 vCPU (< 40MB RAM).
"""

import os
import sys
import time
import json
import math
import numpy as np

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../../sim')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../model')))
from robot_env import RobotEnv2D
from baselines import HeuristicPolicy
from reference_model import quantize_layer, ACT_RELU, ACT_CLIP

class MLP16x8x2:
    def __init__(self, seed=42):
        np.random.seed(seed)
        self.w1 = np.random.randn(8, 16).astype(np.float32) * np.sqrt(2.0 / 16.0)
        self.b1 = np.zeros(8, dtype=np.float32)
        self.w2 = np.random.randn(2, 8).astype(np.float32) * np.sqrt(2.0 / 8.0)
        self.b2 = np.zeros(2, dtype=np.float32)

    def forward_float(self, x):
        h = np.maximum(0.0, np.dot(self.w1, x) + self.b1)
        return np.clip(np.dot(self.w2, h) + self.b2, -1.0, 1.0)

def train_policy(n_initial_episodes=50, dagger_rounds=2, dagger_episodes=30):
    env = RobotEnv2D(max_steps=150)
    teacher = HeuristicPolicy()
    
    print(f"[Train] Collecting initial demonstrations from APF teacher ({n_initial_episodes} episodes)...")
    X_list, Y_list = [], []
    for s in range(n_initial_episodes):
        obs = env.reset(seed=s)
        for _ in range(150):
            act = teacher.act(obs)
            X_list.append(obs.copy())
            Y_list.append(act.copy())
            obs, r, done, info = env.step(act)
            if done:
                break
                
    policy = MLP16x8x2(seed=42)
    
    # Adam state
    mw1, vw1 = np.zeros_like(policy.w1), np.zeros_like(policy.w1)
    mb1, vb1 = np.zeros_like(policy.b1), np.zeros_like(policy.b1)
    mw2, vw2 = np.zeros_like(policy.w2), np.zeros_like(policy.w2)
    mb2, vb2 = np.zeros_like(policy.b2), np.zeros_like(policy.b2)
    t_step = 0

    def optimize_adam(epochs, lr):
        nonlocal t_step
        X = np.array(X_list, dtype=np.float32)
        Y = np.array(Y_list, dtype=np.float32)
        batch_size = 128
        n_batches = len(X) // batch_size
        
        for ep in range(epochs):
            perm = np.random.permutation(len(X))
            for b in range(n_batches):
                t_step += 1
                idx = perm[b*batch_size : (b+1)*batch_size]
                xb, yb = X[idx], Y[idx]
                
                # Forward
                z1 = np.dot(xb, policy.w1.T) + policy.b1
                h1 = np.maximum(0.0, z1)
                pred = np.dot(h1, policy.w2.T) + policy.b2
                
                # Backward
                dpred = 2.0 * (pred - yb) / batch_size
                dw2 = np.dot(dpred.T, h1)
                db2 = np.sum(dpred, axis=0)
                dh1 = np.dot(dpred, policy.w2)
                dz1 = dh1 * (z1 > 0)
                dw1 = np.dot(dz1.T, xb)
                db1 = np.sum(dz1, axis=0)
                
                for p, dp, m, v in [(policy.w1, dw1, mw1, vw1), (policy.b1, db1, mb1, vb1),
                                    (policy.w2, dw2, mw2, vw2), (policy.b2, db2, mb2, vb2)]:
                    m[:] = 0.9 * m + 0.1 * dp
                    v[:] = 0.999 * v + 0.001 * (dp ** 2)
                    m_hat = m / (1.0 - 0.9 ** t_step)
                    v_hat = v / (1.0 - 0.999 ** t_step)
                    p[:] -= lr * m_hat / (np.sqrt(v_hat) + 1e-8)

    t0 = time.time()
    print("[Train] Initial Supervised Pretraining (100 epochs)...")
    optimize_adam(100, lr=0.008)
    
    for d_round in range(dagger_rounds):
        added = 0
        for s in range(dagger_episodes):
            obs = env.reset(seed=100 + d_round * 50 + s)
            for _ in range(150):
                p_act = policy.forward_float(obs)
                t_act = teacher.act(obs)
                X_list.append(obs.copy())
                Y_list.append(t_act.copy())
                added += 1
                obs, r, done, info = env.step(p_act)
                if done:
                    break
        print(f"[Train] DAgger round {d_round+1}/{dagger_rounds}: added {added} samples (Total: {len(X_list)})")
        optimize_adam(60, lr=0.004)
        
    t_elapsed = time.time() - t0
    print(f"[Train] Training complete in {t_elapsed:.2f} s")
    
    # Range-aware symmetric INT8 Quantization
    print("[Train] Performing Range-Aware Symmetric INT8 Quantization...")
    X_arr = np.array(X_list, dtype=np.float32)
    H1_arr = np.maximum(0.0, np.dot(X_arr, policy.w1.T) + policy.b1)
    max_h1 = float(np.percentile(H1_arr, 99.9)) + 0.05
    print(f"[Train] Determined dynamic Layer 1 activation ceiling: max_h1 = {max_h1:.3f}")
    
    scale_x = 127.0
    
    # Layer 1
    max_w1 = float(np.max(np.abs(policy.w1))) + 1e-7
    scale_w1 = 127.0 / max_w1
    w1_int8 = np.clip(np.round(policy.w1 * scale_w1), -128, 127).astype(np.int8)
    scale_b1 = scale_w1 * scale_x
    b1_int32 = np.round(policy.b1 * scale_b1).astype(np.int32)
    
    scale_h1 = 127.0 / max_h1
    m1 = 1.0 / (scale_w1 * max_h1)
    l1_scale_shift = 15
    l1_scale_mult = int(round(m1 * (1 << l1_scale_shift)))
    
    # Layer 2
    max_w2 = float(np.max(np.abs(policy.w2))) + 1e-7
    scale_w2 = 127.0 / max_w2
    w2_int8 = np.clip(np.round(policy.w2 * scale_w2), -128, 127).astype(np.int8)
    scale_b2 = scale_w2 * scale_h1
    b2_int32 = np.round(policy.b2 * scale_b2).astype(np.int32)
    
    m2 = max_h1 / scale_w2
    l2_scale_shift = 15
    l2_scale_mult = int(round(m2 * (1 << l2_scale_shift)))

    model_data = {
        "l1": {
            "weights": w1_int8.tolist(),
            "biases": b1_int32.tolist(),
            "scale_mult": l1_scale_mult,
            "scale_shift": l1_scale_shift,
            "act": ACT_RELU
        },
        "l2": {
            "weights": w2_int8.tolist(),
            "biases": b2_int32.tolist(),
            "scale_mult": l2_scale_mult,
            "scale_shift": l2_scale_shift,
            "act": ACT_CLIP
        },
        "raw_float": {
            "w1": policy.w1.tolist(),
            "b1": policy.b1.tolist(),
            "w2": policy.w2.tolist(),
            "b2": policy.b2.tolist()
        }
    }
    
    out_path = os.path.join(os.path.dirname(__file__), "trained_policy_weights.json")
    with open(out_path, "w") as f:
        json.dump(model_data, f, indent=2)
    print(f"[Train] Saved quantized policy to {out_path}")
    return policy, model_data

if __name__ == "__main__":
    train_policy()
