import numpy as np, json, math, mpmath as mp
c=299792458.0
def db(x): return 10*np.log10(x)
T=json.load(open('p676_tables.json'))
def gamma_p676(f, p_tot=1013.25, rho=7.5, Tc=15.0):
    Tk=Tc+273.15; th=300.0/Tk
    e=rho*Tk/216.7; p=p_tot-e
    No=0.0
    for f0,a1,a2,a3,a4,a5,a6 in T['ox']:
        S=a1*1e-7*p*th**3*math.exp(a2*(1-th))
        df=a3*1e-4*(p*th**(0.8-a4)+1.1*e*th)
        df=math.sqrt(df**2+2.25e-6)
        dl=(a5+a6*th)*1e-4*(p+e)*th**0.8
        F=f/f0*((df-dl*(f0-f))/((f0-f)**2+df**2)+(df-dl*(f0+f))/((f0+f)**2+df**2))
        No+=S*F
    d=5.6e-4*(p+e)*th**0.8
    ND=f*p*th**2*(6.14e-5/(d*(1+(f/d)**2))+1.4e-12*p*th**1.5/(1+1.9e-5*f**1.5))
    No+=ND
    Nw=0.0
    for f0,b1,b2,b3,b4,b5,b6 in T['wv']:
        S=b1*1e-1*e*th**3.5*math.exp(b2*(1-th))
        df=b3*1e-4*(p*th**b4+b5*e*th**b6)
        df=0.535*df+math.sqrt(0.217*df**2+2.1316e-12*f0**2/th)
        F=f/f0*((df)/((f0-f)**2+df**2)+(df)/((f0+f)**2+df**2))
        Nw+=S*F
    return 0.1820*f*No, 0.1820*f*Nw
print("=== P.676 (Standard atm 1013.25 hPa, 15C, 7.5 g/m3)")
for f in [1,2.4,5,10,22.235,24,28,39,57,60,60.3,61,64,71,94,118.75,140,183.31]:
    go,gw=gamma_p676(f); print(f"f={f} GHz: gamma_o={go:.4f} gamma_w={gw:.4f} total={go+gw:.4f} dB/km")
best=max(((gamma_p676(f)[0],f) for f in np.arange(55,66,0.01)))
print("max oxygen 55-66 GHz:",best)
go,gw=gamma_p676(60,rho=0); print("dry atm 60 GHz:", go)
print("=== P.838 rain")
for f,kH,aH,kV,aV in [(28,0.2051,0.9679,0.1964,0.9277),(39,0.4215,0.8743,0.4058,0.8486),(60,0.8606,0.7656,0.8515,0.7486)]:
    for R in [5,25,50]:
        print(f"f={f} R={R}: gammaH={kH*R**aH:.4f} gammaV={kV*R**aV:.4f} dB/km")
print("=== P.2109 BEL")
def Finv(P):
    # inverse normal CDF via mpmath
    return float(mp.sqrt(2)*mp.erfinv(2*P-1))
def bel(f,P=0.5,theta=0,kind='trad'):
    r,s,t,u,v,w,x,y,z = (12.64,3.72,0.96,9.6,2.0,9.1,-3.0,4.5,-2.0) if kind=='trad' else (28.19,-3.00,8.48,13.5,3.8,27.8,-2.9,9.4,-2.1)
    lf=math.log10(f)
    Lh=r+s*lf+t*lf**2; Le=0.212*abs(theta)
    mu1=Lh+Le; mu2=w+x*lf; s1=u+v*lf; s2=y+z*lf
    A=Finv(P)*s1+mu1; B=Finv(P)*s2+mu2; C=-3.0
    return 10*math.log10(10**(0.1*A)+10**(0.1*B)+10**(0.1*C))
for f in [0.7,0.9,1.8,2.4,3.5,5.5,28,39,60]:
    print(f"f={f}: trad median={bel(f):.3f} dB, therm-eff median={bel(f,kind='te'):.3f} dB")
print("=== FSPL / Friis")
def fspl(d,f): return 20*math.log10(d)+20*math.log10(f)-147.55221677811664
print("1 km 1 GHz:",fspl(1000,1e9)," P.525:",32.4+20*math.log10(1000)+20*math.log10(1))
print("GPS 20200 km 1575.42MHz:",fspl(20200e3,1575.42e6))
print("=== log-distance")
f=2.4e9; PL0=fspl(1,f); print("PL(1m,2.4GHz)=",PL0," n=3 d=20:",PL0+30*math.log10(20))
print("=== two-ray")
ht,hr,f=30,1.5,900e6; lam=c/f
print("lam",lam," dx=4pi ht hr/lam:",4*np.pi*ht*hr/lam," Goldsmith dc=4 ht hr/lam:",4*ht*hr/lam)
for d in [100,1000,10000]:
    asym=40*math.log10(d)-20*math.log10(ht*hr)
    # exact with Gamma=-1
    dlos=math.sqrt(d**2+(ht-hr)**2); dref=math.sqrt(d**2+(ht+hr)**2)
    k=2*np.pi/lam
    E=np.exp(-1j*k*dlos)/dlos + (-1)*np.exp(-1j*k*dref)/dref
    PL=-20*math.log10(lam/(4*np.pi)*abs(E))
    print(f"d={d}: asymptotic PL={asym:.3f} dB exact(Gamma=-1)={PL:.3f} dB, FSPL={fspl(d,f):.3f}")
print("=== Hata")
def hata(f,hb,hm,d,env='urban_small'):
    a=(1.1*math.log10(f)-0.7)*hm-(1.56*math.log10(f)-0.8)
    if env=='urban_large': a=3.2*(math.log10(11.75*hm))**2-4.97
    L=69.55+26.16*math.log10(f)-13.82*math.log10(hb)-a+(44.9-6.55*math.log10(hb))*math.log10(d)
    return L,a
L,a=hata(900,30,1.5,5); print(f"Hata urban small/med f=900 hb=30 hm=1.5 d=5: a={a:.4f} L={L:.3f}")
L2,a2=hata(900,30,1.5,5,'urban_large'); print(f"large city: a={a2:.4f} L={L2:.3f}")
print(" suburban:",L-2*(math.log10(900/28))**2-5.4, " open:",L-4.78*(math.log10(900))**2+18.33*math.log10(900)-40.94)
def cost231(f,hb,hm,d,Cm=0):
    a=(1.1*math.log10(f)-0.7)*hm-(1.56*math.log10(f)-0.8)
    return 46.3+33.9*math.log10(f)-13.82*math.log10(hb)-a+(44.9-6.55*math.log10(hb))*math.log10(d)+Cm
print("COST231 f=1800 hb=30 hm=1.5 d=2 Cm=0:",cost231(1800,30,1.5,2), " Cm=3:",cost231(1800,30,1.5,2,3))
print("=== knife edge")
def J(nu): return 6.9+20*math.log10(math.sqrt((nu-0.1)**2+1)+nu-0.1) if nu>-0.78 else 0.0
lam=c/900e6; h=10; d1=d2=1000
nu=h*math.sqrt(2/lam*(1/d1+1/d2)); print(f"nu={nu:.5f} J={J(nu):.4f} dB; J(0)={J(0):.4f}; J(-0.78)={6.9+20*math.log10(math.sqrt(0.88**2+1)-0.88):.4f}")
# exact Fresnel
def Jexact(nu):
    C=float(mp.fresnelc(nu)); S=float(mp.fresnels(nu))
    return -20*math.log10(math.sqrt((1-C-S)**2+(C-S)**2)/2)
print("exact J(nu)=",Jexact(nu)," exact J(0)=",Jexact(0))
print("=== fading")
for fade in [10,20,30]:
    g=10**(-fade/10); print(f"Rayleigh P(power < mean-{fade}dB)={1-math.exp(-g):.6f}")
print("=== Doppler / coherence")
v=30; f=3.5e9; fd=v*f/c; print(f"fd={fd:.4f} Hz, Tc0.423={0.423/fd*1e3:.4f} ms, Tc 9/(16pi fd)={9/(16*np.pi*fd)*1e3:.4f} ms, 1/fd={1/fd*1e3:.4f} ms")
v=100/3.6; f=2e9; fd=v*f/c; print(f"100 km/h 2GHz fd={fd:.4f}")
st=1e-6; print(f"sigma_tau=1us Bc50={1/(5*st)/1e3} kHz Bc90={1/(50*st)/1e3} kHz")
