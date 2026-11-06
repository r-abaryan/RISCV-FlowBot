#!/usr/bin/env python3
"""M2 Stage 1, Step 1a: contract-table checks + reachable abstract state/event coverage of the independent
contract model (sw/test/m2_contract_model.py). Pure Python; no RTL is run here (that is Step 1b).

Expected values in the directed tables are written by hand from the contract text (docs/50 v3.1, v2 sections 1-5,
R1-R4), not computed by the model. Exit 0 iff every check passes. Optional: --json PATH writes the coverage report.
"""
import itertools, json, sys, os
from collections import deque
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m2_contract_model as M
from m2_contract_model import Inputs, Params, State, step, outputs, invariants, RESET

FAILS, PASSES = [], [0]


def check(cond, msg):
    if cond:
        PASSES[0] += 1
    else:
        FAILS.append(msg)


def run(st, seq, p):
    infos = []
    for inp in seq:
        st, info = step(st, inp, p)
        infos.append(info)
    return st, infos


def W(kind, data=0, **kw):
    return Inputs(op=(kind, data), **kw)


IDLE = Inputs()

# ---------------------------------------------------------------------------------------------- helpers
P_SMALL = Params(period=10, stale=25)


def armed_zero(p=P_SMALL):
    """Zero-arm sequence (STEP1 C): FAULT_CLR, CMD 0/0, COMMIT, ARM_REQ."""
    st, _ = run(RESET, [W("ctrl", 4), W("cmd_l", 0), W("cmd_r", 0), W("commit"), W("ctrl", 1)], p)
    assert st.armed == 1, st
    return st


def moving(l=500, r=-500, p=P_SMALL):
    st, _ = run(armed_zero(p), [W("cmd_l", l & 0xFFFF), W("cmd_r", r & 0xFFFF), W("commit")], p)
    while st.pwm_cnt != 0:                     # let SHADOW load
        st, _ = step(st, IDLE, p)
    return st


def range_faulted(p=P_SMALL):
    st, _ = run(RESET, [W("cmd_l", 1001), W("commit")], p)
    assert st.f_range
    return st


def stale_faulted(p=P_SMALL):
    st = armed_zero(p)
    while not st.f_stale:
        st, _ = step(st, IDLE, p)
    return st


def estop_seen(p=P_SMALL):
    st, _ = run(armed_zero(p), [Inputs(disarm_in=1, estop_live=1), IDLE], p)
    assert st.estop_seen
    return st


def ready_nonzero_cmd(p=P_SMALL):
    st, _ = run(RESET, [W("cmd_l", 5)], p)
    return st


# ---------------------------------------------------------------------------------------------- 1. signed boundaries
OWNER_VALUES = [-1001, -1000, -999, -1, 0, 1, 999, 1000, 1001, -32768, 32767]
EXTRA_VALUES = [-512, -511, 511, 512]


def encodings(v):
    """Different bus words carrying the same 16-bit value (A10: bits 31:16 ignored)."""
    return {"sext32": v & 0xFFFFFFFF, "zext16": v & 0xFFFF, "junk_hi": 0xA5A50000 | (v & 0xFFFF)}


def t_boundaries():
    n = 0
    p = Params(period=1000, stale=5000)
    for v in OWNER_VALUES + EXTRA_VALUES:
        valid = -1000 <= v <= 1000                                       # hand-derived contract expectation
        for side in ("cmd_l", "cmd_r"):
            other = "cmd_r" if side == "cmd_l" else "cmd_l"
            for enc_name, word in encodings(v).items():
                # (a) armed: accepted iff in range
                st0 = armed_zero(p)
                st, infos = run(st0, [W(other, 0), W(side, word), W("commit")], p)
                tag = f"v={v} {side} {enc_name} armed"
                if valid:
                    a = st.act_l if side == "cmd_l" else st.act_r
                    check(infos[-1].commit_result == "accepted" and a == v and st.armed == 1 and not st.f_range,
                          f"{tag}: expected accept, got {infos[-1].commit_result} act={a}")
                    # PWM high cycles + DIR over one full period after SHADOW load
                    while st.pwm_cnt != 0:
                        st, _ = step(st, IDLE, p)
                    highs, dirs = 0, set()
                    for _ in range(p.period):
                        o = outputs(st, IDLE, p)
                        highs += o.pin_l if side == "cmd_l" else o.pin_r
                        dirs.add(o.dir_l if side == "cmd_l" else o.dir_r)
                        st, _ = step(st, IDLE, p)
                    check(highs == abs(v) * p.period // 1000, f"{tag}: high={highs}")
                    check(dirs == {1 if v < 0 else 0}, f"{tag}: dir={dirs}")
                else:
                    o = outputs(st, IDLE, p)
                    check(infos[-1].commit_result == "range_fault" and st.f_range == 1 and st.armed == 0
                          and st.act_l == st.act_r == 0 and st.sh_l == st.sh_r == 0 and st.cmd_l == st.cmd_r == 0
                          and o.safe == 1 and o.en == 0 and o.pin_l == o.pin_r == 0,
                          f"{tag}: expected reject+FAULT_RANGE, got {infos[-1].commit_result} {st}")
                    # must not be recoverable without the sequence: COMMIT again -> still safe
                    st2, _ = run(st, [W(side, 5), W("commit"), IDLE], p)
                    check(st2.armed == 0 and st2.act_l == st2.act_r == 0, f"{tag}: auto-resume")
                    # recovery: FAULT_CLR then ARM_REQ works
                    st3, _ = run(st, [W("ctrl", 4), W("ctrl", 1)], p)
                    check(st3.armed == 1 and not st3.latched(), f"{tag}: recovery failed {st3}")
                # (b) disarmed: in range -> ignored, no fault; out of range -> FAULT_RANGE (decision F)
                st, infos = run(RESET, [W(side, word), W("commit")], p)
                exp = "ignored" if valid else "range_fault"
                check(infos[-1].commit_result == exp and st.f_range == int(not valid) and st.act_l == st.act_r == 0,
                      f"v={v} {side} {enc_name} disarmed: expected {exp}, got {infos[-1].commit_result}")
                n += 1
    # pairs: accepted iff both in range (V-IF3 style, extended set)
    vals = OWNER_VALUES + EXTRA_VALUES
    for l, r in itertools.product(vals, vals):
        st, infos = run(armed_zero(p), [W("cmd_l", l & 0xFFFF), W("cmd_r", r & 0xFFFF), W("commit")], p)
        ok = -1000 <= l <= 1000 and -1000 <= r <= 1000
        check((infos[-1].commit_result == "accepted") == ok and st.f_range == int(not ok),
              f"pair ({l},{r}): {infos[-1].commit_result}")
        if ok:
            check((st.act_l, st.act_r) == (l, r), f"pair ({l},{r}) active {(st.act_l, st.act_r)}")
        n += 1
    # exhaustive 16-bit sweep on each side (model-level only; RTL exhaustive is V-IF1/V-IF2 elsewhere)
    bad_escape = 0
    base = armed_zero(p)
    for w in range(0x10000):
        v = M.s16(w)
        st, infos = run(base, [W("cmd_l", w), W("commit")], p)
        if (infos[-1].commit_result == "accepted") != (-1000 <= v <= 1000):
            bad_escape += 1
    check(bad_escape == 0, f"16-bit sweep: {bad_escape} misclassified")
    return n


# ---------------------------------------------------------------------------------------------- 2. CTRL table
HIGH_PATTERNS = [0x0, 0xFFFFFFF0, 0x80000000, 0x55555550, 0xAAAAAAA0, 0x00010000, 0x7FFFFFF0]

# Start states and the hand-written expected outcome per low-3-bit CTRL value (bit3 is reserved, so the same
# expectation holds for low nibble v and v|8). Tuple: (armed_after, faults_after_any, arm_rej, reason)
# 'F' in faults column means "unchanged from start", 0 means cleared.
START = {
    "reset":       (lambda: RESET, dict(disarm_in=0)),
    "ready_cmdnz": (ready_nonzero_cmd, dict(disarm_in=0)),
    "armed_idle":  (armed_zero, dict(disarm_in=0)),
    "moving":      (moving, dict(disarm_in=0)),
    "range_fault": (range_faulted, dict(disarm_in=0)),
    "stale_fault": (stale_faulted, dict(disarm_in=0)),
    "estop_seen_released": (estop_seen, dict(disarm_in=0)),
    "reset_wdt_disarm": (lambda: RESET, dict(disarm_in=1, wdt_trip=1)),
    "armed_wdt_disarm": (armed_zero, dict(disarm_in=1, wdt_trip=1)),
    "fault_estop_held": (range_faulted, dict(disarm_in=1, estop_live=1)),
    "fault_wdt_disarm": (stale_faulted, dict(disarm_in=1, wdt_trip=1)),
}
#            low3:  0 noop      1 ARM          2 DISARM     3 ARM+DIS      4 FCLR        5 ARM+FCLR   6 DIS+FCLR    7 all
EXPECT = {
    "reset":       [(0,'F',0,0), (1,'F',0,0), (0,'F',0,0), (0,'F',1,1), (0,'F',0,0), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "ready_cmdnz": [(0,'F',0,0), (0,'F',1,6), (0,'F',0,0), (0,'F',1,1), (0,'F',1,6), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "armed_idle":  [(1,'F',0,0), (1,'F',1,4), (0,'F',0,0), (0,'F',1,1), (1,'F',1,4), (1,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "moving":      [(1,'F',0,0), (1,'F',1,4), (0,'F',0,0), (0,'F',1,1), (1,'F',1,4), (1,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "range_fault": [(0,'F',0,0), (0,'F',1,2), (0,'F',0,0), (0,'F',1,1), (0, 0, 0,0), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "stale_fault": [(0,'F',0,0), (0,'F',1,2), (0,'F',0,0), (0,'F',1,1), (0, 0, 0,0), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "estop_seen_released":
                   [(0,'F',0,0), (0,'F',1,2), (0,'F',0,0), (0,'F',1,1), (0, 0, 0,0), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    # Owner decision Q3 (2026-11-05): a live kill term (disarm_in) beats the request -> reason 1, also with a fault latched.
    "reset_wdt_disarm":
                   [(0,'F',0,0), (0,'F',1,1), (0,'F',0,0), (0,'F',1,1), (0,'F',1,1), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "armed_wdt_disarm":
                   [(0,'F',0,0), (0,'F',1,1), (0,'F',0,0), (0,'F',1,1), (0,'F',1,1), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "fault_estop_held":
                   [(0,'F',0,0), (0,'F',1,1), (0,'F',0,0), (0,'F',1,1), (0,'F',1,1), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
    "fault_wdt_disarm":
                   [(0,'F',0,0), (0,'F',1,1), (0,'F',0,0), (0,'F',1,1), (0,'F',1,1), (0,'F',1,7), (0,'F',1,1), (0,'F',1,7)],
}


def faults(st):
    return (st.f_stale, st.f_range, st.estop_seen)


def t_ctrl_table():
    n = 0
    for name, (mk, env) in START.items():
        s0 = mk()
        for nib in range(16):
            for hi in HIGH_PATTERNS:
                word = (hi & ~0xF) | nib
                st, info = step(s0, Inputs(op=("ctrl", word), **env), P_SMALL)
                ea, ef, er, ereason = EXPECT[name][nib & 7]
                exp_f = faults(s0) if ef == 'F' else (0, 0, 0)
                if env.get("estop_live"):
                    exp_f = (exp_f[0], exp_f[1], 1)          # E-stop held keeps ESTOP_SEEN latched
                got = (st.armed, faults(st), st.arm_rej, st.reason)
                check(got == (ea, exp_f, er, ereason),
                      f"CTRL {name} word=0x{word:08x}: got {got} expected {(ea, exp_f, er, ereason)}")
                # kill-path effects: any DISARM bit or any disarm_in -> ACTIVE/SHADOW/CMD all zero, outputs safe
                if (nib & 2) or env.get("disarm_in") or s0.latched():
                    check(st.act_l == st.act_r == st.sh_l == st.sh_r == st.cmd_l == st.cmd_r == 0,
                          f"CTRL {name} 0x{word:08x}: kill did not clear registers")
                    check(outputs(st, IDLE, P_SMALL).safe == 1, f"CTRL {name} 0x{word:08x}: not safe")
                n += 1
    return n


# ---------------------------------------------------------------------------------------------- 3. directed contract rows
def t_directed():
    p = P_SMALL
    n = 0
    # T1 reset
    o = outputs(RESET, IDLE, p)
    check(o.safe and not o.en and not o.pin_l and not o.pin_r and RESET.armed == 0, "T1"); n += 1
    # T2 zero command: 0 highs over 3 periods
    st = armed_zero(p); hi = 0
    for _ in range(3 * p.period):
        o = outputs(st, IDLE, p); hi += o.pin_l + o.pin_r; st, _ = step(st, IDLE, p)
    check(hi == 0, "T2"); n += 1
    # T4 mid-period commit: current pulse unaltered, both sides switch at the same rollover
    st = moving(300, 300, p)
    for _ in range(4): st, _ = step(st, IDLE, p)
    st, _ = run(st, [W("cmd_l", 800), W("cmd_r", (-800) & 0xFFFF), W("commit")], p)
    check((st.sh_l, st.sh_r) == (300, 300) and (st.act_l, st.act_r) == (800, -800), "T4 before rollover")
    while st.pwm_cnt != 0: st, _ = step(st, IDLE, p)
    check((st.sh_l, st.sh_r) == (800, -800), "T4 after rollover"); n += 1
    # COMMIT exactly on the rollover edge -> SHADOW gets the new value at that edge
    st = moving(300, 300, p)
    while st.pwm_cnt != p.period - 2: st, _ = step(st, IDLE, p)
    st, _ = step(st, W("cmd_l", 700), p)              # now pwm_cnt == period-1
    st, info = step(st, W("commit"), p)
    check(info.rollover and st.sh_l == 700, "S3 COMMIT on rollover"); n += 1
    # T7 stale exact timing: last reload at edge t0 -> FAULT_STALE at edge t0+STALE
    st = armed_zero(p); edges = 0
    st, _ = step(st, W("commit"), p)                    # t0
    while not st.f_stale:
        st, _ = step(st, IDLE, p); edges += 1
    # contract v3 s3: reload at edge t0 -> FAULT_STALE at edge t0+STALE_CYCLES (edges counted after t0)
    check(edges == p.stale, f"T7 stale at t0+{edges}, expected t0+{p.stale}"); n += 1
    check(outputs(st, IDLE, p).safe == 1, "T7 safe"); n += 1
    # T8: CMD writes, reads, CTRL noop, WDT heartbeat do not reload stale
    st = armed_zero(p)
    seq = [W("cmd_l", 0), W("read", 0x10), W("ctrl", 0), Inputs(wdt_trip=0)] * 10
    st, _ = run(st, seq[:p.stale], p)
    check(st.f_stale == 1, "T8 stale independent of non-COMMIT traffic"); n += 1
    # S1: COMMIT on the stale_hit edge loses
    st = armed_zero(p)
    while st.stale_cnt != 1: st, _ = step(st, IDLE, p)
    st, info = step(st, W("commit"), p)
    check(st.f_stale == 1 and st.armed == 0 and info.commit_result == "discarded", "S1"); n += 1
    # COMMIT one edge before expiry rescues
    st = armed_zero(p)
    while st.stale_cnt != 2: st, _ = step(st, IDLE, p)
    st, _ = step(st, W("commit"), p)
    st, _ = step(st, IDLE, p)
    check(st.f_stale == 0 and st.armed == 1, "stale rescue at cnt=2"); n += 1
    # S2: COMMIT + disarm_in same edge -> kill, CMD cleared
    st = moving(400, 400, p)
    st, _ = step(st, W("cmd_l", 900), p)
    st, info = step(st, Inputs(op=("commit", 0), disarm_in=1, wdt_trip=1), p)
    check(st.armed == 0 and st.act_l == 0 and st.cmd_l == 0 and info.commit_result == "discarded", "S2"); n += 1
    # S4/S5 kill + rollover: SHADOW 0
    for cause in ("disarm_in", "disarm_wr"):
        st = moving(400, 400, p)
        while st.pwm_cnt != p.period - 1: st, _ = step(st, IDLE, p)
        inp = Inputs(disarm_in=1) if cause == "disarm_in" else W("ctrl", 2)
        st, info = step(st, inp, p)
        check(info.rollover and st.sh_l == st.sh_r == 0 and st.armed == 0, f"S4/S5 {cause}"); n += 1
    # S6 reset mid-pulse
    st = moving(900, 900, p)
    st, _ = step(st, Inputs(rst=1), p)
    check(st == RESET and outputs(st, Inputs(rst=1), p).safe == 1, "S6"); n += 1
    # S7 FAULT_CLR while E-stop held: rejected, ESTOP_SEEN stays
    st = estop_seen(p)
    st, _ = step(st, Inputs(op=("ctrl", 4), disarm_in=1, estop_live=1), p)
    check(st.estop_seen == 1 and st.arm_rej == 1 and st.reason == M.R_KILL_EDGE, "S7 (Q3: live kill -> 1)"); n += 1
    # S8 ARM_REQ with disarm_in
    st, _ = step(RESET, Inputs(op=("ctrl", 1), disarm_in=1), p)
    check(st.armed == 0 and st.reason == M.R_KILL_EDGE, "S8 (Q3: live kill -> 1)"); n += 1
    # S9 COMMIT + E-stop on rollover
    st = moving(400, 400, p)
    while st.pwm_cnt != p.period - 1: st, _ = step(st, IDLE, p)
    st, info = step(st, Inputs(op=("commit", 0), disarm_in=1, estop_live=1), p)
    check(st.estop_seen and st.sh_l == 0 and st.armed == 0 and info.rollover, "S9"); n += 1
    # E-stop: ESTOP_SEEN latched, pins low combinationally in the same cycle as disarm_in
    st = moving(1000, 1000, p)
    o = outputs(st, Inputs(disarm_in=1, estop_live=1), p)
    check(o.safe and not o.pin_l and not o.en, "E-stop combinational inhibit"); n += 1
    # T9 no auto-resume after each fault kind
    for mk in (range_faulted, stale_faulted, estop_seen):
        st, _ = run(mk(p), [W("cmd_l", 500), W("commit"), W("ctrl", 1), W("commit")], p)
        check(st.armed == 0 and st.act_l == 0 and outputs(st, IDLE, p).safe, f"T9 {mk.__name__}"); n += 1
    # Owner Q3 example: ARM_REQ with a latched fault plus live disarm -> KILL_EDGE (1), not FAULT (2)
    st, _ = step(range_faulted(p), Inputs(op=("ctrl", 1), disarm_in=1, wdt_trip=1), p)
    check(st.arm_rej == 1 and st.reason == M.R_KILL_EDGE, f"Q3 example ARM+fault+disarm_in: reason {st.reason}"); n += 1
    # Q1: ESTOP_SEEN is STATUS bit 8
    st = estop_seen(p)
    w = M.status_word(st, IDLE, p)
    check((w >> 8) & 1 == 1 and (M.status_word(RESET, IDLE, p) >> 8) & 1 == 0, "Q1 ESTOP_SEEN at STATUS bit 8"); n += 1
    # T10 recovery order: FAULT_CLR -> ARM works; ARM first -> rejected (reason 2); FAULT_CLR alone never arms
    st, _ = run(range_faulted(p), [W("ctrl", 1)], p)
    check(st.armed == 0 and st.reason == M.R_FAULT, "T10 ARM before FAULT_CLR"); n += 1
    st, _ = run(range_faulted(p), [W("ctrl", 4)], p)
    check(st.armed == 0 and not st.latched(), "T10 FAULT_CLR never arms"); n += 1
    st, _ = run(range_faulted(p), [W("ctrl", 4), W("cmd_l", 3), W("ctrl", 1)], p)
    check(st.armed == 0 and st.reason == M.R_CMD_NZ, "T10 nonzero staged cmd blocks ARM"); n += 1
    # T11 FAULT_CLR preconditions: nonzero staged cmd cannot exist while faulted (kill clears it, R2 discards
    # writes) -> the CMD_NZ precondition of FAULT_CLR is only reachable with no fault latched.
    st, _ = run(range_faulted(p), [W("cmd_l", 9)], p)
    check(st.cmd_l == 0, "R2 CMD write discarded while faulted"); n += 1
    # WDT_TRIP: status mirror only. wdt_trip=1 with disarm_in=0 (impossible in soc_top, unit-level) must not
    # change any state; the disarm happens only through disarm_in.
    st0 = moving(600, 600, p)
    st1, _ = step(st0, Inputs(wdt_trip=1), p)
    st2, _ = step(st0, IDLE, p)
    check(st1 == st2 and outputs(st0, Inputs(wdt_trip=1), p).wdt_trip == 1, "WDT_TRIP mirror only"); n += 1
    # P1 pending command never activates after fault: stage 700, fault, recover, ARM, COMMIT without new CMD
    st = moving(400, 400, p)
    st, _ = run(st, [W("cmd_l", 700), Inputs(disarm_in=1), W("ctrl", 4), W("ctrl", 1), W("commit")], p)
    check(st.armed == 1 and st.act_l == 0, "P1 staged cmd lost on kill"); n += 1
    return n


# ---------------------------------------------------------------------------------------------- 4. abstract coverage
P_BFS = Params(period=3, stale=4)
CMD_VALS = [0, 1000, -1000, 1001, -32768]           # classes: zero, +max, -max, bad+, bad- extreme
CTRL_VALS = list(range(8)) + [0xFFFFFFF9, 0xFFFFFFF8]
OPS = ([None] + [("ctrl", c) for c in CTRL_VALS] + [("cmd_l", v & 0xFFFF) for v in CMD_VALS]
       + [("cmd_r", v & 0xFFFF) for v in CMD_VALS] + [("commit", 0), ("read", 0x10)])
ENVS = dict(M.SOC_ENVS, **M.UNIT_ENVS)


def vcls(v):
    return "0" if v == 0 else ("ok" if -1000 <= v <= 1000 else "bad")


def state_class(st, p):
    stale = "idle" if st.stale_cnt == 0 else ("hit" if st.stale_cnt == 1 else
                                               ("full" if st.stale_cnt == p.stale else "mid"))
    pwm = "last" if st.pwm_cnt == p.period - 1 else ("zero" if st.pwm_cnt == 0 else "mid")
    return (("A" if st.armed else "D"), "S" * st.f_stale + "R" * st.f_range + "E" * st.estop_seen or "-",
            "cmd:" + vcls(st.cmd_l) + "/" + vcls(st.cmd_r), "act:" + vcls(st.act_l) + "/" + vcls(st.act_r),
            "sh:" + vcls(st.sh_l) + "/" + vcls(st.sh_r), "stale:" + stale, "pwm:" + pwm)


def op_class(op):
    if op is None: return "idle"
    k, d = op
    if k == "ctrl": return f"ctrl{d & 7}" + ("+hi" if d & ~7 else "")
    if k in ("cmd_l", "cmd_r"): return f"{k}:{vcls(M.s16(d))}"
    return k


def event_class(info):
    return (info.ctrl_result or "-", info.commit_result or "-", info.cmd_write or "-",
            "kill:" + ",".join(info.live_causes) if info.kill else "nokill", "roll" if info.rollover else "")


def t_bfs():
    p = P_BFS
    seen = {RESET}
    q = deque([RESET])
    trans = 0
    s_classes, se_pairs, ev_classes, reasons, reasons_unit = set(), set(), set(), set(), set()
    inv_fail = []
    while q:
        st = q.popleft()
        s_classes.add(state_class(st, p))
        for v in invariants(st, p):
            inv_fail.append((v, st))
        for op in OPS:
            for env_name, env in ENVS.items():
                nst, info = step(st, Inputs(op=op, **env), p)
                trans += 1
                ev = event_class(info)
                ev_classes.add(ev)
                se_pairs.add((state_class(st, p)[:2], op_class(op), env_name))
                (reasons if env_name in M.SOC_ENVS else reasons_unit).add(nst.reason)
                # model self-check: CTRL bits 31:3 ignored
                if op and op[0] == "ctrl":
                    alt, _ = step(st, Inputs(op=("ctrl", op[1] & 7), **env), p)
                    check(alt == nst, f"reserved bits change behaviour: {op[1]:#x}")
                if nst not in seen:
                    seen.add(nst)
                    q.append(nst)
    check(not inv_fail, f"invariant violations: {inv_fail[:3]}")
    # Reason 5 ACTIVE_NZ unreachable (owner Q2 accepted): ACTIVE/SHADOW!=0 implies ARMED, checked first (reason 4).
    # Reason 3 DISARM_IN unreachable after owner Q3: every disarm_in (and A5 estop_live) edge is a KILL edge -> reason 1.
    # (This BFS walks from SoC-reachable AND unit-only inputs; the reason sets are recorded per bucket.)
    check(reasons == {0, 1, 2, 4, 6, 7}, f"SoC reject reasons reached: {sorted(reasons)} (expected 0,1,2,4,6,7)")
    check(reasons_unit <= {0, 1, 2, 4, 6, 7}, f"unit-only reasons: {sorted(reasons_unit)}")
    # expected-unreachable abstract classes (contract arguments), must really be unreachable
    unreach = {
        "armed_with_any_fault": [c for c in s_classes if c[0] == "A" and c[1] != "-"],
        "disarmed_with_active_or_shadow_nz": [c for c in s_classes if c[0] == "D" and
                                              (c[3] != "act:0/0" or c[4] != "sh:0/0")],
        "active_or_shadow_bad": [c for c in s_classes if "bad" in c[3] or "bad" in c[4]],
        "fault_with_staged_cmd_nz": [c for c in s_classes if c[1] != "-" and c[2] != "cmd:0/0"],
        "disarmed_stale_counting": [c for c in s_classes if c[0] == "D" and c[5] != "stale:idle"],
    }
    for k, v in unreach.items():
        check(not v, f"unreachable class {k} reached: {v[:2]}")
    fault_combos = sorted({c[1] for c in s_classes})
    return dict(params=dict(period=p.period, stale=p.stale), concrete_states=len(seen), transitions=trans,
                ops=len(OPS), envs=list(ENVS), abstract_state_classes=len(s_classes),
                state_x_event_classes=len(se_pairs), edge_outcome_classes=len(ev_classes),
                fault_latch_combinations_reached=fault_combos, reject_reasons_reached_soc=sorted(reasons),
                reject_reasons_reached_unit=sorted(reasons_unit),
                expected_unreachable_checked=list(unreach))


# ---------------------------------------------------------------------------------------------- main
def main():
    counts = {}
    counts["boundaries_cases"] = t_boundaries()
    counts["ctrl_table_cases"] = t_ctrl_table()
    counts["directed_cases"] = t_directed()
    cov = t_bfs()
    report = dict(counts=counts, coverage=cov, checks_passed=PASSES[0], checks_failed=len(FAILS),
                  failures=FAILS[:50], assumptions=M.ASSUMPTIONS)
    if "--json" in sys.argv:
        with open(sys.argv[sys.argv.index("--json") + 1], "w") as f:
            json.dump(report, f, indent=1)
    print(json.dumps({k: report[k] for k in ("counts", "coverage", "checks_passed", "checks_failed")}, indent=1))
    for f in FAILS[:50]:
        print("FAIL:", f)
    print("STEP1A-PASS" if not FAILS else f"STEP1A-FAIL ({len(FAILS)} failed checks)")
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())
