#!/usr/bin/env python3
"""
Mobile Robot Navigation Policy: 2-Layer MLP INT8 Inference
Network Structure:
  Input: 16 features (8 distance sensors, 3 IMU, 3 Odometry, 2 Goal)
  Layer 1: 16 -> 8 (ReLU activation)
  Layer 2: 8 -> 2 (Clip activation) -> [v_raw, w_raw]
"""

import sys
import os
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../model')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../safety')))

from reference_model import quantize_layer, ACT_RELU, ACT_CLIP
from safety_layer import DeterministicSafetyFilter

# ============================================================================
# Layer 1 Weights (8 neurons, 16 inputs each = 128 weights)
# ============================================================================
# Inputs:
# 0: d_L90, 1: d_L45, 2: d_L15, 3: d_FC_L, 4: d_FC_R, 5: d_R15, 6: d_R45, 7: d_R90
# 8: ax, 9: ay, 10: wz_imu, 11: vx_odo, 12: vy_odo, 13: wz_odo, 14: goal_dist, 15: goal_heading

# Scale: 127 is open path (+4m), -128 is obstacle at 0m.
# Negative distance weight means: closer obstacle -> higher activation!

L1_WEIGHTS = [
    # N0: Obstacle Left Detector (triggers when d0, d1, d2 are low/negative)
    [-30, -50, -40,  -5,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0],
    # N1: Obstacle Right Detector (triggers when d5, d6, d7 are low/negative)
    [  0,   0,   0,   0,  -5, -40, -50, -30,   0,   0,   0,   0,   0,   0,   0,   0],
    # N2: Front Critical Obstacle (triggers when d3, d4 are low/negative)
    [  0,   0, -20, -55, -55, -20,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0],
    # N3: Goal Right Detector (triggers when goal_heading is positive)
    [  0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,  60],
    # N4: Goal Left Detector (triggers when goal_heading is negative)
    [  0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, -60],
    # N5: Clear Corridor Forward (positive distance on front rays d2..d5)
    [  0,   0,  20,  40,  40,  20,   0,   0,   0,   0,   0,   0,   0,   0,  30,   0],
    # N6: Heading rate damper (IMU gyro yaw rate dampening)
    [  0,   0,   0,   0,   0,   0,   0,   0,   0,   0, -40,   0,   0,   0,   0,   0],
    # N7: Odometry speed tracker
    [  0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,  50,   0,   0,   0,   0],
]

L1_BIAS = [
    100,    # N0 bias
    100,    # N1 bias
    200,    # N2 bias
    0,      # N3 bias
    0,      # N4 bias
    -200,   # N5 bias
    0,      # N6 bias
    0       # N7 bias
]

# Layer 1 Quantization Parameters
L1_SCALE_MULT = 16384  # 0.5 in Q15
L1_SCALE_SHIFT = 15

# ============================================================================
# Layer 2 Weights (2 neurons: v_raw, w_raw, 8 inputs each = 16 weights)
# ============================================================================
# Inputs: N0(ObsL), N1(ObsR), N2(ObsFront), N3(GoalR), N4(GoalL), N5(ClearFwd), N6(Damp), N7(Odo)
L2_WEIGHTS = [
    # Neuron 0: v_raw (Forward velocity command)
    # ObsFront suppresses v; ClearFwd promotes v.
    [-10, -10, -60,   0,   0,  70,   0,  10],
    # Neuron 1: w_raw (Steering command: + for Right, - for Left)
    # ObsL steers Right (+), ObsR steers Left (-), GoalR steers Right (+), GoalL steers Left (-)
    [ 60, -60,  30,  45, -45,   0, -20,   0]
]

L2_BIAS = [
    0,    # v bias
    0     # w bias
]

# Layer 2 Quantization Parameters
L2_SCALE_MULT = 16384  # 0.5 in Q15
L2_SCALE_SHIFT = 15

def run_navigation_inference(sensor_inputs):
    """
    Executes 2-layer quantized policy inference.
    sensor_inputs: 16-element INT8 list
    Returns:
      h1: 8-element INT8 activations (post-ReLU)
      out: 2-element INT8 actions [v_raw, w_raw] (post-Clip)
    """
    assert len(sensor_inputs) == 16, "Must provide 16 input features"

    # Layer 1: 16 -> 8 with ReLU
    h1, _ = quantize_layer(
        X=sensor_inputs,
        W=L1_WEIGHTS,
        B=L1_BIAS,
        scale_mult=L1_SCALE_MULT,
        scale_shift=L1_SCALE_SHIFT,
        act_type=ACT_RELU
    )

    # Layer 2: 8 -> 2 with Clip
    out, _ = quantize_layer(
        X=h1,
        W=L2_WEIGHTS,
        B=L2_BIAS,
        scale_mult=L2_SCALE_MULT,
        scale_shift=L2_SCALE_SHIFT,
        act_type=ACT_CLIP
    )

    return h1, out

def test_scenarios():
    print("=== Testing Mobile Robot Navigation Policy ===")
    
    # Scenario 1: Completely open path, target straight ahead
    s1 = [100]*8 + [0, 0, 0] + [0, 0, 0] + [80, 0]
    h1, out = run_navigation_inference(s1)
    print(f"Scenario 1 (Open path, Goal straight):")
    print(f"  h1: {h1}")
    print(f"  out: v_raw={out[0]}, w_raw={out[1]}  (Expected: v > 0, w ~ 0)")
    assert out[0] > 0, "Robot should drive forward in open path!"

    # Scenario 2: Obstacle ahead on Left, Goal straight
    s2 = [-100, -100, -80, 50, 100, 100, 100, 100] + [0, 0, 0] + [0, 0, 0] + [80, 0]
    h1, out = run_navigation_inference(s2)
    print(f"\nScenario 2 (Obstacle on Left):")
    print(f"  h1: {h1}")
    print(f"  out: v_raw={out[0]}, w_raw={out[1]}  (Expected: w > 0, steer Right)")
    assert out[1] > 0, "Robot should steer right to avoid left obstacle!"

    # Scenario 3: Obstacle ahead on Right, Goal straight
    s3 = [100, 100, 100, 100, 50, -80, -100, -100] + [0, 0, 0] + [0, 0, 0] + [80, 0]
    h1, out = run_navigation_inference(s3)
    print(f"\nScenario 3 (Obstacle on Right):")
    print(f"  h1: {h1}")
    print(f"  out: v_raw={out[0]}, w_raw={out[1]}  (Expected: w < 0, steer Left)")
    assert out[1] < 0, "Robot should steer left to avoid right obstacle!"

    # Scenario 4: Wall straight ahead
    s4 = [50, 50, -100, -120, -120, -100, 50, 50] + [0, 0, 0] + [0, 0, 0] + [80, 0]
    h1, out = run_navigation_inference(s4)
    print(f"\nScenario 4 (Critical Wall Ahead):")
    print(f"  h1: {h1}")
    print(f"  out: v_raw={out[0]}, w_raw={out[1]}  (Expected: v suppressed / braking)")
    assert out[0] < 20, "Robot should slow down or brake for wall!"

    print("\n=== All Navigation Policy Test Scenarios Passed Successfully! ===")

if __name__ == "__main__":
    test_scenarios()
