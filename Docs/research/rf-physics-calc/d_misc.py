# Patch two-slot directivity, Hann/FFT scaling, 3GPP TR 38.901 O2I + path loss, MIMO capacity.
# Run from this folder: python3 d_misc.py   (needs numpy only)
import numpy as np, math
c=299792458.0; lg=math.log10
trap=getattr(np,'trapezoid',None) or np.trapz
def patch(er,h,fr):
    W=c/(2*fr)*np.sqrt(2/(er+1))
    ee=(er+1)/2+(er-1)/2*(1+12*h/W)**-0.5
    dL=0.412*h*(ee+0.3)*(W/h+0.264)/((ee-0.258)*(W/h+0.8))
    L=c/(2*fr*np.sqrt(ee))-2*dL
    return W,ee,dL,L
def patch_D(er,h,fr,n=2000):
    W,ee,dL,L=patch(er,h,fr); lam=c/fr; k0=2*np.pi/lam; Le=L+2*dL
    th=np.linspace(1e-6,np.pi-1e-6,n); ph=np.linspace(0,np.pi,n)
    T,P=np.meshgrid(th,ph,indexing='ij')
    f=np.where(np.abs(np.cos(T))<1e-9,(k0*W/2)**2,(np.sin(k0*W/2*np.cos(T))/np.cos(T))**2)
    I2=trap(trap(f*np.sin(T)**3*np.cos(k0*Le/2*np.sin(T)*np.sin(P))**2,ph,axis=1),th)
    f1=np.where(np.abs(np.cos(th))<1e-9,(k0*W/2)**2,(np.sin(k0*W/2*np.cos(th))/np.cos(th))**2)
    I1=trap(f1*np.sin(th)**3,th)
    return (2*np.pi*W/lam)**2/I1, (2*np.pi*W/lam)**2*np.pi/I2
for args in [(2.2,1.588e-3,10e9),(4.4,1.6e-3,2.45e9),(1.0001,3e-3,5.8e9),(20,4e-3,1575.42e6)]:
    D1,D2=patch_D(*args); print("patch",args,"single-slot %.3f dBi, two-slot %.3f dBi"%(10*lg(D1),10*lg(D2)))
N=1024; n=np.arange(N)
for name,w in [('hann periodic',0.5*(1-np.cos(2*np.pi*n/N))),('hann symmetric',0.5*(1-np.cos(2*np.pi*n/(N-1)))),('rect',np.ones(N))]:
    CG=w.sum()/N; ENBW=N*(w**2).sum()/w.sum()**2
    M=N*64; W=np.abs(np.fft.fft(w,M)); W/=W[0]; WdB=20*np.log10(np.maximum(W[:M//2],1e-300))
    i=1
    while WdB[i+1]<WdB[i]: i+=1
    print(f"{name}: CG={CG:.5f} ENBW={ENBW:.5f} scallop={-WdB[32]:.4f} dB highestSL={WdB[i:M//8].max():.3f} dB")
x=np.cos(2*np.pi*100*n/N); print("|X[100]| rect =",abs(np.fft.rfft(x)[100]),"(vDSP zrop gives 2x)")
def o2i(f,model='low'):
    Lg=2+0.2*f; Lirr=25.4+0.11*f; Lc=5+4*f
    return 5-10*lg(0.3*10**(-Lg/10)+0.7*10**(-Lc/10)) if model=='low' else 5-10*lg(0.7*10**(-Lirr/10)+0.3*10**(-Lc/10))
for f in [3.5,28]: print("O2I",f,"GHz low %.3f high %.3f"%(o2i(f),o2i(f,'high')))
print("InH 5.5GHz 10m LOS %.3f NLOS %.3f"%(32.4+17.3*lg(10)+20*lg(5.5), max(32.4+17.3*lg(10)+20*lg(5.5),38.3*lg(10)+17.30+24.9*lg(5.5))))
print("UMa NLOS opt 3.5GHz 500m %.3f ; UMi NLOS opt 28GHz 200m %.3f"%(32.4+20*lg(3.5)+30*lg(500),32.4+20*lg(28)+31.9*lg(200)))
snr=100; H=np.array([[1,0.5],[0.5,1]])
print("MIMO C: SISO %.4f, I2 %.4f, I4 %.4f, H %.4f b/s/Hz"%(math.log2(1+snr),2*math.log2(1+snr/2),4*math.log2(1+snr/4),math.log2(np.linalg.det(np.eye(2)+snr/2*H@H.T))))
print("photon E at 2.4 GHz: %.4e J = %.4e eV"%(6.62607015e-34*2.4e9,6.62607015e-34*2.4e9/1.602176634e-19))
