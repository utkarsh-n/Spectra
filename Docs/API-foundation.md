# API: foundation

The foundation's public API is documented in full in **`Docs/API.md`**, the file stage-2 builders read. This page lists what the foundation owns and where each part is described.

| Module | Folder | API.md section |
|---|---|---|
| Loop and tab models (`AppModel`, `TabModel`, toasts, `focus`, `sendToSpectrum`) | `Spectra/App/AppModel.swift` | §1 |
| Shared value types (`Provenance`, `AppTab`, `SpectrumMarker`, `TimeMapping`, `SensorID`, `SensorState`, `SensorChannel`, `SignalClock`, `TimestampedRing`, `SignalStream`, `StreamRegistry`, `SpectraFormat`) | `Spectra/Shared/` | §2 |
| Theme (`Theme`, `RGB`, `BandPalette`, `String.instrumentCaps`) | `Spectra/UI/Theme/` | §3 |
| Clock, settings, persistence, launch options, root view | `Spectra/App/` | §4 |
| Sensor hub and simulated channels (API kept by **live**) | `Spectra/Live/` | §5 |
| Components (`InstrumentScreen`, `TopBar`, `SpectrumStrip`, `Transport`, `ControlSheet`, `FieldNotesSheet`, `SettingsSheet`, `PermissionGate`, `GlassKnob`/`KnobSpec`/`KnobScale`, panels, readouts, badges, chips, toasts) | `Spectra/UI/Components/` | §6 |
| Plots (`LinePlot`, `Sparkline`, `SpectrumPlot`, `WaterfallView`, `ConstellationPlot`, `PolarPlot`, `LogRuler`, `VisibleTimeline`, `StreamWindow`) | `Spectra/UI/Plots/` | §7 |
| Feedback (`Haptics`, `HumSynth`, `SynthVoice`, `PCMRing`, `AudioRoute`) | `Spectra/Feedback/` | §8 |
| Rendering (`MetalCanvas`, `SceneBuilder`, `SceneBuffer`, `GlowColor`, `OrbitCamera`, `orbitGestures`, `CameraControls`, `HoloRenderer`, `Shaders.metal`, `DemoScene`) | `Spectra/Render/` | §9 |
| Accessibility identifiers and UI-test helpers | `SpectraUITests/UITestSupport.swift` | §10 |
| Build tools | `Tools/build.sh`, `Tools/agentbuild.sh`, `Tools/make-icon.swift` | §11 |

## Threading at a glance

- **Main actor.** `AppModel`, every tab model, `SensorHub` and its channels, `StreamRegistry`, `AppClock`, `JSONStore`, `Haptics`, `HumSynth`, `AudioRoute`, `HoloRenderer` (MTKView delegate calls arrive on main), `CanvasArbiter`, and all SwiftUI views.
- **Any thread.** `TimestampedRing`, `SignalStream`, `SynthVoice` (atomics), `PCMRing`, and every `nonisolated` value type in `Shared/` and `Render/SceneBuffer.swift`.
- **Off the main actor.** The simulated sensor generators (one detached task per running channel, writing rings every 20 ms), the synth render block, and the CoreHaptics handlers. Each of the last two is built in a `nonisolated` factory and hops back with `Task { @MainActor in … }`.
