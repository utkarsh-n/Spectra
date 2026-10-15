# Gyre → Spectra: integration design

Research date: 3 October 2026. This feeds the final Spectra spec.

**Read in full for this note:**
- Gyre at its 15:18 state: `README.md`, `project.yml`, `Tools/build.sh`, `Tools/physcheck/{run.sh,main.swift}`, every Swift file in `Gyre/{App,Feedback,Model,Physics,Render,Sensors,UI}`, and the key shaders in `Render/Holo.metal` (`filmInterference`, `metalFragment`, `lineVertex`/`lineFragment`, bloom, `compositeFragment`).
- In `Spectra/Docs/research`: `design-gyre.md`, `design-orbitals.md` §d–f, `sdk-sensors.md`, `rf-physics.md`, `port-plan.md` and `design-house-rules.md` §3–5.
- In `spectra-lab`: `README.md`, plus `src/core/constants.js`, `state.js` and the NMR and air parts of `samples.js` and `matter.js`.

Nothing in Gyre or spectra-lab was modified.

**Tags** (the same scheme as `rf-physics.md`):

| Tag | Meaning |
|---|---|
| **[V]** | Read in a primary source this session: a standard PDF, the NIST CODATA table, or an SDK `.swiftinterface`. |
| **[C]** | Computed this session. The script is `rf-physics-calc/e_gyre.py` (run it from that folder; it reuses `b_prop.py`'s P.676). |
| **[S]** | Secondary source only. |
| **[!]** | A flag: a trap, an uncertainty, or a correction. |
| **DEV?** | Must be measured on the iPhone 15 Pro Max. |

---

## 0. Verdict

**Thesis.** Gyre is not a mode to bolt onto Spectra. It brings three layers Spectra needs, and its physics is already EM physics:

1. **One equation.** Gyre's rotor obeys dL/dt = τ with τ = μ × B (`GyroSim.torque`). With μ = γL that becomes dL/dt = γ L × B, which is Larmor precession: the same equation that governs a proton in an NMR magnet and an electron in Earth's field. Gyre already passes a Larmor check to 0.1 % (`physcheck` #5). Gravity enters the same way, τ = ℓ ê × m g. So "gravity ↔ B, mℓ ↔ μ" is an exact analogy, not a metaphor. This becomes a new instrument, **06 Spin**. [corrected in review: the analogy is exact at the level of the torque. In Gyre, μ = μ ê lies along the symmetry axis, not along L (L = L₃ê + I₁ω⊥), so "μ = γL" and ω = γB hold only in the fast-top limit. The residual is the inertial nod (§4.1).]
2. **The live layer.** Gyre already reads device motion (attitude, gravity, rotation), the calibrated magnetometer, the barometer, the microphone (ring buffer, onsets, a scope, a 2048-point FFT), BLE RSSI with `NWPathMonitor` and the RAT, and ARKit. Those classes become Spectra's sensor sources once they are fixed for Swift 6 and timestamped sampling.
3. **The output layer.** Gyre supplies the HDR Metal renderer (bloom, EDR soft-clip, instanced 3D glow lines, GGX holo-metal, thin film), the continuous Core Haptics hum, the live `AVAudioSourceNode` synth and the Liquid Glass knob console. They become Spectra's one renderer, one haptics service, one synth and one knob system.

**Required ideas and added ideas:**

| # | Idea | Verdict | One-line reason |
|---|---|---|---|
| 1 | Spin as a gyroscope; Earth's-field NMR from live \|B\| | **Keep (centrepiece)**, refined | The rotor *is* a classical spin. Proton precession in Earth's field (~2.13 kHz) is audible at its true pitch. Rabi nutation is shown with Bloch equations. Heavy-top nutation is kept explicitly distinct from Rabi "nutation". |
| 2 | Phone attitude = antenna attitude | **Keep**, refined | Rotate the pattern and the polarization with the attitude quaternion. "Beam lock" reuses Gyre's main lesson (an axis held fixed in the world). Live BLE comparison only as a turntable experiment with fading statistics. |
| 3 | Magnetometer as an ELF probe | **Keep**, but **rewrite the sampling** | Gyre pulls the field once per *render frame*, which is not valid for an FFT. Use timestamped push samples at the hardware rate (~100 Hz, DEV?) and teach aliasing (60 Hz → about 40 Hz; exactly 39.8 Hz only at the illustrative fs = 99.8 Hz [corrected in review]). |
| 4 | Mic + Drives → audio sources and voice modulation | **Keep**; Drives becomes the modulation matrix | Modulation *is* "a slow signal pushing a knob of a fast one". Voice is AM/FM/QPSK'd through the live antenna chain and played back. Push-to-talk avoids acoustic feedback. |
| 5 | Barometer → refractivity, horizon, Spectra's air | **Keep**, with honest weights | The barometer barely moves N (0.27 N/hPa). Its real value lies elsewhere: GNSS zenith delay (2.28 mm/hPa), O₂ absorption at 60 GHz, and height above the start point (8.3 m/hPa) for the radio horizon. |
| 6 | Holo renderer + Orbitals phosphor merged | **Keep** | One HDR pipeline with two line material modes (3D "holo", 2D "phosphor") over shared bloom and EDR. |
| 7 | AR true scale | **Keep** | Use Gyre's single-Metal camera path plus Orbitals' phase machine. One `ARSession` feeds placement, LiDAR ToF, CCT and UWB camera assist. An AR-placed transmitter supplies the real link direction for idea 2. |
| 8 | Heavy top as an oscillator node; κ unified | **Keep** | The axle-tip projection e_x + i e_y is literally an IQ signal. Sample it at 960 Hz from the substeps, not at the frame rate. One time contract: real time, κ-slowed, or heterodyned. |
| 9 | Haptics and HumSynth as sinks | **Keep** | Merge Gyre's continuous hum with Orbitals' rate-limited transients. The synth uses `Atomic<Double>` controls under Swift 6, with explicit feedback guards. |
| 10 | Dust motes → EM analogue | **Refine**: charged particles. **Reject**: radiation pressure. **Keep, metaphor badge**: Brownian motion | A thermal electron's gyroradius in Earth's field is **1.08 cm**, which fits in the bubble at true scale. The Air knob becomes collision frequency, and gyration needs ~3–5 Pa [corrected in review: ~5.5 Pa with measured e–N₂/O₂ rates, §4.10]. Radiation pressure on dust is 7 × 10⁻⁵ of its weight (3.5 × 10⁻⁵ at density 2000 kg/m³) [corrected in review]. |
| + | Soap film → thin-film specimen | **Add** | Gyre's film shader is optical interference. Use the Airy formula and spectra-lab's water index. |
| + | Glass orb → Sellmeier dispersion | **Add** | Replace the "Dispersion" fudge with `Medium.index(λ)` at 450/530/640 nm. |
| + | Planet → Earth dipole from measured inclination | **Add** | Gravity plus B gives the dip angle I, and tan I = 2 tan λₘ gives magnetic latitude. |
| + | Electron cyclotron vs spin (g − 2) | **Add** | In 50 µT: 1.39962 MHz vs 1.40125 MHz. The 1.62 kHz beat is the anomaly frequency. |
| + | Phone chassis as a dipole | **Add** (MODEL) | 159.9 mm is about λ/2 at 937 MHz, so the low band radiates along the long axis. |
| + | Extend the spectrum ruler below 1 km | **Add** | Earth-field NMR (λ 140.8 km), mains (5,000 km) and Schumann (38,000 km) are off spectra-lab's ruler. |
| + | Field painting (AR position × magnetometer/RSSI) | **Add** (experiment) | Measured B lines through the room, and λ/2 RSSI fading structure. |
| − | Gyre `RadioColor` (hue from BLE beacon rate) | **Reject** | Breaks "hue = frequency": every BLE packet is 2.4 GHz. |
| − | Gyre's audio visualizer in spectrum hues | **Recolor** | Sound is not EM. Use the phosphor/amber analogy palette. |
| − | Gyre's hum "wobble" at 2·precession + 1.5 Hz | **Replace** | Not physical. Modulate at the true (κ-scaled) nutation frequency. |
| − | Speaker coil or Taptic magnet as a "transmitter" for the magnetometer | **Reject as a feature** | Becomes a DEV? interference check instead (§11). |

---

## 1. Gyre today, and corrections to `design-gyre.md`

`design-gyre.md` was written during a 14:20–14:40 snapshot. Gyre has since gained `Sensors/RadioSense.swift` (166 lines) and `Sensors/Spectrum.swift` (73 lines), and the console has a **Signals** page with a Radio knob. Four statements in that note are now wrong or need qualifying:

| `design-gyre.md` says | Now |
|---|---|
| "Gyre has no FFT and touches no radios" (§0, §12) | `Spectrum`: Hann, 2048-point `vDSP_fft_zrip`, 48 log bands from 45 Hz to 15 kHz. `RadioSense`: CoreBluetooth scan with duplicates, `NWPathMonitor`, the `CTTelephonyNetworkInfo` RAT, and `-fakeRadio` (11 synthetic radios). |
| Magnetometer usable as an EMF probe | `GyroModel.updateEMF` takes the RMS and zero-crossing rate of \|B\| from `motion.sample(dt:)`, which is pulled **once per render frame** (120 Hz, 60 in AR). With a ~100 Hz sensor (DEV?), about 1 frame in 6 repeats a sample, and an FFT over those values has images. Spectra must not reuse this sampling (§4.3). |
| Keep `installTap` (no Swift refinement) | `sdk-sensors.md` §1.6 found the Swift replacement: `installAudioTap(onBus:bufferSize:format:tapProvider:) throws`, read through `AVReadOnlyAudioPCMBuffer.channelData(_:)` as a `Span<Float>`. [corrected in review: `channelData(_:)` returns the `~Escapable` enum `ChannelData` (`.int16`, `.int32` or `.float(Span<Float>)`), so you switch on `.float(let span)`. The tap is iOS 27 only, and `tapProvider` is `@Sendable`. Both were type-checked against the iOS 27 SDK in Swift 6 mode.] |
| `HumSynth.Controls` unlocked doubles are fine | Fine in Swift 5. Spectra is Swift 6 with strict concurrency, so this won't compile without changes. `Synchronization.Atomic<Double>` is available from iOS 18 [V: `Synchronization.swiftmodule/arm64e-apple-ios.swiftinterface` line 216] (§9). [corrected in review: **it does compile.** Type-checking Gyre's `HumSynth.swift` as Swift 6 against the iOS 27 SDK gives no error, because `AVAudioSourceNodeRenderBlock` is `NS_SWIFT_NONSENDABLE`. The race is real but the compiler does not diagnose it, so `Atomic<Double>` is still right, for correctness rather than compilation. The actual Swift 6 errors in Gyre are listed in §9.] |

Other things in Gyre that matter for physical coherence:
- **Magnet strength.** `GyroSim.maxDipole = 60 A·m²` is "a fantasy magnet" (source comment). A rotor of solid NdFeB with the same 60 g mass has μ = (Bᵣ/μ₀)·V = (1.3 T / μ₀)·(0.06 kg / 7500 kg m⁻³) = **8.28 A·m²** [C], so 60 is 7.2× too strong. **Keep 60 so the effect is visible, and add a "Real NdFeB" detent at 0.138.** Its Larmor period at 1500 rpm in 50 µT is **64.4 s**, against 8.88 s at full strength [C].
- **Signed γ.** `GyroParams.magnet` is 0…1, so γ_rotor is always positive (μ parallel to L, like a proton). **Change it to −1…1** with an "Electron-like" detent at −1, so the rotor can precess the other way.

---

## 2. Coherence rules

These are the contract that makes Gyre feel native in Spectra rather than bolted on.

- **R1. One equation of motion for every precessing thing.** dL/dt = μ × B (+ ℓ ê × m g for the top). Gyroscope, proton and electron share one view, one trail renderer and one IQ output. Only γ and the inertia differ (§4.1).
- **R2. Hue means EM frequency, and nothing else.**
  - EM signals take their colour from spectra-lab's `displayRGB(λ)` and band colours.
  - Non-EM signals (sound, mechanical motion, the rotor) use Gyre's phosphor green (0.35, 1.00, 0.55) and Orbitals' amber. They carry an **ANALOGY** badge (as `sdk-sensors.md` §4.9 already does for audio).
  - Brightness means level or strength. Saturation is not used to encode data.
- **R3. Every visible oscillation declares its time mapping.** There are three honest options, and the transport shows which one is active:
  1. **Real time** (D = 1): the gyroscope, the magnetometer, audio envelopes.
  2. **κ-slowed**: D = κ / f_ref sim-seconds per wall-second. This is spectra-lab's `timeScale`, where κ is the display cycles per second of the reference oscillator.
  3. **Heterodyned**: a rotating frame at f_ref. You see Δf = f − f_ref. This is NMR's rotating frame, an RF mixer's baseband, and the IQ view, all one idea.

  If displayed frequency × (1/frame rate) exceeds ½, the display is aliasing. Draw Gyre's swept-arc motion blur (`HoloSceneBuilder.markers`) and show an **ALIASED** chip. The magnetometer has the same lesson (§4.3).
- **R4. Provenance travels along cables.** The badges are LIVE / INFERRED / SIM / MODEL / TABLE / LOCKED / NEEDS PEER (`sdk-sensors.md` §7) plus ANALOGY. A node's output carries the *set* of badges of its inputs plus its own. Gyroscope driven by live motion → "MODEL · LIVE motion".
- **R5. One of each.** One clock (the render loop calls `advance(dt:)`, from Gyre), one renderer, one synth, one haptics service and one `ARSession`. Instruments that are off screen cost nothing (Orbitals rule 9).

---

## 3. Subsystem map (every Gyre file)

Target paths follow `port-plan.md` §2: `Spectra/Spectra/Core/` imports Foundation and simd only, uses Double, and converts to Float at the Metal boundary.

| Gyre file | Becomes in Spectra | Physics link | Reuse | UI surface |
|---|---|---|---|---|
| `App/GyreApp.swift` | — | — | Not reused. The app shell comes from Orbitals' `OrbitalsApp`. | — |
| `Physics/MathUtil.swift` | `Core/Math/SIMDMath.swift` | — | **Verbatim** (V3/F3/F4, `clamped`, `smoothstep`, `perpendicular`, `wrapAngle`, quaternion casts). | — |
| `Physics/GyroSim.swift` | `Core/Mechanics/GyroSim.swift` | Heavy symmetric top; μ × B Larmor; rotating-B₁ magnetic resonance needs **no code change** (pass B₀ + B₁(t) in `env.magneticField`). | **Verbatim**, plus one change: `magnet` range −1…1. Non-Sendable `final class`, owned only by the `@MainActor` engine (§9). Add a substep tap for the 960 Hz tip output (§4.8). | Spin instrument; Gyroscope node. |
| `Physics/BubbleWorld.swift` `MoteField` | `Core/Plasma/ChargedParticles.swift` | Lorentz force via the Boris pusher; Air → collision frequency (§4.10). | **Reimplement** the dynamics. Keep the wall/bounce code. | Spin bubble "Charges" layer. |
| `BubbleWorld.swift` `Jiggle` | `Rendering/BubbleWobble.swift` | Damped spring, cosmetic. | Verbatim. | Bubble skin only. |
| `BubbleWorld.swift` `TrailBuffer` | `Core/Util/RingTrail.swift` | — | **Verbatim**. | Axle trail, Bloch-tip trail, IQ persistence. |
| `Model/GyroModel.swift` | Split into `GyroEngine` (sim, touch → torque, harmonic centre), `ModulationMatrix` (`envelope`, the drives), `ScopeTrigger` (`updateScope`), `Telemetry` (10 Hz) and `RadioField` (BLE wavefront visuals) | Torque from touch: string pull r × F, flick impulse. | **Adapt**: keep the observed vs `@ObservationIgnored` split and the 10 Hz telemetry verbatim. | Spin console; graph. |
| `Model/Knobs.swift` | `UI/Knobs/KnobSpec.swift` + `Instruments/Spin/SpinKnobs.swift` | Detents carry physical meaning (Moon, Earth, Jupiter → add "Earth field 50 µT", "Real NdFeB", "Vacuum", "D layer ~5 Pa" [corrected in review]). | **Verbatim** mapping maths (`position(of:)`, `value(at:)` with log, `origin`, `detent(at:)`, `isSwitch`). Generalize `keyPath` to `ReferenceWritableKeyPath<Root, Double>` (generic `KnobSpec<Root>`). `Experiment` → Spin field trips. | Every console. |
| `Feedback/Haptics.swift` | `Services/SpectraHaptics.swift`, merged with `OrbitalHaptics` | Strain \|ω_phone × L\| is the real gyroscopic reaction torque you feel. | **Adapt**: `@MainActor`; engine handlers hop with `Task { @MainActor in }`; add Orbitals' `strength`, rate limit and background stop; keep `updateHum` and `spinUp`; make the crackle Poisson. | **Feel** sink node; Settings "Feel". |
| `Feedback/HumSynth.swift` | `Audio/SpectraSynth.swift` | The rotor voice stays. New voices: FID at true Larmor pitch, demodulated audio, mapped tones, Geiger. | **Adapt**: the DSP loop is verbatim; controls become `Atomic<Double>`; add iOS 27 interruption notifications. | **Hear** sink node. |
| `Sensors/MotionSource.swift` | `Sensors/MotionSource.swift` + new `Sensors/MagnetometerStream.swift` + `Sensors/Barometer.swift` | Attitude rotates antenna patterns. Raw B goes to ELF FFT. P goes to N, ZHD and height. | **Adapt**: keep frame-pulled device motion for rendering (correct for attitude). **Add** push-mode raw magnetometer with `CMLogItem.timestamp`. Add `relativeAltitude`, `deviceMotionBody` (iOS 27) and an optional `.xMagneticNorthZVertical` frame. | Motion, Magnetometer and Barometer nodes; TelemetryCard. |
| `Sensors/MicListener.swift` | `Sensors/MicSource.swift` | Acoustic analogue source; voice message for modulation. | **Adapt**: `installAudioTap`; ring under `Mutex` (Synchronization); `AudioRoute` verbatim plus route detection; `-fakeMic` verbatim plus a "voice" mode. | Microphone node. |
| `Sensors/RadioSense.swift` | `Sensors/BLEScanner.swift` + `Sensors/NetworkPathSource.swift` | 2.4 GHz RSSI per advert; RAT; link quality. | **Adapt**: keep the scan, the 10 s identifier expiry and the Apple-mfr check. Deliver **every** RSSI sample with a timestamp (Gyre smooths it with a 0.3 EMA, which hides fading). Keep the 1.5 s pulse throttle for visuals only. Drop `RadioColor`. | BLE and Cellular/Wi-Fi nodes. |
| `Sensors/Spectrum.swift` | `DSP/BandSpectrum.swift` | Hann window, scalloping 1.42 dB (`rf-physics.md` G.2). | **Reimplement** on `vDSP.FFT` with calibrated dBFS (coherent-gain correction; mind zrip's 2× scaling, G.4). Keep the 48-band log-binning and peak-hold idea as a display style. | Fourier visualizer "Bands" style. |
| `Sensors/ARController.swift` | `AR/SpectraARController.swift` | Real-scale wavelengths; placed transmitter gives the link direction. | **Adapt**: keep Gyre's zero-copy YCbCr → Metal path, carry/place, ease, pinch and `-fakeAR`. Take Orbitals' `Phase` machine, readiness raycast (0.12 s), "Move anchor / Scan a new space", Open Settings recovery and `@preconcurrency ARSessionDelegate`. Add `.sceneDepth`. | AR mode for any 3D instrument. |
| `Render/HoloRenderer.swift` | `Rendering/SpectraRenderer.swift` | — | **Adapt**: the skeleton is verbatim (rgba16Float + depth32Float, ½ and ¼ bloom, triple buffer, `pipeline(...)` builder, `phoneSetup` layout-driven camera, `arSetup` reversed-Z detection). Take Orbitals' non-blocking semaphore, offscreen skip and 60/30 fps policy. | All Metal canvases. |
| `Render/HoloScene.swift` | `Rendering/GlowGeometry.swift` + `Rendering/FieldLineTracer.swift` | Field lines: seed spacing ∝ 1/√\|B\|, so lines per unit area ∝ \|B\| (Faraday's convention; Gyre clamps strength to 0.5–8 and spacing to ≥ 0.3) [corrected in review: was "line density ∝ √\|B\|"]; midpoint tracing. | **Adapt**: keep `seg`/`point`/`ring`/`arrow`/`markers`/`billboard`, `cue`, scan band and `ViewBasis`. Generalize `fieldLines(field:…)` to take a `fieldAt: (V3) -> V3` closure (painted or modelled fields). `HoloPalette` keeps geometry tokens only. | Wave scope, Spin, ELF view, antenna, graph. |
| `Render/GyroMeshes.swift` | `Rendering/MeshBuilder.swift` + `Rendering/AntennaMeshes.swift` | Radiation-pattern surfaces r(θ,φ); antenna bodies. | **Verbatim** `Builder` (`grid`, `cap`, `torus`, `cylinder`, `sphere`, `lathe`, `annulus`, `smooth`, `orient`, `upload`) and the matrix inits. Rotor/top/planet meshes are verbatim for Spin. **Add** `tube(path:)` (helix), `box` (patch/PIFA) and a parabolic `lathe` (dish). | Spin; RF Lab 3D. |
| `Render/Holo.metal` | `Glow.metal`, `Post.metal`, `Materials.metal`, `Backgrounds.metal` | Thin film (Airy), GGX metal, refraction with dispersion. | **Verbatim**: `lineVertex`/`lineFragment`, prefilter/copy/blur, `softClip`, `compositeFragment`, `cameraColor`, `sky`. **Adapt**: `metalFragment` (add a dielectric path for PCB/radome), `filmInterference` (n from Medium.water), `glassOrbFragment` (per-channel n from Sellmeier), `planetFragment` → Earth. | — |
| `UI/GlassKnob.swift` | `UI/Knobs/GlassKnob.swift`, merged with Orbitals' | — | **Adapt**: Gyre's gesture, ticks (24/sweep), detent capture (±0.02), switch clicks and double-tap reset. Orbitals' linear slider underneath, `onKeyPress` and `@FocusState`. **Add** a modulation ring (§7). | Every console. |
| `UI/Console.swift` | `UI/Console/KnobConsole.swift` | — | **Verbatim** pattern: `.tabs` pages, fold, `KnobReadout`, `LevelMeter`, `ObjectTile`, `glassEffectID` morph. | Spin; RF Lab. |
| `UI/TopBar.swift` | `UI/TelemetryCard.swift` | Sensor transparency. | **Verbatim** pattern; the rows become live µT, fs, kPa, RSSI and a SIM caption. | Every instrument. |
| `UI/InfoSheet.swift` | "How Spectra works" sheet sections | — | **Adapt**: `[.medium, .large]`, background interaction, auto-generated knob section from `KnobSpec.detail`, serif-italic legend. | `info.circle`. |
| `UI/ContentView.swift` | Spin instrument root | — | **Adapt**: `bubbleRegion` → `onGeometryChange` → eased camera; canvas accessibility actions ("Spin faster", "π/2 pulse"). | Spin. |
| `UI/ARViews.swift` | `AR/ARViews.swift` | — | **Verbatim**. | AR. |
| `Tools/physcheck` | `Tools/physcheck` + new `Tools/spincheck` | Oracles in §10. | **Verbatim** harness shape (`check(name, ok, detail)`, exit code). | CI. |
| `Tools/build.sh` | `Tools/build.sh` | — | **Verbatim** with renames (`SPECTRA_BUILD_DIR`). | — |
| `Tools/make-icon.swift` | — | — | Pattern only. | — |

---

## 4. The ten ideas

### 4.1 Spin: the gyroscope is a classical spin (KEEP, centrepiece)

**Physics**
- Torque on a magnetic moment: τ = μ × B. If μ = γL, then dL/dt = γ L × B, so L precesses about B at **ω_L = γ B** (sense set by the sign of γ).
  - Proton: γ > 0. Electron: γ < 0.
  - Gyre's rotor: γ_rotor = μ / L₃ = μ / (I₃ ω₃). This is mechanical, set by the Magnet knob *and the spin rate*.
- Heavy-top analogue: τ = ℓ ê × m g gives a precession rate Ω_p ≈ m g ℓ / L₃ (fast-top limit). The exact slow root of I₁ cosθ Ω² − L₃ Ω + m g ℓ = 0 is in `GyroSim.launch`. **Map: μ ↔ m ℓ, B ↔ g.** The Gravity knob is a "gravitational Larmor" field.
- [!] **The word "nutation" means two different things.**
  - The heavy top nods at ω_n ≈ L₃/I₁ because the rotor has *transverse inertia* I₁.
  - A quantum spin has no transverse inertia, so it has no inertial nutation.
  - NMR's "nutation" is the *driven* rotation of M about a resonant B₁ (Rabi).
  - Spectra must label them separately: "inertial nod" (Gyre) vs "Rabi nutation" (spin). The rotor behaves like a spin in the fast-top limit L₃ ≫ I₁Ω, where the inertial nod is small and fast.
- Constants: CODATA 2022 [V, NIST allascii table]. spectra-lab uses the 2018 γ_p for parity (`GAMMA_PROTON_HZ_PER_T = 42.577478518e6`). The 2022 value 42.577 478 461 MHz/T differs by 1.3 × 10⁻⁹, which doesn't matter here. Keep 2018 in the parity core and add the others as new constants:

| Constant | Value (2022) | Swift name (proposed) |
|---|---|---|
| γ_p/2π | 42.577 478 461 MHz T⁻¹ | `SI.gammaProtonHzPerT` (keep the 2018 value for parity) |
| γ′_p/2π (shielded, H₂O, sphere, 25 °C) | 42.576 385 43 MHz T⁻¹ | `SI.gammaProtonShieldedHzPerT` |
| \|γ_e\|/2π | 28 024.951 3861 MHz T⁻¹ | `SI.gammaElectronHzPerT` |
| a_e | 1.159 652 180 46 × 10⁻³ | `SI.electronAnomaly` |
| μ_p/μ_N | 2.792 847 344 63 | `SI.protonMomentNuclearMagnetons` |

**Worked values [C]** (water protons use the shielded γ′):

| \|B\| | Proton f_L | Electron f_L | Electron f_c = eB/2πmₑ | f_c − f_L(e) |
|---|---|---|---|---|
| 25 µT (equatorial low) | 1064.41 Hz | 0.70062 MHz | 0.69981 MHz | 811.5 Hz |
| 45.65 µT (Gyre's simulated field \|(0, 22, −40)\|) | 1943.65 Hz | 1.27936 MHz | 1.27788 MHz | 1481.9 Hz |
| **50 µT** | **2128.82 Hz** | **1.40125 MHz** | **1.39962 MHz** | **1623.1 Hz** |
| 65 µT (high latitude) | 2767.47 Hz | 1.82162 MHz | 1.81951 MHz | 2110.0 Hz |
| 390 µT (magnet at 5 cm, §4.3) | 16.605 kHz | 10.930 MHz | 10.917 MHz | 12.66 kHz |

- **Precision.** A 1 µT error in \|B\| moves the proton line by 42.6 Hz. The magnetometer's calibration state (`CMMagneticFieldCalibrationAccuracy`) must be shown next to f_L.
- **Ear and radio.**
  - The proton line in Earth's field is **audible at its true frequency** (~C7).
  - The electron line falls **inside the AM broadcast band** (530–1700 kHz [S]). Both slide live as you bring a magnet near. [corrected in review: this holds only for 18.9 µT < \|B\| < 60.7 µT (or < 57.3 µT for the ITU Region 1 upper edge of 1606.5 kHz). At 65 µT the line is 1.82 MHz, in the 160 m amateur band. The "AM band" chip must be conditional.]

**Driven spin (Bloch equations) [Bloch 1946, *Phys. Rev.* 70, 460; S]**
- In the frame rotating at ω_rf:
  - dM/dt = γ M × B_eff − (M_x x̂ + M_y ŷ)/T₂ − (M_z − M₀) ẑ/T₁
  - B_eff = (B₁ cos φ, B₁ sin φ, B₀ − ω_rf/γ)
  - [corrected in review] **Sense of rotation.** With dM/dt = γM × B, free precession has angular velocity −γB₀ẑ, which is clockwise seen from +z when γ > 0. The formula above holds in a frame rotating at **−ω_rf ẑ**, so the lab-frame drive must be B₁(cos(ω_rf t − φ), **−**sin(ω_rf t − φ), 0) for γ > 0, and the opposite sense for γ < 0. B₁ is the amplitude of the *co-rotating* component; a linearly polarized coil field 2B₁ cos ωt contains it plus a counter-rotating part (Bloch–Siegert shift).
- Integrate with **Strang splitting**: an exact Rodrigues rotation about B_eff for h/2, then exact exponential relaxation for h, then the rotation for h/2 again. It is unconditionally stable at any κ.
- Rabi frequency f₁ = γB₁/2π. Pulse times: t_π/2 = 1/(4 f₁), t_π = 1/(2 f₁).
- Off resonance, the maximum transfer is f₁²/(f₁² + Δf²). [corrected in review: this is the maximum *inversion* probability, (1 − M_z,min/M₀)/2, not the maximum \|M_xy\|.]
- **Worked values [C]** (γ′_p):

| Case | Result |
|---|---|
| B₁ = 1 µT | f₁ = 42.576 Hz, t_π/2 = 5.872 ms, t_π = 11.744 ms |
| B₁ = 0.1 µT | t_π/2 = 58.72 ms |
| B₁ = 10 µT | t_π/2 = 0.587 ms |
| Δf = 10 Hz with f₁ = 42.576 Hz | f_eff = 43.735 Hz; maximum inversion probability P = (1 − M_z,min/M₀)/2 = 0.9477 [corrected in review: was "maximum M_z → M_xy transfer". B_eff is tilted θ = 76.8° from z, so M sweeps a cone up to 2θ = 153.6° and does reach the transverse plane: the maximum \|M_xy\| is 1.] |

- **FID and echo.**
  - FID: M_xy(t) = M⊥ e^(−t/T₂*) e^(−iω₀t).
  - Inhomogeneous dephasing: T₂* ≈ 1/(π Δf), Δf = γ′ G Δx.
  - Worked: a 10 cm sample in a 1 µT/m gradient gives Δf = 4.258 Hz and **T₂* ≈ 75 ms**. At 10 µT/m, T₂* ≈ 7.5 ms. Tap-water T₁ and T₂ are ~2–3 s [S].
  - [corrected in review] The formula T₂* = 1/(πΔf) is for a *Lorentzian* line of FWHM Δf. A linear gradient across a uniform sample gives a *rectangular* line, so the FID envelope is sinc(πΔf t), not an exponential. For Δf = 4.258 Hz it falls to 1/e at **164 ms** and has its first null at 1/Δf = **235 ms**, about 2.2× longer than 75 ms. At 10 µT/m the values are 16.4 ms and 23.5 ms. The 64-isochromat ensemble reproduces this automatically; label the readout "dephasing time", not T₂*.
  - Hahn echo (π/2 – τ – π) refocuses the gradient: the echo appears at 2τ with amplitude e^(−2τ/T₂) [Hahn 1950, *Phys. Rev.* 80, 580; S].
  - The gradient G can come from **field painting** (§5.7): two magnetometer readings 10 cm apart, with positions from ARKit.

**Honesty: why the phone cannot do real NMR [C]**
- Proton polarization at 50 µT and 298 K is P = γħB/(2kT) = **1.7 × 10⁻¹⁰**.
- Water's Curie magnetization is M₀ = Nγ²ħ²B/(4kT) = **1.6 × 10⁻⁷ A/m** (N = 6.67 × 10²⁸ m⁻³).
- Real Earth's-field NMR rigs prepolarize at ~20 mT (×400) and read µV signals in a coil of hundreds of turns. The phone has no coil and no prepolarizer, and its magnetometer samples at ~100 Hz, far below 2 kHz.
- **The Spin instrument is therefore MODEL driven by LIVE \|B\|.** The caption reads: "Your phone measures the field. The spins are simulated." Never imply the audio is a measured FID.

**Classical magnetic resonance with Gyre's own rotor** (no new physics code)
- Feed `env.magneticField = B₀ẑ + B₁(cos Ω_rf t, sin Ω_rf t, 0)` into the existing `GyroSim.step`.
  - [corrected in review] **Wrong rotation sense.** For magnet > 0, Gyre's rotor precesses clockwise about +B (physcheck #5 expects −μB/L). The drive above rotates the other way, so it is 2Ω₀ off resonance in the rotor's frame. Verified with `GyroSim.swift` compiled verbatim: with the drive as written, the tilt never exceeds **11.4°** (= 2·atan(10/100)). Use **B₁(cos Ω₀t, −sin Ω₀t, 0)** for magnet > 0 and the + sense for the Electron-like (negative) side; in general ω⃗_rf = −γ_rotor B₀. With the correct sense and launch tilt 0, the verbatim sim reaches tilt π/2 at **11.14 s** (theory 11.10 s, +0.3 %).
- With balance 0, gravity 0, friction 0, air 0, motor 1500 rpm and magnet 1:
  - L = 4.2412 × 10⁻³ J·s, γ_rotor = 14 147 rad s⁻¹ T⁻¹.
  - Ω₀ = 0.7074 rad/s (period **8.88 s**) in 50 µT.
  - B₁ = 10 µT at Ω_rf = Ω₀ tips the axis 90° in **t = π/(2γB₁) = 11.10 s** [C].
- This is the Purcell/Feynman spinning-magnet resonance demonstration, run on the very integrator that passes the Larmor check. The inertial nod (42.19 Hz at 1500 rpm, balanced) rides on top as a small fast wiggle. [corrected in review: 42.19 Hz is L₃/I₁. The field stiffens the nod to √((L₃/I₁)² + 4μB cosθ/I₁), and the verbatim sim measures 42.40 Hz in 50 µT at magnet 1.]
- **κ link:** γ′_p / γ_rotor = **1.89 × 10⁴** at 1500 rpm. The rotor is a proton slowed 19 000-fold, and its slowness is honest mechanics, not a display trick.

**Ethanol at Earth's field** (extends spectra-lab's `samples.js` NMR)
- Δδ(CH₂ − CH₃) = 3.69 − 1.22 = 2.47 ppm; J = 7.1 Hz. Δν/J at each field [C]:

| Spectrometer | B₀ | Δν | Δν/J | Regime |
|---|---|---|---|---|
| 400 MHz | 9.4 T | 988.6 Hz | 139 | first order: triplet + quartet |
| 60 MHz | 1.41 T | 148.3 Hz | 20.9 | first order |
| Earth | 50 µT | **5.26 mHz** | **7.4 × 10⁻⁴** | strongly coupled |

- In the strongly coupled homonuclear limit the J pattern collapses to one line, because the total-spin operators commute with I·I [S: standard NMR theory].
- **Add an "Earth" mode** to the NMR sample with B₀ = live \|B\|, drawn on a Hz axis. Caption: "Chemical shifts shrink with the field; J doesn't. At 2 kHz, ethanol is one line."

**Swift**
- `Core/Spin/Bloch.swift`: `enum Bloch { static func step(_ m: inout V3, h: Double, gamma: Double, bEff: V3, t1: Double, t2: Double, m0: Double) }`. It also holds `Pulse` (`.ninety`, `.oneEighty`, `.echo(tau)`, `.cw(sweep)`).
- `Core/Spin/SpinEnsemble.swift`: 64 isochromats spread by the painted gradient, so T₂* and the echo emerge from the physics rather than being imposed.
- `Core/Mechanics/GyroSim.swift` verbatim; the rotating B₁ comes from `GyroEngine`.
- `Audio/SpectraSynth.swift` `FIDVoice`: s(t) = A·\|M⊥(t)\|·cos(2π f_L t + φ). The carrier runs at audio rate at the **true** f_L; the envelope runs at control rate. Smooth \|B\| with τ = 0.25 s so magnetometer noise (resolution DEV?) doesn't warble the tone. Above 20 kHz (\|B\| > 470 µT: the 10 × 3 mm disc within ~4.7–4.9 cm, depending on how its field adds to Earth's [corrected in review: was "~4 cm"]), switch to spectra-lab's mapped pitch `110·2^(4(log₁₀f − 5.5)/16)` and badge it MAPPED. Worked: 1.40125 MHz maps to 123.0 Hz [C].

**UI: instrument "06 Spin"**
- **Hero.** Gyre's bubble (thin-film sky window, layout-driven camera). Skins on the object shelf (`ObjectTile`):
  - *Gyroscope*: holo-metal, classical γ.
  - *Spin*: Bloch arrow and precession cone, ensemble M.
  - *Top*: titanium, gravity analogue.
  - *Earth*: dipole globe, §5.3.
  - Wireframe.
- **Console pages** (`.pickerStyle(.tabs)`, four knobs per row):
  - **Field**: B₀ source (switch: Live \|B\| / Manual), Magnet μ (−1…1; detents Electron-like −1, Off 0, Real NdFeB 0.138, Fantasy 1), Gravity (Gyre's detents), Time κ.
  - **Drive**: B₁ (0.1–10 µT, log), RF offset Δf (−50…+50 Hz; "On resonance" detent at 0), Phase φ, and the buttons π/2, π, Echo, Sweep.
  - **Relax**: T₁, T₂ (0.01–5 s, log), Gradient (Live painted / Manual, µT/m), Isochromats.
  - **Listen**: FID level, Pitch (switch: True / Mapped), Rotor hum, Haptic hum.
- **Readout chips** (TelemetryCard):
  - "\|B\| 50.0 µT · cal high"
  - "¹H 2128.8 Hz"
  - "e⁻ 1.4013 MHz · AM band" (append "AM band" only while 530 kHz ≤ f ≤ 1700 kHz [corrected in review])
  - "e⁻ cyclotron 1.3996 MHz"
  - "Rotor Ω 0.113 Hz · γ = 14 147 rad/s/T"
  - "Rotating frame @ 2128.8 Hz" (R3)
- **Field trips:**
  - Gyre's nine experiments: Spinning top, Free gyroscope, Moon, Jupiter, Hanging gyro, Magnetic compass, Slow motion, Wind-down, Zero-g.
  - "Your field, as a proton hears it"
  - "Magnetic resonance with a gyroscope" (rotor + rotating B₁)
  - "π/2 and π pulses"
  - "Spin echo"
  - "Electron in Earth's field (AM band)"
  - "g − 2: cyclotron vs spin" (§5.4b)
  - "Real NdFeB rotor"
  - "Ionosphere electrons" (§4.10)

### 4.2 Phone attitude = antenna attitude (KEEP, refined)

**Frames**
- Use Gyre's `MotionSample.attitude` q (phone → world, Z up), including its quaternion convention check (`invertAttitude`).
- Phone axes: x right, y toward the top, z out of the screen.
- Use `.xMagneticNorthZVertical` when the magnetometer is calibrated, so azimuths mean something. Otherwise fall back to Gyre's `.xArbitraryCorrectedZVertical`.
- The pattern G(û) and polarization p̂(û) are defined in the phone frame. Direction to the reference in the world is ŵ, so in the phone frame it is û = q⁻¹ ŵ.
- Received factor = G(û) · PLF with PLF = \|p̂_w · ρ̂_ref\|² (`rf-physics.md` A.15 [V]), where p̂_w = q p̂(û) is projected onto the plane ⊥ ŵ.

**Worked values [C]**

| Case | Result |
|---|---|
| PLF at mismatch 30° | −1.249 dB |
| PLF at 45° | −3.010 dB |
| PLF at 60° | −6.021 dB |
| PLF at 80° | −15.207 dB |
| PLF at 89° | −35.163 dB (display clamp −40 dB) |
| *Roll* a vertical λ/2 dipole 60° about the line of sight | Pure polarization loss −6.02 dB; gain toward the source unchanged |
| *Pitch* it 60° toward the source | Polarization stays matched, but the source now sits 30° off the dipole axis: F²(30°) = [cos(π/2·cos30°)/sin30°]² = **−7.58 dB** |

- The roll and pitch cases show the two mechanisms separately. Readouts must split "pattern" and "polarization" dB.

**Phased-array beam steering by tilting** ("beam lock")
- AF_n = sin(Nψ/2)/(N sin(ψ/2)), ψ = kd cosθ + β, steering β = −kd cosθ₀ (`rf-physics.md` A.11 [V]).
- **Worked [C]** for N = 8, d = λ/2:
  - Yaw the phone 30°. The tower moves from broadside (θ = 90° from the axis) to θ = 60°.
  - **Unsteered, AF = 0: the tower sits exactly in the first null.** At 6.4° off broadside it is already −3.0 dB. [corrected in review: this is the **second** null. The nulls fall at ψ = 2πk/N. k = 1 gives cos θ = 0.25, so θ = 75.5°, which is 14.5° off broadside. k = 2 gives θ = 60°, the tower. Yaw by 14.5° to hit the first null.]
  - Re-steering needs β = −90.000° and restores the peak. HPBW at that scan is 14.84° (A.11 test).
  - Element pitch: λ/2 = 5.353 mm at 28 GHz, 3.843 mm at 39 GHz.
- **Coherence:** this is Gyre's free-gyroscope lesson in phase. A balanced gyro keeps its axis fixed in space while the phone turns, and a locked beam keeps its direction fixed in space while the array turns.
- Modes:
  - *Follow phone*: no re-steer.
  - *Lock beam*: compute θ₀ from q every frame and set β.
- Show β per element as small phasor clocks, which are the IQ view again.

**Live BLE comparison: the turntable experiment**

[!] A single RSSI stream cannot separate the antenna pattern from multipath. Present it as an experiment with statistics, never as a measured pattern:
1. Lay the phone flat and rotate it slowly about z (on a lazy Susan, or by fingertip) through n ≥ 3 turns. Bin RSSI by yaw (36 bins of 10°). Require ≥ 8 samples per bin.
2. Plot mean ± σ per bin against the MODEL pattern for the chosen band. Report the front-to-back ratio and its σ.
3. Expected fading spread for pure Rayleigh is σ(10 log₁₀ X) = (10/ln 10)·π/√6 = **5.57 dB** [C]. If the measured per-bin σ is about 5.6 dB, tell the user honestly that the pattern is buried in fading.
4. Notes in copy:
   - LE adverts hop across channels 37/38/39 (2402/2426/2480 MHz, λ = 12.48/12.36/12.09 cm [C]), so successive samples see different fades.
   - The hand and body add several dB of loss [S; `rf-physics.md` A.13 gives a 40–70 % efficiency range].
   - Real base stations use ±45° slant dual polarization and phones have several antennas [S], so the live polarization effect is far smaller than the single-reference model's −15 dB at 80°. Indoor multipath depolarizes further.

**Swift**
- `Core/RF/AntennaPose.swift`: `func linkFactor(pattern: AntennaPattern, attitude: simd_quatd, toward w: V3, ref: Polarization) -> (gainDB: Double, plfDB: Double)`. Pure, Sendable, in Core.
- `Core/RF/ArraySteering.swift`: `beta(thetaDeg:spacingWavelengths:)` and `af(_:)`.
- The turntable uses `RingTrail` plus a `YawBinner` in the BLE node.

**UI**
- RF Lab antenna view, with the reference direction set by one of:
  - "Aim the top of your phone at it and tap Mark", or
  - automatically from an AR-placed transmitter (§4.7).
- Knobs: Reference polarization (switch: V / H / +45 / −45 / RHCP / LHCP), Hold (switch: Phone / Lock beam / Off), Elements N, Spacing d/λ.
- Readouts: "Pattern −7.6 dB · Polarization −0.0 dB · β −90°".
- The BLE node has a **Turntable** card.
- The haptic hum follows the link factor, so you feel the null as you sweep through it.

### 4.3 Magnetometer as a live ELF probe (KEEP, sampling rewritten)

**Sampling**
- [!] Gyre's per-frame pull is right for attitude but wrong for spectra.
- Use `CMMotionManager.startMagnetometerUpdates(to:withHandler:)` (raw µT, includes hard-iron bias, which doesn't matter for AC) at the minimum `magnetometerUpdateInterval`. Timestamp each sample with `CMLogItem.timestamp` and write it into a `Mutex`-guarded ring (Gyre's `MicListener` ring shape).
- [corrected in review] The 39.8 Hz figures below assume an illustrative fs = 99.8 Hz. The real fs and any internal anti-alias filtering are DEV? (`rf-physics.md` F.3 review note on the magnetometer).
- Measure fs from the timestamp deltas and display it ("fs 99.8 Hz, measured").
- Use the calibrated `CMDeviceMotion.magneticField` for the DC vector and \|B\|.

**Aliasing** f_a = \|f − fs·round(f/fs)\| (`rf-physics.md` G.3 [V]). Worked [C]:

| fs | 50 Hz | 60 Hz | 100 Hz | 120 Hz | 180 Hz | 300 Hz |
|---|---|---|---|---|---|---|
| 100 Hz | 50 (Nyquist) | 40 | 0 | 20 | 20 | 0 |
| 99.8 Hz | 49.8 | **39.8** | 0.2 (slow beat) | 20.2 | 19.6 | 0.6 |
| 120 Hz (Gyre's frame pull) | 50 | 60 (Nyquist) | 20 | 0 | 60 | 60 |

- FFT N = 512 at 99.8 Hz gives a 5.13 s window and 0.195 Hz bins. N = 1024 gives 10.26 s and 0.0975 Hz.
- An internal anti-alias filter could attenuate AC to invisibility (DEV?).
- **The same lesson appears twice.** The screen samples the gyroscope at 120 Hz exactly as the magnetometer samples the mains at ~100 Hz. Gyre's balanced rotor at 12 000 rpm nods at 337.5 Hz, which shows up as **22.5 Hz** at 120 fps [C] (§4.8). Show both folding diagrams with one shared component.

**Field magnitudes [C]**
- Earth: 25–65 µT. [corrected in review: this is NOAA's rounded range, and it is fine for copy. An IGRF-14 synthesis at the surface for 2026.75, computed in review, gives **22.0 µT** (South Atlantic Anomaly, 26.5° S 60° W) to **66.6 µT** (59.5° S 134° E). Use 20–70 µT for knob ranges and fakes. Dipole B₀ = 29.7 µT.]
- NdFeB disc 10 × 3 mm (Bᵣ 1.3 T, m = 0.244 A·m²), on axis: 390 µT at 5 cm, 48.7 µT at 10 cm, 6.1 µT at 20 cm, 1.8 µT at 30 cm. B = μ₀·2m/(4πr³).
- Two-conductor cord, 5 A, 4 mm spacing: 10 µT at 2 cm, 1.6 µT at 5 cm, 0.4 µT at 10 cm. B ≈ μ₀Is/(2πr²). A single wire would give 50/20/10 µT, which is why cords are quiet.
- Scale card linking to the Wave scope: spectra-lab's default source has E₀ = 1000 V/m, so its B₀ = E₀/c = **3.34 µT**. Full sunlight peaks at E₀ = 1013 V/m, B₀ = **3.38 µT** [C]. [corrected in review: 1361 W/m² is the solar constant above the atmosphere; at the ground (~1000 W/m²) E₀ ≈ 868 V/m and B₀ ≈ 2.9 µT. Sunlight is broadband and incoherent, so this is the amplitude of an equivalent monochromatic wave of the same intensity, not a "peak".] That is a fifteenth of the static field the magnetometer shows, oscillating at 545 THz.

**Gyre's Magnet knob**
- It stays the *rotor's* μ (Spin, §4.1). The probe's "magnet" is the real one in the user's hand.
- The probe gets its own knobs: Mode (switch: DC / AC / Both), Window N (256/512/1024), DC removal τ (0.5–10 s), Virtual fs (scrub 20–200 Hz to watch the alias move, with the folding diagram), and Gain (µT full scale, log).
- The Geiger crackle moves from the Magnet knob to this node's *Feel* output. Rate = clamp((\|B\| − baseline)/30 µT, 0, 30) s⁻¹ with **exponential** gaps (−ln U / rate). Gyre's uniform 0.3–1.7/rate jitter is not Poisson.

**Field lines**
- Gyre's `fieldLines` (seed spacing ∝ 1/√\|B\|, midpoint tracing, pulses along +B) draws the measured DC field in the ELF node view.
- With field painting (§5.7) it draws through interpolated measured samples instead of a uniform field.

**Swift**
- `Sensors/MagnetometerStream.swift`: `final class MagnetometerStream: Sendable`, with `Mutex<Ring<TimedV3>>`, `start(interval:)`, `drain() -> [TimedV3]`, `measuredRate`. [corrected in review: as specified this does not compile. A `Sendable` class cannot own the `CMMotionManager` that `start(interval:)` needs; the error is "stored property 'manager' … has non-Sendable type 'CMMotionManager'", verified in Swift 6 against the iOS 27 SDK. Split it into a `@MainActor final class MagnetometerSource`, which owns the manager and an `OperationQueue`, and a `final class SampleRing<T: Sendable>: Sendable { let storage = Mutex(Ring<T>()) }` captured by the handler. That split type-checks cleanly.]
- `DSP/UniformResampler.swift`: linear resampling onto a uniform grid when jitter exceeds 1 % (DEV?).
- `DSP/Spectrum.swift`: vDSP.FFT, shared with the mic and RSSI.

**UI.** The Magnetometer node is badged "LIVE · fs 99.8 Hz". Its Fourier view shows the PSD next to the folding diagram, labelled "you're seeing 60 Hz folded by sampling" (`sdk-sensors.md` §4.7).

### 4.4 Microphone, Drives → audio sources, voice modulation (KEEP; Drives → modulation matrix)

**Sources**
- The Microphone node outputs:
  - `audio` (48 kHz, from Gyre's ring)
  - `envelope` (Gyre's auto-floor follower, §7)
  - `onsets` (Gyre's 1.9× average + 0.004, 0.12 s refractory)
  - `scope` (Gyre's rising-zero-crossing trigger, 1024 window, 900-sample search, hysteresis 0.02/gain, 3 persistence sweeps, XY lag 48 samples = 1 ms)
- All carry the ANALOGY badge.

**Voice through the radio chain** (`rf-physics.md` D.1, D.2, C.1, C.6, B.1, B.2)
- Simulate in **complex baseband** at 48 kHz. The carrier f_c is a label; you can't synthesize GHz.
  - AM: s̃ = A[1 + m x(t)]
  - FM: s̃ = A exp(j 2π k_f ∫x dt)
  - QPSK: on μ-law PCM bits
- Channel: AWGN from the link budget, then Rayleigh fading with Doppler f_m = v f/c, then **PLF and pattern from the live attitude** (§4.2), then demodulation, then the speaker.
  - Demodulation: AM uses \|s̃\|. FM uses arg(s̃ₙ s̃*ₙ₋₁)·fs/(2πk_f).
- **Worked chain [C]:**

| Item | Value |
|---|---|
| Narrowband FM, Δf 5 kHz, f_m 3 kHz | β = 1.667, Carson B = 16 kHz |
| AM, m = 0.8 | P_t/P_c = 1.32, sideband efficiency 24.2 % |
| FRS-like 462.6 MHz, 27 dBm, log-distance n = 3.5 from 1 m; noise −174 + 10 log₁₀(12.5 kHz) + NF 6 = −127.0 dBm | CNR 33.8 dB at 500 m, 23.3 dB at 1 km, **12.7 dB at 2 km** [corrected in review: this is inconsistent with the FM row above. Δf = 5 kHz needs a 16 kHz Carson bandwidth, not 12.5 kHz. Either keep ±5 kHz and use a 16 kHz noise bandwidth (−126.0 dBm, so CNR 32.7 / 22.2 / **11.7 dB**, and −3.5 dB after the 80° roll), or use FRS's ±2.5 kHz deviation [S] (β = 0.83, Carson 11 kHz) and keep 12.5 kHz.] |
| FM threshold | ~10 dB CNR [S] |
| At 2 km, roll the phone to 80° (−15.2 dB PLF) | CNR −2.5 dB: the voice breaks into noise **because you turned the phone** |
| Walking 1.4 m/s | f_m = 2.16 Hz at 462.6 MHz, 11.39 Hz at 2.44 GHz |
| Rayleigh outage below mean −10 dB / −20 dB | 9.52 % / 0.995 % |
| Digital: 8 kHz × 8-bit μ-law (64 kb/s), QPSK, BER = Q(√(2E_b/N₀)) | 1.25 × 10⁻² at 4 dB, **2.39 × 10⁻³ at 6 dB (≈153 bit errors/s, audible clicks)**, 3.87 × 10⁻⁶ at 10 dB |
| Display | Symbol-level IQ scatter; errors applied to PCM at the analytic BER |

**Feedback guard (new)**
- Speaker → mic loops are inevitable on the built-in speaker. **Default to push-to-talk:**
  - Hold: record up to 4 s into the ring.
  - Release: transmit the clip and play it back.
  - The mic and speaker never overlap.
- Allow live duplex only when `AVAudioSession.currentRoute.outputs` is headphones or Bluetooth A2DP.
- Keep Gyre's `mic.ignoreOnsets(for: 0.2)` after every haptic transient.

**Swift**
- `DSP/Modem.swift`: `AMModulator`, `FMModulator`, `PSKModem`, `Demod`. Pure, with Float buffers, vDSP where useful.
- `Core/RF/LinkBudget.swift` (Friis, log-distance).
- `Audio/SpectraSynth` `DemodVoice` reads a `Mutex<Ring<Float>>`.

**UI.** In the RF Lab's "Message" slot, a Microphone node is dragged onto the Modulator's `message` input. Knobs: Mode (switch: AM / FM / QPSK), Depth m / Deviation Δf, Distance, Fading (switch: Off / Walk / Drive). The push-to-talk button is a large `.glassProminent` capsule.

### 4.5 Barometer → refractivity, horizon, Spectra's air (KEEP, honest weighting)

**ITU-R P.453-14 (08/2019) [V, read in the PDF this session]**
- n = 1 + N·10⁻⁶ (eq. 1).
- N = 77.6 P_d/T + 72 e/T + 3.75 × 10⁵ e/T² (eq. 2).
- Approximation N = (77.6/T)(P + 4810 e/T), within 0.02 % from −50 to +40 °C (eq. 7).
- e = H·e_s/100 (eq. 8), with e_s = EF·a·exp[(b − t/d) t/(t + c)] (eq. 9).
  - EF_water = 1 + 10⁻⁴[7.2 + P(0.0320 + 5.9 × 10⁻⁶ t²)].
  - a = 6.1121, b = 18.678, c = 257.14, d = 234.5 (water, −40 to +50 °C).
- Reference profile: N₀ = 315, h₀ = 7.35 km.

**Effective Earth radius**
- k = 1/(1 + a·dN/dh·10⁻⁶), a = 6371 km.
- The standard gradient −40 N/km gives k ≈ 4/3 and an effective radius of about 8500 km (ITU-R P.310 [V via search excerpt]).
- Radio horizon d = √(2 k a h).

**Worked values [C]**

| Conditions | N |
|---|---|
| 1013.25 hPa, 15 °C, dry | 272.87 |
| 1013.25 hPa, 15 °C, 50 % RH (e = 8.561 hPa) | 311.37 (eq. 2) / 311.36 (eq. 7) |
| 25 °C, 80 % RH | 370.64 |
| 835 hPa (Denver-like), 15 °C, dry | 224.87 |

- **Sensitivity at 15 °C:** ∂N/∂P = **0.269 N/hPa**; ∂N/∂e = **4.50 N/hPa**. Climbing one 3 m floor (−0.36 hPa) changes N by 0.1. **The barometer hardly moves N; humidity does.** Expose Temperature and Humidity as knobs, because no public API gives ambient T or RH (`sdk-sensors.md` §4.10).
- k(−40 N/km) = **1.3420**. Ducting threshold: dN/dh ≤ −1/a = **−157 N/km** (k → ∞).

| Antenna height h | Radio horizon (k = 4/3) | Geometric horizon |
|---|---|---|
| 1.5 m | **5.048 km** | 4.372 km |
| 11.5 m (three floors up) | 13.978 km | 12.105 km |
| 30 m (mast) | 22.576 km | 19.551 km |

- A phone at 1.5 m and a 30 m mast are mutually visible up to 27.6 km.

**Where the barometer earns its place (coherent links)**
1. **GNSS zenith hydrostatic delay** (Saastamoinen 1972 as given by Davis et al. 1985, IERS Conventions 2010 ch. 9 [V via search excerpt]):
   - D_hz = 0.0022768·P / (1 − 0.00266 cos 2φ − 0.00000028 H) m, with P in hPa.
   - Worked: **2.3070 m (7.70 ns)** at 1013.25 hPa, φ = 45°, H = 0. 1.903 m at 835 hPa, 40°, 1600 m.
   - Sensitivity: **2.28 mm per hPa**, so a 30 hPa weather swing moves GPS ranging by 6.8 cm.
   - This feeds the GNSS node (`sdk-sensors.md` §4.6).
2. **Oxygen absorption** (P.676, `rf-physics.md` B.7, ρ = 7.5 g/m³, 15 °C) [C]:

   | f | γ_o at 1013.25 hPa | γ_o at 835 hPa | Total at 835 hPa |
   |---|---|---|---|
   | 60 GHz | 14.502 dB/km | **12.270 dB/km** | 12.401 dB/km |
   | 28 GHz | 0.0183 dB/km | 0.0124 dB/km | 0.0845 dB/km |
3. **Height.** H = RT/(Mg) = 8434.7 m at 288.15 K, which is **8.32 m per hPa**. `CMAltitudeData.relativeAltitude` gives antenna height above the start point for the horizon card. Walk up three floors and the horizon grows from 5.05 to 13.98 km.
4. **Spectra's air medium.**
   - spectra-lab's `air` is a constant n = 1.000293 (valid above 200 nm); keep it for parity.
   - Add a Spectra-native `Medium.airHere(P, T, RH)`:
     - **Radio:** P.453 radio refractivity.
     - **Optical:** dry-air dispersion (Birch & Downs 1994 revised Edlén [S]): N = 282.76 at 400 nm, 277.84 at 550 nm, 275.81 at 700 nm (15 °C, 1013.25 hPa) [C], scaled by (P/1013.25)(288.15/T).
   - The **difference** is a teaching point. Dry air is 272.9 at radio and 277.8 at 550 nm, because electronic dispersion rises toward the UV. Water vapour's large radio term (3.75 × 10⁵ e/T²) is **orientation of the permanent dipole**. That contribution switches off above the vapour's microwave and far-IR rotational lines. For *liquid* water the same orientational physics appears as spectra-lab's Debye relaxation, τ = 8.27 ps → f = 1/(2πτ) = **19.24 GHz** [C].
   - [!] Same physics, different phase and timescale; don't conflate vapour lines with the liquid's Debye τ.
   - λ at 2.44 GHz in air (N = 311) is 38 µm shorter than in vacuum, and the excess delay is 1.04 ns/km.

**Swift**
- `Core/Air/Refractivity.swift`: `enum Refractivity { static func n(pressureHPa:tempC:rh:) -> (n: Double, nDry: Double, nWet: Double); static func kFactor(dNdh:) ; static func horizon(heightM:k:) ; static func zenithHydrostaticDelay(pHPa:latDeg:heightM:) }`.
- Gyre's `pressureKPa / 101.325` density factor survives only for the Spin rotor's air drag.

**UI.** An Air node with knobs Pressure (Live / Manual; "ISA 1013.25" detent), Temperature ("ISA 15 °C" detent), Humidity, and dN/dh (detents −40 standard (k = 4/3), 0 (k = 1), −157 ducting).
- Readouts: N, n−1 in ppm, k, horizon, ZHD and γ_o at the RF Lab's frequency.
- Spectrum tuner medium picker: "Air (here)".

### 4.6 One renderer, two line materials (KEEP)

**Pipeline** (Gyre skeleton, `design-gyre.md` §9)
- Targets: rgba16Float scene + depth32Float; bloom at ½ and ¼; composite with `softClip` into `currentEDRHeadroom` (≤ 3); `extendedLinearDisplayP3`; triple buffering.
- From Orbitals:
  - **non-blocking** `inFlight.wait(timeout: .now())` (drop the frame, keep the clock);
  - offscreen skip;
  - error surface (`RendererError` → `ContentUnavailableView`);
  - frame policy: 120 Hz only while a live Spin or gyroscope scene is visible, otherwise 60, and 30 on Low Power or thermal `.serious`.

**Unified segment**, 80 B; 32 768 per buffer is 2.6 MB × 3:

```swift
struct GlowSegment {          // mirrors Glow.metal
  var a: F4                   // xyz (bubble/world) or xy (points) ; w = width px
  var b: F4
  var ca: F4                  // rgb·intensity, alpha
  var cb: F4
  var style: F4               // glow 0…1, dash period, cumulative dash offset, hollow radius
}
```

**Two materials**, chosen with `MTLFunctionConstantValues` and drawn as sub-ranges of one buffer:

| | **Holo** (Gyre) | **Phosphor** (Orbitals) |
|---|---|---|
| Space | 3D, `viewProj`, depth test with no write, nudged 0.015 toward the eye | 2D screen points, ortho |
| Ends | **Butt caps** on polylines; round dot for a lone point | Analytic capsule; dashes (56 % duty); hollow particles; hot-core dots |
| Glow | core `1 − smoothstep(w−0.6, w+0.9, d)` + `0.45·exp(−d²/g²)`, g = 2.2w + 1.5 | `exp(−outside²/spread²)·glow·0.34`, spread = 1.4 + 3.1·glow |
| Blend | Additive, α = 0, so lines glow over the AR camera | Additive into HDR (not Orbitals' premultiplied over bgra8), so it gets the same bloom |
| CPU cues | Scan band (4.2 s sweep), flicker, depth cue (Reduce Motion off) | Fixed widths in points |
| Uses | Field lines, wavefronts, E/B arrows, antenna wire geometry, Bloch cone, trails | Fourier bars, scopes, ruler, **node-graph cables**, annotations |

**Meshes**
- Gyre's `metalFragment` (GGX/Smith/Schlick, anisotropic circular brushing, oxide film, IBL from the studio or the AR probe) is extended with a **dielectric** branch (F0 = 0.04) for PCB, FR-4 and radomes.
- Copper, brass, aluminium and gold come from the `base` reflectance.

**3D radiation lobes**
- `MeshBuilder.grid(rows: 64, cols: 128)` in (θ, φ).
- Radius r = max(0, (G_dB − G_max + 30)/30) by default (30 dB range; toggle to linear \|F\|).
- Normals by central differences inside the grid closure.
- Rebuild only when a signature (pattern parameters) changes, using Orbitals' signature-keyed cache. The attitude goes in the model matrix each frame.
- Material: holo glass. Fresnel rim and scan band come from the `metalFragment` glow path with base reflectance 0, tinted by the band hue (R2).
- **Iso-gain contours** at −3 dB (the HPBW) and −10 dB, drawn as holo lines traced on the grid.

**Node-graph cables** (phosphor material)
- Cubic Bézier, 24 segments.
- Dash offset advances at 30 pt/s × clamp(log₁₀(f/0.1 Hz), 0.5, 6), so ELF crawls and GHz races. The dashes are Gyre's packet streams and field-line pulses, re-expressed.
- Colour: the EM hue of the signal's frequency, or analogy phosphor (R2).
- Width 1.5–3 pt by level; glow follows the live envelope.
- Provenance badge dots at each cable end.

**Backgrounds.** Gyre's world-anchored `sky()` window for 3D scenes, and Orbitals' `instrumentFragment` grid for 2D instruments. One fullscreen triangle either way.

**Gyre-only effects**
- Kept for Spin: thin-film bubble, rim lensing, glass orb.
- Dropped elsewhere: projector cone, horizon ring (except in Spin and AR).

**Swift files:** `Rendering/SpectraRenderer.swift`, `Rendering/GlowGeometry.swift` (Gyre primitives + Orbitals `add/dot/path/gradientPath`), `Rendering/{Glow,Post,Materials,Backgrounds}.metal`, `Rendering/MeshBuilder.swift`.

### 4.7 AR true scale (KEEP)

**Controller**
- **Gyre's** Metal path: the captured YCbCr textures (zero copy through `CVMetalTextureCache`) are decoded in our own composite, so bloom, EDR and holo-metal reflections (`environmentTexturing = .automatic`, `AREnvironmentProbeAnchor`) all apply.
- **Orbitals'** wrapper: phase machine, readiness raycast throttled to 0.12 s, Move anchor / Scan a new space, camera-denied `ContentUnavailableView` with Open Settings, `@preconcurrency ARSessionDelegate` with `delegateQueue = .main`.
- Reject Orbitals' RealityKit `ARView` camera layer. It would bypass the HDR composite and duplicate the camera path.
- **One ARSession** serves:
  - placement;
  - `frameSemantics.insert(.sceneDepth)` for the LiDAR ToF node (`sdk-sensors.md` §4.11; 1 m gives 6.67 ns round trip);
  - `ARLightEstimate.ambientColorTemperature` for the Visible node;
  - UWB camera assistance via `NISession.setARSession(_:)` (`sdk-sensors.md` §4.4). Gyre's configuration (`worldAlignment = .gravity`, no collaboration) is the kind NI requires [S].

**True-scale wavelengths [C]** (sceneScale 1 m = 1 m):

| Signal | λ | λ/2 (dipole) | 0.47 λ (real dipole) | Reactive edge λ/2π |
|---|---|---|---|---|
| NFC 13.56 MHz (LOCKED) | 22.11 m | 11.05 m | 10.39 m | 3.52 m |
| FM 100 MHz | 3.00 m | 1.50 m | 1.41 m | 47.7 cm |
| LTE 700 MHz | 42.8 cm | 21.4 cm | 20.1 cm | 6.8 cm |
| GPS L1 1575.42 MHz | 19.03 cm | 9.51 cm | 8.94 cm | 3.03 cm |
| **BLE 2.44 GHz** | **12.29 cm** | **6.14 cm** | 5.77 cm | 1.96 cm |
| Wi-Fi 5.5 GHz | 5.45 cm | 2.73 cm | 2.56 cm | 0.87 cm |
| UWB ch 5 6489.6 MHz | 4.62 cm | 2.31 cm | 2.17 cm | 0.74 cm |
| UWB ch 9 7987.2 MHz | 3.75 cm | 1.88 cm | 1.76 cm | 0.60 cm |
| 5G n261 28 GHz | 1.07 cm | 5.35 mm | 5.0 mm | 1.7 mm |
| Visible 550 nm | — | — | — | Show in a "×10⁵ loupe" inset; never at room scale |

**Content**
1. **Wave at real λ.** A placed "transmitter" anchor and a ray from it to the phone. The E-field sinusoid is drawn with its true spatial period and animated at κ (R3).
   - Reflection off an ARKit vertical plane draws standing-wave nodes every λ/2 (6.14 cm at BLE), which pairs with RSSI painting (§5.7).
2. **Twin phone (Gyre's carry, re-purposed).** While carried, a virtual phone floats at Gyre's `carryOffset` (45 cm ahead) and mirrors the real phone's attitude, with its MODEL antenna lobes around it. Turn your phone and the twin's lobes turn.
   - At 45 cm you're far outside the reactive zone (1.96 cm at 2.44 GHz). Treating the whole 16 cm phone as the aperture, 2D²/λ = 0.42 m at 2.44 GHz [C]: the far field begins at about the carry distance.
3. **The placed transmitter is the reference direction.** It feeds §4.2 automatically (PLF, beam lock), so no manual "Mark" is needed in AR.
4. **The phone's antennas.** Draw the four frame segments, badged MODEL with the copy "frame segments act as antennas" (`rf-physics.md` F.2 [!]: Apple publishes no map). On the US A2849 only, the mmWave window sits on the right side [S]. Never name a band per segment.

**Swift.** `AR/SpectraARController.swift` takes Gyre's `frameState`, `place`, `pickUp`, `pinch` and `fakeFrame`, plus Orbitals' phases. `Core/ARSceneProjection.swift` is verbatim from Orbitals for 2D overlays.

**UI.** Every 3D instrument (Wave scope, Spin, RF Lab antenna) gets the AR toolbar button. Entering AR folds the console (Gyre). The banner uses Gyre's `ARBanner`.

### 4.8 Heavy top as an oscillator source; κ unified (KEEP)

**Gyroscope node outputs** (all MODEL · LIVE motion)

| Output | Rate | Notes |
|---|---|---|
| `tip` (complex) = e_x + i e_y in world axes | **960 Hz** | Taken at the substeps, not per frame |
| `spin` | control | rpm |
| `precession` Ω_p | control | `GyroSim.precessionRate` |
| `nod` frequency | control | L₃/I₁ |
| `strain` | control | \|ω_phone × L\|, for Feel |
| `L` | control | vector |
| `torque` τ | control | vector |

- The axle-tip trail seen from above **is an IQ plot**. Steady precession is a single line at Ω_p (a carrier offset). The inertial nod adds sidebands at roughly Ω_p ± ω_n, which looks like FM. [corrected in review: the nod is nearly *circular*, so in the complex IQ spectrum it is essentially **one** sideband, on the spin's side. The verbatim sim (3000 rpm, tilt 0.5, kicked) shows the carrier at 0.20 Hz, a line at **+39.1 Hz** at −26.6 dBc, and the mirror at −38.7 Hz only at −49.4 dBc. That is single-sideband-like, a second carrier, not FM's symmetric pair. This makes it a good IQ lesson: only a complex (I + jQ) display can tell the two sides apart.]

**Worked values [C]** (m = 60 g, R = 3 cm, so I₃ = 2.700 × 10⁻⁵ kg m²; `cageInertia` 2.5 × 10⁻⁶):

| Case | L₃ (J·s) | I₁ (kg m²) | Ω_p | ω_n |
|---|---|---|---|---|
| 3000 rpm, ℓ = 1.75 cm (balance 0.5) | 8.482 × 10⁻³ | 3.4375 × 10⁻⁵ | 1.2139 rad/s fast-top (exact slow root at tilt 0.3: 1.2197; physcheck measured 1.2201 at tilt 0.5) = **0.193 Hz** | **246.8 rad/s = 39.27 Hz** (L₃/I₁) [corrected in review: that is the g = 0 value. Under gravity, ω_n = cos θ·(Ω₊ − Ω₋) = √((L₃/I₁)² − 4mgℓ cosθ/I₁). That gives **244.4 rad/s = 38.90 Hz** at tilt 0.3. The verbatim sim measures 244.32 / 244.43 / 245.06 rad/s at tilt 0.02 / 0.3 / 0.8.] |
| 4000 rpm, balanced | — | — | — | 112.5 Hz: aliases to **7.5 Hz** if sampled at 120 fps |
| 12 000 rpm, balanced | — | — | — | 337.5 Hz → **22.5 Hz** at 120 or 60 fps |
| 12 000 rpm, inertia ×3, balanced | — | — | — | 376.7 Hz |

- The 960 Hz output rate (Nyquist 480 Hz) covers the 376.7 Hz worst case. [corrected in review: this holds in *simulated* time. With Gyre's Time knob above 1.27×, the wall-clock nod exceeds 480 Hz (753 Hz at 2×), so resample in sim time or scale the rate with D.] **Hence the tap at the substep loop**: `GyroSim.step` already runs n = ⌈dt·fastest/0.1⌉ RK4 substeps. Add an optional `onSubstep: ((Double, V3) -> Void)?` and resample to 960 Hz in `GyroEngine`. This is one adapted line in an otherwise verbatim file.
- Inputs: `gravity` scale, `B` vector (Magnetometer or Spin drive), `torque` (control), `kicks` (events; Gyre's `kick(strength:)`), κ.

**κ, unified** (R3). spectra-lab defines κ = display cycles per second of reference source A (`state.js`: `timeScale = speed / f_ref`). Gyre's Time knob (0.05–2×) is D directly. Spectra keeps **one κ knob** whose reference oscillator depends on the instrument:

| Instrument | f_ref | Default mapping | Example D |
|---|---|---|---|
| Wave scope, tuner | source A | κ-slowed | 545 THz, κ = 1 → 1.83 × 10⁻¹⁵ |
| Spin, gyroscope skin | none | **real time** (D = 1); Gyre's 0.25 "Slow motion" detent survives as D | — |
| Spin, spin skin | f_L | **heterodyned** at f_rf; κ applies to the residual Δf | rotating frame @ 2128.8 Hz |
| Charges | f_c | κ-slowed | 1.40 MHz, κ = 1 → D = 7.1 × 10⁻⁷ |
| RF Lab IQ | f_c | heterodyned (baseband) | — |

- The transport always prints the active mapping: "Real time", "κ 1 · 1 : 1.8 × 10¹⁵", or "Rotating frame @ 2128.8 Hz". [corrected in review: D = 1.83 × 10⁻¹⁵ means the display is slowed **5.45 × 10¹⁴**-fold (= f_ref/κ). Print "κ 1 · slowed 5.5 × 10¹⁴×" or "1 s shows 1.8 × 10⁻¹⁵ s". "1 : 1.8 × 10¹⁵" overstates the slowdown 3.3×.]
- Gyre's honest blur (`markers`) is the generic **display anti-alias**: any phasor sweeping more than π per frame draws as an arc over the swept angle.

### 4.9 Haptics and HumSynth as feedback sinks (KEEP)

**`SpectraHaptics`** (`@MainActor`, singleton per Orbitals; `design-orbitals.md` §e)
- Pulses: Orbitals' table (touch 0.64/0.5, detent 0.43/0.86, release, boundary, success), plus Gyre's knob ticks (0.32/0.9) and detent (0.9/0.3).
- Continuous: Gyre's looping `CHHapticAdvancedPatternPlayer`, 30 s event, loop on, parameters ≤ 40 Hz, sharpness sent as an offset (−0.5).
- `spinUp()` curve verbatim.
- Global `strength` (default 0.85) and background stop from Orbitals.
- [!] Orbitals' rule "nothing runs continuously" is relaxed only while a **Feel** sink is connected and its instrument is on screen.

**Feel sink inputs**
- `intensity` and `sharpness` (control 0–1, mapped through the cable curve, §7).
- `events` → transients, with `minGap`.
- Default patches:
  - Gyroscope → Gyre's mapping: `0.1 + 0.34√spinNorm` × (1 + 0.6·nod) + 0.55·strain.
  - ELF probe → Poisson crackle.
  - Antenna link factor → hum intensity, so you feel the null.

**Hear sink: `SpectraSynth`**
- One `AVAudioEngine` and `AudioRoute` shared with the mic, from Gyre. Voices:
  - `RotorVoice`: Gyre's DSP verbatim (blade pass ×6, harmonics 0.55/0.17/0.06, xorshift noise, rumble, air band-pass, equal-power pan). The nod AM is **at the true nutation frequency × D**, replacing Gyre's `2·precession + 1.5 Hz`.
  - `FIDVoice` (§4.1): true pitch.
  - `ToneVoice`: spectra-lab's mapped pitch for any EM frequency. Worked: 60 Hz → 57.7 Hz, 2.44 GHz → 215.7 Hz, 545 THz → 545.1 Hz [C].
  - `DemodVoice` (§4.4).
  - `ClickVoice`: Geiger.
- Under Swift 6: `final class Controls: Sendable { let level = Atomic<Double>(0) … }` with `.relaxed` loads on the audio thread (iOS 18+ [V]). Per-voice DSP state is `final class VoiceState: @unchecked Sendable`, documented "audio-thread only".
- [corrected in review] **Build the `AVAudioSourceNode` render block in a `nonisolated` function** (for example `nonisolated static func makeNode(format:)`). The block type is `NS_SWIFT_NONSENDABLE`, so a closure literal written inside a `@MainActor` type (or under default MainActor isolation) inherits main-actor isolation. Swift 6 then traps when the audio thread calls it. This was reproduced in review: an offline-rendered `AVAudioSourceNode` formed in a `@MainActor` method died with SIGTRAP on its first off-main render, and the same node from a `nonisolated` factory rendered fine.
- Add the iOS 27 session notifications (`AVAudioSessionDidBecomeInactiveNotification` and `…ResumptionRecommendationNotification`, `design-gyre.md` §5), which Gyre lacks.

**Guards** (centralized in `FeedbackGuard`)

| Loop | Guard |
|---|---|
| Haptic → mic onsets | `ignoreOnsets(0.2 s)` (Gyre) |
| Haptic → accelerometer and gyro | Drop vibration-spectrum frames during a transient; mark them |
| Speaker → mic | Push-to-talk or headphones (§4.4) |
| Taptic Engine and speaker magnets → magnetometer | DEV? (§11). If confirmed, "Quiet capture" mutes haptics and synth during ELF FFT windows |

### 4.10 Dust motes → charged particles (REFINE; reject radiation pressure)

**Keep:** the motes become **charged particles in the live B field**.
- **Integrator:** Boris pusher [Boris 1970; Birdsall & Langdon, *Plasma Physics via Computer Simulation*; S]. It is exact for gyration and conserves energy in pure B: [corrected in review: it conserves \|v\| exactly in pure B, but it is **not** phase-exact. Each step rotates v by 2·atan(ω_c h/2) instead of ω_c h, so the gyrofrequency is low by ≈(ω_c h)²/12 and the orbit radius is high by ≈(ω_c h)²/8: 3.3 × 10⁻⁴ and 4.9 × 10⁻⁴ at 100 steps per orbit. For an exact f_c, replace t = (q/m)B h/2 with t = tan(ω_c h/2) B̂.]
  - v⁻ = v + (q/m)E h/2
  - t = (q/m)B h/2, s = 2t/(1 + t²)
  - v′ = v⁻ + v⁻ × t, v⁺ = v⁻ + v′ × s
  - v = v⁺ + (q/m)E h/2
- **Worked [C]**, electrons at 300 K (v_mp = √(2kT/m) = 9.54 × 10⁴ m/s) in 50 µT: [corrected in review: √(2kT/m) is the 3D most-probable speed. Used as v⊥, it equals the *RMS* perpendicular speed, the usual plasma v_th. The most probable v⊥ is √(kT/m), which gives r = 0.77 cm. State the convention on the readout.]
  - Larmor radius r = m v⊥/(eB) = **1.08 cm**; period 0.714 µs.
  - Gyre's bubble is 17 cm across (`sceneScale` 12/m), so **true-scale spirals fit**. Time runs at D = κ/f_c.
  - Bring the 390 µT magnet: r shrinks to 1.4 mm and f_c rises to 10.9 MHz.
  - Protons at 300 K: r = 46 cm, f_c = 762 Hz. Too big for the bubble, so show them in AR.
- **E × B drift:** with an E knob, v_d = E/B. For E = 1 V/m and 50 µT, v_d = **2 × 10⁴ m/s**.
- **Gyre's Air knob → collision frequency ν.**
  - At sea level, n = 2.55 × 10²⁵ m⁻³ and v̄ = 1.08 × 10⁵ m/s. With an assumed σ ≈ 10⁻¹⁹ m² [!], ν ≈ **2.7 × 10¹¹ s⁻¹**, against ω_c = 8.79 × 10⁶ s⁻¹. ω_c/ν ≈ **3 × 10⁻⁵**: electrons can't complete an orbit in air.
  - Gyration needs ω_c/ν ≈ 1, which happens at about **3 Pa**, the ionosphere's D-region pressures [C, order of magnitude]. [corrected in review: a cross-check uses the measured e–N₂ and e–O₂ momentum-transfer rates (Schunk & Nagy, *Ionospheres*, at T_e = 300 K) instead of σ = 10⁻¹⁹ m². That gives ν ≈ 1.6 × 10¹¹ s⁻¹ at sea level, ω_c/ν ≈ 5 × 10⁻⁵, and ω_c = ν at about **5.5 Pa** (roughly 70 km). Use "D layer ~5 Pa". The conclusion, gyration only in the D region and above, stands.]
  - Knob detents: Vacuum, "D layer ~5 Pa" [corrected in review: was ~3 Pa], "Sea level". The barometer pressure feeds the "Here" position.
  - Langevin kicks use the fluctuation–dissipation variance 2νkT/m·h, so Air and Temperature are consistent.
- **Temperature knob is shared** with the RF Lab noise floor kTB: −173.98 dBm/Hz; −113.98 dBm in 1 MHz; −110.96 dBm in 2 MHz; −133.0 dBm in 12.5 kHz [C]. It is one "noise temperature" across particle jitter and receiver noise.

**Brownian motion: keep only as a metaphor.** A 1 µm dust grain in air has σ_v = 1.99 mm/s and momentum relaxation in 6.1 µs, but it diffuses only √(2Dt) = **7.0 µm in 1 s** [C]. It is invisible at bubble scale, so any visible jitter carries a "×10⁴ magnified" badge.

**Reject radiation pressure** as a mote driver. In full sunlight (1361 W/m²), F = IA/c on a 10 µm grain is 3.6 × 10⁻¹⁶ N, against a weight of 5.1 × 10⁻¹² N: a ratio of **7 × 10⁻⁵** [C]. [corrected in review: that weight assumes density 1000 kg/m³, while the Brownian paragraph uses 2000. With 2000 the ratio is 3.5 × 10⁻⁵. 1361 W/m² is the top-of-atmosphere value; at the ground (~1000 W/m²) the ratio is 2.6 × 10⁻⁵. The rejection only gets stronger.] It stays as spectra-lab's `radiationPressure` readout in the Wave scope.

**Swift**
- `Core/Plasma/ChargedParticles.swift`: Double, Boris, species enum (electron, proton, O⁺).
- Walls reuse Gyre's bounce and static-friction code (`MoteField.step`) for the "dust" species only.

**UI.** The Spin bubble's "Charges" layer, with knobs Species (switch), Temperature, Air (collisions) and E. Readouts: r_L, f_c, ω_c/ν.

---

## 5. Added ideas

**5.1 Soap film → thin-film specimen (Matter bench).**
- Gyre's `filmInterference` is genuinely EM optics: a 420 nm base thickness draining toward measured gravity.
- Replace the two-beam 0.5 − 0.5 cos δ with the **Airy reflectance**: R = 2r²(1 − cos δ)/(1 + r⁴ − 2r² cos δ), r = (n − 1)/(n + 1), δ = 4πnd cosθ_t/λ.
- Take n from spectra-lab's water Cauchy fit (1.3251 + 2946/nm²): 1.3323, 1.3356 and 1.3396 at 640, 530 and 450 nm [C].
- Worked with n = 1.33 [C]:
  - d = 420 nm: R = 0.0412, 0.0092, 0.0769 at 640/530/450 nm (magenta).
  - d = 10 nm: R ≤ 0.003, the "black film".
  - Maximum R = 0.0771.
- The phone's tilt drains the film, which makes it a live gravity-driven interferometer. Badge it MODEL.

**5.2 Glass orb → real dispersion.**
- Replace Gyre's "Dispersion" knob with a material picker using `Medium.index(λ)` per channel [C]:

| Material | 450 nm | 530 nm | 640 nm |
|---|---|---|---|
| Fused silica (Malitson 1965) | 1.46557 | 1.46080 | 1.45681 |
| N-BK7 (Schott) | 1.52532 | 1.51958 | 1.51485 |

- Frost and Refraction (shell thickness) remain artistic knobs, badged so.

**5.3 Planet skin → Earth's dipole from your own sensors.**
- Gyre already has both gravity and B in the world frame. The dip angle is I = atan2(B·(−ẑ_up), \|B_horizontal\|). A dipole gives tan I = 2 tan λₘ and \|B\| = B₀√(1 + 3 sin² λₘ), with B₀ ≈ 30 µT [S].
- Worked [C]: I = 66° → λₘ = 48.3°, \|B\| = 49.0 µT. I = 60° → 40.9°.
- The globe shows your inferred magnetic latitude (INFERRED badge) next to the measured \|B\|.
- Gyre's fieldLines with its dipole term (`3(a·r̂)r̂ − a`/r³) draws the magnetosphere.

**5.4 (a) The phone chassis is a dipole.**
- Below about 1 GHz, the handset ground plane is the main radiator. Length 159.9 mm gives c/2L = **937 MHz** [C; Vainikainen et al., IEEE TAP 50(10), 2002, S], so low-band LTE radiates roughly like a dipole along the phone's y axis.
- This is the MODEL default for §4.2 below 1 GHz. Above 2 GHz, use the PIFA or a lumpy pattern, badged MODEL.

**5.4 (b) g − 2 in Earth's field.**
- Electron cyclotron and spin precession differ by a factor 1 + a_e = 1.0011597 [V].
- In 50 µT: f_c = 1.39962 MHz, f_s = 1.40125 MHz, beat f_a = a_e f_c = **1623 Hz** [C]. This is the principle of the g − 2 experiments.
- For the proton the orbit/spin ratio is μ_p/μ_N = 2.7928 [V]: 762 Hz cyclotron vs 2129 Hz Larmor.
- Spin field trip: two arrows, one orbiting and one precessing, slowly drifting apart.

**5.5 Beam lock is the gyroscope of phase** (§4.2): the Free gyroscope experiment and Lock beam share one animation idiom.

**5.6 Extend the spectrum ruler.**
- spectra-lab's ruler stops at λ = 1 km (`LOG_MAX = 3`). Gyre brings sources far below it [C]:

| Source | λ |
|---|---|
| Earth-field ¹H | 140.8 km |
| 60 Hz | 4997 km |
| 50 Hz | 5996 km |
| Schumann 7.83 Hz | 38 288 km |
| Electron ESR | 213.9 m (on the ruler) |

- Add a Spectra-native extended range to log₁₀λ = 8, with detents at mains, Earth-field NMR, the AM band and the Schumann resonance. Parity tests stay inside [−13, 3].

**5.7 Field painting** (experiment, AR + LIVE).
- Tag each magnetometer sample and each BLE RSSI sample with the ARKit camera position. Assume the sensor offset inside the phone is 0, about 5 cm of error [!].
- Accumulate mean and variance in 5 cm voxels.
- B: draw measured arrows, plus Gyre field lines through an inverse-distance-weighted `fieldAt`, and a gradient estimate for T₂* (§4.1).
- RSSI: coloured voxels. Slow sweeps can reveal ~λ/2 (6 cm) fading structure, but ±5.6 dB fading and 1 dB quantization make this DEV?.

**5.8 Rejected extras**
- Using the speaker coil as a magnetic transmitter for the magnetometer: 2 kHz is far above the ~50 Hz Nyquist. [corrected in review: being above Nyquist is not by itself a reason. By this doc's own lesson (§4.3), an unfiltered 2 kHz tone would *alias* rather than vanish. The real reasons are that the sensor's internal filtering and the coil's stray field are unknown, and that the result would not be repeatable. It stays a DEV? interference check (§11 item 2).]
- MRI imaging: no gradient coils, no signal.
- Gyre's Planet precession (25 772-year Earth axis) as a feature: mechanics, not EM. Keep it only as a caption on the Earth skin.

---

## 6. Node catalogue (Gyre-derived)

| Node | Badge | Inputs | Outputs (rate) |
|---|---|---|---|
| Motion | LIVE / SIM | — | attitude q, rotationRate, gravity, userAccel (frame); vibration (100 Hz, DEV?) |
| Magnetometer | LIVE / SIM | — | B vector (fs ≈ 100 Hz, timestamped), \|B\|, dip I, fs_measured, calibration |
| Barometer | LIVE / SIM | — | P kPa (~1 Hz), relative altitude m |
| Microphone | LIVE (ANALOGY) | — | audio 48 kHz, envelope, onsets, scope |
| BLE | LIVE / SIM | — | per-device RSSI series (timestamped), Tx power if advertised, yaw-binned pattern |
| Gyroscope | MODEL · LIVE motion | gravity, B, torque, kicks, κ | tip IQ (960 Hz), spin, Ω_p, nod, strain, L, τ |
| Spin | MODEL · LIVE \|B\| | B₀, B₁ (IQ), Δf, pulses, T₁, T₂, gradient | FID (audio, true pitch), M vector, f_L, IQ (heterodyned) |
| Charges | MODEL · LIVE B, P | B, E, T, Air | positions (frame), f_c, r_L, ω_c/ν |
| Air | MODEL · LIVE P | P, T, RH, dN/dh | n, N, k, horizon, ZHD, γ_o(f) |
| Antenna (RF Lab, extended) | MODEL | **attitude q**, reference direction (Mark or AR), polarization | gain toward the reference, PLF, β per element |
| Modulator / Demodulator (RF Lab) | MODEL | message (audio), carrier, mode | IQ, audio |
| Envelope | utility | audio | control (Gyre's follower) |
| Feel | sink | intensity, sharpness, events | — |
| Hear | sink | audio, or pitch/level/pan | — |

---

## 7. Modulation matrix: "Drives", generalized

Gyre's Drives switch (Gravity, Air, Spin, Kicks, Film), with Listen as depth, is a hard-wired 1 × 5 modulation matrix. Spectra generalizes it to **any control output → any knob**.

**Conditioner** (audio → control): Gyre's `envelope()`, verbatim.

```
dB = 20 log10(level·gain); raw = clamp((dB + 55)/45, 0, 1)
floor: τ 0.4 s falling, 20 s rising
above = max(0, raw − floor − 0.04)/max(1 − floor, 0.25)
env: attack 30 ms, release 350 ms → min(1.5·above, 1)
```

The auto-floor is why steady hums (including the rotor's own) don't drive anything.

**Application in knob position space** (new; it makes log knobs modulate musically):

```
p = clamp(spec.position(of: base) + depth·cv, 0, 1); value = spec.value(at: p)
```

Gyre's `p.gravity += depth·m·2` becomes Gravity knob depth 0.5 (the range −1…3 spans 4 g).

**Events:** onsets and packets go to impulse inputs. Gyre's `kick` and `applyImpulse` scale with \|L\| (`clamp(0.4·|L|, 0.0008, 0.0065)`).

**Default patches** (Gyre's five, preserved):
- Mic → Gyroscope.gravity
- Mic → Gyroscope.air (+ turbulence)
- Mic → Gyroscope.torque along the axis
- Mic.onsets → Gyroscope.kicks
- Mic → Bubble.film

**New natural patches** (each one is a modulation-theory lesson):
- Mic → Source A E₀ (AM of light)
- Mic → Source A λ (FM: whistle and the colour wobbles)
- Mic → Spin B₁
- Gyroscope.tip → Antenna steering
- BLE RSSI envelope → Feel

**UI**
- Each modulated `GlassKnob` gets a second `KnobArc` showing the live modulated position, dashed, in the cable's colour.
- Long-press a knob → "Modulate from…" menu.
- `KnobReadout` adds "Driven by Microphone · depth 50 %".

---

## 8. Simulator fakes, extended

Rules:
- Gate every fake behind `#if DEBUG` (`design-house-rules.md` §4) and document it in the README.
- Each fake implements the same `SensorSource` protocol and **writes into the same ring with real timestamps at the real rate**, so downstream code (including aliasing) behaves identically. This is Gyre's `-fakeMic` principle.
- All fakes are badged **SIM**. `-seed N` makes them deterministic. They run on a shared `SimClock`.

| Argument | Fakes | Behaviour |
|---|---|---|
| `-simSway` (kept), `-simPose p,y,r` | Motion | Gyre's sway (0.9 sin 0.31t yaw, …); a fixed pose for screenshots |
| `-fakeMic[=room\|voice\|tone:F]` | Mic | `room` = Gyre's chord (196/294/392 Hz = G3–D4–G4, an open fifth rather than a major triad [corrected in review]; swell 0.18 Hz) + 1.6 s clap (unchanged). `voice` = a glottal pulse train at 110–180 Hz through F1/F2 formants (700/1200 Hz), for AM/FM/QPSK tests. `tone:1000` for FFT calibration. |
| `-fakeMag[=earth\|hum60\|hum50\|magnet\|magsafe]` | Magnetometer (raw + calibrated) | `earth`: Gyre's (0, 22, −40) µT rotated by the simulated attitude. `hum60`: + 1.6 µT at 60 Hz + 0.4 µT at 120 Hz, sampled at **99.8 Hz ± 2 % jitter** → lines at 39.8 and 20.2 Hz. `magnet`: the 0.244 A·m² dipole approaching from 30 to 5 cm over 10 s (1.8 → 390 µT). `magsafe`: a static step + `batteryState = .charging` (tests the INFERRED path). |
| `-fakeBLE[=N]` (alias `-fakeRadio`) | BLE | N beacons placed in a virtual room. RSSI = 0 dBm − 40.20 dB(1 m @ 2.44 GHz) − 10·n·log₁₀d (n = 3) + G_phone(q, û) − PLF + Rayleigh(f_m from the simulated motion), 1 dB quantization, occasional 127 ("unavailable"). **The turntable experiment and polarization effects are testable.** Gyre's 11 radios and beacon intervals are kept. |
| `-fakeCell[=lte,nsa,sa,mmwave]` | Cellular | Steps through RATs every 15 s via the typed iOS 27 notification path; `PathReport.radioType` sub-6/mmWave; RTT 20–60 ms |
| `-fakeWiFi` | Wi-Fi | `linkQuality` cycles unknown/minimal/moderate/good; `.ax` |
| `-fakeNFC` | NFC (LOCKED) | Every 8 s, a simulated `.miFare` tap event (fixed fake UID) drives only the **model** (13.56 MHz loop coupling, 1/r³). The node stays LOCKED and the caption says "Simulated tag" (`sdk-sensors.md` §4.5). |
| `-fakeUWB` | UWB (NEEDS PEER) | Peer at d(t) = 1.5 + 1.0 sin 0.2t m, horizontal angle swinging ±40°, convergence passing through `.notConverged([.insufficientHorizontalSweep])` |
| `-fakeBaro[=still\|stairs\|weather]` | Barometer | `stairs`: −0.36 hPa per 3 m floor every 20 s. `weather`: ±15 hPa over 10 min (moves ZHD by ±3.4 cm) |
| `-fakeGNSS` | GNSS | Location from `simctl location`; horizontalAccuracy random walk 3–15 m |
| `-fakeLight[=K,lux]` | Camera/ARKit light | CCT 3100 K, 300 lux by default |
| `-fakeAR` (kept) | ARKit | Gyre's synthetic camera and room; adds a fake `sceneDepth` (a wall at 1.2 m) and a fake environment probe |
| `-fakeAll`, `-scenario kitchen\|desk\|stairwell` | Bundles | `kitchen`: hum60, a 2.45 GHz "oven" burst source in BLE, and magnet. `desk`: earth, 8 BLE, Wi-Fi good. `stairwell`: baro stairs plus BLE fading. |
| `-startMic`, `-startAR` (kept), `-startLive <node>`, `-open <instrument>` | Launch | Deterministic UI tests and screenshots |

---

## 9. Swift 6 port notes (Gyre was Swift 5)

| Gyre construct | Problem under strict concurrency | Fix |
|---|---|---|
| `HumSynth.Controls` plain `var Double`s read on the audio thread | Data race across isolation | `final class Controls: Sendable { let x = Atomic<Double>(0) }`, with `load/store(ordering: .relaxed)` [V: iOS 18+] |
| `AVAudioSourceNode` closure capturing `Voice` | Sendable closure capturing non-Sendable state | `final class VoiceState: @unchecked Sendable`, touched only on the render thread (documented) |
| `MicListener` `NSLock` + ring | Fine, but non-Sendable class used across threads | `Mutex<Ring>` (Synchronization, iOS 18) in a `final class: Sendable`; `installAudioTap` closure copies out of the `Span` |
| `Haptics` handlers hopping with `DispatchQueue.main.async` | Main-actor state touched from a `@Sendable` closure | `@MainActor` class; handlers use `Task { @MainActor [weak self] in … }` (Orbitals) |
| `RadioSense: NSObject, CBCentralManagerDelegate` with `queue: nil` | Delegate on main, not declared | `@MainActor` class + `@preconcurrency CBCentralManagerDelegate`, or a dedicated queue + `Mutex` |
| `ARController` delegate on `.main` | Same | `@MainActor` + `@preconcurrency ARSessionDelegate` (Orbitals) |
| `CMAltimeter` handler on `.main` | OK | Keep, inside a `@MainActor` source |
| `GyroSim`, `MoteField` | Non-Sendable mutable classes | Fine if owned by the one `@MainActor` engine and never sent. `physcheck` compiles them in a CLI unchanged. |
| `GyroModel @Observable` + `@ObservationIgnored` engine state | — | Keep the pattern; add `@MainActor`. Telemetry stays a 10 Hz `Equatable` struct. |

[corrected in review] **What Swift 6 actually rejects.** Every Gyre source file was type-checked as the primary file, with `-swift-version 6` against `iPhoneOS27.0.sdk` and the platform macro plugins, using the default (nonisolated) isolation. The compiler reports exactly **five errors in three files**, which the table above mostly misses:
1. `Model/Knobs.swift:105/189/253`: `static let physics/sound/glass: [KnobSpec]` is "not concurrency-safe because non-'Sendable' type '[KnobSpec]'". `KnobSpec` holds `Color` and a `ReferenceWritableKeyPath`. Fix: make the static tables `@MainActor` (the generic `KnobSpec<Root>` will hit the same error).
2. `Sensors/MicListener.swift:8`: `AudioRoute.recording` is a `static var`, which is global mutable state. Fix: `@MainActor`, or move it into the `Mutex`.
3. `Sensors/RadioSense.swift:45`: the `NWPathMonitor` handler captures `self` inside `DispatchQueue.main.async`, which is a `@Sendable` closure. Fix: the `@MainActor` class plus `Task { @MainActor in }` from the table.

The rows "`HumSynth.Controls` … data race" and "`AVAudioSourceNode` closure … Sendable closure capturing non-Sendable state" describe **no compile error**: the render block is `NS_SWIFT_NONSENDABLE`. Keep the `Atomic` fix for correctness. The real Swift 6 hazard is a runtime one: a render block formed in a `@MainActor` context traps off the main thread (§4.9).

---

## 10. Test oracles

These are the `Tools/physcheck` (Gyre, verbatim, 8 checks) and new `Tools/spincheck` cases, written as XCTest-compatible numbers.

| Check | Inputs | Expected | Tolerance |
|---|---|---|---|
| Proton Larmor (shielded) | B = 50 µT | ~~2128.8193 Hz~~ **2128.8192715 Hz** [corrected in review: the printed values carry 7–8 significant figures and fail a 1e-9 relative test] | 1e-9 rel |
| Electron Larmor | 50 µT | ~~1.401248 MHz~~ **1.401247569305 MHz** [corrected in review: the old value is off by 3.1e-7] | 1e-9 rel |
| Electron cyclotron | 50 µT | ~~1.399624 MHz~~ **1.3996244917 MHz**, with CODATA 2022 m_e = 9.109 383 7139 × 10⁻³¹ kg [corrected in review: `e_gyre.py` uses the 2018 m_e (…7015), which moves f_c by 1.36e-9] | 1e-9 rel |
| f_s/f_c | — | 1 + a_e = 1.00115965218 | 1e-11 (holds to 5e-14 only if m_e, γ_e and a_e are all CODATA 2022; with the 2018 m_e it fails by 1.36e-9 [corrected in review]) |
| Bloch π/2 | B₁ 1 µT, on resonance, no relaxation, t = 5.8718 ms | M_z/M₀ < 1e-6 | — |
| Off-resonance maximum inversion (1 − M_z,min/M₀)/2 [corrected in review: was "maximum transfer"; max \|M_xy\|/M₀ is 1 here] | f₁ 42.576 Hz, Δf 10 Hz | 0.94772 | 1e-4 |
| FID decay | T₂ = 1 s, t = 1 s | \|M⊥\| = e⁻¹ | 1e-6 |
| Echo | 64 isochromats, G 1 µT/m over 10 cm, τ = 50 ms, T₂ = 2 s | echo / FID(0) = e^(−0.05) | 1e-3 |
| Rotor resonance (`GyroSim` verbatim) | 1500 rpm, magnet 1, balance 0, g 0, friction 0, air 0, B₀ 50 µT ẑ, B₁ 10 µT rotating at Ω₀ = 0.7074 rad/s | tilt 0.1 → π/2 at t = 11.10 s **[superseded in review: fails as written, see next row]** | ±5 % |
| ↳ [corrected in review] | Same, but B₁ = 10 µT·(cos Ω₀t, **−**sin Ω₀t, 0) (co-rotating with the clockwise precession), launch **tilt 0** | first tilt ≥ π/2 at 11.10 s (verbatim sim: 11.14 s) | ±2 %. A start at tilt 0.1 gives 10.43–11.85 s depending on the B₁ phase, so it is ill-posed at ±5 %. With the + sense the tilt never exceeds 11.4°; keep that as a negative test. |
| Rotor γ | 1500 rpm | 14 147 rad s⁻¹ T⁻¹; Ω₀ 0.7074 rad/s | 1e-3 |
| Nutation | 3000 rpm, ℓ 1.75 cm | ω_n 246.76 rad/s **[superseded in review: fails at g = 1, see next row]** | 1e-3 |
| ↳ [corrected in review] | Same with **gravity 0** (or g = 1, tilt 0.3: expect √((L₃/I₁)² − 4mgℓcosθ/I₁) = 244.43 rad/s) | 246.76 rad/s (verbatim sim: 246.753) / 244.43 rad/s (sim: 244.43) | 1e-3. At g = 1 the L₃/I₁ value is off by 1 % and fails. |
| Display alias | 337.5 Hz at 120 fps | 22.5 Hz | exact |
| Magnetometer alias | 60 Hz at fs 99.8 | 39.8 Hz | exact |
| P.453 N | 1013.25 hPa, 15 °C, 0 % / 50 % RH | 272.87 / 311.37 (eq. 2) | 0.01 |
| k-factor | dN/dh = −40 | 1.34199 | 1e-5 |
| Radio horizon | h 1.5 m, k 4/3 | 5.048 km | 1e-3 |
| ZHD | 1013.25 hPa, 45°, 0 m | 2.30697 m | 1e-5 |
| P.676 γ_o | 60 GHz, 835 hPa, 15 °C, 7.5 g/m³ | 12.270 dB/km | ±0.05 (`rf-physics.md` B.7 [!]). [corrected in review: 835 hPa is *total* pressure (`gamma_p676(p_tot=835)`, so p_dry = 825.0 hPa). State this in the test.] |
| Boris | electron, v⊥ 9.536 × 10⁴ m/s, 50 µT | r = 1.08438 cm, T = 0.714477 µs, energy drift < 1e-12 over 10⁴ steps | 1e-5 [corrected in review: needs h ≤ T/1000 (radius error (ω_c h)²/8 = 4.9e-6, period error 3.3e-6) or the tan-corrected rotation; at 100 steps per orbit both fail at ~4e-4] |
| Rayleigh RSSI σ | 10⁶ exponential samples, seed 1 | 5.570 dB | 0.01 [corrected in review: the sampling standard error is ≈0.006 dB, so 0.01 is only 1.7σ and passes or fails depending on the RNG. Use 0.03.] |
| PLF | 80° | −15.2066 dB | 1e-4 |
| λ/2 dipole F² | θ = 30° | −7.5808 dB | 1e-4 |
| ULA null | N 8, d λ/2, β 0, θ 60° | AF = 0 (the **second** null, k = 2; the first is at θ = 75.52° [corrected in review]) | 1e-12 |
| Thin film | n 1.33, d 420 nm, λ 450 nm, normal incidence | R = 0.0769 | 1e-4 |
| Sellmeier | silica / BK7 at 530 nm | 1.46080 / 1.51958 | 1e-5 |
| Magnetic latitude | I = 66° | 48.316° | 1e-3 |
| NdFeB rotor μ | Bᵣ 1.3 T, 60 g, ρ 7500 | 8.276 A·m² | 1e-3 |

---

## 11. Device checks to add to the "Sensor census" (`sdk-sensors.md` §7)

1. The magnetometer's push-mode rate and jitter from `CMLogItem.timestamp`, and whether the 60 Hz line from a power brick appears at about 39.8–40 Hz or is filtered away.
2. **Self-interference:** drive the haptic hum at intensity 1 for 10 s, then play a loud 60 Hz tone through the speaker. Does either show up in the magnetometer PSD? This decides "Quiet capture".
3. The noise floor of calibrated \|B\| (σ over 10 s, still), which sets the FID pitch jitter: σ_f = 42.58 Hz/µT × σ_B.
4. BLE callbacks per second per device with duplicates (needed for ≥ 8 samples per 10° bin in the turntable experiment).
5. Whether `CMAltitudeData.relativeAltitude` tracks one floor (3 m) within ±0.5 m.
6. Real ARKit plus magnetometer: whether the field-painting voxels are repeatable to within 1 µT on revisits.
7. Taptic hum vs accelerometer: the vibration line frequency (to mask it in the accelerometer spectrum).

---

## 12. Sources

- Gyre source and README (local). `Tools/physcheck` results are quoted from the README and `design-gyre.md` §10 (8/8 pass).
- CODATA 2022, NIST `physics.nist.gov/cuu/Constants/Table/allascii.txt` [V]: γ_e/2π, γ_p/2π, γ′_p/2π, a_e, μ_p/μ_N, m_p, k, ħ, g_e.
- ITU-R P.453-14 (08/2019), *The radio refractive index* [V, PDF text extracted this session]: eqs 1, 2, 6, 7, 8, 9, EF and a/b/c/d coefficients, N₀ = 315, h₀ = 7.35 km. https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.453-14-201908-I!!PDF-E.pdf
- ITU-R P.310 (standard gradient −40 N/km, effective radius ≈ 4/3, ≈ 8500 km) [V via search excerpt]. https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.310-9-199408-I!!PDF-E.pdf ; P.834-8 https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.834-8-201609-S!!PDF-E.pdf
- IERS Conventions 2010, ch. 9 (Saastamoinen/Davis ZHD) [V via search excerpt]. https://iers-conventions.obspm.fr/content/chapter9/icc9.pdf
- ITU-R P.676-13 line-by-line, via `rf-physics-calc/b_prop.py` and `p676_tables.json` (`rf-physics.md` B.7).
- `rf-physics.md` A.11, A.15, B.1, B.2, B.10, C.1, C.6, D.1, D.2, F.2, G.2, G.3, G.4; `sdk-sensors.md` §1, §3, §4.3–4.11, §7; `port-plan.md` §1–3; `design-orbitals.md` §d–f; `design-house-rules.md` §3–4; `design-gyre.md` (with the corrections in §1).
- [S] Bloch 1946 (*Phys. Rev.* 70, 460); Hahn 1950 (*Phys. Rev.* 80, 580); Boris 1970 / Birdsall & Langdon; Malitson 1965 (fused silica Sellmeier); Schott N-BK7 datasheet; Birch & Downs 1994 (*Metrologia* 31, 315); Vainikainen et al. 2002 (*IEEE TAP* 50(10)); IGRF dipole B₀ ≈ 30 µT; FM threshold ≈ 10 dB CNR; ±45° base-station polarization; water T₁/T₂ ≈ 2–3 s; the AM band 530–1700 kHz.
