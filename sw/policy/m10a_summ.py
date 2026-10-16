import json, numpy as np, sys
d = json.load(open(sys.argv[1]))
print("| policy | env | filter | max_steps | n | succ | coll | timeout | to: median dfin/d0 | to: slow frac | to: disp_last(m) | interv |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for k, v in d.items():
    p, e, f, ms = k.split("|"); n = len(v)
    s = sum(x["succ"] for x in v); c = sum(x["coll"] for x in v); T = [x for x in v if not x["succ"] and not x["coll"]]
    if T:
        r = f'{np.median([x["dfin"]/x["d0"] for x in T]):.2f}'; sl = f'{np.mean([x["slow"] for x in T]):.2f}'; ds = f'{np.median([x["disp_last"] for x in T]):.2f}'
    else: r = sl = ds = "-"
    print(f'| {p} | {e} | {f} | {ms} | {n} | {s/n:.3f} | {c/n:.3f} | {len(T)/n:.3f} | {r} | {sl} | {ds} | {np.mean([x["interv"] for x in v]):.2f} |')
