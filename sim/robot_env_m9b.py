"""M9b evaluation environments (simulation only). Same 16-D obs / 2-D action as RobotEnv2D.
Fixed before any M9b run; see docs/30_m9b_protocol.md.
  A: RobotEnv2D unchanged (4 pillars r=0.5).
  B: 1.5x obstacles = 6 pillars: the 4 originals + 2 extra r=0.5 at (0,+2.4),(0,-2.4). Layout fixed;
     start/goal sampling is the parent's rejection rule (robot clear of obstacles by +0.2, goal by +0.15,
     start-goal >= 3.0 m), random only through the episode seed.
  C: B + range noise (Gaussian sigma 0.05 m, clipped to [0, d_max], no dropout) + actuator gain:
     per-episode v_gain, w_gain ~ U(0.9, 1.1) independent, applied
     on the realised plant motion (v_realised = v*vg, w_realised = w*wg; commanded state/odometry nominal).
     Noise/gain use a private RandomState(seed + 1_000_000),
     so start/goal draws are identical across A/B/C-style resets for the same seed stream logic.
The safety filter sees nominal commands and true (noisy) range readings; it is not told the gain."""
import math
import numpy as np
from robot_env import RobotEnv2D

class RobotEnvM9b(RobotEnv2D):
    def __init__(self, variant="A", max_steps=150, dt=0.1):
        assert variant in ("A", "B", "C")
        self.variant = variant
        self._rs = np.random.RandomState(0); self.vg = self.wg = 1.0
        super().__init__(max_steps, dt)
        if variant in ("B", "C"):
            self.obstacles = list(self.obstacles) + [(0.0, 2.4, 0.5, 0.25), (0.0, -2.4, 0.5, 0.25)]
        self.path_len = 0.0

    def reset(self, seed=None):
        if seed is not None:
            self._rs = np.random.RandomState(seed + 1_000_000)
        if self.variant == "C":
            self.vg = self._rs.uniform(0.9, 1.1); self.wg = self._rs.uniform(0.9, 1.1)
        else:
            self.vg = self.wg = 1.0
        self.path_len = 0.0
        return super().reset(seed)

    def _raycast(self):
        h = super()._raycast()
        if self.variant != "C": return h
        return [float(min(max(v + self._rs.randn() * 0.05, 0.0), self.d_max_sensor)) for v in h]

    def step(self, action):
        """Same as RobotEnv2D.step, except in C the *realised* motion uses v*vg and w*wg (actuator gain
        on the plant; the internal commanded state self.v/self.w, and hence odometry/IMU obs, are nominal).
        Variants A/B delegate to the parent unchanged."""
        x0, y0 = self.x, self.y
        if self.variant != "C":
            out = super().step(action)
        else:
            self.step_count += 1
            av = float(min(max(action[0], -1.0), 1.0)); aw = float(min(max(action[1], -1.0), 1.0))
            tv = max(0.0, 0.5 * (av + 1.0)) * self.v_max; tw = aw * self.w_max
            dv = tv - self.v
            self.v += 0.2 if dv > 0.2 else (-0.2 if dv < -0.2 else dv)
            dw = tw - self.w
            self.w += 0.4 if dw > 0.4 else (-0.4 if dw < -0.4 else dw)
            ve, we = self.v * self.vg, self.w * self.wg
            self.x += ve * math.cos(self.theta) * self.dt
            self.y += ve * math.sin(self.theta) * self.dt
            self.theta = (self.theta + we * self.dt + math.pi) % (2.0 * math.pi) - math.pi
            gd = math.hypot(self.goal_x - self.x, self.goal_y - self.y)
            progress = self.prev_dist - gd; self.prev_dist = gd
            reward = 15.0 * progress - 0.05
            obs = self._get_obs()
            info = {'success': False, 'collision': False, 'timeout': False}; done = False
            if self._check_collision(self.x, self.y): reward -= 50.0; done = True; info['collision'] = True
            elif gd < self.goal_radius: reward += 100.0; done = True; info['success'] = True
            elif self.step_count >= self.max_steps: done = True; info['timeout'] = True
            out = (obs, reward, done, info)
        self.path_len += math.hypot(self.x - x0, self.y - y0)
        return out
