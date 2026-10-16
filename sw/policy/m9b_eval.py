"""M9b evaluation of one policy on one environment variant over a fixed seed range.
Usage: m9b_eval.py POLICY ENV START N [OUT.json]
POLICY: rl1..rl5 (frozen ARS state in m6_state/, applied to IL-base weights exactly as m6_eval.py),
        il_base (trained_policy_weights.json), il101..il105 (m9b_models/il_seedNNN.json raw_float).
ENV: A|B|C. Every policy: INT8 requantised with the m6 recipe (calibration = 100 steps of its own
float rollout in unmodified env A, episode seed 1; never environment-specific), safety filter ON.
Writes per-episode records (succ, coll, timeout, steps, path_len, reward, interv, clear)."""
import sys, json, os, time
from m6_common import *
from robot_env_m9b import RobotEnvM9b

def load_float(tag):
    base = json.load(open(os.path.join(HERE, "trained_policy_weights.json")))["raw_float"]
    if tag.startswith("il") and tag != "il_base":
        base = json.load(open(os.path.join(HERE, f"m9b_models/il_seed{tag[2:]}.json")))["raw_float"]
    p = {k: np.array(v, dtype=np.float32) for k, v in base.items()}
    if tag.startswith("rl"):
        th = np.load(os.path.join(HERE, f"m6_state/ars_seed{tag[2:]}.npz"))["theta"]; i = 0
        for k in ["w1", "b1", "w2", "b2"]:
            n = p[k].size; p[k] = th[i:i+n].reshape(p[k].shape).astype(np.float32); i += n
    return p

def build_q(p):
    env = RobotEnv2D(); o = env.reset(seed=1); X = []
    for _ in range(100): X.append(o); o, *_ = env.step(forward_float(p, o))
    return quantize(p, X)

def run(tag, variant, start, n):
    q = build_q(load_float(tag)); env = RobotEnvM9b(variant, max_steps=150); eps = []
    for s in range(start, start + n):
        r = rollout(env, lambda o: int8_act(q, o), s, True)
        r["seed"] = s; r["timeout"] = not r["succ"] and not r["coll"]; r["path_len"] = env.path_len
        eps.append(r)
    return eps

if __name__ == "__main__":
    tag, variant, start, n = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    t0 = time.time(); eps = run(tag, variant, start, n); dt = time.time() - t0
    out = {"policy": tag, "env": variant, "seed_start": start, "n": n, "wall_s": dt, "episodes": eps}
    if len(sys.argv) > 5: json.dump(out, open(sys.argv[5], "w"))
    k = sum(e["succ"] for e in eps); c = sum(e["coll"] for e in eps)
    print(f"{tag} {variant} n={n} succ={k} coll={c} timeout={n-k-c} wall={dt:.1f}s ({dt/n:.3f}s/ep)")
