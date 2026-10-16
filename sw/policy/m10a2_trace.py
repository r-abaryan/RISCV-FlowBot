"""M10a-2: diagnostic per-step logging of the safety filter (observation only; no behaviour change).
Replays stalled filtered 150-step episodes from results/m10a/diag.json with the same seeds.
Usage: m10a2_trace.py [K_PER_CELL] [OUT.json]   (default K=4, subset = first K stalled timeouts per policy/env cell)
Stalled = timeout (no success/collision) with net displacement over last 50 steps < 0.5 m (as in M10a)."""
import sys, json, math, os
from m6_common import *
from m9b_eval import load_float, build_q
from robot_env_m9b import RobotEnvM9b
SEED0 = 70000
HERE = os.path.dirname(os.path.abspath(__file__))
DIAG = os.path.join(HERE, "../../results/m10a/diag.json")

def traced_ep(env, q, seed):
    """Identical control flow to m10a_diag.ep(filt=True); extra reads only (no RNG use, no state writes)."""
    obs = env.reset(seed=seed); flt = make_filter(env); flt.reset()
    d0 = math.hypot(env.goal_x-env.x, env.goal_y-env.y); mind = d0; pos = []; slow = 0; iv = 0; info = {}; log = []
    run = 0
    for t in range(env.max_steps):
        a = int8_act(q, obs)
        v = max(0.0, 0.5*(float(a[0])+1.0))*env.v_max; w = float(a[1])*env.w_max
        hits = min(env.latest_hits)
        vp, wp = flt.v_prev, flt.w_prev
        vs, ws, why = flt.filter_action(v, w, hits)
        if why != "NORMAL": iv += 1
        a = np.array([2.0*vs/env.v_max-1.0, ws/env.w_max])
        gd_before = math.hypot(env.goal_x-env.x, env.goal_y-env.y)
        obs, r, done, info = env.step(a)
        gd = math.hypot(env.goal_x-env.x, env.goal_y-env.y); mind = min(mind, gd); pos.append((env.x, env.y))
        if env.v < 0.05: slow += 1; run += 1
        else: run = 0
        log.append(dict(t=t, why=why, v_req=v, w_req=float(w), v_perm=float(vs), w_perm=float(ws), v_prev=float(vp),
                        min_hit=float(hits), min_ray=int(np.argmin(env.latest_hits)), d_margin=float(flt.d_margin), d_goal=gd, d_goal_delta=gd-gd_before,
                        v_real=float(env.v), stall_run=run))
        if done: break
    n = len(pos); k = min(50, n-1)
    disp = math.hypot(pos[-1][0]-pos[-1-k][0], pos[-1][1]-pos[-1-k][1]) if k > 0 else 0.0
    res = dict(succ=bool(info["success"]), coll=bool(info["collision"]), steps=n, d0=d0, dfin=gd, dmin=mind,
               slow=slow/n, interv=iv/n, disp_last=disp, path=env.path_len)
    return res, log

def select(K):
    d = json.load(open(DIAG)); sel = []
    for tag in ["il101", "rl1"]:
        for e in "ABC":
            eps = d[f"{tag}|{e}|F|150"]
            idx = [i for i, x in enumerate(eps) if not x["succ"] and not x["coll"] and x["disp_last"] < 0.5][:K]
            sel += [(tag, e, i, eps[i]) for i in idx]
    return sel

if __name__ == "__main__":
    K = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "../../results/m10a2/trace.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    qs = {t: build_q(load_float(t)) for t in ["il101", "rl1"]}
    rec = []; bad = 0
    for tag, e, i, ref in select(K):
        res, log = traced_ep(RobotEnvM9b(e, max_steps=150), qs[tag], SEED0+i)
        same = all(res[k] == ref[k] for k in ref)
        bad += (not same)
        print(tag, e, SEED0+i, "outcome-identical-to-M10a:", same, flush=True)
        rec.append(dict(policy=tag, env=e, seed=SEED0+i, identical=same, result=res, log=log))
    json.dump(rec, open(out, "w"))
    print("episodes", len(rec), "mismatches", bad)
    sys.exit(1 if bad else 0)
