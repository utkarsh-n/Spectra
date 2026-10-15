import warnings; warnings.filterwarnings('ignore')
import numpy as np
import mpmath as mp
from util import quad, brentq, argrelmax
c=299792458.0; eta0=376.730313412; eta120=120*np.pi; k_B=1.380649e-23
def db(x): return 10*np.log10(x)
print("=== A1 Hertzian dipole")
for dl in [0.01,0.05]:
    print(f"dl/lam={dl}: Rr(80pi^2)={80*np.pi**2*dl**2:.6f}  Rr(2pi/3*eta0)={2*np.pi/3*eta0*dl**2:.6f}")
print("D=1.5 ->", db(1.5))
print("short dipole triangular l=0.1lam Rr=20pi^2(l)^2:", 20*np.pi**2*0.01, " eta0/(6pi)... ", eta0*np.pi/6*0.01)
print("=== A2 thin dipole arbitrary length")
def F(th,L):  # L in wavelengths, total length
    kl2=np.pi*L
    return ((np.cos(kl2*np.cos(th))-np.cos(kl2))/np.sin(th))**2
def dip(L,eta=eta0):
    kl2=np.pi*L
    I,_=quad(lambda t: F(t,L)*np.sin(t),1e-9,np.pi-1e-9,limit=400)
    # radiated power with I0=1: P = eta/(4pi) * I  (Balanis 4-68 form) -> Rr(at current max) = 2P = eta/(2pi) I
    Rr_max = eta/(2*np.pi)*I
    # max of pattern
    th=np.linspace(1e-6,np.pi-1e-6,200001); f=F(th,L); Umax=f.max(); thmax=th[f.argmax()]
    D=2*Umax/I   # D = 4pi Umax / P_total; U ∝ F/(..) => D = 2 F_max / ∫F sin
    Rin = Rr_max/np.sin(kl2)**2 if abs(np.sin(kl2))>1e-6 else np.inf
    # HPBW around main lobe
    half=Umax/2
    g=lambda t: F(t,L)-half
    # search below thmax
    try:
        t1=brentq(g,1e-6,thmax) ; t2=brentq(g,thmax,np.pi-1e-6)
        hp=np.degrees(t2-t1)
    except Exception as e: hp=None
    return Rr_max,Rin,D,db(D),hp,np.degrees(thmax)
for L in [0.1,0.25,0.5,0.75,1.0,1.25,1.5]:
    Rr,Rin,D,DdB,hp,tm=dip(L)
    print(f"L={L}: Rr(max current)={Rr:.3f}  Rin(center)={Rin:.3f}  D={D:.4f} ({DdB:.3f} dBi) HPBW={hp}  theta_max={tm:.2f}")
print("half-wave with eta=120pi:", dip(0.5,eta120)[0])
Cin2pi = np.euler_gamma+np.log(2*np.pi)-float(mp.ci(2*np.pi))
print("Cin(2pi)=",Cin2pi," Rr=eta0*Cin/(4pi)=",eta0*Cin2pi/(4*np.pi), " eta120:",eta120*Cin2pi/(4*np.pi))
print("=== A3 monopole")
Rr,Rin,D,DdB,hp,tm=dip(0.5)
print(f"quarter-wave monopole Rr={Rr/2:.3f} D={2*D:.4f} ({db(2*D):.3f} dBi)")
print("=== A4 small loop")
for a in [0.02]:
    C=2*np.pi*a; A=np.pi*a**2
    print(f"a={a}lam C/lam={C:.5f} Rr=20pi^2(C/lam)^4={20*np.pi**2*C**4:.6e}  31171(A/l^2)^2={31171*A**2:.6e} exact 320pi^4={320*np.pi**4*A**2:.6e} eta0 form={(8/3)*eta0*np.pi**3*A**2:.6e}")
print("320*pi^4=",320*np.pi**4, " (8/3)eta0 pi^3=",(8/3)*eta0*np.pi**3)
# NFC loop
f=13.56e6; lam=c/f; A=0.04*0.03; N=4
print(f"NFC: lam={lam:.4f} m, A={A} m2, N={N}, Rr={N**2*31171*(A/lam**2)**2:.3e} ohm")
# AM ferrite
f=1e6; lam=c/f; A=np.pi*0.005**2; N=60; mu=100
Rr=N**2*31171*(A/lam**2)**2
print(f"AM ferrite 1 MHz: lam={lam:.2f}, A={A:.4e}, N={N}, Rr_air={Rr:.3e}, mu_eff={mu}, Rr_ferrite={mu**2*Rr:.3e}")
print("=== A5 patch")
def patch(er,h,fr):
    W=c/(2*fr)*np.sqrt(2/(er+1))
    ee=(er+1)/2+(er-1)/2*(1+12*h/W)**-0.5
    dL=0.412*h*(ee+0.3)*(W/h+0.264)/((ee-0.258)*(W/h+0.8))
    L=c/(2*fr*np.sqrt(ee))-2*dL
    return W,ee,dL,L
W,ee,dL,L=patch(2.2,1.588e-3,10e9); print(f"Balanis ex: W={W*100:.4f} cm eeff={ee:.4f} dL={dL*100:.4f} cm L={L*100:.4f} cm")
W,ee,dL,L=patch(4.4,1.6e-3,2.45e9); print(f"FR4 2.45GHz: W={W*1000:.3f} mm eeff={ee:.4f} dL={dL*1000:.4f} mm L={L*1000:.3f} mm")
W,ee,dL,L=patch(20,4e-3,1575.42e6); print(f"GPS ceramic er=20 h=4mm: W={W*1000:.3f} mm eeff={ee:.4f} dL={dL*1000:.4f} mm L={L*1000:.3f} mm ; naive lam/(2sqrt(er))={c/1575.42e6/2/np.sqrt(20)*1000:.3f} mm")
print("=== A6 Yagi NBS TN688 dBd->dBi")
for b,n,g in [(0.4,3,7.1),(0.8,5,9.2),(1.2,6,10.2),(2.2,12,12.25),(3.2,17,13.4),(4.2,15,14.2)]:
    print(f"boom {b} lam, {n} el: {g} dBd = {g+2.15:.2f} dBi")
print("dBd offset exact:",db(dip(0.5)[2]))
print("=== A7 helix")
def helix(Cl,n,Sl):
    D=12*Cl**2*n*Sl; hp=52/(Cl*np.sqrt(n*Sl)); R=140*Cl; Lw=n*Sl
    G_em=10.25+1.22*Lw-0.0726*Lw**2
    AR=(2*n+1)/(2*n)
    return D,db(D),hp,R,G_em,AR
for args in [(1.0,10,0.25),(1.15,5,0.2444),(1.0,20,0.25)]:
    print(args, ["%.4f"%x for x in helix(*args)])
print("10log10(12)=",db(12))
print("=== A8 horn")
lam=c/10e9; A=0.1; B=0.08
G=4*np.pi*A*B*0.51/lam**2; print(f"horn 10GHz A={A} B={B} lam={lam:.6f}: G={G:.3f} ({db(G):.3f} dBi)")
print("=== A9 dish")
lam=c/12e9; D=0.6; eta=0.65
G=eta*(np.pi*D/lam)**2; print(f"dish 12GHz D=0.6 eta=.65: lam={lam:.6f} G={G:.2f} ({db(G):.3f} dBi) HPBW70={70*lam/D:.4f} deg HPBW58.4={58.4*lam/D:.4f}")
lam=c/28e9; D=0.3
print(f"dish 28GHz D=0.3 eta=0.6: G={db(0.6*(np.pi*D/lam)**2):.3f} dBi")
print("=== A10 ULA")
def AF(theta,N,d,beta):
    psi=2*np.pi*d*np.cos(theta)+beta
    num=np.sin(N*psi/2); den=N*np.sin(psi/2)
    out=np.where(np.abs(den)<1e-12,1.0,num/np.where(np.abs(den)<1e-12,1,den))
    return out
N=8; d=0.5
th=np.linspace(0,np.pi,2000001)
for th0deg in [90,60]:
    beta=-2*np.pi*d*np.cos(np.radians(th0deg))
    a=np.abs(AF(th,N,d,beta))**2
    imax=a.argmax(); 
    # HPBW exact
    above=np.where(a>=0.5)[0]
    # contiguous around imax
    i1=imax
    while i1>0 and a[i1-1]>=0.5: i1-=1
    i2=imax
    while i2<len(a)-1 and a[i2+1]>=0.5: i2+=1
    print(f"N={N} d={d} theta0={th0deg}: beta={np.degrees(beta):.3f} deg, peak at {np.degrees(th[imax]):.3f}, HPBW exact={np.degrees(th[i2]-th[i1]):.4f} deg")
    # SLL
print("broadside approx HPBW 2(pi/2-arccos(1.391/(pi N d))):", 2*(90-np.degrees(np.arccos(1.391/(np.pi*N*d)))))
print("AF at theta=45 (broadside N=8,d=.5):", AF(np.radians(45),8,0.5,0.0))
print("first sidelobe level (N=8):", )
a=np.abs(AF(th,8,0.5,0.0))**2
# find local maxima excluding main
idx=argrelmax(a)[0]; vals=sorted(a[idx])[::-1]
print("sidelobes dB:", [round(db(v),3) for v in vals[:4]])
print("grating limit d/lam < 1/(1+|cos th0|): th0=60 ->",1/(1+abs(np.cos(np.radians(60)))), " th0=30(from axis)->",1/(1+np.cos(np.radians(30))))
# directivity broadside numeric
def Dnum(N,d,beta):
    I,_=quad(lambda t: (np.abs(AF(np.array([t]),N,d,beta))**2)[0]*np.sin(t),0,np.pi,limit=500,points=[np.pi/2])
    return 2/I
print("D broadside N=8 d=.5:",Dnum(8,0.5,0.0), db(Dnum(8,0.5,0.0)), " approx 2Nd/lam=",2*8*0.5)
print("=== A11 planar array")
print("8x8 of 5 dBi elements ideal:", 5+db(64), " 4x1 module", 5+db(4))
print("lambda/2 at 28GHz mm:", c/28e9/2*1000, " at 39 GHz:", c/39e9/2*1000)
print("=== A12 Friis etc")
f=2.45e9; lam=c/f; d=10
fspl=20*np.log10(4*np.pi*d/lam); print(f"FSPL 2.45GHz 10m: {fspl:.4f} dB; Pr(20dBm,0,0)={20-fspl:.4f} dBm")
print("Ae of half-wave at 1 GHz:", 1.6409*(c/1e9)**2/(4*np.pi))
Dhw=dip(0.5)[2]; print("Ae exact Dhw:",Dhw*(c/1e9)**2/(4*np.pi))
print("PLF 45deg:", db(np.cos(np.radians(45))**2))
for ZL,Z0 in [(73,50),(36.5,50),(73+42.5j,50),(100,50)]:
    G=(ZL-Z0)/(ZL+Z0); g=abs(G)
    print(f"ZL={ZL}: Gamma={G:.5f} |G|={g:.5f} VSWR={(1+g)/(1-g):.5f} RL={-20*np.log10(g):.4f} dB ML={-10*np.log10(1-g**2):.5f} dB")
print("near-field lam/2pi at 2.4GHz mm:", c/2.4e9/(2*np.pi)*1000)
lam=c/12e9; D=0.6
print(f"dish 0.6m 12GHz: 2D^2/lam={2*D**2/lam:.4f} m, 0.62sqrt(D^3/lam)={0.62*np.sqrt(D**3/lam):.4f} m")
print("FSPL const 20log10(4pi/c)=",20*np.log10(4*np.pi/c))
print("P.525 const 32.4: 20log10(4pi*1e3*1e6/c)=",20*np.log10(4*np.pi*1e9/c))
