"""Resumable M9b full-study runner. Frozen protocol: docs/30_m9b_protocol.md. No retries, no protocol changes.
Usage: m9b_study.py [CALL_LIMIT_S=450]. Unit = (policy, env, 50 consecutive seeds in 60000..60399).
Existing unit file => skipped. Cumulative study runtime cap 200 min (ledger); stops before exceeding it."""
import sys, os, json, time, hashlib
import numpy as np
from m9b_eval import run, load_float, build_q, HERE
POLICIES = ["rl1","rl2","rl3","rl4","rl5","il_base","il101","il102","il103","il104","il105"]
ENVS = ["A","B","C"]; S0, N, CH = 60000, 400, 50
CAP_S = 200*60; OUT = os.path.join(HERE, "../../results/m9b/study"); LED = os.path.join(HERE, "../../results/m9b/ledger.jsonl")
def sha(path): return hashlib.sha256(open(path,"rb").read()).hexdigest()
def src_file(tag):
    if tag == "il_base": return "trained_policy_weights.json"
    if tag.startswith("il"): return f"m9b_models/il_seed{tag[2:]}.json"
    return f"m6_state/ars_seed{tag[2:]}.npz"
def units(): return [(p,e,S0+i) for p in POLICIES for e in ENVS for i in range(0,N,CH)]
def upath(u): return os.path.join(OUT, f"{u[0]}_{u[1]}_{u[2]}.json")
def spent():
    t = 0.0
    for l in open(LED):
        r = json.loads(l)
        t += r.get("wall_s", 0)  # conservative: all logged work counts
    return t
if __name__ == "__main__":
    lim = float(sys.argv[1]) if len(sys.argv) > 1 else 450; t_call = time.time(); os.makedirs(OUT, exist_ok=True)
    code_h = {f: sha(os.path.join(HERE, f)) for f in ["m9b_eval.py","m6_common.py","../../sim/robot_env_m9b.py","../../sim/robot_env.py","m9b_study.py"]}
    done = 0; worst = 0.0
    for u in units():
        if os.path.exists(upath(u)): continue
        el = time.time() - t_call
        if el + max(60, 1.5*worst) > lim: print("call time limit; stopping"); break
        if spent() + 90 > CAP_S: print("BUDGET CAP reached; stopping"); sys.exit(2)
        t0 = time.time(); p, e, s = u
        q = build_q(load_float(p)); eps = run(p, e, s, CH); dt = time.time() - t0
        rec = {"policy": p, "env": e, "seed_start": s, "n": CH, "wall_s": dt, "weights_src": src_file(p),
               "weights_src_sha256": sha(os.path.join(HERE, src_file(p))), "q_sha256": hashlib.sha256(json.dumps(q, sort_keys=True).encode()).hexdigest(),
               "code_sha256": code_h, "numpy": np.__version__, "episodes": eps}
        json.dump(rec, open(upath(u)+".tmp","w")); os.rename(upath(u)+".tmp", upath(u))
        open(LED,"a").write(json.dumps({"what":"study","unit":list(u),"wall_s":dt})+"\n")
        worst = max(worst, dt); done += 1
    rem = sum(1 for u in units() if not os.path.exists(upath(u)))
    print(f"units done this call {done}; remaining {rem}/{len(units())}; study spent {spent():.0f}s of {CAP_S}s")
