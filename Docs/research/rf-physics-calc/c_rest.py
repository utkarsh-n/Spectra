import numpy as np, math, mpmath as mp
c=299792458.0; kB=1.380649e-23
def db(x): return 10*math.log10(x)
def Q(x): return 0.5*math.erfc(x/math.sqrt(2))
print("=== C noise")
print("kT 290K dBm/Hz:", db(kB*290*1000), " 300K:", db(kB*300*1000), " 293.15:",db(kB*293.15*1000))
print("noise floor 20MHz NF7:", db(kB*290*1000)+db(20e6)+7)
print("noise floor 1MHz NF0:", db(kB*290*1000)+60)
print("noise LTE 18 MHz occupied NF 7:", db(kB*290*1000)+db(18e6)+7)
F1=10**0.1; G1=10**2; F2=10**1.0
F=F1+(F2-1)/G1; print("Friis cascade LNA NF1 G20 + mixer NF10:",F, db(F))
print("Te for NF 1 dB:", 290*(10**0.1-1))
print("=== Shannon")
for B,snr in [(20e6,20),(1e6,0),(100e6,30),(1,-10)]:
    print(f"B={B} SNR={snr} dB: C={B*math.log2(1+10**(snr/10)):.4f} b/s")
print("Shannon limit Eb/N0 min = ln2 =", db(math.log(2)))
print("=== BER")
for ebn0db in [0,4,6.79,8,9.59,10,12]:
    g=10**(ebn0db/10); print(f"BPSK/QPSK Eb/N0={ebn0db} dB: Pb={Q(math.sqrt(2*g)):.6e}")
# find Eb/N0 for 1e-5
lo,hi=0,20
for _ in range(100):
    m=(lo+hi)/2
    if Q(math.sqrt(2*10**(m/10)))>1e-5: lo=m
    else: hi=m
print("BPSK Eb/N0 for 1e-5:",m)
def mqam_ps(M,esn0): return 4*(1-1/math.sqrt(M))*Q(math.sqrt(3*esn0/(M-1)))
def mqam_pb_eb(M,ebn0db):
    k=math.log2(M); g=10**(ebn0db/10)*k
    return mqam_ps(M,g)/k
for M,eb in [(16,10),(64,14),(256,18),(1024,22),(4096,26)]:
    print(f"{M}-QAM Eb/N0={eb} dB: Ps={mqam_ps(M,10**(eb/10)*math.log2(M)):.4e} Pb~Ps/log2M={mqam_pb_eb(M,eb):.4e}")
# exact 16QAM symbol error (square) for comparison
def mqam_ps_exact(M,esn0):
    p=2*(1-1/math.sqrt(M))*Q(math.sqrt(3*esn0/(M-1)))
    return 1-(1-p)**2
print("16QAM exact Ps at Eb/N0=10:",mqam_ps_exact(16,10**(1.0)*4))
def mpsk_ps(M,esn0): return 2*Q(math.sqrt(2*esn0)*math.sin(math.pi/M))
print("8PSK Ps Es/N0=15 dB:", mpsk_ps(8,10**1.5))
print("=== EVM")
for p in [17.5,12.5,8,3.5,2.5,2.8]:
    print(f"EVM {p}% = {20*math.log10(p/100):.3f} dB")
for d in [-25,-27,-30,-32,-35,-38]:
    print(f"EVM {d} dB = {100*10**(d/20):.4f} %")
print("=== D modulation")
for m in [0.5,1.0]:
    print(f"AM m={m}: Pt/Pc={1+m*m/2}, sideband eff={m*m/(2+m*m):.4f}")
for b in [0.5,1.0,2.0,2.404825557695773,5.0]:
    print(f"beta={b}: "+" ".join(f"J{n}={float(mp.besselj(n,b)):.5f}" for n in range(0,6)))
print("Carson broadcast 75k/15k:",2*(75+15),"kHz; beta=",75/15)
# fraction of power within Carson BW for beta=5 (n<=6)
b=5; n_max=int(b+1)
frac=sum(float(mp.besselj(n,b))**2*(1 if n==0 else 2) for n in range(0,n_max+1)); print("power within +-(beta+1) sidebands beta=5:",frac)
b=1; frac=sum(float(mp.besselj(n,b))**2*(1 if n==0 else 2) for n in range(0,3)); print("beta=1 within +-2:",frac)
print("AMPS Carson 12k dev 3k audio:",2*(12+3))
print("GFSK: BLE h=0.5 Rb=1e6 -> dev=",0.5*1e6/2, " BR h 0.28-0.35 -> ",0.28*1e6/2,0.35*1e6/2)
Rs=1625e3/6; print("GSM symbol rate", Rs, "Tb us",1e6/Rs, "B=0.3/T:",0.3*Rs, " slot 3/5200 s:",3/5200*1e6," frame 8 slots ms:",8*3/5200*1e3, " bits/slot", 3/5200*Rs)
print("GSM delta = sqrt(ln2)/(2 pi BT):", math.sqrt(math.log(2))/(2*math.pi*0.3))
print("EDGE 8PSK gross:",3*Rs/1e3,"kb/s per slot? per carrier")
print("=== DSSS")
print("GPS C/A Gp:",db(1.023e6/50)," C/A code period ms:",1023/1.023e6*1e3)
print("IS-95 Gp 9.6k:",db(1.2288e6/9600)," 14.4k:",db(1.2288e6/14400))
print("802.11b Barker 11:",db(11))
print("UMTS SF=256 Gp:",db(256), " 3.84M/12.2k:",db(3.84e6/12200))
print("L5 code: 10230 chips @10.23 Mcps period ms:",10230/10.23e6*1e3)
print("=== FHSS: BR slot us", 1e6/1600)
print("=== OFDM")
print("11a Δf=20e6/64=",20e6/64," Tu=",64/20e6*1e6,"us Tsym=",(64/20e6+0.8e-6)*1e6)
print("11a 54 Mbps check:",48*6*0.75/4e-6/1e6)
print("11ax Δf=",20e6/256," Tu=",256/20e6*1e6)
for nsd,bw in [(234,20),(468,40),(980,80),(1960,160),(3920,320)]:
    for bits,cr,name in [(10,5/6,'1024QAM'),(12,5/6,'4096QAM')]:
        r=nsd*bits*cr/(12.8e-6+0.8e-6)/1e6
        print(f"  HE/EHT {bw} MHz {name} 1SS GI0.8: {r:.3f} Mbps; 2SS {2*r:.3f}; 8SS {8*r:.3f}")
print("LTE: Δf=15k, Tu us=",1e6/15000," Ts ns=",1e9/(15000*2048), " CP0 us=",160/(15000*2048)*1e6," CP us=",144/(15000*2048)*1e6, " ext=",512/(15000*2048)*1e6, " slot check (us):",(160+2048+6*(144+2048))/(15000*2048)*1e6)
print("LTE 20MHz: 100RB*12=",100*12,"subc occupied MHz=",1200*15e3/1e6," Fs=",2048*15e3/1e6)
Tc=1/(480e3*4096)
for mu in range(7):
    scs=15e3*2**mu; Nu=2048*64*2**-mu*Tc; cp=144*64*2**-mu*Tc
    print(f"NR mu={mu}: SCS={scs/1e3} kHz Tu={Nu*1e6:.4f} us CP={cp*1e9:.2f} ns slot={1/2**mu} ms slots/subframe={2**mu}")
print("NR Tc ns=",Tc*1e9," kappa=",(1/(15e3*2048))/Tc)
print("NR 100MHz 30kHz 273RB occupied:",273*12*30e3/1e6,"MHz guard per side (formula):",(100e3-273*30*12)/2-15,"kHz")
print("NR-ARFCN 3500 MHz:",600000+(3500-3000)/0.015, " 28 GHz:",2016667+(28000-24250.08)/0.06, " 1900:",1900/0.005)
print("GSM ARFCN 62 UL/DL:",890+0.2*62, 890+0.2*62+45)
print("BLE ch freqs: idx37 2402, idx0 2404, idx10 2424, idx38 2426, idx36 2478, idx39 2480")
print("BR ch k=39:",2402+39)
print("GPS L1/L5/f0:",154*10.23,115*10.23,120*10.23)
print("GPS L1 -158.5 dBW in dBm:",-158.5+30, " L5 -157.9:",-157.9+30)
print("GPS L1 C/N0 approx at -128.5 dBm with NF 2 dB:", -128.5-(-173.975+2))
print("NFC 106k:",13.56e6/128," subcarrier fc/16:",13.56e6/16, " lambda m:",c/13.56e6)
print("UWB pulse ~1/499.2MHz ns:",1/499.2e6*1e9, " ranging res c/(2B) m:",c/(2*499.2e6), " ToF 1 m ns:",1/c*1e9, " ch5 = 13*499.2:",13*499.2," ch9=16*499.2:",16*499.2)
print("DAB mode I Tu=1ms Tg=246us; 1536 carriers BW=1.536 MHz")
