#!/usr/bin/env python3
"""
End-to-End Simulation: Robot Sensor Pipeline -> INT8 Neural Policy -> Deterministic Safety Filter
Demonstrates complete closed-loop navigation step matching the SoC architecture.
"""

import sys
import math
import random
from reference_model import quantize_layer, ACT_RELU, ACT_CLIP
from safety_layer import DeterministicSafetyFilter

class RobotPolicyE2E:
    """
    3-Layer MLP Policy:
      Input (16 features):
        - 8 distance sensors (d_0 .. d_7, normalized: 0.0m to 4.0m -> INT8)
        - 3 IMU features (ax, ay in m/s^2, yaw_rate in rad/s)
        - 3 Odometry features (vx, vy in m/s, yaw_rate)
        - 2 Goal-relative features (dist_to_goal, angle_to_goal)
      Hidden Layer 1: 16 -> 16 (ReLU)
      Hidden Layer 2: 16 -> 8  (ReLU)
      Output Layer:    8 -> 2  (Linear/Clip -> [v_raw, w_raw])
    """
    def __init__(self, seed=123):
        random.seed(seed)
        # Weights and biases for 3-layer MLP
        self.w1 = [[random.randint(-40, 40) for _ in range(16)] for _ in range(16)]
        self.b1 = [random.randint(-100, 100) for _ in range(16)]
        self.scale1_mult = 32768  # 0.5 in Q16
        self.scale1_shift = 16

        self.w2 = [[random.randint(-40, 40) for _ in range(16)] for _ in range(8)]
        self.b2 = [random.randint(-100, 100) for _ in range(8)]
        self.scale2_mult = 32768
        self.scale2_shift = 16

        self.w3 = [[random.randint(-40, 40) for _ in range(8)] for _ in range(2)]
        self.b3 = [random.randint(-50, 50) for _ in range(2)]
        self.scale3_mult = 32768
        self.scale3_shift = 16

        self.safety_filter = DeterministicSafetyFilter(
            v_max=0.5,
            w_max=2.0,
            a_max=1.0,
            alpha_max=4.0,
            d_margin=0.15,
            a_brake=1.5,
            dt=0.02
        )

    def preprocess_sensors(self, distances, imu_ax, imu_ay, imu_wz, odom_vx, odom_vy, odom_wz, goal_dist, goal_angle):
        """Quantizes raw sensor measurements into signed INT8 values [-128, 127]."""
        features = []
        
        # 8 distance sensors: range 0.0m - 4.0m mapped to [-128, 127]
        for d in distances:
            norm_d = min(max(d, 0.0), 4.0) / 4.0  # 0.0 to 1.0
            q_d = int(norm_d * 255.0) - 128
            features.append(min(127, max(-128, q_d)))

        # IMU features: ax, ay in [-2.0, 2.0] m/s^2, wz in [-3.14, 3.14] rad/s
        features.append(int(min(max(imu_ax / 2.0, -1.0), 1.0) * 127))
        features.append(int(min(max(imu_ay / 2.0, -1.0), 1.0) * 127))
        features.append(int(min(max(imu_wz / 3.14, -1.0), 1.0) * 127))

        # Odometry features: vx in [-1.0, 1.0] m/s, vy in [-1.0, 1.0] m/s, wz in [-3.14, 3.14] rad/s
        features.append(int(min(max(odom_vx / 1.0, -1.0), 1.0) * 127))
        features.append(int(min(max(odom_vy / 1.0, -1.0), 1.0) * 127))
        features.append(int(min(max(odom_wz / 3.14, -1.0), 1.0) * 127))

        # Goal features: goal_dist in [0, 10m], goal_angle in [-pi, pi]
        norm_gdist = min(max(goal_dist / 10.0, 0.0), 1.0)
        features.append(int(norm_gdist * 255.0) - 128)
        features.append(int(min(max(goal_angle / 3.14, -1.0), 1.0) * 127))

        return features

    def run_nna_policy(self, input_features):
        """Executes the 3-layer MLP using the accelerator bit-exact quantization model."""
        # Layer 1: 16 -> 16 (ReLU)
        h1, _ = quantize_layer(input_features, self.w1, self.b1, 
                               self.scale1_mult, self.scale1_shift, ACT_RELU)
        
        # Layer 2: 16 -> 8 (ReLU)
        h2, _ = quantize_layer(h1, self.w2, self.b2, 
                               self.scale2_mult, self.scale2_shift, ACT_RELU)

        # Layer 3: 8 -> 2 (Linear / Clip)
        out, _ = quantize_layer(h2, self.w3, self.b3, 
                                self.scale3_mult, self.scale3_shift, ACT_CLIP)

        # Dequantize out to physical commands:
        # out[0]: v_cmd mapped to [-0.5, 0.5] m/s
        # out[1]: w_cmd mapped to [-2.0, 2.0] rad/s
        v_raw = (out[0] / 127.0) * 0.5
        w_raw = (out[1] / 127.0) * 2.0

        return v_raw, w_raw, h1, h2, out

    def step(self, distances, imu, odom, goal, inference_ok=True):
        """Runs one closed-loop step: preprocessing -> NNA -> Deterministic Safety Filter."""
        x_int8 = self.preprocess_sensors(
            distances=distances,
            imu_ax=imu['ax'],
            imu_ay=imu['ay'],
            imu_wz=imu['wz'],
            odom_vx=odom['vx'],
            odom_vy=odom['vy'],
            odom_wz=odom['wz'],
            goal_dist=goal['dist'],
            goal_angle=goal['angle']
        )

        v_raw, w_raw, _, _, _ = self.run_nna_policy(x_int8)

        min_dist = min(distances)
        v_safe, w_safe, reason = self.safety_filter.filter_action(
            v_raw=v_raw,
            w_raw=w_raw,
            min_obstacle_dist=min_dist,
            inference_ok=inference_ok
        )

        return (v_raw, w_raw), (v_safe, w_safe), reason

def run_e2e_tests():
    print("=== Running End-to-End Robot Policy & Safety Filter Simulation ===")
    policy = RobotPolicyE2E(seed=42)

    # Scenario 1: Open field, robot moving forward safely
    dists_open = [3.5] * 8
    imu1 = {'ax': 0.0, 'ay': 0.0, 'wz': 0.0}
    odom1 = {'vx': 0.1, 'vy': 0.0, 'wz': 0.0}
    goal1 = {'dist': 5.0, 'angle': 0.1}
    (v_r1, w_r1), (v_s1, w_s1), r1 = policy.step(dists_open, imu1, odom1, goal1)
    print(f"Scenario 1 (Open space): Raw cmd (v={v_r1:.3f}, w={w_r1:.3f}) -> Safe cmd (v={v_s1:.3f}, w={w_s1:.3f}) [Reason={r1}]")
    assert r1 == "NORMAL"

    # Scenario 2: Obstacle directly ahead (0.10m < d_margin 0.15m)
    dists_close = [0.10, 0.12, 0.8, 1.2, 1.5, 1.5, 0.8, 0.2]
    (v_r2, w_r2), (v_s2, w_s2), r2 = policy.step(dists_close, imu1, odom1, goal1)
    print(f"Scenario 2 (Close obstacle 0.10m): Raw cmd (v={v_r2:.3f}) -> Safe cmd (v={v_s2:.3f}) [Reason={r2}]")
    assert v_s2 <= 0.0, "Linear velocity must be clamped to zero or reverse near obstacle"
    assert r2 == "CRITICAL_OBSTACLE_BRAKE"

    # Scenario 3: Watchdog / Inference Timeout
    (v_r3, w_r3), (v_s3, w_s3), r3 = policy.step(dists_open, imu1, odom1, goal1, inference_ok=False)
    print(f"Scenario 3 (Watchdog timeout): Raw cmd (v={v_r3:.3f}) -> Safe cmd (v={v_s3:.3f}, w={v_s3:.3f}) [Reason={r3}]")
    assert v_s3 == 0.0 and w_s3 == 0.0
    assert r3 == "FAILSAFE_WATCHDOG_TIMEOUT"

    print("=== All End-to-End Simulation Scenarios Passed Successfully! ===")

if __name__ == "__main__":
    run_e2e_tests()
