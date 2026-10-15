# Worked values for Docs/research/gyre-integration.md. Run from this folder: python3 e_gyre.py
# Reuses the ITU-R P.676 line-by-line function from b_prop.py (copied in by exec, without its prints).
import math
src = open('b_prop.py').read().split('print("=== P.676')[0]
ns = {}
exec(src, ns)
gamma_p676 = ns['gamma_p676']

pi = math.pi
c = 299792458.0; h = 6.62607015e-34; hbar = h / (2 * pi); kB = 1.380649e-23; e = 1.602176634e-19
me = 9.1093837015e-31; mp = 1.67262192595e-27; mu0 = 1.25663706212e-6; eps0 = 8.8541878128e-12
# CODATA 2022 (NIST allascii)
gp = 42.577478461e6; gps = 42.57638543e6; ge = 28024.9513861e6; ae = 1.15965218046e-3

print("== Larmor / cyclotron")
for B in [25e-6, math.hypot(22, 40) * 1e-6, 50e-6, 65e-6, 390e-6]:
    fc = e * B / (2 * pi * me)
    print(f"B={B*1e6:7.2f} uT  1H'={gps*B:9.2f} Hz  e-={ge*B/1e6:.5f} MHz  fc_e={fc/1e6:.5f} MHz  fa={ae*fc:7.1f} Hz  fc_p={e*B/(2*pi*mp):7.2f} Hz")
for B1 in [0.1e-6, 1e-6, 10e-6]:
    f1 = gps * B1; print(f"B1={B1*1e6:g} uT f1={f1:.3f} Hz t90={1e3/(4*f1):.3f} ms t180={1e3/(2*f1):.3f} ms")
f1 = gps * 1e-6; print("off-res 10 Hz: feff", math.hypot(f1, 10), "max transfer", f1**2 / (f1**2 + 100))
gam = 2 * pi * gps; N = 2 * 997 / 18.01528 * 1000 * 6.02214076e23
print("P(50uT,298K)", gam * hbar * 50e-6 / (2 * kB * 298.15), "M0", N * gam**2 * hbar**2 * 50e-6 / (4 * kB * 298.15))
for G in [1e-6, 10e-6]:
    df = gps * G * 0.1; print(f"G={G*1e6:g} uT/m over 10 cm: df={df:.3f} Hz T2*={1e3/(pi*df):.1f} ms")

print("== GyroSim rotor")
m, R = 0.06, 0.03; I3 = 0.5 * m * R * R
I1 = lambda off, s=1: s * 0.25 * m * R * R + 2.5e-6 + m * off * off
for rpm, off, s in [(3000, 0.0175, 1), (1500, 0, 1), (4000, 0, 1), (12000, 0, 1), (12000, 0, 3)]:
    L = s * I3 * rpm * 2 * pi / 60; wn = L / I1(off, s); fn = wn / 2 / pi
    print(f"{rpm} rpm off={off} inertia x{s}: L={L:.4e} wn={wn:.2f} rad/s ({fn:.2f} Hz) alias@120fps={abs(fn-120*round(fn/120)):.2f} Hz",
          f"prec={m*9.80665*off/L:.4f} rad/s" if off else "")
L = I3 * 1500 * 2 * pi / 60; g = 60 / L
print("rotor gamma", g, "Omega0", g * 50e-6, "period", 2 * pi / (g * 50e-6), "t90(B1=10uT)", pi / (2 * g * 10e-6), "gamma_p'/gamma_rotor", 2 * pi * gps / g)
mu = 1.3 / mu0 * 0.06 / 7500; print("NdFeB rotor mu", mu, "detent", mu / 60, "Larmor period", 2 * pi / (mu * 50e-6 / L))

print("== Antenna attitude")
for a in [30, 45, 60, 80, 89]: print("PLF", a, 10 * math.log10(math.cos(math.radians(a))**2))
print("lambda/2 dipole F^2(30deg)", 20 * math.log10(math.cos(pi / 2 * math.cos(math.radians(30))) / math.sin(math.radians(30))))
def AF(th, N=8, beta=0):
    psi = pi * math.cos(math.radians(th)) + beta
    return 1.0 if abs(math.sin(psi / 2)) < 1e-15 else math.sin(N * psi / 2) / (N * math.sin(psi / 2))
print("AF(60) unsteered", AF(60), "AF dB at 83.6", 20 * math.log10(abs(AF(83.6))))
print("Rayleigh RSSI std dB", 10 / math.log(10) * pi / math.sqrt(6))
print("BLE adv lambdas cm", [round(c / f * 100, 3) for f in (2402e6, 2426e6, 2480e6)])

print("== Magnetometer")
for fs in [100, 99.8, 120]:
    print(fs, [round(abs(f - fs * round(f / fs)), 2) for f in (50, 60, 100, 120, 180, 300)])
mm = 1.3 * pi * 0.005**2 * 0.003 / mu0
print("NdFeB disc m", mm, "axis uT", [round(mu0 * 2 * mm / (4 * pi * r**3) * 1e6, 1) for r in (0.05, 0.1, 0.2, 0.3)])
print("cord 5A 4mm uT", [round(mu0 * 5 * 0.004 / (2 * pi * r * r) * 1e6, 2) for r in (0.02, 0.05, 0.1)])
E0 = math.sqrt(2 * 1361 / (c * eps0)); print("sun E0", E0, "B0 uT", E0 / c * 1e6, "1000 V/m B uT", 1000 / c * 1e6)

print("== Air (ITU-R P.453-14)")
def es(t, P): return (1 + 1e-4 * (7.2 + P * (0.0320 + 5.9e-6 * t * t))) * 6.1121 * math.exp((18.678 - t / 234.5) * t / (t + 257.14))
def Nr(P, t, RH):
    T = t + 273.15; ee = RH / 100 * es(t, P)
    return 77.6 * (P - ee) / T + 72 * ee / T + 3.75e5 * ee / T**2, 77.6 / T * (P + 4810 * ee / T), ee
for P, t, RH in [(1013.25, 15, 0), (1013.25, 15, 50), (1013.25, 25, 80), (835, 15, 0)]: print(P, t, RH, Nr(P, t, RH))
print("k(-40)", 1 / (1 - 6371 * 40e-6), "ducting dN/dh", -1e6 / 6371e3 * 1e3)
for hh in [1.5, 11.5, 30]: print("horizon", hh, math.sqrt(2 * 4 / 3 * 6371e3 * hh) / 1e3, math.sqrt(2 * 6371e3 * hh) / 1e3)
print("scale height m/hPa", 8.314462618 * 288.15 / (0.0289644 * 9.80665) / 1013.25)
print("ZHD", 0.0022768 * 1013.25, 0.0022768 * 835 / (1 - 0.00266 * math.cos(2 * math.radians(40)) - 0.28e-6 * 1600))
for f in [60, 28]:
    for P in [1013.25, 835]: print("P.676", f, P, gamma_p676(f, p_tot=P, rho=7.5))
for nm in [400, 550, 700]:
    s2 = (1000 / nm)**2; print("optical dry N", nm, (8342.54 + 2406147 / (130 - s2) + 15998 / (38.9 - s2)) / 100)
print("Debye f GHz", 1 / (2 * pi * 8.27e-12) / 1e9)

print("== Optics")
n = 1.33; r = (n - 1) / (n + 1)
Rf = lambda d, l: 2 * r * r * (1 - math.cos(4 * pi * n * d / l)) / (1 + r**4 - 2 * r * r * math.cos(4 * pi * n * d / l))
for d in [10, 420]: print("film", d, [round(Rf(d, l), 4) for l in (640, 530, 450)])
sil = lambda u: math.sqrt(1 + 0.6961663 * u*u / (u*u - 0.0684043**2) + 0.4079426 * u*u / (u*u - 0.1162414**2) + 0.8974794 * u*u / (u*u - 9.896161**2))
bk7 = lambda u: math.sqrt(1 + 1.03961212 * u*u / (u*u - 0.00600069867) + 0.231792344 * u*u / (u*u - 0.0200179144) + 1.01046945 * u*u / (u*u - 103.560653))
for nm in [450, 530, 640]: print(nm, round(sil(nm / 1e3), 5), round(bk7(nm / 1e3), 5), round(1.3251 + 2946 / nm**2, 4))
for I in [60, 66]:
    lm = math.atan(math.tan(math.radians(I)) / 2); print("dip", I, "maglat", math.degrees(lm), "B(B0=30)", 30 * math.sqrt(1 + 3 * math.sin(lm)**2))

print("== Charges")
v = math.sqrt(2 * kB * 300 / me); print("e- vmp", v, "r cm", me * v / (e * 50e-6) * 100, "T us", 2 * pi * me / (e * 50e-6) * 1e6)
vp = math.sqrt(2 * kB * 300 / mp); print("p+ r m", mp * vp / (e * 50e-6))
nn = 101325 / (kB * 288.15); vb = math.sqrt(8 * kB * 300 / (pi * me)); nu = nn * 1e-19 * vb; wc = e * 50e-6 / me
print("nu", nu, "wc", wc, "ratio", wc / nu, "P for ratio 1 (Pa)", 101325 * wc / nu)
a_ = 0.5e-6; mg = 2000 * 4 / 3 * pi * a_**3; D = kB * 300 / (6 * pi * 1.81e-5 * a_)
print("1um grain sigma_v mm/s", math.sqrt(kB * 300 / mg) * 1e3, "rms 1s um", math.sqrt(2 * D) * 1e6)
s = 10e-6; print("rad pressure/weight 10um", 1361 * pi * (s / 2)**2 / c / (1000 * 4 / 3 * pi * (s / 2)**3 * 9.80665))
print("kTB dBm 1Hz,1MHz,2MHz,12.5kHz", [round(10 * math.log10(kB * 290 * b * 1e3), 2) for b in (1, 1e6, 2e6, 12.5e3)])

print("== Scale")
for name, f in [("FM", 100e6), ("LTE700", 700e6), ("L1", 1575.42e6), ("BLE", 2.44e9), ("UWB5", 6489.6e6), ("n261", 28e9)]:
    l = c / f; print(name, f"lambda {l*100:.2f} cm, lambda/2pi {l/2/pi*100:.2f} cm")
print("phone 2D^2/lambda at 2.44 GHz m", 2 * 0.1599**2 / (c / 2.44e9), "chassis lambda/2 MHz", c / (2 * 0.1599) / 1e6)
for f in [2128.82, 60, 50, 7.83, 1.40125e6]: print("lambda km", f, c / f / 1e3)
pitch = lambda f: 110 * 2**(4 * (math.log10(f) - 5.5) / 16)
print("mapped pitch", [round(pitch(f), 1) for f in (60, 2.44e9, 545e12, 1.40125e6)])

print("== Modulation / link")
fspl = lambda d, f: 20 * math.log10(d) + 20 * math.log10(f) - 147.55221677811664
Nn = -174 + 10 * math.log10(12.5e3) + 6
for d in [500, 1000, 2000]: print("FRS CNR", d, 27 - (fspl(1, 462.6e6) + 35 * math.log10(d)) - Nn)
Q = lambda x: 0.5 * math.erfc(x / math.sqrt(2))
print("QPSK BER", [Q(math.sqrt(2 * 10**(x / 10))) for x in (4, 6, 10)])
print("fm walk", [1.4 * f / c for f in (462.6e6, 2.44e9)])
