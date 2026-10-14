"""M6: RL fine-tuning (Augmented Random Search, pure NumPy) starting from the IL policy.
Usage: m6_rl_ars.py SEED ITERS   (resumable; state in sw/policy/m6_state/ars_seed<N>.npz)
Reward = env return with the safety filter in the loop. Training episode seeds (2000+) are
disjoint from held-out eval seeds (50000+)."""
import sys, os, json, time
from m6_common import *
N_DIR, EPS, SIGMA, LR, TOP = 8, 6, 0.03, 0.02, 4
KEYS = ["w1", "b1", "w2", "b2"]
def flat(p): return np.concatenate([p[k].ravel() for k in KEYS])
def unflat(v, ref):
    out, i = {}, 0
    for k in KEYS:
        n = ref[k].size; out[k] = v[i:i+n].reshape(ref[k].shape).astype(np.float32); i += n
    return out
def score(v, ref, seeds):
    p = unflat(v, ref); env = RobotEnv2D(max_steps=150)
    return float(np.mean([rollout(env, lambda o: forward_float(p, o), s)["reward"] for s in seeds]))
def main():
    seed, iters = int(sys.argv[1]), int(sys.argv[2])
    d = os.path.join(HERE, "m6_state"); os.makedirs(d, exist_ok=True)
    path = os.path.join(d, f"ars_seed{seed}.npz")
    j = json.load(open(os.path.join(HERE, "trained_policy_weights.json")))["raw_float"]
    ref = {k: np.array(v, dtype=np.float32) for k, v in j.items()}
    if os.path.exists(path):
        z = np.load(path); theta, it = z["theta"], int(z["it"])
    else: theta, it = flat(ref), 0
    t0 = time.time()
    for _ in range(iters):
        rng = np.random.RandomState(seed * 100003 + it)
        eps_seeds = [2000 + rng.randint(0, 5000) for _ in range(EPS)]
        deltas = rng.randn(N_DIR, theta.size)
        rp = np.array([score(theta + SIGMA * dl, ref, eps_seeds) for dl in deltas])
        rm = np.array([score(theta - SIGMA * dl, ref, eps_seeds) for dl in deltas])
        idx = np.argsort(-np.maximum(rp, rm))[:TOP]
        sd = np.concatenate([rp[idx], rm[idx]]).std() + 1e-8
        theta = theta + LR / (TOP * sd) * sum((rp[i] - rm[i]) * deltas[i] for i in idx)
        it += 1
        np.savez(path, theta=theta, it=it)
        print(f"seed {seed} it {it} mean_r {np.mean(np.r_[rp,rm]):.2f} t={time.time()-t0:.0f}s", flush=True)
if __name__ == "__main__": main()
