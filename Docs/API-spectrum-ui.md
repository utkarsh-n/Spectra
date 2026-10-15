# API: spectrum-ui (Spectrum tab)

Owner: **spectrum-ui**. Paths: `Spectra/UI/Spectrum/`, `Spectra/Render/Scenes/WaveScene.swift`, `Spectra/Render/Scenes/WignerScene.swift`. Everything here is `@MainActor` unless marked `nonisolated`. Physics comes from Core (`SpectraState`, `FieldView`, `SpectrumDisplay`, specimens, samples) and Phase (`Phase.phaseSpaceScene`); this slice only routes edits, draws and remembers.

## What other slices call

`app.spectrum` is the `SpectrumModel` (`@Observable @MainActor final class`, `TabModel`). The stub's API is kept.

| Member | Use |
|---|---|
| `init()` | No arguments. It loads `Spectra.spectrum.v1` (skipped with `-ui-testing`) and always runs with the long ruler (`state.extendedRange = true`, λ up to 100,000 km). |
| `markers` | `spectrum.A`, `spectrum.B` and `spectrum.C` for the sources that are on. Each is MODEL, tab `.spectrum`, with label "Source A" (thermal: "Source A · 5772 K glow"). |
| `tune(lambda:)` | Tunes source A (makes it active, turns it on, turns a thermal A into a plane wave), plays the ruler detents it crosses, and scrolls the tuner window to the new λ. Non-finite or non-positive values are ignored. `AppModel.sendToSpectrum` and Patch's knob drive call this. |
| `sourceALambda` | Source A's λ in metres. Setting it calls `tune(lambda:)`. Stage-1 API (`AppTests`, Patch). |
| `static lambdaKnob` | The λ `KnobSpec`: log from 0.1 pm to 100,000 km, with detents at the band edges, Green (550 nm), 1 km and the long-wave landmarks. Stage-1 API. |
| `openEarthFieldLab()` | Spin's "Open in Lab": closes the full-screen view, selects the Spectroscopy lab and its NMR "Earth field (live \|B\|)" mode. **Integrator:** add `extension SpectrumModel: SpinEarthFieldLab {}` (one line; the protocol lives in `UI/Spin/SpinModel.swift`, which the stage-2 baseline does not have). |
| `state: SpectraState` | The ported web state (Core): sources, medium, κ and per-instrument settings. Read it freely. Prefer the methods below for writes, because they handle detents, Link and presets. |
| `extras: SpectrumExtras` | Native settings: cameras, tuner window, Phase space page and `PhaseSpaceSettings`, Earth-field mode and cursor. |
| `active` | The active `WaveSource`. |
| `edit(_ SourceEdit, quiet:)`, `setLambda(_:)`, `jump(to: BandKey)`, `apply(preset:)`, `select(_ Instrument)`, `selectSource(_:)`, `setActiveEnabled(_:)`, `setKind(_:)`, `resetDials()`, `resetAlignment()`, `align()` | The same edits the UI makes (detent haptics, Link, follow-the-cursor tuner window). |
| `selectSample(_:)`, `selectMode(_:)`, `selectEarthMode()`, `setLabSweep(_:)`, `toggleSweep()`, `tuneToEarthLine()` | Spectroscopy lab. The cursor retunes the **active** source (web `lab.tune`, SPEC-features §1). |
| `openFieldInScope()`, `addFieldToPatch()`, `openLabInScope()`, `addLabToPatch()` | The Scope and Patch hooks. These register the streams below on first use. |
| `transport() -> TransportConfig` | κ-slowed time mapping for the reference source, with the Scope and Patch actions in the ⋯ menu. |

Launch path: `-open spectrum/<instrument>[/<page>][/fullscreen]`.

- Instruments: `scope` (or `wave`), `tuner`, `bench` (or `matter`), `decompose`, `lab` (or `spectroscopy`).
- Pages: `decompose/polarization`, `decompose/probe`, `decompose/fourier`, `decompose/phase`, `lab/<sample>` (hydrogen, co2, water, chlorophyll, nmr) and `lab/earth`.
- Shortcuts: `phase`, `probe`, `fourier`, `polarization` and `earth` also work alone.

DEBUG-only launch arguments (this slice):

- `-spectrumChecks` runs `SpectrumLogicChecks` (below) at launch; results go to the console and `Documents/spectrum-ui-checks.txt`.
- `-spectrumSnapshots[=name,…]` walks every instrument, page, the full-screen view and both sheets, and writes PNGs of the real key window (Metal included) to `Documents/spectrum-ui-<name>.png`. `=page` renders the content column offscreen instead (Metal scenes as CPU sketches). It exists because `simctl io screenshot` hangs when many simulators share the machine.

## Streams published (scope bus)

Each stream is registered the first time someone presses "Open in Scope" or "Add to Patch", and keeps running after that. Samples are written only while the app is active and the Spectrum, Live or Patch tab is showing. Each sample carries its `SignalClock` timestamp.

| Id | Label / unit | Rate | Provenance | What it is |
|---|---|---|---|---|
| `spectrum.ex` | "Spectrum Ex at z = 0 (κ-slowed)", `E (norm.)` | 240 Hz | MODEL, EM, λ of the reference source | `FieldView.fieldAt(z: 0)` summed over the sources that are on, in display units. Its screen time follows the app clock, so it holds while the clock is paused. |
| `spectrum.ey` | same, Ey | 240 Hz | MODEL, EM | The Ey counterpart of `spectrum.ex`. |
| `spectrum.lab` | "Spectroscopy lab detector", `rel.` | 30 Hz | MODEL (TABLE for liquid water) | Sample value at the lab cursor, normalized to the sample's maximum. A sweep draws the spectrum over time. |

In the Earth-field lab mode, "Open in Scope" opens the live owner's `mag.norm` stream with preset "Magnetic scope". "Add to Patch" adds `mag.norm`. "Hear it in Spin" calls `app.focus` with a `live.nmr` marker (tab `.spin`), which Spin answers with its proton view on the live field.

The group name is `"Spectrum"`. The live owner's `StreamGroup` has no Spectrum case, so the scope lists this group after the known groups.

## Scenes

- **`WaveScene: SceneBuilder`** (`Render/Scenes/WaveScene.swift`) is the Wave scope, a port of spectra-lab `scope.js` on `FieldView`. It reads `state` (set by the model) and its camera, and draws:
  - E and B traces with ribbons (planar fields) and stems
  - faint per-source traces when several sources are on
  - the beam axis in the wave's display colour
  - the Poynting arrow S
  - the medium block (Fresnel amplitude and absorption come from `FieldView`)

  `OrbitCamera.waveScopeHome` is the home framing. `displaySources` is the cached `FieldView.DisplaySources`; Decompose reuses it.
- **`WignerScene: SceneBuilder`** (`Render/Scenes/WignerScene.swift`) is the Φ cube.
  - `points: [SIMD4<Float>]` holds (x, t, ν, w), with every component in −1…1.
  - `tSlice` and `xSlice` are the slice planes, also in −1…1.
  - The colour map is `WignerScene.positive` (warm orange) and `.negative` (cool blue). Points add along the line of sight, so each is dimmed by √(count / 1,500) to keep the two hues apart.
  - `OrbitCamera.wignerCubeHome` is the home framing.

## Pure logic (`SpectrumLogic.swift`, `nonisolated`, Foundation + simd, Core and Phase only)

- `SpectrumExtras`, `PhaseSpaceSettings`, `SpectrumSaved`: the persisted settings, with lenient decoding (a bad field keeps its default; ranges are clamped).
- `TunerWindow`: `clamp(low:high:)` (≥ 2 decades inside −13…8), `zoomed(_:factor:anchor:)` (the anchor stays put), `following(_:lg:margin:)`; `web` (−13…3) and `full` (−13…8).
- `EarthFieldAxis`: the Earth-field lab axis, 500 Hz–4 kHz; `frequency(at:)`, `fraction(of:)`, `lambda(at:)`, `fieldRange` (25–65 µT), `displayHalfWidth`.
- `PhaseSpaceRequestBuilder.build(state:settings:) -> Built` maps the sources to `Phase.PhaseSpaceRequest`, with notes and the source index of each packet.
  - A plane wave becomes a `planeWaveCycles` = 10-cycle packet. Core allows 12, but a 12-cycle packet overflows the 48-point window (ALIASED in every medium); 10 is the longest that reads CONSISTENT.
  - Thermal light is left out (it is incoherent); a source below a waveguide cut-off is left out. Each gets a note.
  - Packets are spaced `settings.spacing` λ apart.
  - `gridSize` is 48, or 40 in Debug builds (40 is the smallest grid on which two default pulses read CONSISTENT; 32 reads ALIASED).
- `WignerCubePoints.extract(cube, budget:, peak:)` returns the strongest cells of a `Phase.Cube` as cube points (histogram threshold of at least 4 %). A k column is extracted on the scale of the whole Φ (`peak`), so a column far from the packets stays dark.
- `SpectrumLogicChecks.run()` (DEBUG): 38 checks of the above, including Φ scenes computed by Phase. Run them on macOS without a simulator (see `Docs/notes/spectrum-ui.md`) or in the app with `-spectrumChecks`.

`SpectrumPhaseModel` (`model.phase`) computes the scene in `Task.detached` after a 140 ms debounce. It publishes `scene`, `built`, `computing`, `computeSeconds`, `cubeColumn` and `cubeRevision`, and offers `image(_:settings:)` (heat maps, cached per scene and slice), `sliceIndices(_:)` and `startKFraction(spacing:)` (the first carrier k̂₀ for one packet; k̂₀ + π/d for two or more, where the in-phase cross term is most negative).

## Persistence

`Spectra.spectrum.v1` holds `SpectrumSaved { state: SpectraState, extras: SpectrumExtras }`. `extras` holds:

- the scope camera
- the tuner window
- the Phase space page flag
- the Earth-field lab mode and its cursor
- `PhaseSpaceSettings`: dispersion choice, plasma and cut-off ratios, chirps, spacing, k column, slice fractions and cube camera

## Accessibility identifiers (smoke tests)

| Area | Identifiers |
|---|---|
| Top level | `spectrum-band-<gamma\|xray\|uv\|visible\|ir\|microwave\|radio>`, `spectrum-instrument-<scope\|tuner\|bench\|decompose\|lab>`, `spectrum-align`, `spectrum-fullscreen`, `fullscreen-close`, `spectrum-fullscreen-scroll`, `spectrum-status`, `spectrum-readouts` |
| Wave scope | `spectrum-wave-stage`, `spectrum-scope-e/b/s`, `wave-camera-zoom-in/out/align`, `spectrum-scope-open-scope`, `spectrum-scope-add-patch` |
| Tuner | `spectrum-tuner` (adjustable), `spectrum-tuner-zoom-in/out`, `spectrum-tuner-full`, `spectrum-tuner-web`, `spectrum-tuner-overview` |
| Bench | `spectrum-bench-arrangement-side/series`, `spectrum-bench-stage`, `spectrum-specimen-<key>`, `spectrum-bench-lambda0` |
| Decompose | `spectrum-decompose-<polarization\|probe\|fourier\|phase>`, `spectrum-decompose-stage`, `spectrum-polarizer`, `spectrum-probe-mode-<both\|electric\|magnetic>`, `spectrum-a0`, `spectrum-decompose-open-scope/add-patch` |
| Phase space | `spectrum-phase-spacetime`, `spectrum-phase-momentum`, `spectrum-phase-cube`, `wigner-camera-*`, `spectrum-phase-slice-t/x`, `spectrum-phase-t`, `spectrum-phase-x`, `spectrum-phase-marginals`, `spectrum-phase-dispersion-<medium\|plasma\|waveguide>`, `spectrum-phase-plasma`, `spectrum-phase-cutoff`, `spectrum-phase-spacing`, `spectrum-phase-chirp-<A\|B\|C>`, `spectrum-phase-two-packets`, `spectrum-phase-kslice`, `spectrum-phase-k`, `spectrum-phase-notes` |
| Lab | `spectrum-lab-sample-<key>`, `spectrum-lab-technique-mode-<mode>`, `spectrum-lab-technique-earth`, `spectrum-lab-sweep`, `spectrum-lab-stage`, `spectrum-lab-earth-stage`, `spectrum-lab-earth-tune`, `spectrum-lab-earth-spin`, `spectrum-lab-open-scope/add-patch` |
| Field controls sheet | `spectrum-trips`, `spectrum-trip-<key>`, `spectrum-source-<A\|B\|C>`, `spectrum-link`, `spectrum-source-enabled`, `spectrum-kind-<plane\|pulse\|thermal>`, `knob-spectrum-<lambda\|temperature\|e0\|theta\|delta\|phi\|cycles>` (+ `-slider`), `spectrum-medium-<medium>`, `spectrum-speed`, `spectrum-show-e/b/s`, `spectrum-sound`, `spectrum-haptics` |

Lab technique ids use the mode's raw value: `mode-emission`, `mode-ir`, `mode-a`, `mode-400`, `mode-60` and so on.
