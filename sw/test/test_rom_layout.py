#!/usr/bin/env python3
"""M7C: verify robot_nav.hex ROM image against nav_weights.inc at the ELF symbol addresses.
Usage: test_rom_layout.py [hex] ; --selftest runs a negative corruption test."""
import re, subprocess, sys, os, shutil
FW=os.path.join(os.path.dirname(__file__),'..','firmware')
def inc_words():
    t=open(f'{FW}/nav_weights.inc').read(); cur=None; d={}
    for l in t.splitlines():
        m=re.match(r'(l[12]_(?:weights|biases)):',l.strip())
        if m: cur=m.group(1); d[cur]=[]; continue
        m=re.match(r'\.word\s+(0x[0-9a-fA-F]+)',l.strip())
        if m and cur: d[cur].append(int(m.group(1),16))
    return d
def syms():
    out=subprocess.check_output(['riscv-none-elf-nm',f'{FW}/robot_nav.elf'],text=True)
    return {l.split()[2]:int(l.split()[0],16) for l in out.splitlines() if len(l.split())==3}
def check(hexf):
    rom=[int(x,16) for x in open(hexf).read().split() if not x.startswith('//')]
    d=inc_words(); s=syms(); err=0
    exp_len={'l1_weights':32,'l1_biases':8,'l2_weights':4,'l2_biases':2}  # words: 8x16 and 2x8 INT8 bytes/4; biases int32
    for k,w in d.items():
        a=s[k]; assert a%4==0 and a<0x2000
        if len(w)!=exp_len[k]: print(f'FAIL {k}: {len(w)} words, expected {exp_len[k]}'); err+=1
        got=rom[a//4:a//4+len(w)]
        if got!=w:
            bad=[i for i,(x,y) in enumerate(zip(got,w)) if x!=y]
            print(f'FAIL {k}@0x{a:x}: {len(bad)} mismatching words, first idx {bad[:3]}'); err+=1
        else: print(f'OK   {k}@0x{a:08x} {len(w)} words match')
    return err
if __name__=='__main__':
    hexf=f'{FW}/robot_nav.hex'
    if '--selftest' in sys.argv:
        assert check(hexf)==0
        s=syms(); lines=open(hexf).read().split('\n'); i=s['l1_weights']//4+5
        lines[i]='%08x'%(int(lines[i],16)^0x00000100); open('/tmp/corrupt.hex','w').write('\n'.join(lines))
        e=check('/tmp/corrupt.hex'); assert e>0,'corruption NOT detected'
        print('NEGATIVE SELFTEST PASS: single-bit corruption detected'); sys.exit(0)
    sys.exit(1 if check(hexf) else 0)
