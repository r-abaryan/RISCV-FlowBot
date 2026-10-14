"""Evaluate IL baseline and RL seed1 (validation-selected) on RobotEnvHard, seeds 20000..20199 (disjoint from train/val/test)."""
import sys, json, os
from m6_common import *
from robot_env_hard import RobotEnvHard
which = sys.argv[1]; filt = sys.argv[2] == "filter"
j = json.load(open(os.path.join(HERE, "trained_policy_weights.json")))["raw_float"]
p = {k: np.array(v, dtype=np.float32) for k, v in j.items()}
if which != "il":
    th = np.load(os.path.join(HERE, f"m6_state/ars_seed{which}.npz"))["theta"]; i = 0
    for k in ["w1","b1","w2","b2"]:
        n = p[k].size; p[k] = th[i:i+n].reshape(p[k].shape).astype(np.float32); i += n
env = RobotEnv2D(); o = env.reset(seed=1); X = []
for _ in range(100): X.append(o); o, *_ = env.step(forward_float(p, o))
q = quantize(p, X)
henv = RobotEnvHard(); N = int(os.environ.get("N","200"))
rs = [rollout(henv, lambda o: int8_act(q, o), s, filt) for s in range(int(os.environ.get("S0","20000")), int(os.environ.get("S0","20000"))+N)]
ks = sum(r["succ"] for r in rs); kc = sum(r["coll"] for r in rs)
print(which, "filter" if filt else "nofilter", "S0", os.environ.get("S0","20000"), "N", N, "succ", ks, "coll", kc, "timeout", N-ks-kc)
