"""Harder variant of RobotEnv2D (same 16-D obs / 2-D action, so same firmware/weights apply).
Changes: 8 pillars (4 original + 4 extra, incl. 2 narrow-gap pairs), radius 0.6 on the originals,
Gaussian range noise (sigma 0.05 m), 3% per-ray dropout (reads max range), goal >= 4 m away,
max_steps 150. Obstacle layout fixed; randomness only from the seed."""
import math, numpy as np
from robot_env import RobotEnv2D

class RobotEnvHard(RobotEnv2D):
    def __init__(self, max_steps=150, dt=0.1, noise=0.05, dropout=0.03):
        self.noise, self.dropout = noise, dropout
        super().__init__(max_steps, dt)
        self.obstacles = [(x, y, r, r*r) for x, y, r in [
            (1.5, 1.5, 0.6), (-1.5, 1.5, 0.6), (1.5, -1.5, 0.6), (-1.5, -1.5, 0.6),
            (0.0, 0.8, 0.35), (0.0, -0.8, 0.35), (2.6, 0.0, 0.35), (-2.6, 0.0, 0.35)]]
        self.noise, self.dropout = noise, dropout

    def reset(self, seed=None):
        # parent reset spawns with >=3 m; retry to enforce >=4 m using the same RNG stream
        o = super().reset(seed)
        for _ in range(200):
            if math.hypot(self.goal_x - self.x, self.goal_y - self.y) >= 4.0: break
            o = super().reset(None)
        return self._get_obs()

    def _raycast(self):
        h = super()._raycast()
        out = []
        for v in h:
            if np.random.rand() < self.dropout: v = self.d_max_sensor
            else: v = min(max(v + np.random.randn() * self.noise, 0.0), self.d_max_sensor)
            out.append(v)
        return out
