"""M6 shared: INT8 requantization of float MLP, safety-filtered rollout, Wilson interval."""
import os, sys, math, json
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path += [os.path.join(HERE, '../../sim'), os.path.join(HERE, '../model'), os.path.join(HERE, '../safety')]
from robot_env import RobotEnv2D
from reference_model import quantize_layer, ACT_RELU, ACT_CLIP
from safety_layer import DeterministicSafetyFilter

def forward_float(p, x):
    h = np.maximum(0.0, p["w1"] @ x + p["b1"])
    return np.clip(p["w2"] @ h + p["b2"], -1.0, 1.0)

def quantize(p, X):
    """Same scheme as train_policy.py (range-aware, symmetric, shift 15). X: calibration obs."""
    X = np.asarray(X, dtype=np.float32)
    H1 = np.maximum(0.0, X @ p["w1"].T + p["b1"])
    max_h1 = float(np.percentile(H1, 99.9)) + 0.05
    sw1 = 127.0 / (np.max(np.abs(p["w1"])) + 1e-7)
    sw2 = 127.0 / (np.max(np.abs(p["w2"])) + 1e-7)
    sh1 = 127.0 / max_h1
    S = 15
    return {
        "w1": np.clip(np.round(p["w1"] * sw1), -128, 127).astype(int).tolist(),
        "b1": np.round(p["b1"] * sw1 * 127.0).astype(int).tolist(),
        "m1": int(round(1.0 / (sw1 * max_h1) * (1 << S))),
        "w2": np.clip(np.round(p["w2"] * sw2), -128, 127).astype(int).tolist(),
        "b2": np.round(p["b2"] * sw2 * sh1).astype(int).tolist(),
        "m2": int(round(max_h1 / sw2 * (1 << S))), "S": S}

def int8_act(q, obs):
    x = [int(np.clip(round(v * 127.0), -128, 127)) for v in obs]
    h, _ = quantize_layer(x, q["w1"], q["b1"], q["m1"], q["S"], ACT_RELU)
    o, _ = quantize_layer(h, q["w2"], q["b2"], q["m2"], q["S"], ACT_CLIP)
    return np.array([o[0] / 127.0, o[1] / 127.0], dtype=np.float32)

def make_filter(env):
    # d_margin includes robot radius because rays start at the robot centre
    return DeterministicSafetyFilter(v_max=env.v_max, w_max=env.w_max, a_max=2.0,
                                     alpha_max=4.0, d_margin=env.robot_radius + 0.15,
                                     a_brake=1.5, dt=env.dt)

def rollout(env, act_fn, seed, use_filter=True):
    obs = env.reset(seed=seed)
    flt = make_filter(env); flt.reset()
    tot = 0.0; interv = 0; steps = 0; clear = 1e9
    info = {"success": False, "collision": False}
    for _ in range(env.max_steps):
        a = act_fn(obs)
        if use_filter:
            v = max(0.0, 0.5 * (float(a[0]) + 1.0)) * env.v_max
            w = float(a[1]) * env.w_max
            vs, ws, why = flt.filter_action(v, w, min(env.latest_hits))
            if why != "NORMAL": interv += 1
            a = np.array([2.0 * vs / env.v_max - 1.0, ws / env.w_max])
        obs, r, done, info = env.step(a)
        tot += r; steps += 1
        clear = min(clear, min(env.latest_hits) - env.robot_radius)
        if done: break
    return {"succ": bool(info["success"]), "coll": bool(info["collision"]),
            "reward": tot, "interv": interv, "steps": steps, "clear": clear}

def wilson(k, n, z=1.96):
    if n == 0: return (0.0, 0.0)
    p = k / n; d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (c - h, c + h)

def evaluate(act_fn, seeds, use_filter=True):
    env = RobotEnv2D(max_steps=150)
    rs = [rollout(env, act_fn, s, use_filter) for s in seeds]
    n = len(rs); ks = sum(r["succ"] for r in rs); kc = sum(r["coll"] for r in rs)
    kt = n - ks - kc
    steps = sum(r["steps"] for r in rs)
    return {"n": n, "succ": ks / n, "succ_ci": wilson(ks, n), "coll": kc / n,
            "timeout": kt / n, "reward": float(np.mean([r["reward"] for r in rs])),
            "interv_rate": sum(r["interv"] for r in rs) / max(1, steps),
            "clear_p5": float(np.percentile([r["clear"] for r in rs], 5))}
