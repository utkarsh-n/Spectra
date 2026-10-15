# API: Scope (`Spectra/UI/Scope/`, `Render/Scenes/ScopeScene.swift`, `Render/Scope.metal`)

Owner: **scope**. The universal oscilloscope of SPEC-features §3b, plus the Scope bullet of §3c (Spectrogram · Wigner–Ville · Pseudo-Wigner with edge marginals). Consumers: **live** (the Live tab's Scope page), **patch** (the Scope sink), anyone with an "Open in Scope" button.

## Views

```swift
ScopeView()                                    // the Live tab's Scope page
ScopeView(fixedStreams: ["mag.x", "mag.norm"]) // embedded (Patch Scope sink, previews)
```

- Both are **scroll content**: a `VStack` of `InstrumentPanel`s (01 Scope, 02 Probes, 03 Measurements, 04 Trigger · cursors · display). Put them inside an `InstrumentScreen` scroll view; they bring no `NavigationStack` and no top bar of their own. The embedded form shows only the display panel and a compact measurements panel.
- `ScopeView()` follows `app.scopeRequest`: on appear and whenever `scopeRequest?.id` changes, the request's streams go to CH1…CH4 in order (other channels switch off unless a preset is named), and `preset` is applied first when it names a probe. The Live tab should switch its page picker to **Scope** when `scopeRequest` changes (the hook in `Docs/API.md`), then this view does the rest.
- `ScopeView()` shares one model (`ScopeModel.main`) for the app's lifetime, so its state survives page and tab switches; settings persist under **`Spectra.scope.v1`** (not loaded with `-ui-testing`).
- `ScopeView(fixedStreams:)` keeps its own model, ignores `scopeRequest`, persists nothing. Up to four ids; extra ids are ignored. The model lives in a child keyed by `.id(fixedStreams)` and is made on first appear, so rewiring a Patch sink (or the inspector moving to another Scope node) gives a fresh scope on the new streams, and parent re-renders never allocate throwaway models. Its channel sheet states the cabled stream instead of offering a source picker (rewire in Patch).
- Sensors: while visible, the view acquires the sensors its channels need through `app.live.acquire(_, by:)` with owner **`"scope"`** (embedded: `"scope.embedded.<ids joined by +>"`) and releases them all on disappear. Sensors that show a permission prompt (`SensorID.needsPermission`) are started only after a tap: a probe chip, "Open in Scope", or the display's "Start <sensor>" button (`scope-start-<sensor>`). Faked sensors (`-fakeAll`) and sensors already running for someone else start at once. A needed sensor that is held but not delivering (denied, unavailable, locked, turned off in Settings → Sensors, or still asking) gets a line along the bottom of the display, with **Open Settings** on denial.

## Opening the scope from elsewhere

```swift
app.openScope(["mag.x", "mag.y", "mag.z", "mag.norm"])            // streams → CH1…CH4
app.openScope([], preset: "Magnetic scope")                         // a probe by name
app.openScope(["ble.<uuid>.rssi"], preset: nil)
```

Preset names are matched loosely (`ScopePreset(name:)`): the raw value or the title with any punctuation and suffix, e.g. `"magnetic"`, `"Magnetic scope"`, `"vibration"`, `"seismograph"`, `"bluetoothEMF"` / `"Bluetooth / EMF"`, `"network"`, `"sound"`, `"compassXY"` / `"Compass XY"`, `"air"`, `"lightFlicker"` / `"Light flicker"`, `"spinFID"` / `"Spin FID"`, `"radioIQ"` / `"Radio I/Q"`.

Presets find their streams **by meaning** (`ScopeEngine.StreamQuery`: group, axis, keywords, preferences, rank such as "strongest 3 BLE radios"), so they work with the foundation's SIM ids now and the live builder's ids later (`accel.user.x` is preferred over `accel.x` for Vibration and Seismograph; calibrated `mag.x` over `mag.raw.x`).

## Streams the scope publishes (MODEL)

Only while a probe or channel needs them, and **only when no other slice has registered the same id** (an existing stream is never replaced; if Spin or Radio publish these ids, the scope shows theirs).

| id | label | unit | rate | group | what |
|---|---|---|---|---|---|
| `spin.fid` | Proton FID (true pitch) | V (norm.) | 8 kHz | Spin | Water-proton FID at the true Larmor pitch in the live |B| (`mag.norm`, ≈ 2.13 kHz at 50 µT), T₂* 0.6 s, re-pulsed every 3 s, from `SpinFIDSource.renderAudio`. REAL TIME. |
| `radio.i`, `radio.q` | Radio I/Q (EDGE 8-PSK) | V (norm.) | 200 per displayed second | Radio | `RF.BasebandLink` EDGE 8-PSK through a 30 dB channel, played out κ-slowed by f_s/200 ≈ 1.08 × 10⁴ (25 symbols/s). |

`ScopeProbeStreams` owns them (`ensure(_:registry:)`, `pump(now:fieldTesla:)`, `stopAll(registry:)`, `owns(_:)`, `radioTimeMapping`).

## Model (`ScopeModel`, `@Observable @MainActor`)

```swift
ScopeModel.main                                          // the Live page's model
ScopeModel(owner:persistent:fixedStreams:)
model.appear(app:) / disappear()                         // the view calls these
model.applyPendingRequest()                              // follow app.scopeRequest
model.applyPreset(.magnetic, tapped: true)
model.setMode(.fft); model.setTimebase(0.01)             // timebase snaps to what the streams allow
model.toggleRun(); model.armSingle(); model.autoset()
model.mutate { $0.channels[0].coupling = .ac }           // any ScopeSettings edit (persists, re-acquires)
model.startSensor(.microphone)                           // a user tap
model.readout                                            // status, measurements[0…4], rates, aliasNotes (≈ 5 Hz)
model.spectrum, model.timeFrequency                      // FFT and time–frequency results
model.export                                             // ScopeExport: Transferable CSV of the visible window
model.addToPatch(i)                                      // app.patch.addStreamSource for channel i
model.cursorReadout                                      // Δt, 1/Δt (time cursors), ΔY (amplitude cursors); nil when off or outside YT/Roll
```

A probe tap, "Open in Scope" or a new `scopeRequest` also resumes a stopped scope (clears the frozen window). FFT and the time–frequency modes lengthen a too-short timebase on entry and give the previous one back on the way out to YT/Roll/XY (unless the user turned it meanwhile). Saved settings go through `ScopeSettings.sanitize()` after decoding (indices, positions, cursors, holdoff, corner and scales clamped), so an older or damaged `Spectra.scope.v1` cannot trap. A probe channel whose stream disappears (a Bluetooth radio rotating its address) is found again by meaning after its sensor has run 2 s without it, among streams no other channel shows; two channels never resolve to the same stream unless the query is ranked.

Channel index 0…3 = CH1…CH4, 4 = math. Per-frame work happens in `buildScopeFrame` / `tick()` on `@ObservationIgnored` state; observed values change at about 5 Hz.

## Pure engine (`ScopeEngine`, `nonisolated`, usable anywhere)

`triggerTimes(values:times:level:slope:hysteresis:holdoff:notBefore:)`, `decimate`, `trace(…hold:holdUntil:)`, `rollTrace`, `pairXY(x:y:window:tolerance:holdY:)`, `measure(values:times:sampleRate:)` (and `measure(…analyzers:)` with a reusable `PeakAnalyzers` cache of FFT setups) → `Measurements` (count, min, max, mean, rms, acRMS, peakToPeak, frequencyZeroCrossing, frequencyFFT, period), `zeroCrossingFrequency`, `fftPeakFrequency` (RF.SpectrumAnalyzer), `SpectrumCache.spectrum`, `resample`, `boxcarDecimate`, `OnePoleHighPass` (irregular-safe), `acCorner`, `MathProcessor` (A+B, A−B, A·B, |vector|, d/dt, ∫dt, high-pass), `aliasNotes`, `mainsFrequency(region:)`, `sequence125`, `timebases`, `minimumTimebase`, `timebaseRange`, `clampTimebase`, `scales(unit:)`, `autoScale`, `StreamQuery` + `resolve`, `sensor(for:group:)`, `csv`. All timestamps are the sensors' own (`SignalClock`); nothing assumes a uniform rate unless it resamples explicitly.

## Rendering

`ScopeCanvas(source: any ScopeFrameSource, redrawKey:label:value:)` is the Scope's own `MTKView` (it takes part in `CanvasArbiter`, renders only while on screen and active, continuously while running, on demand when stopped). `ScopeRenderer`: persistence buffer (rgba16Float, multiplied by exp(−Δt/τ) through the blend unit, beam added with the foundation's `phosphorVertex/Fragment`), scene (graticule + persistence + overlay), the foundation's bloom (`prefilterFragment`, `blurFragment`, `copyFragment`), EDR composite. `Scope.metal` functions: `scopeFullscreenVertex`, `scopeFadeFragment`, `scopeGraticuleFragment`, `scopeAccumulationFragment`, `scopeCompositeFragment`. `ScopeFrame` carries `accumulate` and `overlay` (`SceneBuffer` 2D phosphor helpers), `decay`, `clearAccumulation`, `graticule`.

## Field notes

`ScopeNotes.notes` (a `FieldNotes`) — the view's ⓘ (`scope-notes`) opens it; the Live tab may reuse its sections. It credits Utkarsh's spacetime Wigner construction and convention (C).

## Accessibility identifiers

`scope-view`, `scope-embedded`, `scope-display`, `scope-status`, `scope-aliased`, `scope-time-mapping`, `scope-scales`, `scope-notes`, `scope-run`, `scope-single`, `scope-autoset`, `scope-mode-<yt|roll|xy|fft|spectrogram|wignerVille|pseudoWigner>`, `scope-channels`, `scope-channel-1…4`, `scope-math`, `scope-preset-<raw>`, `scope-measure-<0…4>`, `scope-measurements`, `scope-cursor-readouts`, `scope-export-csv`, `scope-measure-add-to-patch`, `scope-trigger-mode-<auto|normal|single>`, `scope-trigger-source-<0…4>`, `scope-trigger-slope-<rising|falling>`, `scope-cursors-<off|time|amplitude|both>`, `scope-cursor-channel-<0…4>`, `scope-x-<0…3>`, `scope-y-<0…3>`, `scope-analysis-<0…4>`, `scope-log-frequency`, `scope-marginal-errors`, `scope-analysis-source` (the analyzed channel line under the display in FFT/time–frequency), `scope-start-<sensor>`, `scope-sensor-state-<sensor>` (a needed sensor that is not delivering), `scope-open-settings-<sensor>` (on denial). Knobs: `knob-scope-timebase`, `knob-scope-level` (display panel), `knob-scope-trigger-level` (trigger panel), `knob-scope-persistence`, `knob-scope-holdoff`, `knob-scope-cursor-t1|t2|y1|y2`, `knob-scope-ch<n>-scale|offset`, `knob-scope-math-scale|offset|corner`. Channel sheet: `scope-enable`, `scope-autoscale`, `scope-coupling-<dc|ac|removeGravity|removeEarthField>`, `scope-invert`, `scope-source-<stream id>`, `scope-add-to-patch`. Math sheet: `scope-math-enable`, `scope-math-op-<raw>`, `scope-math-input-a|b|c`, `scope-math-autoscale`.

## DEBUG launch options (screenshots, smoke tests)

`-scopePreset <name>` applies a probe on appear (not counted as a tap: sensors that prompt wait on the display's Start button, like a restored session), `-scopeMode <yt|roll|xy|fft|spectrogram|wignerVille|pseudoWigner>` sets the mode, `-scopeCursors <off|time|amplitude|both>` sets the cursors, `-scopeStop` stops after 1.5 s, `-scopeScroll <1…4>` scrolls to a panel, `-scopeSheet <ch1…ch4|math|notes>` opens a sheet, `-scopeTour <seconds>` steps through probes (as taps), modes, panels and the channel/math/notes sheets. Combine with `-fakeAll -open live/scope` (the live builder's Live tab hosts the Scope page and handles that path). Release builds ignore them.

## Threading

`ScopeEngine` is pure and `Sendable`. `ScopeModel`, `ScopeTrack`, `ScopeProbeStreams` and `ScopeRenderer` are main-actor. The time–frequency band focusing and image are computed in `Task.detached` (`ScopeModel.focusedTimeFrequency` → `computeTF`, both `nonisolated`) and the `CGImage` is made on the main actor; a generation counter (bumped on mode/channel change, cancel and disappear) drops late results.
