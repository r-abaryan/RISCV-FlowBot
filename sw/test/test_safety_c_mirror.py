#!/usr/bin/env python3
"""Integer mirror of safety_filter_command() in sw/firmware/safety_driver.h.
NOT compiled C (no C compiler in sandbox); keep in sync by hand."""
V=64;W=64;SL=8;STOP=25
def f(last,rv,rw,d):
    lv,lw=last
    tv=max(-V,min(V,rv)); tw=max(-W,min(W,rw))
    tv=max(lv-SL,min(lv+SL,tv)); tw=max(lw-SL,min(lw+SL,tw))
    d=max(d,0)
    if d<=STOP:
        tv=min(tv,0)
    elif tv>0:
        tv=min(tv,((d-STOP)*5)>>3)
    return tv,tw
def main():
    st=(64,0)
    st=f(st,64,0,10); assert st[0]<=0,st   # was 56 before fix
    st=(0,0)
    for _ in range(20): st=f(st,127,0,-5); assert st[0]<=0
    import random; random.seed(1); st=(0,0)
    for _ in range(50000):
        d=random.randint(-50,300)
        st=f(st,random.randint(-128,127),random.randint(-128,127),d)
        assert abs(st[0])<=V and abs(st[1])<=W
        if d<=STOP: assert st[0]<=0
        # one tick at 0.02s: 1 LSB=1/128*... m/s, distance travelled stays above margin
        assert st[0]<=0 or st[0]*0.0078125*0.02*100 <= d-STOP
    print("C mirror safety tests passed")
main()
