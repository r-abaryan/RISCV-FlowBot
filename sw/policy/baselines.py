"""
Baseline Policies for 2D Mobile Robot Navigation Benchmark
1. RandomPolicy: Uniform random action exploration baseline
2. HeuristicPolicy: Artificial Potential Field (APF) obstacle avoidance & goal tracking
"""

import math
import numpy as np

class RandomPolicy:
    """Selects uniform random actions in [-1.0, 1.0]."""
    def __init__(self, seed=None):
        if seed is not None:
            np.random.seed(seed)

    def act(self, obs):
        return np.random.uniform(-1.0, 1.0, size=2).astype(np.float32)

class HeuristicPolicy:
    """
    Artificial Potential Field (APF) reactive controller.
    Computes attractive force towards goal and repulsive forces from proximity rays.
    """
    def __init__(self):
        # Ray angles corresponding to 8 distance sensor rays
        self.angles = [-1.5708, -1.0472, -0.5236, -0.1745, 0.1745, 0.5236, 1.0472, 1.5708]
        self.d_safe = 1.2

    def act(self, obs):
        goal_angle = obs[15] * math.pi  # body frame heading to goal
        
        # Attractive force
        f_att_x = math.cos(goal_angle) * 2.0
        f_att_y = math.sin(goal_angle) * 2.0
        
        # Repulsive force from obstacle distance rays
        f_rep_x = 0.0
        f_rep_y = 0.0
        min_dist = 4.0
        
        for i, a in enumerate(self.angles):
            # obs[0..7] in [-1.0, 1.0], mapped from [0, 4]m -> d = (obs + 1) * 2
            d = (obs[i] + 1.0) * 2.0
            if d < min_dist:
                min_dist = d
            if 0.05 < d < self.d_safe:
                mag = (1.0 / d - 1.0 / self.d_safe) / (d * d)
                f_rep_x -= mag * math.cos(a) * 0.4
                f_rep_y -= mag * math.sin(a) * 0.4
                
        f_tot_x = f_att_x + f_rep_x
        f_tot_y = f_att_y + f_rep_y
        
        desired_yaw = math.atan2(f_tot_y, f_tot_x)
        turn_cmd = float(np.clip(desired_yaw * 1.5, -1.0, 1.0))
        
        # Confident forward drive unless obstacle is close or turning sharply
        speed_cmd = 0.6 if min_dist > 0.8 else (0.2 if min_dist > 0.4 else -0.3)
        if abs(turn_cmd) > 0.6:
            speed_cmd = min(speed_cmd, 0.3)
            
        return np.array([speed_cmd, turn_cmd], dtype=np.float32)
