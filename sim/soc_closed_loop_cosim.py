#!/usr/bin/env python3
"""
===============================================================================
Closed-Loop Hardware-in-the-Loop Co-Simulation Harness
File: sim/soc_closed_loop_cosim.py

Couples the 2D Mobile Robot Physics Simulation (RobotEnv2D) directly to the
Verilog RTL simulation of the RV32IM + rv_nna SoC (tb_soc_cosim.vvp).

Features:
- Bidirectional mailbox exchange between Python physics and RISC-V SoC
- Real-time INT8 sensor quantization (16 features)
- Closed-loop policy execution on simulated hardware
- Bit-exact verification against Python INT8 reference model (0 LSB error)
- Deterministic safety layer intervention monitoring & emergency braking
- Hardware PWM duty cycle extraction & differential kinematics tracking
- Outputs comprehensive metrics report to JSON
===============================================================================
"""

import os
import math
import sys
import time
import json
import argparse
import subprocess
import numpy as np

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../sw/policy')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../sw/model')))

from robot_env import RobotEnv2D
from reference_model import quantize_layer, ACT_RELU, ACT_CLIP

class ReferencePolicyINT8:
    """Bit-exact Python INT8 reference policy for verification against SoC."""
    def __init__(self, weights_path):
        with open(weights_path, 'r') as f:
            data = json.load(f)
        
        self.l1_w = np.array(data["l1"]["weights"], dtype=np.int32)
        self.l1_b = np.array(data["l1"]["biases"], dtype=np.int32)
        self.l1_scale = data["l1"]["scale_mult"]
        self.l1_shift = data["l1"]["scale_shift"]

        self.l2_w = np.array(data["l2"]["weights"], dtype=np.int32)
        self.l2_b = np.array(data["l2"]["biases"], dtype=np.int32)
        self.l2_scale = data["l2"]["scale_mult"]
        self.l2_shift = data["l2"]["scale_shift"]

    def infer(self, obs_int8):
        # Layer 1: 16 -> 8, ReLU
        h, _ = quantize_layer(obs_int8, self.l1_w, self.l1_b,
                              self.l1_scale, self.l1_shift, ACT_RELU)
        # Layer 2: 8 -> 2, Clip
        out, _ = quantize_layer(h, self.l2_w, self.l2_b,
                                self.l2_scale, self.l2_shift, ACT_CLIP)
        return out[0], out[1]

class SoCSubprocess:
    """Manages the interactive Icarus Verilog simulation subprocess."""
    def __init__(self, vvp_path):
        if not os.path.isfile(vvp_path):
            raise FileNotFoundError(f"VVP simulation binary not found at: {vvp_path}")
        
        self.proc = subprocess.Popen(
            ["vvp", vvp_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1
        )
        
        # Wait for SoC to boot and signal readiness
        booted = False
        while True:
            line = self.proc.stdout.readline()
            if not line:
                stderr_out = self.proc.stderr.read()
                raise RuntimeError(f"SoC terminated unexpectedly during boot: {stderr_out}")
            if "SOC_READY" in line:
                booted = True
                break
        if not booted:
            raise RuntimeError("Failed to receive SOC_READY acknowledgment.")

    def step(self, obs_int8):
        """Sends 16-D INT8 sensor vector and reads execution telemetry."""
        words = []
        for i in range(0, 16, 4):
            b0 = obs_int8[i] & 0xFF
            b1 = obs_int8[i+1] & 0xFF
            b2 = obs_int8[i+2] & 0xFF
            b3 = obs_int8[i+3] & 0xFF
            w = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
            words.append(f"{w:08x}")
        
        cmd = f"STEP {words[0]} {words[1]} {words[2]} {words[3]}\n"
        self.proc.stdin.write(cmd)
        self.proc.stdin.flush()

        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("SoC simulation pipe closed prematurely during step execution.")
            if line.startswith("STEP_RESULT"):
                # STEP_RESULT v_raw w_raw v_cmd w_cmd safety_trip pwm_l pwm_r cycles
                parts = line.strip().split()
                return {
                    "v_raw": int(parts[1]),
                    "w_raw": int(parts[2]),
                    "v_cmd": int(parts[3]),
                    "w_cmd": int(parts[4]),
                    "safety_trip": int(parts[5]),
                    "pwm_l": int(parts[6]),
                    "pwm_r": int(parts[7]),
                    "cycles": int(parts[8]) if len(parts) > 8 else 0
                }

    def close(self):
        try:
            self.proc.stdin.write("SHUTDOWN\n")
            self.proc.stdin.flush()
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()

def run_cosim(args):
    print("=" * 78)
    print("RV32IM + rv_nna SoC Closed-Loop Co-Simulation Harness")
    print(f"Simulation Binary: {args.vvp}")
    print(f"Episodes: {args.episodes} | Steps per Episode: {args.steps} | Seed: {args.seed}")
    print("=" * 78)

    weights_json = os.path.abspath(os.path.join(os.path.dirname(__file__), "../sw/policy/rl_seed1_policy.json"))
    ref_policy = ReferencePolicyINT8(weights_json)
    
    soc = SoCSubprocess(args.vvp)
    env = RobotEnv2D(max_steps=args.steps)

    all_episodes = []
    total_steps = 0
    total_cycles = 0
    total_trips = 0
    max_discrepancy_lsb = 0

    t_start = time.time()

    for ep_idx in range(args.episodes):
        obs = env.reset(seed=args.seed + ep_idx)
        ep_history = []
        ep_trips = 0
        ep_cycles = 0

        print(f"\n--- Episode {ep_idx + 1}/{args.episodes} (Seed {args.seed + ep_idx}) ---")
        print("Step | Pos (x, y)    | Heading | Raw (v, w) | Safe (v, w)| Trip | PWM (L, R) | Cycles")
        print("-" * 78)

        for st in range(env.max_steps):
            total_steps += 1
            
            # 1. Quantize 16-D float observation to INT8 [-128, 127]
            obs_int8 = [int(np.clip(round(v * 127.0), -128, 127)) for v in obs]

            # 2. Reference Model Inference
            ref_v, ref_w = ref_policy.infer(obs_int8)

            # 3. Hardware SoC Step via Mailbox
            res = soc.step(obs_int8)

            # 4. Bit-Exact Verification Check
            diff_v = abs(res["v_raw"] - ref_v)
            diff_w = abs(res["w_raw"] - ref_w)
            lsb_err = max(diff_v, diff_w)
            if lsb_err > max_discrepancy_lsb:
                max_discrepancy_lsb = lsb_err

            if lsb_err > 0:
                print(f"[ERROR] Step {st+1}: Discrepancy detected! SoC=({res['v_raw']}, {res['w_raw']}) Ref=({ref_v}, {ref_w})")
                soc.close()
                sys.exit(1)

            # 5. Track Safety Trip & Cycles
            if res["safety_trip"]:
                ep_trips += 1
                total_trips += 1
            ep_cycles += res["cycles"]
            total_cycles += res["cycles"]

            # 6. Apply Filtered Action to 2D Physics Environment
            # env maps action[0] in [-1,1] -> target_v = 0.5*(a+1)*v_max, so v_cmd=0 must map to a=-1
            act_float = np.array([2.0 * max(0, res["v_cmd"]) / 127.0 - 1.0, res["w_cmd"] / 127.0], dtype=np.float32)
            obs, reward, done, info = env.step(act_float)

            # Log step
            trip_str = "TRIP!" if res["safety_trip"] else "PASS "
            print(f"{st+1:4d} | ({env.x:+5.2f}, {env.y:+5.2f}) | {env.theta:+6.2f} | ({res['v_raw']:+4d}, {res['w_raw']:+4d}) | ({res['v_cmd']:+4d}, {res['w_cmd']:+4d}) | {trip_str} | ({res['pwm_l']:4d}, {res['pwm_r']:4d}) | {res['cycles']:6d}")

            ep_history.append({
                "step": st + 1,
                "x": float(env.x),
                "y": float(env.y),
                "theta": float(env.theta),
                "v_raw": res["v_raw"],
                "w_raw": res["w_raw"],
                "v_cmd": res["v_cmd"],
                "w_cmd": res["w_cmd"],
                "safety_trip": res["safety_trip"],
                "pwm_l": res["pwm_l"],
                "pwm_r": res["pwm_r"],
                "cycles": res["cycles"],
                "dist_to_goal": float(math.hypot(env.x - env.goal_x, env.y - env.goal_y))
            })

            if done:
                print(f"Finished at step {st+1}: Success={info.get('success')}, Collision={info.get('collision')}")
                break

        all_episodes.append({
            "episode": ep_idx + 1,
            "steps": len(ep_history),
            "safety_trips": ep_trips,
            "total_cycles": ep_cycles,
            "avg_cycles_per_step": ep_cycles / len(ep_history) if ep_history else 0,
            "history": ep_history
        })

    t_total = time.time() - t_start
    soc.close()

    avg_cycles = total_cycles / total_steps if total_steps > 0 else 0
    # At 50 MHz clock: 1 cycle = 20 ns
    avg_latency_us = (avg_cycles * 20.0) / 1000.0

    print("\n" + "=" * 78)
    print("CO-SIMULATION SUMMARY RESULTS")
    print("=" * 78)
    print(f"Total Steps Executed:         {total_steps}")
    print(f"Total Wall-Clock Time:        {t_total:.2f} s ({t_total/total_steps:.2f} s/step in simulation)")
    print(f"Max SoC Discrepancy (LSB):    {max_discrepancy_lsb} (Bit-Exact Match)")
    print(f"Total Safety Interventions:   {total_trips}")
    print(f"Mean Hardware Inference:      {avg_cycles:.1f} cycles ({avg_latency_us:.2f} microseconds @ 50 MHz)")
    print("=" * 78)

    results_data = {
        "status": "PASS",
        "total_steps": total_steps,
        "total_episodes": args.episodes,
        "wall_clock_time_sec": t_total,
        "max_discrepancy_lsb": max_discrepancy_lsb,
        "total_safety_trips": total_trips,
        "mean_cycles_per_step": avg_cycles,
        "hardware_latency_us_at_50mhz": avg_latency_us,
        "episodes": all_episodes
    }

    if args.output:
        with open(args.output, 'w') as f:
            json.dump(results_data, f, indent=2)
        print(f"Results written to: {args.output}")

    assert max_discrepancy_lsb == 0, f"Discrepancy detected: {max_discrepancy_lsb} LSB"
    print("\nALL CO-SIMULATION CHECKS PASSED SUCCESSFULLY!\n")
    return 0

def main():
    parser = argparse.ArgumentParser(description="RISC-V SoC Closed-Loop Co-Simulation Harness")
    parser.add_argument("--vvp", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "tb_soc_cosim.vvp"), help="Path to compiled tb_soc_cosim.vvp")
    parser.add_argument("--steps", type=int, default=20, help="Max steps per episode")
    parser.add_argument("--episodes", type=int, default=1, help="Number of episodes")
    parser.add_argument("--seed", type=int, default=42, help="Random seed for environment reset")
    parser.add_argument("--output", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "cosim_results.json"), help="Path to write JSON results")
    args = parser.parse_args()

    sys.exit(run_cosim(args))

if __name__ == "__main__":
    main()
