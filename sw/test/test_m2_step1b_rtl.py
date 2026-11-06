#!/usr/bin/env python3
"""M11b M2 Stage 1 Step 1b: cycle-by-cycle comparison of rtl/periph/soc_pwm.v against the INDEPENDENT
contract model sw/test/m2_contract_model.py (Step 1a, corrected per owner decisions Q1-Q3).

SIMULATION ONLY. Deterministic. The tracked RTL is never modified; planted RTL defects are temporary copies.

Wishbone stimulus is generated the way the PicoRV32 wishbone adapter drives it (rtl/cpu/picorv32.v,
WBSTART/WBEND): cyc=stb=1 with address/data/we, held until the cycle after ACK is seen, then dropped for
one cycle. The model gets the same raw signals and decides itself which edge a request acts on (A16), so the
ACK timing and read-data timing are compared, not assumed.

Per cycle 25 fields are compared: PRE-edge (live inputs applied): pin L/R, DIR L/R, EN, monitor L/R, ACK, read
data; POST-edge: ARMED, FAULT_STALE, FAULT_RANGE, ESTOP_SEEN, ARM_REJECTED, reason, CMD L/R, ACTIVE L/R,
SHADOW L/R, stale counter, PWM counter, ACK, read data. X/Z never compares equal.

Each test is a segment that starts from reset. Segments are tagged SOC (input combinations reachable in
soc_top) or UNIT (soc_pwm-only combinations impossible in soc_top: estop_live or wdt_trip with disarm_in=0).
A mismatch is reported per segment with the first differing cycle and fields; nothing is auto-fixed.

Exit: 0 = no SOC mismatch and all planted errors detected; 1 = any SOC mismatch or an undetected planted
error; 2 = harness/tool error. UNIT mismatches are reported as findings and do not change rc (see report).
"""
import json, os, re, shutil, subprocess, sys, tempfile, time
from collections import deque, Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import m2_contract_model as M  # noqa: E402
from m2_contract_model import Inputs, Params, RESET, step, outputs  # noqa: E402

RTL = os.path.join(ROOT, "rtl", "periph", "soc_pwm.v")
TB = os.path.join(ROOT, "sim", "tb_m2_step1b.v")
IVERILOG = os.environ.get("IVERILOG", "iverilog")
VVP = os.environ.get("VVP_PLAIN", "vvp")

PRE = ["pin_l", "pin_r", "dir_l", "dir_r", "en", "mon_l", "mon_r", "ack_pre", "rdat_pre"]
POST = ["armed", "f_stale", "f_range", "estop_seen", "arm_rej", "reason", "cmd_l", "cmd_r", "act_l", "act_r",
        "sh_l", "sh_r", "stale_cnt", "pwm_cnt", "ack", "rdat"]
FIELDS = PRE + POST
HEXF = {"mon_l", "mon_r", "rdat_pre", "cmd_l", "cmd_r", "act_l", "act_r", "sh_l", "sh_r", "stale_cnt", "pwm_cnt", "rdat"}

OFFK = {0x00: "ctrl", 0x04: "cmd_l", 0x08: "cmd_r", 0x0C: "commit"}
ENV_ALL = dict(M.SOC_ENVS, **M.UNIT_ENVS)


def envbits(env):
    return (env.get("disarm_in", 0), env.get("estop_live", 0), env.get("wdt_trip", 0))


def vec(rst=0, cyc=0, stb=0, we=0, env=None, off=0, dat=0):
    d, e, w = envbits(env or {})
    return ((rst << 63) | (cyc << 62) | (stb << 61) | (we << 60) | (d << 59) | (e << 58) | (w << 57)
            | ((off & 0xFF) << 48) | (dat & 0xFFFFFFFF))


def decode(v):
    return dict(rst=v >> 63 & 1, cyc=v >> 62 & 1, stb=v >> 61 & 1, we=v >> 60 & 1, disarm_in=v >> 59 & 1,
                estop_live=v >> 58 & 1, wdt_trip=v >> 57 & 1, off=v >> 48 & 0xFF, dat=v & 0xFFFFFFFF)


def s16(x):
    return M.s16(x)


class ModelRun:
    """Replays raw per-cycle vectors through the contract model plus the A14/A16 Wishbone interpretation."""

    def __init__(self, p, mod=M):
        self.p, self.m = p, mod
        self.st, self.ack, self.rdat = mod.RESET, 0, 0

    def cycle(self, v):
        m, p, d = self.m, self.p, decode(v)
        if d["rst"]:
            self.st, self.ack, self.rdat = m.RESET, 0, 0
            inp = m.Inputs(rst=1, disarm_in=d["disarm_in"], estop_live=d["estop_live"], wdt_trip=d["wdt_trip"])
            pre = self._pre(inp)
            return pre + self._post()
        req = d["cyc"] and d["stb"] and not self.ack
        op = None
        if req:
            if d["we"]:
                k = OFFK.get(d["off"])
                op = (k, d["dat"]) if k else None
            else:
                op = ("read", d["off"])
        inp = m.Inputs(op=op, disarm_in=d["disarm_in"], estop_live=d["estop_live"], wdt_trip=d["wdt_trip"])
        pre = self._pre(inp)
        if req and not d["we"]:
            self.rdat = m.read_data(self.st, inp, p, d["off"])
        self.st, self.info = m.step(self.st, inp, p)
        self.ack = int(bool(req))
        return pre + self._post()

    def _pre(self, inp):
        o = self.m.outputs(self.st, inp, self.p)
        ml, mr = self.m.monitor(self.st, inp, self.p)
        return (o.pin_l, o.pin_r, o.dir_l, o.dir_r, o.en, ml, mr, self.ack, self.rdat)

    def _post(self):
        s = self.st
        return (s.armed, s.f_stale, s.f_range, s.estop_seen, s.arm_rej, s.reason, s.cmd_l, s.cmd_r, s.act_l,
                s.act_r, s.sh_l, s.sh_r, s.stale_cnt, s.pwm_cnt, self.ack, self.rdat)


SIGNED16 = {"cmd_l", "cmd_r", "act_l", "act_r", "sh_l", "sh_r"}


def parse_dump(path):
    rows = []
    with open(path) as f:
        for line in f:
            a, b = line.split("|")
            toks = a.split() + b.split()
            if len(toks) != len(FIELDS):
                raise RuntimeError("bad dump line: " + line)
            row = []
            for name, t in zip(FIELDS, toks):
                if re.search(r"[xXzZ]", t):
                    row.append("X:" + t)               # never equal to a model int
                    continue
                v = int(t, 16) if name in HEXF else int(t)
                if name in SIGNED16:
                    v = s16(v)
                row.append(v)
            rows.append(tuple(row))
    return rows


# ------------------------------------------------------------------------------------------- segment builder
class Seg:
    """One test from reset. Stimulus only; a private ModelRun is used to steer timing (phase/stale), never to
    produce expectations (those come from the fresh comparison replay)."""

    def __init__(self, name, p, bucket="SOC", suite="D"):
        self.name, self.p, self.bucket, self.suite = name, p, bucket, suite
        self.v, self.env = [], {}
        self.mr = ModelRun(p)
        self.reset(2)

    def _emit(self, x):
        d = decode(x)
        if (d["estop_live"] or d["wdt_trip"]) and not d["disarm_in"] and not d["rst"]:
            self.bucket = "UNIT"                       # any SoC-impossible input cycle makes the segment UNIT
        self.v.append(x)
        self.mr.cycle(x)

    def reset(self, n=1, env=None):
        for _ in range(n):
            self._emit(vec(rst=1, env=env or {"disarm_in": 1}))

    def idle(self, n=1, env=None):
        for _ in range(n):
            self._emit(vec(env=self.env if env is None else env))

    def wr(self, off, dat, env=None, env_hold=None):
        e = self.env if env is None else env
        eh = e if env_hold is None else env_hold
        self._emit(vec(cyc=1, stb=1, we=1, env=e, off=off, dat=dat))     # request: acts on this edge
        self._emit(vec(cyc=1, stb=1, we=1, env=eh, off=off, dat=dat))    # held while ACK is seen
        self._emit(vec(env=eh))                                          # WBEND

    def rd(self, off, env=None):
        e = self.env if env is None else env
        self._emit(vec(cyc=1, stb=1, we=0, env=e, off=off))
        self._emit(vec(cyc=1, stb=1, we=0, env=e, off=off))
        self._emit(vec(env=e))

    # convenience
    def ctrl(self, x, **k): self.wr(0x00, x, **k)
    def cmd(self, l=None, r=None, **k):
        if l is not None: self.wr(0x04, l & 0xFFFFFFFF, **k)
        if r is not None: self.wr(0x08, r & 0xFFFFFFFF, **k)
    def commit(self, **k): self.wr(0x0C, 0xDEADBEEF, **k)
    def status(self, **k): self.rd(0x10, **k)

    def arm_zero(self):
        self.ctrl(4); self.cmd(0, 0); self.commit(); self.ctrl(1); self.status()

    def go(self, l, r):
        self.cmd(l, r); self.commit()

    def until(self, pred, limit=100000):
        n = 0
        while not pred(self.mr):
            self.idle(); n += 1
            if n > limit:
                raise RuntimeError("until() limit in " + self.name)

    def phase(self, k):
        """Idle until the NEXT cycle's pre-edge PWM counter == k (so a request issued next acts at counter k)."""
        self.until(lambda mr: mr.st.pwm_cnt == k)

    def stale_at(self, k):
        self.until(lambda mr: mr.st.stale_cnt == k)


# ------------------------------------------------------------------------------------------- suite D: directed
P_D = Params(period=10, stale=25)
CLEAR, WDT, ESTOP, DIS = M.SOC_ENVS["clear"], M.SOC_ENVS["wdt"], M.SOC_ENVS["estop"], M.SOC_ENVS["disable"]


def faulted(s, kind):
    if kind == "range":
        s.cmd(1001); s.commit()
    elif kind == "stale":
        s.arm_zero(); s.until(lambda mr: mr.st.f_stale)
    elif kind == "estop":
        s.arm_zero(); s.env = ESTOP; s.idle(3); s.env = CLEAR; s.idle(2)
    s.status()


def suite_directed():
    p, segs = P_D, []

    def S(name):
        s = Seg(name, p); segs.append(s); return s
    # reset: T1, async reset mid-pulse (rst asserted for one cycle while moving), every offset read after reset
    s = S("T1_reset_reads"); s.env = CLEAR; s.idle(25)
    for off in range(0, 0x24, 4): s.rd(off)
    s = S("S6_reset_mid_pulse"); s.env = CLEAR; s.arm_zero(); s.go(900, -900); s.phase(3); s.reset(1, env=CLEAR); s.idle(25)
    s.status()
    # reads of every register while moving (A14 incl. 0x14, 0x18, 0x1C) + WDT/E-stop status live bits
    s = S("reads_moving"); s.env = CLEAR; s.arm_zero(); s.go(-400, 250); s.phase(0)
    for off in range(0, 0x24, 4): s.rd(off)
    s.rd(0x10, env=WDT); s.rd(0x10, env=ESTOP); s.rd(0x10, env=DIS); s.status()
    # COMMIT / PWM rollover: COMMIT acting at every PWM phase, both sides change at the same rollover (T4)
    for k in range(p.period):
        s = S(f"T4_commit_phase{k}"); s.env = CLEAR; s.arm_zero(); s.go(300, 300); s.phase(0)
        s.cmd(800, -800)
        s.phase(k); s.commit(); s.idle(2 * p.period)
    # T2 zero command 3 periods; values incl. full scale both signs
    s = S("T2_zero"); s.env = CLEAR; s.arm_zero(); s.idle(3 * p.period)
    s = S("duty_values"); s.env = CLEAR; s.arm_zero()
    for l, r in [(1000, -1000), (-1, 1), (999, -999), (100, 0), (0, -100), (550, -449)]:
        s.go(l, r); s.idle(2 * p.period)
    # stale expiry: exact edge, rescue at cnt=2, COMMIT on the expiry edge (S1), at cnt 3/2/1 issued
    s = S("T7_stale_exact"); s.env = CLEAR; s.arm_zero(); s.commit(); s.idle(p.stale + 5); s.status()
    for k in (3, 2, 1):
        s = S(f"S1_commit_at_stale{k}"); s.env = CLEAR; s.arm_zero(); s.go(500, 500); s.stale_at(k); s.commit()
        s.idle(p.stale + 3); s.status()
    s = S("T8_traffic_no_reload"); s.env = CLEAR; s.arm_zero()
    for _ in range(4): s.cmd(0, 0); s.status(); s.ctrl(0)
    s.idle(p.stale); s.status()
    # WDT status mirror (disarm via disarm_in, SoC-reachable) + WDT pulse while moving + recovery
    s = S("wdt_trip_moving"); s.env = CLEAR; s.arm_zero(); s.go(700, 700); s.phase(4)
    s.env = WDT; s.idle(3); s.status(); s.ctrl(4); s.ctrl(1); s.env = CLEAR; s.idle(2); s.status()
    s.ctrl(1); s.status(); s.go(200, 200); s.idle(2 * p.period)
    # E-stop: combinational inhibit, ESTOP_SEEN (bit8), FAULT_CLR refused while held (S7), recovery after release
    s = S("estop_full"); s.env = CLEAR; s.arm_zero(); s.go(1000, 1000); s.phase(2)
    s.env = ESTOP; s.idle(2); s.status(); s.ctrl(4); s.status(); s.ctrl(1); s.status()
    s.env = CLEAR; s.idle(2); s.status(); s.ctrl(1); s.status(); s.ctrl(4); s.status(); s.ctrl(1); s.status()
    s.go(-300, 300); s.idle(2 * p.period)
    # S9 COMMIT + E-stop on the rollover edge; S4/S5 kill/DISARM on the rollover edge
    s = S("S9_commit_estop_rollover"); s.env = CLEAR; s.arm_zero(); s.go(400, 400); s.cmd(600, 600)
    s.phase(p.period - 1); s.commit(env=ESTOP, env_hold=ESTOP); s.env = ESTOP; s.idle(3); s.status()
    s = S("S4_disarm_in_rollover"); s.env = CLEAR; s.arm_zero(); s.go(400, 400); s.phase(p.period - 1)
    s.idle(1, env=DIS); s.idle(p.period); s.status()
    s = S("S5_ctrl_disarm_rollover"); s.env = CLEAR; s.arm_zero(); s.go(400, 400); s.phase(p.period - 1)
    s.ctrl(2); s.idle(p.period); s.status()
    # S2 COMMIT + disarm_in same edge (staged CMD cleared, P1 pending command)
    s = S("S2_P1_commit_disarm"); s.env = CLEAR; s.arm_zero(); s.go(400, 400); s.cmd(900)
    s.commit(env=WDT, env_hold=CLEAR); s.status(); s.ctrl(4); s.ctrl(1); s.commit(); s.idle(2 * p.period); s.status()
    # fault recovery: each fault kind, T9 no auto-resume, T10 order, CMD!=0 blocks
    for kind in ("range", "stale", "estop"):
        s = S(f"T9_T10_{kind}"); s.env = CLEAR; faulted(s, kind)
        s.cmd(500); s.commit(); s.ctrl(1); s.commit(); s.status()      # no resume, ARM -> reason 2
        s.ctrl(4); s.cmd(3); s.ctrl(1); s.status()                      # CMD!=0 blocks ARM (6)
        s.ctrl(4); s.status()                                           # FAULT_CLR with CMD!=0 -> 6
        s.cmd(0); s.ctrl(4); s.ctrl(1); s.status(); s.ctrl(1); s.status()   # arms, second ARM -> 4
        s.go(250, -250); s.idle(2 * p.period)
    # simultaneous-event priority (owner Q3): ARM with fault latched + live disarm -> 1; combined -> 7 always
    for kind in ("range", "stale", "estop"):
        for envn, env in (("wdt", WDT), ("estop", ESTOP), ("disable", DIS)):
            for c in (1, 4, 5, 3, 6, 7):
                s = S(f"prio_{kind}_{envn}_ctrl{c}"); s.env = CLEAR; faulted(s, kind)
                s.ctrl(c, env=env, env_hold=CLEAR); s.status()
    for c in range(16):
        for hi in (0, 0xFFFFFFF0, 0x55555550):
            for start in ("reset", "armed", "moving"):
                s = S(f"ctrl_{start}_{(hi | c):08x}"); s.env = CLEAR
                if start != "reset": s.arm_zero()
                if start == "moving": s.go(600, -600)
                s.ctrl(hi | c); s.status(); s.idle(p.period)
    # COMMIT on the stale-expiry edge while also on rollover
    s = S("S1_stale_and_rollover"); s.env = CLEAR; s.arm_zero(); s.go(500, 500)
    s.stale_at(1); s.commit(); s.idle(3)
    # boundary values (sampled V-IF1/V-IF2/V-IF3; NOT the exhaustive requirement)
    vals = [-1001, -1000, -999, -512, -511, -1, 0, 1, 511, 512, 999, 1000, 1001, -32768, 32767]
    for side in ("L", "R"):
        for v in vals:
            for enc in (v & 0xFFFFFFFF, v & 0xFFFF, 0xA5A50000 | (v & 0xFFFF)):
                s = S(f"bnd_{side}_{v}_{enc:08x}"); s.env = CLEAR; s.arm_zero()
                (s.cmd(enc, 0) if side == "L" else s.cmd(0, enc)); s.commit(); s.rd(0x14); s.status()
                s.idle(2 * p.period); s.ctrl(4); s.ctrl(1); s.status()
                s2 = S(f"bnd_disarmed_{side}_{v}_{enc:08x}"); s2.env = CLEAR
                (s2.cmd(enc, 0) if side == "L" else s2.cmd(0, enc)); s2.rd(0x04); s2.rd(0x08); s2.commit(); s2.status()
    for l in (-1001, -1000, -1, 0, 1, 1000, 1001):
        for r in (-1001, -1000, -1, 0, 1, 1000, 1001):
            s = S(f"VIF3_{l}_{r}"); s.env = CLEAR; s.arm_zero(); s.go(l, r); s.rd(0x14); s.status(); s.idle(p.period)
    return segs


# ------------------------------------------------------------------------------------------- suite U: unit-only
def suite_unit():
    p, segs = P_D, []
    for envn, env in M.UNIT_ENVS.items():
        for start in ("reset", "armed", "moving", "range"):
            for act in ("idle", "ctrl1", "ctrl4", "commit", "status"):
                s = Seg(f"U_{envn}_{start}_{act}", p); segs.append(s); s.env = CLEAR
                if start in ("armed", "moving"): s.arm_zero()
                if start == "moving": s.go(500, 500)
                if start == "range": faulted(s, "range")
                if act == "idle": s.idle(3, env=env)
                elif act == "ctrl1": s.ctrl(1, env=env, env_hold=CLEAR)
                elif act == "ctrl4": s.ctrl(4, env=env, env_hold=CLEAR)
                elif act == "commit": s.commit(env=env, env_hold=CLEAR)
                else: s.rd(0x10, env=env)
                s.status(); s.idle(p.period)
    return segs


# ------------------------------------------------------------------------------------------- suite B: transaction BFS
P_B = Params(period=3, stale=4)
B_OPS = ([("idle",)] + [("w", 0x00, c) for c in list(range(8)) + [0xFFFFFFF9]]
         + [("w", 0x04, v & 0xFFFFFFFF) for v in (0, 1000, -1001)] + [("w", 0x08, v & 0xFFFFFFFF) for v in (0, -1000, 1001)]
         + [("w", 0x0C, 0), ("r", 0x10)])
B_ENVS = ["clear", "wdt", "estop", "disable"]


def apply_op(s, op, env):
    if op[0] == "idle":
        s.idle(1, env=env)
    elif op[0] == "w":
        s.wr(op[1], op[2], env=env, env_hold=CLEAR)
    else:
        s.rd(op[1], env=env)
    s.env = CLEAR


def bfs_key(st):
    d = dict(st.__dict__); d.pop("arm_rej"); d.pop("reason"); d.pop("ghost_commit_since_arm")
    return tuple(sorted(d.items()))


def suite_bfs():
    """BFS over model states at transaction granularity (every op is a full Wishbone transaction followed by the
    CLEAR environment). Each discovered (state, op, env) transition becomes an RTL segment: reset -> shortest path
    -> op -> 2 idle cycles. Exhaustive only for these parameters and value classes."""
    p = P_B
    start = Seg("probe", p); start.env = CLEAR
    root = (start.mr.st, start.mr.ack, start.mr.rdat)
    seen = {bfs_key(root[0]): []}
    q = deque([(root, [])])
    acts = [(op, e) for op in B_OPS for e in B_ENVS]
    trans = []
    while q:
        (st, ack, rd), path = q.popleft()
        for a in acts:
            trans.append(path + [a])
            mr = ModelRun(p); mr.st, mr.ack, mr.rdat = st, ack, rd
            tmp = Seg.__new__(Seg); tmp.name, tmp.p, tmp.bucket, tmp.v, tmp.env, tmp.mr = "t", p, "SOC", [], CLEAR, mr
            apply_op(tmp, a[0], M.SOC_ENVS[a[1]])
            k = bfs_key(mr.st)
            if k not in seen:
                seen[k] = path + [a]
                q.append(((mr.st, mr.ack, mr.rdat), path + [a]))
    segs = []
    for i, path in enumerate(trans):
        s = Seg(f"B{i}", p, suite="B"); s.env = CLEAR
        for op, e in path:
            apply_op(s, op, M.SOC_ENVS[e])
        s.idle(2)
        segs.append(s)
    return segs, len(seen), len(trans)


# ------------------------------------------------------------------------------------------- suite W: seeded walk
def suite_walk(n_tx=12000, seed=12345, unit=False):
    p = Params(period=7, stale=40)
    s = Seg("W_unit" if unit else "W_soc", p, suite="W"); s.env = CLEAR
    x = seed
    envs = list(M.SOC_ENVS.values()) + (list(M.UNIT_ENVS.values()) if unit else [])

    def rnd(m):
        nonlocal x
        x = (1103515245 * x + 12345) & 0x7FFFFFFF
        return (x >> 8) % m
    vals = [0, 1, -1, 500, -500, 1000, -1000, 1001, -1001, 32767, -32768, 7]
    for _ in range(n_tx):
        r = rnd(100)
        env = CLEAR if rnd(10) < 8 else envs[rnd(len(envs))]
        if r < 25: s.ctrl([1, 4, 2, 0, 5, 7, 3, 6][rnd(8)] if rnd(4) else 1, env=env, env_hold=CLEAR)
        elif r < 45: s.wr(0x04 if rnd(2) else 0x08, vals[rnd(len(vals))] & 0xFFFFFFFF, env=env, env_hold=CLEAR)
        elif r < 70: s.commit(env=env, env_hold=CLEAR)
        elif r < 80: s.rd([0x04, 0x08, 0x10, 0x14, 0x18, 0x1C, 0x20][rnd(7)], env=env)
        elif r < 82: s.reset(1, env=CLEAR)
        else: s.idle(1 + rnd(12), env=env)
    return [s]


# ------------------------------------------------------------------------------------------- suite V: sampled V-IF1 at PERIOD 1000
def suite_vif_sampled():
    p = Params(period=1000, stale=5000)
    segs = []
    for v in (1, -1, 999, -999, 1000, -1000, 333, -667):
        s = Seg(f"V_{v}", p, suite="V"); segs.append(s); s.env = CLEAR; s.arm_zero(); s.go(v, -v)
        s.phase(0); s.idle(p.period + 2)
    return segs


# ------------------------------------------------------------------------------------------- run + compare
def run_rtl(segs, p, rtl_path, work, tag):
    vecs = [x for s in segs for x in s.v]
    vf, of, exe = (os.path.join(work, tag + e) for e in (".vec", ".dump", ".vvp"))
    with open(vf, "w") as f:
        f.write("\n".join("%016x" % v for v in vecs) + "\n")
    cmd = [IVERILOG, "-g2012", "-P", "tb_m2_step1b.PERIOD=%d" % p.period, "-P", "tb_m2_step1b.STALE=%d" % p.stale,
           "-P", "tb_m2_step1b.MAXV=%d" % (len(vecs) + 1), "-o", exe, rtl_path, TB]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("iverilog failed: " + r.stderr[-2000:])
    r = subprocess.run([VVP, "-N", exe, "+VEC=" + vf, "+OUT=" + of, "+N=%d" % len(vecs)], capture_output=True, text=True)
    if r.returncode != 0 or ("[STEP1B-TB-DONE] n=%d" % len(vecs)) not in r.stdout or "FATAL" in r.stdout:
        raise RuntimeError("vvp failed rc=%d: %s" % (r.returncode, (r.stdout + r.stderr)[-2000:]))
    rows = parse_dump(of)
    for e in (vf, of, exe):
        os.remove(e)
    if len(rows) != len(vecs):
        raise RuntimeError("dump length %d != vectors %d" % (len(rows), len(vecs)))
    return rows


def fmt(name, v):
    if isinstance(v, str): return v
    if name in ("rdat", "rdat_pre"): return "%08x" % (v & 0xFFFFFFFF)
    return str(v)


def compare(segs, rows, p, mod=M, corrupt=None):
    """Fresh model replay of every segment (from its own reset), compared with the RTL rows.
    Returns list of segment mismatches: (seg, cycle_in_seg, [field diffs], vector)."""
    out, i = [], 0
    for s in segs:
        mr = ModelRun(p, mod)
        first = None
        for j, v in enumerate(s.v):
            mrow = mr.cycle(v)
            rrow = rows[i + j]
            if corrupt and corrupt(s, j):
                rrow = tuple((x ^ 1) if (k == POST.index("arm_rej") + len(PRE) and isinstance(x, int)) else x
                             for k, x in enumerate(rrow))
            if first is None and mrow != rrow:
                diffs = ["%s rtl=%s model=%s" % (FIELDS[k], fmt(FIELDS[k], rrow[k]), fmt(FIELDS[k], mrow[k]))
                         for k in range(len(FIELDS)) if mrow[k] != rrow[k]]
                first = (s, j, diffs, v)
        if first:
            out.append(first)
        i += len(s.v)
    return out


def group_by_params(segs):
    g = {}
    for s in segs:
        g.setdefault((s.p.period, s.p.stale), []).append(s)
    return g


def run_all(segs, rtl_path, work, tag, mod=M, corrupt=None):
    mism = []
    for (P, S), ss in group_by_params(segs).items():
        rows = run_rtl(ss, Params(period=P, stale=S), rtl_path, work, "%s_%d_%d" % (tag, P, S))
        mism += compare(ss, rows, Params(period=P, stale=S), mod, corrupt)
    return mism


# ------------------------------------------------------------------------------------------- planted errors
RTL_MUTANTS = [   # temporary copies only
    ("M1_kill_keeps_cmd", "cmd_l    <= 16'sd0;  cmd_r    <= 16'sd0;", "cmd_l <= cmd_l; cmd_r <= cmd_r;"),
    ("M2_commit_beats_stale", "wire stale_hit   = armed && (stale_cnt == 32'd1);",
     "wire stale_hit   = armed && (stale_cnt == 32'd1) && !wr_commit;"),
    ("M3_combo_allowed", "wire ctl_combo = ctl_arm && ctl_fclr;", "wire ctl_combo = 1'b0;"),
    ("M4_range_check_off", "wire range_bad   = wr_commit && ", "wire range_bad   = 1'b0 && "),
    ("M5_safe_ignores_disarm", "wire safe = !armed || fault_any || disarm_in;", "wire safe = !armed || fault_any;"),
    ("M6_estop_not_latched", "if (estop_in)  estop_seen  <= 1'b1;", "if (1'b0)  estop_seen  <= 1'b1;"),
    ("M7_pwm_off_by_one", "(lhs <= rhs_l)", "(lhs < rhs_l)"),
    ("M8_rollover_drops_commit", "shadow_l <= commit_ok ? cmd_l : active_l;", "shadow_l <= active_l;"),
    ("M9_numeric_reason_order", "reject_reason <= kill_live ? RJ_KILL_EDGE : RJ_FAULT;",
     "reject_reason <= fault_any ? RJ_FAULT : RJ_KILL_EDGE;"),
    ("M10_status_bit8_9_swapped", "shadow_zero,        // 9\n                               estop_seen,         // 8",
     "estop_seen,         // 9\n                               shadow_zero,        // 8"),
    ("M11_ack_not_single_cycle", "wb_ack_o <= bus_req;", "wb_ack_o <= wb_cyc_i && wb_stb_i && !wb_ack_o && !wb_we_i || (wb_cyc_i && wb_stb_i && wb_we_i);"),
    ("M12_commit_reload_short", "                    stale_cnt <= STALE_CYCLES;\n                end",
     "                    stale_cnt <= STALE_CYCLES - 1;\n                end"),
    ("M13_wdt_status_tied0", "wdt_trip_in,        // 3", "1'b0,               // 3"),
]


def mutate_model(name):
    """Planted model errors: a modified copy of the model module."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("m2_mut_" + name, os.path.join(HERE, "m2_contract_model.py"))
    mm = importlib.util.module_from_spec(spec); spec.loader.exec_module(mm)
    if name == "MM1_pwm_high_plus1":
        mm.high_cycles = lambda c, per: (abs(c) * per) // 1000 + (1 if c else 0)
    elif name == "MM2_estop_bit_at_9":
        mm.STATUS_BITS = dict(mm.STATUS_BITS, estop_seen=9, shadow_zero=8)
    elif name == "MM3_rdat_zero":
        mm.read_data = lambda st, inp, p, off: 0
    elif name == "DIAG_1C_PERIOD":          # DIAGNOSTIC ONLY (not a contract change): unmask mismatches behind 0x1C reads
        orig = mm.read_data
        mm.read_data = lambda st, inp, p, off: (p.period & 0xFFFFFFFF) if off == 0x1C else orig(st, inp, p, off)
    return mm


MODEL_MUTANTS = ["MM1_pwm_high_plus1", "MM2_estop_bit_at_9", "MM3_rdat_zero"]


# ------------------------------------------------------------------------------------------- main
def summarize(mism):
    return [dict(segment=s.name, bucket=s.bucket, suite=s.suite, cycle=j, vector="%016x" % v, diffs=d[:8])
            for s, j, d, v in mism]


def main():
    t0 = time.time()
    if not shutil.which(IVERILOG) or not shutil.which(VVP):
        print("FAIL: iverilog/vvp missing (not a pass)"); return 2
    quick = "--quick" in sys.argv
    jpath = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    rtl_hash = __import__("hashlib").sha256(open(RTL, "rb").read()).hexdigest()
    segs_d = suite_directed()
    segs_u = suite_unit()
    segs_b, b_states, b_trans = suite_bfs()
    segs_w = suite_walk(n_tx=3000 if quick else 12000) + suite_walk(n_tx=1500 if quick else 6000, seed=777, unit=True)
    segs_v = suite_vif_sampled()
    allsegs = segs_d + segs_u + segs_b + segs_w + segs_v
    cyc = Counter(); nseg = Counter()
    for s in allsegs:
        cyc[s.bucket] += len(s.v); nseg[(s.suite, s.bucket)] += 1
    print("segments:", dict(nseg), "cycles:", dict(cyc), "bfs states", b_states, "transitions", b_trans, flush=True)
    work = tempfile.mkdtemp(prefix="m2s1b_")
    rep = dict(rtl_sha256=rtl_hash, bfs=dict(params="PERIOD=3 STALE=4", states=b_states, transitions=b_trans),
               segments={"%s/%s" % k: v for k, v in nseg.items()}, cycles=dict(cyc))
    try:
        t1 = time.time()
        mism = run_all(allsegs, RTL, work, "real")
        rep["real_runtime_s"] = round(time.time() - t1, 1)
        soc = [m for m in mism if m[0].bucket == "SOC"]
        unit = [m for m in mism if m[0].bucket == "UNIT"]
        rep["mismatch_segments_soc"] = len(soc); rep["mismatch_segments_unit"] = len(unit)
        rep["mismatches_soc"] = summarize(soc)[:200]; rep["mismatches_unit"] = summarize(unit)[:200]
        print("REAL RTL: SOC mismatch segments %d, UNIT mismatch segments %d (%.0fs)"
              % (len(soc), len(unit), rep["real_runtime_s"]), flush=True)
        if "--diag-1c" in sys.argv:
            dm = run_all(allsegs, RTL, work, "diag", mod=mutate_model("DIAG_1C_PERIOD"))
            rep["diag_1c_soc"] = summarize([m for m in dm if m[0].bucket == "SOC"])[:50]
            rep["diag_1c_unit_segments"] = len([m for m in dm if m[0].bucket == "UNIT"])
            print("DIAG (model reads 0x1C as PERIOD): SOC mismatch segments %d, UNIT %d"
                  % (len(rep["diag_1c_soc"]), rep["diag_1c_unit_segments"]), flush=True)
            for m in rep["diag_1c_soc"][:10]: print("DIAG-SOC", m)
        # field histogram of first-difference fields
        hist = Counter()
        for s, j, d, v in mism:
            for x in d: hist[(s.bucket, x.split()[0])] += 1
        rep["first_diff_field_hist"] = {"%s:%s" % k: n for k, n in sorted(hist.items())}
        # planted errors on the directed + BFS + sampled-V segments (SOC and UNIT both count as detection)
        nc_segs = segs_d + segs_u + segs_b + segs_v
        ncres = {}
        if "--no-nc" in sys.argv:
            raise StopIteration
        base = {s.name for s, *_ in mism}
        sel = None
        if "--nc-select" in sys.argv:   # run a subset of the planted errors (sharding for the 600 s shell limit)
            sel = set(sys.argv[sys.argv.index("--nc-select") + 1].split(","))
            unknown = sel - {n for n, _, _ in RTL_MUTANTS} - set(MODEL_MUTANTS) - {"H1_dump_bit_flip"}
            if unknown: raise RuntimeError("unknown NC names: %s" % sorted(unknown))
        rep["nc_selected"] = sorted(sel) if sel else "ALL"
        rtl_src = open(RTL).read()
        for name, old, new in RTL_MUTANTS:
            if sel is not None and name not in sel: continue
            if rtl_src.count(old) != 1:
                ncres[name] = "HARNESS-ERROR pattern count %d" % rtl_src.count(old); continue
            mp = os.path.join(work, name + ".v")
            with open(mp, "w") as f: f.write(rtl_src.replace(old, new))
            mm = run_all(nc_segs, mp, work, name)
            new_fail = [m for m in mm if m[0].name not in base]
            ncres[name] = ("DETECTED %d new mismatch segments, first: %s" % (len(new_fail), new_fail[0][0].name)
                           if new_fail else "NOT DETECTED")
            print(" NC", name, ncres[name], flush=True)
        for name in MODEL_MUTANTS:
            if sel is not None and name not in sel: continue
            mm = run_all(nc_segs, RTL, work, name, mod=mutate_model(name))
            new_fail = [m for m in mm if m[0].name not in base]
            ncres[name] = ("DETECTED %d new mismatch segments" % len(new_fail)) if new_fail else "NOT DETECTED"
            print(" NC", name, ncres[name], flush=True)
        # harness NC: corrupt one RTL-dumped bit in one cycle of one segment
        tgt = segs_d[5].name
        if sel is not None and "H1_dump_bit_flip" not in sel: raise StopIteration
        mm = run_all(segs_d[:10], RTL, work, "hc", corrupt=lambda s, j: s.name == tgt and j == 40)
        ncres["H1_dump_bit_flip"] = "DETECTED" if any(m[0].name == tgt for m in mm) and tgt not in base else "NOT DETECTED"
        print(" NC H1_dump_bit_flip", ncres["H1_dump_bit_flip"], flush=True)
        rep["negative_controls"] = ncres
    except StopIteration:
        if "--no-nc" in sys.argv:
            rep["negative_controls"] = "SKIPPED (--no-nc); not a pass for planted errors"
            ncres = {"NC_SKIPPED": "SKIPPED"}
        else:
            rep["negative_controls"] = ncres
    except RuntimeError as e:
        print("HARNESS ERROR:", e); return 2
    finally:
        shutil.rmtree(work, ignore_errors=True)
    rep["rtl_sha256_after"] = __import__("hashlib").sha256(open(RTL, "rb").read()).hexdigest()
    rep["total_runtime_s"] = round(time.time() - t0, 1)
    undetected = [k for k, v in ncres.items() if not v.startswith("DETECTED")]
    rep["undetected_controls"] = undetected
    if jpath:
        with open(jpath, "w") as f: json.dump(rep, f, indent=1)
    for m in rep["mismatches_soc"][:20]: print("SOC-MISMATCH", m)
    for m in rep["mismatches_unit"][:10]: print("UNIT-MISMATCH", m)
    ok = rep["mismatch_segments_soc"] == 0 and not undetected and rep["rtl_sha256_after"] == rtl_hash
    print("STEP1B-PASS" if ok else "STEP1B-FAIL", "total %.0fs" % rep["total_runtime_s"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
