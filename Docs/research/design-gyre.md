# Gyre: design system, UX logic, sensors, rendering and tooling

Research for **Spectra** (native iOS 27 SwiftUI port of `spectra-lab`, plus live sensors, an antenna and frequency simulator, a Fourier visualizer and a node graph).
Source: `/path/to/developer/Documents/AI Stuff/Gyre` (read-only; nothing in it was modified).
SDK checked: Xcode 27.0 (27A5194q), `iPhoneOS27.0.sdk`.

> **Snapshot warning.** Another session was editing Gyre while this was written (Oct 3 2026, 14:20–14:40 CDT). It was adding a v3 **Object** console page with five skins (`GyroObject`: wireframe, gyroscope, glassOrb, top, planet) and Glass knobs (`frost`, `dispersion`, `refraction`). `Model/`, `Render/` and `UI/Console|TopBar|InfoSheet` changed between reads. All line references below match the 14:40 state. Treat the Object page and the glass-orb pass as work in progress. Everything else (knobs, haptics, audio, sensors, AR, bloom, build) was stable across reads.

---

## 0. TL;DR for Spectra

- **The look.** A full-bleed Metal hologram (`HoloView`, an `MTKView` in `UIViewRepresentable`, `isUserInteractionEnabled = false`). On top of it sits a thin SwiftUI layer of Liquid Glass chrome: a `TopBar` (telemetry card plus a capsule toolbar group), a `KnobConsole` of 60 pt glass knobs, a floating `KnobReadout` card and an `InfoSheet`. The app is dark only, the status bar is hidden, it is portrait only, and it runs at 120 Hz.
- **The feel.** Every touch has a Core Haptics answer: grab, tick, detent, switch click, reset, toggle and spin-up. A **continuous looping haptic** follows the simulation (`Haptics.updateHum`, at most 40 Hz parameter updates). A live **AVAudioSourceNode synth** follows the simulation too (`HumSynth`).
- **The architecture.** The render loop owns time. `HoloRenderer.draw(in:)` calls `model.advance(dt:ar:)` once per display frame, so there are no timers. `GyroModel` is `@Observable`, but all per-frame state is `@ObservationIgnored`. SwiftUI only sees `telemetry`, which is republished at **10 Hz** (`clock - lastTelemetry > 0.1`).
- **Sensors.**
  - Core Motion device motion is **pulled** each frame at a requested 1/120 s. It uses `.xArbitraryCorrectedZVertical` and the calibrated magnetometer in µT.
  - The barometer (`CMAltimeter`) is opt-in.
  - The microphone is an `AVAudioEngine` input tap into a 16384-sample lock-protected ring buffer. It gives RMS, bass and onset values, and a triggered scope with an XY delay embedding.
  - ARKit world tracking feeds the same Metal pipeline.
  - **Gyre has no FFT and touches no radios** (no CoreLocation, CoreBluetooth, NearbyInteraction or CoreTelephony). Spectra must add both.
- **Simulator stand-ins** are wired through `ProcessInfo.processInfo.arguments`: `-simSway`, `-fakeMic`, `-fakeAR`, `-startMic` and `-startAR`.
- **Build.** `Tools/build.sh` rsyncs the project to `$TMPDIR/GyreBuild/src`, runs `xcodegen generate` there and builds with `-derivedDataPath $TMPDIR/GyreBuild/dd`, because `xcodebuild` hangs on the iCloud folder. `Tools/physcheck/run.sh` compiles the pure-Swift physics with a Mac harness. I re-ran it: **8/8 PASS** (section 9).

---

## 1. Project shape and frame architecture

```
Gyre/App/GyreApp.swift          WindowGroup { ContentView().preferredColorScheme(.dark).statusBarHidden() }
Gyre/UI/ContentView.swift       ZStack layering, gestures, scenePhase, reduceMotion
Gyre/UI/GlassKnob.swift         GlassKnob + KnobArc (Shape)
Gyre/UI/Console.swift           ConsolePage, KnobConsole, ObjectTile, LevelMeter, KnobReadout
Gyre/UI/TopBar.swift            TopBar (toolbar group + Menus), TelemetryCard
Gyre/UI/InfoSheet.swift         NavigationStack/List sheet, .medium/.large detents
Gyre/UI/ARViews.swift           CoachingOverlay (ARCoachingOverlayView), ARBanner
Gyre/Model/GyroModel.swift      @Observable owner: sensors → physics → feedback → telemetry
Gyre/Model/Knobs.swift          KnobID, KnobSpec, KnobDetent, Experiment presets, GyroObject, GlassParams
Gyre/Physics/{MathUtil,GyroSim,BubbleWorld}.swift   pure Swift + simd (compiled by physcheck too)
Gyre/Sensors/{MotionSource,MicListener,ARController}.swift
Gyre/Feedback/{Haptics,HumSynth}.swift
Gyre/Render/{HoloRenderer,HoloScene,GyroMeshes}.swift + Holo.metal
Tools/build.sh, Tools/physcheck/{run.sh,main.swift}, Tools/make-icon.swift
```

**Frame loop** (`HoloRenderer.draw(in:)`, `HoloRenderer.swift` around lines 261–420):
1. Compute `dt = min(now - lastTime, 1/15)`. The first frame uses 1/120.
2. Get `model.ar.frameState(...)` if AR is active.
3. Call `model.advance(dt:ar:)`. This samples motion and the mic, steps the physics, steps the motes and wobble, updates haptics and the hum, and publishes telemetry every 0.1 s.
4. Call `builder.build(...)` to make the line instances.
5. Encode the passes and present.

**Observation discipline** (`GyroModel`):
- Observed properties are the user-facing state only: `params`, `sound`, `object`, `glass`, toggles, `paused`, `telemetry`, `activeKnob`, `isRunning` and `micState`.
- Everything that changes per frame is `@ObservationIgnored`: `sample`, `trail`, `ripples`, `scope`, `filmDrive`, `centerBlend`, `clock`, `bubbleRegion` and `arScreen`. So are the subsystems (`motion`, `sim`, `motes`, `haptics`, `hum`, `mic`, `ar`).
- **Copy this for Spectra.** The 120 Hz engine must never invalidate SwiftUI. Publish a small `Telemetry: Equatable` struct at 10 Hz.

**Lifecycle**: `ContentView.onChange(of: scenePhase)` calls `model.start()` on `.active` and `model.stop()` on `.background`. `start()` starts motion, haptics, the hum (if `soundOn`) and the barometer (if enabled). On first start it applies the launch args. Later starts call `ar.resume()`. `HoloView.updateUIView` sets `view.isPaused = !model.isRunning`.

**Layout** (`ContentView`):
```swift
ZStack {
  HoloView(model:).ignoresSafeArea()
  if model.ar.isActive, !model.ar.simulated { CoachingOverlay(controller:).ignoresSafeArea().allowsHitTesting(model.ar.isCoaching) }
  VStack(spacing: 0) {
    TopBar(...).padding(.horizontal, 16).padding(.top, 6).layoutPriority(1).zIndex(1)
    if model.ar.isActive { ARBanner(...).padding(.top, 8).transition(.blurReplace) }
    bubbleRegion            // GeometryReader { Color.clear.contentShape(Rectangle()) + gestures }
    KnobConsole(...).padding(.horizontal, 12).padding(.bottom, 4).layoutPriority(1)
  }
}
.background(Color.black)
.sheet(isPresented: $showInfo) { InfoSheet(model:) }
.persistentSystemOverlays(.hidden)
```
- The **bubble's size is a layout result.** `bubbleRegion` publishes its global frame through `.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.bubbleRegion = $0 }`. The renderer eases the bubble toward `center = region.mid` and `radius = min(w, h) * 0.44` with time constant τ = 0.12 s (`phoneSetup`). Folding the knobs therefore makes the hologram swell smoothly, with no explicit animation. **This is the key UX trick to reuse:** the SwiftUI layout drives a Metal camera.
- Entering AR folds the knobs (`knobsOpen = !on`, `.spring(duration: 0.45, bounce: 0.2)`).
- Accessibility:
  - The canvas is one element with `accessibilityLabel`, a computed `accessibilityValue` ("Spinning at N rpm, axis N degrees…") and named `accessibilityAction`s ("Spin faster", "Relaunch").
  - The `MTKView` itself is hidden (`accessibilityElementsHidden = true`).

---

## 2. Design tokens (as used, verbatim values)

### Colour
| Token | Value | Where |
|---|---|---|
| Background | `Color.black`; launch `LaunchBackground` sRGB (0.006, 0.012, 0.030) | ContentView, Assets |
| AccentColor | sRGB (0.38, 0.88, 1.00) | Assets |
| Primary action tint | `Color(red: 0.2, green: 0.62, blue: 0.85)` on `.glassProminent` | Relaunch / Place |
| Mic-on glass tint | `Color(red: 0.2, green: 0.75, blue: 0.45).opacity(0.6)` | `.buttonStyle(.glass(.regular.tint(...)))` |
| Phosphor meter | `Color(red: 0.35, green: 1.0, blue: 0.55)` gradient + shadow r 4 | `LevelMeter` |
| Selected tile tint | `Color(red: 0.25, green: 0.7, blue: 1.0).opacity(0.45)` | `ObjectTile` |
| Time-scale chip | `Color(red: 0.72, green: 0.55, blue: 1.0).opacity(0.35)` capsule | TelemetryCard |
| Telemetry icon | `Color(red: 0.36, green: 0.86, blue: 1.0)` | `fanblades.fill` |
| Text | white; secondary labels `.white.opacity(0.62)`; `.secondary` in cards | GlassKnob |

**Per-knob tints** (`KnobSpec.tint`; each knob has its own hue, as in Orbitals' `dial*` colours):

| Knob | Tint (r, g, b) |
|---|---|
| Motor | (0.36, 0.86, 1.0) |
| Inertia | (0.30, 1.0, 0.82) |
| Gravity | (1.0, 0.70, 0.28) |
| Balance | (1.0, 0.45, 0.62) |
| Friction | (1.0, 0.50, 0.30) |
| Air | (0.55, 0.75, 1.0) |
| Magnet | (0.55, 1.0, 0.45) |
| Time | (0.72, 0.55, 1.0) |
| Listen | (0.35, 1.0, 0.6) |
| Drives | (1.0, 0.62, 0.85) |
| Gain | (0.45, 0.85, 1.0) |
| Scope | (0.4, 1.0, 0.55) |
| Frost | (0.8, 0.9, 1.0) |
| Dispersion | (1.0, 0.55, 0.85) |
| Refraction | (0.5, 0.85, 1.0) |

**Hologram palette** (`HoloPalette`, linear `F3`, in `HoloScene.swift`; the InfoSheet legend reuses these):

| Token | Value | Token | Value |
|---|---|---|---|
| rotor | (0.30, 0.88, 1.00) | field B | (0.50, 1.00, 0.42) |
| rotorCore | (0.85, 0.97, 1.00) | trailHead | (0.35, 1.00, 0.90) |
| cage | (0.62, 0.42, 1.00) | trailTail | (0.55, 0.35, 1.00) |
| axle | (0.75, 0.86, 1.00) | horizon | (0.45, 0.60, 1.00) |
| momentum L | (0.25, 1.00, 0.85) | north | (1.00, 0.35, 0.40) |
| torque τ | (1.00, 0.32, 0.80) | mote | (0.70, 0.85, 1.00) |
| gravity g | (1.00, 0.66, 0.22) | emitter | (0.30, 0.75, 1.00) |
| phosphor (scope) | (0.35, 1.00, 0.55) | | |

### Type
- The interface uses SF Pro with `.monospacedDigit()` on numbers. It does **not** use `design: .monospaced`, which is an Orbitals trait.
- Knob title: `.caption2.weight(.semibold)`, `.textCase(.uppercase)`, `.tracking(0.6)`.
- Knob value: `.caption.weight(.medium).monospacedDigit()` with `.contentTransition(.numericText(value:))`.
- Buttons: `.subheadline.weight(.semibold)`. Toolbar icons: `.body.weight(.semibold)` in 42×44 frames.
- Readout card: `.headline` title and `.headline.monospacedDigit()` value, plus `.footnote` hint.
- InfoSheet legend glyphs (L, τ, g, B): `.system(.headline, design: .serif).italic()`.

### Shape, spacing and motion
- Corner radii: cards and readouts use `.rect(cornerRadius: 22)`, tiles use 18, and the toolbar group and banner use `.capsule`. Circular buttons use `.buttonBorderShape(.circle)` at 36×36.
- `GlassEffectContainer` spacing: 18 for the console, 12 for the top bar and 4 for the tile shelf.
- Springs:
  - Picker page: `.spring(duration: 0.35, bounce: 0.2)`
  - Readout: `.spring(duration: 0.3, bounce: 0.25)`
  - Fold: `.spring(duration: 0.45, bounce: 0.2)`
  - Telemetry expand: `.spring(duration: 0.4, bounce: 0.25)`
  - Knob grab: `.spring(duration: 0.25, bounce: 0.4)`
  - Resets: `.smooth(duration: 0.5)`. Experiment apply: `.smooth(duration: 0.6)`.
- Transitions:
  - Pages and expanding content: `.blurReplace`
  - Knob deck: `.blurReplace.combined(with: .scale(0.9, anchor: .bottom))`
  - Readout: `.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom))`
- Symbol effects:
  - `.symbolEffect(.bounce, value: bump)` on knob detents
  - `.symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive:)` on the telemetry fan
  - `.contentTransition(.symbolEffect(.replace))` on toggling icons
- Reduce Motion (`@Environment(\.accessibilityReduceMotion)` is pushed into `model.reduceMotion`) turns off the scan band, flicker, scanlines, ripples, film shimmer and wobble.

---

## 3. (a) `GlassKnob` (`UI/GlassKnob.swift`, 188 lines)

**API**
```swift
struct GlassKnob: View {
  let spec: KnobSpec; @Binding var value: Double; var haptics: Haptics; var onActive: (Bool) -> Void
}
struct KnobArc: Shape { var from, to, sweep: Double; animatableData = AnimatablePair(from, to) }
```

**Geometry**
- Total frame 84×84 with `.contentShape(Circle())`.
- Track: `KnobArc(0→1)`, stroke white 0.1, 3 pt, round caps. Arc radius = 84/2 − 2 = 40.
- Value arc: `KnobArc(lo→hi)`, where `lo/hi = min/max(originPosition, position)`. **Bipolar knobs light up from their zero**: `origin: 0` on Gravity (−1…3) and Balance (−1…1). Stroke `spec.tint` at 3 pt with `.shadow(color: tint.opacity(0.8), radius: 4)`.
- Detent dots: 3×3 at `offset(y: -41)`, rotated to each detent. White at 0.45, or 1.0 when it is the current detent.
- Puck: a 60×60 `ZStack` of the SF Symbol (16 pt semibold, white 0.9, `.symbolEffect(.bounce, value: bump)`) and a pointer `Capsule` 3.5×10 at `offset(y: -22)` with `.shadow(color: tint, radius: 3)`.
- **The Liquid Glass call:**
  ```swift
  .glassEffect(.regular.tint(spec.tint.opacity(startPosition == nil ? 0.1 : 0.32)).interactive(), in: .circle)
  .scaleEffect(startPosition == nil ? 1 : 1.07)
  .animation(.spring(duration: 0.25, bounce: 0.4), value: startPosition == nil)
  ```
  The glass tint deepens and the puck swells 7% while you hold it.
- Sweep is 270°. Angle = `-sweep/2 + sweep * position` (0° is up).

**Interaction**
- `DragGesture(minimumDistance: 2)` with `@GestureState dragging`. `onChange(of: dragging)` calls `finish()`; this handles cancellation too.
- Mapping is relative: `p = clamp(startPosition + (dx − dy) / 230, 0, 1)`. Dragging up or right turns it up, and 230 pt is the full travel.
- **Ticks**: `Int(p * 24)`, so 24 light ticks per full sweep.
- **Detent capture**: if `|position(detent) − p| < 0.02`, snap to the detent value. Haptic and bounce fire only on entry (`lastDetent` tracks it).
- **Rotary switch** (`spec.isSwitch == step >= 1`): integer positions, each a named detent. Every change gives a firm click.
- Double-tap (`TapGesture(count: 2)`, simultaneous) resets to `spec.defaultValue` with `.smooth`.
- `onActive(true/false)` drives `model.activeKnob`, which shows the `KnobReadout` above the console.

**Haptics per event** (`haptics.transient(intensity:sharpness:)`)
| Event | Intensity | Sharpness |
|---|---|---|
| Grab | 0.45 | 0.7 |
| Tick (every 1/24) | 0.32 | 0.9 |
| Detent entry | 0.9 | 0.3 |
| Switch position | 0.9 | 0.35 |
| Double-tap reset | 0.7 | 0.4 |
| VoiceOver nudge (continuous; ±1/20 of travel) | 0.4 | 0.8 |
| VoiceOver nudge (switch; ±1) | 0.7 | 0.4 |

**Accessibility**: `.accessibilityElement(children: .ignore)`, label = title, value = `spec.format(value)`, hint = `spec.hint`, and `.accessibilityAdjustableAction`.

**`KnobSpec`** (`Model/Knobs.swift`) is the data-driven half. Copy it.
```swift
struct KnobSpec: Identifiable {
  let id: KnobID; let title: String; let symbol: String; let tint: Color
  let range: ClosedRange<Double>; let defaultValue: Double
  var logarithmic = false; var origin: Double? = nil; var detents: [KnobDetent] = []; var step: Double = 0
  let hint: String; let detail: String
  let keyPath: ReferenceWritableKeyPath<GyroModel, Double>; let format: (Double) -> String
  var isSwitch: Bool { step >= 1 }
  func position(of:) / value(at:)   // log mapping: log(v/lo)/log(hi/lo); step rounding; clamp
  func detent(at:) -> KnobDetent?    // tolerance 0.004 in position space
}
```
- `hint` is the one-liner shown in the readout card. `detail` is the paragraph in the InfoSheet.
- Detents carry **physical meaning as labels**. Gravity, for example, has Inverted, Zero-g, Moon 0.166, Mars 0.38, Earth 1 and Jupiter 2.53.
- Switches format with `label([...])`.

**For Spectra**, natural knobs include:
- frequency (log, with band detents: ELF/VLF/LF/MF/HF/VHF/UHF/SHF/EHF, or named services such as "FM 88–108", "Wi-Fi 2.4", "5G n78")
- antenna length as a fraction of λ (detents λ/4, λ/2, 5/8 λ)
- gain, phase, element count, and a "Generation" rotary switch (1G…6G)

---

## 4. (b) Console, TopBar, InfoSheet and banner layouts

### `KnobConsole` (`UI/Console.swift`)
```swift
GlassEffectContainer(spacing: 18) {
  VStack(spacing: 12) {
    if open {
      VStack(spacing: 10) {
        Picker("Knobs", selection: $page.animation(.spring(duration: 0.35, bounce: 0.2))) {
          ForEach(ConsolePage.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.tabs)          // iOS 27-only TabsPickerStyle
        .frame(maxWidth: 320)        // was 260 with two pages
        switch page { case .physics: Grid(2 rows × 4) ; case .sound: soundPage ; case .object: objectPage }
      }
      .transition(.blurReplace.combined(with: .scale(0.9, anchor: .bottom)))
    }
    controls   // always visible bottom row
  }
}
.overlay(alignment: .top) { if let id = model.activeKnob { KnobReadout(...).offset(y: -78) } }
```
- **Verified in the SDK:** `TabsPickerStyle` / `.tabs` is `@available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *)` and unavailable on watchOS (`SwiftUI.swiftinterface` line ~16485). It renders as a glass capsule segmented control with a sliding glass selection (see `Documentation/sound-trace-scope.png`).
- The knob grid is `Grid(horizontalSpacing: 2, verticalSpacing: 10)` with `GridRow { ForEach(specs.prefix(4)) }` and `suffix(4)`. Knobs use `.frame(maxWidth: .infinity)`, so 4 per row fill the width.
- **Sound page**:
  - A one-row grid of 4 knobs, dimmed to 0.55 opacity unless the mic is on.
  - A mic button: `Label(micTitle, systemImage: "mic.fill"/"mic.slash.fill")` with `.buttonStyle(.glass(on ? .regular.tint(green.opacity(0.6)) : .regular))` and `.disabled(micState == .denied)`.
  - A `LevelMeter`: a 6 pt capsule bar, width = `level`, with `.animation(.linear(duration: 0.1))`.
  - Mic button copy by state: "Listening", "Asking…", "Mic access is off in Settings", "Mic unavailable" and "Turn on mic".
- **Object page (v3, in progress)**: a nested `GlassEffectContainer(spacing: 4)` holding an `HStack` of `ObjectTile`s. Each tile is a `Button` with `.buttonStyle(.plain)` and `.glassEffect(selected ? .regular.tint(...).interactive() : .regular.interactive(), in: .rect(cornerRadius: 18))`, `minHeight: 62`, and `.accessibilityAddTraits(selected ? .isSelected : [])`. Below the tiles sit either the Glass knobs or the subtitle text.
- **Controls row** (morphing glass):

  | id | Control | Style |
  |---|---|---|
  | `"relaunch"` | Relaunch, as a `Label` with `systemImage: "hurricane"` | `.buttonStyle(.glassProminent).tint(...)` |
  | `"place"` | Place / Pick up (AR only) | same as Relaunch |
  | `"pause"` | play/pause | `.glass` + `.buttonBorderShape(.circle)`, 36×36 |
  | `"reset"` | reset knobs (only when open) | `.glass` + `.buttonBorderShape(.circle)`, 36×36 |
  | `"fold"` | "Knobs" | `.glass`, `systemImage` `"chevron.down"` / `"dial.medium.fill"` |

  - Every control has `.glassEffectID(id, in: glass)` with `@Namespace private var glass`.
  - In AR, Relaunch shrinks to an icon-only circle and Place takes the prominent slot. The shared namespace makes the glass shapes morph. `Spacer(minLength: 0)` separates the left and right clusters.
  - `Label`s use `.lineLimit(1).fixedSize().frame(minHeight: 36)`.
- **`KnobReadout`** is a floating card that names what you are turning and what it does physically:
  - Header: symbol, title and detent label (tinted), then `format(value)`.
  - Body: `hint` in `.footnote`, `.secondary`.
  - Styling: `.glassEffect(.regular, in: .rect(cornerRadius: 22))`, `maxWidth 420`, `.allowsHitTesting(false)`.
  - **Pattern: teach physics at the moment of interaction.** Spectra should do this for every knob ("Wavelength 12.5 cm · Wi-Fi 2.4 GHz · half-wave dipole is 6.2 cm").

### `TopBar` (`UI/TopBar.swift`)
```swift
GlassEffectContainer(spacing: 12) {
  HStack(alignment: .top, spacing: 10) {
    TelemetryCard(model:, expanded:)
    Spacer(minLength: 0)
    HStack(spacing: 0) { AR button; experimentsMenu; layersMenu; info button }   // each 42×44 icon
      .foregroundStyle(.white).padding(.horizontal, 4)
      .glassEffect(.regular.interactive(), in: .capsule)
  }
}
```
- **Menus grow out of the glass group.** `Menu { Section("Experiments") { Button { Label(title, systemImage:); Text(subtitle) } } }` gives two-line items with a subtitle.
- The Layers menu has `Section`s ("Gyroscope", "Show", "Feel", "Sensors") of `Toggle(isOn:) { Label(...); Text(subtitle) }`. "Live air pressure" is `.disabled(!model.motion.barometerAvailable)`.
- **`TelemetryCard`**:
  - Collapsed, it shows rpm, precession Hz and an optional time-scale chip.
  - A tap expands a `Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6)` of live sensor rows: Axis tilt, Gyroscope °/s, Accelerometer g, Magnetometer µT or "calibrating", and Barometer kPa / "off" / "—".
  - With simulated sensors it shows an orange caption: "Simulated motion. Drag outside the bubble to tilt."
  - Styling: `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))`, `.contentShape(.rect(cornerRadius: 22))`, `.onTapGesture` with haptic (0.35, 0.6), `.accessibilityElement(children: .combine)` and `.accessibilityAddTraits(.isButton)`.
  - **This is the "sensor transparency" pattern Spectra should adopt** for live RF and EMF readings: collapsed headline, tap for raw sensors, and an explicit simulated flag.

### `InfoSheet` (`UI/InfoSheet.swift`)
- `NavigationStack { List { Section ... } .navigationTitle("Gyre") .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } } }`
- `.presentationDetents([.medium, .large])` and `.presentationBackgroundInteraction(.enabled(upThrough: .medium))`. The hologram keeps running and stays touchable behind a half-height sheet; see `Documentation/slow-motion-nutation.png`.
- Sections: intro paragraph (`.callout`); "Touch"; "What you're seeing" (colour legend from `HoloPalette` with serif-italic glyphs); "In your room (AR)"; "Sound"; "Knobs" (`ForEach(KnobSpec.physics + KnobSpec.sound)` showing `Label(title, systemImage:)` tinted plus `detail`); "Sensors in play" (`LabeledContent` with live monospaced values and the barometer `Toggle`); and a footnote on the method.
- Helpers:
  - `info(symbol, title, body)`: a `Label` with a VStack of semibold subheadline over callout secondary, icon `.foregroundStyle(.tint)`.
  - `legend(color, glyph, text)`
  - `sensor(symbol, name, value)`

### `ARBanner` and `CoachingOverlay` (`UI/ARViews.swift`)
- **ARBanner**: `Label(text, systemImage: message == nil ? "arkit" : "exclamationmark.triangle.fill")` in `.footnote.weight(.medium)`, padding 14/10, `.glassEffect(.regular, in: .capsule)`, `.contentTransition(.opacity)` and `.allowsHitTesting(false)`. The copy comes from `ARController.message` or from carry/placed instructions.
- **CoachingOverlay**: `ARCoachingOverlayView` with `goal = .tracking`, `activatesAutomatically = true` and the delegate set to the controller. Hit-testing is enabled only while coaching.

---

## 5. (c) `Haptics.swift` and `HumSynth.swift`

### `Haptics` (Core Haptics, `final class`, not an actor)
- **Engine**: `CHHapticEngine()` with `playsHapticsOnly = true` and `isAutoShutdownEnabled = false`.
  - `resetHandler` dispatches to main, then `hum = nil; humRunning = false; try? engine?.start()`.
  - `stoppedHandler` dispatches to main, then clears the hum player.
  - The engine is created lazily in `start()`. `stop()` stops the hum and the engine. `supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics`.
- **Continuous hum** (`updateHum(intensity:sharpness:)`, called every frame):
  - Below intensity 0.02 the hum stops.
  - Otherwise it lazily builds one `CHHapticEvent(eventType: .hapticContinuous, parameters: [.hapticIntensity 1, .hapticSharpness 0.5], relativeTime: 0, duration: 30)` into `engine.makeAdvancedPlayer(with:)` with `loopEnabled = true`.
  - It starts with `CHHapticTimeImmediate`.
  - Parameters are throttled to **≤ 40 Hz** (`now - lastSend > 1/40`). It sends `CHHapticDynamicParameter(.hapticIntensityControl, value: intensity)` and `(.hapticSharpnessControl, value: sharpness − 0.5)`. Sharpness control is an offset, so the base 0.5 is subtracted.
- **`transient(intensity:sharpness:minGap:)`** builds a one-event pattern into `makePlayer` and starts it. `minGap` throttles bursts: string pulls use 0.03 s, and the Geiger crackle uses its own scheduler.
- **`spinUp()`**:
  - A 0.55 s continuous ramp (intensity 0.9, sharpness 0.3).
  - `CHHapticParameterCurve(.hapticIntensityControl)` from 0.1 to 1 over 0.5 s, and `(.hapticSharpnessControl)` from −0.3 to 0.4.
  - A transient click (1.0, 0.9) at 0.56 s.
  - All of it is built with `CHHapticPattern(events:parameterCurves:)`.
- **Mapping in `GyroModel.updateFeedback`** (reusable as a template for "signal strength you can feel"):
  ```
  spinNorm = min(revs/150, 1); strain = min(|ω_phone × L| / 0.03, 1)
  nod = clamp((axisSpeed − runningMean_τ0.8s) / max(mean, 0.3), −0.7, 0.7)
  intensity = (spinNorm > 0.003 ? 0.1 + 0.34·√spinNorm : 0)·(1 + 0.6·nod) + 0.55·strain   (×0.35 if AR placed)
  sharpness = 0.12 + 0.65·spinNorm + 0.2·strain
  ```
- **Geiger crackle** (magnetometer-driven; directly useful for Spectra's EMF probe):
  ```swift
  if params.magnet > 0.01, field > 120 /*µT*/, clock >= crackleDue {
    let rate = min((field - 100) / 30, 30)                       // clicks per second
    crackleDue = clock + Double.random(in: 0.3...1.7) / rate     // Poisson-ish jitter
    haptics.transient(intensity: Float(0.35 + 0.4 * params.magnet), sharpness: 1)
  }
  ```
- **Feedback-loop guard**: after its own haptic pokes and kicks, the model calls `mic.ignoreOnsets(for: 0.2)` so the case rattle is not heard as a clap. Spectra needs the same guard if haptics and mic analysis coexist.

### `HumSynth` (AVAudioEngine plus `AVAudioSourceNode`)
- **Controls**: a `final class Controls` of plain `Double`s (`rotorHz`, `level`, `pan`, `hiss`, `whoosh`, `wobble`, `wobbleHz`). The main thread writes them and the audio thread reads them with **no lock**. The doc comment says torn reads cannot happen on arm64 and a stale read is inaudible after smoothing. A per-voice `Voice` class holds DSP state.
- **Format**: `AVAudioFormat(standardFormatWithSampleRate: outputNode.outputFormat(forBus: 0).sampleRate (fallback 48_000), channels: 2)`. This is deinterleaved Float32; the render block writes `buffers[0]` (L) and `buffers[1]` (R).
- **DSP per sample**:
  - One-pole smoothing of every control, τ = 30 ms (`smooth = 1 − exp(−1/(0.03·fs))`).
  - Blade-pass tone is 6× rotor phase with harmonics 0.55/0.17/0.06, plus the fundamental at 0.30/0.12.
  - Amplitude modulation is `1 + wobble·sin(phaseW)`.
  - Noise source: xorshift32 white noise.
  - Rumble: a one-pole low-pass, k = 0.02.
  - Air: a band-pass made as the difference of two one-poles, with `k = min(0.5, 0.01 + rotorHz·0.0009)`.
  - Mix `×0.2`, then equal-power pan: `angle = (pan+1)·π/4`, L = cos·1.414, R = sin·1.414.
  - `mainMixerNode.outputVolume = 0.9`.
- **Resilience**: `NotificationCenter` observer on `.AVAudioEngineConfigurationChange` (object: engine, queue: .main) restarts the engine. `stop()` calls `engine.pause()`.
- **`AudioRoute`** (in `MicListener.swift`) is the single owner of the session category:
  - Not recording: `.ambient`, mode `.default`, `[.mixWithOthers]`. The silent switch mutes the hum.
  - Recording: `.playAndRecord`, mode `.measurement` (no voice processing or AGC), `[.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]`.
  - Both paths end with `setActive(true)`.

### iOS 27 deprecations (verified in `iPhoneOS27.0.sdk` headers)
| API | Status in SDK 27.0 | What Gyre does |
|---|---|---|
| `AVAudioEngine connect:to:format:` | `API_DEPRECATED_WITH_REPLACEMENT("connect:to:format:error:", ios(8.0, 27.0))`; the replacement is `NS_SWIFT_NAME(connectNode(_:to:format:))` (AVAudioEngine.h:281/295) | **Uses `try engine.connectNode(source, to: engine.mainMixerNode, format: format)`**, catches, and detaches on failure |
| `AVAudioNode installTapOnBus:bufferSize:format:block:` | Deprecated `ios(8.0, 27.0)`; replacement `installTapOnBus:bufferSize:format:error:block:` is `NS_REFINED_FOR_SWIFT` (AVAudioNode.h:117/160), and the SDK has **no AVFAudio Swift overlay** that re-exposes it | **Keeps the deprecated `installTap(onBus:bufferSize:format:)`** with the comment "iOS 27 deprecates this for an error-reporting variant that the beta SDK doesn't yet refine for Swift; this one still works." Expect one deprecation warning. |
| `AVAudioPlayerNode play` | Deprecated → `playAndReturnError:` = Swift `playAudio()` (AVAudioPlayerNode.h:312/323) | Not used. **Spectra: use `try player.playAudio()`** if it plays buffers. |
| `AVAudioSessionInterruptionNotification` (+ keys) | Deprecated `ios(6.0, 27.0)` → `AVAudioSessionDidBecomeInactiveNotification` + `AVAudioSessionResumptionRecommendationNotification` | **Not handled at all.** This is a gap; only engine configuration changes are observed. |
| `AVAudioSessionCategoryOptionAllowBluetooth` | Deprecated → `AllowBluetoothHFP` | Uses `.allowBluetoothA2DP` only |
| `UIScreen.mainScreen` | Deprecated: "Use a UIScreen instance found through context instead (i.e, view.window.windowScene.screen)" | **Uses `view.window?.windowScene?.screen.currentEDRHeadroom`** |
| `AVAudioApplication.recordPermission` / `requestRecordPermission` | iOS 17+ (current API) | Used. The older `AVAudioSession.recordPermission` path is avoided. |
| CoreHaptics, CoreMotion, MetalKit, QuartzCore | No `27.0` deprecations found by header grep | n/a |

---

## 6. (d) Sensors: `MicListener` and `MotionSource`

### `MicListener` (`Sensors/MicListener.swift`)
- **State**: `enum State: Equatable { case off, starting, on, denied, failed }`. Changes are reported through a `(State) -> Void` callback that the model stores in an observed `micState`.
- **Permission flow** (`start(_:)`):
  ```swift
  switch AVAudioApplication.shared.recordPermission {
  case .granted: begin(changed)
  case .denied:  state = .denied; changed(.denied)
  default:       state = .starting; changed(.starting)
                 AVAudioApplication.requestRecordPermission { granted in DispatchQueue.main.async { granted ? begin : .denied } }
  }
  ```
  - The Info.plist string is "Gyre listens to draw an oscilloscope … Nothing is recorded or kept."
  - The UI has no "Open Settings" deep link; the button just reads "Mic access is off in Settings" and is disabled. Orbitals does have a Settings recovery action for camera, so Spectra should add one.
- **Capture** (`begin`):
  1. Set `AudioRoute.recording = true; AudioRoute.apply()`.
  2. Read `engine.inputNode.outputFormat(forBus: 0)` and guard `sampleRate > 0 && channelCount > 0`. That guard is the Simulator/no-input failure path and leads to `.failed`.
  3. Call `removeTap(onBus: 0)`, then `installTap(onBus: 0, bufferSize: 512, format: format)`.
  4. The tap locks `NSLock` and runs `write()` on channel 0.
  5. Call `try engine.start()`.
  - Note: the header says the tap's "Supported range is [100, 400] ms", so the 512-frame request (about 10.7 ms at 48 kHz) may be rounded up by the system. Per-buffer level/onset granularity on a real device is **unverified**; the README lists the real mic as "needs hands-on testing".
- **Ring buffer**: `[Float](repeating: 0, count: 16384)` with a power-of-two mask (`(head + 1) & mask`). It is constantly overwritten; nothing is persisted, which is a privacy promise made in the UI copy. `stop()` zeroes it.
- **Features per tap buffer**:
  - `level` = RMS.
  - `bass` = RMS of a one-pole low-pass at 150 Hz (`a = 1 − exp(−2π·150/fs)`).
  - **Onset**: fires when `rms > average·1.9 + 0.004`, more than 0.12 s since the last one, and `clock > quietUntil`. Strength = `min(rms / max(average, 0.002), 12)`. `average` is a one-pole with τ 0.25 s.
- **`snapshot(count:dt:) -> MicSnapshot { samples, level, bass, onset }`** copies the latest N samples oldest-first under the lock and consumes the pending onset. The model calls it once per frame with `count: 2048`.
- **Scope processing** (in `GyroModel.updateScope`). This is time-domain only.
  - **Trigger**: window 1024. Search backwards up to 900 samples for a rising zero crossing with hysteresis `0.02/gain`, so steady tones stand still.
  - **Trace**: 192 points, `tanh(sample·gain·5)` soft limit.
  - **Persistence**: keep 3 previous traces (alpha `0.3/(age+0.5)`).
  - **XY**: delay embedding with lag 48 samples (1 ms at 48 kHz), 300 pairs at stride 2.
- **Envelope** (`GyroModel.envelope`; sound "above the room's own background"):
  ```
  dB = 20·log10(level·gain); raw = clamp((dB + 55)/45, 0, 1)
  floor follows raw with τ = 0.4 s when falling, 20 s when rising
  above = max(0, raw − floor − 0.04) / max(1 − floor, 0.25)
  env attack 30 ms / release 350 ms toward min(above·1.5, 1)
  ```
- **No FFT exists in Gyre.** For Spectra's Fourier visualizer I verified the Accelerate Swift overlay in SDK 27 (`usr/lib/swift/Accelerate.swiftmodule/arm64e-apple-ios.swiftinterface`):
  - `vDSP.DiscreteFourierTransform<Float>(previous: nil, count: Int, direction: .forward, transformType: .complexReal, ofType: Float.self) throws` (iOS 15+). There is also `init(previousDFT:…)` (iOS 26+).
  - `.transform(inputReal:inputImaginary:outputReal:outputImaginary:)`
  - `vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized | .hanningDenormalized | .hamming | .blackman, count:, isHalfWindow:)`
  - `vDSP.squareMagnitudes(_ splitComplex: DSPSplitComplex, result:)`
  - `vDSP.convert(power:toDecibels:zeroReference:)` and `vDSP.convert(amplitude:toDecibels:zeroReference:)`
  - The older `vDSP.FFT` / `makeFFTSetup(log2n:radix:)` also exists.
  - Feed it from the same 16k ring via `snapshot(count: 4096…)`.
- **Fake room** (`-fakeMic`): `synthesize(dt)` writes 48 kHz samples. The signal is a G-major chord (196 + 0.6·294 + 0.25·392 Hz) at amplitude 0.22, swelling at 0.18 Hz, plus a 50 ms white-noise clap every 1.6 s decaying `exp(−70t)` at 0.7. It is capped at 4096 samples per frame and goes through the same `write()`, so level, onset and scope behave identically. **This is a good FFT test signal too**: three known peaks plus broadband transients.

### `MotionSource` (`Sensors/MotionSource.swift`)
- **Device motion**:
  ```swift
  manager.deviceMotionUpdateInterval = 1.0 / 120.0
  manager.showsDeviceMovementDisplay = false
  let frame = CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical)
            ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical   // magnetometer-corrected yaw stops drift
  manager.startDeviceMotionUpdates(using: frame)                     // PULL mode: no queue/handler
  ```
  `sample(dt:)` reads `manager.deviceMotion` once per render frame. Polling avoids a second clock and queue hops.
- **`MotionSample`** fields:
  - `attitude: simd_quatd` (phone → world, Z up)
  - `rotationRate` (rad/s, phone frame)
  - `gravity` and `userAcceleration` (g, phone frame)
  - `magneticField` (µT, **calibrated** `CMCalibratedMagneticField` from device motion)
  - `fieldCalibrated` (`accuracy != .uncalibrated`)
- **Quaternion sanity check**: once `|gravity| > 0.5`, it compares `q⁻¹·(0,0,−1)` and `q·(0,0,−1)` against measured gravity. If they differ by more than 0.3 it latches `invertAttitude`, which guards against the CMQuaternion convention ambiguity.
- **Barometer**:
  - `CMAltimeter.isRelativeAltitudeAvailable()`
  - `altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in pressureKPa = data.pressure.doubleValue }` (kPa)
  - It is opt-in through the "Live air pressure" toggle. `NSMotionUsageDescription` explains it.
  - The air-density factor is `pressureKPa / 101.325`.
  - `startAbsoluteAltitudeUpdates(to:withHandler:)` exists (iOS 15+) but is unused.
- **Not used by Gyre** (available for Spectra):
  - raw `startMagnetometerUpdates()` / `magnetometerUpdateInterval` (uncalibrated, includes hard-iron bias; CMMotionManager.h:241/274)
  - heading via CoreLocation
  - any radio API
  - The magnetometer's real bandwidth at the requested 120 Hz is **unverified**. Do not promise 50/60 Hz mains detection without measuring it.
- **Simulator** (`!manager.isDeviceMotionAvailable` gives `isLive = false`):
  - The pose comes from `simYaw/simPitch/simRoll`. Default pitch is 60° (the phone held upright, leaning back 30°).
  - `-simSway` adds `yaw += 0.9 sin(0.31t)`, `pitch += 0.3 sin(0.23t+1)` and `roll += 0.25 sin(0.17t)`.
  - The simulated field is `V3(0, 22, −40)` µT (northern-hemisphere-like).
  - `rotationRate` is derived from the frame-to-frame quaternion delta.
  - Dragging outside the bubble tilts the phone at 0.008 rad/pt (`GyroModel.touchChanged`); pitch is clamped to −0.2…π−0.2.

---

## 7. (e) `ARController` (`Sensors/ARController.swift`)

- `@Observable final class ARController: NSObject, ARSessionDelegate, ARCoachingOverlayViewDelegate`.
- `Phase: Equatable { off, starting, tracking, limited(String), denied, unsupported, failed(String) }`. `message` gives the banner copy per phase.
- **Configuration**: `ARWorldTrackingConfiguration` with `planeDetection = [.horizontal, .vertical]`, `worldAlignment = .gravity`, **`environmentTexturing = .automatic`** (so the metal reflects the room) and `isLightEstimationEnabled = false`. It runs with `[.resetTracking, .removeExistingAnchors]`. `session.delegateQueue = .main`.
- **Permission**: `AVCaptureDevice.authorizationStatus(for: .video)` set to `.denied`/`.restricted` gives `.denied`. Otherwise ARKit prompts. `ARError.cameraUnauthorized` in `didFailWithError` also maps to `.denied`.
- **Carry vs place**:
  - Carried, the bubble rides `carryOffset = (0, −0.015, −0.45)` m in camera space, so it floats 45 cm ahead. The physics then adds the lever-arm acceleration `ω̇ × r + ω × (ω × r)`, with ω̇ low-passed at τ 50 ms (in `GyroModel.advance`).
  - `place(at:viewSize:bubbleCenter:)`:
    1. Map the view point to image coordinates through `frame.displayTransform(for: .portrait, viewportSize:).inverted()`.
    2. Raycast: `frame.raycastQuery(from:allowing: .estimatedPlane, alignment: .any)`, then `session.raycast(query).first`.
    3. Accept hits within 4 m and keep the surface normal.
    4. Add `ARAnchor(name: "Gyre bubble", transform:)`.
    5. The bubble sits on the surface, lifted by `normal · radius · scale · 1.12`.
  - With no hit, the bubble floats in mid-air. `pickUp()` removes the anchor. Pinch scales the bubble ×0.4…8.
  - Transitions ease for 0.6 s (`k = 1 − exp(−dt/0.09)`, lerp + slerp).
- **Per-frame `frameState(...) -> ARFrameState`**:
  - `cameraToWorld = inverse(camera.viewMatrix(for: .portrait))` and `projection = camera.projectionMatrix(for: .portrait, viewportSize:, zNear: 0.005, zFar: 100)`.
  - The nearest `AREnvironmentProbeAnchor` that has a texture supplies `environmentTexture`.
  - **Camera YCbCr to Metal with zero copy**: `CVMetalTextureCacheCreate` + `CVMetalTextureCacheCreateTextureFromImage`, plane 0 as `.r8Unorm` and plane 1 as `.rg8Unorm`. The `CVMetalTexture` refs ride in `keepAlive` until the command buffer completes (`cmd.addCompletedHandler { _ = keepAlive }`).
  - The shader decodes with BT.601 coefficients and `pow(2.2)`.
- **Frames**: the AR world is Y-up and the physics world is Z-up, so `simFromAR = simd_quatd(angle: .pi/2, axis: (1,0,0))`. The renderer detects reversed-Z from the projection each frame and swaps its depth states.
- **Lifecycle**:
  - `resume()` re-runs the configuration after backgrounding.
  - Interruptions map to `.limited("The camera was interrupted.")`, then back to `.starting`.
  - `sessionShouldAttemptRelocalization` returns `true`.
  - Tracking reasons are mapped to friendly sentences ("Slow down a little…", "Point at something with more texture or light.").
- **Frame rate**: AR forces `preferredFramesPerSecond = 60`, because ARKit camera frames arrive at 60 Hz.

---

## 8. (f) Simulator fake-sensor launch arguments

| Arg | Read at | Effect |
|---|---|---|
| `-simSway` | `MotionSource.simSway = ProcessInfo.processInfo.arguments.contains("-simSway")` (property initializer) | The simulated phone sways (section 6) |
| `-fakeMic` | `MicListener.fake` (`let`, initializer) | `start()` jumps straight to `.on` with no permission or engine. `snapshot()` calls `synthesize(dt)` first. `stop()` skips engine teardown. |
| `-fakeAR` | `ARController.simulated = !ARWorldTrackingConfiguration.isSupported && args.contains("-fakeAR")` | **Ignored on real devices** (gated on world tracking being unsupported). `start()` goes straight to `.tracking`. `frameState` returns `fakeFrame(...)`: a camera from the simulated attitude, a 62° vertical FOV hand-built projection (near 0.005, far 100), and a procedural 256×512 YCbCr "room" (gradient plus a 32 px checker floor below 60% height). Placed bubbles are orbited at 0.55 m. The coaching overlay is skipped (`!model.ar.simulated`). |
| `-startMic` | `GyroModel.start()` on the first start only: `if args.contains("-startMic") { toggleMic() }` | Mic on at launch |
| `-startAR` | the same place: `ar.start()` | AR at launch |

Launch example (simctl syntax verified with `xcrun simctl help launch`):
`xcrun simctl launch booted com.utkarsh.gyre -fakeMic -startMic -fakeAR -startAR -simSway`

**Pattern for Spectra**:
- Every live source exposes `isLive`/`simulated` plus a deterministic synthetic generator that feeds the **same downstream code path**: write into the same ring, produce the same snapshot type.
- The UI shows an explicit "Simulated" flag (the orange caption in `TelemetryCard`).
- Add equivalents such as `-fakeRF` (synthetic RSSI/BLE/Wi-Fi scan), `-fakeMag` (a magnet approaching) and `-fakeGNSS`.

---

## 9. (g) Metal `HoloRenderer` pipeline

**View** (`HoloView: UIViewRepresentable`):
```swift
let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
view.colorPixelFormat = .rgba16Float; view.framebufferOnly = true
view.preferredFramesPerSecond = isLowPowerModeEnabled ? 60 : 120   // 60 also in AR (updateUIView)
view.isOpaque = true; view.backgroundColor = .black
view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
(view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
```
Info.plist sets `CADisableMinimumFrameDurationOnPhone = true`, which ProMotion needs for 120 Hz.

**Resources**
- Scene target is `.rgba16Float` and depth is `.depth32Float`. Bloom targets are half and quarter resolution, all `.private`.
- The glass orb (v3) adds a mipmapped `behind` copy of the scene via a blit and `generateMipmaps`.
- **Triple buffering**: `DispatchSemaphore(value: 3)` plus 3 `lineBuffers` (`.storageModeShared`). Buffers grow to 2× the needed size and are signalled from `addCompletedHandler`.
- Pipelines are built by a local `pipeline(vertex, fragment, format:, blend: .none | .add | .alpha, depth:)`:
  - `.add` is one/one for RGB, with alpha zero/one.
  - `.alpha` is premultiplied-style srcAlpha / 1−srcAlpha.
- Bubble geometry: a UV sphere, 48 stacks × 96 slices. Its winding is self-checked and flipped if it faces inward.

**Pass order per frame**
1. **Scene** (clear to alpha 1 in phone mode, alpha 0 in AR so the camera can show through):
   1. Background fullscreen triangle: world-anchored sky with a 15° lat/long grid, glowing horizon and a north tick (`sky()`; uses `fwidth` anti-aliasing). The phone reads as a window.
   2. Bubble **lens**: back-face cull, alpha blend. Rim refraction `refract(-V, n, 1/1.45)` of the sky, or of the camera image in AR.
   3. Solid meshes (GGX metal, planet, top) with depth write.
   4. Bubble far wall (front-cull, additive thin-film interference).
   5. **Hologram lines** (instanced).
   6. Bubble near wall (back-cull, additive).
2. **Bloom**:
   - `prefilter` soft threshold: `c · smoothstep(0.35, 1.3, max(r,g,b))` into halfA.
   - Separable blur H then V at half resolution, step 1.4 texels.
   - `copy` into quarterA, then blur H/V at step 2.2 texels.
   - The blur is a 5-tap linear-sampled Gaussian: weights 0.2270270270 / 0.3162162162 / 0.0702702703 at offsets 0, ±1.3846153846, ±3.2307692308.
3. **Composite** into the drawable:
   - Chromatic aberration: R and B sampled at `uv ± (uv − bubbleCentre)·0.0022`.
   - Add `bloomHalf·0.6 + bloomQuarter·0.54`.
   - Scanlines: `1 − 0.04·(0.5 + 0.5·sin(y·2.0944 + 4t))`, a 3 px period. Off with Reduce Motion.
   - In AR, add camera RGB weighted by `(1 − sceneAlpha)`.
   - Then `softClip` each channel into EDR:
   ```metal
   static inline float softClip(float x, float headroom) {
       float k = 0.8; float h = max(headroom, 1.0);
       if (x <= k) return x;
       return k + (h - k) * (1.0 - exp(-(x - k) / (h - k)));
   }
   // headroom = min(uniforms.camera.w, 3.0) where camera.w = view.window?.windowScene?.screen.currentEDRHeadroom
   ```
   Highlights roll off smoothly up to 3× SDR white on XDR panels, so "the hologram glows brighter than white". On SDR, `headroom = 1` gives a soft knee at 0.8.

**Instanced glowing line segments** (the core primitive Spectra should reuse for waves, field lines, antenna patterns and node-graph wires):
- **CPU side** (`HoloSceneBuilder`, `HoloScene.swift`):
  - `LineInstance { a, b, ca, cb: F4 }`, 64 bytes. `a/b.xyz` is the bubble-frame position and `.w` the width in **pixels**. `ca/cb.rgb` is colour × intensity and `.a` is alpha.
  - Primitives: `seg`, `point` (a zero-length seg is a round dot), `ring` (arc or circle, optional dashes), `arrow` (shaft plus two head strokes facing the viewer) and `markers` (motion-blur arcs over the angle swept this frame).
  - Width = `w · pxScale · view.widthScale · (0.75 + 0.25·smoothstep(−1, 1, p·toEye))`. Nearer lines are thicker.
  - Depth cue / scan band: `cue(p) = 0.72 · (0.35 + 0.65·smoothstep(−1.1, 1, p·toEye)) · (1 + 0.9·exp(−((p.y − bandY)/0.07)²)) · flicker`.
    - The band sweeps every 4.2 s: `bandY = −1.4 + 2.8·fract(t/4.2)`.
    - Flicker = `1 + 0.025·sin(47t)·sin(13.3t)`.
    - Reduce Motion disables both (bandY = 9, flicker = 1).
- **GPU side** (`lineVertex`/`lineFragment`; draw with `.triangleStrip`, 4 vertices × `instanceCount`, `baseInstance` for sub-ranges):
  - Endpoints are nudged 0.015 toward the eye so lines on metal surfaces are not hidden.
  - Endpoints are projected to pixels. The quad half-width is `w/2 + 2.2·w + 2` px, leaving room for the glow.
  - **Butt caps**: `cap = len > 1.5 px ? 0 : half` — *"Segments of a polyline butt together without caps, so additive joints don't double up into beads; a lone point gets a round dot."* With additive blending, round caps on every segment of a polyline would overlap at each joint and make bright beads. Butt caps keep a continuous polyline evenly bright.
  - Depth is interpolated between the endpoints. Segments behind the camera (`w < 0.01`) are culled by moving them off-screen.
  - Fragment: distance to the segment in pixels (perpendicular for real segments, radial for dots).
    - `core = 1 − smoothstep(w−0.6, w+0.9, d)`
    - `glow = 0.45·exp(−d²/g²)`, with `g = 2.2·w + 1.5`
    - Output is `float4(rgb·alpha·(core + glow), 0)`, additive with alpha 0, so lines never occlude and stay EDR-capable.
- Compare Orbitals' `PhosphorSegment`: a **2D** analytic capsule (radius, glow, dash period, dash offset, hollow radius, endpoint RGB gradient) in screen points. Gyre's segment is **3D, view-projected, butt-capped, with depth test (no write)**.

**Other shader techniques worth knowing**
- Thin-film interference: 420 nm base thickness, draining toward measured gravity, fbm swirl, sloshing with the wobble quadrupole and shivering with sound. RGB reflectance is at 640/530/450 nm with n = 1.33.
- GGX/Smith/Schlick metal with anisotropic circular brushing and an anodised-oxide rainbow.
- IBL from either a procedural "holographic studio" fixed in the world or ARKit's environment probe cube map (`level(rough·7)`).
- Ripples: up to 4, as a `float4 ripples[4]` uniform array (direction, age).

---

## 10. (h) Build tooling and physics harness

**`project.yml`** (XcodeGen):
- Name `Gyre`, `bundleIdPrefix: com.utkarsh`, deployment `iOS: "27.0"`, `xcodeVersion: "27.0"`.
- `SWIFT_VERSION: "5.0"`; Orbitals uses `"6.0"`.
- `DEVELOPMENT_TEAM: YOUR_TEAM_ID`, Automatic signing.
- `PRODUCT_BUNDLE_IDENTIFIER: com.utkarsh.gyre`, `TARGETED_DEVICE_FAMILY: "1"`, `MTL_FAST_MATH: YES`, `SUPPORTS_MACCATALYST: NO`.
- `info.properties`: usage strings (Motion, Camera, Microphone), `UILaunchScreen.UIColorName: LaunchBackground`, single scene, portrait only, `UIUserInterfaceStyle: Dark`, `UIStatusBarHidden: true`, `CADisableMinimumFrameDurationOnPhone: true`, `ITSAppUsesNonExemptEncryption: false`, category entertainment.

**`Tools/build.sh`** (zsh, `set -e`):
```zsh
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${GYRE_BUILD_DIR:-${TMPDIR:-/tmp}/GyreBuild}"
rsync -a --delete --exclude 'Gyre.xcodeproj/xcuserdata' "$SRC/" "$WORK/src/"
cd "$WORK/src"; xcodegen generate --quiet
sim:    xcodebuild -project Gyre.xcodeproj -scheme Gyre -configuration Debug \
          -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath "$WORK/dd" build
device: xcodebuild -project Gyre.xcodeproj -scheme Gyre -configuration Release \
          -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath "$WORK/dd" build
```
- Why the mirror: `xcodebuild` hangs when it loads a project from the iCloud-synced `~/Documents/AI Stuff`.
- Install on the phone: `xcrun devicectl device install app --device <id> "$TMPDIR/GyreBuild/dd/Build/Products/Release-iphoneos/Gyre.app"`.
- Tools present here: `/opt/homebrew/bin/xcodegen`; `xcode-select -p` gives `/Applications/Xcode-beta.app/Contents/Developer` (Xcode 27.0, 27A5194q).
- **Gotcha found:** the checked-in `Gyre/Info.plist` lacks `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`, although `project.yml` declares them. `xcodegen` regenerates the plist only inside the mirror, and rsync is one-way. Opening `Gyre.xcodeproj` in Xcode without first running `xcodegen generate` in the source folder would ship a binary that is killed by TCC on mic or camera access. **For Spectra:** run `xcodegen generate` in the source tree whenever `project.yml` changes, or keep the plist keys in a static file.

**`Tools/physcheck`**:
- `run.sh` runs `xcrun swiftc -O -o "$TMPDIR/gyre-physcheck" Gyre/Physics/MathUtil.swift Gyre/Physics/GyroSim.swift Tools/physcheck/main.swift`, then executes it.
- `main.swift` prints PASS/FAIL lines and calls `exit(failures == 0 ? 0 : 1)`.
- The physics layer is UI-free: no SwiftUI or Metal, just `simd` and `Foundation`. That is what makes this possible.

I re-ran it into my scratchpad (it compiled in about 2 s):
```
PASS  steady precession — measured 1.2201 rad/s, theory 1.2192 (err 0.08%), period 5.15 s
PASS  free gyro holds its axis — drift 0.00000° over 10 s of tumbling
PASS  energy conservation — max relative drift 1.86e-05 over 20 s
PASS  sleeping-top threshold — critical 421 rpm: sleeps at 1.25× = true, at 0.8× = false
PASS  Larmor precession — measured -0.2652 rad/s, theory -0.2653
PASS  skater effect — spin 2000 rpm after doubling inertia from 4000
PASS  wind-down — fell after 67 s
PASS  step cost — 0.023 ms per frame at 12000 rpm
All physics checks passed.
```
**For Spectra**, create `Tools/rfcheck` the same way. Pure-Swift checks against closed-form theory:
- free-space path loss = 20·log10(4πd/λ)
- dipole resonant length ≈ 0.47 λ
- array factor nulls
- FFT bin of a known tone, and Parseval's energy identity
- Planck peak (Wien's law, b = 2.897771955e−3 m·K)
- λ = c/f round-trips

**Physics substepping idea worth copying**: `n = clamp(ceil(dt·fastestRate/0.1), 1, 2000)` RK4 substeps per frame, where the fastest rate is the maximum over all active timescales. This keeps the step stable at any knob setting.

---

## 11. (i) Gyre vs Orbitals, and how to merge them for Spectra

| Aspect | **Gyre** (Liquid Glass hologram) | **Orbitals** (phosphor instrument) |
|---|---|---|
| Canvas | Full-bleed 3D Metal scene; UI floats over it | Plots inside `InstrumentPanel` cards (`OrbitTheme.panel` (0.065, 0.095, 0.083), radius 26, 0.07 white hairline) on a near-black green background (0.025, 0.045, 0.04) |
| Chrome | Liquid Glass everywhere: `GlassEffectContainer`, `.glassEffect(... .interactive())`, `.glass` / `.glassProminent`, `glassEffectID` morphing | Also glass buttons and knobs, but within opaque phosphor panels; `.pickerStyle(.segmented)`; sheets ("Flight controls") |
| Type | SF Pro + `.monospacedDigit()`; uppercase tracked micro-labels | `design: .monospaced` everywhere for readouts ("01 MOTION CONTROL", "RUN"/"HOLD"); serif Greek symbols on dials (κ, α, ν, φ) |
| Palette | Cool holographic cyan, violet and magenta; per-knob hues; iridescent film | CRT phosphor green (0.4, 0.96, 0.56), amber (1, 0.75, 0.37), CMY channels; per-dial accents |
| Knob | 60 pt glass puck in an 84 pt frame; 270° arc; labelled physical detents; rotary switches; floating readout card; 230 pt travel | 70 pt puck (glass tint 0.22) inside 104 pt with a tick ring (index/30 steps); title + descriptor above; **linear slider under every dial**; keyboard arrows (`onKeyPress`) and `@FocusState` |
| Lines | 3D instanced segments, butt caps, depth-tested, bloom + EDR soft-clip | 2D analytic capsules with dashes, CMY endpoint gradients and hollow particles |
| Haptics | Continuous looping hum + transients + crackle; `Haptics` per model | Short causal pulses only ("Nothing runs continuously"); `@MainActor` singleton; UIKit feedback generators + CHHaptic; **user strength slider (0.85 default)**; stops on `didEnterBackgroundNotification` |
| Audio | Live synth + mic | None |
| Concurrency | Swift 5 mode; plain `final class`es shared with audio threads | Swift 6 mode; `@MainActor` services |
| Tests | Mac physics harness (`physcheck`) | XCTest unit + UI tests (CoreTests, ARPlacementMathTests, …) |
| Devices | iPhone only, portrait | iPhone + iPad, landscape too |

**Merge proposal: "glass over phosphor".** Spectra is both an instrument (spectrum tuner, decompose, spectroscopy, which suit Orbitals) and a living field (antennas radiating, a room full of RF, which suits Gyre).
1. **One renderer, two primitives.**
   - Adopt Gyre's `HoloRenderer` skeleton: rgba16Float scene, bloom ½+¼, `softClip` into EDR, triple buffering.
   - Use Gyre's `LineInstance` (3D, butt caps) for field lines, wavefronts, radiation patterns, antenna geometry and node-graph wires.
   - Add Orbitals' 2D capsule (dashes, gradients) for Fourier bars, scope traces and spectra. An orthographic `viewProj` in the same pipeline can draw 2D plots.
   - One bloom chain gives everything the same glow.
2. **Chrome: Gyre's Liquid Glass. Readouts: Orbitals' monospaced phosphor.**
   - Use `GlassEffectContainer` toolbars, glass knob decks, `.tabs` page pickers and `KnobReadout` cards.
   - Inside cards, write numbers (frequency, λ, dBm, µT) in `design: .monospaced` with phosphor/amber semantic colours.
   - Keep Orbitals' serif-italic symbols (f, λ, ν, φ, B, E) for physical quantities. Gyre already does this in the InfoSheet legend.
3. **Knob: Gyre mechanics + Orbitals accessibility.**
   - From Gyre: `KnobSpec` data model (log mapping, bipolar origin, labelled detents, rotary switch), detent and tick haptics, the readout card, double-tap reset.
   - From Orbitals: `onKeyPress` arrows, `@FocusState`, `@ScaledMetric` descriptor height, optional linear slider for precision.
4. **Haptics: merge into one `@MainActor` service.**
   - Keep Gyre's continuous hum API (`updateHum`) for live signal strength (RSSI, field magnitude, audio level).
   - Keep Gyre's transients and crackle.
   - Add Orbitals' global `strength` multiplier, admission throttling and background stop.
5. **Colour**: hue encodes frequency. Spectra can make the per-knob tint an actual function of the band, from radio (deep red/infrared, rendered as warm hues) through visible (true spectral colour) to UV/X/γ (violet-white). Gyre's per-knob-tint convention extends to "tint = band colour".
6. **Layout**:
   - Gyre's "layout drives the Metal camera" (`onGeometryChange` → eased centre/radius) lets the hero scene swell when the console folds.
   - Orbitals' full-screen popout and focal-anchored pinch/pan/rotate gestures suit 2D plots.
   - Support iPhone portrait first. The user's device is an iPhone 15 Pro Max on iOS 27.2.
7. **Language mode**: Orbitals is Swift 6. If Spectra adopts Swift 6, the Gyre audio and tap closures (`AVAudioSourceNode` render block, `installTap` block) run off the main actor and capture non-Sendable classes. Plan for `nonisolated` DSP types with explicit locking (Gyre's `NSLock` ring) and `@unchecked Sendable`, or keep the audio types in a Swift 5-mode module. This is an inference; Gyre itself sidesteps the problem with `SWIFT_VERSION 5.0`.

---

## 12. What Gyre gives Spectra for "simulation → live interaction"

| Spectra need | Gyre provides | Gap / to build |
|---|---|---|
| Fourier visualizer on live audio | Mic tap, 16k ring, lock, snapshot, triggered scope, XY, envelope, onsets, fake room | FFT (vDSP DFT, verified above), log-frequency binning, waterfall/spectrogram texture |
| EMF (magnetic) probe | Calibrated µT vector at 120 Hz requested, Geiger crackle, field arrow in world frame, north tick | Raw magnetometer option, baseline/zero, magnitude history plot |
| Orientation for antenna aiming / polarisation | World-frame attitude (`.xArbitraryCorrectedZVertical`), gravity, sky "window" shader | True-north heading (CoreLocation) if needed |
| Visible-light spectroscopy (camera) | ARKit capture → Metal YCbCr textures (zero copy) | AVCapture-based spectrum strip if ARKit is not wanted |
| Air / atmosphere (attenuation) | Barometer kPa | n/a |
| RF / antennas (Wi-Fi, BLE, cellular, GNSS, UWB) | **Nothing**: no radio APIs in Gyre | Entirely new; verify each API's iOS 27 availability and entitlements separately |
| AR placement of radiating antennas | Carry/place/pinch, environment probes, coaching, banner | Same, reusable |

---

## 13. Directly reusable files (copy nearly verbatim)

Rename `Gyro*` to `Spectra*`, and point keyPaths at the Spectra model.

1. `Gyre/UI/GlassKnob.swift`: `GlassKnob` + `KnobArc`. The only coupling is `KnobSpec` and `Haptics`.
2. `Gyre/Model/Knobs.swift`: **the `KnobSpec` / `KnobDetent` struct and its mapping methods** (`position(of:)`, `value(at:)`, `detent(at:)`, `isSwitch`, `label(_:)`). Replace the knob tables and change `ReferenceWritableKeyPath<GyroModel, Double>` to the Spectra model.
3. `Gyre/UI/Console.swift`: `KnobReadout`, `LevelMeter`, `ObjectTile`, and the `controls` row pattern (`glassEffectID` morphing).
4. `Gyre/Feedback/Haptics.swift`: whole file (engine lifecycle, looping hum player, 40 Hz parameter throttle, transients, `spinUp` curve pattern).
5. `Gyre/Sensors/MicListener.swift`: whole file, including `AudioRoute`, the ring buffer, the permission flow and `-fakeMic`. Add an FFT consumer on top of `snapshot(count:dt:)`.
6. `Gyre/Sensors/MotionSource.swift`: whole file (`MotionSample`, quaternion convention check, barometer, Simulator pose and `-simSway`).
7. `Gyre/Physics/MathUtil.swift`: whole file (`V3`/`F3`/`F4`, `clamped`, `smoothstep`, `perpendicular`, `wrapAngle`, quaternion casts).
8. `Gyre/UI/ARViews.swift`: `CoachingOverlay` + `ARBanner` verbatim.
9. `Gyre/Render/Holo.metal`, selected functions only: `fullscreenVertex`, `lineVertex`, `lineFragment`, `prefilterFragment`, `copyFragment`, `blurFragment`, `softClip`, `cameraColor`, `lineMask`, and `sky()` if a world-anchored "window" backdrop is wanted.
10. `Gyre/Render/GyroMeshes.swift`: the `Builder` (grid, cap, torus, cylinder, sphere, lathe, annulus, auto-orient, `upload`) and the `simd_float4x4(translation:/scale:/basis:origin:)` extensions. These are ideal for dipole, Yagi, patch and helix antenna meshes.
11. `Tools/build.sh` (change names and the `SPECTRA_BUILD_DIR` env var) and the `Tools/physcheck/run.sh` + `main.swift` harness shape (`check(name, ok, detail)`, exit code).
12. `project.yml` skeleton: deployment 27.0, team `YOUR_TEAM_ID`, dark/portrait/status-bar-hidden, `CADisableMinimumFrameDurationOnPhone`, `MTL_FAST_MATH`. Add `NSMicrophoneUsageDescription`, `NSCameraUsageDescription`, `NSMotionUsageDescription` plus any radio usage strings.

## 14. Adapt (keep the pattern, rewrite the content)

1. `Gyre/Render/HoloRenderer.swift`: keep the target set (rgba16Float + depth32Float + ½/¼ bloom), the triple-buffer semaphore, the `pipeline(...)` builder with blend modes, `phoneSetup` (layout-driven eased camera), `arSetup` (reversed-depth detection), `bindScene`/`drawLines(baseInstance:)`, and the composite. Replace the gyroscope, bubble and orb passes with Spectra scenes (antenna field, Fourier 2D plot through an ortho `viewProj`, node graph).
2. `Gyre/Render/HoloScene.swift`: keep `LineInstance`, `ViewBasis`, `seg`/`point`/`ring`/`arrow`/`markers`, width/cue/scan-band logic and the palette idea. Write new builders for wavefronts, E/B field vectors, radiation lobes, spectra and wires.
3. `Gyre/Model/GyroModel.swift`: keep the structure (observed UI state vs `@ObservationIgnored` engine state; `advance(dt:ar:)` called by the renderer; 10 Hz `Telemetry`; `start`/`stop`/launch args; `updateFeedback` mapping; envelope; scope; the `ignoreOnsets` guard). Rewrite the domain.
4. `Gyre/Feedback/HumSynth.swift`: keep the engine, `AVAudioSourceNode`, unlocked `Controls`, per-sample smoothing, xorshift noise, equal-power pan, config-change restart and `connectNode`. Change the voice to sonify RF (for example, beat-frequency heterodyne of a tuned carrier, AM/FM demodulation tones, or Geiger clicks). **Add** `AVAudioSessionDidBecomeInactiveNotification` / `AVAudioSessionResumptionRecommendationNotification` handling (iOS 27 replacement for interruptions).
5. `Gyre/Sensors/ARController.swift`: reusable mostly as is for placing a radiating antenna. Rename the anchor, retune `carryOffset`/sizes, and keep `-fakeAR`. If Spectra wants spectroscopy from the camera, it may need an AVCapture path instead of ARKit.
6. `Gyre/UI/TopBar.swift`: keep the `GlassEffectContainer` + capsule toolbar group + `Menu` sections + `TelemetryCard` (collapsed headline, tap for the sensor grid, simulated flag). Swap in Spectra's modes (Wave, Spectrum, Matter, Decompose, Spectroscopy, Antenna, Graph) and live readings (µT, dB SPL, kPa, RSSI).
7. `Gyre/UI/Console.swift` `KnobConsole`: keep the `.tabs` picker pages, the 4-wide `Grid` of knobs, the fold-to-expand console and the readout overlay. The pages become Spectra's instruments.
8. `Gyre/UI/InfoSheet.swift`: keep the `.medium/.large` detents with background interaction, Touch / What you're seeing / Knobs (auto-generated from `KnobSpec.detail`) / Sensors in play sections, and the serif-italic legend.
9. `Gyre/UI/ContentView.swift`: keep the ZStack layering, `bubbleRegion` → `onGeometryChange` → renderer, canvas accessibility actions, scenePhase start/stop and reduce-motion propagation.
10. `Gyre/Model/Knobs.swift` `Experiment`: keep the preset pattern (title, subtitle, SF Symbol, params, launched from a toolbar `Menu`). Content becomes "AM radio", "FM", "Wi-Fi", "5G mmWave", "Microwave oven leak", "Visible", "X-ray" and so on.
11. `Gyre/Physics/GyroSim.swift` / `BubbleWorld.swift`: domain-specific. Reuse only the adaptive RK4 substep rule, eased knob changes (`x += (target − x)·(1 − exp(−dt/τ))`) and the `TrailBuffer` ring.
12. `Holo.metal` mesh shading (`metalFragment` GGX + anisotropic brushing + oxide film, `environment()` IBL with AR probe fallback, thin-film `filmInterference`): adapt for antenna materials (copper, PCB, radome). Thin-film interference is itself an EM-spectrum demonstration worth reusing in the Matter bench.
