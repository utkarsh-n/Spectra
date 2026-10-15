# Spectra (native) — build spec, part 1: product, principles, architecture

Owner: Utkarsh. Device: iPhone 15 Pro Max, iOS 27.2 (`47C11007-EC72-5611-98B6-FC3FC5CD65F2`). Toolchain: Xcode 27.0 beta (27A5194q), XcodeGen, iOS 27 SDK. Project root: `/path/to/developer/Documents/AI Stuff/Spectra/` (iCloud folder, so build ONLY through `Tools/build.sh`, which mirrors to `$TMPDIR`).

Read with: `SPEC-features.md` (what each screen does), `SPEC-build.md` (stages, rules, tests). Reference research in `Docs/research/` — treat the **review-corrected** documents as the source of truth: `rf-physics.md` + its "Verified reference" in `rf-physics-review.md`, `gyre-integration.md` (+ `gyre-integration-review.md` when present), `sdk-sensors.md`, `port-plan.md`, `design-orbitals.md`, `design-gyre.md`, `design-house-rules.md`. The web prototype being ported is `/path/to/developer/Documents/AI Stuff/spectra-lab/` (its README, VERIFICATION and `src/`).

## 1. What Spectra is

One instrument for the electromagnetic spectrum, from the phone in your hand outward:

1. **Spectrum** — the web prototype's five instruments, native: Wave scope, Spectrum tuner, Matter bench, Decompose, Spectroscopy lab.
2. **Radio** — an antenna and frequency simulator: antenna styles with 3D radiation patterns, radio generations and systems (1G→6G, Wi-Fi b→be, Bluetooth/BLE, GPS, NFC, UWB, AM/FM, Qi), a Fourier visualizer (time, IQ constellation, spectrum, waterfall, OFDM), and a link budget.
3. **Live** — the iPhone's own radios and sensors as instruments (BLE RSSI, cellular/Wi-Fi generation and link quality, GNSS accuracy, magnetometer ELF probe, microphone Fourier, camera light meter, barometer → air refractivity, charging), each placed on the spectrum.
4. **Spin** — Gyre's gyroscope as a classical spin: one equation dL/dt = μ × B (+ ℓ ê × m g). Heavy top driven by real motion, proton/electron spin precessing in the *live* Earth field you can hear (~2 kHz), Bloch sphere, RF pulses, FID.
5. **Patch** — a node graph where every source (live sensor, simulated radio, spin, Spectra wave) and every process (modulator, antenna, channel, demodulator, FFT) and sink (scope, speaker, haptics, the Spectrum ruler) connect with glowing cables. This is the loop: Spectrum ↔ Radio ↔ Live ↔ Spin, all patchable.

The **loop is visible everywhere**: a thin *Spectrum strip* under the top bar on every tab shows a mini log ruler (0.1 pm … 100,000 km) with a marker for every active frequency in the app (Spectra sources A/B/C, the Radio carrier, live radios, Larmor frequency, mains hum, audio). Tap a marker to jump to its tab; long-press → "Tune Spectrum here".

## 2. Design principles ("glass over phosphor")

Merge Orbitals (instrument logic) with Gyre (living field). Details and exact values: `design-orbitals.md`, `design-gyre.md` §11.

- **Content layer**: dark phosphor instrument. Background `(0.025, 0.045, 0.04)`, panel `(0.065, 0.095, 0.083)` radius 26 with white 7 % hairline, plot well `#040807` radius 16–20 with faint phosphor grid. Numbered monospaced uppercase panel titles ("01 WAVE SCOPE"), monospaced digits for every readout.
- **Chrome**: Liquid Glass only for controls and navigation (`GlassEffectContainer`, `.glassEffect(.regular.interactive())`, `.glass`/`.glassProminent` button styles, `glassEffectID` morphs). Never glass on plots or panels.
- **Colour has meaning** (Gyre rule R2): hue = EM frequency only (spectral colour in the visible, band palette elsewhere: radio `#9DB0CC`, microwave `#5FD3BC`, IR `#FF7A6B`, UV `#B583FF`, X-ray `#8FD3FF`, gamma `#E2D4FF`). Non-EM signals (sound, mechanical motion, the rotor) use phosphor `(0.4, 0.96, 0.56)` / amber `(1, 0.75, 0.37)` and carry an **ANALOGY** badge. Fixed field colours: E `#61B3FF`, B `#FF5C7A`, S (Poynting) amber, Ex `#1AEDFF`, Ey `#FFE82E`. Fixed dial accents: λ follows band colour, E₀ blue, θ mint `#59F0B0`, δ rose `#FF8FB8`, φ violet `#C799FF`, n / T / κ amber. Source identity A/B/C: phosphor, rose, ice `#8FD3FF`. Muted text `(0.61, 0.71, 0.65)`, ionizing `#FF8F6B`.
- **Provenance on every number** (rule R4): badges TABLE, MODEL, LIVE, INFERRED, SIM, LOCKED, NEEDS PEER, ANALOGY. Graph outputs carry the union of their inputs' badges.
- **Every oscillation declares its time mapping** (rule R3): REAL TIME, κ-SLOWED (×10ⁿ slower), or HETERODYNED (rotating frame at f_ref, shows Δf). Show an ALIASED chip when displayed frequency exceeds half the frame rate.
- **Tactile and causal**: every control has a haptic answer (grab, tick, detent, boundary, success). Transients are rate-limited (≥35 ms). Continuous haptic hum only for live signal strength / spin when the user enables it. Global haptic strength slider. Optional sound (synth hums at a pitch mapped from frequency; Spin plays true-pitch precession). Both are user options in Settings → Feedback, default haptics ON, sound OFF.
- **Accessible**: every gesture has a button / VoiceOver adjustable / keyboard alternative; dials have a linear slider fallback; Dynamic Type collapses grids; Reduce Motion stills animations; stable accessibility identifiers on every control.
- **Persistent access**: top-left **Dials** button on every tab and every full-screen view opens that tab's control sheet; Reset dials / Reset alignment pinned at the bottom of sheets. Top-right capsule: Field notes (ⓘ), Settings.
- **Honest copy**: plain sentences, no marketing. Field notes per tab state what is real vs modelled and cite sources (as spectra-lab does).
- **House rules** (`design-house-rules.md` §3): no onboarding; permissions requested on the tap that needs them (never at launch) with an empty state + "Open Settings" on denial; usage strings in the "Spectra <verb>s … so it can …" voice plus a privacy sentence; Settings is a Form in a sheet; tool sheets `[.medium, .large]`; one NavigationStack per tab; American spelling in UI copy.

## 3. Architecture

### 3.1 Language and concurrency
Swift 6 language mode. Build settings: `SWIFT_VERSION: 6.0`, `SWIFT_APPROACHABLE_CONCURRENCY: YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` for the app target. Pure engine code (`Core/`, `RF/`, `Spin/`, `Graph/Engine/`) is written so it compiles **both** in the app and in a plain macOS `swiftc` harness with default (nonisolated) isolation: use `nonisolated` value types, `Sendable` structs/enums, pure functions, no UIKit/SwiftUI imports, Foundation + Accelerate (+ `simd`) only. Audio-thread and sensor-callback code: `nonisolated final class …: Sendable` with `Synchronization.Mutex` / `Atomic` (iOS 18+), or `@unchecked Sendable` with a documented lock. Delegates: `@MainActor` classes with `@preconcurrency` protocol conformance (Orbitals pattern). No `DispatchQueue.main.async` hopping; use `Task { @MainActor in }`.

### 3.2 Folder layout (XcodeGen sources by folder)
```
Spectra/
  project.yml
  Spectra/
    App/        SpectraApp, AppModel (root @Observable), RootView (TabView), LaunchOptions (fakes, -open), Clock
    Core/       port of spectra-lab src/core (port-plan.md §2), Core/Data/ generated tables, Display/FieldView
    RF/         pure RF engine (antennas, propagation, noise, modulation, OFDM, channel, DSP, systems catalog, link budget)
    Spin/       pure spin engine (Bloch, heavy top ported from Gyre GyroSim, species, Earth-field helpers)
    Graph/      Engine/ (pure: signal types, node protocol, graph, evaluator, node catalog) + Model/ (PatchModel @MainActor)
    Live/       SensorHub, SensorSource protocol, timestamped rings, real sources, Fakes/, SensorCensus
    Feedback/   Haptics (merged Gyre+Orbitals), HumSynth (voices + PCM playback), Sonify
    Render/     Metal: MetalCanvas (MTKView wrapper), HoloRenderer (HDR, bloom, EDR soft-clip), Shaders.metal, Camera, Scenes/
    AR/         shared ARSession controller (stage 3+; optional in v1)
    UI/
      Theme/        Theme tokens, BandColor
      Components/   GlassKnob (+KnobSpec), InstrumentPanel, Readout, ProvenanceBadge, TopBar, SpectrumStrip,
                    Transport, TimeMappingChip, ControlSheet, FieldNotesSheet, SettingsSheet, PermissionGate, Chips
      Plots/        SwiftUI Canvas plots: LinePlot, SpectrumPlot, WaterfallView, ConstellationPlot, PolarPlot, LogRuler, Sparkline
      Spectrum/ Radio/ Live/ Spin/ Patch/     one folder per tab, each with <Tab>Tab.swift root view + its model
    Resources/  Assets.xcassets (AppIcon, AccentColor, LaunchBackground)
  SpectraTests/   CoreParityTests (+ Fixtures/vectors.json), RFTests, SpinTests, GraphTests, LiveFakeTests
  SpectraUITests/ SmokeTests (each tab opens with -fakeAll; screenshots)
  Tools/          build.sh, agentbuild.sh, check.sh (macOS harness for Core+RF+Spin+Graph/Engine), gen-tables.mjs, make-icon.swift
  Docs/           SPEC*.md, API.md (written by the foundation stage), research/
  README.md, VERIFICATION.md
```

### 3.3 Rendering
- **3D hero scenes in Metal** (one `MetalCanvas` alive at a time, Orbitals rule): Gyre's `HoloRenderer` skeleton — rgba16Float scene, bloom at ½ and ¼, soft-clip into EDR (≤3×), triple-buffered instance buffers, skip frame if all busy. Two line primitives sharing the bloom: **holo** 3D instanced segments with butt caps (depth-tested) for waves, field lines, radiation lobes, spin trails, gyroscope; **phosphor** 2D analytic capsules (Orbitals `Phosphor.metal` technique: analytic AA + glow in shader) for traces drawn inside a scene. Scenes conform to a small protocol: `func build(into: inout SceneBuffer, time: Double, size: CGSize)` producing line instances + camera. 60 fps; 30 fps on Low Power Mode or serious thermal state; pause when off screen or app inactive.
- **2D plots in SwiftUI `Canvas`** driven by `TimelineView(.animation)` only while visible (spectrum, constellation, waterfall via a reused `CGImage`, polar cuts, sparklines, the log ruler). Phosphor styling helper (glow = wide low-alpha stroke under a crisp stroke).
- Gestures on 3D scenes (Orbitals `OrbitCanvasGestures`): drag rotate, two-finger pan, pinch zoom with focal anchor, double-tap Align; buttons/VoiceOver alternatives.

### 3.4 Shared app state (the loop)
`AppModel` (`@Observable @MainActor final class`, injected via `.environment`) owns:
- `clock: AppClock` — display time `t`, `playing`, `step()`; one render-loop-driven clock (Gyre: the render loop calls `advance(dt:)`; when no Metal scene is visible a `TimelineView` drives it). dt capped at 0.1 s, no catch-up after pause/background.
- `spectrum: SpectrumModel` (UI/Spectrum) — wraps ported `SpectraState`; `func tune(lambda:)`.
- `radio: RadioModel` (UI/Radio), `live: SensorHub` (Live), `spin: SpinModel` (UI/Spin), `patch: PatchModel` (Graph/Model).
- `haptics: Haptics`, `synth: HumSynth` (one each, Gyre rule R5).
- `settings: AppSettings` (feedback sound/haptics/strength, units, fakes) persisted in UserDefaults JSON (`Spectra.settings.v1`, 400 ms debounce, Orbitals pattern). Each sub-model persists its own JSON key `Spectra.<tab>.v1`.
- `var markers: [SpectrumMarker]` — union of every sub-model's `markers` (each sub-model exposes `var markers: [SpectrumMarker] { get }`).
- `func focus(_ marker:)`, `func sendToSpectrum(lambda:label:)` (sets Spectrum source A λ, switches tab, toasts).

```swift
struct SpectrumMarker: Identifiable, Hashable { let id: String; var label: String; var lambda: Double /*m*/; var provenance: Provenance; var tab: AppTab; var isEM: Bool /*false → ANALOGY colour*/ }
enum Provenance: String, CaseIterable, Codable, Sendable { case table, model, live, inferred, sim, locked, needsPeer, analogy }
enum AppTab: String, CaseIterable, Codable, Sendable { case spectrum, radio, live, spin, patch }
enum TimeMapping: Equatable, Sendable { case realTime, slowed(factor: Double), heterodyned(fRef: Double) }
```

### 3.5 Sensors (Live)
`SensorHub` (`@Observable @MainActor`) owns one channel object per source, each conforming to:
```swift
@MainActor protocol SensorChannel: AnyObject, Observable {
  var id: SensorID { get }                 // .motion .magnetometer .barometer .microphone .bluetooth .network .location .light .charging .uwb .nfc
  var provenance: Provenance { get }       // .live when real, .sim when faked, .locked/.needsPeer when unavailable
  var state: SensorState { get }           // .idle .requesting .running .denied .unavailable(reason) .locked(reason)
  var measuredRate: Double? { get }        // Hz, from timestamps
  func start() async                        // requests permission on demand (tap), starts updates
  func stop()
}
```
Timestamped samples go into `TimestampedRing<T>` (`Mutex`-protected, `Sendable`) so FFT consumers read at the true sample rate (never per-frame pulls; `gyre-integration.md` §4.3). Every source has a SIM implementation selected automatically when the hardware/API is unavailable (Simulator) or by launch argument (`-fakeAll`, `-fakeMag=hum60`, `-fakeBLE=8`, `-fakeMic=voice`, … per `gyre-integration.md` §8, all `#if DEBUG`). Sources start when their card/node/instrument is visible and `scenePhase == .active`, stop otherwise.

### 3.5b Signal streams (the universal scope bus)
Everything that produces a time signal publishes a `SignalStream` into one registry, so the Scope (and Patch, and Fourier views) can show *any* of them:
```swift
struct StreamID: Hashable, Codable, Sendable, RawRepresentable { let rawValue: String }   // e.g. "mag.x", "mag.norm", "accel.z", "ble.<uuid>.rssi", "mic.left", "spin.fid", "radio.i"
nonisolated final class SignalStream: Sendable {
  let id: StreamID; let label: String; let unit: String          // "µT", "g", "rad/s", "dBm", "Pa", "lux", "ms", "V (norm.)"
  let nominalRate: Double                                           // Hz (0 = irregular/event-driven, e.g. BLE adverts)
  let provenance: Provenance; let isEM: Bool; let lambda: Double?   // EM streams carry a wavelength for colour/markers
  let group: String                                                  // "Magnetometer", "Motion", "Bluetooth", "Network", "Audio", "Light", "Air", "Location", "Spin", "Radio", "Patch"
  let ring: TimestampedRing<Float>                                   // Mutex-protected, capacity ≥ 30 s at nominal rate (audio: 2 s)
}
@MainActor @Observable final class StreamRegistry { var streams: [SignalStream]; func register(_:) ; func unregister(_:) ; func stream(_ id: StreamID) -> SignalStream? }
```
`AppModel.streams` is the single registry. Sensor channels register their streams when started (and unregister on stop); Radio, Spin and Patch register simulated streams (MODEL/SIM). Samples carry the sensor's own timestamps (CMLogItem.timestamp, AVAudioTime host time, CB callback time), never the render frame time.

### 3.6 Graph
Pure engine (`Graph/Engine`): typed ports (`audio` blocks at 48 kHz, `iq` complex blocks at a node-declared rate, `spectrum` (bins + f axis), `control` scalar stream, `attitude` quaternion, `event` impulses, `em` (a Spectra source description: λ, E₀, polarization)). Pull-based block evaluator (topological order, cycle detection, fixed block size 1024 at 48 kHz for audio-rate graphs, frame-rate for control), provenance propagation, Codable graph documents. Node catalog and presets in `SPEC-features.md` §5. `PatchModel` (`@MainActor`) binds nodes to live channels, the synth, haptics and `AppModel.sendToSpectrum`.

### 3.7 Permissions and Info.plist (no entitlements; free Personal Team)
Usage strings (house voice): Bluetooth ("Spectra listens for nearby Bluetooth radios so it can show their signal strength live. Nothing is stored or sent."), Location when in use (GNSS accuracy and true north), Motion (barometer), Camera (light meter, LiDAR, AR), Microphone ("…turns sound into a live Fourier spectrum… Audio stays on this phone and is never recorded."), Nearby Interaction (UWB with your other device). NFC and Wi-Fi SSID are **LOCKED** on this team (show the node, explain why, offer the model). Bundle `com.utkarsh.spectra`, team `YOUR_TEAM_ID`, iPhone only, portrait, dark, `ITSAppUsesNonExemptEncryption: false`, `CADisableMinimumFrameDurationOnPhone: true`, `UILaunchScreen` with `LaunchBackground`.
