"""M9b equivalence test on PILOT seeds only: continuous vs ordered chunks vs shuffled chunks.
Compares every per-episode field exactly (incl. float path_len/reward/clear). Time is logged to the ledger."""
import sys, json, random, time
from m9b_eval import run
def chunks(tag, env, start, n, size, order):
    idx = list(range(0, n, size)); 
    if order == "shuffled": random.Random(7).shuffle(idx)
    res = {}
    for i in idx:
        for e in run(tag, env, start + i, size): res[e["seed"]] = e
    return [res[s] for s in range(start, start + n)]
tag, env, start, n, size = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
t0 = time.time()
cont = run(tag, env, start, n); t1 = time.time()
ordd = chunks(tag, env, start, n, size, "ordered")
shuf = chunks(tag, env, start, n, size, "shuffled"); t2 = time.time()
ok_o = cont == ordd; ok_s = cont == shuf
k = sum(e["succ"] for e in cont)
rec = {"tag": tag, "env": env, "start": start, "n": n, "chunk": size, "cont_succ": k,
       "ordered_identical": ok_o, "shuffled_identical": ok_s, "wall_cont_s": t1 - t0, "wall_total_s": t2 - t0}
print(json.dumps(rec))
json.dump(rec, open(f"../../results/m9b/equiv/equiv_{tag}_{env}_{start}_{n}.json", "w"))
with open("../../results/m9b/ledger.jsonl", "a") as f: f.write(json.dumps({"what": "equiv", **rec, "wall_s": t2 - t0}) + "\n")
sys.exit(0 if ok_o and ok_s else 1)
