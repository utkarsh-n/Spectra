# Spectra foundation API

Written by the **foundation** stage for every later builder. Everything here compiles today, and `AppTests` covers it (`Tools/build.sh test`). Read SPEC.md §2–3 first. This file covers the types you code against, how to use each one, and what thread it runs on.

Ground rules that follow from the build settings:

- The app target uses **Swift 6** with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Both setting names were checked in Xcode 27's `Swift.xcspec`. Any type you do not annotate is `@MainActor`.
- Value types that cross threads or must compile in the engine harnesses are declared `nonisolated` (for example `nonisolated struct Foo: Sendable`). Do the same for any `Codable` struct you persist, so its conformance is not main-actor isolated.
- SwiftUI `Shape`s must be `nonisolated struct`. Otherwise you get `#ConformanceIsolation`, as `KnobArc` did.
- Build any closure that runs on another thread (audio render blocks, CoreHaptics handlers, sensor handlers) inside a `nonisolated` function, so it does not inherit main-actor isolation. If it does, it traps off the main thread (`gyre-integration.md` §4.9). `@Sendable` closures are already nonisolated.
- To hop back to the main actor, use `Task { @MainActor in … }`, never `DispatchQueue.main.async`.

---

## 1. The loop: `AppModel` and your tab model

`App/AppModel.swift`: `@Observable @MainActor final class AppModel`. `SpectraApp` creates it once and injects it with `.environment(model)`. Read it in a view like this:

```swift
@Environment(AppModel.self) private var app
```

| Member | What it is |
|---|---|
| `launch: LaunchOptions` | Parsed launch arguments (§4). |
| `clock: AppClock` | The one display clock (§4). |
| `streams: StreamRegistry` | The universal scope bus (§3.4). |
| `haptics: Haptics`, `synth: HumSynth` | The one haptics service and the one synth (§7). Same objects as `Haptics.shared` / `HumSynth.shared`. |
| `spectrum: SpectrumModel`, `radio: RadioModel`, `live: SensorHub`, `spin: SpinModel`, `patch: PatchModel` | The five tab models. |
| `selectedTab: AppTab` | The visible tab. Bound to the `TabView`. |
| `focusedMarker: SpectrumMarker?` | The last marker tapped on a strip. Tabs may highlight it. |
| `settings: AppSettings` | Changes apply at once and persist after 400 ms (§4). |
| `toast: Toast?` | Read-only; `RootView` draws it. |
| `markers: [SpectrumMarker]` | Union of every tab model's `markers`: deduplicated by id (first wins), non-finite dropped, shortest λ first. |
| `focus(_ marker:)` | Jumps to `marker.tab`. A selection haptic plays on tab change, a tap haptic otherwise. |
| `sendToSpectrum(lambda:label:)` | Tunes Spectrum source A (`spectrum.tune(lambda:)`), switches to Spectrum, plays the success haptic and shows a toast. Refuses non-finite or non-positive λ with a boundary haptic. |
| `showToast(_:symbol:)` / `dismissToast()` | A glass message for 2.4 s. A newer toast replaces the current one. |
| `setActive(_:)` | Called by `scenePhase`. When inactive, it holds the clock, pauses the synth, stops sensors and haptics, and flushes settings. |
| `save()`, `resetSettings()` | Settings persistence. |
| `static func union(_ lists: [[SpectrumMarker]])` | The marker union, exposed for tests. |

### `TabModel`: replacing a stub

Each tab model conforms to:

```swift
@MainActor protocol TabModel: AnyObject {
  var markers: [SpectrumMarker] { get }   // every active frequency this tab shows
  func attach(to app: AppModel)           // optional; called once after all models exist. Keep `weak var app`.
}
```

The foundation wrote stubs that you replace in place. Keep the **type name, `init()` with no arguments, `markers`, and the conformance**. Everything else is yours.

| Owner | Stub files | Must keep |
|---|---|---|
| spectrum-ui | `UI/Spectrum/SpectrumModel.swift`, `SpectrumTab.swift` | `SpectrumModel.init()`, `markers`, **`tune(lambda:)`**, `SpectrumTab()` |
| radio-ui | `UI/Radio/RadioModel.swift`, `RadioTab.swift` | `RadioModel.init()`, `markers`, `RadioTab()` |
| live | `UI/Live/LiveTab.swift`, `Live/SensorHub.swift`, `Live/Fakes/SimGenerators.swift` | `LiveTab()`, the whole `SensorHub` API (§5) |
| spin-ui | `UI/Spin/SpinModel.swift`, `SpinTab.swift` | `SpinModel.init()`, `markers`, `SpinTab()` |
| patch | `Graph/Model/PatchModel.swift`, `UI/Patch/PatchTab.swift` | `PatchModel.init()`, `markers`, `PatchTab()` |

Each sub-model persists its own JSON under `Spectra.<tab>.v1` with `JSONStore` (§4). Skip loading when `LaunchOptions.current.uiTesting` is set. The stubs show how.

---

## 2. Shared value types (`Spectra/Shared/`)

All of these are `nonisolated`, `Sendable` and free of UI imports, so engines and harnesses can use them.

### `Provenance` (rule R4)

```swift
enum Provenance: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
  case table, model, live, inferred, sim, locked, needsPeer, analogy
  var badge: String      // "TABLE" … "NEEDS PEER"
  var meaning: String    // one sentence for VoiceOver and field notes
  static func union(_ items: [Provenance]) -> [Provenance]                    // deduplicated, in badge order
  static func union<S>(_ lists: S) -> [Provenance]                            // union of several lists (graph outputs)
}
```

The UI side lives in `ProvenanceBadge.swift`: `provenance.color` and `provenance.symbol`.

### `AppTab`

`enum AppTab: String { spectrum, radio, live, spin, patch }` with `title`, `symbol` (each name checked against CoreGlyphs), `rootIdentifier` (`"tab-root-<raw>"`), and `init?(argument:)`, which parses `-open radio/antenna`.

### `SpectrumMarker`

```swift
struct SpectrumMarker: Identifiable, Hashable, Sendable {
  let id: String            // unique app-wide: "spectrum.A", "radio.carrier", "live.ble", "spin.larmor"
  var label: String
  var lambda: Double        // vacuum wavelength, m. Non-EM signals use c/f so they sit where an EM wave of that f would.
  var provenance: Provenance
  var tab: AppTab           // where a tap jumps
  var isEM: Bool            // false → phosphor ANALOGY colour, dashed tick
  init(id:label:lambda:provenance:tab:isEM:)
  init(id:label:frequency:provenance:tab:isEM:)
  var frequency: Double; var logLambda: Double
  static let speedOfLight = 299_792_458.0
  static func lambda(forFrequency:) / frequency(forLambda:)
  static let logRange: ClosedRange<Double> = -13...8   // 0.1 pm … 100,000 km
}
```

### `TimeMapping` (rule R3)

```swift
enum TimeMapping: Equatable, Sendable {
  case realTime                      // 1 : 1
  case slowed(factor: Double)        // display runs `factor` × slower (κ: factor = f / κ)
  case heterodyned(fRef: Double)     // rotating frame: you see |f − f_ref|
  var badge: String; var detail: String
  var simulatedSecondsPerSecond: Double
  func displayedFrequency(of f: Double) -> Double
  func isAliased(frequency: Double, frameRate: Double) -> Bool   // displayed f > frameRate / 2
  static func aliasedFrequency(_ f: Double, sampleRate: Double) -> Double  // 60 Hz @ 99.8 → 39.8
}
```

Hand it to the transport: `TransportConfig(timeMapping: .slowed(factor: f / κ), frequency: f)`. The transport then shows the chip, and the ALIASED chip when it applies.

### Sensors: `SensorID`, `SensorState`, `SensorChannel`

```swift
enum SensorID: String, CaseIterable { motion, magnetometer, barometer, microphone, bluetooth, network, location, light, charging, uwb, nfc }
  // title, symbol, streamGroup, needsPermission
enum SensorState: Equatable, Sendable { idle, requesting, running, denied, unavailable(String), locked(String) }
  // isRunning, label ("Running", "Access off"…), reason (one sentence)

@MainActor protocol SensorChannel: AnyObject, Observable {
  var id: SensorID { get }
  var provenance: Provenance { get }       // .live real, .sim faked, .locked / .needsPeer
  var state: SensorState { get }
  var measuredRate: Double? { get }        // Hz from sample timestamps (nil for event streams)
  var streams: [SignalStream] { get }      // published while running, empty when stopped
  var markers: [SpectrumMarker] { get }    // while running
  var primaryReadout: String? { get }      // "48.2 µT", "6 radios · −52 dBm", refreshed at 2 Hz
  func start() async                       // asks for permission here (on the tap), then starts
  func stop()
}
// extension: title, symbol (from id)
```

`streams`, `markers` and `primaryReadout` are additive refinements of SPEC.md §3.5.

### Timestamps: `SignalClock`, `TimestampedRing<T>`, `TimedSamples<T>`

- `SignalClock.now()` returns system uptime in seconds. That is the same base as `CMLogItem.timestamp`, `CACurrentMediaTime()` and `AVAudioTime.seconds(forHostTime:)`, so every source stamps its samples on one clock.
- `TimestampedRing<T: Sendable>` is a `nonisolated final class: Sendable` guarded by `Synchronization.Mutex`. You can write it from a sensor callback or the audio thread and read it from the main actor. Timestamps must not decrease within one ring.

```swift
let ring = TimestampedRing<Float>(capacity: 3000)
ring.append(v, time: t)                                   // one sample
ring.append(contentsOf: values, times: times)             // batch with own times
ring.append(contentsOf: block, start: t0, interval: 1/48_000)   // uniform block (audio)
ring.snapshot()                  // TimedSamples, oldest first
ring.snapshot(since: lastTime)   // strictly after lastTime: incremental reads for FFTs
ring.snapshot(last: 4096)
ring.latest                      // (value, time)?
ring.count; ring.capacity; ring.totalAppended; ring.measuredRate(window: 2); ring.clear()
```

`TimedSamples<T>` has `values`, `times`, `count`, `isEmpty`, `duration` and `measuredRate`.

### Signal streams: the scope bus

```swift
struct StreamID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral, Comparable   // "mag.x"
enum StreamGroup { magnetometer, motion, bluetooth, network, audio, light, air, location, device, spin, radio, patch; order }

final class SignalStream: Sendable, Identifiable {
  init(id: StreamID, label: String, unit: String, nominalRate: Double, provenance: Provenance,
       isEM: Bool = false, lambda: Double? = nil, group: String, capacity: Int? = nil)
  let id, label, unit, nominalRate /*0 = irregular*/, provenance, isEM, lambda, group
  let ring: TimestampedRing<Float>
  var isIrregular: Bool; var measuredRate: Double?
  func append(_ value: Float, at time: Double)
  static func defaultCapacity(rate:) -> Int   // 30 s at the nominal rate; 2 s at ≥ 8 kHz; 4096 events if irregular
}

@MainActor @Observable final class StreamRegistry {
  private(set) var streams: [SignalStream]      // sorted by StreamGroup.order, then id
  func register(_ s: SignalStream)              // replaces a stream with the same id
  func register(_ batch: [SignalStream])        // one observation change
  func unregister(_ s: SignalStream)            // removes only this instance
  func unregister(_ id: StreamID); func unregister(prefix: "ble.")
  func stream(_ id: StreamID) -> SignalStream?
  func streams(in group: String) -> [SignalStream]
  var groups: [(name: String, streams: [SignalStream])]
}
```

Producers register a stream when they start and unregister it when they stop. Radio, Spin and Patch register their simulated streams with `.model` or `.sim` provenance. Use the stream's group name as the `StreamGroup` constant.

### `SpectraFormat` (readout text)

- `significant(x, 3)`
- `scientific(1.8e15)` → "1.8 × 10¹⁵"
- `si(v, unit:)`
- `frequency(2.44e9)` → "2.44 GHz"
- `wavelength(0.1229)` → "12.3 cm"
- `decibels(v, unit:, decimals:, signed:)`
- `clock(s)` → "MM:SS.hh"
- `rate(hz?)` → "99.8 Hz" or "irregular"
- `superscript(n)`

Minus signs come out as U+2212. These formatters are not for parity tests; `Core/` has the JS-exact ones.

---

## 3. Theme (`UI/Theme/`)

### `Theme` tokens (exact values from SPEC.md §2)

| Group | Tokens |
|---|---|
| Content layer | `background` (0.025, 0.045, 0.04), `panel` (0.065, 0.095, 0.083), `plotWell` #040807, `hairline` (white 7 %), `phosphor` (0.4, 0.96, 0.56), `amber` (1, 0.75, 0.37), `muted` (0.61, 0.71, 0.65), `text` #E8F1EC, `dim` #7E978A, `ionizing` #FF8F6B, `grid`, `axis`. Each colour also comes as an `…RGB` token. |
| Fields | `fieldE` #61B3FF, `fieldB` #FF5C7A, `poynting` (amber), `fieldEx` #1AEDFF, `fieldEy` #FFE82E |
| Dial accents (parameter identity) | `dialE0` (blue), `dialTheta` #59F0B0, `dialDelta` #FF8FB8, `dialPhi` #C799FF, `dialAmber`, `dialLambda(λ)` (band colour) |
| Data identity | `sources` A/B/C = phosphor, rose, ice #8FD3FF; `channels` CH1–4 = phosphor, amber, ice, rose; `analogy` (phosphor), `analogyAlt` (amber) |
| Shape | `panelRadius` 26, `wellRadius` 18, `cardRadius` 20, `chipRadius` 14, `glassCardRadius` 22, `gutter` 16, `stackSpacing` 22, `panelPadding` 20, `minTouch` 44 |
| Type | `panelTitleFont`, `readoutTitleFont`, `readoutValueFont`, `eyebrowFont`, `captionFont`, `annotationFont` (9 pt mono), `symbolFont` (serif) |
| Motion | `Theme.animation(reduceMotion, .smooth(duration: 0.25))` returns `nil` under Reduce Motion |

`RGB` is a `Sendable` sRGB token. It provides `.color`, `.color(opacity)`, `.linear` (SIMD3<Float> for Metal), `.srgb`, `.mix(_:_:)` and `init(hex:)`. There is also `Color(hex:)`.

`String.instrumentCaps` uppercases Latin letters for labels and leaves Greek and µ alone ("λ/2 LENGTH", "µT"). Use it wherever you would call `.uppercased()`, because uppercasing µW gives MW.

### `BandPalette` (hue = EM frequency, rule R2)

This is spectra-lab's `displayColor`. Band colours apply outside the visible range. Inside it, the lifted Bruton spectral colour is rounded to 8 bits like the web version, and tests check that it equals spectra-lab's hex exactly.

```swift
BandPalette.bands                       // [Band] gamma…radio: key, name, short, lo, hi, rgb, color
BandPalette.band(forWavelength:)
BandPalette.rgb(forWavelength:) / color(forWavelength:) / color(forFrequency:)
BandPalette.color(for: marker)          // band colour, or Theme.analogy when !isEM
BandPalette.spectralRGB(nanometres:)
```

---

## 4. App infrastructure (`App/`)

### `AppClock`

`@Observable @MainActor`. The visible `MetalCanvas` calls `tick(at:)` from its render loop. Whenever the clock animates, `ClockDriver` (a `TimelineView` behind `RootView`) calls it too. Ticks arriving less than 2 ms apart are deduplicated.

| API | Behaviour |
|---|---|
| `time` | Seconds. Changes every frame and is **not observed**; renderers read it. |
| `displayTime` | `time` republished at 10 Hz for SwiftUI. |
| `playing` | Editing while paused never starts playback. |
| `frameRate` | Measured display rate, used for ALIASED. |
| `isAnimating` | `playing && active` |
| `tick(at:)` | The first tick after a pause, background or scene change only rebases, so there is no catch-up. |
| `advance(dt:)` | `dt` clamped to 0…0.1 s (`AppClock.maxStep`). |
| `step()` | Pauses, then adds exactly 1/60 s. |
| `togglePlaying()`, `setActive(_:)`, `reset()` | |

Simulation code advances its own state by the clock's `dt`, or reads `clock.time`. Do not use your own timers.

### `AppSettings` and `JSONStore`

`AppSettings` (`Codable`, `Sendable`) has these fields:

- `soundOn` (default false)
- `hapticsOn` (true)
- `hapticStrength` (0.85)
- `continuousHum` (false)
- `powerUnit`: `.dBm` or `.watts`
- `distanceUnit`: `.metric` or `.imperial`
- `disabledSensors: Set<SensorID>`
- `simulation`: `.automatic` or `.always`

It also has `isEnabled(sensor)`. Settings persist under `Spectra.settings.v1`. Decoding tolerates missing keys and clamps strength.

`JSONStore<Value: Codable>(key:defaults:delay: = 400 ms)` is `@MainActor`:

- `load() -> Value?`
- `schedule(_:)`, debounced
- `save(_:)`, immediate
- `flush()`, which writes any pending value; call it on background
- `hasPending`, `clear()`

### `LaunchOptions` (`-flag`, `-flag=value`, `-flag value`)

These work in every build:

- `-open <tab>[/<path>]` sets `openTab` and `openPath`. `openPath` is yours to interpret, e.g. `-open radio/antenna`.
- `-ui-testing` gives fresh defaults (a throwaway suite), a paused clock, and no persisted tab state.

The rest work only in DEBUG builds; Release ignores them (`gyre-integration.md` §8):

| Flag | Field | Fake |
|---|---|---|
| `-fakeAll` | `fakeAll` | Turns on every fake below that is not set explicitly. |
| `-fakeMag[=earth\|hum60\|hum50\|magnet\|magsafe]` | `fakeMag` | Earth (0, 22, −40) µT through the swaying pose. `hum60` adds 1.6 µT at 60 Hz and 0.4 µT at 120 Hz at **99.8 Hz ± 2 %**. `magnet` is a dipole approaching from 30 to 5 cm. `magsafe` is a static step. |
| `-fakeBLE[=N]` / `-fakeRadio` | `fakeBLE` | N advertisers (default 6). RSSI = −40.2 dB − 30·log₁₀d, plus Rayleigh fading, in 1 dB steps, with 2 % of adverts missed. |
| `-fakeMic[=room\|voice\|tone:F]` | `fakeMic` | 48 kHz. `room` is the 196/294/392 Hz open fifth plus a clap every 1.6 s. `voice` is formants. `tone` is a sine. |
| `-fakeCell[=lte,nsa,…]`, `-fakeWiFi` | `fakeCell`, `fakeWiFi` | RTT 20–60 ms and link quality steps. |
| `-fakeBaro[=still\|stairs\|weather]` | `fakeBaro` | 1 Hz pressure and relative altitude. |
| `-fakeGNSS`, `-fakeLight[=K,lux]`, `-fakeUWB`, `-fakeNFC`, `-fakeAR` | … | |
| `-simSway`, `-simPose p,y,r` | `simSway`, `simPose` | Simulated attitude. |
| `-seed N`, `-scenario kitchen\|desk\|stairwell` | `seed`, `scenario` | |
| `-startMic`, `-startAR`, `-startLive <sensor>` (repeatable) | | Starts these at launch. |

`isFaked(_ sensor:)` and `anyFake` are also available.

Example: `xcrun simctl launch booted com.utkarsh.spectra -fakeAll -open live`

### `RootView`

A `TabView(selection: $app.selectedTab)` using the iOS 18+ `Tab(title, systemImage:, value:)` API. Each tab carries the identifier `tab-<raw>`. `RootView` also holds the `ClockDriver` and the toast layer. Your tab root view sits inside it as `SpectrumTab()` and so on.

---

## 5. Sensors (`Live/`)

`SensorHub` is `@Observable @MainActor`, conforms to `TabModel`, and is available as `app.live`. It holds one channel per `SensorID` and counts who holds each one:

```swift
app.live.acquire(.magnetometer, by: "scope")      // starts it if nobody held it (permission prompt happens here)
let x = app.streams.stream("mag.x")               // read its ring
app.live.release(.magnetometer, by: "scope")      // stops when the last holder leaves
app.live.releaseAll(by: "scope")
app.live.channel(.bluetooth)                      // any SensorChannel
app.live.holders(of: .microphone)                 // Set<String>
app.live.channels; app.live.markers; app.live.isEnabled(.nfc)
app.live.setActive(_:); app.live.apply(settings)  // AppModel calls these
```

Start a source only when its card, node or instrument is **visible**, and release it on disappear. Background and Settings → Sensors are handled by the hub.

In stage 1 every channel is a `SimulatedChannel`. It writes SIM data at realistic rates from a background task, and each sample carries its own timestamp. NFC is `.locked` and UWB `.needsPeer` unless `-fakeNFC` / `-fakeUWB` are set. The **live** builder swaps in real sources and keeps this API and these stream ids:

| Sensor | Streams (unit, nominal rate) |
|---|---|
| motion | `accel.x/y/z` (g, 100 Hz), `gyro.x/y/z` (rad/s, 100), `attitude.pitch/yaw/roll` (°, 100) |
| magnetometer | `mag.x/y/z`, `mag.norm` (µT; 100 Hz, or 99.8 Hz with hum fakes) |
| barometer | `baro.pressure` (Pa, 1 Hz), `baro.altitude` (m, 1) |
| microphone | `mic.left` (FS, 48 kHz, 2 s ring), `mic.level` (dBFS per 1024 samples) |
| bluetooth | `ble.<uuid>.rssi` (dBm, irregular, λ of 2.44 GHz) |
| network | `net.rtt` (ms, 1 Hz), `net.quality` (0–3, 1 Hz) |
| location | `gnss.hacc` (m, 1 Hz) |
| light | `light.lux` (10 Hz), `light.cct` (K, 10) |
| charging | `battery.level` (%, 0.2 Hz) |
| uwb | `uwb.distance` (m, 10), `uwb.azimuth` (°, 10) |
| nfc | `nfc.tap` (event, every 8 s) |

The deterministic generators in `Live/Fakes/SimGenerators.swift` are `SimRandom` (SplitMix64 plus Gaussian), `SimPose`, `SampleGrid` and one `…Generator` per source. Their output feeds the same rings, so FFTs and aliasing behave as on the device.

---

## 6. Components (`UI/Components/`)

### `InstrumentScreen`: the frame of every tab

```swift
InstrumentScreen(tab: .radio, title: nil, subtitle: "Antennas and systems", notes: RadioTab.notes,
                 transport: TransportConfig(timeMapping: .heterodyned(fRef: f)),   // nil hides it
                 scrolls: true) {                       // false: content fills (full-bleed canvas / own ScrollView)
  ControlSheet(title: "Radio controls", resetDials: model.resetDials) { … }   // the Dials sheet
} content: {
  InstrumentPanel("Antenna", number: "01", provenance: [.model]) { … }
}
```

`InstrumentScreen` provides:

- its own `NavigationStack`, with the system bar hidden
- `TopBar`: Dials on the left, title and eyebrow subtitle, a glass capsule with ⓘ and ⚙
- `SpectrumStrip`
- content padded by the 16 pt gutter, 22 pt apart, with the scroll id `<tab>-scroll`
- `Transport` as a bottom inset
- the sheets: your dials, `FieldNotesSheet(notes)`, and `SettingsSheet`

A full-screen view puts its own `TopBar` at the top. Add a Close button through `trailing: [TopBarButton(id: "fullscreen-close", title: "Close", symbol: "arrow.down.right.and.arrow.up.left") { … }]`.

### Panels, readouts and badges

- **`InstrumentPanel(_ title:, number:, provenance:, accessory:, content:)`**: a numbered phosphor panel (radius 26, 7 % hairline). The title comes out as "01 WAVE SCOPE" followed by badges. It is never glass.
- **`PlotWell(height:, grid:)`**: the dark well for a plot or canvas (radius 18, phosphor grid, 20 % frame).
- **`PlotGrid`**, **`Eyebrow("LIVE · MAGNETOMETER")`**, and **`.panelCaption()`**, the muted closing sentence of a panel.
- **`Readout(_ title:, value:, color: = amber, provenance:)`**: a caption-sized title above a monospaced value, combined for accessibility. **`ReadoutGrid(columns:)`** collapses to one column at accessibility sizes.
- **`ProvenanceBadge(.live, compact:)`** and **`ProvenanceBadges([...])`**: deduplicated and in badge order.

### Knobs

`KnobScale` is a pure, `Sendable` mapping:

- `position(of:)` and `value(at:)`, linear or log
- `step` rounding; a step ≥ 1 makes a rotary switch
- `origin` for bipolar knobs
- `clamp`
- `modulated(base:depth:cv:)`: Gyre's modulation, applied in **position space**

`KnobSpec`:

```swift
KnobSpec(id: "radio-carrier", title: "Carrier", symbol: "", glyph: "f", tint: …, range: 100e3...300e9,
         defaultValue: 2.44e9, logarithmic: true, origin: nil, step: 0,
         detents: [KnobDetent(2.44e9, "Wi-Fi / BLE 2.44 GHz")], hint: "…", detail: "…", unit: "", format: { … })
// isSwitch, position(of:), value(at:), detent(at:) (tolerance 0.004), label(for:)
```

Keep static knob tables inside an `@MainActor` type, because `KnobSpec` holds a `Color` and a closure and is not `Sendable`.

`GlassKnob(spec:value:modulation:showsSlider:onActive:onModulate:)` gives:

- a relative drag: up or right increases, and 230 pt is the full sweep of 270°
- 24 ticks per sweep with tick haptics
- labelled detents that capture within ±0.02 and play a detent haptic, with a bounce
- rotary-switch clicks
- double-tap to reset
- a long press that calls `onModulate` ("Modulate from…")
- an optional linear slider underneath, in position space
- a VoiceOver adjustable action plus a "Reset" action
- arrow keys with `@FocusState`
- the identifier `knob-<id>` (and `knob-<id>-slider`)

`KnobModulation(value:color:source:depth)` draws the dashed modulation arc of the Drives matrix. Its `caption` reads "Driven by Microphone · depth 50 %".

The other knob views:

- `KnobReadout(spec:value:modulation:)` is the floating glass card.
- `KnobGrid(specs:value:modulation:columns: 4, showsSliders:)` is a grid in one `GlassEffectContainer`, with the readout card floating above it while a knob is held.

### Controls

- **`ActionButton(_ title:, symbol:, prominent:, tint:, action:)`**: `.glassProminent` for the one primary action, otherwise `.glass`. Plays the tap haptic.
- **`GlassToggle(_:isOn:symbol:subtitle:)`** and **`GlassSlider(title:value:range:step:color:format:)`**.
- **`ChoiceChips(items:selection:id:tint:label:)`**: explicit selection chips. Each chip's identifier is `<id>-<item.id>`. **`ChipLabel(number:title:symbol:)`**.
- **`StatusChip(text:detail:color:symbol:)`** and **`LevelMeter(level:)`**.

### Transport

The transport is `Transport(config: TransportConfig(timeMapping:frequency:actions:))`; `InstrumentScreen` places it. It contains:

- Play/Pause (prominent)
- Step: pause plus 1/60 s
- a ⋯ menu holding your `TransportAction(id:title:symbol:destructive:action:)` items, then Reset clock
- `TimeMappingChip`
- `AliasedChip`, shown when `timeMapping.isAliased(frequency, clock.frameRate)`
- `ClockReadout`: RUN or HOLD with MM:SS.hh

Space toggles play. The layout stacks at accessibility sizes.

### Sheets

- **`ControlSheet(title:resetDials:resetAlignment:resetDialsHint:resetAlignmentHint:content:)`**: `NavigationStack` with an inline title and Done. Detents are `[.medium, .large]`, and content behind stays live up to medium. Reset dials and Reset alignment are pinned at the bottom and play the success haptic. **`SheetCaption("…")`**.
- **`FieldNotes(title:intro:sections:includesBadgeLegend:)`**: sections are `FieldNoteSection(number:title:paragraphs:items:sources:)`. `FieldNoteItem(.model, "Title", "detail")` shows a badge beside its text. Use `FieldNoteSource("Title", "https://…")` for citations. Paragraphs accept inline Markdown. A "Reading the badges" section is appended automatically. **`FieldNotesSheet(notes:)`**.
- **`SettingsSheet()`**: a Form with Feedback (Sound, Haptics, Haptic strength, Feel a detent, Continuous hum), Sensors (one enable per source, DEBUG simulation mode, Sensor census), Units, and About with the privacy footer and a restore option. **`SensorCensusView()`**: state, badge, measured rate, stream count and a Run switch for each source. The live builder adds capability flags.
- **`PermissionGate(channel:startTitle:explanation:) { content }`**: shows `content` while running. Otherwise it shows the honest state: a Start button whose tap asks for permission, "Asking…", denied with Open Settings, or the unavailable or locked reason.
- **`ToastView`**: drawn by `RootView`.

### `SpectrumStrip`

A mini log ruler (−13…8) with every `app.markers` entry:

- Tap focuses the nearest marker within 22 pt.
- The context menu offers per-marker "Show in <tab>" and "Tune Spectrum here".
- VoiceOver gets one pair of named actions per marker.
- `InstrumentScreen` places the strip.

---

## 7. Plots (`UI/Plots/`): SwiftUI `Canvas`

| Type | Use |
|---|---|
| `PlotScale(domain, logarithmic:)` | `fraction`, `value(at:)`, `ticks(target:)` (decades or 1-2-5), `padded(values)` |
| `GraphicsContext.phosphorStroke(path, color:, width:, glow:, dash:)` | The phosphor look: a wide faint halo, then a glow, then a crisp core. Also `phosphorDot`, `annotation` (9 pt mono) and `plotGrid(in:columns:rows:centre:)`. |
| `VisibleTimeline(minimumInterval:paused:) { date in … }` | Redraws only while on screen, with the scene active and `paused == false`. Wrap live plots in this. |
| `StreamWindow.read(stream, seconds:, maxPoints:)` | The newest seconds of a stream, decimated with min/max pairs so peaks survive. |
| `LinePlot(series: [PlotSeries], xRange:, yRange:, columns:, rows:, yLabel:)` | `PlotSeries(id:values:x:color:width:glow:dashed:steps:label:)`. `steps` gives sample-and-hold for irregular streams. |
| `Sparkline(values:color:range:fill:steps:)` | Card and node previews. |
| `SpectrumPlot(bins: [Float] dB, binWidth:, frequencyRange:, logFrequency:, dbRange:, color:, showsPeak:, markers: [FrequencyMarker])` | FFT display. Bin i is at i·binWidth. |
| `WaterfallBuffer(width:height:dbRange:)` + `WaterfallView(buffer:)` | Spectrogram backed by a reused `CGImage`. `push(_ dbRow:)` from the main actor; newest row on top. |
| `ConstellationPlot(points: [SIMD2<Float>], ideal:, range:)` | Received symbols as dots, ideal points as amber rings. |
| `PolarPlot(gains: [Double] dB, reference:, floor: -30, color:)` | Radiation cut: 0° at the top, clockwise. |
| `LogRuler(range:markers:cursors: [RulerCursor], showsFrequency:)` | The full-size wavelength ruler. The static `drawBands`, `drawBandNames`, `drawMarker` and `x(_:in:range:)` are shared with the strip. |

---

## 8. Feedback (`Feedback/`)

### `Haptics` (`@MainActor`, `Haptics.shared`)

- Every transient obeys `enabled`, `strength` (0…1), a 35 ms minimum gap and the app being active.
- Calls: `tap()`, `selection()`, `grab()`, `tick()`, `detent()`, `switchClick()`, `resetClick()`, `boundary()`, `success()`, `resonance(strength)`.
- Named form: `play(.tap / .selection / .grab / .tick / .detent / .boundary / .success / .resonance(x))`.
- Orbitals' continuous controls use `beginAdjustment()`, then `detent(normalized:)` (72 steps, coalesced, boundary pulse at the ends), then `endAdjustment()`.
- Gyre extras: `transient(intensity:sharpness:minGap:)`, `crackle(intensity:)` (call it at Poisson times), and `spinUp()`.
- The continuous hum is `updateHum(intensity:sharpness:)`. Call it every frame from a live instrument. Parameters are sent at most 40 times a second, the hum stops below 0.02, and it runs only when `humAllowed` (Settings → Continuous hum) is on. `stopHum()` ends it.
- `stop()` runs on background.
- `soundTick` is set by `AppModel` when Sound is on, so ticks also click.

### `HumSynth` (`@MainActor`, `HumSynth.shared`)

One `AVAudioEngine` with one `AVAudioSourceNode`. The engine starts lazily, and only when **Sound is on and something claims a voice**. It pauses when the app is inactive.

```swift
guard let voice = app.synth.voice(for: "spin.fid") else { return }   // up to 8 voices; nil if all taken or…
voice.tone(440, level: 0.5, pan: 0)          // sine
voice.noise(level: 0.3, color: 0.6)          // white → dark rumble
voice.fid(2128.8, t2: 1.2, level: 0.8)       // ring-down that restarts on every call (true-pitch NMR)
voice.silence()
app.synth.releaseVoice(for: "spin.fid")
app.synth.playPCM(samples, sampleRate: 8000) // demodulated audio → PCM ring, resampled to the output rate
app.synth.pcmGain = 0.8
try app.synth.connect(node, format: fmt)     // attach + iOS 27 connectNode to the main mixer
app.synth.tick(.detent)                      // UI click (Haptics does this when sound is on)
```

- `SynthVoice` controls are `Synchronization.Atomic`s, smoothed per sample on the audio thread (τ 30 ms).
- The render block is built in a `nonisolated` factory, so it is not main-actor isolated.
- The synth observes engine configuration changes, the iOS 27 session notifications (`AVAudioSession.didBecomeInactiveNotification`, `resumptionRecommendationNotification` with `resumptionContextKey`, checked in the SDK headers), route changes and media-services resets.
- `PCMRing` is the lock-protected mono ring. The audio thread reads it with `withLockIfAvailable` and never blocks.
- `HumSynth.resample(_:from:to:)` does linear-interpolation resampling.

### `AudioRoute` (`@MainActor`)

The single owner of the session category:

- Synth only: `.ambient` with mix-with-others, so the silent switch mutes it.
- While the microphone listens, set `AudioRoute.recording = true`. That selects `.playAndRecord` in `.measurement` mode.
- `isPrivateOutput` reports headphones or Bluetooth. Use it to allow live duplex without acoustic feedback.

---

## 9. Rendering (`Render/`)

### Scenes

Make your model, or a dedicated class, conform to `SceneBuilder`:

```swift
@MainActor protocol SceneBuilder: AnyObject {
  func build(into buffer: inout SceneBuffer, time: Double, size: CGSize)   // once per frame, main actor
  var needsContinuousRedraw: Bool { get }   // default false; true for live sensor scenes (redraw while paused)
}
```

`SceneBuffer` is reset for you every frame. World convention: right-handed, +Y up, and the default camera looks down −Z.

| Area | API |
|---|---|
| Camera | `buffer.use(orbitCamera)`, or set `buffer.camera = SceneCamera(viewProj:eye:)` |
| Look | `buffer.background = .grid(pitch: 32)` or `.plain`; `buffer.bloom` (0.6); `buffer.scanlines` (0.03, forced to 0 under Reduce Motion); `buffer.reduceMotion`, which means drop flicker, scan bands and autonomous spin |
| Holo (3D, depth-tested, butt-capped, additive) | `line(a, b, color:, end:, width: pt, glow:, dash:, dashOffset:)`, `polyline(points, color:, end:, width:, closed:)`, `point(p, color:, size:)`, `ring(center:normal:radius:color:width:segments:from:to:dash:)`, `arrow(from:to:color:width:head:)` |
| Phosphor (2D, points, top-left origin) | `segment2D(a, b, …, hollow:)`, `trace([CGPoint], color:, width:, glow:, dash:)` with continuous dashes, `dot2D(p, color:, diameter:, hollow:)` |
| Helpers | `project(p) -> CGPoint?`, `screenDistance(a, b)`, `aspect`, `size`, `SceneBuffer.capacity` (65,536 per material) |

`GlowColor(Theme.fieldERGB, intensity: 1.6, alpha: 1)` is a linear colour times intensity. Values above 1 bloom, and on XDR they glow brighter than white. It also offers `.scaled(k)` and `.alpha(a)`.

`GlowSegment` is the 80-byte instance shared by both materials. It mirrors `Shaders.metal`; tests check the stride, as they do for `FrameUniforms` (128 bytes).

### `MetalCanvas`

```swift
PlotWell(height: 300, grid: 0) {
  MetalCanvas(scene: model.scene, camera: $model.scene.camera, home: WaveScene.home,
              panWithOneFinger: false, maximumFramesPerSecond: 60, redrawKey: model.revision, label: "Wave scope")
}
CameraControls(camera: $model.scene.camera, home: WaveScene.home, id: "wave-camera")   // zoom out / in / align
```

- **One canvas renders at a time.** `CanvasArbiter.shared` hands rendering to the most recently shown canvas. A full-screen canvas therefore takes over and hands back on dismissal. Covered canvases pause.
- The canvas draws continuously while `clock.isAnimating || scene.needsContinuousRedraw`. Otherwise it draws on demand on every SwiftUI update: camera changes, `redrawKey`, model values the view reads.
- It costs nothing off screen, when hidden or in the background.
- It runs at 60 fps, or 30 on Low Power Mode or at a serious thermal state. Use up to 120 for live spin.
- Renderer failures show a `ContentUnavailableView` ("Renderer unavailable").
- It ticks `AppClock` from its render loop.

`.orbitGestures(camera, home:, panWithOneFinger:, label:)` is applied automatically when you pass a camera. It gives:

- Orbitals' UIKit gesture surface: one finger rotates at 0.45°/pt, or pans with `panWithOneFinger`; two fingers pan; pinch zooms about the fingers; double-tap aligns
- detent haptics
- a VoiceOver adjustable action (yaw ±5°) and named actions: zoom in/out, move left/right/up/down, reset camera
- arrow keys and +/−
- the accessibility value "Yaw N degrees, tilt N degrees, zoom N percent, pan X …"

`OrbitCamera` is `Codable` and `Hashable` and uses Orbitals' limits: yaw wraps to [−180, 180), pitch is clamped to ±85, zoom to 0.25…6, pan to ±1.5. It has `rotate`, `pan`, `zoom(by:anchor:)` (the anchored point stays fixed, which tests check), `reset(to:)`, `viewMatrix`, `projectionMatrix(aspect:)` (Metal depth 0…1, then image zoom and pan), `sceneCamera(aspect:)` and `eye`.

### Pipeline (`HoloRenderer` + `Shaders.metal`)

1. **Scene pass**, into rgba16Float with a depth32Float attachment:
   - `backgroundFragment`: plot-well colour, 32 pt grid, centre cross, vignette and scanlines
   - `holoVertex/Fragment`: 3D segments projected to pixels, butt caps on polylines, a round dot for a lone point, depth test `lessEqual` without writes, core + Gaussian glow, optional dashes
   - `phosphorVertex/Fragment`: Orbitals' analytic capsules with glow, 56 % dashes, hollow rings and hot-core dots, added into HDR
2. **Bloom**: prefilter `smoothstep(0.35, 1.3, peak)`, then a 5-tap separable blur at ½ resolution (1.4 texels) and ¼ resolution (2.2 texels).
3. **Composite**: scene + bloom½ × 0.6 + bloom¼ × 0.54, then scanlines, then `softClip` into `currentEDRHeadroom` (≤ 3). The drawable uses extended linear Display P3, so every colour you pass is linear.

The renderer is triple-buffered and never blocks: if three frames are in flight it drops the frame and keeps the clock running.

Later owners add their scenes as `Render/Scenes/<Tab>*.swift`. `scope` also owns `Render/Scope.metal`. **`Render/Scenes/DemoScene.swift`** is a reference scene: a circularly polarized E/B helix with stems, the beam axis in band colour, an S arrow, a dashed ring and a phosphor 2D trace.

---

## 10. Accessibility identifiers (stable; UI tests use only these)

| Area | Identifiers |
|---|---|
| Tabs | `tab-<tab>` (tab bar item) · `tab-root-<tab>` (screen title) · `<tab>-scroll` |
| Top bar | `dials-open` · `field-notes-open` · `settings-open` · `spectrum-strip` |
| Sheets | `dials-scroll` · `dials-done` · `dials-reset` · `dials-reset-alignment` · `field-notes-scroll` · `field-notes-done` · `settings-form` · `settings-done` · `settings-sound` · `settings-haptics` · `settings-strength` · `settings-hum` · `settings-feel` · `settings-census` · `settings-sensor-<id>` · `census-<id>` |
| Transport | `transport-play` · `transport-step` · `transport-more` · `transport-time-mapping` · `transport-aliased` · `transport-clock` (label "Simulation running\|paused, MM:SS.hh") |
| Knobs | `knob-<id>` · `knob-<id>-slider` |
| Camera | `<id>-zoom-out` · `<id>-zoom-in` · `<id>-align` |
| Other | `permission-start` · `permission-open-settings` · `toast` · `<chips id>-<item>` |

`SpectraUITests/UITestSupport.swift` provides:

- `UITest.launch(extra)`, which launches with `-fakeAll -ui-testing`
- `UITest.hittable(id, in:)`, the first *hittable* match; TabView keeps other tabs' copies of the top bar in the hierarchy
- `UITest.tap`, `UITest.reveal` (swipes until hittable), `UITest.select(tab:identifier:in:)` and `UITest.screenshot(name, in:)`

---

## 11. Build and test

Never run `xcodebuild` or `xcodegen` in the iCloud folder.

```sh
Tools/build.sh sim | test | uitest | device [extra xcodebuild args]   # whole project, mirrored to $TMPDIR/SpectraBuild
Tools/agentbuild.sh <name> <ownedPath>... [-- test]                     # your slice over $TMPDIR/SpectraBaseline
xcrun swift Tools/make-icon.swift [out.png]                             # 1024×1024 opaque icon
```

- `build.sh` copies the generated `Info.plist` back to `Spectra/Info.plist` whenever it changes.
- `SPECTRA_BUILD_DIR` and `SPECTRA_SIM` override the defaults.
- Logs are `<mode>.log`, and result bundles go to `results/`.

## Scope hooks (added by the orchestrator at stage 1.5)
- `app.openScope(_ streams: [StreamID], preset: String? = nil)` — any card, node or instrument's "Open in Scope". Sets `app.scopeRequest` (`ScopeRequest(streams:preset:)`, `Shared/ScopeRequest.swift`) and switches to the Live tab. The Live tab (owner **live**) switches its page picker to **Scope** whenever `scopeRequest` changes.
- `ScopeView()` (owner **scope**, `UI/Scope/ScopeView.swift`): the Live tab's Scope page; follows `app.scopeRequest` (applies its streams to CH1…CH4 and its preset).
- `ScopeView(fixedStreams:)`: an embedded scope for given streams (Patch Scope sink, previews); ignores `app.scopeRequest`.
- Stream ids follow `"<group>.<name>"` (e.g. `mag.x`, `mag.norm`, `accel.z`, `ble.<id>.rssi`, `mic.left`, `spin.fid`, `radio.i`). Publishers document their ids in their API doc.
- `app.patch.addStreamSource(_ stream: StreamID, label: String)` — "Add to Patch" from any card, instrument or the Scope. The **patch** owner implements it (adds a source node bound to the stream, places it, switches to the Patch tab and toasts); callers only call it.
