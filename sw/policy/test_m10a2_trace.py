"""Instrumentation must not change outcomes: traced replay == stored M10a result (all fields) and is deterministic."""
import m10a2_trace as T
from m9b_eval import load_float, build_q
from robot_env_m9b import RobotEnvM9b
sel = T.select(1)[:3]
assert len(sel) == 3
for tag, e, i, ref in sel:
    q = build_q(load_float(tag))
    r1, l1 = T.traced_ep(RobotEnvM9b(e, max_steps=150), q, T.SEED0+i)
    r2, l2 = T.traced_ep(RobotEnvM9b(e, max_steps=150), q, T.SEED0+i)
    assert r1 == r2 and l1 == l2, "non-deterministic"
    assert all(r1[k] == ref[k] for k in ref), (tag, e, i, r1, ref)
    assert len(l1) == r1["steps"]
print("PASS test_m10a2_trace (3 episodes identical to M10a, deterministic)")
