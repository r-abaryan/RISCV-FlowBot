import math, numpy as np
from m9b_stats import wilson, mcnemar_exact, paired_boot
# McNemar exact: known values. b=0,c=10 -> 2*0.5^10; b=c -> 1; b=3,c=7 n=10 -> 2*(1+10+45+120)/1024
assert abs(mcnemar_exact(0,10)-2*0.5**10) < 1e-15
assert mcnemar_exact(5,5) == 1.0 and mcnemar_exact(0,0) == 1.0
assert abs(mcnemar_exact(3,7)-2*176/1024) < 1e-15 and mcnemar_exact(7,3) == mcnemar_exact(3,7)
# Wilson: 0/n lower=0; 50/100 symmetric around .5; reference value 81/100 -> [0.7222,0.8748] (hand-computed)
lo,hi = wilson(0,400); assert lo < 1e-12 and 0 < hi < 0.01
lo,hi = wilson(50,100); assert abs((lo+hi)/2-0.5) < 1e-9 and abs(lo-0.4038) < 5e-4
lo,hi = wilson(81,100); assert abs(lo-0.7222) < 5e-4 and abs(hi-0.8748) < 5e-4
# bootstrap: identical -> diff 0 interval 0; deterministic; all-better -> positive interval; paired covers sign
x = np.ones(100); assert paired_boot(x,x) == (0.0,0.0,0.0)
r = np.random.RandomState(5).randint(0,2,200); assert paired_boot(r,1-r) == paired_boot(r,1-r)
d,lo,hi = paired_boot(np.ones(100), np.r_[np.ones(60), np.zeros(40)]); assert abs(d-0.4)<1e-12 and lo > 0.25 and hi < 0.55
# paired structure: swapping arguments negates the interval exactly
a = np.random.RandomState(1).randint(0,2,300); b = np.random.RandomState(2).randint(0,2,300)
d1,l1,h1 = paired_boot(a,b); d2,l2,h2 = paired_boot(b,a); assert abs(d1+d2)<1e-12 and abs(l1+h2)<1e-9 and abs(h1+l2)<1e-9
# normal-approx sanity for McNemar large n: b=40,c=20 -> p ~ 0.0092
assert 0.005 < mcnemar_exact(40,20) < 0.015
print("OK test_m9b_stats: 10 checks passed")
