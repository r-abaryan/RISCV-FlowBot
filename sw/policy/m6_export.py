"""Export validation-selected RL seed (m6_val/*.json) to firmware include/header. Usage: m6_export.py SEED"""
import sys, os, json
from m6_common import *
import export_weights as ex  # run from repo root
tag = sys.argv[1]
j = json.load(open(os.path.join(HERE, "trained_policy_weights.json")))["raw_float"]
p = {k: np.array(v, dtype=np.float32) for k, v in j.items()}
th = np.load(os.path.join(HERE, f"m6_state/ars_seed{tag}.npz"))["theta"]; i = 0
for k in ["w1","b1","w2","b2"]:
    n = p[k].size; p[k] = th[i:i+n].reshape(p[k].shape).astype(np.float32); i += n
env = RobotEnv2D(); o = env.reset(seed=1); X = []
for _ in range(100): X.append(o); o, *_ = env.step(forward_float(p, o))
q = quantize(p, X)
d = {"l1": {"weights": q["w1"], "biases": q["b1"], "scale_mult": q["m1"], "scale_shift": q["S"], "act": 1},
     "l2": {"weights": q["w2"], "biases": q["b2"], "scale_mult": q["m2"], "scale_shift": q["S"], "act": 2}}
json.dump(d, open(os.path.join(HERE, f"rl_seed{tag}_policy.json"), "w"))
w = ex.load_weights(os.path.join(HERE, f"rl_seed{tag}_policy.json"))
ex.generate_asm_include("sw/firmware/nav_weights_trained.inc", *w)
ex.generate_c_header("sw/include/nav_weights_trained.h", *w)
ex.generate_asm_include("sw/firmware/nav_weights.inc", *w)
ex.generate_c_header("sw/include/nav_weights.h", *w)
