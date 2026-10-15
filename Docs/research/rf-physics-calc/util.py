import numpy as np, mpmath as mp
def quad(f,a,b,limit=None,points=None):
    pts=[a]+(list(points) if points else [])+[b]
    v=mp.quad(lambda x: f(float(x)), pts)
    return float(v),0.0
def brentq(g,a,b,xtol=1e-13):
    fa=g(a); fb=g(b)
    if fa*fb>0: raise ValueError('no sign change')
    for _ in range(200):
        m=0.5*(a+b); fm=g(m)
        if fa*fm<=0: b,fb=m,fm
        else: a,fa=m,fm
        if b-a<xtol: break
    return 0.5*(a+b)
def argrelmax(a):
    a=np.asarray(a)
    idx=np.where((a[1:-1]>a[:-2])&(a[1:-1]>a[2:]))[0]+1
    return (idx,)
