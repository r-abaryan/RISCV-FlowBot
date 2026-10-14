#!/usr/bin/env python3
"""M7D: verify firmware front-sensor indices (d2..d5 = bytes 2,3 of word0 and 0,1 of word1,
little-endian packing of obs[0..7]) against robot_env.ray_angles, and the 403/256 cm scale
against the env's obs encoding (obs = hits*0.5-1, hits in [0,4] m, q = round(127*obs))."""
import os, sys, math
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../sim'))
from robot_env import RobotEnv2D
e = RobotEnv2D()
deg = [math.degrees(a) for a in e.ray_angles]
fw_front = [2, 3, 4, 5]                     # byte index within the 8-byte frame = obs index
assert all(abs(deg[i]) <= 30.01 for i in fw_front), deg
assert all(abs(deg[i]) >= 59.9 for i in (0, 1, 6, 7)), deg   # excluded sensors are lateral
# byte order: word0 byte k = obs[k], word1 byte k = obs[4+k]  -> d2,d3 = word0 bytes 2,3; d4,d5 = word1 bytes 0,1
# scale: exhaustive over all 256 q (including invalid -128)
worst = 0.0
for q in range(-127, 128):
    true_cm = (q/127.0 + 1.0) * 2.0 * 100.0          # obs=q/127 -> hits=(obs+1)*2 m
    fw_cm = ((q+127)*403) >> 8
    worst = max(worst, true_cm - fw_cm)
    assert fw_cm <= true_cm + 1e-9, q                  # firmware never overestimates distance
assert ((-128+127)*403 >> 8) < 0                        # invalid -> negative -> contact
print(f'ray angles(deg)={[round(d) for d in deg]}; front=obs[2..5]; max cm underestimate over all q={worst:.2f}; PASS')
