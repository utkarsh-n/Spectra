# API — radio-ui (`Spectra/UI/Radio/`, `Spectra/Render/Scenes/AntennaScene.swift`)

Owner: **radio-ui**. The Radio tab (SPEC-features §2 and the Radio bullets of §3c). Everything is `@MainActor` unless marked `nonisolated`. All physics comes from `RF` and `Phase`; this slice only wires knobs, runs builds off the main actor and draws.

## For other slices

### `RadioModel` (`app.radio`)

Kept from the stub: the type name, `init()`, `TabModel` conformance, `markers`, `carrier`, `lambda`, `resetDials()`, and the static `halfWaveDipolePattern(count:)` / `halfWaveDipoleGainDB(theta:)` used by `AppTests`.

| Member | What |
|---|---|
| `page: RadioPage` | `.antenna .systems .fourier .link` (the page picker). |
| `carrier: Double` | Carrier, Hz (100 kHz … 300 GHz). The antenna is designed for it; the strip marker sits on it. |
| `system: RF.RadioSystem`, `systemID` | The selected catalog system (default `ble`). |
| `select(system:jump:)` | Selects a system, tunes the carrier to it, resets the modulation override and link bandwidth, and (by default) jumps to Fourier with a toast. |
| `openSystemCard(id:) -> Bool` | Opens the Systems page on a catalog card: selects the system (no jump), clears a filter or "only in this iPhone" that would hide it, scrolls to the card (`systemsScrollTarget`) and toasts. False for an unknown id. |
| **Focused markers** | Every `app.focus(_:)` of a marker whose id starts with `RadioModel.systemMarkerPrefix` (`"live.system."`) calls `openSystemCard(id:)` with the rest of the id (`live.system.lte`, `live.system.nr-fr1`, `live.system.wifi-ax`…). This is Live's "You are on 5G NR NSA → open card" (`Docs/notes/live-requests.md` #2). Radio then sets `app.focusedMarker = nil` (`@Observable` skips equal values, so this is what lets the same card open again on the next tap). |
| `antenna: RF.AntennaParameters` | Style and knobs (frequency kept equal to `carrier`). |
| `antennaBuild: RadioAntennaBuild?` | The latest `RF.AntennaModel` + lobe mesh + E/H cuts (built in `Task.detached`, debounced). |
| `apertureBuild: RadioApertureBuild?` | The aperture phase-space view (Phase engine) of the latest build. |
| `followPhone`, `beamLock`, `target`, `aimAtBeam()`, `antennaAttitude`, `linkFactor()` | Follow phone / Beam lock (phased array re-steer through `RF.AntennaModel.steering(toward:)`), the world target, and `RF.AntennaModel.linkFactor` toward it. |
| `phoneAttitude() -> simd_quatd?` | Device → Core Motion world from the `attitude.pitch/yaw/roll` streams (R = Rz(yaw)·Rx(pitch)·Ry(roll)). `static attitude(pitchDeg:yawDeg:rollDeg:)` is pure. |
| `basebandConfig: RF.BasebandLinkConfig` | The Fourier page's configuration (system + SNR, delay spread, Doppler, fading, modulation override, text message). |
| `linkInput`, `linkResult`, `linkBandwidth`, `systemNoiseBandwidth`, `bleInput` | The Link page's `RF.LinkBudgetInput` / result, and the Live check's log-distance input. The default noise bandwidth is the system's widest channel; 6G (no standard width) uses its simulated placeholder waveform's occupied bandwidth and says so, Qi (a tone) is CW (0 Hz). |
| `tuneSpectrum()` | "Tune Spectrum here": `app.sendToSpectrum(lambda:label:)` with the carrier. |
| `openInScope()` | `app.openScope(["radio.i", "radio.q"], preset: "radio-iq")`. |
| `addToPatch(_:label:)` | `app.patch.addStreamSource("radio.i", label: "Radio I/Q")` (toasts itself if the Patch model does not). |
| `resetDials()`, `resetAlignment()` | Reset the visible page's dials; recentre the 3D view. |
| `setVisible(_:_:)`, `refreshDemand()` | Visibility bookkeeping (motion for Follow phone, the Beam-lock loop, the stream producer, the Fourier engine). |

Pure helpers (`nonisolated static`): `isAnalog(_:)`, `supportsText(_:)`, `supportsVoice(_:)`, `fadingKind(_:)`, `wrap(_:)`, `mount`, `upright`.

### Launch path

`-open radio/<page>[/<extra>[/<message>]]`:
- `radio/antenna/<style>` — any `RF.AntennaStyle` raw value (`dipole`, `phasedArray`, `dish`, …) or `follow` (turns Follow phone on).
- `radio/systems/<id>`, `radio/fourier/<id>[/<auto|text|voice>]`, `radio/link/<id>` — any `RF.SystemsCatalog` id (`fmcw-77`, `wifi-ax`, `fm`, …). `radio/systems/<id>` also scrolls to that card.

### Streams published (group `Radio`, provenance **MODEL**)

Registered at launch (`attach(to:)`); fed while the Radio tab shows Fourier or the Live or Patch tab is selected.

| Id | Unit | Rate | What |
|---|---|---|---|
| `radio.i` | V (norm.) | 2400 Hz | Received complex baseband I of the selected system, played **κ-slowed**: one simulated sample (every second one for oversampled single-carrier waveforms) per 1/2400 s. `isEM`, λ of the default carrier. |
| `radio.q` | V (norm.) | 2400 Hz | The Q companion (same timestamps). |
| `radio.audio` | FS | 48 kHz | AM/FM: the demodulated 1 kHz test tone in real time. While the Fourier page is in Voice mode, the demodulated voice (any system). |

### Marker

`radio.carrier` — label "Radio carrier · <system>" (or "Radio carrier" when tuned off the system's bands), MODEL, tab `.radio`.

### Persistence

`Spectra.radio.v1` → `RadioSaved` (every field optional; the stub's `{carrier}` still decodes). Follow phone, Beam lock, Voice and the BLE device restart off each launch. `-ui-testing` skips loading.

## Inside the slice

| File | Contents |
|---|---|
| `RadioModel.swift` | The model above. |
| `RadioSettings.swift` | Persisted value types: `RadioPage`, `RadioLobeScale`, `RadioSystemFilter`, `RadioFading`, `RadioMessage`, `RadioTFView`, `RadioTraceSource`, `RadioFourierSettings`, `RadioEnvironment`, `RadioLinkSettings`, `RadioSaved`. |
| `RadioAntennaCompute.swift` | `RadioAntennaBuild` (model, `RF.PatternMesh` 61 × 72, cuts, array phases) and `RadioApertureBuild` (RF aperture distribution → `Phase.Aperture`, zero-guarded to a record of at least `minimumRecord` = 32λ → Wigner → Fresnel shear → marginals vs RF factor). `nonisolated`, `Sendable`. |
| `RadioFourierEngine.swift` | `RadioFourierEngine` (frame-rate `RF.BasebandLink`, Welch spectrum + waterfall, BER/EVM, text decoding, push-to-talk voice through `HumSynth.playPCM`), `RadioFourierSnapshot`, `RadioTFResult` (Wigner–Ville vs spectrogram via `Phase.timeFrequency`). |
| `RadioVoiceLink.swift` | Digital voice: 48 kHz → 8 kHz µ-law (64 kbit/s) → QPSK 32 kBd RRC through `RF.Transmitter` / `ChannelSimulator` / `Receiver`. |
| `RadioStreams.swift` | `RadioStreamProducer` (the `radio.*` streams). |
| `RadioKnobs.swift` | Every `KnobSpec` and its binding (`knob-radio-…`). |
| `RadioTab.swift` | `RadioTab` (page picker, transport, scroll, and the scroll to `systemsScrollTarget`: the row id `RadioSystemsPage.rowID(_:)` sits on the card inside each timeline row, because an explicit id on a ForEach's direct child is not a `ScrollViewProxy` target), `RadioDialsSheet`, and `RadioFourierDriver` (one page-level `TimelineView` that advances the Fourier simulation each display frame while the page shows, 10 Hz while paused). |
| `RadioAntennaPage.swift`, `RadioAperturePanel.swift`, `RadioSystemsPage.swift`, `RadioFourierPage.swift`, `RadioLinkPage.swift` | The four pages. |
| `RadioPlots.swift` | `RadioHeatImage` + `RadioColorMap` (diverging: positive warm orange, negative cool blue), `RadioHeatMapView`, `RadioSpectrumView` (centred spectrum with channel mask and adjacent channels), `RadioBudgetChart` (the path-loss term reads "Path loss" when given `pathModelName`), `RadioRSSIPlot`, `RadioSpeculativeBadge`, `RadioDisabledReason`, `RadioChoice` (chips for non-Identifiable RF enums). `RadioKnobRow` (a knob row with per-knob disabled state) lives in the Fourier page file. |
| `RadioNotes.swift` | Field notes with sources (credits Utkarsh's construction). |
| `RadioCopy.swift` | `RadioCopy.us(_:)`: American spelling for the RF engine's sentences the tab shows ("centre-fed", "not modelled"). |
| `Render/Scenes/AntennaScene.swift` | `AntennaScene: SceneBuilder` — lit wire-mesh lobe in band colour, E/H cuts, beam arrow, dB rings, the antenna glyph per style (array elements glow with their excitation phase rolling at `phaseRollHz` = 0.6 Hz κ-slowed), the phone frame, and the target ray while following. `AntennaGlyph` value type. |

## Accessibility identifiers

Page picker `radio-page`; scroll `radio-scroll`. Antenna: `radio-style-<style>`, `radio-follow`, `radio-beam-lock`, `radio-aim`, `radio-lobe-scale-<scale>`, `radio-camera-{zoom-out,zoom-in,align}`, `radio-cut-plane-<e|h>`, `radio-reference-<pol>`, `radio-aperture-plane-<e|h>`, `radio-aperture-none`, `radio-antenna-tune-spectrum`, `radio-antenna-open-link`. Systems: `radio-filter-<filter>`, `radio-iphone-only`, `radio-system-<id>`, `radio-system-details-<id>` (scroll id of a row: `RadioSystemsPage.rowID(id)`). Fourier: `radio-change-system`, `radio-modulation-<system|mod>`, `radio-message-<auto|text|voice>`, `radio-text-field`, `radio-decoded-text`, `radio-push-to-talk`, `radio-sound-on`, `radio-trace-<sent|received>`, `radio-tf-<view>`, `radio-fading-<kind>`, `radio-fourier-open-scope`, `radio-fourier-add-patch`, `radio-fourier-tune-spectrum`; transport ⋯ items `radio-open-scope`, `radio-add-patch`, `radio-tune-spectrum`. Link: `radio-environment-<env>`, `radio-use-antenna-gain`, `radio-gas`, `radio-plf`, `radio-wall-<material>-{minus,plus}`, `radio-bandwidth-system`, `radio-ble-<name>`. Knobs: `knob-radio-carrier`, `knob-radio-<param>` (see `RadioKnobs.swift`). Plots (for tests and placing screenshots): `radio-cut-plot`, `radio-readout-directivity`, `radio-aperture-wigner`, `radio-iq-trace`, `radio-constellation`, `radio-spectrum-plot`, `radio-waterfall`, `radio-tf-wigner`, `radio-tf-spectrogram`, `radio-budget-chart`, `radio-rssi-plot`. Dials sheet: `radio-dials-filter-<filter>`, `radio-dials-iphone-only`.

## Threading

Antenna and aperture builds run in `Task.detached` (Sendable value results). The Fourier engine runs on the main actor, one frame per clock tick while visible (~0.3 ms per 4096-sample frame); its time–frequency pair is computed detached at ≤ 4 Hz. The stream producer is a detached loop (20 ms) with its own `RF.BasebandLink`s, writing the thread-safe rings.
