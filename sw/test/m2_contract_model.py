#!/usr/bin/env python3
"""M2 Stage 1, Step 1a: independent executable model of the soc_pwm motor contract v3.1.

Written ONLY from the contract text, NOT from rtl/periph/soc_pwm.v or sw/test/pwm_refmodel.py:
  - docs/50_M2_MOTOR_CONTRACT.md: v3.1 changes a-d, reject reasons, v3 sections 2/3 (priority table rows P0-P5,
    rollover row, pairwise outcomes, the "pending commands" argument), section 5 matrix.
  - M2_CONTRACT_V2.md sections 1-5 (register map, staging, COMMIT, arming, output gating), as kept by v3 section 4.
  - M2_STEP1_DECISIONS.md R1-R4 and the zero-arm sequence (FAULT_CLR clears all three latches; latched bit is not a cause).

Where the contract does not pin something down, the model makes an explicit assumption. Every assumption has an id
(A1..A12) that is listed in ASSUMPTIONS below and in the Step 1a report. Fields that depend only on assumptions are
tagged so that Step 1b can report a mismatch on them as "contract ambiguity", not as an RTL defect.

The model is a cycle model: step(state, inputs) returns the state after one rising clock edge. outputs(state, inputs)
gives the combinational outputs (pins, DIR, EN, STATUS fields) for a state and the live inputs of that cycle.
Pure Python, deterministic, no simulator needed.
"""
from dataclasses import dataclass, replace, field

# ---- register offsets (v2 section 1) -------------------------------------------------------------
OFF_CTRL, OFF_CMD_L, OFF_CMD_R, OFF_COMMIT, OFF_STATUS = 0x00, 0x04, 0x08, 0x0C, 0x10

# ---- reject reasons (v3.1, STATUS bits 14:12) ----------------------------------------------------
R_NONE, R_KILL_EDGE, R_FAULT, R_DISARM_IN, R_ARMED, R_ACTIVE_NZ, R_CMD_NZ, R_COMBINED = range(8)
REASON_NAME = {0: "NONE", 1: "KILL_EDGE", 2: "FAULT", 3: "DISARM_IN", 4: "ARMED", 5: "ACTIVE_NZ", 6: "CMD_NZ",
               7: "COMBINED"}

CMD_MIN, CMD_MAX = -1000, 1000

ASSUMPTIONS = {
    "A1": "[REVISED per owner decision Q3/A1, 2026-11-05] Reject reason follows the contract operation priority, "
          "not numeric order: 7 COMBINED first (v3.1 b); then on a KILL edge (row 1) any live kill term -> 1 KILL_EDGE, "
          "else (only a latched fault) ARM_REQ -> 2 FAULT, FAULT_CLR -> row 2 preconditions; on a non-KILL edge the "
          "row 2/3 preconditions in the order they are listed (ARMED 4, ACTIVE/SHADOW 5, CMD 6). ARM_REQ with a latched "
          "fault plus live disarm_in -> 1 KILL_EDGE.",
    "A2": "[REVISED to follow Q3] Reason 1 KILL_EDGE = an ARM_REQ/FAULT_CLR on an edge with any live kill term "
          "(disarm_in, stale_hit, CTRL.DISARM in the same write, estop_live under A5; range_bad cannot coincide with a "
          "CTRL write). Reason 3 DISARM_IN is then never produced by this model: every disarm_in/estop_live edge is a "
          "KILL edge and reason 1 takes priority.",
    "A3": "A CTRL write clears ARM_REJECTED and resets the reason to 0 before evaluating that write (v2: 'sticky "
          "until next CTRL write'); a rejection on that write sets them again. Non-CTRL ops leave them unchanged.",
    "A4": "Stale counter is 0 ('idle') while disarmed; ARM loads STALE; an accepted COMMIT reloads STALE; "
          "otherwise it decrements by 1 per edge while ARMED. stale_hit = ARMED and counter == 1 (no COMMIT can "
          "rescue that edge, v3 pairwise outcome 1).",
    "A5": "estop_live=1 with disarm_in=0 (unit-level only, impossible in soc_top) is treated as a kill cause on "
          "that edge as well as latching ESTOP_SEEN (conservative reading of v3 section 2 item 5).",
    "A6": "DIR follows the sign of SHADOW (the value the PWM is using); DIR=0 for 0 and in SAFE.",
    "A7": "The PWM counter runs 0..PERIOD-1 continuously from reset, also in SAFE. pin = !SAFE and "
          "counter < floor(|SHADOW|*PERIOD/1000), evaluated on the registered counter.",
    "A8": "A FAULT_CLR with nothing latched and all preconditions met is accepted as a no-op (no ARM_REJECTED).",
    "A9": "FAULT_CLR / ARM_REQ check SHADOW!=0 together with ACTIVE!=0 under reason 5 ACTIVE_NZ (R1 and the "
          "zero-arm sequence step 5 list SHADOW; the reason list has no separate SHADOW code).",
    "A10": "CMD_L/CMD_R take bits 15:0 of the written word as signed 16-bit; bits 31:16 are ignored on write "
           "(v2 section 1 'bits 15:0, sign-extended on read').",
    "A11": "A CMD write accepted while disarmed and fault-free is kept (zero-arm sequence step 2). A CMD write on "
           "any kill edge or while a fault is latched or disarm_in=1 is discarded (R2, R3).",
    "A12": "Reset is modelled as a synchronous step with rst=1 that yields the reset state; the async assertion "
           "itself is outside a cycle model (outputs() forces SAFE whenever rst=1).",
    # Step 1b additions A13-A16: APPROVED by the owner 2026-11-05 (A15 with the revised combinational-SAFE wording below).
    # A3, A6, A7, A9, A11, A12 remain OPEN (not requirements); see docs/50_M2_MOTOR_CONTRACT.md "Contract-model assumptions".
    "A13": "STATUS (0x10) bit10 DISARM_IN is a live (combinational, unlatched) mirror of the disarm_in input, sampled into "
           "the registered read data on the ACK edge like every other STATUS bit. Bit11 and bits 31:15 read 0.",
    "A14": "Register map is read-only except CTRL (0x00, W, reads 0), CMD_L (0x04, RW), CMD_R (0x08, RW) and COMMIT "
           "(0x0C, W, reads 0). Read data is registered: a read returns, on the edge that sets ACK, the value from "
           "pre-edge state and live inputs: 0x04/0x08 sign-extended CMD, 0x10 STATUS, 0x14 {ACTIVE_R[15:0], ACTIVE_L[15:0]}, "
           "0x18 STALE_CYCLES, 0x1C PERIOD (owner decision F1, normative v3.1 clarification), every other offset within "
           "the 256-byte window 0. Writes to 0x10-0xFF have no effect. wb_dat_o holds its value between reads and is 0 "
           "after reset.",
    "A15": "Monitor outputs pwm_left_cmd/pwm_right_cmd = SHADOW_L/SHADOW_R (16-bit two's complement) while SAFE=0, and "
           "exactly 0 while SAFE=1. They use the same combinational SAFE condition as the PWM pins (registered flags plus "
           "live disarm_in), so they can change within a cycle when disarm_in changes, not only on a clock edge.",
    "A16": "Wishbone timing (cycle-accurate): ACK is registered; a request is cyc&stb&!ack; a write acts on the same "
           "clock edge that sets ACK (v3 s3); ACK is high for exactly one cycle per request, so a held cyc&stb gives "
           "one transaction every 2 cycles. wb_sel_i is not decoded (C4 requires aligned 32-bit stores only); "
           "only wb_adr_i[7:0] is decoded.",
}


def s16(x: int) -> int:
    """Bits 15:0 of a bus word as signed 16-bit (A10)."""
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def in_range(v: int) -> bool:
    return CMD_MIN <= v <= CMD_MAX


def high_cycles(cmd: int, period: int) -> int:
    """v2 section 9: PWM high cycles per period = floor(|cmd| * PERIOD / 1000)."""
    return (abs(cmd) * period) // 1000


@dataclass(frozen=True)
class Params:
    period: int = 1000
    stale: int = 1_250_000


@dataclass(frozen=True)
class State:
    armed: int = 0
    f_stale: int = 0
    f_range: int = 0
    estop_seen: int = 0
    arm_rej: int = 0
    reason: int = 0
    cmd_l: int = 0
    cmd_r: int = 0
    act_l: int = 0
    act_r: int = 0
    sh_l: int = 0
    sh_r: int = 0
    stale_cnt: int = 0
    pwm_cnt: int = 0
    # ghost variable (not a register): an accepted COMMIT with a nonzero value happened since the last ARM.
    ghost_commit_since_arm: int = 0

    def latched(self) -> bool:
        return bool(self.f_stale or self.f_range or self.estop_seen)


RESET = State()


@dataclass(frozen=True)
class Inputs:
    """One clock cycle of stimulus. op is None (idle) or (kind, data) with kind in
    'ctrl','cmd_l','cmd_r','commit','read'. One bus op per clock (single Wishbone master, v3 section 3)."""
    op: tuple = None
    disarm_in: int = 0
    estop_live: int = 0
    wdt_trip: int = 0
    rst: int = 0


@dataclass(frozen=True)
class EdgeInfo:
    """Why the edge did what it did (for coverage classification and readable failures)."""
    kill: bool = False
    live_causes: tuple = ()
    ctrl_result: str = ""      # '', 'arm_ok', 'fclr_ok', 'rejected', 'disarm_only', 'noop'
    commit_result: str = ""    # '', 'accepted', 'ignored', 'range_fault', 'discarded'
    cmd_write: str = ""        # '', 'kept', 'discarded'
    rollover: bool = False


def step(st: State, inp: Inputs, p: Params):
    """One rising edge. Returns (new_state, EdgeInfo)."""
    if inp.rst:                                                    # P0 (A12)
        return RESET, EdgeInfo(kill=True, live_causes=("rst",))

    kind, data = (inp.op if inp.op is not None else (None, 0))
    wr_ctrl = kind == "ctrl"
    arm_req = wr_ctrl and bool(data & 1)                           # v3.1 c: bits 31:3 ignored
    disarm_wr = wr_ctrl and bool(data & 2)
    fclr = wr_ctrl and bool(data & 4)
    combined = arm_req and fclr                                    # v3.1 a
    commit = kind == "commit"

    range_bad = commit and not (in_range(st.cmd_l) and in_range(st.cmd_r))   # decision F, armed or not
    stale_hit = bool(st.armed) and st.stale_cnt == 1               # A4
    estop_kill = bool(inp.estop_live)                               # A5 (implied by disarm_in in soc_top)

    live = []
    if inp.disarm_in: live.append("disarm_in")
    if estop_kill: live.append("estop_live")
    if stale_hit: live.append("stale_hit")
    if range_bad: live.append("range_bad")
    if disarm_wr: live.append("disarm_wr")
    latched_before = st.latched()
    kill = bool(live) or latched_before                             # P1 KILL

    n = dict(st.__dict__)
    # latches are ORed with every applicable cause (P1)
    n["f_stale"] = st.f_stale | int(stale_hit)
    n["f_range"] = st.f_range | int(range_bad)
    n["estop_seen"] = st.estop_seen | int(bool(inp.estop_live))

    if wr_ctrl:                                                     # A3
        n["arm_rej"], n["reason"] = 0, R_NONE

    def reject(reason):
        n["arm_rej"], n["reason"] = 1, reason

    def first_reason(conds):                                        # A1
        for code, c in conds:
            if c:
                return code
        return R_NONE

    act_or_sh_nz = bool(st.act_l or st.act_r or st.sh_l or st.sh_r)   # A9
    cmd_nz = bool(st.cmd_l or st.cmd_r)

    info = dict(kill=kill, live_causes=tuple(live))

    reloaded = False
    if kill:
        n.update(armed=0, act_l=0, act_r=0, sh_l=0, sh_r=0, cmd_l=0, cmd_r=0, stale_cnt=0,
                 ghost_commit_since_arm=0)                           # P1 / R3
        if wr_ctrl:
            if combined:
                reject(R_COMBINED); info["ctrl_result"] = "rejected"
            elif fclr and not live:
                # P1 exception / P2: the only KILL term is "fault already latched" (R1)
                r = first_reason([(R_ARMED, st.armed), (R_ACTIVE_NZ, act_or_sh_nz), (R_CMD_NZ, cmd_nz)])
                if r:
                    reject(r); info["ctrl_result"] = "rejected"
                else:
                    n.update(f_stale=0, f_range=0, estop_seen=0); info["ctrl_result"] = "fclr_ok"
            elif fclr or arm_req:
                # A1/A2 (owner Q3): live kill term beats everything except reason 7; only-latched-fault ARM -> 2.
                r = R_KILL_EDGE if live else (R_FAULT if (latched_before and arm_req) else R_NONE)
                assert r, "kill edge without a reason"
                reject(r); info["ctrl_result"] = "rejected"
            elif disarm_wr:
                info["ctrl_result"] = "disarm_only"
            else:
                info["ctrl_result"] = "noop"
        if commit:
            info["commit_result"] = "range_fault" if range_bad else "discarded"
        if kind in ("cmd_l", "cmd_r"):
            info["cmd_write"] = "discarded"
    else:
        if wr_ctrl:
            if combined:                                             # v3.1 a/b
                reject(R_COMBINED); info["ctrl_result"] = "rejected"
            elif fclr:                                               # P2 (no fault latched: A8)
                r = first_reason([(R_ARMED, st.armed), (R_ACTIVE_NZ, act_or_sh_nz), (R_CMD_NZ, cmd_nz)])
                if r:
                    reject(r); info["ctrl_result"] = "rejected"
                else:
                    info["ctrl_result"] = "fclr_ok"
            elif arm_req:                                            # P3
                r = first_reason([(R_ARMED, st.armed), (R_ACTIVE_NZ, act_or_sh_nz), (R_CMD_NZ, cmd_nz)])
                if r:
                    reject(r); info["ctrl_result"] = "rejected"
                else:
                    n.update(armed=1, stale_cnt=p.stale, ghost_commit_since_arm=0)
                    reloaded = True
                    info["ctrl_result"] = "arm_ok"
            else:
                info["ctrl_result"] = "noop"
        elif kind == "cmd_l":
            n["cmd_l"] = s16(data); info["cmd_write"] = "kept"       # A10/A11
        elif kind == "cmd_r":
            n["cmd_r"] = s16(data); info["cmd_write"] = "kept"
        elif commit:
            if st.armed:                                             # P4
                n.update(act_l=st.cmd_l, act_r=st.cmd_r, stale_cnt=p.stale)
                if st.cmd_l or st.cmd_r:
                    n["ghost_commit_since_arm"] = 1
                reloaded = True
                info["commit_result"] = "accepted"
            else:                                                    # P5
                info["commit_result"] = "ignored"
        if st.armed and not reloaded:                                # A4
            n["stale_cnt"] = st.stale_cnt - 1

    # PWM counter and rollover row (A7)
    rollover = st.pwm_cnt == p.period - 1
    n["pwm_cnt"] = 0 if rollover else st.pwm_cnt + 1
    if not kill and rollover:
        n["sh_l"], n["sh_r"] = n["act_l"], n["act_r"]               # SHADOW <= ACTIVE_next
    info["rollover"] = rollover
    return State(**n), EdgeInfo(**info)


@dataclass(frozen=True)
class Outputs:
    safe: int
    pin_l: int
    pin_r: int
    dir_l: int
    dir_r: int
    en: int
    # STATUS fields by name (bit positions: see STATUS_BITS; some are not fixed by the contract text)
    armed: int
    f_stale: int
    f_range: int
    wdt_trip: int
    estop_live: int
    active_zero: int
    arm_rej: int
    shadow_zero: int
    estop_seen: int
    reason: int


# STATUS bit positions as far as the contract documents fix them. None = not fixed by contract text (ambiguity Q1).
# Owner decision Q1: ESTOP_SEEN = bit 8. bit10 DISARM_IN per A13 (approved 2026-11-05).
STATUS_BITS = {"armed": 0, "f_stale": 1, "f_range": 2, "wdt_trip": 3, "estop_live": 4, "safe": 5,
               "active_zero": 6, "arm_rej": 7, "estop_seen": 8, "shadow_zero": 9, "disarm_in": 10, "reason": (12, 14)}


def status_word(st: State, inp: Inputs, p: Params) -> int:
    o = outputs(st, inp, p)
    w = 0
    for name, b in STATUS_BITS.items():
        if name == "reason":
            w |= (o.reason & 7) << 12
        elif name == "disarm_in":
            w |= int(bool(inp.disarm_in)) << b
        else:
            w |= (getattr(o, name) & 1) << b
    return w


def read_data(st: State, inp: Inputs, p: Params, off: int) -> int:
    """A14: value latched into wb_dat_o by a read at offset off."""
    if off == OFF_CMD_L: return st.cmd_l & 0xFFFFFFFF
    if off == OFF_CMD_R: return st.cmd_r & 0xFFFFFFFF
    if off == OFF_STATUS: return status_word(st, inp, p)
    if off == 0x14: return ((st.act_r & 0xFFFF) << 16) | (st.act_l & 0xFFFF)
    if off == 0x18: return p.stale & 0xFFFFFFFF
    if off == 0x1C: return p.period & 0xFFFFFFFF   # owner decision F1 (2026-11-05): 0x1C PERIOD RO, normative v3.1
    return 0


def monitor(st: State, inp: Inputs, p: Params):
    """A15: (pwm_left_cmd, pwm_right_cmd) as 16-bit words."""
    o = outputs(st, inp, p)
    return (0, 0) if o.safe else (st.sh_l & 0xFFFF, st.sh_r & 0xFFFF)


# Input classes. SOC: combinations reachable in soc_top (estop -> actuator_disarm, wdt_expired -> flag_tripped ->
# actuator_disarm, combinationally). UNIT: soc_pwm-level only, impossible in the integrated SoC; reported separately.
SOC_ENVS = {"clear": dict(), "wdt": dict(disarm_in=1, wdt_trip=1), "estop": dict(disarm_in=1, estop_live=1),
            "disable": dict(disarm_in=1), "estop_wdt": dict(disarm_in=1, estop_live=1, wdt_trip=1)}
UNIT_ENVS = {"estop_unit": dict(estop_live=1), "wdt_unit": dict(wdt_trip=1), "estop_wdt_unit": dict(estop_live=1, wdt_trip=1)}


def soc_reachable(inp: Inputs) -> bool:
    return bool(inp.disarm_in) or not (inp.estop_live or inp.wdt_trip)


def outputs(st: State, inp: Inputs, p: Params) -> Outputs:
    safe = int(bool(inp.rst or inp.disarm_in or not st.armed or st.f_stale or st.f_range or st.estop_seen))
    pl = int(not safe and st.pwm_cnt < high_cycles(st.sh_l, p.period))
    pr = int(not safe and st.pwm_cnt < high_cycles(st.sh_r, p.period))
    dl = int(not safe and st.sh_l < 0)                                # A6
    dr = int(not safe and st.sh_r < 0)
    return Outputs(safe=safe, pin_l=pl, pin_r=pr, dir_l=dl, dir_r=dr, en=int(not safe),
                   armed=st.armed, f_stale=st.f_stale, f_range=st.f_range, wdt_trip=int(bool(inp.wdt_trip)),
                   estop_live=int(bool(inp.estop_live)), active_zero=int(st.act_l == 0 and st.act_r == 0),
                   arm_rej=st.arm_rej, shadow_zero=int(st.sh_l == 0 and st.sh_r == 0),
                   estop_seen=st.estop_seen, reason=st.reason)


def invariants(st: State, p: Params):
    """Contract-derived invariants on every reachable state. Returns a list of violated names."""
    bad = []
    if st.armed and st.latched(): bad.append("armed_with_fault")                     # v2 s5, v3 (c)
    if (st.act_l or st.act_r) and not st.armed: bad.append("active_nz_disarmed")     # pending-cmd (b)
    if (st.sh_l or st.sh_r) and not st.armed: bad.append("shadow_nz_disarmed")
    for v in (st.act_l, st.act_r, st.sh_l, st.sh_r):
        if not in_range(v): bad.append("active_or_shadow_out_of_range")
    if st.armed != (1 <= st.stale_cnt <= p.stale): bad.append("stale_cnt_vs_armed")   # A4
    if (st.act_l or st.act_r) and not st.ghost_commit_since_arm: bad.append("P1_active_without_commit")
    if st.latched() and (st.cmd_l or st.cmd_r): bad.append("staged_cmd_survives_fault")  # R2/R3
    if not (0 <= st.pwm_cnt < p.period): bad.append("pwm_cnt_range")
    return bad
