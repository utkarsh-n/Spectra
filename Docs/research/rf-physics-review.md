# RF Lab physics reference: adversarial review

Review of `Docs/research/rf-physics.md`, done 2026-10-03. I assumed errors existed and checked every formula, constant, band edge and worked test value. Each one was checked in one or more of these ways:

- **R (recomputed):** I wrote fresh Python code (mpmath, numpy, pypdf), separate from the author's `rf-physics-calc/` scripts. It is in the session scratchpad, so it is not in the repo.
- **P (primary source):** I read the primary document myself this session. That means the ETSI PDFs of TS 38.104 V19.6.0 and TR 38.901 V19.5.0, and the ITU-R P.838-3, P.2109-2 and P.676-13 PDFs (the PDF text was extracted and the tables parsed line by line). It also covers Apple support pages 111828, 108044 and the Wi-Fi deployment guide, the NRAO Emerson helix page, the Cebik helix notes, Andersen/Rappaport/Yoshida 1995, the MathWorks PIFA page, and search abstracts for IS-GPS-705.
- **H (SDK header):** I read the iPhoneOS27.0.sdk headers and the Swift interface myself.
- **S (secondary):** I could only reach a secondary source.

Verdicts are **correct**, **corrected** (the value or statement was wrong and has been fixed in place in `rf-physics.md` with the marker `[corrected in review]`), or **uncertain** (could not be confirmed, or depends on a convention that the doc must state).

## Summary of what was wrong

There are 7 substantive errors and 9 clarifications or omissions. All of them are fixed in place.

| # | Section | Problem | Fix |
|---|---|---|---|
| 1 | A.3 | The doc says the radiation integral of the λ/2 dipole equals `𝓘 = Cin(2π) = 2.437 653`. That is **wrong by a factor of 2**. With 𝓘 as the doc defines it, `𝓘 = Cin(2π)/2 = 1.218 827`. If you plug 2.4377 into the doc's own `R_r = η𝓘/(2π)` you get 146 Ω, and `D = 2F_max/𝓘` gives 0.82. The table values (73.079 Ω, D = 1.6409) are right, because the author's script integrated numerically. | `𝓘 = Cin(2π)/2 = 1.218 827`; `R_r = η·Cin(2π)/(4π)` is unchanged. |
| 2 | A.3 | The doc says "For L > 1.5λ the main lobe leaves broadside", yet in the same bullet it reports the maximum at 137° when L = 1.5λ. The global maximum actually leaves broadside at **L ≈ 1.44λ** (recomputed). | Use 1.44λ. The simulator must search for F_max at every L > 1.25λ. |
| 3 | A.10 / flag 5 | Uniform circular aperture HPBW is not 58.4 λ/D. The exact value comes from `(2J₁(u)/u)² = ½`, which gives u = 1.616 34, so HPBW = **1.0290 λ/D rad = 58.96° λ/D**. The 58.4 (2 × 29.2°) is the Balanis-table rounding with u ≈ 1.6, about 1 % low. | The test value HPBW(uniform) for D = 0.6 m at 12 GHz is **2.4550°**, not 2.4316°. |
| 4 | B.4 | The doc calls Goldsmith's `d_c = 4h_t h_r/λ` "the last null". It is the **last maximum**: the phase difference Δφ = 4πh_t h_r/(λd) equals π there, and with Γ = −1 that is constructive. The last null is at Δφ = 2π, d ≈ 2h_t h_r/λ. Exact scan for the test geometry: last maximum 540.2 m, last null **268.5 m** (small-angle estimate 270.2 m). | Relabel. |
| 5 | B.2 | Andersen 1995 Table 2 factory LOS at 1300 MHz gives σ = **3.0–6.0 dB**, not 3.0–5.8. Paper/cereals is n = 1.8, σ = 6.0. | Range changed. |
| 6 | G.2 | The leakage test said "rectangular loses 3.90 dB". The analytic scalloping loss is **3.922 dB**, which the doc's own table uses. A real cosine at bin 100.5, N = 1024, gives 3.90–3.94 dB depending on phase and which neighbouring bin you read, because of the negative-frequency image. As a test oracle the test was underspecified. | Use a complex exponential (gives exactly 3.9224 dB), or allow ±0.04 dB. Hann is 1.4236 dB with any phase. |
| 7 | F.3 | The doc said `NEHotspotNetwork.fetchCurrent` "requires precise location, a hotspot configuration, VPN or DNS settings". The header says **any one of** the four, plus the `wifi-info` entitlement. | Reworded. |
| 8 | B.7 | The P.676 values depend on a pressure convention the doc did not state. The author used 1013.25 hPa as **total** pressure, so dry p = 1003.28 hPa and e = 9.97 hPa. If 1013.25 hPa is taken as dry pressure (P.676 eq. 3 defines p as dry), 60 GHz becomes **14.778** instead of 14.656 dB/km, a 0.12 dB/km shift that exceeds the doc's ±0.05 tolerance. | State the convention in the test. The line tables in `p676_tables.json` match P.676-13 Tables 1–2 exactly (72 of 79 rows parsed and diffed, the rest compared by eye). The eqs. (1), (3), (5)–(9) in the author's code match the PDF. |
| 9 | A.5 | Loop Test 1 (0.049 223 Ω) silently uses η = 120π, against the doc's own rule that every test names its η. | With η₀ it is 0.049 189 Ω. |
| 10 | C.3 | The GPS C/N₀ test said "0 dBi antenna". The −128.5 dBm minimum is already defined at the output of a 3 dBi linearly polarized antenna, so no gain should be added. | The number 43.475 dB-Hz is unchanged; only the wording changed. |
| 11 | E.2 | "iPhone 15 Pro Max ceiling if 160 MHz is enabled": Apple's Wi-Fi spec page lists **160 MHz at 5 and 6 GHz, 2400 Mbps** (2×2), and 20 MHz only at 2.4 GHz (229 Mbps). Also, "MLO mandatory" is true for Wi-Fi CERTIFIED 7 (WFA), not as an IEEE requirement, and 320 MHz and 4096-QAM are *optional* for certification [S]. | Clarified. |
| 12 | F.1 | The UMTS line was garbled as "850/900/1700/2100/1900/2100". Apple prints "850, 900, 1700/2100, 1900, 2100 MHz". The A3106 n75/n76 entries are uncertain: launch-time copies (EveryMac, TechWalls) list A3106 *without* n75/n76, and Apple's current page lists them for A2849. | Fixed and flagged. |
| 13 | G.4 | Omission: `vDSP.DiscreteFourierTransform<DSPComplex>` uses `transform(input:)` and `transform(input:output:)`, not `real:imaginary:`. It runs on `vDSP_DFT_Interleaved_CreateSetup`, whose lengths are **f·2ⁿ, f ∈ {2, 3, 5, 9, 15, 25}, n ≥ 2** (vDSP.h line 7523), not the zop/zrop rule. Also `vDSP.FFT.init?(log2n:radix:ofType:)` is **failable**. | Added. |
| 14 | B.9 | Omission: TR 38.901 V19.5.0 Table 7.4.3-2 also has a **"Low-loss A" model**: `5 − 10log(0.3·10^{−L_glass/10} + 0.7·10^{−L_plywood/10})`, σ = 4.4 dB. Plywood `1.03 + 0.17f` is from that model. | Added. |
| 15 | A.6 | Clarification: Balanis prints D₂ = 5.387 (7.31 dB, I₂ = 3.598) for Example 14.1's patch. Precise integration of the same integral gives 5.437 (7.35 dBi, I₂ = 3.5638), which matches the doc. The book's array-factor form (14-56) gives 4.758 (6.77 dBi). | Keep 7.35 dBi as the oracle for the full integral, and say which form a test uses. |
| 16 | F.3 / G.4 | Uncertain: using the magnetometer to detect 50/60 Hz mains hum by aliasing assumes the sensor passes 50/60 Hz. The header documents no output data rate and no filter. | Mark it as an experiment, not a feature. |

Everything else checked out. Section E.6 (NR numerology), the FR2-2 RB counts (148 RB at 960 kHz / 2000 MHz confirmed in TS 38.104 Table 5.3.2-3), the NR band edges, NR-ARFCN, the EVM table, P.838-3, P.2109-2, the TR 38.901 path-loss and delay-spread tables, every Wi-Fi rate, BLE, UWB, NFC, GPS, the iPhone model numbers, and every vDSP signature are correct.

---

## Item-by-item verdicts

### 0. Constants and numerics

| Item | Doc value | Check | Verdict |
|---|---|---|---|
| c | 299 792 458 m/s exact | SI definition | correct |
| k_B | 1.380 649e-23 exact | SI 2019 | correct |
| Z₀ | 376.730 313 412 Ω (±5.9e-8) | CODATA 2022: 376.730 313 412(59) | correct |
| h | 6.626 070 15e-34 exact | SI 2019 | correct |
| T₀ | 290 K | IEEE/ITU convention | correct |
| 120π vs η₀ shift | about 0.07 % | 376.991/376.730 − 1 = 0.069 % (R) | correct |
| math.h `erfc` l.475, `j0/j1/jn` l.735–737 ios(3.2), `tgamma` | — | H (tgamma at l.486) | correct |
| No Ci/Si, Fresnel or inverse-normal in libm | — | H | correct |

### A. Antennas

| Item | Doc value | Independent result / source | Verdict |
|---|---|---|---|
| A.1 Hertzian R_r = (2π/3)η(Δl/λ)² = 80π²(Δl/λ)² | — | (2π/3)(120π) = 80π² (R) | correct |
| A.1 test Δl/λ = 0.01 | 0.078 957 / 0.078 902 Ω | 0.078 957 / 0.078 902 (R) | correct |
| A.1 D = 1.5 = 1.760 91 dBi; HPBW 90° | — | R | correct |
| A.2 short dipole 20π²(l/λ)²; 0.1λ → 1.973 92 Ω | — | 1.973 921 (R) | correct |
| A.3 far field, F(θ), Π, R_r = η𝓘/2π, R_in = R_r/sin²(kL/2), D = 2F_max/𝓘 | — | Balanis 4-58…4-70 form; consistent with table (R) | correct |
| A.3 **𝓘 = Cin(2π) = 2.437 653** | 2.437 653 | ∫cos²(π/2·cosθ)/sinθ dθ = **1.218 827 = Cin(2π)/2** (mpmath quad) | **corrected** |
| A.3 Cin(2π) | 2.437 653 | γ + ln 2π − Ci(2π) = 2.437 653 (R) | correct |
| A.3 table L/λ 0.10 | 0.191 / 1.999 / 1.5050 / 1.775 / 89.53 | 0.191 / 1.999 / 1.5050 / 1.775 / 89.528 (R) | correct |
| A.3 table 0.25 | 6.716 / 13.431 / 1.5318 / 1.852 / 87.04 | 6.716 / 13.431 / 1.5318 / 1.852 / 87.035 | correct |
| A.3 table 0.50 | 73.079 (73.130) / 1.6409 / 2.151 / 78.08 | 73.079 (73.130) / 1.6409 / 2.151 / 78.078 | correct |
| A.3 table 0.75 | 185.68 / 371.36 / 1.8821 / 2.746 / 64.01 | same | correct |
| A.3 table 1.00 | 198.95 / ∞ / 2.4110 / 3.822 / 47.84 | 198.95 / ∞ / 2.4110 / 3.822 / 47.835 | correct |
| A.3 table 1.25 | 106.46 / 212.93 / 3.2825 / 5.162 / 32.61 | same | correct |
| A.3 X_in ≈ +j42.5 Ω; resonant length 0.47–0.48λ | — | standard (Balanis) | correct |
| A.3 A_e = 0.13λ²; 1 GHz → 0.011 736 m² | — | D/4π = 0.1306; 0.011 736 (R) | correct |
| A.3 **"L > 1.5λ main lobe leaves broadside"** | 1.5λ | global max leaves 90° at **L ≈ 1.44λ**; at 1.5λ max at 137.44° (R) | **corrected** |
| A.4 monopole Z ≈ 36.5 + j21.25, D = 3.2818 = 5.161 dBi | — | 2 × 1.640 92 = 3.2818 → 5.1612 (R) | correct |
| A.5 loop R_r = (8/3)ηπ³(A/λ²)²N² = 31 171… = 20π²(C/λ)⁴N² | 320π⁴ = 31 170.9; η₀ 31 149.3 | 31 170.909 / 31 149.345 (R) | correct |
| A.5 D = 1.5; ferrite × μ_eff² | — | standard | correct |
| A.5 Test 1 a = 0.02λ | 0.049 223 Ω (η unlabeled) | 0.049 223 (120π) / **0.049 189 (η₀)** | **corrected** (label) |
| A.5 Test 2 NFC | 3.0e-6 Ω; λ/2π = 3.52 m | 3.006e-6; 3.5187 m (R) | correct |
| A.5 Test 3 ferrite | 8.57e-11 / 8.57e-7 Ω | 8.569e-11 / 8.569e-7 (R) | correct |
| A.6 W, ε_eff, ΔL, L formulas | — | Balanis 14-1…14-7 | correct |
| A.6 ε_r 2.2 row | 11.850 / 1.9715 / 0.8110 / 9.053 mm | 11.8503 / 1.9715 / 0.8110 / 9.0534 (R); Balanis 1.186 / 1.972 / 0.081 / 0.906 cm (S, GitHub reproduction) | correct |
| A.6 FR-4 row | 37.234 / 4.0809 / 0.7386 / 28.809 | 37.2343 / 4.0809 / 0.7386 / 28.8093 | correct |
| A.6 ε_r 20 row | 29.363 / 16.353 / 1.593 / 20.343 | 29.3630 / 16.3527 / 1.5929 / 20.3431 | correct |
| A.6 two-slot D (ε_r 2.2 / FR-4 / air / ε_r 20) | 7.35 / 6.09 / 9.34 / 5.10 dBi | 7.354 / 6.085 / 9.343 / 5.102 (400×800 Gauss–Legendre, R). Balanis prints 7.31 dB for row 1 (coarse I₂) [S] | correct (clarified) |
| A.6 single-slot check | — | I₁ = 1.8623, D₀ = 3.3123 = Balanis 1.863 / 3.312 [S] | correct |
| A.7 NBS TN 688 table (boom 0.4–4.2λ; 3/5/6/12/17/15 el.; 7.1…14.2 dBd) | — | element counts re-derived from Balanis Table 10.6 spacings (0.2 + n·S = boom: 0.2+1×0.2, 0.2+3×0.2, 0.2+4×0.25, 0.2+10×0.2, 0.2+15×0.2, 0.2+13×0.308); gains from memory of the same table; SDSMT PDF unreachable (ECONNRESET) | correct (S) |
| A.7 dBd offset 2.1509 dB | — | 10log₁₀ 1.640 92 = 2.1509 (R) | correct |
| A.7 "4.3 ≤ D ≤ 19 dBi, Z 15–70 Ω, BW ≤ 2 %" | — | source unreachable | uncertain |
| A.8 Kraus D = 12C²NS, 15 in 1st ed.; HPBW 52°/…; R = 140C; S&T 6.2 / 65° | — | Cebik Part 2 text (P) | correct |
| A.8 10.79 = 10log 12 | — | 10.7918 (R) | correct |
| A.8 Emerson G = 10.25 + 1.22L − 0.0726L², 2 ≤ L ≤ 7, "4 or 5 dB" | — | NRAO page (P) | correct |
| A.8 test (C = 1, N = 10, S = 0.25) | 30.000 / 14.771 / 32.888° / 140 / 1.050 / 15.5 / 11.90 / 41.11° / 12.846 | identical (R) | correct |
| A.8 AR = (2N+1)/2N | — | Kraus / Balanis 10-37 | correct (S) |
| A.9 horn ε_ap ≈ 0.51 (0.81 × 0.632) | — | 8/π² = 0.8106; product 0.512 | correct |
| A.9 test | 57.046 / 17.562 dBi | 57.0464 / 17.5623 (R) | correct |
| A.10 dish G, η_ap 0.65 | 3700.3 / 35.682 dBi | 3700.30 / 35.6824 (R) | correct |
| A.10 70λ/D test | 2.9146° | 2.91465° | correct |
| A.10 **uniform HPBW 58.4λ/D → 2.4316°** | 58.4 | (2J₁(u)/u)² = ½ → u = 1.616 340, HPBW = **58.957°λ/D**; exact 2·asin(…) = **2.4550°** (R) | **corrected** |
| A.11 AF, ψ, β steering, grating-lobe rules | — | standard; R | correct |
| A.11 HPBW approximation formula | — | 12.710° (R) | correct |
| A.11 tests N = 8, d = λ/2 | D 8.000 / 9.031; HPBW 12.80 (12.71); SLL −12.80; AF(45°) 0.071 61; β −90°, peak 60°, HPBW 14.84°; d < 0.6667λ | 8.000 / 9.0309; 12.8025 (12.710); −12.797; 0.071 607; −90.000°, 60.000°, 14.836°; 0.666 67 (R) | correct |
| A.12 planar: 23.06 / 11.02 dBi; λ/2 = 5.353 / 3.843 mm | — | 23.0618 / 11.0206; 5.3534 / 3.8435 (R) | correct |
| A.13 MathWorks PIFA 30×20×10 on 36×36, ~2.34 GHz | — | MathWorks page (P) | correct |
| A.13 phone efficiency 40–70 % | — | secondary range | uncertain (as flagged) |
| A.14 Friis, A_e, EIRP; test FSPL 60.231, P_r −40.231 dBm; EIRP 27 dBm | — | 60.2311 (R) | correct |
| A.15 PLF tests −3.0103 dB, RHCP/LHCP 0 | — | R | correct |
| A.16 mismatch table (4 rows) | as printed | 0.186 99 / 1.4600 / 14.564 / 0.1546; −0.156 07 / 1.3699 / 16.134 / 0.1071; 0.371 34 / 2.1814 / 8.605 / 0.6444; 0.333 33 / 2.0000 / 9.542 / 0.5115 (R) | correct |
| A.17 field regions; λ/2π 19.881 mm; 28.820 m; 1.823 m | — | 19.8806 / 28.8199 / 1.8231 (R) | correct |

### B. Propagation

| Item | Doc value | Independent result / source | Verdict |
|---|---|---|---|
| B.1 P.525-5 (11/2024) exists | — | ITU listing (P) | correct |
| B.1 constant 20log(4π/c) | −147.552 217 | −147.552 2168 (R) | correct |
| B.1 32.4 = 32.4478 | — | 32.447 78 (R) | correct |
| B.1 tests 92.4478 dB; GPS 182.503 dB | — | 92.4478 / 182.5027 (R) | correct |
| B.2 log-distance form, d₀ choices | — | Andersen 1995 (P) | correct |
| B.2 office hard partition 1500 MHz n 3.0 σ 7.0 | — | Andersen Table 2 (P) | correct |
| B.2 **factory LOS 1300 MHz n 1.6–2.0, σ 3.0–5.8** | 5.8 | Table 2: textile 2.0/3.0, metalworking 1.6/5.8, **paper/cereals 1.8/6.0** (P) | **corrected** (σ 3.0–6.0) |
| B.2 Rappaport Table 4.2 exponents | — | standard values | correct (S) |
| B.2 test 40.052 → 79.083 dB | — | 40.0520 / 79.0829 (R) | correct |
| B.3 InH LOS/NLOS, UMa NLOS opt, UMi NLOS opt formulas, σ 3 / 8.03 / 7.8 / 8.2 | — | TR 38.901 V19.5.0 (P; NLOS line text-extracted, others standard) | correct |
| B.3 tests 64.507 / 74.035 / 124.250 / 134.746 / 107.412 | — | 64.5073 / 74.0350 / 124.2505 / 134.7460 / 107.4115 (R) | correct |
| B.4 exact two-ray, d⁻⁴ asymptote, d_x = 4πh_th_r/λ | — | R | correct |
| B.4 **d_c = 4h_th_r/λ "last null"** | "last null" | Δφ = π at d_c → **last maximum** (scan: 540.2 m); last null at 268.5 m (R) | **corrected** |
| B.4 test d_x 1697.6, d_c 540.4; 1 km 88.012/86.936/91.533; 10 km 126.946/126.936/111.533 | — | 1697.63 / 540.37; 88.0119 / 86.9357 / 91.5326; 126.9463 / 126.9357 / 111.5326 (R) | correct |
| B.5 Hata urban, a(h_m) small/large, suburban, open, validity | — | standard Hata 1980 forms | correct |
| B.5 COST-231 form, C_m 0/3 | — | standard | correct |
| B.5 "Altair labels suburban correction rural" | — | not re-checked | uncertain (cosmetic) |
| B.5 tests a = 0.0159, 151.024, 151.041, 141.082, 122.518; COST 146.801 / 149.801 | — | 0.015 88 / 151.0244 / 151.0412 / 141.0818 / 122.5180 / 146.8007 / 149.8007 (R) | correct |
| B.6 P.526-16 (11/2025) exists | — | ITU listing (P) | correct |
| B.6 ν formula, J(ν) exact and approx (ν > −0.78) | — | standard P.526 §4.1; eq. numbers not re-checked | correct |
| B.6 tests J(0) 6.033 / 6.021; ν 1.095 82; J 14.530 / 14.476 | — | 6.0329 / 6.0206; 1.095 824; 14.5298 / 14.4762 (mpmath Fresnel, R) | correct |
| B.7 eq. (1) 0.1820 f(N″_O + N″_W); 44 + 35 lines | — | P.676-13 PDF (P) | correct |
| B.7 line tables in `p676_tables.json` | — | diffed against PDF Tables 1–2: 0 mismatches (P) | correct |
| B.7 author's code vs eqs. (3)–(9) | — | line strength, width, Zeeman/Doppler, δ, dry continuum match (P) | correct |
| B.7 table values (1…183.31 GHz), 14.91 dB/km at 60.8 GHz | 14.656 at 60 GHz | reproduced with p_tot = 1013.25; **14.778 if p_dry = 1013.25** | **uncertain → convention stated** |
| B.8 P.838-3 Table 5 rows 28 / 39 / 60 GHz | as printed | PDF lines (P) identical | correct |
| B.8 tests 4.624 / 7.031 / 10.117 / 9.045 dB/km | — | 4.6241 / 7.0310 / 10.1173 / 9.0448 (R) | correct |
| B.9 P.2109-2 equations (1)–(10) and Table 1 coefficients | — | PDF (P) | correct |
| B.9 P.2109 range 0.08–100 GHz | — | PDF (P) | correct |
| B.9 median tests (8 values) | — | identical to 3 dp (R, independent NormalDist inverse) | correct |
| B.9 38.901 materials incl. IRR glass 25.4 + 0.11f (Rel-19), plywood | — | TR 38.901 V19.5.0 Table 7.4.3-1 (P) | correct |
| B.9 low/high-loss PL_tw, PL_in = 0.5d, σ 4.4/6.5 | — | Table 7.4.3-2 (P) | correct; **"Low-loss A" model omitted → added** |
| B.9 O2I tests 12.698 / 27.499 / 17.829 / 35.029 | — | 12.6975 / 27.4993 / 17.8288 / 35.0290 (R) | correct |
| B.10 Rayleigh / Rician pdfs, K, P_r | — | standard | correct |
| B.10 outage tests 0.095 163 / 0.009 950 / 9.995e-4 | — | 0.095 1626 / 0.009 9502 / 9.9950e-4 (R) | correct |
| B.11 B_c,90 = 1/(50σ), B_c,50 = 1/(5σ) | — | Rappaport | correct |
| B.11 38.901 Table 7.7.3-1 (10/30/100/300/1000 ns) | — | (P) | correct |
| B.11 Table 7.7.3-2 (InH 39/20 ns, UMa 363/266, UMa long 1148) | — | (P) | correct |
| B.11 tests 200 kHz / 20 kHz / 551 kHz | — | 550.96 kHz (R) | correct |
| B.12 Doppler, Clarke spectrum, T_c rules | — | √(9/16π) = 0.4231 (R) | correct |
| B.12 tests 350.242 Hz, 1.2077 ms, 0.5112 ms, 185.313 Hz | — | 350.2423 / 1.20774 / 0.511 216 / 185.3134 (R) | correct |

### C. Noise and capacity

| Item | Doc value | Independent result / source | Verdict |
|---|---|---|---|
| C.1 −173.975 dBm/Hz (290 K), −173.828 (300 K), k = −228.6 dBW/K/Hz | — | −173.9752 / −173.8280 / −228.5992 (R) | correct |
| C.1 tests −93.965 / −113.975 / −94.422 dBm | — | −93.9649 / −113.9752 / −94.4225 (R) | correct |
| C.2 Friis cascade 1.348 93 = 1.300 dB; T_e 75.09 K | — | 1.348 925 / 1.299 88 / 75.088 (R) | correct |
| C.3 GPS C/N₀ 43.48 dB-Hz | 43.48, "0 dBi antenna" | 43.475; the −128.5 dBm is already at a 3 dBi linear antenna output | **corrected** (wording) |
| C.4 Shannon tests 133.164 / 996.723 / 1.000 Mb/s; ln2 = −1.592 dB | — | 133.1642 / 996.7226 / 1.0000 / −1.5917 (R) | correct |
| C.4 MIMO 6.658 / 11.345 / 18.802 / 10.581 b/s/Hz | — | 6.6582 / 11.3449 / 18.8018 / 10.5814 (R) | correct |
| C.5 Eb/N0, Es/N0 relations | — | standard | correct |
| C.6 Q(x), BPSK, M-QAM α/β, M-PSK forms | — | Goldsmith ch. 6 | correct |
| C.6 BPSK tests 7.864 960e-2 / 9.994e-4 / 9.953e-6 / 3.872 108e-6; 10⁻⁵ at 9.5879 dB | — | 7.864 960e-2 / 9.9943e-4 / 9.9530e-6 / 3.872 108e-6 / 9.587 86 (R) | correct |
| C.6 16-QAM 7.0166e-3 (exact 7.0043e-3); 64-QAM 1.2924e-2; 256-QAM 2.7777e-2; 8-PSK 2.3395e-3 | — | 7.016 60e-3 (7.004 29e-3) / 1.292 40e-2 / 2.777 68e-2 / 2.339 45e-3 (R) | correct |
| C.7 EVM definition; TS 38.104 Table 6.5.2.2-1 incl. 1024QAM 2.5 % (≤ 4.2 GHz) / 2.8 % (> 4.2 GHz) | — | TS 38.104 V19.6.0 PDF (P) | correct |
| C.7 802.11ax −35 dB; 802.11be −38 dB | — | NI (S) / not opened | correct / uncertain (S) |
| C.7 tests −29.119 / −32.041 dB; 1.7783 % / 1.2589 % | — | R | correct |

### D. Modulation

| Item | Doc value | Independent result / source | Verdict |
|---|---|---|---|
| D.1 AM spectrum, P_t/P_c, efficiency tests | 1.5 / 33.33 %; 1.125 / 11.11 % | R | correct |
| D.2 FM Bessel expansion, Carson's rule, ±75 kHz = 100 % | — | standard; 47 CFR 73.310 | correct |
| D.2 J values β = 1, carrier null 2.404 826, β = 5 values | as printed | 0.765 198 / 0.440 051 / 0.114 903 / 0.019 563; J₀(2.404 826) ≈ −2e-7; −0.177 597 / −0.327 579 / 0.391 232 (mpmath) | correct |
| D.2 β = 5, B_T 180 kHz, 99.36 % within ±6 | — | 0.993 559 (R) | correct |
| D.2 AMPS 2(12 + 3) = 30 kHz | — | R; ±12 kHz [S] | correct |
| D.3 PM | — | standard | correct |
| D.4 h = 2Δf/R_b; BR h 0.28–0.35, BT 0.5, Δf 140–175 kHz; LE h 0.45–0.55; LE rates; sensitivity −70/−75/−82 dBm; EDR π/4-DQPSK/8DPSK | — | Core 5.4 values as known; arithmetic R | correct |
| D.5 GSM 1625/6 ksym/s, T 3.692 31 µs, B 81.25 kHz, δ 0.441 684; EDGE 812.5 kb/s | — | 3.692 308 / 81 250 / 0.441 684 / 812.5 (R) | correct |
| D.6 38.211 QPSK and 16QAM mapping; normalizations √10/42/170/682/2730; test points | — | √(2(M−1)/3) (R) | correct |
| D.7 processing gains 43.11 / 21.07 / 10.41 / 24.08 dB | — | 43.1091 / 21.0721 / 10.4139 / 24.0824 (R) | correct |
| D.8 BR f = 2402 + k, k 0–78; 1600 / 3200 hops/s; 625 µs | — | R | correct |
| D.9 802.11a 312.5 kHz, 3.2 µs, 54 Mb/s; 11ax 78.125 kHz, 12.8 µs, GI 0.8/1.6/3.2 | — | R | correct |
| D.9 LTE T_u 66.667 µs, CP 160/144/512 T_s, slot check 15 360 T_s | — | 5.2083 / 4.6875 / 16.667 µs; 500.000 µs (R) | correct |
| D.10 RB 12 sc / 180 kHz; 10log N: 18.06 / 24.08 dB | — | R | correct |

### E. Generations and systems

| Item | Doc value | Independent result / source | Verdict |
|---|---|---|---|
| E.1 AMPS 824–849 / 869–894, 30 kHz, ±12 kHz, 832 ch | — | standard (S) | correct |
| E.1 GSM P-GSM, F_l(n) = 890 + 0.2n, DCS, PCS, slot 576.9 µs = 156.25 sym, frame 4.615 ms | — | 576.923 µs / 156.25 / 4.6154 ms (R) | correct |
| E.1 IS-95 1.2288 Mcps / 1.25 MHz; EDGE; WCDMA 3.84 Mcps | — | standard | correct |
| E.1 HSDPA Rel-5 / HSPA+ 64QAM Rel-7 / DC-HSDPA Rel-8 | — | standard | correct |
| E.1 LTE T_s 32.552 ns; 6/15/25/50/75/100 RB; 256QAM / 1024QAM DL | — | R; standard | correct |
| E.1 6G: M.2160 (2023); WRC-27 AI 1.7 bands 4.4–4.8 / 7.125–8.4 / 14.8–15.35 GHz | — | standard (S) | correct |
| E.2 Wi-Fi rates 11 / 54 / 54 / 600 / 6933 / 9607.8 / 23 058.8 Mb/s | — | 600.0 / 6933.3 / 9607.84 / 23 058.82 (R) | correct |
| E.2 data-subcarrier counts 48 / 108 / 468 / 234 / 980 / 1960 / 3920 | — | each reproduces published rate (R) | correct (S) |
| E.2 Wi-Fi 7 = 8 SS (not 16) | — | multiple secondary sources | correct (S) |
| E.2 "MLO mandatory" | — | mandatory for **Wi-Fi CERTIFIED 7**; 320 MHz and 4K-QAM optional for certification [S] | **corrected** (clarified) |
| E.2 HE 143.382 / 600.490 / 2401.961 Mb/s | — | R | correct |
| E.2 iPhone 15 Pro Max 160 MHz "if enabled" | — | Apple: 160 MHz at 5 and 6 GHz, **2400 Mbps**, 2×2; 2.4 GHz 20 MHz, 229 Mbps (P) | **corrected** (clarified) |
| E.2 6 GHz US 5925–7125, EU 5945–6425 MHz | — | standard (S) | correct |
| E.3 BLE 40 ch, 37/38/39 = 2402/2426/2480; index mapping tests | — | R | correct |
| E.4 UWB ch5 6489.6, ch9 7987.2, BW 499.2; 3.3356 ns/m; 0.300 m | — | 6489.6 / 7987.2 / 3.335 64 / 0.300 27 (R) | correct |
| E.4 NFC 105.9375 kb/s, ETU 9.4395 µs, 847.5 kHz, Type A/B | — | R; ISO 14443-2 | correct |
| E.4 GPS f₀, L1/L2/L5, C/A, LNAV, −158.5 dBW at 3 dBi linear ≥ 5° | — | 1575.42 / 1227.6 / 1176.45 (R); IS-GPS-200 | correct |
| E.4 L5 I5/Q5 QPSK, 10.23 Mcps, −157.9 (IIF) / −157.0 (III) dBW | — | IS-GPS-705 (search abstract, P/S) | correct |
| E.4 Qi 87–205 kHz; Qi2 MPP 360 kHz | — | (S) | correct (S) |
| E.4 AM US 535–1705, 540–1700 / 10 kHz = 117 ch; R1/R3 526.5–1606.5 / 9 kHz | — | R | correct |
| E.4 FM 88–108, ch 201–300 (88.1–107.9); ITU 87.5–108 | — | R | correct |
| E.4 DAB mode I 1536 × 1 kHz, T_u 1 ms, guard 246 µs; Band III 174–240 | — | ETSI EN 300 401 values | correct (S) |
| E.4 TV bands / widths | — | standard | correct |
| E.5 Globalstar 1610–1618.725 / 2483.5–2500 MHz | — | (S); n53 = 2483.5–2495 MHz per TS 38.104 (P) | correct (S) |
| E.6 numerology µ 0–6, extended CP only µ = 2 | — | TS 38.211 | correct |
| E.6 T_c 0.508 63 ns, κ = 64, N_u, N_CP rules | — | 0.508 626 ns / 64 (R) | correct |
| E.6 T_u / CP / slot table (µ 0, 1, 3, 6) | — | 66.6667 / 4687.50; 33.3333 / 2343.75; 8.3333 / 585.94; 1.0417 / 73.24 ns / 15.625 µs (R) | correct |
| E.6 FR1 410–7125, FR2-1 24 250–52 600, FR2-2 52 600–71 000 MHz | — | TS 38.104 Table 5.1-1 (P) | correct |
| E.6 273 RB @30 kHz / 135 @60 kHz (100 MHz); 264 @120 kHz (400 MHz); **148 @960 kHz (2000 MHz)** | — | TS 38.104 Tables 5.3.2-2/-3 (P) | correct |
| E.6 guard band 845 kHz | — | R | correct |
| E.6 bands n41, n77, n78, n79, n257, n258, n260, n261, n71 | — | TS 38.104 Tables 5.2-1/-2 (P) | correct |
| E.6 NR-ARFCN table and 633 333 → 3499.995 MHz | — | TS 38.104 Table 5.4.2.1-1 (P); R | correct |
| E.6 1024QAM in 38.211 §5.1.7; PC3 23 dBm / PC2 26 dBm | — | standard | correct |

### F. iPhone 15 Pro Max

| Item | Doc value | Independent result / source | Verdict |
|---|---|---|---|
| F.1 model numbers / regions A2849, A3105, A3106, A3108 | — | Apple support 108044 (P) | correct |
| F.1 A2849 5G, mmWave, LTE lists | — | Apple 111828 (P): FDD 1–5, 7–8, 12–14, 17–20, 25–26, 28–30, 32, 66, 71; TD 34, 38–42, 46, 48, 53 | correct |
| F.1 A3105 no mmWave, LTE + 11, 21 | — | TechWalls (S) | correct (S) |
| F.1 A3106 5G incl. **n75, n76** | listed | EveryMac and TechWalls (launch copies) omit n75/n76 for A3106; Apple's current page includes them for A2849 | **uncertain** |
| F.1 A3108 = A3106 − n53 | — | TechWalls (S) | correct (S) |
| F.1 page lists "A2848 / A2849" | — | Apple 111828 (P) | correct |
| F.1 UMTS string | "850/900/1700/2100/1900/2100" | Apple: "850, 900, 1700/2100, 1900, 2100 MHz" | **corrected** |
| F.1 Wi-Fi 6E 2×2, BT 5.3, UWB gen 2, Thread, NFC reader mode | — | Apple 111828 (P) | correct |
| F.1 dual-frequency GPS + GNSS list; sensors; MagSafe/Qi2 15 W | — | Apple 111828 (P) | correct |
| F.1 size 76.7 × 159.9 × 8.25 mm, 221 g | — | Apple 111828 (P) | correct |
| F.1 Qualcomm X70 | — | (S) | correct (S) |
| F.2 four isolated frame sections; mmWave window | — | (S), not re-checked | uncertain (as flagged) |
| F.3 CTRadioAccessTechnologyNR / NRNSA ios(14.1), LTE ios(7.0) | — | H | correct |
| F.3 **fetchCurrent requirements** | all listed | **any one of 4** + entitlement (H) | **corrected** |
| F.3 signalStrength 0–1 in HotspotHelper category | — | H (ios 9.0) | correct |
| F.3 CoreBluetooth RSSI delegate; NINearbyObject distance / direction / horizontalAngle ios(16) | — | H | correct |
| F.3 CMMagnetometerData.magneticField | — | H ("total field incl. device bias") | correct |
| F.3 mains hum via aliasing | — | no documented ODR/anti-alias filter | **uncertain** |

### G. Fourier and vDSP

| Item | Doc value | Independent result / source | Verdict |
|---|---|---|---|
| G.1 DFT conventions, Parseval, amplitude recovery | — | R | correct |
| G.1 tests 11.718 75 Hz, 85.333 ms, 46.875 Hz, bin 100 = 4687.5 Hz, \|X\| 512/256, Parseval 512 | — | R (numpy FFT) | correct |
| G.2 periodic Hann; CG 0.5; ENBW 1.5; scallop 1.4236 / 3.9224 dB; SLL −31.47 / −13.26 dB; 3 dB BW 1.44 bins | — | 0.5 / 1.5 / 1.423 62 / 3.922 39 / −31.467 / −13.261 / 1.441 (R) | correct |
| G.2 **leakage test "3.90 dB rect"** | 3.90 | 3.9224 analytic; real cosine 3.90–3.94 by phase (R) | **corrected** |
| G.3 aliasing tests | — | R | correct |
| G.4 `vDSP.DiscreteFourierTransform` inits (iOS 15 / iOS 26), methods, error cases | — | swiftinterface l.3591–3626 (H) | correct |
| G.4 `vDSP.DFT` deprecated | — | l.4794–4799 (H) | correct |
| G.4 count/2 rule for complexReal | — | swiftdoc (H) | correct |
| G.4 DSPComplex variant API and length rule | not stated | `transform(input:)`; interleaved setup f·2ⁿ, f ∈ {2,3,5,9,15,25}, n ≥ 2 (H) | **corrected** (added) |
| G.4 `vDSP.FFT(log2n:radix:ofType:)` | non-failable implied | `init?` failable (H l.9997) | **corrected** (added) |
| G.4 window, formWindow, squareMagnitudes, absolute, convert(power/amplitude:toDecibels:), convert(interleavedComplexVector:) | — | H | correct |
| G.4 vDSP_hann_window flags 0/1/2, W = 0.5 / 0.816 496 580 927 726, half length (N+1)/2, periodic | — | vDSP.h l.326–328, 4014–4025 (H); mean square 1.000 (R) | correct |
| G.4 zop lengths 2ⁿ or f·2ⁿ (f 3/5/15, n ≥ 3); zrop n ≥ 4 | — | vDSP.h l.6973, 7077 (H) | correct |
| G.4 zrop C = 2 forward / 1 inverse; Ir even / Ii odd; Or[0] DC, Oi[0] Nyquist | — | vDSP.h l.7103–7125 (H) | correct |
| G.4 test \|H\| 1024 / 512 | — | 2× numpy (R) | correct |

### H. Coupling chain

| Item | Doc value | Check | Verdict |
|---|---|---|---|
| Photon energy at 2.4 GHz | 1.5903e-24 J = 9.926 µeV | 1.590 26e-24 J / 9.9256 µeV (R) | correct |

---

## Verified reference

Implementers should use this section, not the original. Each value has been recomputed or confirmed. η₀ = 376.730 313 412 Ω unless "(120π)" is written. Tolerances: closed form 1e-9 relative; numerical integration ±1e-3 relative or ±0.01 dB; values from standards tables ± the last printed digit.

### Constants

c = 299 792 458 m/s · k_B = 1.380 649e-23 J/K · h = 6.626 070 15e-34 J·s · η₀ = 376.730 313 412 Ω · T₀ = 290 K · FSPL constant `20log₁₀(4π/c)` = **−147.552 2168 dB** (d in m, f in Hz) · kT₀ = **−173.975 19 dBm/Hz**.

### Antennas

- **Hertzian dipole:** `R_r = (2π/3)η(Δl/λ)²`. Δl/λ = 0.01 gives 0.078 902 Ω (η₀) or 0.078 957 Ω (120π). D = 1.5 = 1.760 91 dBi, HPBW 90°.
- **Short dipole (triangular current):** `R_r = 20π²(l/λ)²`. l = 0.1λ gives 1.973 92 Ω.
- **Thin dipole of length L:**
  - Radiation integral: `𝓘 = ∫₀^π [cos(πL cosθ) − cos(πL)]²/sinθ dθ`.
  - `R_r(I_max) = η𝓘/(2π)`, `R_in = R_r/sin²(πL)`, `D = 2F_max/𝓘`.
  - **Half-wave:** 𝓘 = Cin(2π)/2 = **1.218 827**, Cin(2π) = 2.437 653. R_r = 73.079 Ω (73.130 Ω with 120π), D = 1.6409 (2.151 dBi), HPBW 78.08°, X_in ≈ +j42.5 Ω.
  - Other test lengths:

| L/λ | R_r (Ω) | R_in (Ω) | D | D (dBi) | HPBW |
|---|---|---|---|---|---|
| 0.10 | 0.191 | 1.999 | 1.5050 | 1.775 | 89.53° |
| 0.25 | 6.716 | 13.431 | 1.5318 | 1.852 | 87.04° |
| 0.75 | 185.68 | 371.36 | 1.8821 | 2.746 | 64.01° |
| 1.00 | 198.95 | ∞ | 2.4110 | 3.822 | 47.84° |
| 1.25 | 106.46 | 212.93 | 3.2825 | 5.162 | 32.61° |
| 1.50 | 105.42 | 105.42 | 2.2263 | 3.476 | max at θ = 42.56° / 137.44° |

  - The global maximum leaves broadside at **L ≈ 1.44λ**. Search for F_max numerically.
- **λ/4 monopole on an infinite PEC ground:** R = 36.540 Ω, Z ≈ 36.5 + j21.25 Ω, D = 3.2818 = **5.161 dBi**.
- **Small loop:**
  - `R_r = (8/3)ηπ³(A/λ²)²N²`. The constant is 31 149.3 (η₀) or 31 170.9 (120π), and the 120π form equals `20π²(C/λ)⁴N²`. D = 1.5.
  - a = 0.02λ gives 0.049 189 Ω (η₀) or 0.049 223 Ω (120π).
  - NFC 40 × 30 mm loop, N = 4, 13.56 MHz: 3.006e-6 Ω. The reactive near-field boundary λ/2π is 3.519 m.
  - Ferrite rod: R_r × μ_eff².
- **Rectangular patch:**
  - `W = c/(2f)·√(2/(ε_r+1))`.
  - `ε_eff = (ε_r+1)/2 + (ε_r−1)/2·(1+12h/W)^(−½)`.
  - `ΔL = 0.412h(ε_eff+0.3)(W/h+0.264)/[(ε_eff−0.258)(W/h+0.8)]`.
  - `L = c/(2f√ε_eff) − 2ΔL`.
  - Test rows (W / ε_eff / ΔL / L in mm):
    - ε_r 2.2, h 1.588 mm, 10 GHz: 11.8503 / 1.9715 / 0.8110 / 9.0534.
    - FR-4, h 1.6 mm, 2.45 GHz: 37.2343 / 4.0809 / 0.7386 / 28.8093.
    - ε_r 20, h 4 mm, 1575.42 MHz: 29.3630 / 16.3527 / 1.5929 / 20.3431.
  - Two-slot full-integral directivity with L_e = L + 2ΔL: 7.354 / 6.085 / 5.102 dBi for the three rows, and 9.343 dBi for air (h 3 mm, 5.8 GHz).
  - Single slot (ε_r 2.2): I₁ = 1.8623, D₀ = 3.3123. Balanis prints 7.31 dB for the two-slot value because of coarse integration. His array-factor form (14-56) gives 6.77 dBi. Say which form a test uses.
- **Yagi (NBS TN 688; Balanis Table 10.6):** boom 0.4 / 0.8 / 1.2 / 2.2 / 3.2 / 4.2 λ with 3 / 5 / 6 / 12 / 17 / 15 elements gives 7.1 / 9.2 / 10.2 / 12.25 / 13.4 / 14.2 dBd. dBi = dBd + 2.1509.
- **Axial helix:**
  - Kraus: `D = 12C²NS`, HPBW `52°/(C√(NS))`, `R = 140C Ω`, AR `(2N+1)/(2N)`. All C and S in λ.
  - Stutzman–Thiele: `6.2C²NS`, `65°/(…)`.
  - Emerson realistic curve: `G = 10.25 + 1.22L − 0.0726L²` dBi, valid for 2 ≤ L ≤ 7 λ.
  - Test (C 1, N 10, S 0.25): D 30 (14.771 dBi), HPBW 32.888°, S&T 15.5 (11.903 dBi, 41.110°), Emerson 12.846 dBi.
- **Horn:** `G = ε_ap·4πAB/λ²` with ε_ap = 0.51 (optimum). 0.10 × 0.08 m at 10 GHz gives 57.046 (17.562 dBi).
- **Dish:** `G = η(πD/λ)²`. D = 0.6 m, 12 GHz, η = 0.65 gives 3700.30 (35.682 dBi).
  - HPBW for a uniform aperture: **58.96° λ/D** (1.0290 λ/D rad). For the test dish that is **2.4550°**.
  - HPBW for a typical tapered feed: ≈ 70° λ/D, which is 2.9146° for the test dish.
- **ULA, N = 8, d = λ/2:** D = 8 (9.031 dBi); HPBW 12.80° exact (12.71° approximation); first sidelobe −12.80 dB; AF_n(45°) = 0.071 61. Steering to 60° gives β = −90°, peak at 60.000°, HPBW 14.84°. Grating-free condition: `d < λ/(1+|cosθ₀|)` (0.6667λ at 60°).
- **Planar arrays:** `G ≈ G_el + 10log(N_xN_y)`. 8 × 8 of 5 dBi gives 23.06 dBi. λ/2 is 5.3534 mm at 28 GHz and 3.8435 mm at 39 GHz.
- **Friis:** 20 dBm, 0 dBi / 0 dBi, 2.45 GHz, 10 m gives FSPL 60.2311 dB and P_r −40.2311 dBm. `A_e = Gλ²/4π`; for a λ/2 dipole at 1 GHz that is 0.011 736 m².
- **Mismatch on Z₀ = 50 Ω:**
  - 73 Ω: Γ 0.186 99, VSWR 1.4600, RL 14.564 dB, ML 0.1546 dB.
  - 36.5 Ω: Γ −0.156 07, VSWR 1.3699, RL 16.134 dB, ML 0.1071 dB.
  - 73 + j42.5 Ω: |Γ| 0.371 34, VSWR 2.1814, RL 8.605 dB, ML 0.6444 dB.
  - 100 Ω: Γ 0.333 33, VSWR 2.0000, RL 9.542 dB, ML 0.5115 dB.
- **PLF:** linear-to-linear at 45° and linear-to-circular are both −3.0103 dB. RHCP to LHCP is 0, so clamp the display.
- **Field regions:** reactive near field `0.62√(D³/λ)`, far field `2D²/λ`, small antennas `λ/2π`. Tests: 19.8806 mm at 2.4 GHz; for the 0.6 m dish at 12 GHz, 28.820 m and 1.823 m.

### Propagation

- **FSPL:** `20log d + 20log f − 147.552 2168`. 1 km at 1 GHz is 92.4478 dB. GPS at 20 200 km, L1 is 182.5027 dB.
- **Log-distance:** 2.4 GHz, d₀ = 1 m (40.0520 dB), n = 3, 20 m gives 79.0829 dB.
  - Andersen measurements: office with hard partitions, 1500 MHz: n 3.0, σ 7.0 dB.
  - Factory LOS, 1300 MHz: n 1.6–2.0, **σ 3.0–6.0 dB**.
- **TR 38.901 V19.5.0:**
  - InH LOS: `32.4 + 17.3log d + 20log f`, σ 3 dB.
  - InH NLOS: `max(LOS, 38.3log d + 17.30 + 24.9log f)`, σ 8.03 dB.
  - UMa NLOS (optional): `32.4 + 20log f + 30log d`, σ 7.8 dB.
  - UMi NLOS (optional): `… + 31.9log d`, σ 8.2 dB.
  - Tests: 64.5073 / 74.0350 / 124.2505 / 134.7460 dB.
- **Two-ray (h_t 30 m, h_r 1.5 m, 900 MHz, Γ = −1):**
  - Asymptote crossover `d_x = 4πh_th_r/λ` = 1697.63 m.
  - **Last interference maximum** `d_c = 4h_th_r/λ` = 540.37 m (Goldsmith's critical distance).
  - Last null 268.5 m (≈ 2h_th_r/λ = 270.2 m).
  - At 1 km: exact 88.0119 dB, asymptote 86.9357 dB, FSPL 91.5326 dB. At 10 km: 126.9463 / 126.9357 / 111.5326 dB.
- **Hata (f 900 MHz, h_b 30 m, h_m 1.5 m, d 5 km):** a = 0.015 88; urban 151.0244 dB; large city 151.0412; suburban 141.0818; open 122.5180.
  - COST-231 (1800 MHz, 2 km): 146.8007 dB (C_m 0) or 149.8007 dB (C_m 3).
- **Knife edge (P.526-16):** J(0) is 6.0329 dB (approximation) and 6.0206 dB (exact). h 10 m, d₁ = d₂ = 1 km, 900 MHz gives ν = 1.095 824, J 14.5298 dB (approximation) and 14.4762 dB (exact).
- **Gas absorption (P.676-13 Annex 1):** `p676_tables.json` is verified. **State the pressure convention.**
  - With 1013.25 hPa as total pressure (dry 1003.28 hPa, e 9.97 hPa), 15 °C, 7.5 g/m³: 60 GHz gives 14.656 dB/km and 22.235 GHz gives 0.1933 dB/km. The oxygen peak is 14.906 dB/km at 60.806 GHz.
  - With 1013.25 hPa as dry pressure: 60 GHz gives 14.778 dB/km.
  - Use ±0.05 dB/km only within one convention.
- **Rain (P.838-3):** `γ = kR^α`. Rows (k_H, α_H, k_V, α_V):
  - 28 GHz: 0.2051, 0.9679, 0.1964, 0.9277.
  - 39 GHz: 0.4215, 0.8743, 0.4058, 0.8486.
  - 60 GHz: 0.8606, 0.7656, 0.8515, 0.7486.
  - H-pol at 25 mm/h: 4.6241, 7.0310 and 10.1173 dB/km for 28, 39 and 60 GHz. 28 GHz at 50 mm/h is 9.0448 dB/km.
- **Building entry (P.2109-2):** equations and coefficients as in rf-physics.md B.9.
  - Medians, traditional: 14.102 / 15.721 / 20.182 / 22.363 dB at 0.7 / 3.5 / 28 / 60 GHz.
  - Medians, thermally efficient: 31.576 / 30.886 / 41.676 / 49.676 dB.
- **38.901 O2I:**
  - Materials (f in GHz): glass `2 + 0.2f`, IRR glass `25.4 + 0.11f` (Rel-19), concrete `5 + 4f`, plywood `1.03 + 0.17f`, wood `4.85 + 0.12f`.
  - Wall models: low-loss (glass/concrete 0.3/0.7, σ 4.4 dB), high-loss (IRR/concrete 0.7/0.3, σ 6.5 dB), and **low-loss A** (glass/plywood 0.3/0.7, σ 4.4 dB). Add `PL_in = 0.5d_2D-in`.
  - Tests: 3.5 GHz gives 12.6975 dB (low) and 27.4993 dB (high). 28 GHz gives 17.8288 and 35.0290 dB.
- **Fading and dispersion:**
  - Rayleigh outage at −10 / −20 / −30 dB below the mean: 0.095 1626 / 0.009 9502 / 9.9950e-4.
  - Coherence bandwidth: `B_c,50 = 1/(5σ_τ)`, `B_c,90 = 1/(50σ_τ)`.
  - Doppler: 30 m/s at 3.5 GHz gives f_m = 350.2423 Hz, T_c(0.423) = 1.2077 ms and T_c(9/16π) = 0.5112 ms.

### Noise, capacity, modulation

- **Noise floor:**
  - 20 MHz, NF 7 dB: −93.9649 dBm. 1 MHz, NF 0: −113.9752 dBm.
  - Cascade LNA (1 dB, 20 dB) + mixer (10 dB): 1.2999 dB.
  - GPS C/N₀ at −128.5 dBm (already at a 3 dBi linear antenna) with NF 2 dB: 43.475 dB-Hz.
- **Capacity:**
  - Shannon: 20 MHz at 20 dB gives 133.1642 Mb/s. Minimum Eb/N₀ is −1.5917 dB.
  - MIMO at 20 dB: 6.6582 / 11.3449 / 18.8018 / 10.5814 b/s/Hz.
- **Error rates:**
  - BPSK at 0 dB: 7.864 960e-2. P_b = 10⁻⁵ needs 9.587 86 dB.
  - 16-QAM at Eb/N₀ 10 dB: 7.016 60e-3 (approximation), 7.004 29e-3 (exact).
  - 64-QAM at 14 dB: 1.292 40e-2. 256-QAM at 18 dB: 2.777 68e-2. 8-PSK at Es/N₀ 15 dB: 2.339 45e-3.
- **EVM (TS 38.104 V19.6.0):** QPSK 17.5 %, 16QAM 12.5 %, 64QAM 8 %, 256QAM 3.5 %, 1024QAM 2.5 % (≤ 4.2 GHz) or 2.8 % (> 4.2 GHz).
- **FM and AM:** J₀(1) = 0.765 198; J₀ = 0 at 2.404 826; J₄(5) = 0.391 232. β = 5 puts 99.356 % of the power within ±6 sidebands. Carson: 180 kHz for broadcast FM. AM with m = 1 gives P_t/P_c = 1.5.
- **GSM:** 1625/6 ksym/s, BT 0.3, δ = 0.441 684. EDGE: 812.5 kb/s gross.
- **Bluetooth:**
  - BR: h 0.28–0.35. LE: h 0.45–0.55. Both BT 0.5.
  - LE advertising channels 2402 / 2426 / 2480 MHz. LE data channel index i maps to `2404 + 2i` (i ≤ 10) or `2428 + 2(i−11)`.
- **Processing gain:** GPS C/A 43.1091 dB; IS-95 21.0721 dB; Barker-11 10.4139 dB.

### Systems

- **NR:**
  - SCS `15·2^µ` kHz. `T_c = 1/(480 000·4096)` s = 0.508 626 ns, κ = 64.
  - Normal CP: µ = 0 gives 4687.5 ns and µ = 6 gives 73.242 ns.
  - FR1 is 410–7125 MHz, FR2-1 is 24 250–52 600 MHz, FR2-2 is 52 600–71 000 MHz.
  - Maximum transmission bandwidth: 273 RB (100 MHz at 30 kHz); 264 RB (400 MHz at 120 kHz); 148 RB (2000 MHz at 960 kHz).
  - Guard band for 100 MHz at 30 kHz: 845 kHz.
  - NR-ARFCN 633 333 maps to 3499.995 MHz.
- **LTE:** T_s = 32.552 ns. CP is 160 or 144 T_s (normal) and 512 T_s (extended).
- **Wi-Fi:**
  - Subcarrier spacing: 312.5 kHz (a/g/n/ac), 78.125 kHz (ax/be).
  - Headline rates: 54 / 600 / 6933.3 / 9607.84 / 23 058.82 Mb/s.
  - Wi-Fi 7 is limited to 8 spatial streams. MLO is mandatory for WFA certification; 320 MHz and 4K-QAM are optional.
  - iPhone 15 Pro Max: 802.11ax 2×2, 160 MHz at 5 and 6 GHz, Apple-listed 2400 Mbps (2401.96 computed); 20 MHz at 2.4 GHz (229 Mbps).
- **UWB:** channel 5 is 6489.6 MHz and channel 9 is 7987.2 MHz, each 499.2 MHz wide.
- **NFC:** 105.9375 kb/s, subcarrier 847.5 kHz.
- **GPS:** L1 1575.42 MHz, L2 1227.6 MHz, L5 1176.45 MHz. Minimum received power: L1 C/A −158.5 dBW; L5 −157.9 dBW (IIF) or −157.0 dBW (III) per component.
- **iPhone 15 Pro Max model numbers:** A2849 (US, with mmWave n258/n260/n261), A3105, A3106, A3108 (none with mmWave). Per-model bands are as in rf-physics.md F.1, but A3106 n75/n76 is unconfirmed.

### Fourier and vDSP

- **DFT and windows:**
  - A unit cosine at bin 100, N = 1024, gives |X| = 512 (rectangular) or 256 (Hann); vDSP zrop returns 2× those.
  - Hann (periodic): CG 0.5, ENBW 1.5 bins, scalloping loss 1.4236 dB, highest sidelobe −31.467 dB, 3 dB bandwidth 1.44 bins.
  - Rectangular: scalloping loss 3.9224 dB for a complex exponential. For a real cosine use ±0.04 dB.
- **vDSP API:**
  - `vDSP.DiscreteFourierTransform`, iOS 15+, `init(previous:count:direction:transformType:ofType:) throws`.
  - Float and Double use `transform(real:imaginary:)`; DSPComplex uses `transform(input:)`.
  - Allowed lengths:
    - Split complex: 2ⁿ or f·2ⁿ, f ∈ {3, 5, 15}, n ≥ 3 (complex) or n ≥ 4 (real).
    - Interleaved: f·2ⁿ, f ∈ {2, 3, 5, 9, 15, 25}, n ≥ 2.
  - `vDSP.FFT` has a failable `init?`.
  - Real forward DFT scaling is C = 2, and the Nyquist bin is in Oi[0].
  - `vDSP_HANN_NORM` uses W = √(2/3).
