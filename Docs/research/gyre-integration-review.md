# Review of `gyre-integration.md`

Adversarial physics and engineering review, 3 October 2026. Every correction has been made in place in `gyre-integration.md` and is marked **[corrected in review]**. Superseded test oracles are struck through or labelled "superseded".

## How each claim was checked

- **Numbers.**
  - Re-ran `rf-physics-calc/e_gyre.py`; it reproduces the doc's figures.
  - Recomputed every figure independently in Python: Larmor, cyclotron, Rabi, Bloch/FID, polarization, ULA, aliasing, P.453, horizon, ZHD, Sellmeier, thin film, Boris, collisions, radiation pressure.
  - Cross-checked against primary sources:
    - CODATA 2022 (NIST `allascii.txt`, downloaded this session);
    - ITU-R P.453-14 PDF (downloaded, eqs. 1, 2, 6–9 and coefficients read);
    - an IGRF-14 spherical-harmonic synthesis from the IAGA coefficient file;
    - the NOAA geomagnetism FAQ.
- **Gyre physics.**
  - Compiled `Gyre/Physics/{MathUtil,GyroSim}.swift` **verbatim** with small harnesses (`xcrun swiftc -O`).
  - Ran Gyre's own `physcheck`: 8/8 pass, with Larmor −0.2652 vs −0.2653 rad/s.
  - With the harnesses, ran the proposed rotor-resonance experiment, the nutation-frequency oracle and the axle-tip IQ spectrum.
- **Gyre code claims.** Grepped and read every file, type, function, constant and launch argument the doc cites.
- **iOS 27 SDK.**
  - Grepped headers and `.swiftinterface` files in `iPhoneOS27.0.sdk`.
  - Type-checked the proposed Swift 6 constructs and all of Gyre (per file, `-swift-version 6`, iOS 27 target).
  - Ran a Swift 6 runtime test of `AVAudioSourceNode` isolation on macOS 27.

## Verdict

The thesis and most of the arithmetic hold up. Around 120 numeric and API claims are correct. **Five defects would break the build or a test as written:**
1. the rotor-resonance drive turns the wrong way;
2. three Larmor/cyclotron oracles cannot pass their 1e-9 tolerance;
3. the nutation oracle is 1 % off under gravity;
4. the proposed `MagnetometerStream: Sendable` does not compile;
5. the Swift 6 section misdiagnoses the audio path (no compile error, but a runtime trap if the render block is built on the main actor).

There are also seven moderate physics errors (mislabelled or wrong) and about ten minor ones.

## Findings

Severity: **H** breaks a test, the build or the headline demo. **M** is wrong physics or a wrong number in copy. **L** is a qualification or inconsistency.

| # | Sev | Where | Claim in the doc | Finding | Evidence |
|---|---|---|---|---|---|
| 1 | **H** | §4.1, §10 | Rotating B₁ = B₁(cos Ω₀t, **sin** Ω₀t, 0) into the verbatim `GyroSim` tips the axis 90° in 11.10 s. | **Wrong rotation sense.** For magnet > 0, Gyre's rotor precesses *clockwise* about +B (physcheck #5 expects −μB/L). This drive counter-rotates and is 2Ω₀ off resonance, so the maximum tilt is 11.4°. The correct drive is (cos, **−**sin) and ω⃗_rf = −γB₀, flipped for the Electron-like side. The oracle "tilt 0.1 → π/2 ±5 %" is also ill-posed: the time is 10.43–11.85 s depending on the B₁ phase. Start at tilt 0 instead. | Verbatim `GyroSim` harness. + sense: never crosses π/2 (max 11.4°). − sense, tilt 0: **11.14 s** (theory 11.10). |
| 2 | **H** | §10 | Proton Larmor 2128.8193 Hz, electron 1.401248 MHz, cyclotron 1.399624 MHz, each at **1e-9 rel**. f_s/f_c = 1 + a_e at 1e-11. | The printed values are 7–8 significant figures; the old electron Larmor value is 3.1e-7 off, so the tests fail by construction. The script uses the **CODATA 2018 m_e** (…7015), so f_s/f_c misses 1 + a_e by 1.36e-9. Full-precision CODATA 2022 values: **2128.8192715 Hz**, **1.401247569305 MHz**, **1.3996244917 MHz**; ratio within 5e-14. | NIST allascii (2022); Python. |
| 3 | **H** | §4.8, §10 | Nutation ω_n = L₃/I₁ = 246.76 rad/s at 3000 rpm, ℓ 1.75 cm, tolerance 1e-3. | Exact only at g = 0. Under gravity, ω_n = cos θ·(Ω₊ − Ω₋) = √((L₃/I₁)² − 4mgℓ cosθ/I₁) = **244.4 rad/s** at tilt 0.3 (−1 %). Likewise the in-field nod at 1500 rpm is 42.40 Hz, not 42.19. | Verbatim sim, DFT of tilt: 244.32 / 244.43 / 245.06 rad/s at tilt 0.02 / 0.3 / 0.8; 246.753 at g = 0; 42.40 Hz in 50 µT. |
| 4 | **H** | §4.3 Swift | `final class MagnetometerStream: Sendable` with `Mutex<Ring>` and `start(interval:)`. | Doesn't compile: "stored property 'manager' … has non-Sendable type 'CMMotionManager'". Fix: a `@MainActor` source owns the manager; a `Sendable` `SampleRing` with a `Mutex` is captured by the handler. | `swiftc -typecheck -swift-version 6`, iOS 27 SDK. The fixed version type-checks cleanly. |
| 5 | **H** | §1, §4.9, §9 | "HumSynth.Controls … won't compile without changes" under Swift 6. "`AVAudioSourceNode` closure: Sendable closure capturing non-Sendable state." | **No compile error.** `AVAudioSourceNodeRenderBlock` is `NS_SWIFT_NONSENDABLE`, and `HumSynth.swift` type-checks under Swift 6. The real hazard is at runtime: a render block formed in a `@MainActor` context inherits main-actor isolation and **traps** on the audio thread, so build it in a `nonisolated` factory. Gyre's actual Swift 6 errors are five, in three files: `Knobs.swift` static `[KnobSpec]` (3), `AudioRoute.recording` static var, and `RadioSense` `NWPathMonitor` capture. `Atomic<Double>` is still advisable, for correctness. | Per-file Swift 6 type-check of all of Gyre. Runtime test: the MainActor-formed block exits with SIGTRAP (133); the nonisolated factory renders off-main. |
| 6 | **M** | §4.2, §10 | Yawing 30° puts the tower "exactly in the **first** null". | It is the **second** null (k = 2). The first null of N = 8, d = λ/2 is at cos θ = 1/4, i.e. 14.48° off broadside. AF = 0, −3 dB at 6.4°, β = −90° and HPBW 14.84° are all correct. | ψ = 2πk/N. |
| 7 | **M** | §4.1 | T₂* ≈ 1/(πΔf) = 75 ms for a 10 cm sample in a 1 µT/m gradient. | That formula is for a Lorentzian line. A linear gradient over a uniform sample gives a rectangular line, so the FID is a **sinc**: 1/e at **164 ms**, first null at **235 ms** (2.2× longer). The echo oracle e^(−0.05) is unaffected. | Python. |
| 8 | **M** | §4.1, §10 | "Maximum M_z → M_xy transfer 0.9477" for f₁ 42.576 Hz, Δf 10 Hz. | f₁²/(f₁²+Δf²) is the Rabi maximum **inversion probability**, (1 − M_z,min/M₀)/2. B_eff is tilted 76.8°, so M sweeps to 153.6° and the maximum \|M_xy\| = 1. Relabelled. | Geometry of the rotation about B_eff. |
| 9 | **M** | §4.8 | Transport label "κ 1 · 1 : 1.8 × 10¹⁵" for 545 THz. | D = κ/f = 1.83 × 10⁻¹⁵, so the slowdown is **5.45 × 10¹⁴×**. The label overstates it 3.3×. | 1/D. |
| 10 | **M** | §4.8 | The nod adds "sidebands at Ω_p ± ω_n, which looks like FM". | The nod is nearly circular, so it is essentially a **single sideband** on the spin side: +39.1 Hz at −26.6 dBc versus the mirror at −49.4 dBc. It is not FM's symmetric pair. This makes it a better IQ lesson. | Verbatim sim, complex DFT of e_x + i e_y at 960 Hz. |
| 11 | **M** | §4.10, §10 | Boris "is exact for gyration"; Boris oracle at 1e-5 with no step size. | It conserves \|v\| exactly, but the phase is not exact: rotation 2 atan(ω_c h/2), frequency error ≈ (ω_c h)²/12, radius error ≈ (ω_c h)²/8. The oracle needs h ≤ T/1000 or the tan-corrected t. | Analytic; 3.3e-4 / 4.9e-4 at 100 steps per orbit. |
| 12 | **M** | §4.4 | FM Δf 5 kHz, Carson 16 kHz; CNR uses a 12.5 kHz noise bandwidth. | Inconsistent. With a 16 kHz bandwidth the CNR is 1.07 dB lower (32.7 / 22.2 / **11.7 dB**; −3.5 dB at the 80° roll). Alternatively use FRS ±2.5 kHz deviation [S]. The demo's conclusion stands. | Python. |
| 13 | L | §4.10 | Gyration at ~3 Pa (σ = 10⁻¹⁹ m² assumed); ν = 2.7 × 10¹¹ s⁻¹. | Measured e–N₂/O₂ rates (Schunk & Nagy, T_e = 300 K) give ν ≈ 1.6 × 10¹¹ and ω_c = ν at **~5.5 Pa** (~70 km). It is still the D region, which matches the classic ν ≈ ω_H near 75 km. The detent is now "~5 Pa". | Python. |
| 14 | L | §4.1 | The electron line is "inside the AM broadcast band". | Only for 18.9–60.7 µT; at 65 µT it is 1.82 MHz (160 m band). The readout chip is made conditional. | 530 / 1700 kHz ÷ 28 024.95 MHz/T. |
| 15 | L | §4.1 | Mapped pitch above 20 kHz, "a magnet within ~4 cm". | 20 kHz needs 470 µT, which the 10 × 3 mm disc reaches at **4.7–4.9 cm**. | Dipole on axis; the exact cylinder is within 1.3 %. |
| 16 | L | §4.3 | Earth: 25–65 µT. | This is NOAA's rounded range ("roughly 25,000–65,000 nT"), fine for copy. The IGRF-14 surface extremes at 2026.75 are **22.0 µT** (South Atlantic Anomaly) to **66.6 µT**; use 20–70 µT for knob ranges. Dipole B₀ = 29.7 µT confirms §5.3's "≈ 30 µT". | IGRF-14 synthesis (London sanity check: 49.0 µT, I = 66.9°). |
| 17 | L | §4.3, §4.10 | Sunlight E₀ 1013 V/m "peaks"; radiation pressure / weight = 7 × 10⁻⁵. | 1361 W/m² is top of atmosphere; at the ground E₀ ≈ 868 V/m. For broadband light E₀ is an equivalent amplitude, not a peak. The weight uses density 1000, while the Brownian paragraph uses 2000; with 2000 the ratio is 3.5 × 10⁻⁵ (2.6 × 10⁻⁵ at the ground). The rejection stands. | Python. |
| 18 | L | §4.10 | v_mp = √(2kT/m) used as v⊥. | That is the RMS v⊥ (plasma v_th). The most probable v⊥ is √(kT/m), giving r = 0.77 cm. State the convention. | 2D Maxwellian. |
| 19 | L | §5.8 | Speaker coil rejected because "2 kHz is far above the ~50 Hz Nyquist". | By the doc's own aliasing lesson an unfiltered 2 kHz tone would alias, not vanish. The reason should be the unknown filtering and stray field. | Logic. |
| 20 | L | §3 | Field lines: "line density ∝ √\|B\|". | Seed spacing ∝ 1/√\|B\| (clamped), so lines per area ∝ \|B\|. | `HoloScene.swift:203`. |
| 21 | L | §0, §4.3 | "60 Hz shows up at 39.8 Hz". | Only at the assumed fs = 99.8 Hz. The real fs and anti-alias filtering are DEV? (`rf-physics.md` F.3 review). | — |
| 22 | L | §10 | Rayleigh σ oracle at ±0.01 dB with 10⁶ samples. | The standard error is 0.0061 dB; 4 of 40 seeds fail. Use ±0.03. | numpy, 40 seeds. |
| 23 | L | §10 | P.676 at 835 hPa. | Must state 835 hPa as **total** pressure (p_dry 825.0); the convention moves 60 GHz by ~0.1 dB/km (`rf-physics-review.md` #8). | `b_prop.py`. |
| 24 | L | §1 | `channelData(_:)` "as a `Span<Float>`". | It returns the `~Escapable` enum `ChannelData`; switch on `.float(let span)`. | AVFAudio swiftinterface 335–363. |
| 25 | L | §4.8 | 960 Hz tip output covers 376.7 Hz. | True in sim time. With Gyre's Time knob above 1.27×, the wall-clock nod exceeds 480 Hz. | 2 × 376.7. |
| 26 | L | §8 | `-fakeMic` "G-major chord". | 196/294/392 Hz is G3–D4–G4, an open fifth. | `MicListener.swift:196`. |
| 27 | L | §0 | "μ = γL … exact analogy". | Exact at the level of the torque. μ ∥ ê, not L, so ω = γB holds only in the fast-top limit. | `GyroSim.torque`. |

## Claims verified correct

| Area | Checked, all correct |
|---|---|
| CODATA 2022 | γ_p/2π 42.577 478 461; γ′_p/2π 42.576 385 43; \|γ_e\|/2π 28 024.951 3861 MHz/T; a_e 1.159 652 180 46e-3; μ_p/μ_N 2.792 847 344 63; the 2018 vs 2022 γ_p gap of 1.3e-9; spectra-lab's `GAMMA_PROTON_HZ_PER_T = 42.577478518e6`. |
| Larmor / cyclotron table | All rows at 25 / 45.65 / 50 / 65 / 390 µT; anomaly beat 1623.08 Hz = a_e·f_c; proton f_c 762.2 Hz; ~C7 (+29 cents); 42.6 Hz per µT. |
| Rabi / Bloch | f₁ = γB₁/2π with B₁ the co-rotating amplitude; t_π/2 5.8718 ms, t_π 11.744 ms; 58.72 / 0.587 ms; f_eff 43.735 Hz; Bloch form and Strang splitting; Hahn echo e^(−2τ/T₂); P = 1.71e-10; M₀ = 1.61e-7 A/m. |
| Rotor | I₃ 2.7e-5, I₁ 3.4375e-5 / 1.6e-5; L 4.2412e-3 J·s; γ_rotor 14 147; Ω₀ 0.7074 rad/s (8.88 s); t₉₀ 11.10 s (with the corrected sense); γ′_p/γ_rotor 1.89e4; NdFeB μ 8.276 A·m², detent 0.138, period 64.4 s; Ω_p 1.2139 fast-top, slow root 1.2197, physcheck 1.2201; nods 112.5 → 7.5 Hz and 337.5 → 22.5 Hz at 120 or 60 fps; 376.7 Hz worst case. |
| Ethanol | 988.6 / 148.3 Hz / 5.26 mHz; Δν/J 139 / 20.9 / 7.4e-4; strong-coupling collapse. |
| Antenna | PLF −1.249 / −3.010 / −6.021 / −15.207 / −35.163 dB; dipole F²(30°) −7.581 dB; roll vs pitch separation; ULA AF = 0 at 60°, −3.01 dB at 83.6°, β −90°, HPBW 14.84°; λ/2 at 28 / 39 GHz; Rayleigh σ 5.570 dB; BLE λ 12.48 / 12.36 / 12.09 cm; 2D²/λ 0.416 m; chassis c/2L 937.4 MHz (159.9 mm). |
| Magnetometer | Aliasing table rows (fs 100 / 99.8 / 120); 512/1024-point windows and bins; disc m 0.2437 A·m², on-axis 390 / 48.75 / 6.1 / 1.8 µT (exact cylinder 384.9 µT at 5 cm); cord 10 / 1.6 / 0.4 µT vs single wire 50 / 20 / 10 µT; B₀ = E₀/c 3.34 µT. |
| Modulation | β 1.667, Carson 16 kHz; AM 1.32 and 24.2 %; FSPL at 1 m (25.75 dB at 462.6 MHz, 40.20 dB at 2.44 GHz); CNR arithmetic; −2.5 dB at 80° roll; f_m 2.16 / 11.39 Hz; outage 9.52 / 0.995 %; QPSK BER 1.25e-2 / 2.39e-3 / 3.87e-6; 153 errors/s. |
| Air | P.453-14 eqs. (1), (2), (6), (7) (0.02 %, −50 to +40 °C), (8), (9), EF_water, a/b/c/d, N₀ 315, h₀ 7.35 km (all read in the PDF); N 272.87 / 311.37 / 311.36 / 370.64 / 224.87; ∂N/∂P 0.269, ∂N/∂e 4.50; k 1.34199; ducting −157 N/km; horizon √(2kah) = 4.12√h km: 5.048 / 13.978 / 22.576 km, sum 27.6 km; ZHD 2.30697 m (7.70 ns), 1.903 m, 2.28 mm/hPa; scale height 8.32 m/hPa; P.676 14.502 / 12.270 / 0.0183 / 0.0124 dB/km (same code as the reviewed `b_prop.py`); Edlén 282.76 / 277.84 / 275.81; Debye 19.24 GHz; 38 µm and 1.04 ns/km. |
| Optics | Airy free-film formula; R 0.0412 / 0.0092 / 0.0769, max 0.0771, black film ≤ 0.003; water Cauchy 1.3323 / 1.3356 / 1.3396; Malitson 1.46557 / 1.46080 / 1.45681; N-BK7 1.52532 / 1.51958 / 1.51485 (n_d 1.51680); dip 66° → 48.32°, 49.05 µT; 60° → 40.89°. |
| Charges | r_L 1.0844 cm, T 0.7145 µs; 1.39 mm and 10.92 MHz at 390 µT; proton r 46 cm; E × B 2e4 m/s; n 2.55e25; v̄ 1.08e5; ω_c 8.79e6; fluctuation–dissipation variance; Brownian σ_v 1.99 mm/s, τ 6.1 µs, √(2Dt) 7.0 µm; kTB −173.98 / −113.98 / −110.96 / −133.0 dBm. |
| Scale / ruler | True-scale table (all rows); λ 140.8 km, 4997 km, 5996 km, 38 288 km, 213.9 m; `LOG_MIN −13`, `LOG_MAX 3`; spectra-lab `pitchFor` = 110·2^(4(log₁₀f − 5.5)/16) → 57.7 / 215.7 / 545.1 / 123.0 Hz; default E₀ 1000 V/m; Debye τ 8.27 ps; `timeScale = speed/f_ref`. |

## Gyre code claims verified

All exist with the stated behaviour:
- **Physics:** `GyroSim` (`torque`, `launch` slow root, `maxDipole = 60` "fantasy magnet", `magnet` 0…1, substeps n = ⌈dt·fastest/0.1⌉ clamped to 1–2000, `precessionRate`); `MoteField` (bounce, static friction), `Jiggle`, `TrailBuffer` (`BubbleWorld.swift`); `MathUtil` helpers.
- **Motion:** `MotionSample.attitude` (phone → world), `invertAttitude`, `.xArbitraryCorrectedZVertical`, `deviceMotionUpdateInterval = 1/120`, simulated field (0, 22, −40) µT, sway 0.9 sin 0.31t.
- **Model:** `updateEMF` (RMS and zero crossings of the per-frame calibrated \|B\|); 120 fps, or 60 in AR / Low Power; `sceneScale = 12` ("about 17 cm across"); `envelope()` constants; `kick` clamp(0.4·\|L\|, 0.0008, 0.0065) (the tap poke uses 0.45); `p.gravity += depth·m·2`; `wobbleHz = 2·precession + 1.5`.
- **Feedback:** crackle uniform 0.3–1.7/rate; haptic hum mapping, 30 s looped event, ≤ 40 Hz updates, sharpness −0.5, ticks 0.32/0.9 and detent 0.9/0.3; HumSynth blade ×6, 0.55/0.17/0.06, xorshift, equal-power pan.
- **Microphone:** ring 16 384, onset 1.9× + 0.004, 0.12 s refractory, `ignoreOnsets(for: 0.2)`, scope 1024 / 900 / 0.02·gain / 3 sweeps / lag 48.
- **Radio:** duplicates, `NWPathMonitor`, `CTTelephonyNetworkInfo`, 10 s expiry, 0x4C 0x00, 0.3 EMA, 1.5 s throttle, 24 kept, 11 fakes; `RadioColor`; `Spectrum` (Hann, 2048, `vDSP_fft_zrip`, 48 bands 45 Hz – 15 kHz, 73 lines).
- **AR:** `carryOffset` 45 cm, `.gravity`, `.automatic`, `delegateQueue = .main`, `place` / `pickUp` / `pinch` / `fakeFrame` / `frameState`.
- **Render:** `HoloRenderer` (rgba16Float, depth32Float, ½ and ¼ bloom, semaphore 3, `pipeline`, `phoneSetup`, `arSetup` reversed-Z); `Holo.metal` line glow constants, 0.015 nudge, `filmInterference` (420 nm, 0.5 − 0.5 cos δ, n = 1.33), `softClip`; `GyroMeshes.Builder` methods; `HoloSceneBuilder.markers` and `fieldLines` (dipole term 3(a·r̂)r̂ − a).
- **UI and knobs:** knob ranges and detents; nine experiments; `GlassKnob` 24 ticks and ±0.02; `.tabs`, `KnobReadout`, `LevelMeter`, `ObjectTile`, `glassEffectID`; `TelemetryCard`; `ARBanner`; physcheck harness shape.

## iOS 27 SDK claims verified

All present in `iPhoneOS27.0.sdk`:
- **Audio:** `AVAudioNode.installAudioTap(onBus:bufferSize:format:tapProvider:) throws` (iOS 27, `@Sendable` provider); `AVReadOnlyAudioPCMBuffer` / `ChannelData`; `AVAudioSessionDidBecomeInactiveNotification` and `AVAudioSessionResumptionRecommendationNotification` (iOS 27; the old interruption notification is deprecated in 27); `AVAudioSourceNodeRenderBlock` (`NS_SWIFT_NONSENDABLE`).
- **Synchronization:** `Atomic<Double>` (`Double: AtomicRepresentable` at line 216, iOS 18) and `Mutex` (iOS 18).
- **Core Motion:** `deviceMotionBody` (iOS 27; `UIView` conforms to `CMBodyIdentifiable`); `startMagnetometerUpdates`; `CMLogItem.timestamp`; `CMMagneticFieldCalibrationAccuracy`; `.xMagneticNorthZVertical`; `CMAltitudeData.relativeAltitude`.
- **Network and telephony:** `NWPath.LinkQuality` (unknown / minimal / moderate / good); `PathReport.radioType` and `.ax`; CoreTelephony `radioAccessTechnologyDidChange` typed message (iOS 27).
- **Other frameworks:** `NISession.setARSession(_:)` and `…InsufficientHorizontalSweep`; `ARLightEstimate.ambientColorTemperature`; `ARFrameSemanticSceneDepth`; `vDSP.FFT`; `MTLFunctionConstantValues`.

**Not an SDK fact:** the "`currentEDRHeadroom` (≤ 3)" cap does not appear in Gyre. Gyre passes the raw headroom to `softClip`, so ≤ 3 is a design choice to state as such.

## Reproducing the key checks

The rotor-resonance check compiles `Gyre/Physics/MathUtil.swift` and `GyroSim.swift` unchanged, plus this loop:

```swift
var p = GyroParams(); p.friction = 0; p.air = 0; p.balance = 0; p.gravity = 0; p.magnet = 1; p.motorRPM = 1500
let sim = GyroSim(); sim.launch(params: p, tilt: 0, rpm: 1500)
var env = GyroEnvironment(); env.airDensity = 0
let W = GyroSim.maxDipole / (sim.I3 * 1500 * 2 * .pi / 60) * 50e-6, B1 = 10e-6
for i in 0..<(40 * 120) {                       // sense = −1 works; +1 (the doc's) never passes 11.4°
  let t = Double(i) / 120
  env.magneticField = V3(B1 * cos(W * t), -B1 * sin(W * t), 50e-6)
  sim.step(dtReal: 1.0 / 120, env: env, params: p)
}
```

The nutation check takes a DFT of `sim.tilt` sampled at 4 kHz after a 2e-5 J·s transverse kick. The IQ check takes a complex DFT of `axis.x + i·axis.y` at 960 Hz. The Swift 6 checks used `xcrun --sdk iphoneos swift-frontend -typecheck -swift-version 6 -target arm64-apple-ios27.0`, with each file as the primary and the iPhoneOS platform macro plugins on the path.

## Left as is (outside this review's scope)

`rf-physics-calc/e_gyre.py` still uses the CODATA 2018 values of m_e, μ₀ and ε₀. Its printed results are unchanged at the precision shown, but it should switch to the 2022 m_e (9.1093837139e-31) before anyone generates oracles from it at 1e-9.
