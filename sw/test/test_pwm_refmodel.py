#!/usr/bin/env python3
"""M11b M2 Stage 1: lockstep check of rtl/periph/soc_pwm.v against sw/test/pwm_refmodel.py.

SIMULATION ONLY. Deterministic (no random seeds that change between runs).

Suites (each one vector file -> sim/tb_pwm_refmodel.v -> per-cycle dump -> compared
with the Python model on every cycle, every observable field):
  A  BFS: PERIOD=3, STALE_CYCLES=4 (small so the full transition replay fits the runtime budget). The model enumerates every reachable abstract state
     (all registers except reject/read-data, incl. pwm counter and stale counter) under
     an action alphabet (all 8 CTRL values + reserved-bit CTRL, CMD_L/R writes with
     boundary-class values, COMMIT, STATUS read, idle) x input classes (all-clear,
     WDT trip, E-stop, !enable). For every reachable state and every action the trace
     is reset -> shortest path -> action -> 1 idle edge, so every transition of the
     abstract graph is checked against the RTL.
  B  Boundaries: PERIOD=10, STALE=25. CMD pairs from {0,+-1,+-999,+-1000,+-1001,-32768,32767}
     committed armed and disarmed, COMMIT at counter PERIOD-2/PERIOD-1/0, stale counter
     2/1/0 with a same-edge COMMIT, every CTRL value with each input class.
  C  Pseudo-random walk, fixed LCG seed 1 (deterministic), PERIOD=7, STALE=40, 60k cycles.
Model invariants are checked on every reachable BFS state.
Negative controls: planted RTL defects (temporary mutated copies of soc_pwm.v; the
tracked RTL is never modified) and planted model defects must each produce a mismatch.

Exit: 0 pass, 1 fail, 2 missing tool / harness error (never a pass).
"""
import os, shutil, subprocess, sys, tempfile, time
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from pwm_refmodel import Model, DUMP_NAMES  # noqa: E402

RTL = os.path.join(ROOT, "rtl", "periph", "soc_pwm.v")
TB = os.path.join(ROOT, "sim", "tb_pwm_refmodel.v")
IVERILOG = os.environ.get("IVERILOG", "iverilog")
VVP = os.environ.get("VVP_PLAIN", "vvp")

ENV = [(0, 0, 0), (1, 0, 1), (1, 1, 0), (1, 0, 0)]  # (disarm_in, estop_in, wdt_trip_in)
ENV_NAMES = ["clear", "wdt", "estop", "disabled"]
# Unit-level only: E-stop live with disarm_in=0. Unreachable in soc_top (estop_tripped feeds
# safety_filter.pin_estop_button, which ORs combinationally into actuator_disarm), but the
# soc_pwm contract checks estop_live on its own (FAULT_CLR row 2), so suites B and C drive it.
ENV_UNIT = ENV + [(0, 1, 0)]


def vec(reset=0, op=None, off=0, data=0, env=(0, 0, 0)):
    o = {None: 0, "W": 1, "R": 2}[op]
    d, e, w = env
    return (reset << 63) | (o << 61) | (d << 60) | (e << 59) | (w << 58) | ((off & 0xFF) << 40) | (data & 0xFFFFFFFF)


def decode(v):
    reset = v >> 63 & 1
    op = {0: None, 1: "W", 2: "R"}[v >> 61 & 3]
    return reset, op, v >> 40 & 0xFF, v & 0xFFFFFFFF, (v >> 60 & 1, v >> 59 & 1, v >> 58 & 1)


def model_trace(vecs, P, S, mutate=None):
    m = Model(P, S, mutate)
    out = []
    for v in vecs:
        reset, op, off, data, env = decode(v)
        if reset:
            m.reset()
        else:
            m.step(op, off, data, *env)
        out.append(m.snapshot(env[0]))
    return out


def parse_dump(path):
    rows = []
    with open(path) as f:
        for line in f:
            t = line.split()
            if len(t) != len(DUMP_NAMES):
                raise RuntimeError("bad dump line: %r" % line)
            r = []
            for i, x in enumerate(t):
                if "x" in x.lower() or "z" in x.lower():
                    r.append(None)          # X/Z never equals a model value
                elif i in (5, 6) or i >= 13:
                    r.append(int(x, 16))
                else:
                    r.append(int(x))
            rows.append(tuple(r))
    return rows


def run_rtl(vecs, P, S, rtl_path, work, tag):
    vf = os.path.join(work, tag + ".vec")
    of = os.path.join(work, tag + ".dump")
    exe = os.path.join(work, tag + ".vvp")
    with open(vf, "w") as f:
        f.write("\n".join("%016x" % v for v in vecs) + "\n")
    cmd = [IVERILOG, "-g2012", "-P", "tb_pwm_refmodel.PERIOD=%d" % P, "-P", "tb_pwm_refmodel.STALE=%d" % S,
           "-P", "tb_pwm_refmodel.MAXV=%d" % (len(vecs) + 1), "-o", exe, rtl_path, TB]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("iverilog failed: " + r.stderr[-2000:])
    r = subprocess.run([VVP, "-N", exe, "+VEC=" + vf, "+OUT=" + of, "+N=%d" % len(vecs)],
                       capture_output=True, text=True)
    if r.returncode != 0 or ("[REFTB-DONE] n=%d" % len(vecs)) not in r.stdout or "FATAL" in r.stdout:
        raise RuntimeError("vvp failed rc=%d: %s" % (r.returncode, (r.stdout + r.stderr)[-2000:]))
    return parse_dump(of)


def compare(vecs, rtl_rows, model_rows, limit=5):
    if len(rtl_rows) != len(model_rows):
        return ["length mismatch rtl=%d model=%d" % (len(rtl_rows), len(model_rows))]
    bad = []
    for i, (a, b) in enumerate(zip(rtl_rows, model_rows)):
        if a != b:
            diff = ["%s rtl=%s model=%s" % (DUMP_NAMES[k], a[k], b[k]) for k in range(len(a)) if a[k] != b[k]]
            bad.append("cycle %d vec=%016x: %s" % (i, vecs[i], "; ".join(diff)))
            if len(bad) >= limit:
                break
    return bad


# ---------------------------------------------------------------- suite A: BFS
LVALS = [0, 1000, -1001]
RVALS = [0, -1000, 1001]


def actions_a():
    bus = [None] + [("W", 0, c) for c in range(8)] + [("W", 0, 0xFFFFFFF9)]
    bus += [("W", 4, v) for v in LVALS] + [("W", 8, v) for v in RVALS]
    bus += [("W", 0x0C, 0), ("R", 0x10, 0)]
    return [(b, e) for b in bus for e in ENV]


def abstract(m):
    k = m.key()
    F = Model.FIELDS
    return tuple(k[i] for i, f in enumerate(F) if f not in ("rej", "reason", "rdat"))


def apply(m, act):
    b, e = act
    if b is None:
        m.step(None, 0, 0, *e)
    else:
        m.step(b[0], b[1], b[2], *e)


def act_vec(act):
    b, e = act
    return vec(env=e) if b is None else vec(op=b[0], off=b[1], data=b[2], env=e)


def check_invariants(m):
    """Contract-derived properties on a reachable model state; returns list of violations."""
    v = []
    if m.armed and m.fault(): v.append("armed with a fault latched")
    if (m.act_l or m.act_r) and not m.armed: v.append("ACTIVE nonzero while not armed")
    if (m.sh_l or m.sh_r) and not m.armed: v.append("SHADOW nonzero while not armed")
    for x in (m.act_l, m.act_r, m.sh_l, m.sh_r):
        if not -1000 <= x <= 1000: v.append("ACTIVE/SHADOW out of range")
    if m.armed and not (1 <= m.stale <= m.S): v.append("armed with stale counter %d" % m.stale)
    if not m.armed and m.stale: v.append("stale counter running while disarmed")
    return v


def suite_a(P=3, S=4):
    acts = actions_a()
    m = Model(P, S)
    m.reset()
    start = m.key()
    parent = {abstract(m): None}
    full = {abstract(m): start}
    order = [abstract(m)]
    q = deque([start])
    inv = []
    while q:
        s = q.popleft()
        for i, a in enumerate(acts):
            m.load(s)
            apply(m, a)
            k = abstract(m)
            if k not in parent:
                parent[k] = (abstract_of(s), i)
                full[k] = m.key()
                order.append(k)
                q.append(m.key())
                inv += ["%s: %s" % (k, x) for x in check_invariants(m)]
    # paths
    paths = {}
    for k in order:
        p = parent[k]
        paths[k] = [] if p is None else paths[p[0]] + [p[1]]
    vecs = []
    for k in order:
        pre = [vec(reset=1)] + [act_vec(acts[i]) for i in paths[k]]
        for a in acts:
            vecs += pre + [act_vec(a), vec()]
    return vecs, {"states": len(order), "actions": len(acts), "transitions": len(order) * len(acts),
                  "max_depth": max(len(p) for p in paths.values()), "invariant_violations": inv}


def abstract_of(key):
    m = Model(2, 2)
    m.load(key)
    return abstract(m)


# ---------------------------------------------------------------- suite B: boundaries
BVALS = [0, 1, -1, 999, -999, 1000, -1000, 1001, -1001, -32768, 32767]


def arm_seq(env=(0, 0, 0)):
    # zero-arm: DISARM, CMD 0, FAULT_CLR, ARM_REQ (separate writes, idle between bus ops)
    s = []
    for op in [("W", 0, 2), ("W", 4, 0), ("W", 8, 0), ("W", 0, 4), ("W", 0, 1)]:
        s += [vec(op=op[0], off=op[1], data=op[2], env=env), vec(env=env)]
    return s


def suite_b(P=10, S=25):
    v = [vec(reset=1)]
    # CMD pairs, armed then disarmed commit
    for l in BVALS:
        for r in BVALS:
            v += arm_seq()
            v += [vec(op="W", off=4, data=l), vec(), vec(op="W", off=8, data=r), vec(),
                  vec(op="W", off=0x0C), vec()] + [vec()] * P
            v += [vec(op="R", off=0x10), vec(), vec(op="R", off=0x14), vec()]
            v += [vec(op="W", off=0, data=2), vec()]                              # DISARM
            v += [vec(op="W", off=4, data=l), vec(), vec(op="W", off=8, data=r), vec(),
                  vec(op="W", off=0x0C), vec(), vec(op="R", off=0x04), vec(), vec(op="R", off=0x08), vec()]
    # COMMIT at counter PERIOD-2, PERIOD-1, 0 (counter after reset: cycle index known to the model only,
    # so we align by issuing commits at every phase of the period)
    for ph in range(P + 1):
        v += arm_seq() + [vec(op="W", off=4, data=500), vec(), vec(op="W", off=8, data=-300), vec()]
        v += [vec()] * ph + [vec(op="W", off=0x0C), vec()] + [vec()] * (2 * P)
    # stale counter 2/1/0 with same-edge COMMIT: commit at every offset around expiry
    for d in range(S - 4, S + 3):
        v += arm_seq() + [vec(op="W", off=4, data=100), vec()]
        v += [vec()] * (d - 2) + [vec(op="W", off=0x0C), vec()] + [vec()] * (S + 2)
    # every CTRL value with every input class, from armed and from faulted states
    for c in list(range(8)) + [0xFFFFFFF9, 0xFFFFFFFD]:
        for e in ENV_UNIT:
            v += arm_seq() + [vec(op="W", off=0, data=c, env=e), vec(), vec(op="R", off=0x10, env=e), vec()]
            v += [vec(op="W", off=4, data=1001), vec(), vec(op="W", off=0x0C), vec()]   # range fault
            v += [vec(op="W", off=0, data=c, env=e), vec(), vec(op="R", off=0x10, env=e), vec()]
    # WDT/E-stop pulse while armed and moving
    for e in ENV_UNIT[1:]:
        v += arm_seq() + [vec(op="W", off=4, data=-1000), vec(), vec(op="W", off=0x0C), vec()] + [vec()] * P
        v += [vec(env=e)] + [vec()] * 3 + [vec(op="W", off=0, data=4), vec(), vec(op="R", off=0x10), vec()]
    return v


# ---------------------------------------------------------------- suite C: deterministic random walk
def suite_c(n=60000, seed=1):
    x = seed
    def rnd():
        nonlocal x
        x = (1103515245 * x + 12345) & 0x7FFFFFFF
        return x >> 8
    vals = BVALS + [500, -500, 250, -7]
    v = [vec(reset=1)]
    while len(v) < n:
        r = rnd() % 100
        e = ENV[0] if rnd() % 50 else ENV_UNIT[rnd() % 5]
        if r < 40:
            v.append(vec(env=e))
        elif r < 52:
            v += arm_seq()
        elif r < 60:
            v.append(vec(op="W", off=0, data=rnd() % 8, env=e))
        elif r < 75:
            v.append(vec(op="W", off=4 if r % 2 else 8, data=vals[rnd() % len(vals)], env=e))
        elif r < 90:
            v.append(vec(op="W", off=0x0C, env=e))
        elif r < 99:
            v.append(vec(op="R", off=(rnd() % 8) * 4, env=e))
        else:
            v.append(vec(reset=1))
    return v[:n]


# ---------------------------------------------------------------- negative controls
RTL_MUTANTS = [
    ("kill_keeps_cmd", "cmd_l    <= 16'sd0;  cmd_r    <= 16'sd0;", "cmd_l <= cmd_l; cmd_r <= cmd_r;"),
    ("commit_beats_stale", "wire stale_hit   = armed && (stale_cnt == 32'd1);",
     "wire stale_hit   = armed && (stale_cnt == 32'd1) && !wr_commit;"),
    ("combo_allowed", "wire ctl_combo = ctl_arm && ctl_fclr;", "wire ctl_combo = 1'b0;"),
    ("range_check_off", "wire range_bad   = wr_commit && ", "wire range_bad   = 1'b0 && "),
    ("fclr_ignores_cmd", "!cmd_zero    ? RJ_CMD_NZ    : RJ_NONE;", "1'b0         ? RJ_CMD_NZ    : RJ_NONE;"),
    ("safe_ignores_disarm", "wire safe = !armed || fault_any || disarm_in;", "wire safe = !armed || fault_any;"),
    ("fclr_ignores_estop", "estop_in     ? RJ_DISARM_IN :", "1'b0         ? RJ_DISARM_IN :"),
    ("estop_not_latched", "if (estop_in)  estop_seen  <= 1'b1;", "if (1'b0)  estop_seen  <= 1'b1;"),
    ("pwm_off_by_one", "(lhs <= rhs_l)", "(lhs < rhs_l)"),
    ("rollover_drops_commit", "shadow_l <= commit_ok ? cmd_l : active_l;", "shadow_l <= active_l;"),
    ("arm_ignores_cmd", "!cmd_zero                    ? RJ_CMD_NZ    : RJ_NONE;",
     "1'b0                         ? RJ_CMD_NZ    : RJ_NONE;"),
]
# Not used as controls because they are equivalent on every reachable state (reported, not hidden):
#  - ARM_REQ ignoring SHADOW/ACTIVE non-zero: SHADOW/ACTIVE != 0 implies ARMED (BFS invariant), and
#    ARMED is checked first (reason 4), so the SHADOW/ACTIVE check (reason 5) can never decide.
MODEL_MUTANTS = ["kill_keeps_cmd", "combo_ok", "pwm_ge"]


def main():
    for tool in (IVERILOG, VVP):
        if shutil.which(tool) is None:
            print("FAIL test_pwm_refmodel: %s missing (not a pass)" % tool)
            return 2
    quick = "--quick" in sys.argv
    t0 = time.time()
    with open(RTL) as f:
        rtl_src = f.read()
    work = tempfile.mkdtemp(prefix="pwm_refmodel_")
    rc = 0
    try:
        va, info = suite_a()
        print("[REFMODEL] suite A BFS: %d reachable abstract states x %d actions = %d transitions, "
              "max path depth %d, %d vector cycles" % (info["states"], info["actions"], info["transitions"],
                                                       info["max_depth"], len(va)))
        if info["invariant_violations"]:
            print("[REFMODEL-FAIL] model invariants violated on reachable states:")
            for x in info["invariant_violations"][:10]:
                print("   ", x)
            rc = 1
        else:
            print("[REFMODEL] invariants hold on all %d reachable states" % info["states"])
        suites = [("A", va, 3, 4), ("B", suite_b(), 10, 25), ("C", suite_c(), 7, 40)]
        expect = {}
        for name, v, P, S in suites:
            exp = model_trace(v, P, S)
            expect[name] = exp
            got = run_rtl(v, P, S, RTL, work, "s" + name)
            bad = compare(v, got, exp)
            if bad:
                rc = 1
                print("[REFMODEL-FAIL] suite %s (PERIOD=%d STALE=%d): RTL != model" % (name, P, S))
                for b in bad:
                    print("   ", b)
            else:
                print("[REFMODEL] suite %s PERIOD=%d STALE=%d: %d cycles, RTL == model on all %d fields"
                      % (name, P, S, len(v), len(DUMP_NAMES)))
        # coverage of CTRL values x state class in suite A/B/C (model-side bins)
        print("[REFMODEL] %.0fs for main suites" % (time.time() - t0))
        if quick:
            return rc
        # Negative controls
        nc_ok = 0
        nc_total = 0
        for name, old, new in RTL_MUTANTS:
            nc_total += 1
            if rtl_src.count(old) != 1:
                print("[REFMODEL-FAIL] NC %s: anchor not found exactly once (harness stale)" % name)
                rc = 1
                continue
            mp = os.path.join(work, "mut_%s.v" % name)
            with open(mp, "w") as f:
                f.write(rtl_src.replace(old, new))
            hit = None
            for sname, v, P, S in sorted(suites, key=lambda t: len(t[1])):   # cheapest suite first
                got = run_rtl(v, P, S, mp, work, "m_" + name + sname)
                if compare(v, got, expect[sname], limit=1):
                    hit = sname
                    break
            if hit:
                nc_ok += 1
                print("[REFMODEL-NC] RTL mutant %-22s detected (suite %s)" % (name, hit))
            else:
                rc = 1
                print("[REFMODEL-FAIL] RTL mutant %s NOT detected" % name)
        for name in MODEL_MUTANTS:
            nc_total += 1
            hit = None
            for sname, v, P, S in suites:
                exp_m = model_trace(v, P, S, {name})
                if exp_m != expect[sname]:
                    hit = sname
                    break
            if hit:
                nc_ok += 1
                print("[REFMODEL-NC] model mutant %-20s detected (suite %s)" % (name, hit))
            else:
                rc = 1
                print("[REFMODEL-FAIL] model mutant %s NOT detected" % name)
        print("[REFMODEL] negative controls %d/%d detected" % (nc_ok, nc_total))
        with open(RTL) as f:
            if f.read() != rtl_src:
                print("[REFMODEL-FAIL] tracked soc_pwm.v changed during the run")
                rc = 1
    except RuntimeError as e:
        print("FAIL test_pwm_refmodel: harness error: %s" % e)
        rc = 2
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("[REFMODEL] total %.0fs" % (time.time() - t0))
    if rc == 0:
        print("[REFMODEL-PASS]")
    return rc


if __name__ == "__main__":
    sys.exit(main())
