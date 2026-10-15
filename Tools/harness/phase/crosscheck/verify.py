#!/usr/bin/env python3
"""Independent numpy re-derivation of Spectra/Phase (verifier, 2026-10-08).

Everything here is written from Utkarsh's convention (C) (Docs/research/wigner-spacetime.md):
    psi~(k, nu) = int psi(x, t) e^{-i(k x - 2 pi nu t)} dx dt
    Phi(nu, k; x, t) = int int psi*(x - xi/2, t - tau/2) psi(x + xi/2, t + tau/2) e^{-i(k xi - 2 pi nu tau)} dxi dtau
discretized with half-lags (xi, tau) = (2 m_x dx, 2 m_t dt), samples outside the record = 0, and
the rule-1 lag cap |m| <= M/2 - 1 when M (columns per Wigner period) is smaller than the record.
Direct sums (no FFT) evaluated at column values derived here: the half-lag Wigner has period
fs/2 in nu (pi/dx in k), split into M columns; positive band s = c, centred s = c - M/2.
"""
import json, math, sys
import numpy as np
import mpmath as mp

J = json.load(open(sys.argv[1]))
def arr(k):
    v = J[k]
    if isinstance(v, list):
        return np.array([float(x) if not isinstance(x, str) else float(x.replace("inf", "inf")) for x in v])
    return v

results = []
def check(name, err, tol, extra=""):
    ok = bool(np.isfinite(err) and err <= tol)
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + f"{name}: {err:.3g} (tol {tol:g}) {extra}")

def maxrel(a, b, scale=None):
    a = np.asarray(a); b = np.asarray(b)
    s = scale if scale is not None else max(np.max(np.abs(b)), 1e-300)
    return float(np.max(np.abs(a - b)) / s) if a.size else 0.0

def good_size(n):
    best = None
    for f in (1, 3, 5, 15):
        p = 8
        while f * p < n: p *= 2
        best = f * p if best is None else min(best, f * p)
    return best

def signal(key):
    return arr(key + ".re") + 1j * arr(key + ".im"), J[key + ".step"], J[key + ".origin"]

def col_values(domain, step, M, band):
    s = np.arange(M) - (0 if band == "positive" else M // 2)
    period = (1 / step) / 2 if domain == "time" else math.pi / step  # half the grid period
    return s * period / M

# ---------------------------------------------------------------- 1-D Wigner (direct sums)
def lag_weights(kind, L):
    m = np.arange(L + 1)
    if kind[0] == "full" or kind[0] == "rect": return np.ones(L + 1)
    if kind[0] == "hann": return 0.5 * (1 + np.cos(np.pi * m / (L + 1)))
    if kind[0] == "gauss": return np.exp(-0.5 * m * m / kind[1] ** 2)

def wigner1d(z, step, domain, cols, M, lag=("full",), lagHalf=None):
    """W(n, col) = 2 step sum_m h(m) z*[n-m] z[n+m] e^{s i 2pi col (2 m step)} (time s=+1, nu) or e^{-i k 2 m step} (space)."""
    N = len(z)
    cap = M // 2 - 1
    L = cap if lagHalf is None else min(cap, lagHalf)
    h = lag_weights(lag, L)
    W = np.zeros((N, len(cols)))
    for n in range(N):
        acc = np.zeros(len(cols), complex)
        for m in range(-L, L + 1):
            a, b = n - m, n + m
            if min(a, b) < 0 or max(a, b) >= N: continue
            prod = np.conj(z[a]) * z[b] * h[abs(m)]
            if domain == "time": ph = np.exp(2j * np.pi * cols * 2 * m * step)
            else: ph = np.exp(-1j * cols * 2 * m * step)
            acc += prod * ph
        assert np.max(np.abs(acc.imag)) <= 1e-12 * max(1, np.max(np.abs(acc.real)))
        W[n] = 2 * step * acc.real
    return W

def spectrum_direct(z, step, origin, domain, cols):
    n = np.arange(len(z)); t = origin + n * step
    if domain == "time": E = np.exp(2j * np.pi * np.outer(cols, t))
    else: E = np.exp(-1j * np.outer(cols, t))
    return step * (E @ z)

print("== A. 1-D time record (N = 40, dt = 0.37 ms, origin 12.3 ms)")
zA, dtA, oA = signal("A")
for key, M, band in [("A.W", 40, "positive"), ("A.Wc", 40, "centered"), ("A.W64", 64, "positive"), ("A.W16", 16, "positive")]:
    cols = col_values("time", dtA, M, band)
    check(f"{key} column axis", maxrel(arr(key + ".col")[:2], [cols[0], cols[1] - cols[0]], scale=cols[1] - cols[0]), 1e-12)
    W = wigner1d(zA, dtA, "time", cols, M)
    Ws = arr(key + ".values").reshape(40, M)
    check(f"{key} values vs direct convention-(C) sum", maxrel(Ws, W), 1e-13)
    meas = 1 / (2 * M * dtA)
    check(f"{key} column measure 1/(2 M dt)", abs(J[key + ".colMeasure"] - meas) / meas, 1e-14)
    # M1, M2, P from the definitions
    m1 = W.sum(1) * meas
    check(f"{key} M1 = |z|^2", maxrel(m1, np.abs(zA) ** 2), 1e-13 if M >= 16 else 1e-13)
    Z = spectrum_direct(zA, dtA, oA, "time", cols)
    Za = spectrum_direct(zA, dtA, oA, "time", cols + 1 / (2 * dtA))
    m2 = W.sum(0) * dtA
    if M >= 40:
        check(f"{key} M2 = |Z(nu)|^2 + |Z(nu + fs/2)|^2", maxrel(m2, np.abs(Z) ** 2 + np.abs(Za) ** 2), 1e-13)
    check(f"{key} P = sum |z|^2 dt", abs(W.sum() * dtA * meas - np.sum(np.abs(zA) ** 2) * dtA) / (np.sum(np.abs(zA) ** 2) * dtA), 1e-13)
spec = arr("A.spec.power"); al = arr("A.spec.aliased")
cols = col_values("time", dtA, 40, "positive")
Z = spectrum_direct(zA, dtA, oA, "time", cols); Za = spectrum_direct(zA, dtA, oA, "time", cols + 1 / (2 * dtA))
check("A.spectrum power |Z|^2 (DTFT, + sign)", maxrel(spec, np.abs(Z) ** 2), 1e-13)
check("A.spectrum aliased", maxrel(al, np.abs(Z) ** 2 + np.abs(Za) ** 2), 1e-13)
cols16 = col_values("time", dtA, 16, "centered")
Z16 = spectrum_direct(zA, dtA, oA, "time", cols16); Z16a = spectrum_direct(zA, dtA, oA, "time", cols16 + 1 / (2 * dtA))
check("A.spectrum M=16 centred (record folded, 2M < N)", maxrel(arr("A.specc16.power"), np.abs(Z16) ** 2), 1e-13)
check("A.spectrum M=16 centred aliased", maxrel(arr("A.specc16.aliased"), np.abs(Z16) ** 2 + np.abs(Z16a) ** 2), 1e-13)

# pseudo (Hann lag 9, stride 3)
cols = col_values("time", dtA, 32, "positive")
W = wigner1d(zA, dtA, "time", cols, 32, lag=("hann",), lagHalf=9)
rows = np.arange(0, 40, 3)
check("A.PW rows stride 3", maxrel(arr("A.PW.rowIndices"), rows, scale=1), 0)
check("A.PW pseudo-Wigner (Hann 9) values", maxrel(arr("A.PW.values").reshape(len(rows), 32), W[rows]), 1e-13)
check("A.PW row measure n/rows*dt", abs(J["A.PW.rowMeasure"] - 40 / len(rows) * dtA) / dtA, 1e-14)
# smoothed: Gaussian lag (7, sigma 3), Hann time window G = 3 normalized
Wp = wigner1d(zA, dtA, "time", cols, 32, lag=("gauss", 3.0), lagHalf=7)
G = 3
g = 0.5 * (1 + np.cos(np.pi * np.arange(-G, G + 1) / (G + 1))); g /= g.sum()
Wsm = np.zeros_like(Wp)
for n in range(40):
    for j, p in enumerate(range(-G, G + 1)):
        r = n - p
        if 0 <= r < 40: Wsm[n] += g[j] * Wp[r]
check("A.SPW smoothed pseudo = sum_p g(p) PW(n - p)", maxrel(arr("A.SPW.values").reshape(40, 32), Wsm), 1e-13)

# spectrogram: S = |dt sum_p z[n+p] w[p] e^{+2 pi i nu p dt}|^2, dt sum w^2 = 1
def spectrogram(z, step, cols, wsamples, rows):
    L = len(wsamples); lo = -((L - 1) // 2)
    w = wsamples / math.sqrt(np.sum(wsamples ** 2) * step)
    S = np.zeros((len(rows), len(cols)))
    for r, n in enumerate(rows):
        acc = np.zeros(len(cols), complex)
        for j in range(L):
            p = lo + j; i = n + p
            if 0 <= i < len(z): acc += z[i] * w[j] * np.exp(2j * np.pi * cols * p * step)
        S[r] = np.abs(step * acc) ** 2
    return S
L = 11; c = (L - 1) / 2
hann = 0.5 * (1 + np.cos(2 * np.pi * (np.arange(L) - c) / (L + 1)))
cols = col_values("time", dtA, 24, "positive")
check("A.SG spectrogram (Hann 11, M = 24)", maxrel(arr("A.SG.values").reshape(40, 24), spectrogram(zA, dtA, cols, hann, range(40))), 1e-13)
L = 12; c = (L - 1) / 2
gw = np.exp(-0.5 * (np.arange(L) - c) ** 2 / 2.5 ** 2)
rowsc = [int(math.floor(i * 39 / 6 + 0.5)) for i in range(7)]
cols = col_values("time", dtA, 24, "centered")
check("A.SGc rows .count(7)", maxrel(arr("A.SGc.rowIndices"), rowsc, scale=1), 0)
check("A.SGc spectrogram (Gaussian 12, centred, 7 rows)", maxrel(arr("A.SGc.values").reshape(7, 24), spectrogram(zA, dtA, cols, gw, rowsc)), 1e-13)

print("== B. 1-D space record (N = 33, dx = 0.21, origin -1.3)")
zB, dxB, oB = signal("B")
for key, band in [("B.W", "centered"), ("B.Wp", "positive")]:
    M = good_size(33)
    cols = col_values("space", dxB, M, band)
    W = wigner1d(zB, dxB, "space", cols, M)
    check(f"{key} (M = {M}, {band}) vs direct e^(-ik xi) sum", maxrel(arr(key + ".values").reshape(33, M), W), 1e-13)
    check(f"{key} column axis k = s pi/(M dx)", maxrel(arr(key + ".col")[:2], [cols[0], cols[1] - cols[0]], scale=cols[1] - cols[0]), 1e-12)
    meas = 1 / (2 * M * dxB)
    check(f"{key} M1 = |psi|^2 with dk/2pi", maxrel(W.sum(1) * meas, np.abs(zB) ** 2), 1e-13)
    Z = spectrum_direct(zB, dxB, oB, "space", cols); Za = spectrum_direct(zB, dxB, oB, "space", cols + np.pi / dxB)
    check(f"{key} M2 = |Psi(k)|^2 + |Psi(k + pi/dx)|^2", maxrel(W.sum(0) * dxB, np.abs(Z) ** 2 + np.abs(Za) ** 2), 1e-13)
cols = col_values("space", dxB, 40, "centered")
Z = spectrum_direct(zB, dxB, oB, "space", cols)
check("B.spectrum |Psi(k)|^2 (e^{-ikx})", maxrel(arr("B.spec.power"), np.abs(Z) ** 2), 1e-13)

print("== C. analytic signal, oversampling, IQ")
x = arr("C.x"); N = len(x)
def analytic_std(x, P):
    X = np.fft.fft(np.concatenate([x, np.zeros(P - len(x))]))
    H = np.zeros(P); H[0] = 1
    if P % 2 == 0: H[P // 2] = 1; H[1:P // 2] = 2
    else: H[1:(P + 1) // 2] = 2
    return np.fft.ifft(X * H)[:len(x)]  # x + i H[x] (textbook)
zs = analytic_std(x, good_size(2 * N))
at, _, oat = signal("C.at")
check("C analytic time = conj(x + iH[x]) = x - iH[x]", maxrel(at, np.conj(zs), scale=np.max(np.abs(zs))), 1e-14)
check("C analytic time: Re z = x exactly", float(np.max(np.abs(at.real - x))), 0)
asg, _, _ = signal("C.as")
check("C analytic space = x + iH[x]", maxrel(asg, zs, scale=np.max(np.abs(zs))), 1e-14)
atc, _, _ = signal("C.atc")
check("C analytic circular (P = N)", maxrel(atc, np.conj(analytic_std(x, N)), scale=np.max(np.abs(zs))), 1e-14)
# sign: cos 2 pi nu0 t -> e^{-2 pi i nu0 t} lands at +nu0 under Z(nu) = int z e^{+2 pi i nu t}
tt = np.arange(64); tone = np.cos(2 * np.pi * 5 * tt / 64)
zt = np.conj(analytic_std(tone, 64))
check("C sign: analytic cos = e^{-2 pi i nu0 t} (lands at +nu0)", float(np.max(np.abs(zt - np.exp(-2j * np.pi * 5 * tt / 64)))), 1e-13)
cz, czs, czo = signal("C.z")
def over2(z, P):
    n = len(z)
    Zf = np.fft.fft(np.concatenate([z, np.zeros(P - n)]))
    U = np.zeros(2 * P, complex)
    for q in range(P):
        if P % 2 == 0 and q == P // 2:
            U[P // 2] += Zf[q] / 2; U[2 * P - P // 2] += Zf[q] / 2
        elif q < (P + 1) // 2: U[q] = Zf[q]
        else: U[q + P] = Zf[q]
    return np.fft.ifft(U)[:2 * n] * 2
up, ups, upo = signal("C.up")
check("C oversampled2x (linear, zero-insert interpolation)", maxrel(up, over2(cz, good_size(60)), scale=1), 1e-14)
check("C oversampled2x passes through samples", maxrel(up[::2], cz, scale=1), 1e-14)
check("C oversampled2x step/origin", abs(ups - czs / 2) + abs(upo - czo), 0)
upc, _, _ = signal("C.upc")
check("C oversampled2x circular", maxrel(upc, over2(cz, 30), scale=1), 1e-14)
iq, _, _ = signal("C.iq")
check("C fromIQ: I + jQ (e^{+j2pi f t}) conjugated", maxrel(iq, np.exp(-2j * np.pi * 3 * np.arange(16) / 16), scale=1), 1e-7)

print("== D. spacetime Phi (13 x 11 random field, dx 0.3, dt 0.05)")
nx, nt = 13, 11
psi = (arr("D.re") + 1j * arr("D.im")).reshape(nx, nt)
dx, dt = 0.3, 0.05
x0, t0 = -2.0, 0.7
def phi_direct(psi, Mx, Mt, kband, nuband, hx=None, ht=None):
    nx, nt = psi.shape
    kc = col_values("space", dx, Mx, kband); nc = col_values("time", dt, Mt, nuband)
    Lx = Mx // 2 - 1 if hx is None else len(hx) - 1
    Lt = Mt // 2 - 1 if ht is None else len(ht) - 1
    hx = np.ones(Lx + 1) if hx is None else hx
    ht = np.ones(Lt + 1) if ht is None else ht
    Ek = {m: np.exp(-1j * kc * 2 * m * dx) for m in range(-Lx, Lx + 1)}
    En = {m: np.exp(2j * np.pi * nc * 2 * m * dt) for m in range(-Lt, Lt + 1)}
    P = np.zeros((nx, nt, Mx, Mt)); maxim = 0
    for i in range(nx):
        for n in range(nt):
            acc = np.zeros((Mx, Mt), complex)
            for mx in range(-Lx, Lx + 1):
                if min(i - mx, i + mx) < 0 or max(i - mx, i + mx) >= nx: continue
                for mt in range(-Lt, Lt + 1):
                    if min(n - mt, n + mt) < 0 or max(n - mt, n + mt) >= nt: continue
                    b = np.conj(psi[i - mx, n - mt]) * psi[i + mx, n + mt] * hx[abs(mx)] * ht[abs(mt)]
                    acc += b * np.outer(Ek[mx], En[mt])
            maxim = max(maxim, np.max(np.abs(acc.imag)) / max(np.max(np.abs(acc.real)), 1e-300))
            P[i, n] = 4 * dx * dt * acc.real
    return P, kc, nc, maxim

def st_checks(key, Mx, Mt, kband, nuband, hx=None, ht=None, exact=True):
    P, kc, nc, maxim = phi_direct(psi, Mx, Mt, kband, nuband, hx, ht)
    full = arr(key + ".full").reshape(nx, nt, Mx, Mt)
    sc = np.max(np.abs(P))
    check(f"{key} Phi (all {P.size} values) vs direct sum (Float storage)", maxrel(full, P, scale=sc), 1e-6)
    check(f"{key} Phi is real (direct complex sum)", maxim, 1e-13)
    check(f"{key} k axis / nu axis", maxrel(np.r_[arr(key + ".k")[:2], arr(key + ".nu")[:2]], np.r_[kc[0], kc[1] - kc[0], nc[0], nc[1] - nc[0]], scale=1), 1e-12)
    km, nm = 1 / (2 * Mx * dx), 1 / (2 * Mt * dt)
    m1 = P.sum((2, 3)) * km * nm
    check(f"{key} M1 (Swift) vs direct", maxrel(arr(key + ".m1"), m1.ravel()), 1e-13)
    check(f"{key} M1 = |psi|^2 (definition)", maxrel(m1.ravel(), np.abs(psi.ravel()) ** 2), 1e-13)
    m2 = P.sum((0, 1)) * dx * dt
    check(f"{key} M2 (Swift) vs direct", maxrel(arr(key + ".m2"), m2.ravel()), 1e-13)
    X = x0 + dx * np.arange(nx); T = t0 + dt * np.arange(nt)
    def psit(k, nu):
        return dx * dt * np.einsum("ij,ki,lj->kl", psi, np.exp(-1j * np.outer(k, X)), np.exp(2j * np.pi * np.outer(nu, T)))
    if exact:
        al = sum(np.abs(psit(kc + a, nc + b)) ** 2 for a in (0, np.pi / dx) for b in (0, 1 / (2 * dt)))
        check(f"{key} M2 = |psi~|^2 + 3 alias partners (derived)", maxrel(m2, al), 1e-13)
    E = np.sum(np.abs(psi) ** 2) * dx * dt
    check(f"{key} P total", abs(J[key + ".total"] - E) / E, 1e-13)
    check(f"{key} k-integrated cube = sum_k Phi dk/2pi", maxrel(arr(key + ".kInt"), (P.sum(2) * km).ravel()), 1e-13)
    check(f"{key} nu-integrated cube = sum_nu Phi dnu", maxrel(arr(key + ".nuInt"), (P.sum(3) * nm).ravel()), 1e-13)
    check(f"{key} min/max", maxrel([J[key + ".min"], J[key + ".max"]], [P.min(), P.max()], scale=sc), 1e-13)
    am = np.unravel_index(np.argmin(P), P.shape)
    check(f"{key} argMin", float(np.max(np.abs(np.array(am) - arr(key + ".argMin")))), 0)
    return P, kc, nc

P, kc, nc = st_checks("D.st", 16, 16, "centered", "positive")
check("D.st kSlice index nearest 1.7", abs(J["D.st.sliceIndex"] - int(np.argmin(np.abs(kc - 1.7)))), 0)
check("D.st kSlice cube", maxrel(arr("D.st.slice"), P[:, :, int(J["D.st.sliceIndex"]), :].ravel()), 1e-13)
# partial marginal = 1-D temporal Wigner at fixed x; spatial at fixed t
kint = arr("D.st.kInt").reshape(nx, nt, 16)
w1 = wigner1d(psi[5], dt, "time", nc, 16)
check("D.st partial marginal sum_k Phi dk/2pi = W(t, nu) at x_5", maxrel(kint[5], w1), 1e-13)
nuint = arr("D.st.nuInt").reshape(nx, nt, 16)
w1s = wigner1d(psi[:, 7], dx, "space", kc, 16)
check("D.st partial marginal sum_nu Phi dnu = W(x, k) at t_7", maxrel(nuint[:, 7], w1s), 1e-13)
X = x0 + dx * np.arange(nx); T = t0 + dt * np.arange(nt)
ps = dx * dt * np.einsum("ij,ki,lj->kl", psi, np.exp(-1j * np.outer(kc, X)), np.exp(2j * np.pi * np.outer(nc, T)))
check("D spectrum |psi~(k,nu)|^2 (convention C)", maxrel(arr("D.spec.power"), (np.abs(ps) ** 2).ravel()), 1e-13)
st_checks("D.st2", 32, 24, "positive", "centered")
hx = 0.5 * (1 + np.cos(np.pi * np.arange(4) / 4)); ht = np.ones(3)
st_checks("D.st3", 16, 16, "centered", "positive", hx, ht, exact=False)
st_checks("D.st4", 8, 6, "centered", "positive", exact=False)  # M < N: lag cap M/2 - 1
rep = arr("D.rep")
print("   D.rep", rep, J["D.rep.status"], "| D.rep4", arr("D.rep4"), J["D.rep4.status"], "| D.rep3", J["D.rep3.status"])

print("== E. apertures")
cur, dxa, oa = signal("E.arr")
lam = 2.0; k = 2 * np.pi / lam; d = 0.7 * lam; kx0 = k * np.sin(np.radians(20))
pos = (np.arange(5) - 2) * d
xs = oa + dxa * np.arange(len(cur))
nz = np.nonzero(np.abs(cur) > 0)[0]
check("E array: element positions", maxrel(xs[nz], pos, scale=1), 1e-12)
check("E array: dx = pitch/4", abs(dxa - d / 4), 1e-15)
check("E array: weights e^{+i k sin(th0) x}/dx (steer toward +th0)", maxrel(cur[nz], np.exp(1j * kx0 * pos) / dxa, scale=1 / dxa), 1e-14)
M = good_size(len(cur))
colsE = col_values("space", dxa, M, "centered")
WE = wigner1d(cur, dxa, "space", colsE, M)
check("E array Wigner vs direct", maxrel(arr("E.arrW.values").reshape(len(cur), M), WE), 1e-12)
ang = arr("E.angles")
def AF2(kx): return np.abs(np.exp(1j * np.outer(kx0 - kx, pos)).sum(1)) ** 2 / 25
ff = arr("E.arrFF")
check("E array far field at 72 angles = |AF(k sin th)|^2 normalized (exact)", maxrel(ff, AF2(k * np.sin(np.radians(ang))), scale=1), 1e-12)
check("E array far-field peak at +20 deg", 0 if abs(ang[np.argmax(ff)] - 20) <= 1.25 + 1e-9 else 1, 0)
# continuous cosine aperture
cc, dxc, oc = signal("E.cont")
lam = 1.5; k = 2 * np.pi / lam; kx0 = k * np.sin(np.radians(-10))
xs = oc + dxc * np.arange(len(cc))
half = round(3 * lam / 2 / dxc)
u = xs / (half * dxc)
ref = np.where(np.abs(u) <= 1 + 1e-12, np.cos(np.pi * u / 2), 0) * np.exp(1j * kx0 * xs)
check("E continuous current = cos(pi u/2) e^{i kx0 x}", maxrel(cc, ref, scale=1), 1e-14)
def Psi2(kx): return np.abs(dxc * np.exp(-1j * np.outer(kx, xs)) @ cc) ** 2
ffc = arr("E.contFF")
kk = k * np.sin(np.radians(ang))
fine = np.linspace(-k, k, 20001); pk = Psi2(fine).max()
Mc = good_size(len(cc))
cols = col_values("space", dxc, Mc, "centered")
alias = (Psi2(cols + np.pi / dxc)).max() / pk
check("E continuous far field = |Psi(k sin th)|^2 / max (within the alias)", maxrel(ffc, Psi2(kk) / pk, scale=1), 2 * alias + 1e-9, f"alias {alias:.2g}")
check("E continuous far-field peak at -10 deg", 0 if abs(ang[np.argmax(ffc)] + 10) <= 1.25 + 1e-9 else 1, 0)
th = arr("E.contFFcols.theta"); pw = arr("E.contFFcols.power")
check("E continuous farField(from:) columns at asin(kx/k)", maxrel(pw, Psi2(k * np.sin(np.radians(th))) / pk, scale=1), 2 * alias + 1e-9)
wa, dxw, ow = signal("E.warr")
nzw = np.nonzero(np.abs(wa) > 0)[0]
check("E weighted array uses the weights", maxrel(wa[nzw] * dxw, [0.2, 0.7, 1, 1, 0.7, 0.2], scale=1), 1e-14)

print("== F. Fresnel")
beam, dxf, of = signal("F.beam")
xs = of + dxf * np.arange(len(beam))
k0 = 2 * np.pi
def propagate(z, model="paraxial", pad=64):
    P = pad * len(beam); off = (P - len(beam)) // 2
    buf = np.zeros(P, complex); buf[off:off + len(beam)] = beam
    F = np.fft.fft(buf)
    kq = 2 * np.pi * np.fft.fftfreq(P, dxf)
    if model == "paraxial": H = np.exp(-1j * z * kq ** 2 / (2 * k0))
    else:
        kz = np.sqrt((k0 ** 2 - kq ** 2).astype(complex))
        H = np.exp(1j * (kz - k0) * z)
        H = np.where(np.abs(kq) < k0, H, np.exp(-np.sqrt(np.abs(kq ** 2 - k0 ** 2)) * abs(z)) * np.exp(-1j * k0 * z))
    return np.fft.ifft(F * H)[off:off + len(beam)]
pr, _, _ = signal("F.prop")
check("F paraxial propagation e^{-i z k^2/(2 k0)} (convention C)", maxrel(pr, propagate(7), scale=1), 1e-12)
pa, _, _ = signal("F.propAS")
check("F angular-spectrum propagation", maxrel(pa, propagate(7, "as"), scale=1), 1e-12)
M = good_size(len(beam)); colsF = col_values("space", dxf, M, "centered")
sig2 = 2.0  # |psi|^2 rms^2 for env exp(-(x+2)^2/8)
def W0cf(xv, kv): return np.sqrt(8 * np.pi * sig2) * np.exp(-((xv + 2) ** 2) / (2 * sig2) - 2 * sig2 * (kv - 0.3) ** 2)
X, K = np.meshgrid(xs, colsF, indexing="ij")
Wnum = arr("F.W0.values").reshape(len(beam), M)
check("F W0 of the sampled Gaussian = closed form", maxrel(Wnum, W0cf(X, K)), 1e-11)
Wz = W0cf(X - 7 * K / k0, K)
check("F shear z = +7: W0(x - z k/k0, k) (closed form)", maxrel(arr("F.shear.values").reshape(len(beam), M), Wz), 1e-9)
Wzn = W0cf(X + 5 * K / k0, K)
check("F shear z = -5", maxrel(arr("F.shearNeg.values").reshape(len(beam), M), Wzn), 1e-9)
Wdir = wigner1d(propagate(7), dxf, "space", colsF, M)
check("F shear = Wigner of the propagated field", maxrel(arr("F.shear.values").reshape(len(beam), M), Wdir), 1e-9)
ks = np.where(np.abs(K) < k0, K, 0)
sAS = 7 * K / np.sqrt(np.maximum(k0 ** 2 - K ** 2, 1e-300))
Was = np.where(np.abs(K) < k0, W0cf(X - sAS, K), 0)
check("F angular-spectrum shear z k/sqrt(k0^2 - k^2)", maxrel(arr("F.shearAS.values").reshape(len(beam), M), Was), 1e-9)
xo = -20 + 0.2 * np.arange(200)
Xo, Ko = np.meshgrid(xo, colsF, indexing="ij")
check("F cubic shear onto a wider axis (Catmull-Rom, h = 0.25)", maxrel(arr("F.shearCubic.values").reshape(200, M), W0cf(Xo - 7 * Ko / k0, Ko)), 2e-2)

print("== G. packet fields (spectral propagation, display units)")
def packet_spec(kv, p, k0):
    A, w, beta, xc, ph = p
    a = 1 / (4 * w * w) - 1j * beta
    return A * np.exp(1j * ph) * (2 * np.pi * w * w) ** -0.25 * np.exp(-1j * kv * xc) * np.sqrt(np.pi / a) * np.exp(-((kv - k0) ** 2) / (4 * a))
def field_quad(packets, omega, xv, tv, gate=None):
    out = np.zeros((len(xv), len(tv)), complex)
    for p, k0 in packets:
        sk = math.sqrt(1 / (4 * p[1] ** 2) + 4 * p[2] ** 2 * p[1] ** 2)
        kg = np.linspace(k0 - 14 * sk, k0 + 14 * sk, 40001)
        S = packet_spec(kg, p, k0); Om = omega(kg)
        wts = np.full(len(kg), kg[1] - kg[0]); wts[0] *= 0.5; wts[-1] *= 0.5
        for j, t in enumerate(tv):
            out[:, j] += (np.exp(1j * (np.outer(xv, kg) - Om * t)) @ (S * wts)) / (2 * np.pi)
    if gate is not None: out *= gate(tv)[None, :]
    return out
fpn = 2e14 / 3e14
def om_plasma(kv): return np.sqrt((2 * np.pi * fpn) ** 2 + kv ** 2)
k01 = math.sqrt((2 * np.pi) ** 2 - (2 * np.pi * fpn) ** 2)
k02 = -math.sqrt((2 * np.pi * 1.3) ** 2 - (2 * np.pi * fpn) ** 2)
check("G plasma carriers k = sqrt(w^2 - wp^2) (display units), signed", maxrel(arr("G.carriers"), [k01, k02], scale=1), 1e-13)
gx = -10 + 0.35 * np.arange(40); gt = -2 + 0.7 * np.arange(9)
ref = field_quad([((1.2, 1.5, 0.04, -3, 0.4), k01), ((0.8, 2, 0, 4, -1), k02)], om_plasma, gx, gt)
G = (arr("G.re") + 1j * arr("G.im")).reshape(40, 9)
check("G plasma two-packet field vs direct quadrature of int psi~ e^{i(kx - w t)} dk/2pi", maxrel(G, ref), 1e-9)
# glass: own Sellmeier and root find
B = [1.03961212, 0.231792344, 1.01046945]; C = [0.00600069867, 0.0200179144, 103.560653]
def n_bk7(lum):
    l2 = lum * lum
    return math.sqrt(1 + sum(b * l2 / (l2 - c) for b, c in zip(B, C)))
lref = 600e-9
def om_glass_scalar(kh):
    # k^ = n(lambda_ref / nu^) * omega^, nu^ = omega^/2pi
    f = lambda w: kh - n_bk7(lref * 1e6 / (w / (2 * math.pi))) * w
    return float(mp.findroot(lambda w: f(float(w)), kh / 1.5))
k0g = 2 * math.pi * n_bk7(0.6)
check("G glass carrier k = 2 pi n(600 nm)", abs(arr("G.glass.carrier")[0] - k0g) / k0g, 1e-13)
sk = math.sqrt(1 / (4 * 2.5 ** 2) + 4 * 0.02 ** 2 * 2.5 ** 2)
kg = np.linspace(k0g - 14 * sk, k0g + 14 * sk, 4001)
omg = np.array([om_glass_scalar(v) for v in kg])
def om_glass(kv): return np.interp(kv, kg, omg)  # nodes coincide with the quadrature grid below
def field_quad_nodes(p, k0, xv, tv, gate):
    S = packet_spec(kg, p, k0); wts = np.full(len(kg), kg[1] - kg[0]); wts[0] *= 0.5; wts[-1] *= 0.5
    out = np.zeros((len(xv), len(tv)), complex)
    for j, t in enumerate(tv):
        out[:, j] = (np.exp(1j * (np.outer(xv, kg) - omg * t)) @ (S * wts)) / (2 * np.pi) * gate(t)
    return out
gt2 = 3.0 * np.arange(5)
refg = field_quad_nodes((1, 2.5, -0.02, 1, 0), k0g, gx, gt2, lambda t: math.exp(-((t - 6) ** 2) / (4 * 16)))
Gg = (arr("G.glass.re") + 1j * arr("G.glass.im")).reshape(40, 5)
check("G BK7 packet with Gaussian gate vs quadrature with own Sellmeier root find", maxrel(Gg, refg), 1e-8)

print("== H. dispersion (SI)")
c = 299792458.0
nu = arr("H.plasma.nu"); fp = 9e6
kp = np.sqrt((2 * np.pi * nu) ** 2 - (2 * np.pi * fp) ** 2) / c
check("H plasma k(nu)", maxrel(arr("H.plasma.k"), kp), 1e-14)
check("H plasma v_g = c^2 k / w", maxrel(arr("H.plasma.vg"), c * c * kp / (2 * np.pi * nu)), 1e-14)
check("H plasma v_p = w/k", maxrel(arr("H.plasma.vp"), 2 * np.pi * nu / kp), 1e-14)
w = 2 * np.pi * nu; wp = 2 * np.pi * fp
check("H plasma D = c^2 wp^2 / w^3 (both branches)", max(maxrel(arr("H.plasma.gvd"), c * c * wp * wp / w ** 3), maxrel(arr("H.plasma.gvdm"), c * c * wp * wp / w ** 3)), 1e-14)
check("H plasma backward branch v_g < 0", maxrel(arr("H.plasma.vgm"), -c * c * kp / w), 1e-14)
nu = arr("H.waveguide.nu"); fc = 6.557e9
kw = np.sqrt((2 * np.pi * nu) ** 2 - (2 * np.pi * fc) ** 2) / c
check("H waveguide k, v_g", max(maxrel(arr("H.waveguide.k"), kw), maxrel(arr("H.waveguide.vg"), c * c * kw / (2 * np.pi * nu))), 1e-14)
mp.mp.dps = 40
def nb7(l):  # l in metres, mp
    lu = l * mp.mpf(1e6); l2 = lu * lu
    return mp.sqrt(1 + sum(mp.mpf(b) * l2 / (l2 - mp.mpf(cc)) for b, cc in zip(B, C)))
SB = {"glass": (B, C)}
SIL = ([0.6961663, 0.4079426, 0.8974794], [0.0684043 ** 2, 0.1162414 ** 2, 9.896161 ** 2])
DIA = ([4.3356, 0.3306], [0.106 ** 2, 0.175 ** 2])
def sell(bc):
    Bv, Cv = bc
    def n(l):
        lu = l * mp.mpf(1e6); l2 = lu * lu
        return mp.sqrt(1 + sum(mp.mpf(b) * l2 / (l2 - mp.mpf(cc)) for b, cc in zip(Bv, Cv)))
    return n
def water(l):
    nm = l * mp.mpf(1e9); return mp.mpf(1.3251) + mp.mpf(2946) / (nm * nm)
lams = [400e-9, 550e-9, 800e-9, 1.5e-6, 2e-6]
for name, nf in [("glass", sell((B, C))), ("silica", sell(SIL)), ("diamond", sell(DIA)), ("water", water)]:
    ks, vgs, gvds = [], [], []
    for l in lams:
        if name == "water" and l > 1.1e-6:
            ks.append(np.nan); vgs.append(np.nan); gvds.append(np.nan); continue
        kf = lambda w: nf(2 * mp.pi * c / w) * w / c  # k(omega)
        w0 = 2 * mp.pi * c / l
        ks.append(float(kf(w0)))
        k1 = mp.diff(kf, w0); k2 = mp.diff(kf, w0, 2)
        vgs.append(float(1 / k1)); gvds.append(float(-k2 / k1 ** 3))  # d2w/dk2 = -k''/k'^3
    sel = ~np.isnan(ks)
    check(f"H {name} k = n w / c", maxrel(arr(f"H.{name}.k")[sel], np.array(ks)[sel]), 1e-14)
    check(f"H {name} v_g (mp derivative)", maxrel(arr(f"H.{name}.vg")[sel], np.array(vgs)[sel]), 1e-7)
    check(f"H {name} D = d2w/dk2 (mp derivative)", maxrel(arr(f"H.{name}.gvd")[sel], np.array(gvds)[sel]), 2e-3)
    check(f"H {name} omega(k(nu)) round trip", maxrel(arr(f"H.{name}.omegaBack")[sel], 2 * np.pi * arr(f"H.{name}.nu")[sel]), 1e-13)
# Taylor inverse: w = 5 - 0.7 d + 0.2 d^2, d = k - 3
for wv, kv in zip([4.0, 5.0, 6.0], arr("H.taylor.k")):
    if np.isnan(kv): print(f"   taylor k({wv}) = nil"); continue
    d = kv - 3
    check(f"H Taylor inverse at w = {wv}", abs(5 - 0.7 * d + 0.2 * d * d - wv), 1e-12, f"(k = {kv:.6g}, branch slope {-0.7 + 0.4 * d:.3g})")

print("== I. scene (vacuum, 2 packets, grid 24)")
xa = arr("I.x"); ta = arr("I.t")
dxs, dts = xa[1], ta[1]
kMax = max(2 * np.pi * 1 + 5 / (2 * 1.5), 2 * np.pi * 1.4 + 5 / (2 * 1.2))
check("I scene dx = pi / (1.1 k_max) (positive k band)", abs(dxs - np.pi / (1.1 * kMax)) / dxs, 1e-14)
nuMax = kMax / (2 * np.pi)
check("I scene nu band 1/(2 dt) >= 1.1 (nu_max + Hann lobe)", 0 if 1 / (2 * dts) >= 1.1 * (nuMax + 2 / (24 * dts)) - 1e-9 else 1, 0)
psiI = (arr("I.re") + 1j * arr("I.im")).reshape(24, 24)
check("I scene Phi grid M = goodSize(24)", abs(arr("I.st.k")[2] - good_size(24)), 0)
print("   I status", J["I.status"], "| notes:", J["I.notes"])

print("== J. live time-frequency views (1000 samples, 8 kHz → 50 × 64)")
xj = arr("J.x")
zj = np.conj(analytic_std(xj, good_size(2000)))
zj = xj + 1j * zj.imag
for mode in ["wignerVille", "pseudoWigner", "smoothedPseudoWigner", "spectrogram"]:
    rowsj = arr(f"J.{mode}.rowIndices").astype(int)
    exp_rows = [int(math.floor(i * 999 / 49 + 0.5)) for i in range(50)]
    check(f"J {mode} rows .count(50)", float(np.max(np.abs(rowsj - exp_rows))), 0)
    cols = arr(f"J.{mode}.col")
    check(f"J {mode} columns 0..fs/2 in 64", abs(cols[1] * 64 - 4000) + abs(cols[2] - 64), 1e-9)
    inten = arr(f"J.{mode}.intensity")
    check(f"J {mode} intensity = |z|^2 at rows", maxrel(inten, np.abs(zj[rowsj]) ** 2), 1e-12)
Wv = arr("J.wignerVille.values").reshape(50, 64)
# WV: M = 1024 (64 * 2^4 >= 1000), binned 16x
colsB = col_values("time", 1 / 8000, 1024, "positive")
Wfull = np.zeros((50, 1024))
rowsj = arr("J.wignerVille.rowIndices").astype(int)
for r, n in enumerate(rowsj):
    L = 511; acc = np.zeros(1024, complex)
    for m in range(-L, L + 1):
        a, b = n - m, n + m
        if min(a, b) < 0 or max(a, b) >= 1000: continue
        acc += np.conj(zj[a]) * zj[b] * np.exp(2j * np.pi * colsB * 2 * m / 8000)
    Wfull[r] = 2 / 8000 * acc.real
check("J wignerVille = 1024-bin Wigner binned 16x", maxrel(Wv, Wfull.reshape(50, 64, 16).mean(2)), 1e-12)
check("J wignerVille M1 per row", maxrel(Wv.sum(1) * J["J.wignerVille.colMeasure"], np.abs(zj[rowsj]) ** 2), 1e-12)

print()
print(f"{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
