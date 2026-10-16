"""M10a timeout diagnosis (simulation only). Diagnostic seeds 70000.. (disjoint from M9b held-out 60000..60399 and training).
Usage: m10a_diag.py N OUT.json. Policies il101, rl1; envs A,B,C; filter on/off; max_steps 150 and 300.
Per episode: outcome, final/min goal distance, mean commanded v, fraction of steps with realised v<0.05,
intervention fraction, net displacement over last 50 steps (stuck/oscillation indicator)."""
import sys, json, time, math
from m6_common import *
from m9b_eval import load_float, build_q
from robot_env_m9b import RobotEnvM9b

def ep(env, q, seed, filt):
    obs = env.reset(seed=seed); flt = make_filter(env); flt.reset()
    d0 = math.hypot(env.goal_x-env.x, env.goal_y-env.y); mind = d0; pos = []; slow = 0; iv = 0; info = {}
    for t in range(env.max_steps):
        a = int8_act(q, obs)
        if filt:
            v = max(0.0, 0.5*(float(a[0])+1.0))*env.v_max; w = float(a[1])*env.w_max
            vs, ws, why = flt.filter_action(v, w, min(env.latest_hits))
            if why != "NORMAL": iv += 1
            a = np.array([2.0*vs/env.v_max-1.0, ws/env.w_max])
        obs, r, done, info = env.step(a)
        gd = math.hypot(env.goal_x-env.x, env.goal_y-env.y); mind = min(mind, gd); pos.append((env.x, env.y))
        if env.v < 0.05: slow += 1
        if done: break
    n = len(pos); k = min(50, n-1)
    disp = math.hypot(pos[-1][0]-pos[-1-k][0], pos[-1][1]-pos[-1-k][1]) if k > 0 else 0.0
    return dict(succ=bool(info["success"]), coll=bool(info["collision"]), steps=n, d0=d0, dfin=gd, dmin=mind,
                slow=slow/n, interv=iv/n, disp_last=disp, path=env.path_len)

if __name__ == "__main__":
    N = int(sys.argv[1]); out = {}; t0 = time.time()
    for tag in ["il101", "rl1"]:
        q = build_q(load_float(tag))
        for e in "ABC":
            for filt in (True, False):
                for ms in (150, 300):
                    env = RobotEnvM9b(e, max_steps=ms)
                    out[f"{tag}|{e}|{'F' if filt else 'N'}|{ms}"] = [ep(env, q, s, filt) for s in range(70000, 70000+N)]
        print(tag, "done", round(time.time()-t0), "s", flush=True)
    json.dump(out, open(sys.argv[2], "w"))
