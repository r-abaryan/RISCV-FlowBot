#!/usr/bin/env python3
"""M11b M2 Stage 1: deterministic cycle reference model of soc_pwm (contract v3.1).

SIMULATION-ONLY verification aid. Written from the contract text
(docs/50_M2_MOTOR_CONTRACT.md section 3 priority table + v3.1 changes,
M2_STEP1_DECISIONS.md R1-R4, register map), NOT translated from rtl/periph/soc_pwm.v.
The same author wrote both, so independence is partial (see the doc).

Per clock edge the model applies, in priority order:
  0 async reset
  1 KILL = disarm_in | stale_hit | range_bad | CTRL.DISARM | fault latched
  2 FAULT_CLR (R1: evaluated when the only KILL term is "fault latched")
  3 ARM_REQ   4/5 COMMIT   rollover: SHADOW <= KILL ? 0 : ACTIVE_next
Bus: one Wishbone slave; a request is accepted on an edge iff cyc&stb&!ack
(the write takes effect on the edge that sets ack); ack <= request.

Usable as a library (Model, step) and by test_pwm_refmodel.py.
"""

CMD_MAX = 1000
RJ_NONE, RJ_KILL_EDGE, RJ_FAULT, RJ_DISARM_IN, RJ_ARMED, RJ_ACTIVE_NZ, RJ_CMD_NZ, RJ_COMBINED = range(8)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def in_range(v):
    return -CMD_MAX <= v <= CMD_MAX


class Model:
    FIELDS = ("armed", "fs", "fr", "es", "rej", "reason", "cmd_l", "cmd_r",
              "act_l", "act_r", "sh_l", "sh_r", "stale", "cnt", "ack", "rdat")

    def __init__(self, period, stale_cycles, mutate=None):
        assert period >= 2 and stale_cycles >= 2
        self.P = period
        self.S = stale_cycles
        self.mutate = mutate or set()   # model-side planted defects (negative controls)
        self.reset()

    def reset(self):
        self.armed = 0; self.fs = 0; self.fr = 0; self.es = 0
        self.rej = 0; self.reason = 0
        self.cmd_l = 0; self.cmd_r = 0; self.act_l = 0; self.act_r = 0
        self.sh_l = 0; self.sh_r = 0
        self.stale = 0; self.cnt = 0; self.ack = 0; self.rdat = 0

    def key(self):
        return tuple(getattr(self, f) for f in self.FIELDS)

    def load(self, key):
        for f, v in zip(self.FIELDS, key):
            setattr(self, f, v)

    # ---- combinational views of the current (registered) state + live inputs ----
    def fault(self):
        return self.fs or self.fr or self.es

    def safe(self, disarm):
        return (not self.armed) or self.fault() or disarm

    def high_count(self, v):
        # high cycles per period = floor(|v| * PERIOD / 1000)
        return (abs(v) * self.P) // 1000

    def pins(self, disarm):
        """(pl, pr, dl, dr, en, cl, cr) after the edge, for live disarm_in."""
        if self.safe(disarm):
            return (0, 0, 0, 0, 0, 0, 0)
        hi = 1 if "pwm_ge" in self.mutate else 0
        pl = int(self.cnt < self.high_count(self.sh_l) + hi)
        pr = int(self.cnt < self.high_count(self.sh_r) + hi)
        return (pl, pr, int(self.sh_l < 0), int(self.sh_r < 0), 1,
                self.sh_l & 0xFFFF, self.sh_r & 0xFFFF)

    def status_word(self, disarm, estop, wdt):
        sz = int(self.sh_l == 0 and self.sh_r == 0)
        az = int(self.act_l == 0 and self.act_r == 0)
        return (self.armed | self.fs << 1 | self.fr << 2 | wdt << 3 | estop << 4
                | int(bool(self.safe(disarm))) << 5 | az << 6 | self.rej << 7
                | self.es << 8 | sz << 9 | disarm << 10 | self.reason << 12)

    def read_reg(self, off, disarm, estop, wdt):
        if off == 0x04: return s16(self.cmd_l) & 0xFFFFFFFF
        if off == 0x08: return s16(self.cmd_r) & 0xFFFFFFFF
        if off == 0x10: return self.status_word(disarm, estop, wdt)
        if off == 0x14: return ((self.act_r & 0xFFFF) << 16) | (self.act_l & 0xFFFF)
        if off == 0x18: return self.S
        if off == 0x1C: return self.P
        return 0

    # ---- one rising clock edge ----
    def step(self, op, off=0, data=0, disarm=0, estop=0, wdt=0):
        """op: None (idle), 'W' write, 'R' read. Returns nothing; updates state."""
        req = op is not None and not self.ack
        wr = req and op == "W"
        rd = req and op == "R"
        wr_ctrl = wr and off == 0x00
        arm_req = wr_ctrl and bool(data & 1)
        dis_req = wr_ctrl and bool(data & 2)
        fclr_req = wr_ctrl and bool(data & 4)
        combo = arm_req and fclr_req and "combo_ok" not in self.mutate
        commit = wr and off == 0x0C

        stale_hit = self.armed and self.stale == 1
        range_bad = commit and not (in_range(self.cmd_l) and in_range(self.cmd_r))
        live = disarm or stale_hit or range_bad or dis_req
        kill = live or self.fault()
        a_zero = self.act_l == 0 and self.act_r == 0
        s_zero = self.sh_l == 0 and self.sh_r == 0
        c_zero = self.cmd_l == 0 and self.cmd_r == 0

        # pre-edge values for registered read data and next state
        n = dict((f, getattr(self, f)) for f in self.FIELDS)
        n["ack"] = int(req)
        if rd:
            n["rdat"] = self.read_reg(off, disarm, estop, wdt)

        if wr_ctrl:                     # ARM_REJECTED sticky until the next CTRL write
            n["rej"] = 0; n["reason"] = RJ_NONE
        if self.armed and self.stale != 0:
            n["stale"] = self.stale - 1

        def reject(r):
            n["rej"] = 1; n["reason"] = r

        def fclr_check():
            # Row 2 preconditions, first failing check wins
            if estop or disarm: return RJ_DISARM_IN
            if self.armed: return RJ_ARMED
            if not a_zero: return RJ_ACTIVE_NZ
            if not c_zero: return RJ_CMD_NZ
            return RJ_NONE

        commit_ok = commit and self.armed and not kill
        if kill:                        # Row 1
            n.update(armed=0, act_l=0, act_r=0, sh_l=0, sh_r=0, stale=0)
            if "kill_keeps_cmd" not in self.mutate:
                n.update(cmd_l=0, cmd_r=0)
            if stale_hit: n["fs"] = 1
            if range_bad: n["fr"] = 1
            if estop: n["es"] = 1
            if arm_req or fclr_req:
                if combo:
                    reject(RJ_COMBINED)          # v3.1: reason 7 wins, fault stays latched
                elif fclr_req and not live:       # R1 exception
                    r = fclr_check()
                    if r == RJ_NONE:
                        n.update(fs=0, fr=0, es=0)
                    else:
                        reject(r)
                else:
                    reject(RJ_KILL_EDGE if live else RJ_FAULT)
        else:
            if combo:
                reject(RJ_COMBINED)
            elif fclr_req:
                r = fclr_check()
                if r != RJ_NONE:
                    reject(r)
            if arm_req and not combo:   # Row 3 (no fault here: kill==0)
                if self.armed: reject(RJ_ARMED)
                elif not (a_zero and s_zero): reject(RJ_ACTIVE_NZ)
                elif not c_zero: reject(RJ_CMD_NZ)
                else:
                    n["armed"] = 1; n["stale"] = self.S
            if wr and off == 0x04: n["cmd_l"] = s16(data)
            if wr and off == 0x08: n["cmd_r"] = s16(data)
            if commit_ok:               # Row 4 (Row 5: not armed -> ignored)
                n.update(act_l=self.cmd_l, act_r=self.cmd_r, stale=self.S)
            if self.cnt == self.P - 1:  # rollover: SHADOW <= ACTIVE_next
                n["sh_l"] = n["act_l"]; n["sh_r"] = n["act_r"]
        n["cnt"] = 0 if self.cnt == self.P - 1 else self.cnt + 1
        for f in self.FIELDS:
            setattr(self, f, n[f])

    def snapshot(self, disarm):
        """Comparable observable tuple after an edge (matches the TB dump order)."""
        p = self.pins(disarm)
        return p + (self.armed, self.fs, self.fr, self.es, self.rej, self.reason,
                    self.cmd_l & 0xFFFF, self.cmd_r & 0xFFFF, self.act_l & 0xFFFF,
                    self.act_r & 0xFFFF, self.sh_l & 0xFFFF, self.sh_r & 0xFFFF,
                    self.stale, self.cnt, self.rdat)


DUMP_NAMES = ("pl", "pr", "dl", "dr", "en", "cl", "cr", "armed", "fault_stale",
              "fault_range", "estop_seen", "arm_rejected", "reason", "cmd_l", "cmd_r",
              "active_l", "active_r", "shadow_l", "shadow_r", "stale_cnt",
              "pwm_counter", "wb_dat_o")
