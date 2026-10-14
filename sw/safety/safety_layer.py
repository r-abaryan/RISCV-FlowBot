#!/usr/bin/env python3
"""
Deterministic Safety Layer Reference Implementation
Enforces strict mathematical bounds on unverified neural policy outputs.
"""

import math

class DeterministicSafetyFilter:
    def __init__(self, 
                 v_max=0.5,           # Max linear velocity (m/s)
                 w_max=2.0,           # Max angular velocity (rad/s)
                 a_max=1.0,           # Max linear acceleration (m/s^2)
                 alpha_max=4.0,       # Max angular acceleration (rad/s^2)
                 d_margin=0.15,       # Safety stop bubble (meters)
                 a_brake=1.5,         # Emergency deceleration capacity (m/s^2)
                 dt=0.01):            # Control period (seconds)
        self.v_max = v_max
        self.w_max = w_max
        self.a_max = a_max
        self.alpha_max = alpha_max
        self.d_margin = d_margin
        self.a_brake = a_brake
        self.dt = dt

        # State tracking
        self.v_prev = 0.0
        self.w_prev = 0.0
        self.heartbeat_counter = 0
        self.watchdog_timeout = 5  # Max allowed missed cycles

    def reset(self):
        self.v_prev = 0.0
        self.w_prev = 0.0
        self.heartbeat_counter = 0

    def calculate_stopping_distance(self, v):
        """Calculates kinematic stopping distance with brake capacity."""
        if v <= 0.0:
            return self.d_margin
        return self.d_margin + (v * v) / (2.0 * self.a_brake)

    def filter_action(self, v_raw, w_raw, min_obstacle_dist, inference_ok=True):
        """
        Takes raw unverified neural outputs and sensor distances,
        returns guaranteed safe motor commands.
        """
        # Rule -1 (M5): invalid distance reading (NaN/inf/negative) => treat as contact
        if not math.isfinite(min_obstacle_dist) or min_obstacle_dist < 0.0:
            min_obstacle_dist = 0.0

        # Rule 0: Watchdog check
        if not inference_ok:
            self.v_prev = 0.0
            self.w_prev = 0.0
            return 0.0, 0.0, "FAILSAFE_WATCHDOG_TIMEOUT"

        # Rule 1: Kinematic Envelope Clamping
        v_c1 = max(-self.v_max, min(self.v_max, v_raw))
        w_c1 = max(-self.w_max, min(self.w_max, w_raw))

        # Rule 2: Acceleration Slew-Rate Limiting
        dv_max = self.a_max * self.dt
        dw_max = self.alpha_max * self.dt

        dv = max(-dv_max, min(dv_max, v_c1 - self.v_prev))
        dw = max(-dw_max, min(dw_max, w_c1 - self.w_prev))

        v_c2 = self.v_prev + dv
        w_c2 = self.w_prev + dw

        # Rule 3: Obstacle Proximity & Dynamic Braking (TTC)
        d_stop = self.calculate_stopping_distance(v_c2)
        override_reason = "NORMAL"

        if min_obstacle_dist <= self.d_margin:
            # Emergency Stop / Obstacle violation: Prevent forward drive
            v_safe = min(0.0, v_c2)
            w_safe = w_c2
            override_reason = "CRITICAL_OBSTACLE_BRAKE"
        elif min_obstacle_dist < d_stop:
            # Proportional dynamic braking
            scale = (min_obstacle_dist - self.d_margin) / (d_stop - self.d_margin)
            scale = max(0.0, min(1.0, scale))
            v_safe = v_c2 * scale
            w_safe = w_c2
            override_reason = "DYNAMIC_TTC_BRAKING"
        else:
            v_safe = v_c2
            w_safe = w_c2

        # Rule 4 (M5): never step past the margin within one control period
        if v_safe > 0.0:
            v_safe = min(v_safe, max(0.0, min_obstacle_dist - self.d_margin) / self.dt)

        # Update historical state
        self.v_prev = v_safe
        self.w_prev = w_safe

        return v_safe, w_safe, override_reason

if __name__ == "__main__":
    filter_mod = DeterministicSafetyFilter(dt=0.02)  # 50 Hz loop

    print("--- Test 1: Out-of-bounds speed command ---")
    v_out, w_out, reason = filter_mod.filter_action(v_raw=10.0, w_raw=20.0, min_obstacle_dist=2.0)
    print(f"Raw: [10.0, 20.0] -> Safe: [{v_out:.3f}, {w_out:.3f}] (Reason: {reason})")
    assert v_out <= 0.5 and w_out <= 2.0

    print("\n--- Test 2: Acceleration limiting across consecutive steps ---")
    filter_mod.reset()
    for step in range(5):
        v_out, w_out, reason = filter_mod.filter_action(v_raw=0.5, w_raw=0.0, min_obstacle_dist=2.0)
        print(f"Step {step+1}: v_safe={v_out:.3f} m/s")
    assert v_out < 0.5  # Gradually ramped up

    print("\n--- Test 3: Emergency obstacle brake ---")
    # Robot approaching wall at 0.4 m/s, suddenly obstacle at 0.10 m (below d_margin 0.15 m)
    v_out, w_out, reason = filter_mod.filter_action(v_raw=0.5, w_raw=0.0, min_obstacle_dist=0.10)
    print(f"Obstacle at 0.10m -> v_safe={v_out:.3f} m/s (Reason: {reason})")
    assert v_out <= 0.0

    print("\n--- Test 4: Inference watchdog failure ---")
    v_out, w_out, reason = filter_mod.filter_action(v_raw=0.5, w_raw=0.0, min_obstacle_dist=2.0, inference_ok=False)
    print(f"Inference Timeout -> v_safe={v_out:.3f} m/s (Reason: {reason})")
    assert v_out == 0.0 and w_out == 0.0

    print("\nAll deterministic safety checks successfully verified!")
