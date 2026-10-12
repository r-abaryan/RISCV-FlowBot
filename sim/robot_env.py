"""
Lightweight 2D Mobile Robot Simulation Environment for RISC-V Neural SoC
Pure Python / NumPy implementation designed for headless execution under tight RAM/CPU limits.
Matches 16-feature INT8 input space and differential drive kinematics.
"""

import math
import numpy as np

class RobotEnv2D:
    def __init__(self, max_steps=150, dt=0.1):
        self.arena = (-3.5, 3.5, -3.5, 3.5)
        # 4 circular obstacle pillars (x, y, radius, radius^2)
        self.obstacles = [
            ( 1.5,  1.5, 0.5, 0.25),
            (-1.5,  1.5, 0.5, 0.25),
            ( 1.5, -1.5, 0.5, 0.25),
            (-1.5, -1.5, 0.5, 0.25)
        ]
        self.robot_radius = 0.25
        self.goal_radius = 0.35
        self.dt = dt
        self.max_steps = max_steps
        
        self.d_max_sensor = 4.0
        self.d_max_goal = 7.0
        self.v_max = 0.8
        self.w_max = 1.5
        
        self.ray_angles = [
            -math.pi / 2, -math.pi / 3, -math.pi / 6, -math.pi / 18,
            math.pi / 18,  math.pi / 6,  math.pi / 3,  math.pi / 2
        ]
        self.ray_cos_sin = [(math.cos(a), math.sin(a)) for a in self.ray_angles]
        
        self.reset()

    def reset(self, seed=None):
        if seed is not None:
            np.random.seed(seed)
            
        self.step_count = 0
        self.v = 0.0
        self.w = 0.0
        
        # Spawn robot in safe location
        for _ in range(50):
            rx = np.random.uniform(-2.7, 2.7)
            ry = np.random.uniform(-2.7, 2.7)
            if not self._check_collision(rx, ry, extra=0.2):
                break
        self.x = rx
        self.y = ry
        self.theta = np.random.uniform(-math.pi, math.pi)

        # Spawn goal at least 3.0m away from robot
        for _ in range(50):
            gx = np.random.uniform(-2.7, 2.7)
            gy = np.random.uniform(-2.7, 2.7)
            if not self._check_collision(gx, gy, extra=0.15):
                if math.hypot(gx - rx, gy - ry) >= 3.0:
                    break
        self.goal_x = gx
        self.goal_y = gy
        self.prev_dist = math.hypot(self.goal_x - self.x, self.goal_y - self.y)
        
        return self._get_obs()

    def _check_collision(self, x, y, extra=0.0):
        r = self.robot_radius + extra
        if x - r < self.arena[0] or x + r > self.arena[1] or y - r < self.arena[2] or y + r > self.arena[3]:
            return True
        for cx, cy, cr, cr2 in self.obstacles:
            if (x - cx)**2 + (y - cy)**2 < (cr + r)**2:
                return True
        return False

    def _raycast(self):
        cos_t = math.cos(self.theta)
        sin_t = math.sin(self.theta)
        hits = [self.d_max_sensor] * 8
        
        for i, (rcos, rsin) in enumerate(self.ray_cos_sin):
            dx = cos_t * rcos - sin_t * rsin
            dy = sin_t * rcos + cos_t * rsin
            h = self.d_max_sensor
            
            # Arena boundaries
            if dx > 1e-5:
                tx = (self.arena[1] - self.x) / dx
                if 0 < tx < h: h = tx
            elif dx < -1e-5:
                tx = (self.arena[0] - self.x) / dx
                if 0 < tx < h: h = tx
            if dy > 1e-5:
                ty = (self.arena[3] - self.y) / dy
                if 0 < ty < h: h = ty
            elif dy < -1e-5:
                ty = (self.arena[2] - self.y) / dy
                if 0 < ty < h: h = ty
                
            # Circular obstacle pillars
            for cx, cy, cr, cr2 in self.obstacles:
                dpx = cx - self.x
                dpy = cy - self.y
                t_proj = dpx * dx + dpy * dy
                if t_proj > 0:
                    d_perp2 = (dpx*dpx + dpy*dpy) - t_proj*t_proj
                    if d_perp2 < cr2:
                        t_hit = t_proj - math.sqrt(cr2 - d_perp2)
                        if 0 < t_hit < h: h = t_hit
            hits[i] = h
        return hits

    def _get_obs(self):
        obs = np.empty(16, dtype=np.float32)
        hits = self._raycast()
        self.latest_hits = hits
        
        # 0..7: 8 Distance sensors normalized to [-1.0, 1.0]
        for i in range(8):
            obs[i] = hits[i] * 0.5 - 1.0  # [0.0, 4.0] -> [-1.0, 1.0]

        # 8..10: IMU (ax=0, ay=v*w, wz=w)
        obs[8] = 0.0
        obs[9] = min(max((self.v * self.w) / 1.5, -1.0), 1.0)
        obs[10] = min(max(self.w / self.w_max, -1.0), 1.0)

        # 11..13: Odometry (v, vy=0, w)
        obs[11] = min(max(2.0 * (self.v / self.v_max) - 1.0, -1.0), 1.0)
        obs[12] = 0.0
        obs[13] = obs[10]

        # 14..15: Goal relative distance and heading
        dx = self.goal_x - self.x
        dy = self.goal_y - self.y
        g_dist = math.hypot(dx, dy)
        obs[14] = min(max(2.0 * (min(g_dist, self.d_max_goal) / self.d_max_goal) - 1.0, -1.0), 1.0)
        
        target_angle = math.atan2(dy, dx)
        angle_diff = (target_angle - self.theta + math.pi) % (2.0 * math.pi) - math.pi
        obs[15] = angle_diff / math.pi
        
        return obs

    def step(self, action):
        self.step_count += 1
        av = float(min(max(action[0], -1.0), 1.0))
        aw = float(min(max(action[1], -1.0), 1.0))
        
        # Convert continuous action to target velocities
        target_v = max(0.0, 0.5 * (av + 1.0)) * self.v_max
        target_w = aw * self.w_max
        
        # Acceleration limits
        dv = target_v - self.v
        if dv > 0.2: self.v += 0.2
        elif dv < -0.2: self.v -= 0.2
        else: self.v = target_v
        
        dw = target_w - self.w
        if dw > 0.4: self.w += 0.4
        elif dw < -0.4: self.w -= 0.4
        else: self.w = target_w
        
        # Integrate differential drive kinematics
        self.x += self.v * math.cos(self.theta) * self.dt
        self.y += self.v * math.sin(self.theta) * self.dt
        self.theta = (self.theta + self.w * self.dt + math.pi) % (2.0 * math.pi) - math.pi
        
        goal_dist = math.hypot(self.goal_x - self.x, self.goal_y - self.y)
        progress = self.prev_dist - goal_dist
        self.prev_dist = goal_dist
        
        reward = 15.0 * progress - 0.05
        
        obs = self._get_obs()
        min_front = min(self.latest_hits[2:6])
        if min_front < 0.8:
            reward -= 2.0 * (0.8 - min_front)
            
        done = False
        info = {'success': False, 'collision': False, 'timeout': False}
        
        if self._check_collision(self.x, self.y):
            reward -= 50.0
            done = True
            info['collision'] = True
        elif goal_dist < self.goal_radius:
            reward += 100.0
            done = True
            info['success'] = True
        elif self.step_count >= self.max_steps:
            done = True
            info['timeout'] = True
            
        return obs, reward, done, info
