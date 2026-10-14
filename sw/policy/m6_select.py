"""Select RL seed on a VALIDATION seed set (10000..10199; disjoint from train 2000..6999 and test 50000..50199). Usage: m6_select.py TAG"""
import sys, json, os
from m6_common import *
tag = sys.argv[1]
j = json.load(open(os.path.join(HERE, "trained_policy_weights.json")))["raw_float"]
p = {k: np.array(v, dtype=np.float32) for k, v in j.items()}
if tag != "il":
    th = np.load(os.path.join(HERE, f"m6_state/ars_seed{tag}.npz"))["theta"]; i = 0
    for k in ["w1","b1","w2","b2"]:
        n = p[k].size; p[k] = th[i:i+n].reshape(p[k].shape).astype(np.float32); i += n
env = RobotEnv2D(); o = env.reset(seed=1); X = []
for _ in range(100): X.append(o); o, *_ = env.step(forward_float(p, o))
q = quantize(p, X)
res = evaluate(lambda o: int8_act(q, o), range(10000, 10200))
os.makedirs(os.path.join(HERE, "m6_val"), exist_ok=True)
json.dump(res, open(os.path.join(HERE, f"m6_val/{tag}.json"), "w"), indent=1)
print(tag, res["succ"], res["coll"], res["reward"])
