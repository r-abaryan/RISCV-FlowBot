#!/usr/bin/env python3
"""
Comprehensive Quantization Error Analysis & Test Vector Generator for rv_nna
Analyzes Float32 vs Bit-Exact INT8 policy behavior across authentic robot navigation episodes.
Exports authentic test vectors for Verilog RTL simulation verification.
"""

import os
import sys
import json
import math
import numpy as np

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
from sim.robot_env import RobotEnv2D
from sw.model.reference_model import quantize_layer, ACT_RELU, ACT_CLIP

def load_trained_policy(weights_path):
    with open(weights_path, "r") as f:
        data = json.load(f)
    return data

class FloatPolicy:
    def __init__(self, data):
        self.w1 = np.array(data["raw_float"]["w1"], dtype=np.float32)
        self.b1 = np.array(data["raw_float"]["b1"], dtype=np.float32)
        self.w2 = np.array(data["raw_float"]["w2"], dtype=np.float32)
        self.b2 = np.array(data["raw_float"]["b2"], dtype=np.float32)
        
    def __call__(self, obs):
        x = np.array(obs, dtype=np.float32)
        h1 = np.maximum(0.0, np.dot(x, self.w1.T) + self.b1)
        out = np.dot(h1, self.w2.T) + self.b2
        return np.clip(out, -1.0, 1.0)

class INT8Policy:
    def __init__(self, data):
        self.w1 = data["l1"]["weights"]
        self.b1 = data["l1"]["biases"]
        self.l1_mult = data["l1"]["scale_mult"]
        self.l1_shift = data["l1"]["scale_shift"]
        
        self.w2 = data["l2"]["weights"]
        self.b2 = data["l2"]["biases"]
        self.l2_mult = data["l2"]["scale_mult"]
        self.l2_shift = data["l2"]["scale_shift"]
        
    def infer_layers(self, obs):
        # Quantize input features
        x_int8 = [int(np.clip(np.round(val * 127.0), -128, 127)) for val in obs]
        
        # Layer 1: 16 -> 8, ReLU
        h1_int8, h1_acc = quantize_layer(x_int8, self.w1, self.b1, self.l1_mult, self.l1_shift, ACT_RELU)
        
        # Layer 2: 8 -> 2, Clip
        y_int8, y_acc = quantize_layer(h1_int8, self.w2, self.b2, self.l2_mult, self.l2_shift, ACT_CLIP)
        
        # Float reconstructed
        act_float = np.array([y_int8[0] / 127.0, y_int8[1] / 127.0], dtype=np.float32)
        return {
            "x_int8": x_int8,
            "h1_int8": h1_int8,
            "h1_acc": h1_acc,
            "y_int8": y_int8,
            "y_acc": y_acc,
            "act_float": act_float
        }

    def __call__(self, obs):
        return self.infer_layers(obs)["act_float"]

def pack_int8_words(byte_list):
    words = []
    for i in range(0, len(byte_list), 4):
        chunk = byte_list[i:i+4]
        while len(chunk) < 4:
            chunk.append(0)
        word = (chunk[0] & 0xFF) | ((chunk[1] & 0xFF) << 8) | ((chunk[2] & 0xFF) << 16) | ((chunk[3] & 0xFF) << 24)
        words.append(word)
    return words

def collect_dataset_and_analyze(data_weights, n_episodes=50, base_seed=1000):
    env = RobotEnv2D()
    float_policy = FloatPolicy(data_weights)
    int8_policy = INT8Policy(data_weights)
    
    observations = []
    actions_float = []
    actions_int8 = []
    int8_layer_details = []
    
    # Collect observations during navigation under the policy
    for ep in range(n_episodes):
        obs = env.reset(seed=base_seed + ep)
        for st in range(env.max_steps):
            observations.append(obs)
            af = float_policy(obs)
            details = int8_policy.infer_layers(obs)
            ai = details["act_float"]
            
            actions_float.append(af)
            actions_int8.append(ai)
            int8_layer_details.append(details)
            
            # Step environment using int8 policy
            obs, r, done, info = env.step(ai)
            if done:
                break
                
    obs_arr = np.array(observations)
    af_arr = np.array(actions_float)
    ai_arr = np.array(actions_int8)
    
    # Error metrics
    diff = af_arr - ai_arr
    mae_v = float(np.mean(np.abs(diff[:, 0])))
    mae_w = float(np.mean(np.abs(diff[:, 1])))
    max_err_v = float(np.max(np.abs(diff[:, 0])))
    max_err_w = float(np.max(np.abs(diff[:, 1])))
    rmse_v = float(np.sqrt(np.mean(diff[:, 0]**2)))
    rmse_w = float(np.sqrt(np.mean(diff[:, 1]**2)))
    
    # Signal-to-Noise Ratio (SNR) in dB
    sig_power_v = np.mean(af_arr[:, 0]**2)
    noise_power_v = np.mean(diff[:, 0]**2) + 1e-12
    snr_v_db = float(10.0 * np.log10(sig_power_v / noise_power_v))
    
    sig_power_w = np.mean(af_arr[:, 1]**2)
    noise_power_w = np.mean(diff[:, 1]**2) + 1e-12
    snr_w_db = float(10.0 * np.log10(sig_power_w / noise_power_w))
    
    # Correlation (Pearson)
    corr_v = float(np.corrcoef(af_arr[:, 0], ai_arr[:, 0])[0, 1])
    corr_w = float(np.corrcoef(af_arr[:, 1], ai_arr[:, 1])[0, 1])
    
    # Distribution statistics
    stats = {
        "num_samples": len(observations),
        "mae_v": mae_v,
        "mae_w": mae_w,
        "overall_mae": float((mae_v + mae_w) / 2.0),
        "max_err_v": max_err_v,
        "max_err_w": max_err_w,
        "overall_max_err": max(max_err_v, max_err_w),
        "rmse_v": rmse_v,
        "rmse_w": rmse_w,
        "snr_v_db": snr_v_db,
        "snr_w_db": snr_w_db,
        "corr_v": corr_v,
        "corr_w": corr_w,
        "float_v": {
            "mean": float(np.mean(af_arr[:, 0])),
            "std": float(np.std(af_arr[:, 0])),
            "min": float(np.min(af_arr[:, 0])),
            "max": float(np.max(af_arr[:, 0])),
            "p25": float(np.percentile(af_arr[:, 0], 25)),
            "p50": float(np.percentile(af_arr[:, 0], 50)),
            "p75": float(np.percentile(af_arr[:, 0], 75))
        },
        "float_w": {
            "mean": float(np.mean(af_arr[:, 1])),
            "std": float(np.std(af_arr[:, 1])),
            "min": float(np.min(af_arr[:, 1])),
            "max": float(np.max(af_arr[:, 1])),
            "p25": float(np.percentile(af_arr[:, 1], 25)),
            "p50": float(np.percentile(af_arr[:, 1], 50)),
            "p75": float(np.percentile(af_arr[:, 1], 75))
        },
        "int8_v": {
            "mean": float(np.mean(ai_arr[:, 0])),
            "std": float(np.std(ai_arr[:, 0])),
            "min": float(np.min(ai_arr[:, 0])),
            "max": float(np.max(ai_arr[:, 0])),
            "p25": float(np.percentile(ai_arr[:, 0], 25)),
            "p50": float(np.percentile(ai_arr[:, 0], 50)),
            "p75": float(np.percentile(ai_arr[:, 0], 75))
        },
        "int8_w": {
            "mean": float(np.mean(ai_arr[:, 1])),
            "std": float(np.std(ai_arr[:, 1])),
            "min": float(np.min(ai_arr[:, 1])),
            "max": float(np.max(ai_arr[:, 1])),
            "p25": float(np.percentile(ai_arr[:, 1], 25)),
            "p50": float(np.percentile(ai_arr[:, 1], 50)),
            "p75": float(np.percentile(ai_arr[:, 1], 75))
        }
    }
    
    # Select 25 diverse authentic vectors across episodes for RTL verification
    selected_indices = np.linspace(0, len(observations) - 1, 25, dtype=int)
    test_vectors = []
    for idx in selected_indices:
        d = int8_layer_details[idx]
        x_words = pack_int8_words(d["x_int8"])
        h1_words = pack_int8_words(d["h1_int8"])
        y_words = pack_int8_words(d["y_int8"])
        test_vectors.append({
            "sample_index": int(idx),
            "obs_raw": [float(v) for v in observations[idx]],
            "x_int8": d["x_int8"],
            "x_words": [f"0x{w:08x}" for w in x_words],
            "x_words_raw": x_words,
            "h1_int8": d["h1_int8"],
            "h1_words": [f"0x{w:08x}" for w in h1_words],
            "h1_words_raw": h1_words,
            "y_int8": d["y_int8"],
            "y_words": [f"0x{w:08x}" for w in y_words],
            "y_words_raw": y_words,
            "act_float_expected": [float(v) for v in af_arr[idx]],
            "act_int8_reconstructed": [float(v) for v in ai_arr[idx]]
        })
        
    return stats, test_vectors

def main():
    weights_path = os.path.join(os.path.dirname(__file__), "../policy/trained_policy_weights.json")
    data_weights = load_trained_policy(weights_path)
    
    print("[Quantization Analysis] Collecting dataset across 50 episodes...")
    stats, test_vectors = collect_dataset_and_analyze(data_weights, n_episodes=50, base_seed=1000)
    
    print(f"\n--- INT8 Quantization Error Analysis ({stats['num_samples']} authentic samples) ---")
    print(f"Linear Velocity v:  MAE = {stats['mae_v']:.4f} | Max Err = {stats['max_err_v']:.4f} | RMSE = {stats['rmse_v']:.4f} | SNR = {stats['snr_v_db']:.2f} dB | Corr = {stats['corr_v']:.4f}")
    print(f"Angular Velocity w: MAE = {stats['mae_w']:.4f} | Max Err = {stats['max_err_w']:.4f} | RMSE = {stats['rmse_w']:.4f} | SNR = {stats['snr_w_db']:.2f} dB | Corr = {stats['corr_w']:.4f}")
    print(f"Overall Action MAE: {stats['overall_mae']:.4f} (Criterion < 0.05: {'PASS' if stats['overall_mae'] < 0.05 else 'FAIL'})")
    print(f"Overall Max Error:  {stats['overall_max_err']:.4f}")
    
    # Save analysis results
    analysis_path = os.path.join(os.path.dirname(__file__), "../policy/quantization_analysis.json")
    with open(analysis_path, "w") as f:
        json.dump(stats, f, indent=2)
    print(f"\nSaved quantization analysis to {analysis_path}")
    
    # Save RTL verification test vectors
    vectors_path = os.path.join(os.path.dirname(__file__), "../../sim/test_vectors_trained.json")
    with open(vectors_path, "w") as f:
        json.dump(test_vectors, f, indent=2)
    print(f"Saved {len(test_vectors)} authentic RTL test vectors to {vectors_path}")

if __name__ == "__main__":
    main()
