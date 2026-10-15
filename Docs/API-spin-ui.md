# API: Spin tab (`Spectra/UI/Spin/`, `Spectra/Render/Scenes/SpinScene.swift`)

Owner: **spin-ui**. Engines used: `Spin/` (`GyroscopeEngine`, `SpinEnsemble`, `SpinFIDSource`, `SpinFieldReadout`, `SpinDriveReadout`, `EarthField`, `FIDSpectrum`, `LarmorSonification`, `AirHere`) and `Phase/` (`Phase.timeFrequency`). The UI derives no physics of its own: every number comes from those types.

## What other slices can call

`app.spin` is the `SpinModel` (`@Observable @MainActor`, `TabModel`). The stage-1 contract is kept: `SpinModel.init()`, `markers`, `attach(to:)`, `fieldTesla` (the B₀ dial, tesla, settable) and `larmorFrequency` (water protons in the field in use, Hz).

| Member | What it does |
|---|---|
| `fieldInUse: Double` | B₀ in use (tesla): the smoothed live \|B\| (τ 0.25 s) while the source is Live and the magnetometer runs, otherwise the dial. |
| `readings: SpinReadings` | The 10 Hz snapshot: field and its provenance, magnetometer calibration, dip and magnetic latitude, `SpinFieldReadout` chips, per-species bench readings, rotor telemetry, Hear-it voice. |
| `saved: SpinSaved` | Everything persisted under `Spectra.spin.v1` (view, rotor params, benches, toggles). Edits apply at once; decoding is tolerant and clamps each bench value into its knob's range. |
| `select(_ view: SpinView)` | `.gyroscope`, `.proton`, `.electron`, `.compare`. |
| `handleFocus(_ marker: SpectrumMarker?)` | Acts once on a marker focused on the Spin tab. `live.nmr` (Live's "Hear Earth-field NMR") selects the proton view on the live field, starts Hear it when Sound is on and scrolls to it; `spin.larmor` / `spin.electron` / `spin.nod` open the view that owns the marker. SpinTab calls it on appear and when `app.focusedMarker` changes, so other slices only need `app.focus(marker)` with `tab: .spin`. |
| `scroll(to anchor: String)` | Scrolls the content to `spin-anchor-<anchor>` (see Launch paths). |
| `showOnSpectrum()` | `app.sendToSpectrum` with the Larmor line's wavelength (electron in the electron view, else water protons). |
| `openInLab()` | Spectroscopy lab in Earth-field NMR mode, through the `SpinEarthFieldLab` hook below; otherwise `app.focus` + a toast. |
| `openInScope()` | Turns on *Publish while hidden*, then `app.openScope([spin.fid, spin.fid.q])` (preset "Spin FID"), or the tip pair in the gyroscope view. |
| `addToPatch()` | Turns on *Publish while hidden*, then `app.patch.addStreamSource(...)`; toasts if the Patch tab did not take focus. |
| `runSequence(_:)`, `pulse(_:flip:)`, `resetMagnetization(_:)` | Bench actions for `.protonWater` or `.electron`. |
| `toggleHearing()` | Hear it (proton only, Sound on). |
| `apply(preset: HeavyTopPreset)`, `relaunchRotor()`, `kickRotor()` | Rotor actions. |
| `static func timeUnit(_ species) -> Double` | u = γ′ₚ/\|γ\|: 1 for water protons, 1/658.2 for the electron (the electron bench runs the proton's picture at its own pace). `nonisolated`. |

### Hooks for integration

```swift
// "Open in Lab": spectrum-ui or integration, e.g. in UI/Spectrum.
@MainActor protocol SpinEarthFieldLab: AnyObject { func openEarthFieldLab() }
extension SpectrumModel: SpinEarthFieldLab {
  func openEarthFieldLab() { select(.lab); selectEarthMode() }   // the live SpectrumModel already has both
}

// Magnetometer calibration next to f_L: live or integration.
@MainActor protocol SpinCalibrationReporting: AnyObject { var accuracy: Int { get } }   // −1…2, Core Motion's
extension MagnetometerChannel: SpinCalibrationReporting {}
```

Both are checked at run time (`as?`), so nothing breaks before the conformances exist. Without the calibration conformance Spin reads `accuracy` by reflection; with neither, the calibration readout is hidden.

## Streams published (group "Spin", provenance MODEL)

Registered while the Spin tab is on screen or *Publish while hidden* is on (Dials → Display, or the Loop panel); unregistered otherwise. Timestamps are wall-clock (`SignalClock`), monotonic.

| id | Unit | Nominal rate | What |
|---|---|---|---|
| `spin.fid` | M₀ | 400 × bench pace (Hz) | I = mean Mₓ of the selected spin bench in the rotating frame (proton unless the electron view is shown). `isEM`, `lambda` = the Larmor line's wavelength at registration. Label says which species and whether B₀ is live ("live \|B\|", i.e. MODEL driven by LIVE). |
| `spin.fid.q` | M₀ | same | Q = mean M_y. I + jQ is engineering baseband: protons (clockwise) put a line above the carrier at negative frequency. |
| `gyro.tip.i` | eₓ | 960 × Time knob (Hz) | Axle tip eₓ (world axes), the `GyroscopeEngine` tip stream (960 samples per simulated second), driven by live device motion. |
| `gyro.tip.q` | e_y | same | Axle tip e_y. |

The electron's `spin.fid` is slowed ×658 (its label says so). A change of species, pace or Time re-registers the streams with the new rate (look streams up by id). The rotor and the proton bench keep stepping while publishing hidden, whatever the view.

## Markers

- `spin.larmor`: water-proton line in the field in use (always), MODEL, label notes "(live |B|)" when driven by the magnetometer.
- `spin.electron`: electron spin line (electron and Compare views).
- `spin.nod`: rotor inertial nod (gyroscope and Compare views), ANALOGY (`isEM: false`).

## Launch paths

`-open spin/gyroscope|proton|electron|compare` (aliases `gyro`, `rotor`, `top`, `nmr`, `h`, `esr`, `e`, `all`), optionally `/<panel>` to scroll there: `top`, `dials` (gyroscope), `readouts`, `drive`, `hear`, `fid`, `wigner`, `tip`, `field`, `loop` (e.g. `-open spin/proton/wigner`).

DEBUG only: `-spinSnapshots[=<name>,…]` walks the tab (views, panels, Dials and Field notes sheets, the `live.nmr` hand-off) and writes `spin-ui-<name>.png` of the key window plus `spin-ui-snapshots.txt` to the app's Documents folder; `=dtxl` / `=rm` run the short sets for an accessibility text size (`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL`) or Reduce Motion. It exists because `simctl io screenshot` hangs on a loaded host.

## Accessibility identifiers

`spin-view-<gyroscope|proton|electron|compare>`, `spin-scene`, `spin-camera-zoom-in|zoom-out|align`, `spin-kick`, `spin-relaunch`, `spin-trail`, `spin-vectors`, `spin-rotating-frame`, `spin-align-field`, `spin-pulse-90`, `spin-pulse-180`, `spin-run-sequence`, `spin-reset-m`, `spin-sequence-<fid|echo|inversion>`, `spin-cw`, `spin-repeat`, `spin-hear` (disabled on the electron page and with Sound off), `spin-zoom-<narrow|medium|full>`, `spin-wigner-mode-<mode>`, `spin-field-source-<live|dial>`, `spin-field-open-settings`, `spin-preset-<id>`, `spin-show-spectrum`, `spin-open-lab`, `spin-open-scope`, `spin-add-patch`, `spin-publish-hidden`, knobs `knob-spin-<motor|inertia|gravity|balance|friction|air|magnet|time|b0>` and `knob-spin-<p|e>-<b1|offset|phase|ramp|t1|t2|gradient|isochromats|tau|tr|slow>`; in the Dials sheet `spin-dials-<cw|repeat|rotating|trail|vectors|publish>`, `spin-dials-sequence-<…>`, `spin-lock-carrier`. Transport ⋯: `spin-transport-relaunch`, `spin-transport-kick`, `spin-transport-run`, `spin-transport-reset-m`.

## Threading and cost

All on the main actor. The engines step from the Metal render loop (`SpinScene.build`) while the canvas draws, and from a 60 Hz main-actor loop otherwise (canvas paused or the tab hidden while publishing); both step to `AppClock.time`, so they never double-count. Only what is on screen steps (rotor in gyroscope/Compare, each bench in its view and Compare), plus whatever feeds a published stream. Per frame: one heavy-top step (RK4 substeps), 64 isochromats × ~7 substeps per bench, a few hundred bytes of ring appends. The FID spectrum (≤ 512-point DFT) runs on the main actor when a record completes; the Wigner image (`Phase.timeFrequency`, 128 × 128) runs in `Task.detached`. The rolling plots redraw from the model's own ~30 Hz tick, only while scrolled into view.
