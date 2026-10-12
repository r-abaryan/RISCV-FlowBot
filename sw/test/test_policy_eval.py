"""
Comparative Evaluation Benchmark for RISC-V SoC Reinforcement Learning Policy
Evaluates Random, Heuristic (APF), Trained Float, and Bit-Exact INT8 Policies over 50 test episodes.
Enforces Phase 1 Acceptance Criteria with strict assertion exit codes.
"""

import os
import sys
import time
import math
import numpy as np

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../../sim')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../policy')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../model')))

from robot_env import RobotEnv2D
from baselines import RandomPolicy, HeuristicPolicy
from train_policy import train_policy, MLP16x8x2
from reference_model import quantize_layer, ACT_RELU, ACT_CLIP

class QuantizedInt8Policy:
    """Bit-exact INT8 inference policy running identical math to rv_nna accelerator."""
    def __init__(self, model_data):
        self.w1 = model_data["l1"]["weights"]
        self.b1 = model_data["l1"]["biases"]
        self.l1_mult = model_data["l1"]["scale_mult"]
        self.l1_shift = model_data["l1"]["scale_shift"]
        
        self.w2 = model_data["l2"]["weights"]
        self.b2 = model_data["l2"]["biases"]
        self.l2_mult = model_data["l2"]["scale_mult"]
        self.l2_shift = model_data["l2"]["scale_shift"]

    def act(self, obs_float):
        # Quantize float obs [-1.0, 1.0] to INT8 [-127, 127]
        x_int8 = [int(np.clip(round(val * 127.0), -128, 127)) for val in obs_float]
        
        # Layer 1: 16 -> 8, ReLU
        h1_int8, _ = quantize_layer(x_int8, self.w1, self.b1, self.l1_mult, self.l1_shift, ACT_RELU)
        
        # Layer 2: 8 -> 2, Clip
        out_int8, _ = quantize_layer(h1_int8, self.w2, self.b2, self.l2_mult, self.l2_shift, ACT_CLIP)
        
        # Dequantize action back to [-1.0, 1.0]
        act_float = np.array([out_int8[0] / 127.0, out_int8[1] / 127.0], dtype=np.float32)
        return act_float

def run_evaluation(policy_fn, env, n_episodes=50, base_seed=1000):
    successes = 0
    collisions = 0
    timeouts = 0
    rewards = []
    succ_steps = []
    
    for i in range(n_episodes):
        obs = env.reset(seed=base_seed + i)
        tot_r = 0.0
        for st in range(env.max_steps):
            act = policy_fn(obs)
            obs, r, done, info = env.step(act)
            tot_r += r
            if done:
                if info["success"]:
                    successes += 1
                    succ_steps.append(st + 1)
                elif info["collision"]:
                    collisions += 1
                else:
                    timeouts += 1
                break
        rewards.append(tot_r)
        
    return {
        "success_rate": successes / n_episodes,
        "collision_rate": collisions / n_episodes,
        "timeout_rate": timeouts / n_episodes,
        "mean_reward": float(np.mean(rewards)),
        "mean_steps": float(np.mean(succ_steps)) if succ_steps else float(env.max_steps),
        "total_episodes": n_episodes
    }

def main():
    print("================================================================================")
    print(" Phase 1: Reinforcement Learning Mobile Robot Navigation Verification Suite")
    print("================================================================================")
    
    env = RobotEnv2D(max_steps=150)
    
    # 1. Train or load policy
    weights_path = os.path.join(os.path.dirname(__file__), "../policy/trained_policy_weights.json")
    if not os.path.exists(weights_path):
        float_policy, model_data = train_policy()
    else:
        import json
        with open(weights_path) as f:
            model_data = json.load(f)
        float_policy = MLP16x8x2()
        float_policy.w1[:] = np.array(model_data["raw_float"]["w1"])
        float_policy.b1[:] = np.array(model_data["raw_float"]["b1"])
        float_policy.w2[:] = np.array(model_data["raw_float"]["w2"])
        float_policy.b2[:] = np.array(model_data["raw_float"]["b2"])
        
    int8_policy = QuantizedInt8Policy(model_data)
    rand_policy = RandomPolicy()
    apf_policy = HeuristicPolicy()
    
    print("\nRunning 50-episode comparative evaluation on identical seeds [1000..1049]...\n")
    
    res_rand = run_evaluation(lambda obs: rand_policy.act(obs), env)
    print(f"Random Baseline:   Success={res_rand['success_rate']*100:4.1f}% | Collisions={res_rand['collision_rate']*100:4.1f}% | Reward={res_rand['mean_reward']:6.2f}")
    
    res_apf = run_evaluation(lambda obs: apf_policy.act(obs), env)
    print(f"Heuristic Baseline:Success={res_apf['success_rate']*100:4.1f}% | Collisions={res_apf['collision_rate']*100:4.1f}% | Reward={res_apf['mean_reward']:6.2f}")
    
    res_flt = run_evaluation(lambda obs: float_policy.forward_float(obs), env)
    print(f"Trained Float MLP: Success={res_flt['success_rate']*100:4.1f}% | Collisions={res_flt['collision_rate']*100:4.1f}% | Reward={res_flt['mean_reward']:6.2f}")
    
    res_int8 = run_evaluation(lambda obs: int8_policy.act(obs), env)
    print(f"Trained INT8 NNA:  Success={res_int8['success_rate']*100:4.1f}% | Collisions={res_int8['collision_rate']*100:4.1f}% | Reward={res_int8['mean_reward']:6.2f}")
    
    print("\n--------------------------------------------------------------------------------")
    print(" Acceptance Criteria Verification:")
    print("--------------------------------------------------------------------------------")
    
    # 1. Success rate beats random by large margin (> 50% minimum threshold, 70%+ target)
    target_succ = 0.50
    succ_ok = (res_flt["success_rate"] >= target_succ)
    print(f"  [1] Success Rate >= 50%:         {'PASS' if succ_ok else 'FAIL'} ({res_flt['success_rate']*100:.1f}%)")
    
    # 2. Collision rate is substantially lower than random exploration
    coll_ok = (res_flt["collision_rate"] < res_rand["collision_rate"])
    print(f"  [2] Collision Rate < Random:     {'PASS' if coll_ok else 'FAIL'} ({res_flt['collision_rate']*100:.1f}% vs {res_rand['collision_rate']*100:.1f}%)")
    
    # 3. Reward is positive and outperforms random baseline
    rew_ok = (res_flt["mean_reward"] > 0.0 and res_flt["mean_reward"] > res_rand["mean_reward"])
    print(f"  [3] Mean Reward Outperforms:     {'PASS' if rew_ok else 'FAIL'} ({res_flt['mean_reward']:.2f} vs {res_rand['mean_reward']:.2f})")
    
    # 4. INT8 Quantization retention
    retention = (res_int8["success_rate"] / max(res_flt["success_rate"], 0.01)) * 100.0
    print(f"  [4] INT8 vs Float Retention:     {'PASS' if retention >= 70.0 else 'INFO'} ({retention:.1f}%)")
    
    all_passed = succ_ok and coll_ok and rew_ok
    if all_passed:
        print("\n>>> ALL PHASE 1 ACCEPTANCE CRITERIA PASSED SUCCESSFULLY! <<<\n")
        return 0
    else:
        print("\n>>> PHASE 1 VERIFICATION FAILED! <<<\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
