#!/usr/bin/env python3
"""M7B: independent reference for tb_soc_nav PWM expectations. Applies the C-mirror safety
filter (test_safety_c_mirror.f()) to the raw policy outputs and the firmware sensor words,
then the M2 contract-v3 motor command cmd=sign(x)*min(1000,(|x|*1000)>>7), x=v-w (L), v+w (R)
(sw/test/motor_cmd_ref.py). Values are 16-bit two's-complement words as committed."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from test_safety_c_mirror import f
from motor_cmd_ref import motor_cmd
def s8(x): return x-256 if x>127 else x
def dist_cm(w0,w1):
    q=[s8((w0>>(8*i))&255) for i in (2,3)]+[s8((w1>>(8*i))&255) for i in (0,1)]
    return ((min(q)+127)*403)>>8
cases=[((0x64646464,0x64646464),(0x17,0x07)),((0x32B09C9C,0x64646464),(0xE8,0x7F)),((0x88B03232,0x3232B088),(0x17,0x41))]
def duty(x): return motor_cmd(x) & 0xFFFF
def expected():
    st=(0,0); out=[]
    for (w0,w1),(v,w) in cases:
        d=dist_cm(w0,w1); st=f(st,s8(v),s8(w),d)
        out.append((d,st,duty(st[0]-st[1]),duty(st[0]+st[1])))
    return out
if __name__=='__main__':
    exp=[(0x0007,0x0075),(0xff8b,0x0075),(0xff4d,0x00b3)]
    for (d,st,l,r),(el,er) in zip(expected(),exp):
        print(f"dist={d}cm v,w={st} L=0x{l:04x} R=0x{r:04x}")
        assert (l,r)==(el,er),(l,r,el,er)
    assert expected()[2][1][0]==0
    print("nav expected-CMD reference matches tb_soc_nav constants")
