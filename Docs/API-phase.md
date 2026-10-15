# API: Phase-space engine (`Spectra/Phase/`)

Owner: **phase-engine**. Consumers: spectrum-ui (Decompose → Phase space, `Render/Scenes/Wigner*.swift`), scope (Spectrogram · Wigner–Ville · Pseudo-Wigner modes), radio-ui (Fourier time–frequency view, FMCW chirp, Antenna → Aperture phase space), spin-ui (FID chirp in a gradient), patch (Wigner and Marginal nodes).

## Ground rules

- **Utkarsh's convention (C).** Everything follows his convention and his definition of the spacetime Wigner distribution (`Docs/research/wigner-spacetime.md`); field notes must credit him ("Spacetime Wigner distribution: Utkarsh's construction and convention (C)").

  ```
  ψ̃(k, ν) = ∫ ψ(x, t) e^{−i(k·x − 2πνt)} dx dt          ψ(x, t) = ∫ ψ̃(k, ν) e^{+i(k·x − 2πνt)} dν dk/2π
  Φ(ν, k; x, t) = ∫∫ ψ*(x − ξ/2, t − τ/2) ψ(x + ξ/2, t + τ/2) e^{−i(k·ξ − 2πντ)} dξ dτ
  ```
  k is angular (rad/m, measure dk/2π), ν is ordinary (Hz, measure dν). A plane wave e^{i(k₀x − 2πν₀t)} lands at **(+k₀, +ν₀)**. In time alone, positive frequency is e^{−2πiνt} (the physicist's sign); in space, positive k is e^{+ikx}. Engineering I + jQ (e^{+j2πft} = +f, as `RF.IQBuffer` and `FIDSignal.baseband`) enters through `Signal.fromIQ`, which conjugates, so +f lands at +ν and the picture equals the usual engineering Wigner–Ville.
- **Pure and portable.** Foundation, Accelerate and simd only; Core supplies `Matter.Medium` (indices) and `SI.c`. Every type is a `nonisolated` `Sendable` value; `Phase.DFT` is a `final class` marked `@unchecked Sendable` (vDSP setups are immutable after `init`). No global mutable state.
- **Threading.** Everything is a synchronous pure function. Run the expensive ones (`spacetimeWigner`, `phaseSpaceScene`, long Wigner–Ville) in `Task.detached` and hand the `Sendable` result to the main actor. `Tools/harness/phase/IsolationProbe.swift` proves this compiles under the app's Swift 6 / default-MainActor settings.
- **Precision.** Double inside, `Float` only at the display boundary (`floatValues()`, `signedUnit()`). Values are |z|²·Δt, so amplitudes must keep |z|² representable (|z| ≲ 1e150).
- **Robustness (verified 2026-10-08, `Docs/notes/phase-engine-verify.md`).** Nothing traps or returns NaN for empty, non-finite or absurd inputs:
  - Non-finite samples count as 0 everywhere (`wigner`, `spectrogram`, `spectrum`, `oversampled2x`, both `timeFrequency` entry points before the 2× interpolation, `spacetimeWigner`, `marginalReport`), so one sensor glitch never blanks or NaNs an image.
  - A record without a usable step (Δ = 0, NaN or ±∞) gives an **empty** plane (0 rows, 0 columns); `timeFrequency` also requires a positive sample rate. **An irregular stream (BLE RSSI has nominal rate 0) must be resampled to a uniform rate first**, or the image is empty.
  - Sizes are clamped, never overflowed: `bins` ≤ `Phase.maxBins` (2²⁰), Φ bins ≤ `Phase.maxSpacetimeBins` (2¹²), `keepFull` only up to `Phase.maxFullValues` (2²⁶ Float, else `full == nil`), scene grid 8…`Phase.maxSceneGrid` (128), smoothing half-width ≤ 2¹⁶, spectrogram window ≤ 2²¹. A 1-D Wigner or spectrogram keeps rows × columns ≤ `Phase.maxPlaneValues` (2²⁵): a longer record with `rows: .all` gets evenly spread rows (`Phase.boundedRows`), M1 stays exact, and `coversRecord` is false (the M2 identity needs every sample as a row).
  - Gaussian windows with σ NaN/≤ 0 become one-sample windows; Fresnel shear/propagation with z non-finite or k₀ ≤ 0 is the identity; `Axis.nearestIndex` clamps in Double (no `Int(1e300)` trap); `value(ix:it:ck:cnu:)` and `kSliceCube(column:)` return nil outside the grid.
- **Provenance.** Simulated packets and apertures are **MODEL**. A Wigner image of a live stream is "MODEL · LIVE" (the transform is a model-free identity, but the view is a computed quasi-distribution). The marginal strip shows **CONSISTENT**, **ALIASED**, **SMOOTHED** or **INCONSISTENT** (`MarginalReport.Status.badge`).
- **Colour.** Wigner values are signed. Use a diverging map: positive warm orange, negative cool blue (as in Utkarsh's poster), symmetric about zero: `plane.signedUnit()` gives values / max|value| in −1…1. Spectrograms and |ψ|², |ψ̃|² are ≥ 0.

## The discrete rules, and what is exact

The six rules of `wigner-spacetime.md` are implemented as follows (and proved by the oracles):

1. **Lag window ≤ half the padded grid.** Half-lags m use a lag DFT of length M (= the number of ν or k columns) and |m| ≤ M/2 − 1; samples outside the record are zero, never wrapped. No double-counted lags, so no checkerboard.
2. **2× oversampling or the analytic signal.** The half-lag Wigner repeats every fs/2 in ν (π/Δx in k). `Band.positive` shows [0, period): analytic signals and positive-frequency fields. `Band.centered` shows [−period/2, period/2): complex fields sampled ≥ 2× (use `oversampled2x()`).
3. **Real signals** go through `Signal.analytic(real:…)` (FFT Hilbert transform; Re z = x exactly).
4. Φ fixes ψ only up to a global phase.
5. Exact Wigner, pseudo-Wigner (lag window), smoothed pseudo-Wigner (lag + time window) and spectrogram are all available; only the unsmoothed Wigner has exact marginals.
6. Free fields live on their dispersion shell (`Phase.Dispersion`); Fresnel diffraction shears W(x, k) (`fresnelShear`); an aperture's far-field pattern is its k marginal (`Aperture.farField`).

Exact identities (verified to ≤ 1e-12, typically 1e-15):
- **M1** Σ_ν W dν = |z[n]|² at every row (any lag window with h(0) = 1, no time smoothing). Φ: Σ Φ dν dk/2π = |ψ(x,t)|² at every grid point.
- **M2** Σ_t W Δt = |Z(ν)|² + |Z(ν + period)|² at every column when the lag covers the record (`bins ≥ N`, `.full`) and every sample is a row. The second term is the rule-2 alias; `Phase.Spectrum.alias` / `MarginalReport.aliasLevel` report it. For an analytic or oversampled field it is ≤ 1e-9 of the peak, so M2 = |Z|² to that level. Φ: four alias partners (k and/or ν shifted by half a period).
- **P** Σ W Δt dν = Σ|z|²Δt = Σ (|Z|² + alias) dν.
- **Reality** Im W ≈ 1e-16 of Re W; Φ* = Φ.
- **Moyal** Σ W_f W_g Δt dν = |⟨f,g⟩|² + |⟨f,(−1)ⁿg⟩|² (`moyalReference`).

## Basic types

| Type | What |
|---|---|
| `Phase.Domain` | `.time` (columns ν in Hz, kernel e^{+2πiντ}) or `.space` (columns k in rad/m, kernel e^{−ikξ}). |
| `Phase.Band` | `.positive` [0, period) or `.centered` [−period/2, period/2). Helpers map columns to DFT bins. |
| `Phase.Axis` | `start`, `step`, `count`; `value(i)`, `values`, `end`, `nearestIndex(_:)`, `fractionalIndex(_:)`, `extent` (pixel edges). |
| `Phase.DFT` | Double complex DFT on vDSP (`.negative` = e^{−i}, `.positive` = e^{+i}, unscaled). Fast for N = f·2ⁿ, f ∈ {1,3,5,15}, n ≥ 3 (and 4) — `goodSize(atLeast:)`, `isFast(_:)`; any other N uses an exact O(N²) fallback. `execute` (pointers) and `transform` (arrays). `Phase.dft2D` for 2-D. |
| `Phase.Signal` | Complex record `re`, `im`, `step`, `origin`, `domain`. `init(real:…)` (not analytic), `init(count:step:origin:domain:_ f:)`, `fromIQ(i:q:sampleRate:)` / `fromIQ([SIMD2<Double>], sampleRate:)`, `toIQ()`, `intensity()`, `energy()`, `conjugated()`, `sanitized()` (non-finite → 0), `slice(_:)`, `+`, `scaled(_:)`. |
| `Signal.analytic(real:step:origin:domain:padding:)` | Analytic signal in convention (C) (time: x − iH[x]; space: x + iH[x]). `padding: .linear` (zero-padded ≥ 2N, default) or `.circular` (whole-period records). Float overload `analytic(real: [Float], sampleRate:)`. |
| `signal.oversampled2x(padding:)` | Band-limited 2× interpolation (z′[2n] = z[n] exactly). |
| `Phase.spectrum(_ signal, bins: M, band:)` → `Spectrum` | `axis`, `power` (|Z|² on the M columns), `aliased`, `alias`, `peak`. |
| `Phase.Plane` | Signed image, rows = t (or x), columns = ν (or k), row-major `values: [Double]`. `kind` (`.wigner .pseudoWigner .smoothedPseudoWigner .spectrogram .closedForm .fresnelSheared`), `rowAxis`, `columnAxis`, `band`, `rowMeasure` (Δt), `columnMeasure` (dν or dk/2π), `imaginaryResidual`, `rowIndices`, `coversRecord`. `value(row:column:)`, `row(_:)`, `column(_:)`, `minValue`, `maxValue`, `absMax`, `floatValues()`, `signedUnit()`, `rowMarginal()` (M1), `columnMarginal()` (M2), `total` (P), `innerProduct(_:)` (Moyal), `binnedColumns(_:)` (keeps M1), `columnIndex(_:)`, `rowIndex(_:)`. |
| `Phase.Cube` | (a, b, c) block for the Φ volume: `axisA/B/C`, `labels`, `values`, `value(_:_:_:)`, `minValue`, `maxValue`, `absMax`, `floatValues()`, `signedUnit()`. |
| `Phase.Grid2D` | Non-Wigner heat maps (|ψ(x,t)|², |ψ̃(k,ν)|², M2): `rowAxis`, `columnAxis`, labels, `values`, `unitValues()`, `argMax`. |

## Time–frequency and space–wavenumber Wigner

```swift
Phase.wigner(_ signal: Signal, options: WignerOptions = .init()) -> Plane
WignerOptions(bins: Int? = nil,                // M; nil = goodSize(≥ N): the exact Wigner of the record
              lag: LagWindow = .full,          // .full | .rectangular(halfWidth:) | .hann(halfWidth:) | .gaussian(halfWidth:sigma:)
              smoothing: SmoothingWindow = .none,  // .hann(halfWidth:) | .gaussian(halfWidth:sigma:) — smoothed pseudo-Wigner
              rows: RowSelection = .all,       // .count(256) | .stride(n) — live views of long streams
              band: Band? = nil,               // nil: .positive (time), .centered (space)
              columnBinning: Int = 1)          // average groups of columns (preserves M1)
Phase.wignerVille(real: [Double], step:, origin:, domain:, options:) -> Plane     // analytic + wigner
Phase.spectrogram(_ signal, window: .hann(length:) | .gaussian(length:sigma:) | .rectangular(length:), bins: M, rows:, band:) -> Plane
```

The spectrogram sits on the same column grid as an M-bin Wigner (side-by-side comparison); its window is normalized so Δt Σw² = 1 (time marginal = |z|² smoothed by w², total = record energy).

**Live views** (`TimeFrequencyRequest`, `TimeFrequencyImage`):

```swift
Phase.timeFrequency(real: [Float], sampleRate:, origin:, request:) -> TimeFrequencyImage     // analytic, 0…fs/2
Phase.timeFrequency(complex: Signal, oversample: true, request:) -> TimeFrequencyImage       // 2× → −fs/2…fs/2
TimeFrequencyRequest(mode: .wignerVille | .pseudoWigner | .smoothedPseudoWigner | .spectrogram,
                     rows: 256, columns: 256, lagHalfWidth:, smoothingHalfWidth:, spectrogramLength:, maxBins: 16_384)
image.plane                        // rows × columns
image.timeMarginal, image.intensity        // M1 of the image and |z(t_row)|² (equal for WV / pseudo)
image.frequencyMarginal, image.spectrum    // M2 of the image and |Z(ν)|² on the columns
```

`.wignerVille` uses M = columns·2ᵖ ≥ N (the exact Wigner of the whole record, capped at `maxBins`) and bins the columns down to `columns`; `.pseudoWigner` uses a Hann lag of `columns/2 − 1`; `.smoothedPseudoWigner` adds a Hann time window of ±2 row strides. A record with no positive, finite sample rate returns an empty image (all arrays empty) — check `image.plane.isEmpty`.

## Apertures and Fresnel (Radio → Antenna → Aperture phase space)

```swift
let ap = Phase.Aperture.uniformArray(elements: 8, spacing: 0.5 /*λ*/, steerFromBroadsideDeg: 30,
                                     wavelength: 1, samplesPerElement: 2, weights: nil, guardElements: nil)
let ap2 = Phase.Aperture.continuous(width: 10 /*λ*/, illumination: .uniform | .cosine | .gaussian(edgeTaperDB: 10),
                                    steerFromBroadsideDeg: 0, wavelength: 1, samplesPerWavelength: 8, guardFraction: 0.5)
let w = ap.wigner()                                   // W(x, kₓ), exact, centred band
ap.farField(from: w)                                  // [FarFieldPoint(thetaDeg, kx, power 0…1)] for |kₓ| ≤ k
ap.farField(from: w, anglesDeg: [...])                // any angles (kₓ = k sinθ wrapped into the period), exact between columns
Phase.MarginalCurve(plane: w)                         // the k (or ν) marginal as a continuous trig polynomial: value(atColumnValue:), peak
ap.farFieldPower(kx:)                                 // |Ĩ(kₓ)|² directly
Phase.fresnelShear(w, distance: z, wavenumber: k0, model: .paraxial | .angularSpectrum, rowAxis: nil, interpolation: .fourier | .cubic)
Phase.fresnelPropagate(signal, distance: z, wavenumber: k0, model:, padding: 4)
```

- θ is measured **from broadside** toward +x (RF's `RF.Arrays` measures from the axis: θ_axis = 90° − θ). Steering phase e^{+ik sinθ₀ x} (convention C). The k marginal equals RF's `normalizedAF²` exactly, at every angle (oracle: 481 angles between the columns): with half-lags |m| ≤ M/2 − 1 the marginal is a trigonometric polynomial that `MarginalCurve` evaluates exactly and normalizes to its true peak.
- Size: the Wigner of an N-sample aperture is N × M doubles (the 200 λ dish at 8 samples/λ: 3201 × 3840 = 98 MB, ≈ 95 ms). In-app ranges (arrays ≤ 64 elements, dish ≤ 200 λ, horn ≤ 20 λ) stay exact; far larger requests keep evenly spread rows (see Robustness), and the far field is then approximate — use `farFieldPower(kx:)` for an exact pattern.
- Point-element arrays are sampled with `samplesPerElement` (even) points per spacing, zeros between: the element spectrum repeats every 2π/d, so the half-lag window holds whole grating periods and M2 = 2|Ĩ|² exactly — normalized patterns are exact, and grating lobes appear where `RF.Arrays.gratingLobes` puts them.
- `fresnelShear` implements W_z(x, k) = W₀(x − z k/k₀, k) (paraxial, exact) or the ray shear z k/√(k₀² − k²). `.fourier` (default, same grid) is a band-limited shift; `.cubic` resamples onto a custom `rowAxis` (e.g. a window that follows the beam, or x/z for the far field). Content shifted out of the record is lost.

## Spacetime Φ

```swift
let field = Phase.Field(x: xAxis, t: tAxis) { x, t in SIMD2(re, im) }   // x-major: index ix·nt + it
let w = Phase.spacetimeWigner(field, options: SpacetimeOptions(
          kBins: nil, nuBins: nil,              // nil = goodSize(≥ nx/nt): the exact Φ
          lagX: .full, lagT: .full,             // pseudo windows allowed (M2 then smoothed)
          kBand: .centered, nuBand: .positive,
          keepFull: false,                      // keep the 4-D Φ as Float (nx·nt·M_x·M_t; 21 MB at 48⁴)
          kSlice: nil))                         // also return the (x,t,ν) cube at the k nearest this value
w.m1, w.m1Grid      // (x, t) ≈ |ψ|²          w.m2, w.m2Grid      // (k, ν) ≈ |ψ̃|²          w.total   // P
w.kIntegrated       // Cube (x, t, ν) = Σ_k Φ dk/2π = the temporal Wigner at each x (the default volume)
w.nuIntegrated      // Cube (x, t, k) = Σ_ν Φ dν = the spatial Wigner at each t
w.kSlice, w.kSliceIndex, w.kSliceCube(column:)     // Φ at one k column (from `kSlice` or `full`)
w.spatialWigner(atT:) -> Plane        w.temporalWigner(atX:) -> Plane      // partial marginals (= the 1-D Wigners, oracle)
w.value(ix:it:ck:cnu:)                // needs keepFull
w.minValue, w.maxValue, w.argMin, w.argMax ([ix, it, ck, cν]), w.imaginaryResidual, w.exactM2, w.elapsed
Phase.spectrum(field, kBins:, nuBins:, kBand:, nuBand:) -> FieldSpectrum   // |ψ̃(k, ν)|² (Grid2D) + aliased
Phase.marginalReport(w, field:) -> MarginalReport   // m1Error, m2IdentityError, m2Error, aliasLevel, parsevalError,
                                                    // spectralParsevalError, realityResidual, energy, status (.badge)
Phase.spacetimeWignerPoint(field, ix:, it:, options:) -> (re, im)   // reference: plain complex 2-D DFT at one point
```

Cost: a 48 × 48 grid with 48 × 48 lags (5.3 M values) takes **56 ms of CPU on an M1 Max** (`-O`; 74 ms with `keepFull`) — inside the 250 ms iPhone budget. Debounce knob drags and compute in `Task.detached`.

## Dispersion, units and packets

```swift
Phase.Dispersion.vacuum | .medium(Matter.Medium) | .plasma(plasmaFrequency: Hz) | .waveguide(cutoffFrequency: Hz) | .taylor(Taylor)
d.angularFrequency(wavenumber:) / frequency(wavenumber:) / wavenumber(frequency:)   // nil below cut-off
d.refractiveIndex(frequency:) -> (n, valid), d.isValid(frequency:), d.groupVelocity(frequency:), d.phaseVelocity(frequency:)
d.taylor(atFrequency:direction:) -> Taylor(k0, omega0, groupVelocity, gvd)        // linear/quadratic model around a carrier
d.shell(kRange:count:) -> [ShellPoint(k, nu, valid)]                              // overlay on the (k, ν) view (SI)
d.title, d.formula                                                                  // "Plasma (ionosphere)", "ω² = ω_p² + c²k²"

Phase.DisplayUnits(referenceFrequency:) / (referenceWavelength:)    // λ_ref = c/ν_ref, T_ref = 1/ν_ref
units.length(m) / time(s) / wavenumber(rad/m) / frequency(Hz) and back: metres, seconds, radPerMetre, hertz
Phase.ShellModel(dispersion, units: units)       // the relation in display units: omega(k̂), frequency(k̂), wavenumber(ν̂),
                                                 // groupVelocity(ν̂) (in c), taylor(atFrequency:), shell(kRange:count:)
```

Media use Core's `Matter.Medium.index(λ)` (BK7 Sellmeier, fused silica, diamond, water Cauchy/Debye, air): the same values as the Matter bench; the imaginary index (absorption) is ignored; `valid` marks Core's fitted range. In display units x is in λ_ref, t in T_ref, k in rad per λ_ref, ν in ν_ref and speeds in c, so one picture serves any band (the 2.4 GHz and 550 nm scenes are identical — oracle).

```swift
Phase.GaussianPacket(carrierFrequency: ν₀, width: σ /*rms of |ψ|²*/, chirp: β, center: x₀, direction: ±1, amplitude: A, phase: φ)
Phase.GaussianPacket.fromSource(lambda:cycles:model:chirp:center:direction:amplitude:)   // Spectra source → packet (cycles at FWHM, Core's convention)
p.carrierWavenumber(model), p.spectralWidth, p.spectrum(k:k0:), p.initialField(x:k0:)
p.closedFormSpatialWigner(x:k:t:taylor:)     // 2A² exp(−u²/2σ² − 2σ²(k − k₀ − 2βu)²), u = x − (v_g + D(k − k₀))t − x₀ (exact for linear/quadratic ω)
p.closedFormTemporalWigner(t:nu:x:taylor:)   // linear dispersion: W₀(x − v_g t, (2πν − Ω)/v_g)/|v_g|
Phase.packetField([packets], model:, x: Axis, t: Axis, gate: TimeGate?) -> PacketField(field, droppedFraction, carriers, periodLimited)
// invalid packets (non-finite or non-positive width…) are left out; a packet whose envelope stays > 12σ outside the
// x window for the whole t axis contributes nothing; periodLimited = the internal grid hit its 2²¹ cap (field approximate)
Phase.TimeGate.gaussian(center:sigma:) | .hann(start:end:) | .hann(over: tAxis)        // observation window (amplitude)
```

**The one-call scene** (Spectrum → Decompose → Phase space):

```swift
Phase.PhaseSpaceRequest(packets: [GaussianPacket] /*≤ 3, display units; center = position at mid-window*/,
                        dispersion:, referenceFrequency: /*Hz, source A*/, gridSize: 48, lagBins: nil,
                        observationWindow: true /*Hann in t*/, kSlice: nil /*k̂*/, keepFull: false, kBand: nil)
let scene = Phase.phaseSpaceScene(request)     // ≈ 58 ms CPU at 48 (M1 Max); run detached
scene.units, scene.model, scene.field
scene.intensity           // Grid2D |ψ(x,t)|²   (rows x, columns t) — left panel
scene.spectrum.power      // Grid2D |ψ̃(k,ν)|²  (rows k, columns ν) — right panel
scene.shell               // [ShellPoint] over the k axis — overlay
scene.wigner              // SpacetimeWigner — centre cube, slices, marginals
scene.report              // MarginalReport — the Marginals strip (errors + badge)
scene.carriers            // [(k̂₀, ν̂₀)?] per source (nil = below cut-off)
scene.notes               // plain sentences: cut-off, invalid packet or reference frequency, model validity,
                          // dropped energy, packets outside the window, period-limited field, ALIASED advice
```

The scene picks Δx so the packets fill 1/1.1 of the k band (positive when every packet moves toward +x, else centred), a time window during which the packets (±3σ) stay inside the x window, Δt so the positive ν band holds the content plus the Hann gate's main lobe, and places each packet's envelope at its `center` at mid-window.

## Usage

**spectrum-ui** (Decompose → Phase space, `Render/Scenes/Wigner*.swift`):

```swift
let s = state                                            // SpectraState (Core)
let units = Phase.DisplayUnits(referenceWavelength: s.sources[0].lambda)
let disp: Phase.Dispersion = ionosphere ? .plasma(plasmaFrequency: fpKnob) : (waveguide ? .waveguide(cutoffFrequency: fcKnob) : .medium(s.medium))
let model = Phase.ShellModel(disp, units: units)
let packets = s.enabledIndices.compactMap { i in
  Phase.GaussianPacket.fromSource(lambda: s.sources[i].lambda, cycles: s.sources[i].cycles, model: model,
                                  chirp: chirpKnob[i], center: offsets[i])
}
let req = Phase.PhaseSpaceRequest(packets: packets, dispersion: disp, referenceFrequency: SI.c / s.sources[0].lambda,
                                  kSlice: kSliceKnob, keepFull: true)
let scene = await Task.detached { Phase.phaseSpaceScene(req) }.value
// Volume: scene.wigner.kIntegrated.signedUnit() (x, t, ν) or scene.wigner.kSliceCube(column: c)!.signedUnit()
// Slices: scene.wigner.spatialWigner(atT: it), scene.wigner.temporalWigner(atX: ix) (signedUnit → diverging map)
// Strip: "M1 \(r.m1Error)  M2 \(r.m2Error) (alias \(r.aliasLevel))  P \(r.parsevalError)  \(r.status.badge)"
```
Two sources show the negative cross term midway; one Gaussian stays ≥ 0 (Hudson). A `.plane` source has no envelope: map it to `cycles = 12` (Core's maximum) and say "plane wave shown as a long packet". Thermal sources are not coherent packets: leave them out with a note.

**scope** (Spectrogram · Wigner–Ville · Pseudo-Wigner):

```swift
let snap = stream.ring.snapshot(last: 4096)                       // uniform-rate streams; resample irregular ones first
let fs = stream.measuredRate ?? stream.nominalRate                // 0 (BLE RSSI) → empty image: resample first
let tf = Phase.timeFrequency(real: snap.values, sampleRate: fs, origin: snap.times.first ?? 0,
                             request: .init(mode: .wignerVille, rows: 256, columns: 256))
// texture: tf.plane.signedUnit() (rows = time, columns = 0 … fs/2); edges: tf.timeMarginal / tf.intensity,
// tf.frequencyMarginal / tf.spectrum. 4096 samples → 256 × 256 Wigner–Ville ≈ 6 ms CPU.
```

**radio-ui** (Fourier time–frequency view, FMCW chirp, Aperture phase space):

```swift
let frame = link.next()
let z = Phase.Signal.fromIQ(i: frame.tx.i, q: frame.tx.q, sampleRate: link.sampleRate)
let tf = Phase.timeFrequency(complex: z, request: .init(mode: .wignerVille))     // −fs/2 … fs/2 (2× oversampled)
let sg = Phase.timeFrequency(complex: z, request: .init(mode: .spectrogram))     // side by side
// FMCW preset: a linear chirp's Wigner is the straight line ν(t) = f₀ + αt (≥ 90 % within ±2 bins, oracle).
let ap = Phase.Aperture.uniformArray(elements: p.arrayNx, spacing: p.arraySpacing, steerFromBroadsideDeg: p.steerTheta)
let w = ap.wigner()                                              // W(x, kₓ) image
let pattern = ap.farField(from: w)                               // k marginal = far field (compare model.cut(.e))
let near = Phase.fresnelShear(w, distance: zKnob, wavenumber: ap.wavenumber)   // near field → far field
// Dish / horn: Phase.Aperture.continuous(width: p.dishDiameter, illumination: .gaussian(edgeTaperDB: 10))
```

**spin-ui** (FID in a field gradient is a chirp):

```swift
let iq = FIDSignal.baseband(params, referenceHz: fRef, sampleRate: 2000, count: 1024)    // I + jQ
let tf = Phase.timeFrequency(complex: Phase.Signal.fromIQ(iq, sampleRate: 2000),
                             request: .init(mode: .smoothedPseudoWigner, rows: 128, columns: 256))
// Audio-rate FID (real): var src = SpinFIDSource(field: b); src.pulse(); Phase.timeFrequency(real: src.renderAudio(4096), sampleRate: 48_000)
```

**patch** (Wigner and Marginal nodes):

```swift
// Wigner node: stream block → image (evaluate at control rate, off the audio thread)
let image = Phase.timeFrequency(real: block, sampleRate: fs, request: .init(mode: node.mode, rows: 128, columns: 128))
// Marginal node: image → |x(t)|² or |X(ν)|²
let edge = node.axis == .time ? image.plane.rowMarginal() : image.plane.columnMarginal()
```

## Tests

`SpectraTests/PhaseTests.swift`: 14 oracle groups (126 checks, 15 XCTest methods) — conventions and plane-wave signs, analytic signal and oversampling, temporal and spatial marginals, Hudson positivity and cross terms, linear-chirp concentration, Moyal, pseudo/smoothed/spectrogram, aperture far field vs `RF.Arrays` and Fresnel shear vs direct propagation, spacetime Φ, packets/closed forms/dispersion shells, timing budgets (CPU time), robustness, and **independent references** (direct sums written from convention (C) in the test file — 1-D Wigner incl. M < N where rule 1 binds, pseudo/smoothed, spectrogram, Φ at grid points incl. M < N and a centred ν band, Φ marginals by direct DTFT, a corrupted-report check, Fresnel shear vs the closed-form Gaussian-beam Wigner, beam centroid, steering, far field between columns vs `RF.Arrays`). The verifier's 47 deliberate bugs (sign of ν/k, lag rule, factors 2/4, analytic signal, dispersion, shear sign, …) are all caught (`Docs/notes/phase-engine-verify.md`). `Tools/check-phase.sh` runs the same file on macOS (harness, `-O`) and as a real XCTest bundle, after import, isolation, iOS 27 SDK and file-name checks.
