# API — Core (spectra-lab physics port)

Owner: core-port. Source: `Spectra/Core/` (14 files). Parity: `SpectraTests/CoreParityTests.swift` (51 XCTests) and `Tools/check-core.sh`.

## Threading and conventions

- Every type is a `nonisolated` value type or caseless `enum` namespace, `Sendable`, with no global mutable state. Call it from any actor: the MainActor UI, a render loop, a `Task.detached`, the Patch evaluator.
- No UIKit, SwiftUI, Metal or AVFoundation imports. Foundation only.
- Units: SI. Wavelengths are vacuum wavelengths in **metres**, frequencies in Hz, photon energies in eV, angles in **degrees** in the API (radians inside `Jones`, `Component.phase` and `FieldView`). Attenuation is in 1/cm, as in the JS.
- `Double` everywhere. Convert to `Float` only at the GPU boundary. For Metal, reduce phase `2π·r·κ·t` modulo 2π on the CPU in Double; a Float `t` loses phase after about 1,000 s.
- Strings are JS-exact (`toFixed` ties round away from zero, µ is U+00B5, superscripts U+207B/U+2070…). Do not reformat parity strings with `FormatStyle`.
- Provenance: Core returns `CoreProvenance` (`.table` / `.model`). The raw values match the app's `Provenance`, so use `Provenance(rawValue: p.rawValue)!`.

## `SI` (constants.js)

`c, h, hbar, e, kB, nA, eps0, mu0, me, meEV, meOverMp, rydbergInf, rHydrogen, wienB, gammaProtonHzPerT, hcEVm, eVToKcalPerMol, eVToKJPerMol, pairThresholdEV, ionizingEV, visibleEdgeEV`. All are bit-identical to the JS values.

Native addition: `gammaProtonShieldedHzPerT` = 42.57638543e6 Hz/T (γ′ₚ/2π, water protons, CODATA 2022), the value Earth-field NMR measures and the Spin engine uses for water. `gammaProtonHzPerT` stays the 2018 bare-proton value for the web lab's 400/60 MHz modes.

## `Spectrum` (SpectrumCore.swift)

| API | Notes |
|---|---|
| `logMin = -13`, `logMax = 3`, `logRange` | The web dial range. This is the default everywhere, and parity depends on it. |
| `rulerLogMin = -13`, `rulerLogMax = 8`, `rulerLogRange`, `clampRulerLog(_:)` | **Native extension**: the ruler reaches 100,000 km (3 Hz). It is opt-in (see `SpectraState.extendedRange`) and matches `SpectrumMarker.logRange`. |
| `frequency(_ λ)`, `wavelength(frequency:)`, `photonEV(_:)`, `wavelength(eV:)`, `kcalPerMol(eV:)`, `kjPerMol(eV:)`, `wavenumber(_:)` (cm⁻¹), `wavelength(wavenumber:)`, `clampLog(_:)` | Conversions. |
| `BandKey`, `Band {key,name,short,lo,hi,colorHex}`, `bands`, `band(_ key)`, `band(at: λ)`, `bandJump[key]` | Band edges and palette (uppercase hex). `bandJump` gives the λ each band button jumps to. |
| `subBand(at:)`, `rulerSubBand(at:)`, `hueName(nm:)` | `rulerSubBand` gives ITU names past 1 km: LF·longwave, VLF, ULF, SLF, ELF. Below 1 km it is identical to `subBand`. |
| `ionizationClass(_:) -> IonizationClass` (`.ionizing/.bond/.none`, `.label`) | |
| `spectralRGB(nm:) -> SIMD3<Double>`, `displayColorHex(_:)`, `displayRGB(_:)`, `rgb(hex:)` | `displayRGB` gives linear 0…1 values for `Color`. Visible light is lowercase hex; other bands use their palette. |
| `Detent {log, kind .band/.ionizing/.landmark, label}`, `detents`, `crossedDetents(fromLog:toLog:)` | On every λ edit, fire one haptic per crossed detent, ordered over the half-open interval (lo, hi]. The web `detents` end at 1 km (no `.landmark` ever appears in them). |
| `rulerDetents`, `crossedRulerDetents(fromLog:toLog:)` | **Native extension**: the web detents plus one `.landmark` detent per `longWaveLandmarks` mark (Earth-field NMR, mains 60/50 Hz, Schumann). Identical to `crossedDetents` below 1 km; use it when `extendedRange` is on. |
| `SizeComparison`, `sizeComparisons`, `nearestComparison(_:) -> Comparison {size,label,ratio,decades}` | |
| `Landmark {id,label,frequency,lambda}`, `longWaveLandmarks` | Ruler marks: `earthNMR` (water protons, γ′ₚ·50 µT = 2,128.82 Hz, 140.83 km, as in gyre-integration.md §4.1 and the Spin engine), `mains60` (4,996.5 km), `mains50` (5,995.8 km), `schumann` (7.83 Hz, 38,288 km). |
| `describe(_ λ) -> WaveDescription {lambda,f,ev,band,sub,ion,colorHex,text{lambda,f,ev,kcal,wavenumber}}` | Everything a readout needs. |

## `JSFormat`, `JSMath` (JSFormat.swift)

- `JSFormat.toFixed(x, n)`, `toPrecision(x, p)` and `jsString(x)` (JS `String(x)`) are ECMAScript-exact.
- `JSFormat.sig3`, `sci(_:unit:)`, `length(_:)`, `frequency(_:)`, `energy(_:)` and `kcal(eV:)` are the readout formatters. `superscript(_:)` is also here.
- `JSMath.max/min/clamp` propagate NaN. `JSMath.round` rounds ties toward +∞. `JSMath.sign` and `JSMath.hypot` match V8 bit for bit.

## `WaveSource`, `Wave` (WaveCore.swift)

- **`WaveSource`** is `Codable`, and its JSON keys are the JS keys (`E0`).
  - Fields: `enabled`, `kind (.plane/.pulse/.thermal; .name, .note)`, `lambda`, `e0`, `theta`, `delta`, `phi`, `cycles`, `temperature`.
  - `WaveSource()` is the JS `defaultSource()`.
  - `sanitize(logRange:)` / `sanitized(logRange:)` reproduce JS `sanitize`. Pass `Spectrum.rulerLogRange` for the long ruler. A NaN field resets to its default, which is an intentional divergence (port-plan Q8).
- **`Wave`**:
  - Basics: `tau`, `rad(_:)`, `jones(_:) -> Jones {ax, ay, delta}`, `fields(_:phase:) -> FieldSample {ex,ey,bx,by}` (B in E units), `phase(_:z:t:n:)`.
  - Intensity and pressure: `intensity(e0:n:)`, `peakB(e0:n:)`, `radiationPressure(e0:n:reflect:)`, `photonFlux(e0:lambda:n:)`.
  - Polarization: `ellipse(_:) -> Ellipse {orientation°, chi°, kind, sense?}` and `polarizerTransmission(_:alphaDeg:)`. For circular light, `orientation` is noise; use `SpectrumDisplay.orientationText`.
  - Pulses and thermal light: `pulseEnvelope(_:phase:)`, `pulseBandwidth(_:)`, `planckLambda(_:temperature:)`, `wienPeak(_:)`, `components(_:count:) -> [Component {lambda, amp, phase}]`. Thermal phases come from an LCG seeded 12345 on every call, so the result is deterministic.
  - Strong fields: `a0(e0:lambda:)`, `fieldForA0(_:lambda:)`, `quiverAmplitude(e0:lambda:)`, `driftSpeed(_:)`, `ProbeMode (.both/.electric/.magnetic)`, `electronTrajectory(_:a:mode:cycles:steps:) -> [TrajectoryPoint {eta,t,x,y,z,ux,uy,uz,gamma}]` (steps + 1 points, units c/ω and 1/ω; a negative `steps` returns `[]`, as in JS).

## `Matter` (Matter.swift, MatterComplex.swift) and the tables

- **Interpolation.** `LogLogTable(xs:ys:) / (flat:) / (rows:)` builds a table. `Matter.logLog(_:_:) -> Double?` returns nil outside the table and takes the upper value at an edge.
- **NIST XCOM.** `xcomMinEV`, `xcomMaxEV` and `xcomLambdaMax` (the literal 1.239841984e-9 m) are the limits. `massAttenuation(_ XCOMMaterial, eV:)` returns cm²/g and `linearAttenuation(_:eV:density:)` returns 1/cm.
  - `XCOMMaterial` is `.water/.tissue/.bone/.lead/.zinc/.pyrex`, with `.name`, `.density`, `.sourceURL` and `.table`.
- **Water.** `waterAbsorption(_ λ) -> Double?` uses Segelstein, 10 nm to 10 m, in 1/cm.
- **Complex index.**
  - `Matter.Complex` follows the JS arithmetic: naive `/` and `Complex.sqrt` with the JS sign rule.
  - `index(fromEpsilon:) -> ComplexIndex {n, k}`, `absorptionFromK(_:lambda:)` and `normalReflectance(n:k:)` build on it.
- **Oscillators.** `oscillatorResponse(omega:omega0:gamma:) -> {amplitude, lag°, power}`, `LorentzOscillator {w0, wp, gamma}`, `lorentzEpsilon(omega:_:)` and `drudeEpsilon(omega:wp:gamma:)`.
- **Media.** `Medium` is `.vacuum/.air/.water/.glass/.silica/.diamond`, with `.name` and `.index(λ) -> MediumIndex {n, k, valid}`.
- **Metals.** `freeElectronMetal(...)` and `zinc` describe free-electron metals. `workFunctions` (in JS order) and `zincWorkFunction` give work functions.
- **Slabs and curves.** `slab(r:alphaPerCm:thicknessCm:) -> TRA {t, r, a}`. `anchors(_:_:)` clamps at the ends; `bridge(...)` extrapolates.
- **Generated data.** `XCOMTables.*` and `SegelsteinWater.flat/.table` are generated: never edit them. Regenerate with `node Tools/gen-tables.mjs`.

## Matter bench (Specimens.swift)

- **Specimen API.**
  - `SpecimenKey` is `.oscillator/.antenna/.water/.glass/.zinc/.dna/.hand`, with `.name` and `.sub`.
  - `evaluate(_ λ, source: WaveSource?, options: SpecimenOptions(lambda0:q:)) -> SpecimenResult`.
- **`SpecimenResult`** fields:
  - `transmission`, `reflection` and `absorption` are nil for the oscillator and the antenna.
  - `alpha`, `absorbance`, `boneT` and `contrast` are specimen-specific.
  - `source: CoreProvenance`.
  - `response: SpecimenResponse {kind, text, amplitude, lag, power, regime, value, heating, ejectKeMax, resonance}`.
- **`Specimens` helpers.** `waterAlpha(_:)`, `dnaAbsorbance(_:)`, `isXray(_:)` and `inSeries(_:source:list:) -> [SeriesStep {key, before, after}]`.
- Pass `state.bench.lambda0` as `SpecimenOptions.lambda0` for the oscillator.

## Spectroscopy lab (LabSamples.swift)

- **Samples and modes.**
  - `SampleKey` is `.hydrogen/.co2/.water/.chlorophyll/.nmr`, with `.name`, `.modes`, `.source`, `.axis` (`SampleAxis {kind, from, to, label; x(at: u)}`), `.value(_:mode:)`, `.toLambda(_:mode:)` and `.note(mode:)`.
  - `SampleMode` covers `.emission/.absorption/.ir/.raman/.a/.b/.nmr400 ("400")/.nmr60 ("60")`. `.name` is in SpectrumDisplay.swift.
- **`Samples` helpers.**
  - Hydrogen: `hydrogenLine(n1:n2:)`, `hydrogenLines(mode:)` (cached) and `lineName(n1:n2:)` (Hα…).
  - NMR: `larmor(b0:ppm:)`, `nmrField(_:)` and `nmrSpectrum(ppm:b0:)`.
  - Line data: `co2IR`, `co2Raman`, `chlorophyllA/B`, `ethanol`.
- **NMR at any field** (native). `Samples.ethanolValue(ppm:b0:)` and `Samples.nmrLambda(ppm:b0:)` (the web lab's bare-γₚ convention).
  - The first-order multiplets are only valid at spectrometer fields.
  - For the **Earth-field mode**, draw a single water-proton line at `Samples.earthFieldLarmor(b0: |B|)` (shielded γ′ₚ: 2,128.82 Hz at 50 µT, the Spin tab's value) and tune with `Samples.earthFieldLambda(b0:)` (140.83 km at 50 µT). At that field the multiplets collapse, because the shifts are millihertz and J is 7.1 Hz.
  - 140 km is beyond the web range: set `state.extendedRange = true` before `state.edit(.lambda(Samples.earthFieldLambda(b0: b)))`, or the edit clamps to 1 km.

## `SpectraState`, `SpectraPreset` (SpectraState.swift, SpectraPresets.swift)

- **`SpectraState`** is `Codable, Equatable, Sendable`, and its JSON keys are the JS keys.
  - Sources: `sources` (always 3), `active`, `link`.
  - Settings: `medium`, `speed` (κ), `instrument`, `scope {showE,showB,showS,yaw,pitch,zoom}`, `decompose {tab, polarizer, probeMode, a0}`, `bench {arrangement, lambda0, focus}`, `lab {sample, mode, sweep, sweeping}`, `feedback`, `playing`, `preset`.
  - **`extendedRange`** (native, default false): when true, edits, presets and decoding sanitize λ to `rulerLogRange`. It is serialized only when true. Switching it off re-sanitizes the sources onto the web range.
- **Behaviour.**
  - `SpectraState()` is the JS `defaults()`.
  - `edit(_ SourceEdit)` reproduces JS `editSource`. With Link on, the edit applies to the enabled sources plus the active one: λ, E₀ and T scale; θ, δ and φ shift; everything else copies.
  - Derived values: `sanitizeSources()`, `timeScale`, `slowMotion`, `enabledSources`, `enabledIndices`, `referenceSource`, `activeSource`, `logRange`, `lambda(frequency:)`. `activeSource` and `edit` clamp a stray `active` into 0…2 instead of trapping.
- **Persistence.** `deserialize(_ Data | String)` follows JS rules: garbage gives the defaults, `active` is computed as `|0` then clamped, `lab.sweeping` is forced off, and an unknown medium becomes vacuum. Write with `serialized()`, or with any `JSONEncoder`, and decode with `JSONDecoder` as usual. Prefer `serialized()`: a plain `JSONEncoder` throws on a non-finite field (κ = ∞, say), while `serialized()` writes it as a string and `deserialize` restores that one field's default.
- **Dials.** `Dial` (`.lambda/.temperature/.e0/.theta/.delta/.phi/.cycles`) provides `.range`, `.range(extended:)`, `.isLog` and `.step`.
- **Presets.** `SpectraPreset.all` holds the 14 field trips (`key`, `name`, `detail`, `note`, …). `SpectraPreset.named(_:)` looks one up. `state.apply(_:)` and `state.apply(preset: key) -> Bool` apply one; an unknown key leaves the state untouched.

## Display (Display/FieldView.swift, Display/SpectrumDisplay.swift)

- **`FieldView`** (from fieldview.js):
  - `maxRatio`, `sourceTags`, `sourceLetters`.
  - `displaySources(_ state)` or `displaySources(sources:medium:) -> DisplaySources`. Rebuild it when `isCurrent(sources:medium:)` is false.
  - `fieldAt(_:z:t:speed:only:) -> FieldPoint {ex, ey, n}`: z is in reference wavelengths, t in screen seconds, and B = n ẑ × E.
  - `hiddenNote(_:)`.
- **`SpectrumDisplay`** (UI mappings from the web instruments):
  - Controls: `speedLogRange` (κ, log₁₀ −1.3…0.6), `polarizerRange` (0…180°), `a0LogRange` (log₁₀ −2…1), `lambda0LogRange` (bench λ₀, log₁₀ m −8…0), from `controls.js` and the instruments.
  - Scope: geometry constants.
  - Polarization: `polarizationTrailTime`, `componentStripSpan`, `polarizerProjection`, `orientationText` ("—" for circular light), `polarizationReadouts`, `polarizationNote`.
  - Probe: `probeTrajectory` (3 cycles, 900 steps; cache it by a₀, mode, θ, δ), `transverse`, `probeIndex`, `driftFrame`, `probeReadouts`, `probeNote`, `driftTag`.
  - Fourier: `fourierWindow`, `fourierTrace`, `stemAxis`, `prismDeviation`.
  - Tuner: `comparisonPhrase`, `decadeLabel` (to e = 8), `thermalTemperature(atLog:)`.
  - Lab: `labSweepRate`, `labAxisText`, `labMaximum` (2,401 evaluations: cache per sample/mode).
  - Readouts: `readouts(_ state) -> [Readout {key, value, sub, colorHex}]`, `statusLine`, `slowMotionText`, `readoutIndex`. Beyond 1 km (extended ruler) `statusLine` names the ITU band (`rulerSubBand`) and `slowMotionText` reads "… faster" when f < κ.
  - Feedback: `soundPitch(frequency:)` (110·2^(4(log f − 5.5)/16) Hz), `hapticMinInterval` (35 ms), `tickMinInterval` (45 ms).
  - Colours are spectra-lab THEME hex strings. Map them to the app's theme tokens.

## Typical use (Spectrum tab model, MainActor)

```swift
@Observable @MainActor final class SpectrumModel {
  var state = SpectraState()            // persist with JSONEncoder under "Spectra.spectrum.v1"
  private var display: FieldView.DisplaySources?
  func tune(lambda: Double) {
    let before = state.activeSource.lambda
    state.edit(.lambda(lambda))
    let crossed = state.extendedRange ? Spectrum.crossedRulerDetents : Spectrum.crossedDetents
    for d in crossed(log10(before), log10(state.activeSource.lambda)) { /* haptic: d.kind */ }
  }
  func field(z: Double, t: Double) -> FieldView.FieldPoint {
    if display?.isCurrent(sources: state.sources, medium: state.medium) != true { display = FieldView.displaySources(state) }
    return FieldView.fieldAt(display!, z: z, t: t, speed: state.speed)
  }
}
```
