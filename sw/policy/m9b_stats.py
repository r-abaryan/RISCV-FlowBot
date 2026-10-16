"""M9b statistics exactly as fixed in docs/30_m9b_protocol.md. Functions are unit-tested in test_m9b_stats.py."""
import math, json, os, glob, sys
import numpy as np
def wilson(k, n, z=1.959964):
    p = k/n; d = 1+z*z/n; c = (p+z*z/(2*n))/d; h = z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))/d
    return (c-h, c+h)
def mcnemar_exact(b, c):
    n = b+c
    if n == 0: return 1.0
    k = min(b, c); p = sum(math.comb(n, i) for i in range(k+1))/2**n*2
    return min(1.0, p)
def paired_boot(x, y, reps=10000, seed=0):
    """x,y: 0/1 arrays on common episodes. Returns (diff, lo, hi) for mean(x)-mean(y), paired resampling."""
    x = np.asarray(x, float); y = np.asarray(y, float); d = x-y; n = len(d)
    rs = np.random.RandomState(seed); idx = rs.randint(0, n, size=(reps, n)); m = d[idx].mean(1)
    return float(d.mean()), float(np.percentile(m, 2.5)), float(np.percentile(m, 97.5))
def load(root):
    R = {}
    for f in glob.glob(os.path.join(root, "*.json")):
        r = json.load(open(f))
        for e in r["episodes"]: R.setdefault((r["policy"], r["env"]), {})[e["seed"]] = e
    return R
def coverage(R, policies, envs, s0=60000, n=400):
    bad = []
    for p in policies:
        for e in envs:
            d = R.get((p, e), {})
            if sorted(d) != list(range(s0, s0+n)): bad.append((p, e, len(d)))
    return bad
def main(root, out):
    pol = ["rl1","rl2","rl3","rl4","rl5","il_base","il101","il102","il103","il104","il105"]; envs = ["A","B","C"]
    R = load(root); S = list(range(60000, 60400)); L = []; summ = {"rates": {}, "paired": {}}
    L.append("# M9b results (simulation only; unadjusted, descriptive)\n\n## Rates (n=400, Wilson 95%)\n\n| env | policy | success | collision | timeout | mean path (succ) | mean path (all) |\n|---|---|---|---|---|---|---|")
    for e in envs:
        for p in pol:
            d = R[(p, e)]; ep = [d[s] for s in S]; n = 400
            k = sum(x["succ"] for x in ep); c = sum(x["coll"] for x in ep); t = n-k-c
            ps = [x["path_len"] for x in ep if x["succ"]]; pa = [x["path_len"] for x in ep]
            f = lambda v: f"{v/n:.3f} [{wilson(v,n)[0]:.3f},{wilson(v,n)[1]:.3f}]"
            L.append(f"| {e} | {p} | {f(k)} | {f(c)} | {f(t)} | {np.mean(ps) if ps else float('nan'):.2f} | {np.mean(pa):.2f} |")
            summ["rates"][f"{p}_{e}"] = {"succ": k, "coll": c, "timeout": t}
    L.append("\n## IL variance across seeds 101..105 (min / mean / max of per-seed rates)\n\n| env | success | collision |\n|---|---|---|")
    for e in envs:
        s = [np.mean([R[(p,e)][q]["succ"] for q in S]) for p in pol[6:]]; c = [np.mean([R[(p,e)][q]["coll"] for q in S]) for p in pol[6:]]
        L.append(f"| {e} | {min(s):.3f} / {np.mean(s):.3f} / {max(s):.3f} | {min(c):.3f} / {np.mean(c):.3f} / {max(c):.3f} |")
    L.append("\n## Paired: RL seed 1 minus IL (common seeds 60000..60399)\n\nb = RL only, c = IL only. Bootstrap: 10,000 paired resamples, RandomState(0). McNemar exact two-sided. Path: paired on episodes where both succeed.\n\n| env | IL | outcome | both | RL only | IL only | neither | diff [95% boot] | p | paired path diff (n) |\n|---|---|---|---|---|---|---|---|---|---|")
    for e in envs:
        for il in ["il101","il102","il103","il104","il105","il_base"]:
            for oc in ["succ", "coll"]:
                x = np.array([int(R[("rl1",e)][s][oc]) for s in S]); y = np.array([int(R[(il,e)][s][oc]) for s in S])
                b = int(((x==1)&(y==0)).sum()); c = int(((x==0)&(y==1)).sum()); both = int(((x==1)&(y==1)).sum()); ne = int(((x==0)&(y==0)).sum())
                dd, lo, hi = paired_boot(x, y); pv = mcnemar_exact(b, c)
                pl = "-"
                if oc == "succ":
                    cs = [s for s in S if R[("rl1",e)][s]["succ"] and R[(il,e)][s]["succ"]]
                    if cs: pl = f"{np.mean([R[('rl1',e)][s]['path_len']-R[(il,e)][s]['path_len'] for s in cs]):+.3f} ({len(cs)})"
                summ["paired"][f"{e}_{il}_{oc}"] = {"b": b, "c": c, "both": both, "neither": ne, "diff": dd, "lo": lo, "hi": hi, "p": pv}
                L.append(f"| {e} | {il} | {oc} | {both} | {b} | {c} | {ne} | {dd:+.3f} [{lo:+.3f},{hi:+.3f}] | {pv:.4g} | {pl} |")
    L.append("\n## Superiority rule (protocol): paired success interval excludes zero in the same direction in all three environments, per IL seed\n")
    for il in ["il101","il102","il103","il104","il105","il_base"]:
        sg = []
        for e in envs:
            r = summ["paired"][f"{e}_{il}_succ"]; sg.append(1 if r["lo"] > 0 else (-1 if r["hi"] < 0 else 0))
        L.append(f"- {il}: per-env sign {sg} -> {'RL better in all 3' if all(v==1 for v in sg) else ('IL better in all 3' if all(v==-1 for v in sg) else 'rule NOT met')}")
    L.append("\n## RL seeds 2..5 (reference only, see rates table)\n")
    open(out+".md", "w").write("\n".join(L)+"\n"); json.dump(summ, open(out+".json", "w"), indent=1)
if __name__ == "__main__": main(sys.argv[1], sys.argv[2])
