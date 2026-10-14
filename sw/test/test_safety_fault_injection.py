#!/usr/bin/env python3
"""M5 fault-injection matrix for the Python reference safety filter."""
import math, os, sys, random
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "safety"))
from safety_layer import DeterministicSafetyFilter as F

NAN, INF = float("nan"), float("inf")
res = []
def check(name, ok): res.append((name, ok)); print(("PASS " if ok else "FAIL ") + name)
def mk(): return F(dt=0.02)
def finite(*xs): return all(math.isfinite(x) for x in xs)

# 1 NaN / inf policy outputs must give finite, in-envelope, braking command
for tag, (v, w) in {"nan_v": (NAN, 0.0), "nan_w": (0.0, NAN), "inf_v": (INF, 0.0),
                    "-inf_w": (0.0, -INF), "nan_both": (NAN, NAN)}.items():
    f = mk()
    for _ in range(10): f.filter_action(0.5, 0.0, 2.0)
    vo, wo, _ = f.filter_action(v, w, 2.0)
    check(f"policy_{tag}: finite and within envelope",
          finite(vo, wo) and abs(vo) <= f.v_max and abs(wo) <= f.w_max)
    check(f"policy_{tag}: internal state finite", finite(f.v_prev, f.w_prev))

# 2 sensor dropout: NaN / negative / inf distance. Must NOT permit forward motion (fail safe)
for tag, d in {"nan": NAN, "neg": -1.0, "-inf": -INF}.items():
    f = mk()
    for _ in range(40): f.filter_action(0.5, 0.0, 2.0)
    vo, wo, _ = f.filter_action(0.5, 0.0, d)
    check(f"dist_{tag}: forward motion blocked", finite(vo, wo) and vo <= 0.0)

# 3 stuck policy: constant max command with obstacle closing never violates margin
f = mk(); x = 0.0; wall = 3.0; ok = True
for _ in range(2000):
    d = wall - x
    vo, wo, _ = f.filter_action(0.5, 0.0, d)
    x += vo * 0.02
    if wall - x < f.d_margin - 1e-9: ok = False
check("stuck_policy: margin never violated approaching wall", ok)

# 4 watchdog: inference_ok False -> zero and state reset
f = mk()
for _ in range(30): f.filter_action(0.5, 0.0, 2.0)
vo, wo, r = f.filter_action(0.5, 0.0, 2.0, inference_ok=False)
check("watchdog: zero output", vo == 0 and wo == 0)

# 5 rate limit fuzz incl. random faults
random.seed(1234); f = mk(); ok = True; vp = wp = 0.0
for _ in range(20000):
    v = random.choice([NAN, INF, -INF, random.uniform(-5, 5)])
    w = random.choice([NAN, INF, -INF, random.uniform(-9, 9)])
    d = random.choice([NAN, -1.0, random.uniform(0, 4)])
    vo, wo, _ = f.filter_action(v, w, d)
    if not finite(vo, wo) or abs(vo) > f.v_max + 1e-9 or abs(wo) > f.w_max + 1e-9 \
       or abs(vo - vp) > f.a_max * f.dt + 1e-9 and vo != 0.0:
        ok = False
    vp, wp = vo, wo
check("fuzz 20000 faulty inputs: always finite and in envelope", ok)

n = sum(1 for _, o in res if not o)
print(f"{len(res)-n}/{len(res)} passed"); sys.exit(1 if n else 0)
