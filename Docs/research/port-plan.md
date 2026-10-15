# Spectra: porting the physics core to Swift, with parity vectors

Research date: 3 October 2026. Source: `/path/to/developer/Documents/AI Stuff/spectra-lab`, read in full: `src/core/*` (8 modules), `src/data/xcom.js`, `src/data/water.js`, `src/ui/fieldview.js`, `tests/core.test.mjs`, `tests/fixtures/reference.json`, `README.md` and `VERIFICATION.md`. Call sites were also checked in `src/ui/app.js`, `controls.js`, `draw.js`, `feedback.js` and `src/instruments/*`.

Two new files were added, and no existing file was changed:

- `spectra-lab/tests/parity/generate.mjs`, the vector generator.
- `spectra-lab/tests/parity/vectors.json`, its output: 2,508,288 bytes and 11,746 cases.

`npm test` still passes 14 of 14. Its glob, `tests/*.test.mjs`, does not reach `tests/parity/`.

Toolchain claims were checked on this Mac:

- Swift 6.4 (`swiftlang-6.4.0.20.104`) and `iPhoneOS27.0.sdk` from `Xcode-beta.app`.
- XcodeGen 2.46.0.
- Node v26.10.0.

Numeric claims about Swift vs V8 were **measured**. A scratch Swift program decoded `vectors.json` with `JSONDecoder` and recomputed part of the core (§4). It lives only in the scratchpad.

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Where the core lives | `Spectra/Spectra/Core/` in the app target. Foundation only: no SwiftUI, UIKit or Metal imports. `@testable import Spectra` from `SpectraTests`. | This matches Orbitals (`Orbitals/Orbitals/Core/*Math.swift`, XCTest `CoreTests.swift`) and house rule 15 (a UI-free core). |
| Headless parity run | `Tools/parity.sh` compiles `Core/*.swift`, `Core/Data/*.swift`, `Display/FieldView.swift` and `Tools/parity/main.swift` with `swiftc -O` into a macOS CLI, then runs it against `vectors.json`. | This is the same pattern as Subtext `Tools/synctest.sh`. It takes seconds and needs no simulator. The scratch probe built this way in under 5 s. |
| Test framework | XCTest. `ParityTests.swift` loads `vectors.json` from the test bundle. | House rule 22: no app imports `Testing`. `Testing.framework` exists in the SDK, but it would break the convention. |
| Precision | `Double` everywhere in Core and Display. Convert to `Float` only at the Metal/Canvas boundary (§9.3). | JS numbers are IEEE-754 doubles. |
| Reference tables | Generated Swift source holding flat `[Double]` literals with explicit type annotations. No bundled JSON. | Measured: 0.36 s to type-check the 2,522-element Segelstein literal (2.5 s as `[SIMD2<Double>]`), and every value is bitwise identical to the JS (§6). |
| Complex numbers | A local `struct Complex` that copies the JS formulas exactly. No swift-numerics. | The SDK has no `Numerics` module (checked in `iPhoneOS27.0.sdk/usr/lib/swift`). The JS division is the naive formula, so a library that uses Smith or scaled division would drift by ulps. |
| Namespaces | Caseless `enum` namespaces (`SI`, `Spectrum`, `Wave`, `Matter`, `Specimens`, `Samples`) plus `Sendable` value types. This is the Orbitals `OrbitalMath` style. | Pure functions and Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`). Do not store closures in static tables: the JS `PRESETS[].apply` and `SPECIMENS[].evaluate` become `switch` statements over enums. |
| Serialized keys | Keep the JS keys through `CodingKeys` (`E0`, `lambda`, `T`, `R`, `A`, `lambda0`, …). | `vectors.json` and the old `localStorage` JSON then decode directly. |

---

## 2. Swift file layout

```
Spectra/Spectra/Core/
  SI.swift              constants.js
  Spectrum.swift        spectrum.js: conversions, bands, sub-bands, detents, colour, describe
  JSFormat.swift        spectrum.js formatting, plus a JS-exact toFixed/toPrecision
  Wave.swift            wave.js
  Complex.swift         matter.js complex helpers (cx, cdiv, csqrt)
  Matter.swift          matter.js: logLog, XCOM/Segelstein lookups, Lorentz/Drude, MEDIA, slab, anchors, bridge
  Specimens.swift       specimens.js
  Samples.swift         samples.js
  SpectraState.swift    state.js
  Presets.swift         presets.js
  Data/XCOMTables.swift        GENERATED, do not edit
  Data/SegelsteinWater.swift   GENERATED, do not edit
Spectra/Spectra/Display/
  FieldView.swift       ui/fieldview.js: display-space fields, UI-framework-free
SpectraTests/
  ParityVectors.swift   Decodable mirror of vectors.json
  ParityTests.swift     one XCTest method per category
  Fixtures/vectors.json copied from spectra-lab/tests/parity (XcodeGen adds it as a bundle resource)
Tools/
  gen-tables.mjs        imports spectra-lab/src/data/*.js and writes Core/Data/*.swift
  parity.sh             swiftc -O … && ./parity Fixtures/vectors.json
  parity/main.swift
```

Load the fixture with `Bundle(for: ParityTests.self).url(forResource: "vectors", withExtension: "json")`. Decode it with `JSONDecoder`. The probe confirmed that JSONDecoder reproduces every double bit for bit, all 2,522 table values included.

---

## 3. JS export → Swift mapping

Signatures are proposals. Every value is `Double` unless marked otherwise, and every type is `Sendable, Hashable`, plus `Codable` where it persists.

### 3.1 `constants.js` → `SI.swift` (`enum SI`)

| JS | Swift | Note |
|---|---|---|
| `C, H, E_CHARGE, KB, NA` | `SI.c, .h, .e, .kB, .nA` | Exact SI 2019 literals. |
| `EPS0, MU0, ME, ME_EV, RYDBERG_INF, WIEN_B, GAMMA_PROTON_HZ_PER_T` | `.eps0, .mu0, .me, .meEV, .rydbergInf, .wienB, .gammaProtonHzPerT` | `42.577478518e6`. |
| `HBAR = H / (2 * Math.PI)` | `h / (2 * Double.pi)` | Keep this exact expression order. `2 * Double.pi` is bitwise equal to `2 * Math.PI` (6.283185307179586). |
| `ME_OVER_MP = 1 / 1836.15267343`, `R_HYDROGEN = RYDBERG_INF / (1 + ME_OVER_MP)` | same expressions | |
| `HC_EV_M = (H * C) / E_CHARGE` | `(h * c) / e` | Bitwise 1.2398419843320026e-6, verified in Swift. |
| `EV_TO_KCAL_PER_MOL = (E_CHARGE*NA)/4184`, `EV_TO_KJ_PER_MOL = (E_CHARGE*NA)/1000` | same | |
| `PAIR_THRESHOLD_EV = 2*ME_EV`, `IONIZING_EV = 10`, `VISIBLE_EDGE_EV = HC_EV_M / 400e-9` | same | |

Write every derived constant with the same operand order as the JS. Then the basic operations (`+ − × ÷ sqrt`), which IEEE rounds correctly, give bit-identical results.

### 3.2 `spectrum.js` → `Spectrum.swift` and `JSFormat.swift`

| JS | Swift |
|---|---|
| `LOG_MIN = -13`, `LOG_MAX = 3` | `Spectrum.logMin: Double = -13`, `.logMax = 3` |
| `frequency(λ)`, `wavelength(f)`, `photonEV(λ)`, `wavelengthFromEV(ev)` | `static func frequency(_ lambda: Double) -> Double`, `wavelength(frequency:)`, `photonEV(_:)`, `wavelength(eV:)` |
| `kcalPerMol(ev)`, `kjPerMol(ev)`, `wavenumber(λ)` (cm⁻¹ = `1/(λ*100)`), `fromWavenumber(ν)` | `kcalPerMol(eV:)`, `kjPerMol(eV:)`, `wavenumber(_:)`, `wavelength(wavenumber:)` |
| `clampLog(lg)` | `clampLog(_:)`, written as `min(logMax, max(logMin, lg))` (§7 Q8 covers NaN) |
| `BANDS` | `enum BandKey: String, CaseIterable, Codable { case gamma, xray, uv, visible, ir, microwave, radio }`; `struct Band { key, name, short: String; lo, hi: Double; colorHex: String }`. `radio.hi = .infinity`. |
| `bandAt(λ)` | `band(at:) -> Band`: the first band with `lo ≤ λ < hi`, else `.radio`. NaN and ∞ fall through to radio. |
| `subBandAt(λ)`, `hueName(nm)`, `ionizationClass(λ)` | `subBand(at:) -> String`, `hueName(nm:) -> String`, `ionizationClass(_:) -> IonizationClass` (`enum { ionizing, bond, none }`, labels "Ionizing", "Can break bonds", "Non-ionizing") |
| `spectralRGB(nm)` | `spectralRGB(nm:) -> SIMD3<Double>` (linear 0…1) |
| `displayColor(λ)` | `displayColorHex(_:) -> String` for parity, plus `displayRGB(_:) -> SIMD3<Double>` for SwiftUI `Color` |
| `DETENTS`, `crossedDetents(from, to)` | `struct Detent { log: Double; kind: .band/.ionizing; label: String }`; `crossedDetents(fromLog:toLog:) -> [Detent]` |
| `SIZE_COMPARISONS`, `nearestComparison(λ)` | `[SizeComparison]`; `nearestComparison(_:) -> (size, label, ratio, decades)` |
| `sig3, sci, formatLength, formatFrequency, formatEnergy, formatKcal` | `JSFormat.sig3(_:)`, `.sci(_:unit:)`, `.length(_:)`, `.frequency(_:)`, `.energy(_:)`, `.kcal(eV:)` (§8) |
| `describe(λ)` | `Spectrum.describe(_:) -> WaveDescription { lambda, f, ev, band, sub, ion, colorHex, text: (lambda, f, ev, kcal, wavenumber) }` |

### 3.3 `wave.js` → `Wave.swift`

```swift
struct Source: Codable, Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable { case plane, pulse, thermal }
  var enabled = true, kind: Kind = .plane
  var lambda = 550e-9, e0 = 1000.0, theta = 90.0, delta = 0.0, phi = 0.0   // CodingKey "E0" for e0
  var cycles = 3.0, temperature = 5772.0
}
enum ProbeMode: String, Codable, CaseIterable, Sendable { case both, electric, magnetic }
```

| JS | Swift |
|---|---|
| `defaultSource(overrides)` | `Source()` memberwise defaults |
| `jones(src)` → `{ax, ay, delta}` (delta in rad) | `Wave.jones(_:) -> Jones` |
| `fieldsAtPhase(src, q)` → `{ex, ey, bx: -ey, by: ex}` | `Wave.fields(_:phase:) -> FieldSample` (B is returned in "E units") |
| `phaseAt(src, z, t, n=1)` | `Wave.phase(_:z:t:n:)` = `k*z − w*t + rad(phi)` with `k = TAU*n/λ`, `w = TAU*c/λ` |
| `intensity(E0, n=1)` = `0.5*n*C*EPS0*E0*E0` | `Wave.intensity(e0:n:)`. Keep the left-to-right multiply order. |
| `peakB`, `radiationPressure(E0, n, reflect)`, `photonFlux(E0, λ, n)` | `peakB(e0:n:)`, `radiationPressure(e0:n:reflect:)`, `photonFlux(e0:lambda:n:)` |
| `ellipse(src)` | `Wave.ellipse(_:) -> Ellipse { orientation, chi /*deg*/, kind: .linear/.circular/.elliptical, sense: Sense? }` |
| `polarizerTransmission(src, αdeg)` | `Wave.polarizerTransmission(_:alphaDeg:)` |
| `pulseEnvelope(src, q)`, `pulseBandwidth(src)` | same names |
| `planckLambda(λ, T)`, `wienPeak(T)` | `Wave.planckLambda(_:temperature:)` (uses `Foundation.pow`, `expm1`), `wienPeak(_:)` |
| `components(src, count=15)` | `Wave.components(_:count: Int = 15) -> [Component]` (`lambda, amp, phase`) |
| `a0`, `fieldForA0`, `quiverAmplitude`, `driftSpeed` | same; `driftSpeed(_ a:) = a*a/(4+a*a)` |
| `electronTrajectory(src, a, mode="both", cycles=2, steps=720)` | `Wave.electronTrajectory(_:a:mode:cycles: Double = 2, steps: Int = 720) -> [TrajectoryPoint]`, returning `steps + 1` points `{eta, t, x, y, z, ux, uy, uz, gamma}` |

`TAU = 2 * Math.PI` and `rad(d) = (d * Math.PI) / 180`. Write them as `(d * .pi) / 180`, not `d * (.pi/180)`.

### 3.4 `matter.js` → `Complex.swift` and `Matter.swift`

| JS | Swift |
|---|---|
| `logLog(rows, x)` | `struct LogLogTable { let xs: [Double]; let ys: [Double] }`; `Matter.logLog(_ t: LogLogTable, _ x: Double) -> Double?` (§7 Q1) |
| `XCOM_MIN_EV = 1e3`, `XCOM_MAX_EV = 2e7`, `XCOM_LAMBDA_MAX = 1.239841984e-6 / XCOM_MIN_EV` | `Matter.xcomMinEV`, `.xcomMaxEV`, `.xcomLambdaMax` (§7 Q4: keep the literal) |
| `massAttenuation(material, ev)` | `Matter.massAttenuation(_ m: XCOMMaterial, eV: Double) -> Double?`, computed as `logLog(table, eV / 1e6)` (divide; do not multiply by 1e-6) |
| `linearAttenuation(material, ev, density = default)` | `linearAttenuation(_:eV:density: Double? = nil) -> Double?` |
| `waterAbsorption(λ)` | `Matter.waterAbsorption(_ lambda: Double) -> Double?`, computed as `logLog(segelstein, lambda * 1e9)` |
| `csqrt`, `indexFromEpsilon`, `cx`, `cdiv` | `Complex.sqrt(_:)`, `Matter.index(fromEpsilon:) -> (n: Double, k: Double)`, `struct Complex { var re, im }` with `static func / ` |
| `absorptionFromK(k, λ)` = `4πk/λ/100` | same order: `(4 * .pi * k) / lambda / 100` |
| `normalReflectance(n, k=0)` | `Matter.normalReflectance(n:k:)` |
| `oscillatorResponse(ω, ω0, γ)` → `{amplitude, lag°, power}` | `Matter.oscillatorResponse(omega:omega0:gamma:)` (`hypot`, `atan2`) |
| `lorentzEpsilon(ω, [{w0, wp, gamma}])`, `drudeEpsilon(ω, wp, γ)` | `Matter.lorentzEpsilon(omega:_ oscillators: [LorentzOscillator]) -> Complex`, `drudeEpsilon(omega:wp:gamma:)` |
| `MEDIA` (6 media; each `index(λ) → {n, k, valid}`) | `enum Medium: String, CaseIterable, Codable { vacuum, air, water, glass, silica, diamond }`; `var name`; `func index(_ lambda: Double) -> MediumIndex` |
| `freeElectronMetal({density, molarMass, valence, conductivity})`, `ZINC` | `Matter.freeElectronMetal(...) -> FreeElectronMetal { ne, wp, gamma, plasmaEV }`; `static let zinc` |
| `WORK_FUNCTIONS` | an ordered `[(metal: String, eV: Double)]`: cesium 2.14, potassium 2.3, sodium 2.36, zinc 4.33, copper 4.65, platinum 5.65 |
| `slab(R, α, d)` → `{T, R, A}` | `Matter.slab(r:alphaPerCm:thicknessCm:) -> TRA` (A = `max(0, 1−T−R)`) |
| `anchors(rows, λ)`, `bridge(λ, λa, va, λb, vb)` | `Matter.anchors(_:_:)` (clamps), `Matter.bridge(...)` (extrapolates) |

The Sellmeier coefficients, the water Cauchy fit (`1.3251 + 2946/nm²`), Debye (εs 78.36, ε∞ 5.16, τ 8.27 ps) and borosilicate `sqrt(4.6)` all move over verbatim. Silica's `Cs` are written in the JS as squares (`0.0684043 ** 2`). Keep them as `0.0684043 * 0.0684043`: `**` with an integer exponent of 2 is exact squaring in V8, so the result matches.

### 3.5 `specimens.js` → `Specimens.swift`

```swift
enum Provenance: String, Codable, Sendable { case table, model }
enum SpecimenKey: String, CaseIterable, Codable, Sendable { case oscillator, antenna, water, glass, zinc, dna, hand }
struct SpecimenOptions: Sendable { var lambda0 = 120e-9; var q = 8.0 }
struct SpecimenResult: Sendable {
  var transmission, reflection, absorption: Double?      // JS T, R, A (absent for oscillator/antenna)
  var alpha, absorbance, boneT, contrast: Double?
  var source: Provenance
  var response: SpecimenResponse  // kind, text, amplitude?, lag?, power?, regime?, value?, heating?, ejectKeMax?, resonance?
}
extension SpecimenKey {
  var name: String; var sub: String
  func evaluate(_ lambda: Double, source: Source?, options: SpecimenOptions = .init()) -> SpecimenResult
}
enum Specimens {
  static func waterAlpha(_ lambda: Double) -> (alpha: Double, source: Provenance)
  static func dnaAbsorbance(_ lambda: Double) -> Double
  static func inSeries(_ lambda: Double, source: Source?, list: [SpecimenKey] = SpecimenKey.allCases) -> [(key: SpecimenKey, before: Double, after: Double)]
}
```

The response kinds are `spring, current, twist, stretch, pass, absorb, eject, reflect, dimer, shadow, glow`. The private tables `GLASS_ALPHA` (24 rows), `TISSUE_OPTICAL` (16) and `TISSUE_RF` (4) are copied verbatim as `LogLogTable`s. `SEG_MIN = 10e-9`. The helper `xray(λ) = λ ≤ XCOM_LAMBDA_MAX && photonEV(λ) ≤ XCOM_MAX_EV`.

### 3.6 `samples.js` → `Samples.swift`

- `enum SampleKey { hydrogen, co2, water, chlorophyll, nmr }`
- `enum SampleMode: String { emission, absorption, ir, raman, a, b, nmr400 = "400", nmr60 = "60" }`
- `struct SampleAxis { kind: .lambdaLog/.lambda/.wavenumber/.ppm; from, to: Double; label: String }`
- `SampleKey` gets `value(_ x: Double, mode:) -> Double`, `toLambda(_ x: Double, mode:) -> Double` and `note(mode:) -> String`.
- `Samples.hydrogenLine(n1:n2:)`, `hydrogenLines(mode:) -> [HydrogenLine]` (48 emission lines, 12 absorption), `larmor(b0:ppm:)`.
- The CO₂ bands (2349.1, 667.4, 3716, 3609 IR; 1388.2, 1285.4 Raman), the chlorophyll Gaussians and the ethanol multiplets (J = 7.1 Hz, display half-width 1.2 Hz) are copied verbatim.
- NMR B₀ is 9.4 T for mode "400" and 1.41 T for "60".
- JS rebuilds `hydrogenLines(mode)` on every `value()` call. Cache them in a `static let` per mode; the numbers come out identical.

### 3.7 `state.js` / `presets.js` → `SpectraState.swift` / `Presets.swift`

- `struct SpectraState: Codable, Equatable, Sendable` holds:
  - `sources: [Source]` (always 3)
  - `active: Int`, `link: Bool`, `medium: Medium`, `speed: Double`, `instrument: Instrument`
  - `scope {showE, showB, showS, yaw 64, pitch 18, zoom 1}`
  - `decompose {tab: .polarization/.probe/.fourier, polarizer 30, probeMode .both, a0 1.5}`
  - `bench {arrangement: .side/.series, lambda0 120e-9, focus: SpecimenKey .water}`
  - `lab {sample .co2, mode .ir, sweep 0.46, sweeping false}`
  - `feedback {sound false, haptics true, strength 0.7}`
  - `playing true`, `preset: String?`
  - Defaults: sources A 550 nm on, B 450 nm off, C 650 nm off. `defaults()` does **not** sanitize them, so λ stays exactly `5.5e-7`.
- `editSource(state, key, value)` becomes `mutating func edit(_ e: SourceEdit)`, with `enum SourceEdit { case lambda(Double), e0(Double), temperature(Double), theta(Double), delta(Double), phi(Double), cycles(Double), kind(Source.Kind), enabled(Bool) }`.
- `sanitize(s)` becomes `mutating func sanitize()` on `Source`.
- `timeScale`, `slowMotion` and `enabledSources` become computed properties. `lambdaFromFrequency` is `SI.c / f`.
- `serialize`/`deserialize` become `JSONEncoder`/`JSONDecoder`. Write a custom `init(from:)` that uses `decodeIfPresent` for every field, so a partial blob merges over the defaults. Persist through `UserDefaults` (house rule 17).
- `PRESETS` (14) become `struct Preset { key, name, detail, note; patch: PresetPatch }`, a value type with optional `medium`, `instrument`, `bench`/`decompose`/`lab` partials and `sources: [Source]`. `applyPreset(state, key)` becomes `mutating func apply(preset:)`.

---

## 4. Precision: measured Swift-vs-V8 agreement

The probe decoded the vectors with `JSONDecoder` and ported a slice of the core. Results:

| Function (operation class) | Max relative difference | Non-bit-identical cases |
|---|---|---|
| `frequency`, `photonEV`, `wavenumber`, `kcalPerMol`, `wienPeak` (÷, ×) | 0 | 0 of 356 |
| `oscillatorResponse.power` (arithmetic only) | 0 | 0 |
| Thermal `components` λ and phase (`pow`, LCG) | 0 | 0 |
| Thermal `components` amplitude (`pow`, `expm1`, `sqrt`) | 3.2e-16 | 13 |
| `planckLambda` (`pow(λ,5)`, `expm1`) | 3.2e-16 | 16 of 330 |
| `oscillatorResponse.amplitude` (`hypot`) | 4.4e-16 | 71 |
| `oscillatorResponse.lag` (`atan2`) | 2.9e-16 | 13 |
| `massAttenuation` (`log`/`exp` in `logLog`) | 9.5e-16 | 173 of 1391 |
| `waterAbsorption` | 1.8e-15 | 220 of 1808 |
| `sanitize` λ = `pow(10, log10(λ))` | 1.6e-16 | 1 of 52 |
| `electronTrajectory` (sin, 4,000-step midpoint sums) | 2.2e-14 (abs ≤ 1.6e-15·max(1, a²)) | — |
| `ellipse.orientation` (not circular) | 1.4e-14° absolute | — |
| `polarizerTransmission` | 2.2e-16 absolute | — |
| `displayColor` hex (visible band) | — | 0 mismatches |
| table hit/miss (`null` vs value) | — | 0 mismatches |

So the only source of drift is that V8's `Math.log/exp/pow/hypot/atan2/expm1` and Apple libm differ by at most about 2 ulp.

Recommended tolerances for `ParityTests`:

- **Exact**: strings, enum keys, booleans, counts, null-ness, and anything built from `+ − × ÷ sqrt` alone.
- **Tight**: `|a−b| ≤ 1e-12·|b|`, or `≤ 1e-300` near zero, for single-expression results.
- **Chained**: `|a−b| ≤ max(1e-10·|b|, 1e-13)` for specimens, media, samples, inSeries and fieldview. The reason: `exp(−α·d)` amplifies the relative error of α by α·d, which reaches 700 near the underflow cutoffs.
- **Integrated**: `electronTrajectory` with `1e-12·max(1, a²)` absolute. The measured worst case is 1.6e-15·max(1, a²), and the JS suite's own tolerance against the exact solution is a much looser 1e-5. `meta.tolerance` in `vectors.json` states these same classes.

---

## 5. Parity vectors

The generator is `spectra-lab/tests/parity/generate.mjs`.

- `node tests/parity/generate.mjs` writes `vectors.json`.
- `node tests/parity/generate.mjs --check` exits 1 if the file is stale.

Output is deterministic. A seeded LCG (`seed = 20261003`, the same `Math.imul(seed,1664525)+1013904223 >>> 0` the suite uses) drives every input, and the generator writes no timestamps. Two separate runs produced the same bytes, sha256 `874b62e0…37a2`.

`meta.sourceSha256` (`ce2105fd…1ddf`) hashes `src/core/*`, `src/data/*` and `fieldview.js`. If it changes, regenerate the vectors and re-copy them into `SpectraTests/Fixtures/`.

**Encoding.** Each category is `{ "about": String, "cases": [...] }` with homogeneous records, so one `Decodable` struct covers each category.

- Numbers use JSON shortest round-trip form.
- Non-finite values are the strings `"Infinity"`, `"-Infinity"` and `"NaN"`. Decode them with a `JSNumber` wrapper that tries `Double` and then falls back to those strings; the probe proved this works.
- `-0` is written as `0`.
- JS `null`/`undefined` becomes `null`, so decode it as `Double?`.

| Category | Cases | Covers |
|---|---|---|
| constants | 31 | every exported constant, `ZINC.{ne, wp, gamma, plasmaEV}`, `MAX_RATIO` |
| tables | 1 | `BANDS`, `DETENTS`, `SIZE_COMPARISONS`, `WORK_FUNCTIONS`, `SERIES`, `INSTRUMENTS`, `SOURCE_KINDS`, media/specimen/sample/preset metadata incl. notes, `defaults()` |
| dataTables | 1 | the full XCOM (6 materials, 285 rows) and Segelstein (1,261 rows) tables, for a row-by-row check of the generated Swift |
| conversions | 356 | all λ↔f↔E↔ν conversions, `clampLog` |
| bandAt | 276 | `bandAt`, `subBandAt`, `ionizationClass`, exact band edges ±1e-12, `0`, `∞` |
| describe | 296 | every number and every readout string |
| spectralRGB | 501 | every nm from 370 to 790, plus random |
| displayColor | 256 | hex plus `hueName` |
| format | 138 | `sig3`, `sci`, length/frequency/energy/kcal, including binary ties 1.125, 2.5, 10.25, 100.5 and 1e21 |
| crossedDetents | 79 | every detent approached from both sides |
| nearestComparison | 80 | |
| jonesFields | 150 | `jones`, `fieldsAtPhase`, `phaseAt` |
| ellipse | 213 | 13 special cases (circular, linear, ±180) plus random |
| polarizer | 300 | |
| intensity | 200 | `intensity`, `peakB`, `radiationPressure`, `photonFlux` |
| planck | 330 | 30 temperatures from 1 K to 1e8 K × λ at 10^±3 × peak; includes the `x > 700` cutoff |
| components | 56 (752 rows) | plane, pulse and thermal × count 2/3/15/41 |
| pulse | 80 | envelope and bandwidth |
| laser | 100 | `a0`, `fieldForA0`, `quiverAmplitude`, `driftSpeed` |
| electronTrajectory | 12 (312 points) | `both`/`electric`/`magnetic`; a₀ from 0.1 to 5; up to 4,000 steps |
| oscillatorResponse | 215 | |
| lorentzEpsilon | 121 | 1–3 oscillators |
| drude | 120 | ZINC and random metals, with `indexFromEpsilon` |
| complexIndex | 71 | `csqrt` in all quadrants and on the axes, `absorptionFromK`, `normalReflectance` |
| slab | 80 | |
| anchorsBridge | 60 | |
| logLog | 12 | a synthetic edge table: at the edge, ±1 ulp, outside, NaN |
| media | 271 | six media × 271 λ including every validity boundary |
| xcom | 1,391 | every table energy, ±1e-12, midpoints, random, out of range, the lead K edge |
| waterAbsorption | 1,808 | every Segelstein point, midpoints, random, out of range |
| specimens | 1,463 | 7 specimens × ~209 λ (boundaries plus 140 random) with random E₀/λ₀, plus a no-source run |
| waterAlpha | 200 | |
| inSeries | 60 | |
| dnaAbsorbance | 201 | |
| samples | 1,821 | all 9 sample/mode pairs × the 201-point axis grid, plus the CO₂ band centres |
| hydrogenLines | 2 (60 lines) | emission (48) and absorption (12) |
| hydrogenLine | 84 | n1 1–6, n2 up to n1+14 |
| larmor | 65 | |
| sanitize | 75 | clamps and wraps, thermal Wien override |
| editSource | 81 | every key, link on and off, random active source |
| timeScale | 40 | `timeScale`, `slowMotion`, `enabledSources` |
| deserialize | 10 | garbage, `null`, `[]`, partial, `active` 2.7, −1, "2" and 7 |
| applyPreset | 30 | 14 presets × {defaults, modified state} plus an unknown key |
| fieldview | 9 states (360 `fieldAt` samples) | the UI layer (§9) |
| **Total** | **11,746** | 2.39 MiB |

---

## 6. Data tables: embed as generated Swift source

Use generated Swift source, not bundled JSON resources:

- The tables are small: XCOM is 285 rows across 6 materials, and Segelstein is 1,261 rows.
- Core functions stay non-throwing and synchronous. A bundle lookup would add a failure path to `waterAbsorption`.
- The same files compile into the `swiftc` CLI harness, the test bundle and any future widget, with no `Bundle` plumbing.

Format, as measured:

```swift
// Core/Data/SegelsteinWater.swift (GENERATED by Tools/gen-tables.mjs from spectra-lab/src/data/water.js)
enum SegelsteinWater {
  /// [λ nm, α 1/cm] pairs, flattened. 10 nm … 10 m. Segelstein 1981 via OMLC, retrieved 2026-10-03.
  static let flat: [Double] = [10, 21928, 11, 27099, /* … */ 10000000000, 0.000087097]
  static let table = LogLogTable(flat: flat)   // splits into xs / ys once (static let is lazy and thread-safe)
}
// Core/Data/XCOMTables.swift
enum XCOMMaterial: String, CaseIterable, Sendable { case water, tissue, bone, lead, zinc, pyrex }
// density g/cm³: 1, 1.06, 1.92, 11.35, 7.134, 2.23; rows [MeV, cm²/g] with repeated energies at edges
```

- Write every number with JS `String(n)`.
- The flat `[Double]` with an explicit annotation type-checks in 0.36 s. `[SIMD2<Double>]` took 2.52 s.
- All 2,522 Segelstein values and all 570 XCOM values are **bitwise** equal to the vectors (Swift literal parse vs `JSONDecoder` parse).
- **Keep the raw wavelengths exactly as they are.** Segelstein's long-wavelength rows carry float32 artefacts that come from the source file itself (`data/raw/segelstein81.dat` line 1205: `3899000064`, plus `4698999808` and others). "Cleaning" them to `3.899e9` would move the table knots and break table-point parity.
- XCOM edges are repeated energies. Lead has 9, tissue and bone 5 each, zinc and pyrex 4 each, water 0. Keep the row order, below-edge value first.
- `ParityTests.testDataTables` compares the embedded arrays to `dataTables` row by row with `==`.

---

## 7. JS quirks the Swift port must reproduce

Q1. **`logLog` edges and bounds.**
- The guard is `!(x >= rows[0][0]) || x > last`, which returns `nil`, and it catches NaN as well. Both ends are inclusive.
- The scan is `while i < n−1 && xs[i] < x: i++`, followed by `while i < n−1 && xs[i+1] == x: i++`. So **at exactly an edge the upper value wins**, just below the edge the curve interpolates toward the lower value, and just above it the curve starts from the upper value.
- `x1 == x0` returns `y1`.
- Interpolate with exactly `exp(log(y0) + u*(log(y1) − log(y0)))`, where `u = log(x/x0)/log(x1/x0)`. Do not refactor to `pow`; the vectors would drift.

Q2. **`anchors` clamps** (`λ ≤ first` returns the first value exactly; `λ ≥ last` returns the last). **`bridge` does not clamp**: it is a log-log line through two points and is used to extrapolate.

Q3. **Edge hits depend on correctly rounded division.**
- `massAttenuation` uses `ev / 1e6`, and `waterAbsorption` uses `lambda * 1e9`. Do not rewrite them as `ev * 1e-6` or `lambda / 1e-9`.
- Check: `88004.5 / 1e6 == 0.0880045` holds in both JS and Swift, and the "lead K edge > 4×" test depends on it.
- Another case: `waterAbsorption(10e-9)` evaluates `10e-9*1e9 = 10.000000000000002`, which lands inside the table (21927.99999999999).

Q4. **`XCOM_LAMBDA_MAX` uses the literal `1.239841984e-6`, not `HC_EV_M`** (1.2398419843320026e-6).
- This leaves a 0.27 ppb sliver above 1.239841984e-9 m. There `xray()` is false and Segelstein returns null, so `waterAlpha` takes the bridge branch.
- Two `BOUNDARY_LAMBDAS` cases sit on either side of it.

Q5. **Out-of-range fallbacks.**
- `waterAlpha` for λ > 10 m: Segelstein returns null, and so does `linearAttenuation("water", min(photonEV, 2e7))`, because ~1e-9 eV is far below the table. That null becomes `?? 0`, so **α = 0 with source `"model"`**.
- The tissue RF anchors clamp at 0.025 /cm beyond 300 m.
- `GLASS` below 100 nm (but above 1.24 nm) bridges from 4e5 /cm toward Pyrex XCOM.
- JS `null` coerces to 0 in arithmetic. Inside the slider range none of the XCOM lookups in `xray()` branches can return null. Use `?? 0`, not `!`, so any path that slips through behaves like the JS rather than trapping.

Q6. **`csqrt` sign rule.** `Math.sign(z.im || 1)` treats `+0`, `−0` and NaN imaginary parts as +1. `indexFromEpsilon` then takes `abs(im)`, so the sign only shows in `csqrt` itself.

Q7. **Naive complex division.** `cdiv` computes `d = b.re² + b.im²` directly, with no Smith scaling. It is safe in range: ω ≤ 1.9e22 gives d ≈ 1e89, well short of overflow. Copy it as is.

Q8. **`clamp` and NaN differ between the languages. This one was verified in Swift.**
- JS `Math.min(hi, Math.max(lo, NaN))` returns NaN.
- Swift `max(1.0, .nan)` returns `1.0`, so `min(hi, max(lo, .nan))` returns `lo`. Swift's `max(.nan, 1.0)` returns NaN.
- For bad input the JS keeps NaN and Swift clamps. NaN can only arrive through corrupted storage, which Codable rejects anyway.
- **Intentional divergence**: in Swift, `sanitize()` maps non-finite fields to the defaults (`Source()`), except that λ = 0 or −∞ goes to `10^logMin`, which matches the JS.
- The vectors exclude NaN inputs to `sanitize`.

Q9. **`sanitize` details.**
- λ becomes `pow(10, clamp(log10(λ), −13, 3))`, so every sanitized λ drifts by a few ulp. Example: 5.5e-7 becomes **5.500000000000003e-7** in V8, and the presets show it. Apple libm reproduced V8's drift exactly in 51 of 52 cases, and was 1 ulp off in the other.
- `delta = (((δ+180) % 360) + 360) % 360 − 180`, using JS `%`, which is `truncatingRemainder`, not `remainder`. This maps **+180 to −180**.
- `phi` is wrapped into [0, 360).
- Clamps: E₀ to [1e-6, 1e16], θ to [−90, 90], cycles to [1, 12], T to [1, 1e8].
- For `thermal`, λ is overwritten with `wienPeak(T)` **after** the λ clamp.

Q10. **`editSource` semantics.**
- Targets are the enabled sources plus the active one, matched by identity in JS. Swift has to match by index.
- `lambda`, `E0` and `temperature` apply a ratio, `value / src[key]`.
- `theta`, `delta` and `phi` apply a shift, `value − src[key]`.
- **Every other key** (`kind`, `cycles`, `enabled`) copies the same value to every target.
- Only the targets are re-sanitized.

Q11. **`components`.**
- `count = max(3, count)`.
- Plane sources return `[{λ, 1, rad(φ)}]`.
- Pulses: u runs from −1 to 1, `f = f0 + 2.2σ_f·u`, amplitudes are L1-normalized, and every phase equals `rad(φ)`.
- Thermal sources ignore `src.lambda`. λ comes from `wienPeak(T)·10^(−0.6 + 1.6 i/(count−1))`, amplitude is √(B_λ·λ) L2-normalized, and phase is `TAU·rand()` from a **fresh LCG seeded 12345 on every call**.
- Swift: `var r: UInt32 = 12345; r = r &* 1664525 &+ 1013904223; Double(r) / 4294967296`. This is bit-exact with `Math.imul … >>> 0`, verified.

Q12. **`planckLambda`** returns exactly 0 when `x = hc/(λkT) > 700`, and otherwise `a / expm1(x)`.

Q13. **`ellipse`.**
- `kind` is linear when `|sin2χ| < 1e-9`, and circular when `||sin2χ| − 1| < 1e-6` (sin2χ is clamped to ±1 first).
- `sense` is `nil` for linear light.
- **For circular light, `orientation` is numerical noise.** It comes from `atan2` of two ~1e-17 values, giving 7.7085° for (45°, 90°). The decompose readout shows `Math.round(e.orientation)°`, so it reads "8°". This is a JS display bug. Swift should print "—" for circular light, and the parity test should skip `orientation` when `kind == circular`. Swift happens to reproduce 7.7085° bit for bit anyway.

Q14. **Lookups with fallbacks.**
- `bandAt` returns the first band with `lo ≤ λ < hi`, else radio. λ = 0 gives gamma.
- `subBandAt` splits gamma at the literal `1.2398e-12` ("Gamma above 1 MeV"). Visible light gets `"Visible · <hue>"`. Above 1,000 m it falls back to the band name.
- `ionizationClass` uses `ev ≥ 10` and then `ev > 3.0996`.

Q15. **`spectralRGB` below 380 nm** enters the `nm < 490` branch, so g is negative. It is then multiplied by `k = 0`, giving `[0, −0, 0]`. Keep the `k = 0` gate rather than adding an early return. The outputs are identical either way, and the gate keeps the structure 1:1 with the JS.

Q16. **`displayColor`.**
- Non-visible bands return the band's **uppercase** palette hex (`#E2D4FF`).
- Visible light returns **lowercase** hex from `lift(c) = 0.16 + 0.84·c^0.8`, then `Math.round(clamp01·255)`.
- For non-negative values `Math.round` equals `rounded(.toNearestOrAwayFromZero)`. Swift's `rounded()` defaults to that rule; `Math.round(-0.5)` is `-0`, but negatives never occur here.

Q17. **Specimen branch details.**
- **OSCILLATOR**: regime `below` when λ > 1.15·λ₀, `above` when λ < λ₀/1.15, otherwise `on`. Q = 8 and λ₀ = `options.lambda0 ?? 120e-9`. The bench passes `state.bench.lambda0`.
- **ANTENNA**: current = max over n ∈ {1, 3, 5}, with weights {1, 0.55, 0.4}, of `w/√(1+x²)`, where `x = Q(f/fn − fn/f)`, f0 = 100 MHz and Q = 8. The text says "resonant" when current > 0.5.
- **WATER**: heating = `(α·100·I/4.18e6)·60` K/min, where I = `intensity(src.E0)` and I = 0 without a source.
- **GLASS** uses `MEDIA.glass.index(λ).n` whatever `valid` says: Sellmeier for 0.3–2.5 µm, √4.6 (valid) at 1 mm and above, and the invalid placeholder 1.5 everywhere else outside X-rays.
- **ZINC** text:
  - `keMax.toFixed(2) + " eV"` below 1,000 eV, else `(keMax/1e3).toFixed(1) + " keV"`.
  - `${phi}` prints `4.33`. JS prints integral numbers without ".0", so use a `jsString(_:)` helper for any number interpolated into text.
- **DNA**: in band (150–400 nm), A = `dnaAbsorbance` and source `"model"`; otherwise A = 0 and the source is the water source. T = `T_water·10^(−A)`.
- **HAND**:
  - X-ray: `boneT = exp(−μ_bone·1 − α_t·2)`. Otherwise `exp(−1.2α_t − 2α_t)`, with source forced to `"model"`.
  - `contrast = softT > 1e-12 ? 1 − boneT/softT : 0`.
  - The text uses `Math.round(contrast·100)`.
- **inSeries**: specimens with no T (oscillator, antenna) pass the beam through.

Q18. **Samples.**
- Hydrogen value = Σ strength·Lorentzian in **log10 space**, with half-width 0.0012 decades.
- Strengths: `(n1/n2)^3`, times `1/n1` for emission, then normalized by the maximum. Absorption is Lyman only.
- The CO₂ envelope `bandShape` has a lobe of `(|d|/12)·exp(0.5 − d²/288)`. Perpendicular bands add a Q branch of `1.0·lorentz(hw 1.2)`, and Raman uses `lorentz(hw 2.5)`.
- The water sample returns 0 when the lookup is null. Its value is the absorbance of a 1 µm film, `α·1e-4/ln10`.
- NMR is normalized by `nmrSpectrum(1.22, B0)`. `toLambda` for NMR is `C / larmor(B0, x)`.
- Axis grid used by the tests and the lab: `lambda-log` uses `from·(to/from)^u`, everything else uses `from + (to−from)·u`.

Q19. **`deserialize`.**
- `active = clamp(s.active | 0, 0, 2)`. `|0` truncates toward zero and maps non-numbers to 0: 2.7 gives 2, "2" gives 2, −1 gives 0, 7 gives 2.
- `lab.sweeping` is forced to false.
- `sources.length` must be 3, otherwise the result is the defaults.
- Unknown top-level keys pass through in JS and are dropped by Codable. This is harmless; compare only known keys.
- `medium` is not validated in JS, and an unknown key would crash `MEDIA[...]` in `fieldview`. Swift should decode an unknown medium as `.vacuum`.

Q20. **`applyPreset`.**
- The order is `{...state, medium: "vacuum", link: false, active: 0, ...patch}`, then the sources are sanitized, the `decompose`/`bench` patches are shallow-merged, and `lab` is merged with `sweeping: false`. Finally `preset = key`.
- An unknown key returns the state untouched, and `preset` stays unset.
- The laser preset sets `E0: 8.03e12` (a₀ ≈ 2 at 800 nm) together with `decompose {tab: probe, a0: 2, probeMode: both}`.

---

## 8. Formatting: JS `toFixed` and `toPrecision` in Swift

Verified in Swift: `String(format:"%.Nf")` rounds **exact binary ties to even**, while JS rounds them **away from zero**.

| Input | printf | JS |
|---|---|---|
| 0.125 at 2 places | `0.12` | `0.13` |
| 2.5 at 0 places | `2` | `3` |
| 10.25 at 1 place | `10.2` | `10.3` |
| 100.5 at 0 places | `100` | `101` |

Non-tie cases agree, because both work from the exact binary value. For example, JS `(1.005).toFixed(2)` is `"1.00"`, and so is printf. Swift's `FormatStyle` rounds the shortest decimal instead, so it would print `1.01`. **Do not use `FormatStyle` for parity strings.**

`JSFormat.toFixed(x, f)` passed all 138 format cases except 1e21 (rule 1 fixes that case):

1. If `|x| ≥ 1e21`, return JS `String(x)` (`"1e+21"`).
2. Otherwise compute `wide = String(format: "%.\(f+40)f", x)`. Apple's libc prints the exact binary expansion.
3. If digit f+1 after the point is `5` and every later digit is `0`, the value is an exact tie. Nudge x away from zero by half a unit and format with `%.\(f)f`.
4. Otherwise format with `%.\(f)f` directly.

`JSFormat.toPrecision(x, 3)`: let e be the decimal exponent of the value **after** rounding to 3 significant digits.

- If `e < −6 || e ≥ 3`, use exponential form: `d.dd` + `"e"` + sign + `|e|` (JS writes `1.23e-7` and `1e+21`, with no zero padding).
- Otherwise use `toFixed(x, 2 − e)`.
- Apply the same tie rule in both branches.

Other rules to copy:

- `engineering()` uses a 0.9995 threshold, and non-finite or zero values become `"0 unit"`.
- `formatFrequency` switches to `sci` at 1e19 Hz or more.
- `sci` can print a `10.00` mantissa, e.g. 9.996e5 prints as `10.00×10⁵`. This is a JS quirk; keep it.
- `formatKcal` uses `sig3` for 0.01 ≤ k < 1e5 and `sci` otherwise.

Unicode code points must match exactly:

- µ is **U+00B5 MICRO SIGN**, not U+03BC. The two are not canonically equivalent, so Swift `==` treats them as different.
- × is U+00D7, ⁻ is U+207B, and the superscript digits are ⁰ U+2070, ¹ U+00B9, ² U+00B2, ³ U+00B3, ⁴–⁹ U+2074–2079.
- The middle dot is U+00B7 and the arrow is U+2192.

---

## 9. Display-specific JS the Swift UI layer needs

### 9.1 `src/ui/fieldview.js` → `Display/FieldView.swift` (parity-tested in the `fieldview` category)

**Units**

- Distance is measured in **reference wavelengths**. The reference is the first enabled source, or `sources[0]` when none is enabled. Time is screen seconds.
- Each component carries `r = ref.λ / c.λ`. Components with `r > 24` or `r < 1/24` (`MAX_RATIO = 24`) are hidden.
- `hiddenNote` reads: "Source A, B is too far from the reference wavelength to draw at this zoom".

**Component lists**

- Thermal sources use `components(s, 15)` with `scale ×0.45`.
- Pulses and plane waves use **one carrier** `{λ, amp 1, phase rad(φ)}`. Pulses are not expanded into components here.

**Scale and colour**

- `scale = E0 / ΣE0(enabled)`, where the sum falls back to 1 when it is 0.
- `color = displayColor(s.λ)`. `tag = THEME.sources[i]`, which is `#66f58f`, `#ff8fb8` and `#8fd3ff`.

**Field at a point**, for z and t:

- `q = TAU·r·n·z − TAU·r·speed·t + phase`.
- The medium occupies only `z > 0`. Inside it the amplitude is multiplied by the Fresnel transmission `2/(1+n)` (real n) and by `exp(−TAU·r·k·z)`.
- An invalid medium index is treated as **n = 1, k = 0**. The readouts, by contrast, use the fallback `m.n` (§9.2), so the two disagree for invalid ranges.

**Pulse envelope**

- The envelope rides with the carrier and repeats every `TAU·(cycles·2.2 + 3)`.
- `centre = (((TAU·r·speed·t) % P) + P) % P − P/2`, written with `truncatingRemainder`.
- The envelope is `pulseEnvelope(src, TAU·r·n_or_1·z − centre)`.

**Return value**

- `fieldAt` returns `{ex, ey, n}`. `nAt` is the n of the **last** component evaluated inside the medium. B is drawn as `n ẑ × E`.
- `only` restricts the sum to one source index.

**Cache**

- The JS cache key is `JSON.stringify([sources, medium])`. In Swift, recompute when `(sources, medium)` changes, using `Equatable` on an `@Observable` model.

### 9.2 Other UI constants and behaviour found in `src/ui` and `src/instruments`

- **Clock**: `app.t` grows without bound. `slowMotion = f_ref/speed`, and the transport displays `sci(slowMotion)× slower`.
- **Metal precision**: in Metal, compute `TAU·r·speed·t mod TAU` per component in Double on the CPU, and pass the phase offset to the GPU. A Float `t` loses phase precision after about 10³ s.
- **Scope**: `Z0 = −1.6`, `Z1 = 1.6`, `AMP = 0.62`, `N = 260` samples.
  - Camera: yaw/pitch rotate, `S = min(w/4.5, h/1.95)·zoom`. Defaults: yaw 64°, pitch 18°, zoom 1. Pitch is clamped to [−60, 80].
  - Drag sensitivity: 0.4 °/px for yaw, 0.3 °/px for pitch.
- **Decompose / polarization**: the trail is 120 samples over one reference period (`t − i/(120·speed)`). The Ex/Ey strips span `2.2/speed` s, with the newest sample on the right.
  - The polarizer projection is `p = ex·cos α + ey·sin α`.
- **Decompose / probe**: trajectory `electronTrajectory(src, a0, mode, 3, 900)`, cached by `(a0, mode, θ, δ)`.
  - Positions are projected onto the polarization direction.
  - Electron animation phase: `η = (TAU·speed·t·0.5) mod (TAU·3)`.
  - The drift-frame inset subtracts `v_d = z_end/t_end`.
- **Decompose / Fourier**:
  - Time trace: `(ex + ey)·0.707`, over a window of `4/speed` s.
  - Stems: `components(src, 41)` for every source, plotted at `a = amp·scale` on a log-f axis padded by ±0.15 decades, with a minimum span of 0.4 decades. Stem colour is `describe(λ).color`.
  - Prism inset: minimum deviation `2·asin(min(1, n·sin 30°)) − 60°` for a 60° prism, with the spread between colours exaggerated ×8.
  - This is the seed of the new Fourier visualizer. Analytic stems come from `components`, and live spectra (microphone, RF) will need vDSP. Those are not part of parity.
- **Lab**: `xAt(s, u)` (§7 Q18). Sweeping advances `sweep += dt·0.06` until it reaches 1. Retuning calls `setLambda(s.toLambda(xAt(s, sweep), mode))`. Axis text:
  - wavenumber: `sig3(x) + " cm⁻¹"`
  - ppm: `x.toFixed(2) + " ppm"`
  - wavelength axes: `describe(...).text.lambda`
- **Dials** (`ui/controls.js`), as `{range, quantization}`:
  - λ: log [−13, 3]
  - T: log [0, 7], formatted `toPrecision(4)` below 1e4, `sci` otherwise
  - E₀: log [−3, 13], which is narrower than sanitize's [1e-6, 1e16]
  - θ: lin [−90, 90], rounded to 1°
  - δ: lin [−180, 180], 1°
  - φ: lin [0, 360], 1°
  - N: lin [1, 12], rounded to 0.5
  - The dial accents are the Orbitals scheme: λ follows `describe(λ).color`, T amber, E₀ `#61b3ff`, θ mint `#59f0b0`, δ rose `#ff8fb8`, φ violet `#c799ff`, N amber.
- **Band jump buttons**: `{gamma: 1.24e-12, xray: 20.7e-12, uv: 254e-9, visible: 550e-9, ir: 9.3e-6, microwave: 0.1224, radio: 3}`.
- **Readouts** (`app.js`): `n = medium == vacuum ? 1 : m.n`. The fallback n is used even when `valid` is false.
  - Rows show B₀ from `peakB(E0, n)`, intensity from `intensity(E0, n)`, photon flux ×1e-4 per cm²·s, and the period `sci(1/f, "s")`.
  - In a medium: `n.toFixed(4)` and `speed (1/n).toFixed(3) c`.
- **Detents and haptics**: on every λ edit, fire `crossedDetents(log10(before), log10(after))`. The ionizing line gets its own pulse; band edges get a click.
  - The JS rate-limits haptics to 35 ms, and ticks to 45 ms.
  - Sound pitch: `110·2^(4·(log10 f − 5.5)/16)` Hz. Core Haptics and AVAudioEngine replace these in the native app.
- **THEME** (`ui/draw.js`):
  - plot `#040807`, phosphor `#66f58f`, amber `#ffbf5e`
  - E `#61b3ff`, B `#ff5c7a`, S `#ffbf5e`
  - Ex `#1aedff`, Ey `#ffe82e`
  - text `#e8f1ec`, muted `#9cb5a6`, dim `#7e978a`, ionizing `#ff8f6b`
  - grid `rgba(102,245,143,0.06)`, axis `rgba(156,181,166,0.35)`

---

## 10. Hooks for the new Spectra modules

These modules are not in the JS, so there is nothing to keep parity with.

- Keep `Spectrum.describe`, `band(at:)`, `Medium.index`, `Wave.components` and `Specimens` pure and `Sendable`. The Antenna/Frequency simulator, the Fourier visualizer and the node graph can then call them from any actor.
- The `ANTENNA` specimen, a half-wave dipole with Q 8 and odd harmonics, is the seed of the antenna-style simulator.
- The new RF math (dipole, monopole and patch patterns; cellular, Wi-Fi and GNSS band tables; link budgets) has no JS reference. Give it closed-form XCTest checks in the style of `core.test.mjs`, for example a half-wave dipole's 2.15 dBi and free-space path loss `20·log10(4πd/λ)`. Golden vectors from Swift alone would only detect regressions.
- Tag every new readout with the same **table/model** provenance, extended with **live** for sensor-derived values. The prototype's honesty rule (README "Physics and provenance") carries over directly.

---

## 11. Risks and open items

- **Branch flips at thresholds.** A text or `kind` result can differ if a transcendental output lands within ~1e-15 of a threshold. The thresholds are `T > 0.5` (glass), `softT > 0.05` (hand), `A > 0.3` (DNA) and `Math.round(contrast·100)`.
  - None of the current vectors sits that close.
  - The threshold comparisons that use only arithmetic (oscillator regime, antenna `current > 0.5`) are bit-exact.
  - If a string mismatch appears, check the controlling number before suspecting the port.
- **Unreachable states are not vectored**: NaN fields in `sanitize`; λ < 6.2e-14 m (beyond `LOG_MIN`) in the specimens; `fieldAt` at very large t.
- **Regenerating**: after any change to `spectra-lab/src/core` or `src/data`, run `node tests/parity/generate.mjs`, copy `vectors.json` into `SpectraTests/Fixtures/`, and re-run `Tools/gen-tables.mjs`. `meta.sourceSha256` and `generate.mjs --check` will report staleness.
