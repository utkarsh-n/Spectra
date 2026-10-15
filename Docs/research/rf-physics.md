# RF Lab: verified physics and engineering reference

Reference for the Spectra "RF Lab" (antenna / frequency simulator, radio generations, Fourier visualizer, node graph). Every formula has a source and at least one worked test value (inputs, expected output, tolerance) that can go straight into an XCTest / Swift Testing case.

Compiled 2026-10-03. SI units throughout unless a standard defines a mixed-unit form, in which case that form is labeled.

## 0. How to read this document

### 0.1 Verification tags

| Tag | Meaning |
|---|---|
| **[V]** | Read in the primary source text during this session (standard PDF, spec HTML, or SDK header). |
| **[C]** | Value computed in this session from the cited formula (Python 3.10, numpy 2.2, mpmath 1.3). Scripts are in `Docs/research/rf-physics-calc/` (`a_antenna.py`, `b_prop.py`, `c_rest.py`, `d_misc.py`; run from that folder). |
| **[S]** | Secondary source only (vendor app note, lecture slide, reputable trade press). OK for UI copy. Confirm before using as a unit-test oracle. |
| **[!]** | Flag: uncertainty, a definitional trap, or a disagreement with the task brief. Section I collects all of them. |

### 0.2 Constants (use these exact values in Swift)

| Symbol | Value | Source |
|---|---|---|
| c | 299 792 458 m/s (exact) | NIST [V] https://physics.nist.gov/cgi-bin/cuu/Value?c |
| k_B | 1.380 649 × 10⁻²³ J/K (exact) | NIST [V] https://physics.nist.gov/cgi-bin/cuu/Value?k |
| Z₀ = η₀ | 376.730 313 412 Ω (±5.9 × 10⁻⁸) | NIST [V] https://physics.nist.gov/cgi-bin/cuu/Value?z0 |
| h | 6.626 070 15 × 10⁻³⁴ J·s (exact, SI 2019) | NIST (SI definition) |
| T₀ | 290 K, the noise reference temperature | IEEE / ITU convention |

[!] Many textbook constants assume η = 120π ≈ 376.99 Ω (for example 80π², 31 171, 73 Ω). With η₀ the results move by about 0.07 %. Every test below says which η it uses. Pick one per test and keep it consistent.

### 0.3 Recommended test tolerances

- Closed-form expressions: relative 1e-9 (Double).
- Values from numerical integration (dipole D, patch D, array HPBW): ±1e-3 relative or ±0.01 dB.
- Values quoted from standards tables (rounded in the standard): ± the last printed digit.
- dB conversions: `10*log10` for power and `20*log10` for field/amplitude.

### 0.4 Swift numerics available on iOS (checked in iPhoneOS27.0.sdk `usr/include/math.h`) [V]

`erfc(double)` (line 475), `j0`, `j1`, `jn(int,double)` (Bessel first kind, lines 735–737, `ios(3.2)`), `tgamma`. Not in libm: cosine and sine integrals Ci/Si, Fresnel C/S, inverse normal CDF. Implement these with numerical quadrature or series. They are needed only for exact dipole Rr(L), the exact knife edge, and P.2109.

---

## A. Antenna theory

Primary textbook source: N. Nikolova, McMaster University EE 4FJ4 lecture notes (2025/2026 editions, built on Balanis *Antenna Theory*). Base URL `https://www.ece.mcmaster.ca/faculty/nikolova/antenna_dload/current_lectures/` (files referenced below as L03, L09, and so on).

### A.1 Hertzian (infinitesimal) dipole: uniform current I₀, length Δl ≪ λ (Δl < λ/50)

- Far field: `E_θ = j η k I₀ Δl sinθ e^{-jkr} / (4π r)`, `H_φ = E_θ/η`.
- Pattern: `U(θ) ∝ sin²θ`. Directivity D = 1.5 (1.761 dBi). HPBW = 90°.
- Radiation resistance: `R_r = (2π/3) η (Δl/λ)²`, which equals `80 π² (Δl/λ)²` for η = 120π. Source: L03 eq. (3.17) [V].
- **Test:** Δl/λ = 0.01 gives R_r = 0.078 957 Ω (80π² form) or 0.078 902 Ω (η₀ form) [C]. D = 1.5 gives 1.760 91 dBi.

### A.2 Short dipole: triangular current, l ≤ λ/10

- The field is half that of the Hertzian dipole, so `R_r = 20 π² (l/λ)²`. D = 1.5. Source: L09 eq. (9.10) [V].
- **Test:** l = 0.1λ gives R_r = 1.973 92 Ω [C]. L09 says "≈ 2 Ω".

### A.3 Thin center-fed dipole of arbitrary total length L (sinusoidal current)

- Far field (L09 eq. 9.21) [V]: `E_θ = j η I₀ e^{-jkr}/(2π r) · [cos(kL/2·cosθ) − cos(kL/2)] / sinθ`.
- Power pattern: `F(θ) = ([cos(kL/2·cosθ) − cos(kL/2)] / sinθ)²`.
- Radiation integral: `𝓘 = ∫₀^π [cos(kL/2·cosθ) − cos(kL/2)]² / sinθ dθ`. Radiated power `Π = η|I₀|²/(4π)·𝓘` (L09 eq. 9.26–9.28) [V].
- Radiation resistance referred to the current maximum: `R_r = η 𝓘 / (2π)` (L09 eq. 9.29). Input resistance at the feed: `R_in = R_r / sin²(kL/2)` (infinite for L = nλ in the thin-wire model).
- Directivity: `D = 2·F_max / 𝓘`.
- Half-wave closed form: `𝓘 = Cin(2π)/2 = 1.218 827`, where `Cin(2π) = γ + ln(2π) − Ci(2π) = 2.437 653` [C]. So `R_r = η·Cin(2π)/(4π)` and `D = 2/𝓘 = 4/Cin(2π)`. L09 eq. (9.48)–(9.51) gives Cin(2π) ≈ 2.435, 73 Ω, 1.643 [V]. [corrected in review: the earlier text set 𝓘 = Cin(2π); with 𝓘 as defined above that is 2× too large. Plugging 2.4377 into R_r = η𝓘/(2π) gives 146 Ω, and D = 2/𝓘 gives 0.82. The table values below were always right.]

**Tests** (η₀, numerical integration, tolerance ±0.01 dB / ±1e-3 rel.) [C]:

| L/λ | R_r at I_max (Ω) | R_in at feed (Ω) | D | D (dBi) | HPBW (°) |
|---|---|---|---|---|---|
| 0.10 | 0.191 | 1.999 | 1.5050 | 1.775 | 89.53 |
| 0.25 | 6.716 | 13.431 | 1.5318 | 1.852 | 87.04 |
| **0.50** | **73.079** (73.130 with 120π) | 73.079 | **1.6409** | **2.151** | **78.08** |
| 0.75 | 185.68 | 371.36 | 1.8821 | 2.746 | 64.01 |
| 1.00 | 198.95 | ∞ (thin-wire) | 2.4110 | 3.822 | 47.84 |
| 1.25 | 106.46 | 212.93 | 3.2825 | 5.162 | 32.61 |

- The input reactance of a λ/2 dipole is about +j42.5 Ω. Shortening the dipole to about 0.47–0.48λ cancels it (L09 p. 13) [V].
- Maximum effective area of a λ/2 dipole: `A_e = 0.13 λ²` (L09 eq. 9.52) [V]. **Test:** at f = 1 GHz, A_e = D λ²/4π = 0.011 736 m² [C].
- The global maximum leaves broadside at **L ≈ 1.44λ** [C]. At L = 1.5λ the computed maximum is at θ = 42.56° / 137.44° (R_r = R_in = 105.42 Ω, D = 2.2263 = 3.476 dBi). The simulator must search for F_max and not assume θ = 90° for any L > 1.25λ. [corrected in review: this bullet previously said "L > 1.5λ", which contradicted its own 137° result.]

### A.4 Quarter-wave monopole over an infinite perfect ground

- The pattern is the λ/2 dipole pattern in the upper half-space only.
- `Z_in ≈ 36.5 + j21.25 Ω`, and `D = 2 × 1.643 = 3.286` (L09 p. 24) [V].
- **Test:** R_r = 73.079/2 = 36.540 Ω. D = 3.2818, which is **5.161 dBi** [C].
- [!] The brief says 5.15 dBi. The correct value is 5.16 dBi (2.15 + 3.01).
- With a finite or phone-sized ground the gain is lower and the pattern tilts. The value above is the ideal case.

### A.5 Small loop (magnetic dipole), area A, N turns, C = circumference

- `R_r = (8/3) η π³ (A/λ²)² · N²`. With η = 120π this is `R_r = 31 171 (A/λ²)² N² = 20 π² (C/λ)⁴ N²` (L12 eq. 12.8–12.10) [V]. The constant is exactly 320π⁴ = 31 170.9, or 31 149.3 with η₀ [C].
- D = 1.5 (L12 eq. 12.11) [V].
- Ferrite rod: R_r is multiplied by μ_eff², where μ_eff < μ_r and depends on rod geometry (L12 §6) [V].
- **Test 1:** circular loop, radius a = 0.02λ (C/λ = 0.125 664), gives R_r = 0.049 223 Ω with 120π, or **0.049 189 Ω with η₀** [C]. [corrected in review: the η was not labeled.]
- **Test 2 (NFC, why it is not "radio"):** 40 × 30 mm loop, N = 4, 13.56 MHz (λ = 22.1086 m) gives R_r = 3.0 × 10⁻⁶ Ω [C]. The reactive near-field boundary λ/2π is 3.52 m, far larger than NFC's ~4 cm range. NFC is inductive (transformer) coupling.
- **Test 3 (AM ferrite bar):** 1 MHz, N = 60, r = 5 mm, μ_eff = 100 gives R_r,air = 8.57 × 10⁻¹¹ Ω and R_r,ferrite = 8.57 × 10⁻⁷ Ω [C].

### A.6 Rectangular microstrip patch (transmission-line model; Balanis ch. 14 via L20 and L21)

- `W = c/(2 f_r) · √(2/(ε_r+1))` (L21 eq. 21.5).
- `ε_eff = (ε_r+1)/2 + (ε_r−1)/2 · (1 + 12 h/W)^(−1/2)` for W/h ≥ 1 (L20 eq. 6) [V].
- `ΔL = 0.412 h (ε_eff+0.3)(W/h+0.264) / [(ε_eff−0.258)(W/h+0.8)]` (L21 eq. 21.1) [V].
- `L = c/(2 f_r √ε_eff) − 2ΔL` (L21 eq. 21.14) [V]. So the brief's `L ≈ λ/(2√ε_eff)` is correct before the fringing correction.

**Tests** [C] (tolerance 1e-4 rel.):

| Case | W | ε_eff | ΔL | L |
|---|---|---|---|---|
| ε_r 2.2, h 1.588 mm, 10 GHz | 11.850 mm | 1.9715 | 0.8110 mm | 9.053 mm |
| FR-4 ε_r 4.4, h 1.6 mm, 2.45 GHz | 37.234 mm | 4.0809 | 0.7386 mm | 28.809 mm |
| GPS ceramic ε_r 20, h 4 mm, 1575.42 MHz | 29.363 mm | 16.353 | 1.593 mm | 20.343 mm |

[!] The first row matches the widely reproduced Balanis Example 14.1 (W ≈ 1.186 cm, ε_eff ≈ 1.972, L ≈ 0.906 cm). The book was not opened this session. High-ε_r GPS ceramic patches are normally square and tuned empirically, so treat row 3 as a starting point only.

**Directivity** (Balanis two-slot model, `D₂ = (2πW/λ₀)²·π / I₂` with `I₂ = ∫₀^π∫₀^π [sin(k₀W cosθ/2)/cosθ]² sin³θ cos²(k₀L_e sinθ sinφ/2) dθ dφ`, `L_e = L + 2ΔL`) [C, formula reconstructed from Balanis §14.2; not opened this session]:

| Substrate | Directivity |
|---|---|
| ε_r 2.2 | 7.35 dBi |
| FR-4 | 6.09 dBi |
| Air (ε_r ≈ 1) | 9.34 dBi |
| ε_r 20 ceramic | 5.10 dBi |

[corrected in review: clarification only. The values above are the full two-slot integral with L_e, computed precisely (ε_r 2.2: I₁ = 1.8623, D₀ = 3.3123, I₂ = 3.5638, D₂ = 5.437). Balanis prints D₂ = 5.387 (7.31 dB, I₂ = 3.598) for the same patch because his integration was coarse. His array-factor form (14-56) gives 4.758 (6.77 dBi). A test must say which form it uses.]

[!] The brief's "typical 6–9 dBi" holds for low-permittivity substrates. High-ε_r GPS ceramics are about 5 dBi directivity, and realized gain is lower on small ground planes.

### A.7 Yagi-Uda

- Model the antenna as an array (AF approach) of a driven λ/2 dipole plus parasitic reflector and directors. Gain is set mostly by **boom length**, not element count.
- Typical: 4.3 dBi ≤ D ≤ 19 dBi, Z_in 15–70 Ω (without matching), bandwidth ≤ 2 % (SDSMT EE483 notes) [V].
- NBS Technical Note 688 (Viezbicke, 1976) optimized designs, d/λ = 0.0085, reflector spacing 0.2λ, reproduced in SDSMT notes (http://montoya.sdsmt.edu/ee483_583/notes/yagi_uda_design.pdf) [V]:

| Boom length (λ) | Elements | Gain (dBd) | Gain (dBi) = dBd + 2.15 [C] |
|---|---|---|---|
| 0.4 | 3 | 7.1 | 9.25 |
| 0.8 | 5 | 9.2 | 11.35 |
| 1.2 | 6 | 10.2 | 12.35 |
| 2.2 | 12 | 12.25 | 14.40 |
| 3.2 | 17 | 13.4 | 15.55 |
| 4.2 | 15 | 14.2 | 16.35 |

- **Test:** 7.1 dBd = 9.25 dBi. The exact dBd offset is 10log₁₀(1.6409) = 2.1509 dB [C].

### A.8 Axial-mode helix (Kraus)

- Valid for 3/4 < C/λ < 4/3, spacing S ≈ λ/4 (pitch about 12–14°).
- `D = 12 (C/λ)² N (S/λ)`. Kraus's 1st edition used 15; the 2nd edition (1988) uses 12.
- `G(dBi) ≈ 10.79 + 10 log₁₀[(C/λ)² N S/λ]`. The brief's 10.8 is 10log₁₀ 12.
- `HPBW = 52° / ((C/λ) √(N S/λ))`, `R_in ≈ 140 (C/λ) Ω`.
- Stutzman and Thiele give a more conservative pair: `D = 6.2 (C/λ)² N S/λ`, `HPBW = 65°/(…)`.
- Source: Cebik, *Notes on Axial-Mode Helical Antennas* Part 2, §"shirt-pocket estimators" (https://q82.uk/projects/cebik/uhfvhf/Axial-Mode%20Helical%20Antennas%20-%20Part%202.pdf) [V]. Axial ratio `AR = (2N+1)/(2N)` (Kraus) [S, not re-verified].
- [!] **Realistic gain.** D. Emerson (NRAO, ARRL Antenna Compendium 4, 1995; https://www.cv.nrao.edu/~demerson/cs/helix.htm) [V] found the Kraus formula "grossly optimistic – by up to 4 or 5 dB". Empirical maximum gain for 2 ≤ L ≤ 7 wavelengths (L = N S/λ): `G_max(dB) = 10.25 + 1.22 L − 0.0726 L²`. Show this as the "realistic" curve next to Kraus.
- **Test** (C/λ = 1.0, N = 10, S/λ = 0.25, so L = 2.5) [C]:

| Quantity | Value |
|---|---|
| Kraus D | 30.000 (14.771 dBi) |
| HPBW | 32.888° |
| R_in | 140 Ω |
| AR | 1.050 |
| Stutzman–Thiele D | 15.5 (11.90 dBi), HPBW 41.11° |
| Emerson G_max | **12.846 dBi** |

### A.9 Pyramidal horn

- `G = ε_ap · 4π A B / λ²`, where A × B is the aperture (L18 eq. 18.49) [V].
- The optimum-gain horn has ε_ap = ε_t ε_ph^E ε_ph^H = 0.81 × 0.632 ≈ **0.51** (L18 eq. 18.40–18.41) [V].
- The brief's `10log(4πA e_a/λ²)` is the same expression.
- **Test:** A = 0.10 m, B = 0.08 m, f = 10 GHz (λ = 0.029 979 m), ε_ap = 0.51 gives G = 57.046, i.e. **17.562 dBi** [C].

### A.10 Parabolic dish

- `G = η_ap (πD/λ)²`. A well-designed reflector reaches η_ap ≈ 0.65 "or more, where more is less likely" (L19 p. 23) [V].
- HPBW for a uniform circular aperture: `(2J₁(u)/u)² = ½` at u = 1.616 34, so **HPBW = 1.0290 λ/D rad = 58.96° λ/D** [C]. The `58.4 λ/D` printed in L19 eq. 19.14 and Balanis Table 12.2 (2 × 29.2°/(a/λ)) uses u ≈ 1.6 and is about 1 % low. Typical tapered feed: `≈ 70 λ/D` degrees (NASA NTRS 20070032925) [S]. [corrected in review]
- [!] 70λ/D is the practical rule for edge-tapered illumination. 58.96λ/D is the uniform-aperture limit.
- **Test:** D = 0.6 m, f = 12 GHz (λ = 0.024 983 m), η = 0.65 gives G = 3700.3, i.e. **35.682 dBi**. HPBW(70) = 2.9146°. Uniform-aperture HPBW is **2.4550°** (exact `2·asin(u λ/(πD))`) [C]. [corrected in review: was 2.4316° from 58.4λ/D]

### A.11 Uniform linear array (ULA) and beam steering

- θ is measured from the array axis (Nikolova convention).
- `AF_n(θ) = sin(Nψ/2) / (N sin(ψ/2))`, `ψ = k d cosθ + β` (L13 eq. 13.16–13.17; L14 eq. 14.4) [V].
- Steering to θ₀: `β = −k d cosθ₀` (L13 eq. 13.45) [V].
- Grating lobes: unscanned arrays need d < λ (L13 eq. 13.38) [V]. Scanned arrays need `d < λ/(1+|cosθ₀|)`, which is the same as `d/λ < 1/(1+|sinθ_s|)` with θ_s measured from broadside (Analog Devices, *Analog Dialogue* 54-2) [S]. The condition follows from |ψ| ≤ π over visible space (θ ∈ [0, π]).
- Broadside HPBW ≈ `2[π/2 − arccos(1.391 λ/(π N d))]` (L14 p. 11) [V]. Broadside D ≈ `2N d/λ` (L14).
- **Tests** (N = 8, d = λ/2) [C]:

| Quantity | Value |
|---|---|
| D broadside (numeric) | 8.000 (9.031 dBi) |
| HPBW exact | 12.80° (approximate formula: 12.71°) |
| First sidelobe | −12.80 dB |
| AF_n at θ = 45° (broadside) | 0.071 61 |
| Steer to θ₀ = 60° from axis | β = −90.000°, beam peak 60.000°, HPBW 14.84° |
| Grating-free limit at θ₀ = 60° | d < 0.6667λ |

### A.12 Planar arrays (5G mmWave)

- `AF = AF_x · AF_y` with `ψ_x = k d_x sinθ cosφ + β_x` and `ψ_y = k d_y sinθ sinφ + β_y`.
- Ideal array gain is `G ≈ G_element + 10log₁₀(N_x N_y)` (no coupling, mismatch, or feed loss).
- **Test:** 8 × 8 array of 5 dBi patches gives 23.06 dBi. 1 × 4 module gives 11.02 dBi. λ/2 at 28 GHz is 5.353 mm, at 39 GHz 3.843 mm [C].
- [!] Apple does not publish the element count or layout of the iPhone mmWave modules.

### A.13 PIFA and phone antennas

- PIFA resonance is roughly where the current path (L₁ + L₂ along the top plate) is about λ/4 [S].
- [!] This is only an estimate. It depends on the shorting-strip width: with a full-width short, L + H ≈ λ/4 is closer. MathWorks' default PIFA (30 × 20 × 10 mm on a 36 × 36 mm ground) resonates "around 2.34 GHz" (https://www.mathworks.com/help/antenna/ref/pifa.html) [V], and neither rule reproduces that exactly. Use it as a qualitative "length ↔ frequency" slider, not a test oracle.
- Phone antenna total efficiency: published metal-frame smartphone designs report roughly 40–70 % (−4 to −1.5 dB), worst in the 600–960 MHz low band and with hand loading [S] (for example PMC10383969; ResearchGate 335199655). [!] There is no single authoritative number. Present it as a range.

### A.14 Friis transmission, effective aperture, EIRP (L06) [V]

- `P_r = P_t G_t G_r (λ/(4π d))²`. In dB: `P_r = P_t + G_t + G_r − FSPL`.
- `A_e = G λ² / (4π)`.
- `EIRP = P_t G_t e_TL` (L06 eq. 6.9). In dB: `EIRP = P_t,dBm + G_t,dBi + e_TL,dB` (6.10).
- **Test:** P_t = 20 dBm, G_t = G_r = 0 dBi, f = 2.45 GHz, d = 10 m gives FSPL = 60.231 dB and **P_r = −40.231 dBm** [C].
- **Test (EIRP):** 23 dBm + 5 dBi − 1 dB feed loss = 27 dBm.

### A.15 Polarization mismatch (L05 §7) [V]

- `PLF = |ρ̂_w · ρ̂_a|² = cos²ψ_p`, with 0 ≤ PLF ≤ 1.
- **Tests:** linear-to-linear at 45° gives −3.0103 dB. Linear to circular gives −3.0103 dB. RHCP to LHCP gives PLF = 0 (−∞ dB). Clamp the display to something like −40 dB.

### A.16 Impedance mismatch (L04 eq. 4.28–4.30) [V]

- `Γ = (Z_L − Z₀)/(Z_L + Z₀)`, `VSWR = (1+|Γ|)/(1−|Γ|)`, `RL = −20 log₁₀|Γ|`, `ML = −10 log₁₀(1−|Γ|²)`, `e_r = 1 − |Γ|²`.

**Tests** [C]:

| Z_L on Z₀ = 50 Ω | Γ (or \|Γ\|) | VSWR | RL (dB) | ML (dB) |
|---|---|---|---|---|
| 73 Ω | 0.186 99 | 1.4600 | 14.564 | 0.1546 |
| 36.5 Ω | −0.156 07 | 1.3699 | 16.134 | 0.1071 |
| 73 + j42.5 Ω | \|Γ\| 0.371 34 | 2.1814 | 8.605 | 0.6444 |
| 100 Ω | 0.333 33 | 2.0000 | 9.542 | 0.5115 |

### A.17 Field regions (L03 eq. 3.34, 3.40) [V]

- Reactive near field: `r < 0.62 √(D³/λ)`.
- Radiating near field (Fresnel): `0.62√(D³/λ) ≤ r < 2D²/λ`.
- Far field: `r ≥ 2D²/λ`.
- Electrically small antennas use the boundary `λ/2π`.
- **Tests:** λ/2π at 2.4 GHz is 19.881 mm. For a 0.6 m dish at 12 GHz, 2D²/λ = 28.820 m and 0.62√(D³/λ) = 1.823 m [C].

---

## B. Propagation

### B.1 Free-space path loss (ITU-R P.525-5, 11/2024) [V]

- Eq. (5): `L_bf = 20 log₁₀(4π d/λ)`.
- Eq. (6): `L_bf = 32.4 + 20 log₁₀ f_MHz + 20 log₁₀ d_km`.
- SI form: `FSPL = 20log₁₀ d + 20log₁₀ f − 147.552` with d in m and f in Hz. The constant is exactly `20log₁₀(4π/c) = −147.552 217` [C]. The "32.4" in P.525 is 32.4478 rounded.
- **Tests:** d = 1 km, f = 1 GHz gives 92.4478 dB (P.525 rounded form: 92.4). GPS at 20 200 km and 1575.42 MHz gives 182.503 dB [C].
- Source: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.525-5-202411-I!!PDF-E.pdf

### B.2 Log-distance and shadowing

- `PL(d) = PL(d₀) + 10 n log₁₀(d/d₀) + X_σ`, with X_σ zero-mean Gaussian in dB. Typical d₀ is 1 km for macro, 100 m for micro, 1 m for indoor (Andersen, Rappaport, Yoshida, *IEEE Commun. Mag.* Jan 1995, eq. 1; https://www.cs.columbia.edu/~xia/mobilex/ARY95.pdf) [V].
- Measured n and σ from the same paper's Table 2 [V]: office with hard partitions (1500 MHz) n = 3.0, σ = 7.0 dB. Factory LOS (1300 MHz) n = 1.6–2.0, σ = **3.0–6.0 dB**. The rows are textile/chemical 2.0/3.0, metalworking 1.6/5.8 and paper/cereals 1.8/6.0. [corrected in review: was 3.0–5.8]
- Street microcell: n ≈ 2 before the breakpoint and ≈ 4 after it [V].
- Classic exponent table (Rappaport, *Wireless Communications*, Table 4.2, via secondary reproductions) [S]: free space 2; urban cellular 2.7–3.5; shadowed urban 3–5; in-building LOS 1.6–1.8; obstructed in building 4–6; obstructed in factories 2–3.
- **Test:** f = 2.4 GHz, d₀ = 1 m (PL₀ = FSPL = 40.052 dB), n = 3, d = 20 m gives 79.083 dB [C].

### B.3 3GPP TR 38.901 V19.5.0 path-loss models (f_c in GHz, d in m) [V]

| Model | Formula | Shadowing σ | Validity |
|---|---|---|---|
| InH-Office LOS | 32.4 + 17.3 log d₃D + 20 log f_c | 3 dB | 1–150 m |
| InH-Office NLOS | max(PL_LOS, 38.3 log d₃D + 17.30 + 24.9 log f_c) | 8.03 dB | |
| UMa NLOS (optional) | 32.4 + 20 log f_c + 30 log d₃D | 7.8 dB | |
| UMi-Street Canyon NLOS (optional) | 32.4 + 20 log f_c + 31.9 log d₃D | 8.2 dB | |

- **Tests** [C]:
  - InH at 5.5 GHz, 10 m: LOS 64.507 dB, NLOS 74.035 dB.
  - UMa NLOS at 3.5 GHz, 500 m: 124.250 dB.
  - UMi NLOS at 28 GHz, 200 m: 134.746 dB (FSPL 107.412 dB).
- Source: https://www.etsi.org/deliver/etsi_tr/138900_138999/138901/19.05.00_60/tr_138901v190500p.pdf

### B.4 Two-ray ground reflection

- Exact: `P_r = P_t G_t G_r (λ/4π)² · |e^{−jkd₁}/d₁ + Γ e^{−jkd₂}/d₂|²`, with `d₁ = √(d² + (h_t−h_r)²)` and `d₂ = √(d² + (h_t+h_r)²)`. Use Γ ≈ −1 at grazing incidence.
- Far asymptote: `P_r ≈ P_t G_t G_r h_t² h_r² / d⁴`. It falls as d⁻⁴ and does not depend on frequency (Stanford EE359 lecture 2; https://web.stanford.edu/class/ee359/pdfs/lecture2_handout.pdf) [V].
- [!] Two "breakpoint" definitions are in use:
  - Crossover of the d⁻² and d⁻⁴ asymptotes: `d_x = 4π h_t h_r/λ`.
  - Goldsmith's critical distance `d_c = 4 h_t h_r/λ`. This is the **last interference maximum**: there the phase difference Δφ ≈ 4πh_th_r/(λd) = π, which is constructive with Γ = −1. Beyond it the d⁻⁴ regime begins. The last null is at Δφ = 2π, d ≈ 2h_th_r/λ. [corrected in review: was labeled "last null"]
  - Label which one the UI shows.
- **Test** (h_t = 30 m, h_r = 1.5 m, 900 MHz, isotropic, Γ = −1) [C]:

| Quantity | Value |
|---|---|
| d_x | 1697.6 m |
| d_c (last maximum) | 540.4 m (exact scan 540.2 m) |
| last null | 268.5 m exact (≈ 2h_th_r/λ = 270.2 m) [corrected in review] |
| d = 1 km | exact 88.012 dB, asymptote 86.936 dB, FSPL 91.533 dB |
| d = 10 km | exact 126.946 dB, asymptote 126.936 dB, FSPL 111.533 dB |

### B.5 Okumura–Hata and COST-231

- Hata, *IEEE Trans. Veh. Technol.* VT-29(3), 1980 (not fetched). Formulas verified against Altair WinProp docs (https://help.altair.com/winprop/topics/winprop/user_guide/propagation_methods/propgation_models_terrain_hata_okmura_model.htm) [V].
- Units: f in MHz, heights in m, d in km.
- Urban: `L = 69.55 + 26.16 log f − 13.82 log h_b − a(h_m) + (44.9 − 6.55 log h_b) log d`.
- Mobile antenna correction a(h_m):
  - Small or medium city: `(1.1 log f − 0.7) h_m − (1.56 log f − 0.8)`.
  - Large city: `8.29 (log 1.54 h_m)² − 1.1` for f ≤ 200 MHz, and `3.2 (log 11.75 h_m)² − 4.97` for f ≥ 400 MHz.
- Suburban: `L − 2[log(f/28)]² − 5.4`.
- Open: `L − 4.78 (log f)² + 18.33 log f − 40.94`.
- Validity: f 150–1500 MHz, h_b 30–200 m, h_m 1–10 m, d 1–20 km.
- COST-231 (1500–2000 MHz): `46.3 + 33.9 log f − 13.82 log h_b − a(h_m) + (44.9 − 6.55 log h_b) log d + C_m`, with C_m = 0 dB (medium city or suburban) or 3 dB (metropolitan).
- [!] Altair labels the `−2[log(f/28)]² − 5.4` correction "rural". In Hata's paper it is the suburban correction.
- **Tests** [C]:
  - f = 900, h_b = 30, h_m = 1.5, d = 5, small/medium city: a(h_m) = 0.0159 dB, L = **151.024 dB**. Large city: 151.041. Suburban: 141.082. Open: 122.518.
  - COST-231, f = 1800, d = 2, h_b = 30, h_m = 1.5: 146.801 dB (C_m = 0) and 149.801 dB (C_m = 3).

### B.6 Knife-edge diffraction (ITU-R P.526-16, 11/2025, §4.1) [V]

- Fresnel parameter: `ν = h √[(2/λ)(1/d₁ + 1/d₂)]` (eq. 26).
- Exact loss: `J(ν) = −20 log(√([1−C(ν)−S(ν)]² + [C(ν)−S(ν)]²)/2)`, where C and S are Fresnel integrals (eq. 30).
- Approximation for ν > −0.78: `J(ν) ≈ 6.9 + 20 log(√((ν−0.1)² + 1) + ν − 0.1)` dB (eq. 31). Otherwise J ≈ 0.
- **Tests** [C]:
  - J(0): 6.033 dB (approximation) vs 6.021 dB (exact, the classic −6 dB at grazing).
  - h = 10 m, d₁ = d₂ = 1 km, 900 MHz gives ν = 1.095 82, J ≈ 14.530 dB (approximation) and 14.476 dB (exact).
- Source: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.526-16-202511-I!!PDF-E.pdf

### B.7 Atmospheric gas absorption (ITU-R P.676-13, Annex 1 line-by-line) [V formula; C values]

- `γ = γ_o + γ_w = 0.1820 f [N″_Oxygen(f) + N″_WaterVapour(f)]` dB/km (eq. 1), with f in GHz.
- 44 oxygen lines and 35 water-vapour lines (Tables 1 and 2), plus the dry continuum (eq. 8).
- The table data is extracted to `rf-physics-calc/p676_tables.json` so Swift can embed it.
- Standard atmosphere: p = 1013.25 hPa, T = 15 °C, ρ = 7.5 g/m³.

| f (GHz) | γ_o | γ_w | total (dB/km) |
|---|---|---|---|
| 1 | 0.0053 | 0.0001 | 0.0054 |
| 2.4 | 0.0068 | 0.0003 | 0.0071 |
| 22.235 (H₂O line) | 0.0130 | 0.1803 | 0.1933 |
| 28 | 0.0183 | 0.0825 | 0.1008 |
| 39 | 0.0458 | 0.0760 | 0.1218 |
| **60** | **14.502** | 0.154 | **14.656** |
| 64 | 6.770 | 0.174 | 6.944 |
| 71 | 0.237 | 0.213 | 0.450 |
| 118.75 (O₂) | 1.334 | 0.610 | 1.944 |
| 183.31 (H₂O) | 0.013 | 28.247 | 28.260 |

- Oxygen peak: 14.91 dB/km near 60.8 GHz [C]. The brief's "~15 dB/km at 60 GHz" is confirmed.
- [!] This implementation has not been checked against ITU's official P.676 validation spreadsheets. Use ±0.05 dB/km until it is.
- [corrected in review] **Pressure convention.** The values above take 1013.25 hPa as *total* pressure. Then dry p = 1013.25 − e = 1003.28 hPa, with e = ρT/216.7 = 9.97 hPa. P.676 eq. (3) defines p as *dry* air pressure. If 1013.25 hPa is used as dry pressure, 60 GHz gives **14.778 dB/km**, 0.12 dB/km more, which exceeds the ±0.05 tolerance. Every test must state its convention. The review checked that `p676_tables.json` matches P.676-13 Tables 1–2 exactly, and that `b_prop.py` implements eqs. (1), (3) and (5)–(9) as printed.
- Source: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.676-13-202208-I!!PDF-E.pdf

### B.8 Rain attenuation (ITU-R P.838-3) [V]

- `γ_R = k R^α` dB/km, with R in mm/h.
- k and α come from eqs. (2)–(3), or from Table 5 directly. Mixed polarization uses eqs. (4)–(5): `k = [k_H + k_V + (k_H − k_V) cos²θ cos2τ]/2`.
- Table 5 rows [V]:

| f (GHz) | k_H | α_H | k_V | α_V |
|---|---|---|---|---|
| 28 | 0.2051 | 0.9679 | 0.1964 | 0.9277 |
| 39 | 0.4215 | 0.8743 | 0.4058 | 0.8486 |
| 60 | 0.8606 | 0.7656 | 0.8515 | 0.7486 |

- **Tests** (horizontal polarization, R = 25 mm/h) [C]: 28 GHz gives 4.624 dB/km. 39 GHz gives 7.031 dB/km. 60 GHz gives 10.117 dB/km. At 28 GHz, R = 50 mm/h gives 9.045 dB/km.
- Source: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.838-3-200503-I!!PDF-E.pdf

### B.9 Building entry and penetration loss

**ITU-R P.2109-2 (statistical, 0.08–100 GHz)** [V]:

- `L_BEL(P) = 10 log(10^{0.1A(P)} + 10^{0.1B(P)} + 10^{0.1C})`, with:
  - `A = F⁻¹(P)σ₁ + μ₁`, `B = F⁻¹(P)σ₂ + μ₂`, `C = −3`
  - `μ₁ = L_h + L_e`, `L_h = r + s log f + t (log f)²`, `L_e = 0.212|θ|`
  - `μ₂ = w + x log f`, `σ₁ = u + v log f`, `σ₂ = y + z log f`
- Table 1 coefficients (r, s, t, u, v, w, x, y, z):
  - Traditional: 12.64, 3.72, 0.96, 9.6, 2.0, 9.1, −3.0, 4.5, −2.0.
  - Thermally efficient: 28.19, −3.00, 8.48, 13.5, 3.8, 27.8, −2.9, 9.4, −2.1.
- **Tests** (median P = 0.5, θ = 0) [C]:

| f (GHz) | Traditional (dB) | Thermally efficient (dB) |
|---|---|---|
| 0.7 | 14.102 | 31.576 |
| 3.5 | 15.721 | 30.886 |
| 28 | 20.182 | 41.676 |
| 60 | 22.363 | 49.676 |

- Source: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.2109-2-202308-I!!PDF-E.pdf

**3GPP TR 38.901 O2I** (Tables 7.4.3-1 and 7.4.3-2, f in GHz) [V]:

- Material losses: glass `2 + 0.2f`; IRR glass `25.4 + 0.11f`; concrete `5 + 4f`; plywood `1.03 + 0.17f`; wood `4.85 + 0.12f`.
- Low-loss wall: `PL_tw = 5 − 10log(0.3·10^{−L_glass/10} + 0.7·10^{−L_concrete/10})`.
- High-loss wall: `PL_tw = 5 − 10log(0.7·10^{−L_IRR/10} + 0.3·10^{−L_concrete/10})`.
- Add `PL_in = 0.5 d_2D-in` and σ_P = 4.4 dB (low-loss) or 6.5 dB (high-loss).
- V19.5.0 Table 7.4.3-2 also defines a **low-loss A** model: `PL_tw = 5 − 10log(0.3·10^{−L_glass/10} + 0.7·10^{−L_plywood/10})`, σ_P = 4.4 dB. This model is where the plywood loss is used. [corrected in review: the model was missing]
- [!] IRR glass was updated in Release 19 (older releases use `23 + 0.3f`). Pin the release.
- **Tests:** 3.5 GHz gives PL_tw 12.698 dB (low) and 27.499 dB (high). 28 GHz gives 17.829 dB and 35.029 dB [C].

### B.10 Multipath fading (Stanford EE359 lectures 4–6) [V]

- Rayleigh envelope: `p(r) = (r/σ²) e^{−r²/(2σ²)}`. Received power is exponential, so `P(γ < γ₀) = 1 − e^{−γ₀/γ̄}`.
- Rician: `p(z) = (z/σ²) exp[−(z²+s²)/(2σ²)] I₀(zs/σ²)`, with `K = s²/(2σ²)` and `P_r = s² + 2σ²` (lecture 6).
- **Tests** (Rayleigh outage below the mean) [C]: −10 dB gives 0.095 163. −20 dB gives 0.009 950. −30 dB gives 9.995 × 10⁻⁴.

### B.11 Delay spread and coherence bandwidth

- RMS delay spread: `σ_τ = √(⟨τ²⟩ − ⟨τ⟩²)`.
- `B_c,90 ≈ 1/(50 σ_τ)` and `B_c,50 ≈ 1/(5 σ_τ)` (Georgia Tech ECE4823, citing Rappaport 2002; https://bpb-us-e1.wpmucdn.com/sites.gatech.edu/dist/c/488/files/2016/09/22-CoherenceBandwidth.pdf) [V].
- If the signal bandwidth exceeds B_c,50, the channel is frequency-selective [V].
- 3GPP TR 38.901 Table 7.7.3-1 scaling delay spreads: 10, 30, 100, 300, 1000 ns [V]. Table 7.7.3-2 examples [V]:
  - Indoor office normal: 39 ns at 2 GHz, 20 ns at 28 GHz.
  - UMa normal: 363 ns at 2 GHz, 266 ns at 28 GHz.
  - UMa long: 1148 ns at 2 GHz.
- **Tests:** σ_τ = 1 µs gives B_c,50 = 200 kHz and B_c,90 = 20 kHz. σ_τ = 363 ns gives B_c,50 = 551 kHz [C].

### B.12 Doppler and coherence time

- `f_D = (v/λ) cosθ` (EE359 lecture 4) [V]. Maximum `f_m = v f/c`.
- Clarke/Jakes spectrum: `S(f) = 1/(π f_m √(1 − (f/f_m)²))` for |f| < f_m.
- Coherence time [S, Rappaport]: `T_c ≈ 9/(16π f_m)` (0.5 correlation), or the geometric-mean rule `T_c ≈ 0.423/f_m`.
- **Tests** [C]: v = 30 m/s at 3.5 GHz gives f_m = 350.242 Hz, T_c(0.423) = 1.2077 ms, T_c(9/16π) = 0.5112 ms. 100 km/h at 2 GHz gives f_m = 185.313 Hz.

---

## C. Noise and capacity

### C.1 Thermal noise

- `N = k T B`. At T₀ = 290 K, `N₀ = −173.975 dBm/Hz` (the "−174") [C]. At 300 K it is −173.828 dBm/Hz.
- Utah ECE5325 lecture 5 [V]: `P_N = F k T₀ B`, k = −228.6 dBW/K/Hz.
- **Tests:** B = 20 MHz, NF = 7 dB gives **−93.965 dBm**. B = 1 MHz, NF = 0 gives −113.975 dBm. LTE 18 MHz occupied, NF = 7 gives −94.422 dBm [C].

### C.2 Noise figure and cascades

- `F = SNR_in/SNR_out`, `T_e = (F − 1) T₀`.
- Friis noise cascade: `F = F₁ + (F₂−1)/G₁ + (F₃−1)/(G₁G₂) + …` (Nikolova L07 §3.1) [V].
- **Test:** LNA (NF 1 dB, G 20 dB) followed by a mixer (NF 10 dB) gives F = 1.348 93, i.e. **1.300 dB**. NF 1 dB alone corresponds to T_e = 75.09 K [C].

### C.3 Link SNR

- `SNR(dB) = P_r(dBm) − [−173.975 + 10log₁₀B + NF]`.
- **Test (GPS):** P_r = −128.5 dBm and NF 2 dB give C/N₀ = 43.475 dB-Hz [C]. The −128.5 dBm minimum is already specified at the output of a 3 dBi linearly polarized antenna, so add no further antenna gain. [corrected in review: this test previously said "0 dBi antenna"]

### C.4 Shannon capacity

- `C = B log₂(1 + SNR)` (Shannon 1948). As B → ∞, the minimum `E_b/N₀ = ln 2 = −1.592 dB`.
- **Tests** [C]:
  - 20 MHz at 20 dB: **133.164 Mbit/s**.
  - 100 MHz at 30 dB: 996.723 Mbit/s.
  - 1 MHz at 0 dB: 1.000 Mbit/s.
- MIMO (Foschini/Telatar): `C = log₂ det(I + (ρ/N_t) H Hᴴ)` b/s/Hz. Tests at ρ = 20 dB [C]:

| Channel | Capacity (b/s/Hz) |
|---|---|
| SISO | 6.658 |
| H = I₂ | 11.345 |
| H = I₄ | 18.802 |
| H = [[1, 0.5], [0.5, 1]] | 10.581 |

### C.5 SNR, Eb/N0, Es/N0

- `E_b/N₀ = SNR · B/R_b`, `E_s/N₀ = (E_b/N₀) · log₂M`.

### C.6 Bit and symbol error rates (AWGN, coherent; EE359 lectures 9 and 10) [V]

- `Q(x) = ½ erfc(x/√2)`.
- BPSK, and Gray-coded QPSK per bit: `P_b = Q(√(2E_b/N₀))` (lecture 10) [V].
- General form: `P_s ≈ α_M Q(√(β_M γ_s))` (lecture 9) [V].
  - Square M-QAM: `α_M = 4(1−1/√M)`, `β_M = 3/(M−1)`.
  - M-PSK: `P_s ≈ 2Q(√(2γ_s) sin(π/M))`.
  - Goldsmith Table 6.1 [S].
  - With Gray coding, `P_b ≈ P_s/log₂M`.

**Tests** [C] (relative tolerance 1e-6):

| Case | Result |
|---|---|
| BPSK, E_b/N₀ = 0 dB | P_b = 7.864 960e-2 |
| BPSK, 6.79 dB | 9.994e-4 |
| BPSK, 9.59 dB | 9.953e-6 (10⁻⁵ needs 9.5879 dB) |
| BPSK, 10 dB | 3.872 108e-6 |
| 16-QAM, E_b/N₀ = 10 dB | P_s = 7.0166e-3 (exact square-QAM 7.0043e-3) |
| 64-QAM, 14 dB | P_s = 1.2924e-2 |
| 256-QAM, 18 dB | P_s = 2.7777e-2 |
| 8-PSK, E_s/N₀ = 15 dB | P_s = 2.3395e-3 |

### C.7 EVM

- `EVM_rms = √(Σ|e_k|²/Σ|s_ref,k|²)`, `EVM(dB) = 20log₁₀(EVM_rms)`.
- When noise-limited, `SNR ≈ −EVM_dB` [!] (approximate; ignores phase noise and nonlinearity).
- 3GPP TS 38.104 V19.6.0 Table 6.5.2.2-1 (base-station EVM) [V]:

| Modulation | Required EVM |
|---|---|
| QPSK | 17.5 % |
| 16QAM | 12.5 % |
| 64QAM | 8 % |
| 256QAM | 3.5 % |
| 1024QAM | 2.5 % (≤ 4.2 GHz) / 2.8 % (> 4.2 GHz) |

- 802.11ax 1024-QAM requires −35 dB (NI) [V]. 802.11be 4096-QAM is commonly quoted at −38 dB [S, not verified].
- **Tests:** 3.5 % = −29.119 dB. 2.5 % = −32.041 dB. −35 dB = 1.7783 %. −38 dB = 1.2589 % [C].

---

## D. Modulation

### D.1 AM (DSB with full carrier)

- `s(t) = A_c[1 + m cos 2πf_m t] cos 2πf_c t`.
- Lines at f_c (amplitude A_c) and f_c ± f_m (amplitude mA_c/2 each). B = 2f_m.
- `P_t = P_c(1 + m²/2)`, sideband efficiency `m²/(2+m²)`.
- **Tests:** m = 1 gives P_t/P_c = 1.5 and efficiency 33.33 %. m = 0.5 gives 1.125 and 11.11 % [C].

### D.2 FM

- `s(t) = A_c cos(2πf_c t + β sin 2πf_m t) = A_c Σ_n J_n(β) cos 2π(f_c + n f_m)t`, with `β = Δf/f_m`.
- Carson's rule: `B_T ≈ 2(Δf + f_m) = 2(β+1) f_m` (Stanford EE179 notes 9; https://web.stanford.edu/class/ee179/lectures/notes09.pdf) [S].
- US broadcast FM: ±75 kHz deviation is defined as 100 % modulation (47 CFR §73.310) [V].

**Tests** [C] (Swift `jn(n, β)`):

| β | Bessel values |
|---|---|
| 1 | J₀ = 0.765 20, J₁ = 0.440 05, J₂ = 0.114 90, J₃ = 0.019 56 |
| 2.404 826 | J₀ = 0 (carrier null) |
| 5 | J₀ = −0.177 60, J₁ = −0.327 58, J₄ = 0.391 23 |

- Broadcast: Δf = 75 kHz, f_m = 15 kHz gives β = 5 and **B_T = 180 kHz**. 99.36 % of the power lies within ±6 sidebands.
- AMPS: 2(12 + 3) = 30 kHz, which matches the channel width.

### D.3 PM

- `s = A_c cos(2πf_c t + k_p m(t))`. For a tone, `β_p = k_p A_m`, with the same Bessel line spectrum as FM. Only the β(f_m) dependence differs.

### D.4 ASK / FSK / GFSK

- FSK modulation index: `h = 2Δf/R_b`.
- Bluetooth BR: GFSK, BT = 0.5, h = 0.28–0.35, 1 Msym/s (so Δf = 140–175 kHz) (Core 5.4 Vol 2 Part A §3.1) [V].
- Bluetooth LE: GFSK, BT = 0.5, h = 0.45–0.55 (Core 5.4 Vol 6 Part A §3.1) [V].
  - LE 1M: 1 Msym/s, 1 Mb/s.
  - LE 2M: 2 Msym/s.
  - LE Coded: 125 kb/s (S = 8) or 500 kb/s (S = 2).
  - Sensitivity ≤ −70 / −75 / −82 dBm (uncoded / S2 / S8).
  - **Test:** h = 0.5 at 1 Mb/s gives Δf = 250 kHz.
- EDR: π/4-DQPSK (2 Mb/s) and 8DPSK (3 Mb/s), 1 Msym/s [V].

### D.5 MSK / GMSK (GSM; 3GPP TS 45.004 V19.0.0 §2) [V]

- `1/T = 1625/6 ksym/s ≈ 270.833 ksym/s` (1 bit/symbol).
- Gaussian filter: `h(t) = exp(−t²/(2δ²T²))/(√(2π) δT)` with `δ = √(ln 2)/(2π BT)`, BT = 0.3.
- **Tests:** T_b = 3.692 31 µs, B = 81.25 kHz, δ = 0.441 684 [C].
- EDGE 8PSK: 3 bits/symbol at the same symbol rate, 3π/8 rotation per symbol (§3.4) [V]. Gross rate 812.5 kbit/s per carrier [C].
- EGPRS2 adds 16QAM and 32QAM (§4) [V].

### D.6 PSK / QAM constellations (3GPP TS 38.211 V19.5.0 §5.1) [V]

- QPSK: `d = [(1−2b₀) + j(1−2b₁)]/√2`.
- Square M-QAM normalization: 1/√10 (16), 1/√42 (64), 1/√170 (256), 1/√682 (1024). In general `√(2(M−1)/3)`. 4096-QAM would be 1/√2730 [C].
- 16QAM mapping: `d = {(1−2b₀)[2−(1−2b₂)] + j(1−2b₁)[2−(1−2b₃)]}/√10`.
- **Tests:** bits 0000 give (1 + j)/√10 = 0.316 23 + 0.316 23j. Bits 0010 give (3 + j)/√10.
- Bits per symbol: BPSK 1, QPSK 2, 8PSK 3, 16QAM 4, 64QAM 6, 256QAM 8, 1024QAM 10, 4096QAM 12.

### D.7 DSSS and processing gain

- `G_p = 10 log₁₀(R_c/R_b)`.
- **Tests** [C]:
  - GPS C/A: 1.023 Mcps / 50 bps = **43.11 dB**. The code is 1023 chips with a 1 ms period.
  - IS-95: 1.2288 Mcps / 9.6 kb/s = 21.07 dB.
  - 802.11b Barker-11: 10.41 dB.
  - WCDMA SF 256: 24.08 dB.

### D.8 FHSS (Bluetooth BR/EDR)

- Channels: `f = 2402 + k MHz`, k = 0…78 (Vol 2 Part A Table 2.1) [V].
- Maximum hop rate 1600 hops/s in the Connection state and 3200 hops/s in Inquiry/Page. The slot is 625 µs (Vol 2 Part B) [V].
- **Test:** 1/1600 s = 625 µs.

### D.9 OFDM

- `Δf = 1/T_u`. Symbol duration `T = T_u + T_CP`.
- Subcarrier k has spectrum `T_u sinc((f − kΔf)T_u)`, with nulls at every other subcarrier.

**Tests** [C]:

| System | Δf | T_u | Notes |
|---|---|---|---|
| 802.11a/g | 20 MHz/64 = **312.5 kHz** | 3.2 µs | GI 0.8 µs, T = 4.0 µs. 48 data subcarriers × 6 bits × 3/4 / 4 µs = **54 Mb/s** |
| 802.11ax/be | 20 MHz/256 = **78.125 kHz** | 12.8 µs | GI 0.8, 1.6 or 3.2 µs (NI) [V] |
| LTE | 15 kHz | **66.667 µs** | Normal CP 160 T_s (5.208 µs, l = 0) or 144 T_s (4.6875 µs). Extended 512 T_s (16.667 µs). Slot check: 160 + 2048 + 6 × (144 + 2048) = 15 360 T_s = 0.5 ms |

- NR per numerology µ: see E.6.

### D.10 OFDMA, MIMO

- An LTE or NR resource block is 12 subcarriers (180 kHz in LTE). Spatial streams ≤ min(N_t, N_r).
- Coherent beamforming array gain is 10log₁₀N (N = 64 gives 18.06 dB; N = 256 gives 24.08 dB) [C].

---

## E. Generations and systems

### E.1 Cellular summary

| Gen | System | Key parameters | Source |
|---|---|---|---|
| 1G | AMPS (US) | MS Tx 824–849 MHz / BS Tx 869–894 MHz (45 MHz duplex). 30 kHz FM channels, ±12 kHz peak deviation, FDMA, 832 channels (A/B blocks of 416) | [S] Britannica, rfwireless-world. Band edges [V] in TS 45.005 (GSM 850 reuses them; "MXM 850" mixed-mode mentions 30 kHz carriers) |
| 2G | GSM | 200 kHz carriers. P-GSM 890–915 / 935–960 MHz, `F_l(n) = 890 + 0.2n`, F_u = F_l + 45 (n = 1…124). DCS 1800: 1710–1785 / 1805–1880. PCS 1900: 1850–1910 / 1930–1990. TDMA: slot = 3/5200 s ≈ 576.9 µs = 156.25 symbol periods; 8 slots = 4.615 ms frame. GMSK BT 0.3, 270.833 kbit/s | [V] TS 45.005 §2, Table 2-2; TS 45.002 §4.3; TS 45.004 |
| 2G | IS-95 cdmaOne | 1.2288 Mcps, 1.25 MHz carriers | [S] Qualcomm cdma2000/WCDMA paper; Pitt TELCOM 2720 slides |
| 2.75G | EDGE | 8PSK at 270.833 ksym/s (3π/8 rotation), 812.5 kbit/s gross per carrier | [V] TS 45.004 §3 |
| 3G | UMTS WCDMA | **3.84 Mcps** (TS 25.213 §4.4.1) [V], 5 MHz nominal channel. HSDPA 16QAM (Rel-5), HSPA+ 64QAM (Rel-7), DC-HSDPA (Rel-8) | release numbers [S, from memory] |
| 4G | LTE | Δf 15 kHz. T_s = 1/(15000 × 2048) s = 32.552 ns. CP per Table 6.12-1. RB = 12 subcarriers. 1.4/3/5/10/15/20 MHz → **6/15/25/50/75/100 RB** (TS 36.104 Table 5.6-1) [V]. Downlink 256QAM and 1024QAM defined (TS 36.211 §7.1.5–7.1.6) [V]. 4×4 MIMO, carrier aggregation, LAA | [V] TS 36.211 V19.3.0 |
| 5G | NR | See E.6 | [V] TS 38.211 / 38.104 / 38.101-1 |
| 6G | IMT-2030 | **Speculative.** ITU-R M.2160 framework (2023). WRC-27 agenda item 1.7 studies 4.4–4.8, 7.125–8.4 and 14.8–15.35 GHz. 3GPP Rel-20 studies from 2025, Rel-21 first specs about 2028–29. FR3 "7–24 GHz" appears in the 38.901 Rel-19 channel-model study note. Sub-THz 100–300 GHz is research only | [S] ITU WRS-24 slides, 3GPP Rel-20 page, Ericsson blog; [V] 38.901 Table 7.4.3-1 note 2 |

### E.2 Wi-Fi

| Standard | Bands | Widths (MHz) | Δf | Max QAM | Max SS | Headline PHY rate [C] |
|---|---|---|---|---|---|---|
| 802.11b | 2.4 GHz | 22 (DSSS/CCK) | n/a | DQPSK/CCK | 1 | 11 Mb/s |
| 802.11a | 5 GHz | 20 | 312.5 kHz | 64 | 1 | 54 Mb/s (48 × 6 × 3/4 / 4 µs) |
| 802.11g | 2.4 GHz | 20 | 312.5 kHz | 64 | 1 | 54 Mb/s |
| 802.11n (Wi-Fi 4) | 2.4/5 | 20/40 | 312.5 kHz | 64 | 4 | 600 Mb/s (108 × 6 × 5/6 / 3.6 µs × 4) |
| 802.11ac (Wi-Fi 5) | 5 | ≤ 160 | 312.5 kHz | 256 | 8 | 6933 Mb/s (468 × 8 × 5/6 / 3.6 µs × 8) |
| 802.11ax (Wi-Fi 6/6E) | 2.4/5/6 | ≤ 160 | **78.125 kHz** | 1024 | 8 | 9607.8 Mb/s (1960 × 10 × 5/6 / 13.6 µs × 8) |
| 802.11be (Wi-Fi 7) | 2.4/5/6 | ≤ 320 | 78.125 kHz | 4096 | **8** | 23 058.8 Mb/s (3920 × 12 × 5/6 / 13.6 µs × 8). MLO is mandatory for Wi-Fi CERTIFIED 7, where 320 MHz and 4096-QAM are optional [S] [corrected in review] |

- Sources: NI 802.11ax intro [V] (78.125 kHz, FFT 256–2048, 12.8 µs, 1024-QAM, −35 dB EVM). MathWorks Wi-Fi 7 overview [V] (320 MHz, 4096-QAM, MLO, 8×8 MU-MIMO). Juniper Mist docs [S] (final 802.11be is 8 SS, 23 Gb/s). Keysight 89600 help [V] (FFT sizes per bandwidth).
- 6 GHz: US 5925–7125 MHz (FCC 20-51) [S]. Europe 5945–6425 MHz (ECC Decision (20)01) [S].
- [!] The "46 Gb/s / 16 spatial streams" figure for Wi-Fi 7 comes from early drafts. The published amendment is limited to 8 SS.
- [!] Data-subcarrier counts (48 / 108 / 468 / 980 / 1960 / 3920) are from the IEEE MCS tables, which are paywalled and were not opened. They are confirmed indirectly because each reproduces its published headline rate. Further checks [C]:
  - HE MCS11 20 MHz 1 SS: 143.382 Mb/s.
  - HE MCS11 80 MHz 1 SS: 600.490 Mb/s.
  - HE 160 MHz 2 SS: 2401.961 Mb/s. Apple's Wi-Fi specification page (support.apple.com/guide/deployment/dep268652e6c) lists the iPhone 15 Pro Max as 802.11ax 2×2 with **160 MHz at 5 GHz and 6 GHz, 2400 Mbps**, and 20 MHz only at 2.4 GHz (229 Mbps) [V]. [corrected in review: this was previously "if 160 MHz is enabled"]

### E.3 Bluetooth (Core 5.4 HTML spec) [V]

- Band 2400–2483.5 MHz.
- BR/EDR: 79 × 1 MHz channels, `f = 2402 + k`.
- LE: 40 × 2 MHz channels, 2402–2480 MHz. Primary advertising channels: **37 = 2402 MHz, 38 = 2426 MHz, 39 = 2480 MHz** (Link Layer Table 1.3).
- **Test (LE index to frequency):** idx 0 → 2404, idx 10 → 2424, idx 11 → 2428, idx 36 → 2478. Mapping: `f = 2404 + 2i` for i = 0…10, `f = 2428 + 2(i−11)` for i = 11…36.

### E.4 Short-range and other radios

| System | Parameters | Source |
|---|---|---|
| **UWB** (IEEE 802.15.4z HRP) | Channel 5 = 6489.6 MHz (= 13 × 499.2), channel 9 = 7987.2 MHz (= 16 × 499.2), BW 499.2 MHz; ~2 ns pulses. ToF ranging: d = c·ToF; two-way d = c(T_round − T_reply)/2. **Test:** 1 m = 3.3356 ns. Rule-of-thumb resolution c/(2B) = 0.300 m [C, !rule of thumb] | Keysight HRP overview [S]; Qorvo (Apple U1/U2 channels 5 and 9) [S]; Apple support 109512 (availability varies by region) |
| **NFC** (ISO/IEC 14443) | f_c = 13.56 MHz, 106 kbit/s = f_c/128 = 105.9375 kbit/s (ETU 9.4395 µs). Type A reader→card 100 % ASK, modified Miller; card→reader load modulation of an f_c/16 = 847.5 kHz subcarrier, OOK Manchester. Type B 10 % ASK (8–14 %) NRZ-L; BPSK subcarrier | [V] Atmel/Microchip doc2056 |
| **GPS** | f₀ = 10.23 MHz. L1 = 154 f₀ = **1575.42 MHz**, L2 = 120 f₀ = 1227.6 MHz, L5 = 115 f₀ = **1176.45 MHz**. C/A: 1.023 Mcps, 1023 chips/1 ms, LNAV 50 bps, BPSK. Minimum received power L1 C/A **−158.5 dBW (−128.5 dBm)** into a 3 dBi linear antenna at ≥ 5° elevation. L5: I5 and Q5 (QPSK), 10.23 Mcps, 10 230 chips/1 ms, minimum −157.9 dBW (Block IIF) / −157.0 dBW (GPS III) per component | [V] IS-GPS-200N Table 3-Va and §3.3.1; IS-GPS-705J §3.2.1.1, Table 3-III |
| **Qi** | Baseline/Extended Power Profile operating frequency "typically 87 to 205 kHz". Qi2 MPP (magnetic) 360 kHz | [V] WPC Qi v1.3 Introduction §4.2; [S] Granite River Labs for 360 kHz |
| **AM broadcast** | US 535–1705 kHz, carriers 540–1700 kHz in 10 kHz steps (117). ITU Regions 1/3: 526.5–1606.5 kHz (9 kHz raster) | [V] 47 CFR §73.14; ITU terrestrial broadcasting bands page |
| **FM broadcast** | US 88–108 MHz, 100 channels × 200 kHz (ch 201 = 88.1 MHz … ch 300 = 107.9 MHz). ±75 kHz = 100 %. ITU Band II 87.5–108 MHz | [V] 47 CFR §73.201, §73.310; ITU |
| **DAB** | Band III 174–240 MHz. Mode I: 1536 carriers × 1 kHz = 1.536 MHz, T_u = 1 ms, guard 246 µs | [S] EBU Tech 3391 / ETSI EN 300 401 via search abstract |
| **TV** | ITU VHF 47–68 / 174–230 MHz (Region 1), UHF 470–862 MHz. US ATSC 6 MHz channels; Europe DVB-T 7/8 MHz | [V] ITU bands page; [S] channel widths |

### E.5 Satellite on the iPhone (Emergency SOS etc.)

- Globalstar L-band uplink (~1610–1618.725 MHz) and S-band downlink (~2483.5–2500 MHz, which overlaps LTE B53/n53) [S] (Hackaday 2022; Frank Rayal 2022 analysis of FCC filings). [!] Not from an Apple primary source.

### E.6 5G NR details (verified)

- Numerology (TS 38.211 Table 4.2-1) [V]: SCS = 15·2^µ kHz for µ = 0…6 (15, 30, 60, 120, 240, 480, 960 kHz). Extended CP only at µ = 2.
- Time units [V]: `T_c = 1/(Δf_max N_f)` with Δf_max = 480 kHz and N_f = 4096, so T_c = 0.508 63 ns. κ = T_s/T_c = 64.
  - `N_u = 2048κ·2^{−µ}`.
  - Normal CP: `N_CP = 144κ·2^{−µ}`, plus 16κ on the first symbol of each 0.5 ms (l = 0 or 7·2^µ).
  - Extended CP: `512κ·2^{−µ}`.
  - 14 symbols per slot, 2^µ slots per 1 ms subframe, 10 ms frame.
- **Tests** [C]:

| µ | T_u | Normal CP | Slot |
|---|---|---|---|
| 0 | 66.6667 µs | 4687.50 ns | 1 ms |
| 1 | 33.3333 µs | 2343.75 ns | 0.5 ms |
| 3 | 8.3333 µs | 585.94 ns | 0.125 ms |
| 6 | 1.0417 µs | 73.24 ns | 15.625 µs |

- Frequency ranges (TS 38.104 Table 5.1-1) [V]: FR1 410–7125 MHz. FR2-1 24 250–52 600 MHz. FR2-2 52 600–71 000 MHz.
- Maximum bandwidth [V]:
  - FR1 100 MHz: **273 RB** at 30 kHz, 135 RB at 60 kHz (38.101-1 Table 5.3.2-1).
  - FR2-1 400 MHz: 264 RB at 120 kHz (38.104 Table 5.3.2-2).
  - FR2-2 2000 MHz: 148 RB at 960 kHz (Table 5.3.2-3).
- Guard band formula (38.101-1 §5.3.3): `GB = (BW·1000 − N_RB·SCS·12)/2 − SCS/2` kHz. **Test:** 100 MHz, 30 kHz, 273 RB gives **845 kHz** [C].
- Bands (TS 38.104 Table 5.2-1/-2) [V]:

| Band | Range (MHz) |
|---|---|
| n41 | 2496–2690 TDD |
| n77 | 3300–4200 TDD |
| n78 | 3300–3800 TDD |
| n79 | 4400–5000 TDD |
| n257 | 26 500–29 500 |
| n258 | 24 250–27 500 |
| n260 | 37 000–40 000 |
| n261 | 27 500–28 350 |
| n71 | UL 663–698 / DL 617–652 |

- NR-ARFCN (TS 38.104 §5.4.2.1) [V]: `F_REF = F_REF-Offs + ΔF_Global (N_REF − N_REF-Offs)`:
  - 0–3000 MHz: ΔF = 5 kHz, N from 0.
  - 3000–24 250 MHz: 15 kHz, offset 3000 MHz at N = 600 000.
  - 24 250–100 000 MHz: 60 kHz, offset 24 250.08 MHz at N = 2 016 667.
  - **Test:** N = 633 333 gives 3499.995 MHz [C].
- Modulation up to 1024QAM (38.211 §5.1.7) [V].
- UE power class 3 = **23 dBm** in all FR1 bands. Class 2 = 26 dBm in n41, n77, n78 and others (38.101-1 Table 6.2.1-1) [V].

---

## F. iPhone 15 Pro Max: radios, sensors, antennas

### F.1 Model numbers and bands

Per-model bands come from Apple's cellular page, Wayback snapshot of 2024-03-15 (https://web.archive.org/web/20240315000000/https://www.apple.com/iphone/cellular/) [V].

| Model | Regions | 5G NR sub-6 | mmWave | LTE |
|---|---|---|---|---|
| **A2849** | US, Puerto Rico | n1, 2, 3, 5, 7, 8, 12, 14, 20, 25, 26, 28, 29, 30, 38, 40, 41, 48, 53, 66, 70, 71, 75, 76, 77, 78, 79 | **n258, n260, n261** | 1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 46, 48, 53, 66, 71 |
| **A3105** | Canada, Guam, Japan, Mexico, Saudi Arabia, USVI | same as A2849 | none | A2849 list plus **11, 21** |
| A3106 | Rest of world (incl. India, UK, EU, Australia) | n1, 2, 3, 5, 7, 8, 12, 20, 25, 26, 28, 30, 38, 40, 41, 48, 53, 66, 70, 75, 76, 77, 78, 79 (n75/n76 uncertain [corrected in review]: launch-time copies at EveryMac and TechWalls omit n75/n76 for A3106) | none | 1, 2, 3, 4, 5, 7, 8, 12, 13, 17, 18, 19, 20, 25, 26, 28, 30, 32, 34, 38, 39, 40, 41, 42, 46, 48, 53, 66 |
| A3108 | China mainland, Hong Kong, Macao | A3106 minus n53 | none | A3106 minus 53 |

- Tech-spec page support.apple.com/en-us/111828 (current) [V]:
  - UMTS/HSPA+/DC-HSDPA (850, 900, 1700/2100, 1900, 2100 MHz). [corrected in review: this was garbled as "850/900/1700/2100/1900/2100"]
  - GSM/EDGE 850/900/1800/1900 MHz.
  - "5G (sub‑6 GHz and mmWave) with 4x4 MIMO", "Gigabit LTE with 4x4 MIMO and LAA", "Wi‑Fi 6E (802.11ax) with 2x2 MIMO", "Bluetooth 5.3", "Second-generation Ultra Wideband chip", "Thread networking technology", "NFC with reader mode", "Express Cards with power reserve".
- [!] That page now lists the cellular models as "Model A2848 / Model A2849". A2848 is the iPhone 15 Pro's US number, so the page appears to have merged the Pro and Pro Max entries. Use the cellular-page table above for per-model bands.
- Location [V]: "Precision dual-frequency GPS (GPS, GLONASS, Galileo, QZSS, BeiDou, and NavIC)" (dual frequency means L1 + L5), digital compass, Wi‑Fi, cellular, iBeacon.
- Sensors [V]: Face ID, LiDAR Scanner, barometer, high dynamic range gyro, high-g accelerometer, proximity sensor, dual ambient light sensors. The MagSafe block also lists a **magnetometer** and "Accessory Identification NFC".
- Charging [V]: MagSafe up to 15 W, Qi2 up to 15 W, Qi up to 7.5 W.
- Size [V]: 76.7 × 159.9 × 8.25 mm, 221 g.
- Modem: Qualcomm Snapdragon X70 [S] (MacRumors, iFixit teardown 2023-09-25).

### F.2 Antenna placement (general terms only; Apple publishes no antenna map)

- The titanium band is bonded to an aluminum subframe. Plastic "antenna bands" divide the frame into **four electrically isolated sections** (iFixit, "Anodizing the iPhone 15 Pro": "The antenna bands divide the frame into four sections that don't share continuity") [V for the 15 Pro; S that the Pro Max is the same].
- Those frame segments are the radiators for cellular, GNSS and Wi-Fi/BT, fed and tuned at specific points. [!] Which band uses which segment is not public. The UI should say "frame segments act as antennas", not name a band per segment.
- US model (A2849) only: a **mmWave antenna window** on the side of the frame. iPhone 12–15 US models have it on the right side [S] (9to5Mac 2025-09-09; MacRumors 2023-09-13). mmWave is US-only [S].
- UWB, NFC (rear coil, shared area with the MagSafe and Qi coil) and the GNSS L5 path are internal. [!] Exact positions are unpublished.

### F.3 What iOS lets an app read (iPhoneOS27.0.sdk headers) [V]

This is not physics, but it bounds the "live interaction" ideas:

- **CoreTelephony:** `CTRadioAccessTechnologyNR`, `CTRadioAccessTechnologyNRNSA` (iOS 14.1), `CTRadioAccessTechnologyLTE` (iOS 7). These are strings only. No signal strength API.
- **NetworkExtension:**
  - `+[NEHotspotNetwork fetchCurrentWithCompletionHandler:]` (iOS 14) returns SSID, BSSID and securityType only. It needs **any one of** four conditions: precise-location authorization, the app configured the network through NEHotspotConfiguration, an active VPN configuration, or an active NEDNSSettingsManager configuration. It **also** needs the `com.apple.developer.networking.wifi-info` entitlement. [corrected in review: the earlier wording read as if all four were required]
  - `signalStrength` (0.0–1.0) exists only in the `NEHotspotNetwork (HotspotHelper)` category, which needs the HotspotHelper entitlement.
  - Treat Wi-Fi RSSI as unavailable.
- **CoreBluetooth:** `centralManager:didDiscoverPeripheral:advertisementData:RSSI:` gives a live BLE RSSI (dBm) per advertisement. This is the best real-radio input.
- **NearbyInteraction:** `NINearbyObject.distance` (float, m), `.direction` (simd_float3), `.horizontalAngle` (iOS 16). UWB ToF needs a peer device or accessory.
- **CoreMotion:** `CMMagnetometerData.magneticField` (`CMMagneticField`, µT). The header says this is the total field, including device bias. Usable as a near-field EMF probe for mains hum: 50/60 Hz aliases at low sample rates (see G.3). [corrected in review: this is uncertain. The header documents no output data rate and no anti-alias filter, and the sensor's internal decimation filter may suppress 50/60 Hz completely. Verify on the device before shipping it as a feature.]

---

## G. Fourier analysis and Accelerate vDSP

### G.1 DFT convention

- Forward: `X[k] = Σ_{n=0}^{N−1} x[n] e^{−j2πkn/N}`. Inverse: `x[n] = (1/N) Σ X[k] e^{+j2πkn/N}`.
- Bin frequency `f_k = k f_s/N`, resolution `Δf = f_s/N`, one-sided bins k = 0…N/2.
- Parseval: `Σ|x|² = (1/N)Σ|X|²`.
- Tone amplitude: for `x = A cos(2πk₀n/N)`, `|X[k₀]| = AN/2`. So `Â = 2|X[k]|/(N·CG)`, where CG is the window's coherent gain.
- **Tests** [C]:
  - f_s = 48 kHz, N = 4096: Δf = 11.718 75 Hz, window 85.333 ms.
  - N = 1024: Δf = 46.875 Hz. Bin 100 = 4687.5 Hz.
  - Unit cosine at bin 100, N = 1024: |X| = 512 (rectangular) or 256 (Hann). Parseval: both sides 512.

### G.2 Hann window and leakage (Harris, *Proc. IEEE* 66(1), 1978, pp. 51–83; http://www.ece.uprm.edu/~domingo/teaching/inel5309/On%20the%20Use%20of%20Windows%20for%20Harmonic%20Analysis%20with%20the%20DFT.pdf) [V as source; C values]

- Periodic Hann, which is what vDSP generates: `w[n] = 0.5(1 − cos(2πn/N))`. The symmetric form uses N − 1. Use periodic for spectral analysis.
- Properties for N = 1024 [C]:

| Property | Hann | Rectangular |
|---|---|---|
| Coherent gain | 0.500 (−6.021 dB) | 1.000 |
| ENBW | 1.500 bins | 1.000 |
| Scalloping loss | **1.4236 dB** | 3.9224 dB |
| Highest sidelobe | **−31.47 dB** | −13.26 dB |
| First null | ±2 bins | ±1 bin |
| Sidelobe roll-off | −18 dB/octave | −6 dB/octave |

- Harris tabulates Hann as about −32 dB sidelobe, ENBW 1.50, scallop 1.42 dB, 3 dB bandwidth 1.44 bins.
- Leakage test: a *complex exponential* half a bin off-grid loses **3.9224 dB** (rectangular) or 1.4236 dB (Hann) at the nearest bin [C]. For a *real* cosine at bin 100.5 (N = 1024), the negative-frequency image moves the rectangular figure to between 3.90 and 3.94 dB, depending on phase and which neighbouring bin you read. Hann stays at 1.4236 dB. Use a complex input for oracles, or allow ±0.04 dB. [corrected in review: was "3.90 dB"]

### G.3 Nyquist and aliasing

- Nyquist frequency `f_s/2`. Alias: `f_a = |f − f_s·round(f/f_s)|`.
- **Tests** [C]: 60 Hz sampled at 100 Hz appears at 40 Hz. 50 Hz at 100 Hz sits at 50 Hz (exactly Nyquist, ambiguous). 120 Hz at 100 Hz appears at 20 Hz. 1 kHz at 800 Hz appears at 200 Hz.

### G.4 Accelerate API (verified in `iPhoneOS27.0.sdk`) [V]

**Swift overlay** (`usr/lib/swift/Accelerate.swiftmodule/arm64e-apple-ios.swiftinterface`):

- `vDSP.DiscreteFourierTransform<T>`:
  - `init(previous: vDSP.DiscreteFourierTransform<Float>? = nil, count: Int, direction: vDSP.FourierTransformDirection, transformType: vDSP.DFTTransformType, ofType: T.Type) throws` (iOS 15).
  - `init(previousDFT:count:direction:transformType:ofType:) throws` (iOS 26).
  - Methods: `transform(real:imaginary:) -> (real:[Float], imaginary:[Float])` and `transform(inputReal:inputImaginary:outputReal:outputImaginary:)`.
  - `T` can be Float, Double, `DSPComplex` or `DSPDoubleComplex`. [corrected in review] The two methods above exist only for Float and Double. For `DSPComplex` and `DSPDoubleComplex` the methods are `transform(input:) -> [DSPComplex]` and `transform(input:output:)`. These types run on `vDSP_DFT_Interleaved_CreateSetup`, whose lengths are **f·2ⁿ with f ∈ {2, 3, 5, 9, 15, 25} and n ≥ 2** (vDSP.h line 7523), not the zop/zrop rule below.
  - Throws `vDSP.DFTError.invalidSplitComplexCount` or `.invalidInterleavedCount`.
- `vDSP.DFT<T>` is **deprecated** ("Use `vDSP.DiscreteFourierTransform`").
- `vDSP.DFTTransformType`: `.complexComplex`, `.complexReal`. `vDSP.FourierTransformDirection`: `.forward`, `.inverse`.
- swiftdoc: "When the `transformType` is `complexReal`, each array (Ir, Ii, Or, and Oi) must have `count/2` elements."
- `vDSP.FFT<T>`, created with the **failable** `init?(log2n: vDSP_Length, radix:ofType:)` [corrected in review], with `vDSP.Radix` `.radix2/.radix3/.radix5`, and `forward(input:output:)` / `inverse(input:output:)` on `DSPSplitComplex`. `vDSP.FFT2D`.
- `vDSP.window(ofType:usingSequence:count:isHalfWindow:) -> [T]` with `vDSP.WindowSequence`: `.hanningNormalized`, `.hanningDenormalized`, `.hamming`, `.blackman`. There is also `vDSP.formWindow(usingSequence:result:isHalfWindow:)`.
- `vDSP.squareMagnitudes(_ splitComplex: DSPSplitComplex, result:)`, `vDSP.absolute(_: DSPSplitComplex, result:)`.
- `vDSP.convert(power:toDecibels:zeroReference:)` (10log) and `vDSP.convert(amplitude:toDecibels:zeroReference:)` (20log).
- `vDSP.convert(interleavedComplexVector:toSplitComplexVector:)`.

**C header** (`vecLib.framework/Headers/vDSP.h`):

- `vDSP_hann_window(float *C, vDSP_Length N, int Flag)`.
  - Flags: `vDSP_HANN_DENORM = 0`, `vDSP_HALF_WINDOW = 1`, `vDSP_HANN_NORM = 2`.
  - Computes `C[n] = W·(1 − cos(2πn/N))` with W = 0.5 (denorm, peak 1) or **W = 0.816 496 580 927 726 = √(2/3)** (norm; mean-square = 1.000 [C]).
  - Half window length is (N+1)/2. This is the **periodic** Hann.
- Implemented DFT lengths:
  - Complex `zop`: 2ⁿ, or f·2ⁿ with f ∈ {3, 5, 15}, n ≥ 3.
  - Real `zrop`: 2ⁿ, or f·2ⁿ with f ∈ {3, 5, 15}, n ≥ 4.
  - Other lengths return a NULL setup.

[!] `zrop` scaling and packing (vDSP.h, `vDSP_DFT_zrop_CreateSetup` docs):

- Forward computes `H[k] = C·Σ h[j] e^{−2πijk/N}` with **C = 2**. The inverse uses C = 1. A forward→inverse round trip therefore scales by **2N**.
- Input: even samples go in Ir, odd samples in Ii.
- Output packing: `Or[0] = H[0]` (DC, real), `Oi[0] = H[N/2]` (Nyquist, real), and `Or[k] + i·Oi[k]` for 1 ≤ k < N/2.
- **Test:** unit cosine at bin 100, N = 1024: vDSP reports |H| = 1024 (rectangular) or 512 (Hann denorm), twice the math-DFT values in G.1 [C].

---

## H. Coupling chain for the node graph

Each arrow is a formula above, so a node can expose its inputs and outputs directly:

`f` → `λ = c/f` → `E_photon = h f` (links to the EM-spectrum prototype; **test:** 2.4 GHz gives 1.5903 × 10⁻²⁴ J = 9.926 µeV [C]) → antenna size (λ/2 dipole, λ/4 monopole, patch L, array d = λ/2) → pattern / D / G (A.1–A.12) → mismatch and polarization (A.15–A.16) → EIRP (A.14) → path loss: FSPL, log-distance or 3GPP, plus two-ray, knife edge, gas, rain and building entry (B.1–B.9) → fading and Doppler (B.10–B.12) → `P_r` → noise floor `kTB·F` (C.1–C.2) → SNR → Shannon capacity or BER(M) (C.4–C.6) → choice of modulation and EVM budget (C.7, D) → spectrum shape: OFDM sinc lines, FM Bessel lines, GFSK and so on (D) → FFT visualizer (G) → back to `f`.

---

## I. Flags and discrepancies with the brief

1. **Monopole:** the brief says 5.15 dBi; the correct value is 10log₁₀(3.282) = **5.16 dBi**.
2. **GPS:** the brief says "BPSK, ~−130 dBm". L1 C/A is BPSK. **L5 is QPSK** (I5/Q5). The specified minimum received power is **−128.5 dBm** (L1 C/A, 3 dBi linear antenna) and −127.9 / −127.0 dBm per L5 component.
3. **Wi-Fi 7:** final 802.11be is 8 spatial streams (23 Gb/s), not 16 (46 Gb/s).
4. **Helix:** the Kraus 10.8 + 10log(...) gain is optimistic by up to 4–5 dB (NRAO/Emerson). Show the realistic curve too.
5. **Dish HPBW:** 70λ/D applies to typical tapered illumination. The uniform-aperture value is **58.96λ/D** (1.029λ/D rad). The commonly printed 58.4λ/D is a rounding. [corrected in review]
6. **Patch "6–9 dBi":** true for low ε_r. High-ε_r GPS ceramics are about 5 dBi directivity.
7. **Hann sidelobe:** Harris rounds to −32 dB; the exact value is −31.47 dB. vDSP's Hann is periodic (N, not N−1).
8. **vDSP real DFT:** forward output is 2× the textbook DFT, and Nyquist is packed in `Oi[0]`.
9. **η convention:** "73 Ω / 31 171 / 80π²" assume η = 120π. With η₀ the dipole gives 73.079 Ω.
10. **Two-ray breakpoint:** 4πh_th_r/λ (asymptote crossover) and 4h_th_r/λ (Goldsmith d_c, the last interference *maximum*, not a null) are different quantities. [corrected in review]
11. **TR 38.901 IRR glass:** changed in Release 19 to 25.4 + 0.11f (previously 23 + 0.3f).
12. **Apple support page 111828** shows "A2848 / A2849". Use the archived cellular page for per-model bands. A3105 (Canada/Japan/Mexico/Saudi) has **no mmWave**.
13. **Hata naming:** some tools label the suburban correction "rural"; follow Hata (1980).
14. **Bluetooth:** modulation index is 0.28–0.35 for BR and 0.45–0.55 for LE; both use BT = 0.5. GSM GMSK uses BT = 0.3.
15. **Qi:** 87–205 kHz covers BPP/EPP. Qi2 MPP (what the iPhone's 15 W Qi2 uses) runs at about 360 kHz [S].
16. **PIFA:** "L + W ≈ λ/4" is a rough guide and does not reproduce MathWorks' reference PIFA. Do not unit-test against it.
17. **P.676:** this implementation has not been checked against ITU's validation data (±0.05 dB/km until it is).
18. **Not opened this session, so treat as [S]:** Balanis Example 14.1, Goldsmith Table 6.1, Rappaport Table 4.2, Hata 1980, AMPS ±12 kHz deviation, HSPA release numbers, DAB numerology, 802.11 data-subcarrier tables, 4096-QAM −38 dB EVM, Globalstar SOS bands, the iPhone mmWave window side.
19. **Half-wave radiation integral** [corrected in review]: 𝓘 = Cin(2π)/2 = 1.218 827, not Cin(2π).
20. **Broadside-lobe limit** [corrected in review]: the dipole's global maximum leaves θ = 90° at L ≈ 1.44λ, not 1.5λ.
21. **Review record:** see `rf-physics-review.md` for the item-by-item verdicts and the consolidated "Verified reference" section. Use that section as the oracle source.

---

## J. Source index (all fetched 2026-10-03 unless noted)

**Antennas**

- Nikolova lectures L03–L21: https://www.ece.mcmaster.ca/faculty/nikolova/antenna_dload/current_lectures/
- SDSMT EE483 Yagi notes (NBS TN 688 table): http://montoya.sdsmt.edu/ee483_583/notes/yagi_uda_design.pdf
- Cebik helix notes: https://q82.uk/projects/cebik/uhfvhf/Axial-Mode%20Helical%20Antennas%20-%20Part%202.pdf
- Emerson (NRAO) helix gain: https://www.cv.nrao.edu/~demerson/cs/helix.htm
- NASA NTRS (70λ/D): https://ntrs.nasa.gov/api/citations/20070032925/downloads/20070032925.pdf
- ADI grating lobes: https://www.analog.com/media/en/analog-dialogue/volume-54/number-2/phased-array-antenna-patterns-part-2-grating-lobes-and-beam-squint.pdf
- MathWorks PIFA: https://www.mathworks.com/help/antenna/ref/pifa.html

**Propagation**

- ITU-R P.525-5: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.525-5-202411-I!!PDF-E.pdf
- ITU-R P.526-16: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.526-16-202511-I!!PDF-E.pdf
- ITU-R P.676-13: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.676-13-202208-I!!PDF-E.pdf
- ITU-R P.838-3: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.838-3-200503-I!!PDF-E.pdf
- ITU-R P.2109-2: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.2109-2-202308-I!!PDF-E.pdf
- 3GPP TR 38.901 V19.5.0: https://www.etsi.org/deliver/etsi_tr/138900_138999/138901/19.05.00_60/tr_138901v190500p.pdf
- Andersen/Rappaport/Yoshida 1995: https://www.cs.columbia.edu/~xia/mobilex/ARY95.pdf
- Stanford EE359 lectures 2, 4, 6, 9, 10: https://web.stanford.edu/class/ee359/pdfs/lectureN_handout.pdf
- Georgia Tech coherence bandwidth: https://bpb-us-e1.wpmucdn.com/sites.gatech.edu/dist/c/488/files/2016/09/22-CoherenceBandwidth.pdf
- Altair Hata: https://help.altair.com/winprop/topics/winprop/user_guide/propagation_methods/propgation_models_terrain_hata_okmura_model.htm

**Noise, modulation, regulation**

- Utah ECE5325 lecture 5: https://span.ece.utah.edu/uploads/lecture05-s13.pdf
- Stanford EE179 notes 9: https://web.stanford.edu/class/ee179/lectures/notes09.pdf
- 47 CFR §73.14: https://www.law.cornell.edu/cfr/text/47/73.14
- 47 CFR §73.201: https://www.law.cornell.edu/cfr/text/47/73.201
- 47 CFR §73.310: https://www.law.cornell.edu/cfr/text/47/73.310
- ITU broadcasting bands: https://www.itu.int/en/ITU-R/terrestrial/broadcast/Pages/bands.aspx

**3GPP (ETSI copies)**

- TS 38.211 V19.5.0: https://www.etsi.org/deliver/etsi_ts/138200_138299/138211/19.05.00_60/ts_138211v190500p.pdf
- TS 38.104 V19.6.0: https://www.etsi.org/deliver/etsi_ts/138100_138199/138104/19.06.00_60/ts_138104v190600p.pdf
- TS 38.101-1 V19.7.0: https://www.etsi.org/deliver/etsi_ts/138100_138199/13810101/19.07.00_60/ts_13810101v190700p.pdf
- TS 36.211 V19.3.0: https://www.etsi.org/deliver/etsi_ts/136200_136299/136211/19.03.00_60/ts_136211v190300p.pdf
- TS 36.104 V19.2.0: https://www.etsi.org/deliver/etsi_ts/136100_136199/136104/19.02.00_60/ts_136104v190200p.pdf
- TS 25.213 V19.0.0: https://www.etsi.org/deliver/etsi_ts/125200_125299/125213/19.00.00_60/ts_125213v190000p.pdf
- TS 45.002 V19.0.0: https://www.etsi.org/deliver/etsi_ts/145000_145099/145002/19.00.00_60/ts_145002v190000p.pdf
- TS 45.004 V19.0.0: https://www.etsi.org/deliver/etsi_ts/145000_145099/145004/19.00.00_60/ts_145004v190000p.pdf
- TS 45.005 V19.0.0: https://www.etsi.org/deliver/etsi_ts/145000_145099/145005/19.00.00_60/ts_145005v190000p.pdf

**Bluetooth Core 5.4 (HTML)**

- https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/low-energy-controller/physical-layer-specification.html
- `.../low-energy-controller/link-layer-specification.html`
- `.../br-edr-controller/radio-specification.html`
- `.../br-edr-controller/baseband-specification.html`

**Wi-Fi**

- NI 802.11ax intro: https://www.ni.com/en/solutions/semiconductor/wireless-connectivity-test/introduction-to-802-11ax-high-efficiency-wireless.html
- MathWorks Wi-Fi 7 overview: https://www.mathworks.com/help/wlan/ug/overview-of-wifi-7-or-ieee-802-11-be.html
- Juniper Wi-Fi 7 considerations: https://www.juniper.net/documentation/us/en/software/mist/mist-wireless/topics/concept/mist-wireless-wi-fi-7-considerations.html
- Keysight 89600 WLAN help: https://helpfiles.keysight.com/csg/89600B/Webhelp/Subsystems/wlan-mimo/content/mimo_using_standard_setup.htm
- FCC 20-51: https://docs.fcc.gov/public/attachments/FCC-20-51A1.pdf
- ECC Decision (20)01: https://docdb.cept.org/download/4577

**UWB, NFC, GNSS, Qi**

- Keysight HRP UWB overview: https://www.keysight.com/blogs/en/tech/rfmw/2021/07/28/an-overview-of-the-ieee-802154-hrp-uwb-standard
- Qorvo (Apple U1/U2): https://www.qorvo.com/innovation/ultra-wideband/products/uwb-solutions-compatible-with-apple-u1
- Apple UWB availability: https://support.apple.com/en-us/109512
- Atmel/Microchip ISO 14443: https://ww1.microchip.com/downloads/en/devicedoc/doc2056.pdf
- IS-GPS-200N: https://www.navcen.uscg.gov/sites/default/files/pdf/gps/IS-GPS-200N.pdf
- IS-GPS-705J: https://www.navcen.uscg.gov/sites/default/files/pdf/gps/IS-GPS-705J.pdf
- WPC Qi v1.3 intro: https://www.wirelesspowerconsortium.com/media/cd4ljryt/qi-v13-introduction.pdf
- Granite River Labs Qi2: https://www.graniteriverlabs.com/en-us/technical-blog/qi2-wireless-charging-standards-evolution

**Legacy and 6G (secondary)**

- Britannica AMPS: https://www.britannica.com/technology/advanced-mobile-phone-system
- rfwireless-world AMPS: https://www.rfwireless-world.com/Tutorials/AMPS-tutorial.html
- Qualcomm cdma2000/WCDMA: https://www.qualcomm.com/media/documents/files/commonalities-between-cdma2000-and-wcdma-technologies.pdf
- Pitt TELCOM 2720 slides: https://sites.pitt.edu/~dtipper/2720/2720_Slides13.pdf
- ITU WRS-24 slides: https://www.itu.int/en/ITU-R/seminars/wrs/Documents/2024/Presentations/17-Broadband_trends_WRS24_K_Bogens.pdf
- 3GPP Release 20: https://www.3gpp.org/specifications-technologies/releases/release-20
- Ericsson 6G timeline: https://www.ericsson.com/en/blog/2024/3/6g-standardization-timeline-and-technology-principles

**Apple and iPhone**

- Apple tech specs 111828: https://support.apple.com/en-us/111828
- Apple cellular page (Wayback 2024-03-15): https://web.archive.org/web/20240315000000/https://www.apple.com/iphone/cellular/
- iFixit anodizing article: https://www.ifixit.com/News/89241/anodizing-the-iphone-15-pro
- MacRumors teardown: https://www.macrumors.com/2023/09/25/iphone-15-pro-max-teardown-ifixit/
- MacRumors mmWave US-only: https://www.macrumors.com/2023/09/13/mmwave-5g-iphone-15-us-only/
- 9to5Mac mmWave window: https://9to5mac.com/2025/09/09/iphone-17-pro-mmwave-glass-cutout-new-location/
- Hackaday SOS: https://hackaday.com/2022/09/09/apples-satellite-emergency-texts-how-do-they-work/
- Frank Rayal SOS analysis: https://frankrayal.com/2022/09/12/apple-globalstar-just-an-sos-or-birth-of-the-global-telco/

**Fourier**

- Harris 1978: http://www.ece.uprm.edu/~domingo/teaching/inel5309/On%20the%20Use%20of%20Windows%20for%20Harmonic%20Analysis%20with%20the%20DFT.pdf

**SDK (local, Xcode-beta, iPhoneOS27.0.sdk)**

- `usr/lib/swift/Accelerate.swiftmodule/arm64e-apple-ios.swiftinterface` and `.swiftdoc`
- `System/Library/Frameworks/Accelerate.framework/Frameworks/vecLib.framework/Headers/vDSP.h`
- `usr/include/math.h`
- `CoreTelephony/CTTelephonyNetworkInfo.h`
- `NetworkExtension/NEHotspotNetwork.h`, `NEHotspotHelper.h`
- `CoreBluetooth/CBCentralManager.h`
- `NearbyInteraction/NINearbyObject.h`
- `CoreMotion/CMMagnetometer.h`
