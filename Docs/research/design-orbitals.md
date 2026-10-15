# Orbitals: design system and UX logic (reference for Spectra)

Source: `/path/to/developer/Documents/AI Stuff/Orbitals` (git `385f88f Import Orbitals source`, version 1.0 build 7). I read every Swift and Metal file under `Orbitals/` (UI, Rendering, Services, AR, Core), the app entry, `Info.plist`, the asset catalog, `project.yml`, `README.md` and `VERIFICATION.md`, all 7 unit-test files and 3 UI-test files, and the screenshots in `Documentation/Screenshots/`. Every value below comes from source. Paths are relative to `Orbitals/Orbitals/` unless stated otherwise.

Do not copy `Orbitals 2.xcodeproj` or `Orbitals 3.xcodeproj`. They are stale duplicates and `.gitignore` excludes them. The live project is `Orbitals.xcodeproj`, generated from `project.yml`.

---

## 0. Toolchain and project shell

| Setting | Value |
|---|---|
| Generator | XcodeGen `project.yml` (`xcodegen generate`). The generated project is committed. |
| Xcode | 27.0 (build `27A5194q`) |
| Deployment target | iOS/iPadOS **27.0**; `TARGETED_DEVICE_FAMILY: "1,2"` |
| Swift | `SWIFT_VERSION: "6.0"`, app target `SWIFT_STRICT_CONCURRENCY: complete`. **No** `SWIFT_DEFAULT_ACTOR_ISOLATION`, so types are nonisolated by default and UI classes are annotated `@MainActor` explicitly. |
| Metal | `MTL_FAST_MATH: YES` |
| Signing | `DEVELOPMENT_TEAM: YOUR_TEAM_ID`, `CODE_SIGN_STYLE: Automatic`, `bundleIdPrefix: com.utkarsh`, `PRODUCT_BUNDLE_IDENTIFIER: com.utkarsh.orbitals` |
| Versioning | `MARKETING_VERSION: "1.0"`, `CURRENT_PROJECT_VERSION: "7"` (incremented on every device build) |
| Info.plist keys | `UIUserInterfaceStyle: Dark`, `CADisableMinimumFrameDurationOnPhone: true`, `UILaunchScreen.UIColorName: LaunchBackground`, `UIApplicationSupportsMultipleScenes: false`, `NSCameraUsageDescription`, `ITSAppUsesNonExemptEncryption: false`, `LSApplicationCategoryType: public.app-category.education`. Orientations: iPhone supports Portrait, LandscapeLeft and LandscapeRight; iPad supports all four. |
| Other build settings | `ENABLE_USER_SCRIPT_SANDBOXING: YES`, `SUPPORTS_MACCATALYST: NO`, `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor` |
| Dependencies | None. There is no SPM package, web view or network service. Frameworks: SwiftUI, UIKit, MetalKit, CoreHaptics, ARKit, RealityKit, AVFoundation, Observation, simd. |
| Test targets | `OrbitalsTests` (`bundle.unit-test`) and `OrbitalsUITests` (`bundle.ui-testing`), both `GENERATE_INFOPLIST_FILE: YES`. One scheme, `Orbitals`, builds and tests all three targets. |

Assets (`Resources/Assets.xcassets`):
- `AccentColor`: sRGB (0.4, 0.96, 0.56), which equals `OrbitTheme.phosphor`.
- `LaunchBackground`: sRGB (0.025, 0.045, 0.04), which equals `OrbitTheme.background`.
- `AppIcon`: a single 1024×1024 universal opaque RGB PNG (`Orbitals.png`). It was image-generated, and the prompt is kept in `Documentation/Icon/README.md`: phosphor-green Lissajous loop on smoked CRT glass, three accent nodes, no text. `make-icon.swift` is an earlier programmatic CoreGraphics icon generator (AppKit, `NSBitmapImageRep`, radial gradient, phosphor stroke with shadow blur 26).

App entry, `OrbitalsApp.swift`:

```swift
@main struct OrbitalsApp: App {
  @State private var model = OrbitModel()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      DashboardView(model: model)
        .preferredColorScheme(.dark)
        .tint(OrbitTheme.phosphor)
        .onChange(of: scenePhase) { _, phase in
          model.setActive(phase == .active)
          if phase != .active { OrbitalHaptics.shared.stop(); model.save() }
        }
    }
  }
}
```

---

## (a) Design tokens

### Colors: `UI/OrbitTheme.swift` (`enum OrbitTheme`)

All colors are `Color(red:green:blue:)` in sRGB, opacity 1.

| Token | RGB | Role |
|---|---|---|
| `background` | 0.025, 0.045, 0.04 | App and screen background (near-black green). Also the launch color. |
| `panel` | 0.065, 0.095, 0.083 | `InstrumentPanel` and `VisualizationPanel` fill |
| `phosphor` | 0.4, 0.96, 0.56 | Brand and global tint, panel numbers, toggles, "RUN", Field-note headings |
| `amber` | 1, 0.75, 0.37 | Default `Readout` value color, clock, "HOLD", harmonic/preset menu tint |
| `cyan` | 0.57, 0.89, 1 | Retcon accent and predicted-path legend (a pale cyan, different from the channel cyan) |
| `channelCyan` | 0.1, 0.93, 1 | Channel A |
| `magenta` | 1, 0.18, 0.78 | Channel B |
| `yellow` | 1, 0.91, 0.18 | Channel C; also the tint of the active Move-mode button |
| `muted` | 0.61, 0.71, 0.65 | Secondary text, captions, panel titles |
| `channels` | `[channelCyan, magenta, yellow]` | Indexed by channel 0/1/2 |
| `channelNames` | `["Cyan", "Magenta", "Yellow"]` | Used in accessibility labels and the "Editing A · Cyan" line |
| `dialSpeed` | 1, 0.69, 0.30 | κ Speed dial accent (amber) |
| `dialAmplitude` | 0.38, 0.70, 1 | α Amplitude dial accent (blue) |
| `dialFrequency` | 0.35, 0.94, 0.69 | ν Frequency dial accent (mint) |
| `dialPhase` | 0.78, 0.60, 1 | φ Phase dial accent (violet) |

Rule from the code comment: **"Control accents identify a parameter independently of the edited CMY channel."** Two color systems coexist:
- **Data identity**: each channel keeps its CMY color everywhere, including canvas traces, legend, coordinate tables and the motion-choice fill.
- **Parameter identity**: each dial keeps its accent permanently, whichever channel is being edited.

Metal-side colors are hard-coded `SIMD4<Float>` values in `SceneGeometry.swift` and the shader. They are not read from `OrbitTheme`:
- `green` (0.35, 0.83, 0.49): mesh, axes and grids
- `ghost` (0.55, 0.80, 0.91): retcon ghosts and the 4th axis
- `amber` (1, 0.75, 0.37): the torus "now" ring
- `white` (1, 1, 1): the cylinder present ring
- `channelColors`: CMY with the same values as `OrbitTheme.channels`
- `MTKView.backgroundColor`: `UIColor(0.025, 0.049, 0.041)`
- Shader background base: (0.022, 0.047, 0.038). The retcon variant is (0.027, 0.043, 0.066).
- Shader grid color: (0.075, 0.13, 0.092). The retcon variant is (0.065, 0.115, 0.16).

### Opacity tokens (inline literals, collected)

| Use | Value |
|---|---|
| Panel hairline stroke | `.white.opacity(0.07)` |
| Canvas frame stroke | `phosphor.opacity(0.2)` |
| Knob card fill / stroke idle / stroke dragging | `color.opacity(0.055)` / `0.22` / `0.58` |
| Knob arc track / lit tick / unlit tick | `0.16` / `0.8` / `0.22` |
| Knob glass tint / arc glow shadow / center dot | `0.22` / `0.28` (radius 4) / `0.75` |
| Knob inner ring | `.white.opacity(0.12)`, lineWidth 0.5 |
| Dial descriptor text | `.white.opacity(0.75)` |
| Intro subtitle | `.white.opacity(0.8)` |
| Field-notes body | `.white.opacity(0.85)` |
| Motion chip unselected fill / text | `.white.opacity(0.07)` / `.white.opacity(0.85)` |
| Motion chip stroke selected / unselected | `channel.opacity(0.8)` / `0.18` |
| Motion chip glass tint | `channel.opacity(0.12)` |
| Transport scrim gradient | `[.clear, background.opacity(0.96)]` top to bottom |
| Pinned reset-bar background | `background.opacity(0.96)` |
| Full-screen legend and hint capsules | `background.opacity(0.82)` |
| AR reticle (cannot place) | `.white.opacity(0.7)`; shadow `.black.opacity(0.7)` radius 4 |

### Typography

Orbitals uses system fonts only: no custom fonts and no fixed sizes, apart from two 9 pt canvas annotations. All text scales with Dynamic Type.

| Role | Font |
|---|---|
| Panel header (number plus title) | `.system(.caption, design: .monospaced).weight(.medium)`; title `.uppercased()`, `.tracking(2)` |
| Visualization title | `.system(.caption, design: .monospaced).weight(.semibold)`, uppercased, `.tracking(1.8)` |
| Eyebrow ("SPACE AGE ORBITAL DYNAMICS") | `.system(.caption2, design: .monospaced)`, `.tracking(2)`, muted, preceded by a 5×5 phosphor `Circle` |
| Readout title / value | `.system(.caption2, design: .monospaced)` muted, uppercased / `.system(.callout, design: .monospaced).weight(.medium)` + `.monospacedDigit()` + `.contentTransition(.numericText())` |
| Dial Greek symbol | `.system(.title3, design: .serif).weight(.semibold)` |
| Dial title | `.subheadline.weight(.semibold)` in the accent color |
| Dial descriptor | `.caption` |
| Dial reading | `.system(.title3, design: .monospaced).weight(.semibold)`, `.monospacedDigit()`, `.lineLimit(1)`, `.minimumScaleFactor(0.7)` |
| Slider title / reading | `.subheadline` / `.system(.subheadline, design: .monospaced).weight(.medium)` |
| Buttons | `.subheadline.weight(.semibold)`; view tabs and menus use `.subheadline.weight(.medium)` |
| Explanatory captions | `.caption`, `OrbitTheme.muted` (under nearly every control group) |
| Clock | `RUN`/`HOLD` `.system(.caption2, design: .monospaced)`; time `.system(.caption, design: .monospaced).monospacedDigit()` |
| Canvas annotations | `.system(size: 9, weight: .medium, design: .monospaced)`; hint `.system(size: 9, design: .monospaced).tracking(0.6)` |
| Legends and coordinate tables | `.system(.caption2 / .caption, design: .monospaced)` |
| Field-notes headline | `.title3.weight(.medium)` |

Number formatting: `value.formatted(.number.precision(.fractionLength(min(6, max(0, precision)))))`, followed by `" " + unit` when there is a unit. Coordinates use `String(format: "%+.2f")`, distances `"%.3f u"`, the clock `"%02d:%02d.%02d"`, and revisions `"REV %03d"`.

Copy style: sentence case for titles; UPPERCASE monospaced for instrument labels; " · " (spaced middle dot) as the universal separator ("Editing A · Cyan", "κ · Speed", "Drag to move · Pinch to zoom"); Unicode arrows in labels ("Circle → sphere", "4D → 3D → 2D", "A ↔ B").

### Radii

| Element | Corner radius |
|---|---|
| `VisualizationPanel` background | 28 |
| `InstrumentPanel` background and stroke | 26 |
| AR instruction card (`glassEffect` rect) | 22 |
| Knob card; embedded canvas clip and stroke | 20 |
| Motion-choice chips | 14 |
| Buttons | `.buttonBorderShape(.capsule)` (ActionButton) or system glass capsule |

### Spacing and padding

| Element | Value |
|---|---|
| Dashboard scroll content | `VStack(spacing: 22)`; horizontal padding **16** (compact) or **26** (width > 850); `.padding(.top, 8)`, `.padding(.bottom, 20)`; `.frame(maxWidth: 1500)` centered |
| Primary column | `VStack(spacing: 18)` |
| Wide layout (width > 850) | `HStack(alignment: .top, spacing: 20)`: primary column width = `geometry.size.width * 0.60`; `ControlsView(embedded: true).frame(maxWidth: 400)` |
| Compact column width | `geometry.size.width - 32` |
| `InstrumentPanel` | `VStack(alignment: .leading, spacing: 18)`, header `HStack(spacing: 8)`, `.padding(20)` |
| `VisualizationPanel` | `VStack(spacing: 12)`, header `HStack(spacing: 10)`, `.padding(16)` |
| Canvas height (embedded) | `max(300, min(width * 0.91, 530))` |
| Canvas annotation inset | `.padding(14)` |
| Knob card | `VStack(spacing: 8)`, `.padding(.horizontal, 8)`, `.padding(.vertical, 14)`; dial 104×104; arcs 84×84; glass knob 70×70 |
| Dial grid | `LazyVGrid`, 2 flexible columns (1 at accessibility sizes), `spacing: 16`, inside `GlassEffectContainer(spacing: 16)` |
| Motion-choice grid | 3 columns `GridItem(.flexible(), spacing: 6)` (1 at accessibility sizes), row `spacing: 7` |
| Transport | `GlassEffectContainer(spacing: 10)` → `HStack(spacing: 10)`, `.padding(.horizontal, 16).padding(.vertical, 10)` |
| Full-screen overlay | `.padding(.horizontal, 16).padding(.vertical, 12)`; header `HStack(spacing: 12)`; bottom `VStack(spacing: 12)`; `.frame(maxWidth: 470)` |
| Sheet content | `.padding(16)`; pinned reset bar `.padding(12)` with `HStack(spacing: 12)` (`VStack(spacing: 10)` at accessibility sizes) |
| Minimum touch heights | Sliders and toggles `.frame(minHeight: 44)`; experiment `ellipsis` menu `frame(width: 44, height: 44)`; chips `minHeight: 44`; ActionButton label `minWidth: 24, minHeight: 32` + padding h4/v6; icon buttons `Image.frame(minWidth: 18, minHeight: 22)` with `.controlSize(.large)` |
| `@ScaledMetric` | dial descriptor min height `36.0` (relativeTo `.caption`); motion explanation min height `52.0` (relativeTo `.caption`) |

### Motion and animation tokens

- `.smooth(duration: 0.25)` for view selection and scroll-to-tab. `.smooth(duration: 0.2)` for ActionButton actions and motion-chip selection. `.smooth(duration: 0.14)` for knob grab feedback.
- Every animation is gated on `@Environment(\.accessibilityReduceMotion)`: `reduceMotion ? nil : .smooth(...)`. ActionButton additionally applies `.symbolEffectsRemoved(reduceMotion)` and `.transaction { if reduceMotion { $0.animation = nil } }`. The shader receives a reduce-motion flag in `appearance.y`, which is reserved and currently unused.
- `.contentTransition(.numericText())` on every live number; `.contentTransition(.symbolEffect(.replace))` on button icons (for the play/pause swap).

### Material (Liquid Glass) policy

The README follows the HIG: **glass belongs to navigation and controls only; plots stay dark and high contrast.** APIs used (all iOS 26+ SwiftUI, compiled against the iOS 27 SDK):
- `.buttonStyle(.glass)` and `.buttonStyle(.glassProminent)` (the primary action: Play, AR "Place here", "Open Settings").
- `GlassEffectContainer(spacing:)` wraps every cluster of glass controls: transport, view tabs, dial grid, reset bar, full-screen camera bar, AR header and actions.
- `.glassEffect(.regular.tint(color.opacity(0.22)).interactive(), in: .circle)` on knob caps.
- `.glassEffect(.regular.tint(channel.opacity(0.12)).interactive(), in: .rect(cornerRadius: 14))` on motion chips.
- `.glassEffect(.regular, in: .capsule)` on the full-screen title (outside 5D); `.glassEffect(.regular, in: .rect(cornerRadius: 22))` on the AR instruction card.
- Panels are **not** glass: they use a solid `OrbitTheme.panel` fill with a 7% white hairline.

---

## (b) Reusable components

### `InstrumentPanel<Content>` (`UI/OrbitTheme.swift`)

```swift
struct InstrumentPanel<Content: View>: View {
  let title: String; let number: String
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 8) {
        Text(number).foregroundStyle(OrbitTheme.phosphor)
        Text(title.uppercased()).tracking(2)
        Spacer(minLength: 0)
      }
      .font(.system(.caption, design: .monospaced).weight(.medium))
      .foregroundStyle(OrbitTheme.muted)
      content
    }
    .padding(20)
    .background(OrbitTheme.panel, in: .rect(cornerRadius: 26))
    .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.07)) }
  }
}
```

The "number" is an instrument-style index: `"01"`…`"07"`, or a symbolic code such as `"T"` (time projection) or `"XYZW"` (state vectors). Each panel ends with a muted `.caption` explanation sentence.

### `Readout` (`UI/OrbitTheme.swift`)

`Readout(title:value:color: = OrbitTheme.amber)`: a 5 pt `VStack` with an uppercased caption2 monospaced muted title over a callout monospaced medium value (`monospacedDigit`, `numericText`), combined into one accessibility element (`.accessibilityElement(children: .combine)`).

### `GlassKnob` (`UI/GlassControls.swift`): rotary dial plus linear fallback

API:
```swift
GlassKnob(title: String, symbol: String = "", symbolName: String = "", descriptor: String = "",
          value: Binding<Double>, range: ClosedRange<Double>, step: Double,
          unit: String = "", precision: Int = 2, color: Color = OrbitTheme.amber)
```

Construction, from top to bottom:
1. Header `HStack(alignment: .firstTextBaseline, spacing: 6)`: Greek `symbol` (serif title3 semibold, accent, `accessibilityHidden`) and `title`. This header is one accessibility element labelled `"\(title), \(symbolName)"` (for example "Speed, kappa").
2. Descriptor (caption, white 0.75, centered, `@ScaledMetric` min height 36).
3. The **dial** (104×104, `.contentShape(Circle())`):
   - A `Canvas` scale of **31 ticks** (index 0…30), angle `(-135 + index*9)°`, so 270° of sweep. Every 5th tick is major. Outer radius `size.width/2 - 2`; inner radius `outer - 7` for majors and `outer - 3` for minors. Line width 1.6 (major) or 1 (minor). A tick is lit (opacity 0.8) when `index/30 <= position`, otherwise 0.22.
   - Track arc: `Circle().trim(from: 0, to: 0.75)`, stroke `color.opacity(0.16)` width 2 round cap, `.rotationEffect(.degrees(135))`, 84×84.
   - Value arc: `trim(to: 0.75 * position)`, stroke `color` width 3, `.shadow(color: color.opacity(0.28), radius: 4)`.
   - Glass cap (70×70): white 0.12 hairline ring; a `Capsule` pointer 4×14 at `offset(y: -23)` rotated `-135 + 270*position` degrees; a 4×4 center dot; `.glassEffect(.regular.tint(color.opacity(0.22)).interactive(), in: .circle)`; `.scaleEffect(1.045)` while grabbed.
4. Big monospaced reading (`accessibilityHidden`, because the dial carries the value).
5. A native `Slider(value:in:step:onEditingChanged:)` tinted with the accent, `minHeight 44`, labelled `"\(title), linear control"`. This is the precise alternative to the dial.
6. Card: `color.opacity(0.055)` fill, radius 20, stroke 0.22, or 0.58 while dragging.

Interaction logic:
- `DragGesture(minimumDistance: 2)` with `@GestureState isDragging`. On the first change it captures `startingValue`, focuses the control and calls `OrbitalHaptics.shared.beginAdjustment()`. `movement = translation.width - translation.height` (dragging **up or right** increases the value), and `next = start + movement / 240 * (upper - lower)`, so **240 pt of drag sweeps the full range**.
- `.onChange(of: isDragging)` calls `finishAdjustment()` when dragging ends. This releases correctly even when a scroll view or system gesture cancels the drag (code comment). `.onDisappear` clears `startingValue`.
- Every write goes through `quantized(value, range:, step:)`, i.e. `lower + round((v - lower)/step)*step` clamped to the range (non-finite values become `lowerBound`). The write is skipped if the quantized value is unchanged, which gives **haptic detents only on real value changes**.
- Haptic on change: `voiceOverEnabled ? selection() : detent(normalized:)`.
- Keyboard: `.focusable()`, `.focused($hasKeyboardFocus)`, `.onKeyPress(.upArrow/.rightArrow)` → `nudge(+1)`, down/left → `nudge(-1)`. A nudge at a limit plays `boundary()`; otherwise it plays `selection()`.
- VoiceOver: `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(title)`, `.accessibilityValue(reading)`, `.accessibilityHint("\(descriptor) Swipe up or down to adjust. Drag the dial up or right to increase.")`, `.accessibilityAdjustableAction` → `nudge(±1)`.

Dials as configured in `MotionControls`:

| Dial | symbol | range | step | unit | precision | color | descriptor |
|---|---|---|---|---|---|---|---|
| Speed | κ (kappa) | 0…3 | 0.05 | × | 2 | `dialSpeed` | "Multiplies the base frequency." |
| Amplitude | α (alpha) | 0…1 | 0.01 | — | 2 | `dialAmplitude` | "Sets size, swing or depth." |
| Frequency | ν (nu) | 0.01…1 | 0.01 | Hz | 2 | `dialFrequency` | "Base cycles per second at 1×." |
| Phase | φ (phi) | 0…360 | 1 | ° | 0 | `dialPhase` | "Offsets angles within the motion." |

### `GlassSlider`, `GlassToggle` and `ActionButton` (`UI/GlassControls.swift`)

- `GlassSlider(title:value:range:step: = 0.01, unit: = "", precision: = 2, color: = amber)`: `ViewThatFits(in: .horizontal)` places the title and readout on one row (`Spacer(minLength: 12)`) and falls back to stacking them. The native `Slider` has a tactile binding (same quantize, then selection/detent haptic) and calls `beginAdjustment`/`endAdjustment` from `onEditingChanged`. Accessibility label is `title` and value is `reading`.
- `GlassToggle(title:isOn:symbol:)`: a native `Toggle` with `Label(title, systemImage:)` (`.symbolRenderingMode(.hierarchical)`), tint phosphor, `minHeight 44`, and a `selection()` haptic only on a real change.
- `ActionButton(title:symbol:prominent: = false, tint: = phosphor, action:)`: `.glassProminent` or `.glass`, capsule shape. It plays `OrbitalHaptics.shared.tap()` and then runs the action inside `withAnimation(.smooth(duration: 0.2))` unless Reduce Motion is on. The label `Text` is `lineLimit(1)` + `fixedSize(horizontal: true)`.
- Private helpers in the same file: `normalized(_:in:)`, `quantized(_:range:step:)` and `formatted(_:precision:unit:)`.

### Segmented controls and selectors

- **Dimension picker**: `Picker("Dimension")` `.pickerStyle(.segmented)` with tags 2/3/4/5 shown as "2D"/"3D"/"4D"/"5D". It uses a custom `Binding` whose setter plays `selection()` and then calls `model.setDimension`. Identifier `dimension-picker`.
- **Channel picker**: segmented A/B/C (`channel-picker`) next to a `GlassToggle("Link", symbol: "link")`. Below it, a status line shows either three CMY dots + "Editing all three channels" or one dot + "Editing A · Cyan" (caption monospaced muted).
- **Motion chips** replaced an earlier menu. The build-5 notes say a Menu hid which mode was active, so they switched to explicit selected-state buttons. Each chip is `.buttonStyle(.plain)` with a manual fill: the selected chip uses the channel color fill and `OrbitTheme.background` text; the others use white 0.07. All chips have glass, the `.isSelected` trait and the identifier `motion-choice-<Name>`. A **mode explanation** below the chips (`motion-mode-description`) changes with the mode and catches limiting cases: speed == 0 shows "Speed is zero. Raise κ to move; dashed paths still show the motion."; amplitude == 0 shows "Raise α…".
- **View tabs (5D only)**: a horizontal `ScrollView` + `ScrollViewReader` + `GlassEffectContainer(spacing: 12)` + `HStack(spacing: 10)` of `.glass` buttons. The selected tab is tinted phosphor and the others white. `proxy.scrollTo(selected, anchor: .center)` runs on appear and on change. `.scrollIndicators(.hidden)`. A neighbor tab clipped at the edge is an intentional scroll affordance.
- **Coordinate plane** (cylinder only): a menu-style `Picker` over `CoordinatePlane` XY/XZ/XW/YZ/YW/ZW.

### Transport bar (`DashboardView.transport`)

Attached with `.safeAreaInset(edge: .bottom, spacing: 0)` so it floats over the scroll content:
- Default layout: `[Play/Pause (prominent)] [Step] [⋯ menu] Spacer [ClockReadout]`.
- At accessibility type sizes it becomes `VStack(spacing: 6)` with the clock on top and an icon-only `HStack(spacing: 16)`.
- Play toggles `model.running`; the icon is `play.fill`/`pause.fill` and the label is "Play"/"Pause" (asserted by UI tests). Step calls `model.step()`, which **always pauses** and advances exactly 1/60 s.
- The `⋯` menu (`ellipsis`, 44×44, `.glass`, label "Experiment actions") contains Clear trails (`eraser`), Clear recorded history (`clock.badge.xmark`), a Divider, and Reset experiment (`arrow.counterclockwise`, `success()` haptic). The `Menu` gets a tap haptic via `.simultaneousGesture(TapGesture().onEnded { tap() })`, a pattern repeated on every Menu.
- `ClockReadout`: "RUN" (phosphor) or "HOLD" (amber) over `00:00.00` (amber), combined into one accessibility element labelled `"Simulation running|paused, <clock>"`.
- Scrim: `LinearGradient([.clear, background.opacity(0.96)])`, `.ignoresSafeArea(edges: .bottom)`.
- Keyboard: `.onKeyPress(.space)` toggles running on both the dashboard and full screen.

### Top bar and the persistent top-left Dials button

`NavigationStack` with `.navigationTitle("Orbitals")` and `.navigationBarTitleDisplayMode(.large)`.
- `ToolbarItem(placement: .topBarLeading)`: `Label("Dials", systemImage: "dial.medium").labelStyle(.titleAndIcon)`, accessibility label "Motion control", identifier `motion-controls-open`. It opens `sheet = .motion`. In the iOS 27 captures it renders as a glass circle showing only the icon.
- `ToolbarItemGroup(placement: .topBarTrailing)`: `info` ("Field notes" → `.notes`) and `slider.horizontal.3` ("All controls" → `.controls`). The two render together in one glass capsule.
- **The persistence rule**: the same Dials shortcut appears top-left on every surface. On the dashboard it lives in the toolbar, so it survives scrolling. On every full-screen view it is `fullscreen-motion-controls-open`, the first item of the header. In AR it is `ar-motion-controls`. All three open the same `InstrumentControlSheet(destination: .motion)`. UI tests assert `shortcut.frame.midX < app.frame.midX` after scrolling.

### Control sheets with pinned Reset buttons (`UI/InstrumentControlSheet.swift`)

```swift
enum DashboardSheet: String, Identifiable { case motion, controls, notes; var id: String { rawValue } }
```
- Presented with `.sheet(item: $sheet)` from the dashboard, full screen and AR. It wraps its own `NavigationStack` with an inline title: "Motion control", "Flight controls" or "Field notes". `ToolbarItem(placement: .confirmationAction) { Button("Done") }` plays the tap haptic and dismisses.
- `.presentationDetents([.medium, .large], selection: $detent)` with the default `.large`; `.presentationDragIndicator(.visible)`; `.background(OrbitTheme.background)`.
- Content: `.motion` shows `ScrollView { MotionControls }` (`motion-controls-scroll`), `.controls` shows `ScrollView { ControlsView(embedded: false) }` (`controls-scroll`), and `.notes` shows `FieldNotesView` (`field-notes-scroll`).
- **Pinned footer (motion only)**: `.safeAreaInset(edge: .bottom, spacing: 0)` holds `GlassEffectContainer(spacing: 12)` with **"Reset dials"** (`arrow.counterclockwise`, `motion-reset-dials`) and **"Reset alignment"** (`viewfinder`, `motion-reset-alignment`). The footer uses an HStack, or a VStack at accessibility sizes. Each button: `.glass`, tint phosphor, `frame(maxWidth: .infinity, minHeight: 32)`, `.fixedSize(horizontal: false, vertical: true)` so labels wrap. The footer background is `background.opacity(0.96)`. The hints change with Link state: "Restore default motion and dial values for all linked channels." versus "…for the selected channel."
- Semantics: Reset dials restores `OrbitalSettings().channels[selectedChannel]` to the selected channel, or to all channels when linked. Reset alignment calls `model.alignAllViews()`. Neither touches the clock or the recorded history.

### `MotionControls` (sheet 01)

Order: harmonic picker → channel picker + Link → editing indicator → motion chips + explanation → 2×2 dial grid → footer caption ("Drag a dial up or right. Fine-tune with its slider." or "All channels share the same motion settings.").

### Presets: "Harmonic starters" (`Core/HarmonicPreset.swift` + `MotionControls.harmonicPicker`)

- `enum HarmonicPreset: String, CaseIterable, Identifiable, Sendable { case unison, counterphase, threePhase, laplace, beats, lissajous }`. Each case provides `title`, `ratioLabel`, `summary`, `channels: [Channel]`, `sourceTitle` and `sourceURL`. The sources are NASA, MIT OCW and OpenStax links.
- UI: a full-width `.glass` Menu tinted amber. The label is `waveform.path` + title ("Harmonic starters", or the matching preset title) + monospaced ratio ("Choose a synchronization" by default) + `chevron.down`. Menu sections: "Start a harmonic · new recording" (each preset shows title + ratio and plays `success()`), then "Zero all phase offsets" (`arrow.triangle.merge`, `selection()`). Caption below: "Starters set A, B & C and begin a fresh recording."
- Identity is **derived, not stored**: `model.currentHarmonic = HarmonicPreset.allCases.first { $0.channels == settings.channels }`, so editing any dial reverts the label to "Harmonic starters".
- `applyHarmonic` resets the clock to 0, clears the recorder, turns off Link and the loop, and sets `preset = title`. It keeps geometry, camera, selected view and play/pause state. Copy states every side effect.
- A second, older preset system exists in `ControlsView` panel 04, "Experiment presets": Circle study, Spherical orbits, Lissajous study, Hyperspace. It restarts everything, including cameras, and selects `.spatial`.

### Field notes (`FieldNotesView` in `UI/TelemetryView.swift`)

A `ScrollView` of numbered `InstrumentPanel`s, 01 to 07: "A dimensional instrument", "Five ways to see", "Time & accuracy", "Touch & efficiency", "Reading the dials", "Harmonic starters", "Orbitals in your space". The body is `.subheadline` white 0.85 and the panels sit in `VStack(spacing: 20)` with `.padding(16)`. A private helper `note(title, detail)` shows the title in phosphor `.medium` above the detail. External references use `Link(...)` to Apple HIG pages and the preset sources.

Tone: every simplification is stated explicitly ("kinematic illustrations, not gravitational…", "The transparent line art does not hide behind furniture", "Camera frames and room maps are not saved").

### Telemetry (`UI/TelemetryView.swift`)

- `TelemetryPanel` ("State vectors", number "XYZW") contains a `CoordinatesTable`, then three `Readout`s for "A ↔ B", "B ↔ C" and "C ↔ A" (`"%.3f u"`), then a caption explaining the metric ("Euclidean distances in 4D, measured before projection.").
- `CoordinatesTable(points: [Vec4]?, fourD: Bool)`: a `Grid(horizontalSpacing: 8, verticalSpacing: 13)`. The header row is CH/X/Y/Z/(W) in muted text. Each channel row is colored with its channel color, values use `"%+.2f"` trailing-aligned with `monospacedDigit`, and each cell has an accessibility label at 3 decimals. A missing value shows "—" ("not recorded" for VoiceOver). **Gaps are never interpolated in the UI.**
- `model.points` and the other readouts refresh at **10 Hz**, not per frame.

### Context panels (`UI/ControlsView.swift`)

`ControlsView` panels: 02 "Geometry" (morph, radius, 4D toggle, XW/YW/ZW sliders), 03 "Display & attitude" (mesh, axes, trails, connections toggles; persistence and glow; per-view camera yaw/tilt/zoom; Reset view), 04 "Experiment presets", 05 "Physical feedback" (Haptics toggle, Intensity 0.2–1 step 0.05, "Feel a detent" button).

The dashboard shows extra panels only when they are relevant: `TimelineInspector` ("T", for the cylinder and torus), `LoopControls` (for tracks) and `RetconControls` (for retcon). Disabled states use `.disabled(...)`; for example, morph is disabled in 4D and Intensity is disabled when haptics are off.

---

## (c) Navigation and screen structure

```
OrbitalsApp → DashboardView (NavigationStack, large title)
  ├─ toolbar: [Dials]  ·  [info][sliders]
  ├─ ScrollView (dashboard-scroll)
  │    introduction (eyebrow + subtitle)
  │    dimension picker 2D/3D/4D/5D
  │    primaryColumn
  │      viewSelector (only when dimension == 5)
  │      VisualizationPanel (title, Align, Expand, canvas, legend, caption)
  │      [TimelineInspector | LoopControls | RetconControls] (view-dependent)
  │      ActionButton "Motion control & harmonics"
  │      TelemetryPanel
  │      ActionButton "Geometry, display & haptics" (compact width only)
  │      footer caption
  │    (width > 850: ControlsView embedded as a right column)
  ├─ safeAreaInset(bottom): transport
  ├─ .sheet(item:) InstrumentControlSheet(.motion | .controls | .notes)
  └─ .fullScreenCover(item: $expandedView) FullScreenVisualization
        ├─ header: [Dials] [view Menu | title capsule]  ···  [AR] [Close]
        ├─ footer: legend capsule, hint capsule, camera bar (5 buttons)
        ├─ .sheet(item:) InstrumentControlSheet
        └─ .fullScreenCover OrbitARScreen
              header: [Dials] [AR view Menu] ··· [×]
              instruction card, then [Place here | Move anchor] [Play][−][+][⋯]
```

Key rules:
- **Progressive disclosure by dimension**: the view tabs appear only in 5D. Choosing a non-spatial view auto-promotes to 5D (`chooseView` → `setDimension(5)`), and choosing below 5D forces `.spatial`.
- **One renderer at a time**: `VisualizationPanel(isRendering: expandedView == nil && !fullScreenActive)`. While full screen is up, the embedded canvas is replaced by a plain `OrbitTheme.background`. The full screen in turn swaps its canvas for a background while AR is presented. On every dismissal `model.invalidate()` runs to force a repaint.
- **Camera state lives in the model, per view** (`cameras: [String: ViewCamera]`), so framing carries between the dashboard, full screen and AR return, and each of the five views keeps its own.
- **Full-screen header**: Dials (`dial.medium`), then a view Menu (5D) or a glass title capsule, then `Spacer`, then "AR" (`arkit`), then Close (`arrow.down.right.and.arrow.up.left`). The expand icon is `arrow.up.left.and.arrow.down.right`. `.statusBarHidden()`; Escape closes and Space toggles play.
- **Full-screen footer**: legend capsule + zoom % and a hint capsule ("Drag to rotate · Two fingers to move · Pinch to zoom", or the Move-mode variant). Both are hidden when `verticalSizeClass == .compact` (landscape iPhone). The camera bar has Play/Pause, Move (`hand.draw` / `hand.draw.fill`, tinted yellow when on, with value "On"/"Off" and the `.isSelected` trait), Zoom out ×0.8, Zoom in ×1.25, and Reset (`viewfinder`).
- **Align**: `VisualizationPanel` has a labelled "Align" (`viewfinder`) glass button that resets *this* view's camera. Reset alignment in the sheet resets *all* views. Double-tap on the canvas also resets this view.

### Gestures (`UI/OrbitCanvasGestures.swift`)

A transparent `UIViewRepresentable` surface sits above the `MTKView`. The `MTKView` has `isUserInteractionEnabled = false`. Accessibility stays on the SwiftUI host.

Recognizers:
- One `UIPanGestureRecognizer` with `minimumNumberOfTouches = 1` and `maximumNumberOfTouches = 2`. A single recognizer handles both one and two fingers; the comment explains that a separate one-finger recognizer would prevent pinch from beginning.
- One `UIPinchGestureRecognizer`.
- One `UITapGestureRecognizer` with `numberOfTapsRequired = 2` (reset).
- Pan and pinch recognize simultaneously through the delegate.

Behavior:
- **Rotate** (one finger, not in Move mode, not part of a multitouch sequence): `yaw += dx * 0.45`, `pitch -= dy * 0.45` (degrees per point).
- **Pan** (two fingers, or one finger in Move mode): `panCamera(dx: dx/width, dy: dy/height)`, so pan is viewport-relative.
- **Pinch**: zooms about the focal point. It first pans by the centroid delta and then calls `zoomCamera(by: scale, anchor: (x/w - 0.5, y/h - 0.48))`, resetting `recognizer.scale = 1` on every callback.
- **Robustness rules**: when the touch count changes, that event is treated as a rebase (the centroid jumps). Once a sequence has involved two fingers, a leftover single finger never resumes rotation. After a pinch, pan translation is zeroed so a lifted finger causes no jump. Changing model or view calls `cancel()`, which toggles `isEnabled` on every recognizer and ends haptics.
- **Haptics during gestures**: `beginAdjustment()` when the first adjustment starts (tracked as a `Set<Adjustment>`), `endAdjustment()` when the last one ends. Detents are normalized as follows: yaw `(yaw+180)/360` or pitch `(pitch+85)/170`, depending on the dominant axis; zoom `log(zoom/0.25)/log(6/0.25)`; pan `(pan+1.5)/3`.
- **Camera limits** (`OrbitModel`): yaw wraps to [-180, 180); pitch is clamped to ±85; zoom to **0.25…6** (25–600%); pan to **±1.5** viewport. A pan delta is clamped to ±3 before it is added, and non-finite input is ignored. The projection center is (0.5w, 0.48h); it sits slightly above middle to leave room for the bottom chrome.
- **Default cameras**: spatial = settings yaw/pitch (0/0), cylinder 16/10, torus 0/35, tracks 0/40, retcon 0/38.
- **Non-gesture alternatives**: canvas `.accessibilityAdjustableAction` (±5° yaw); named actions "Zoom in", "Zoom out", "Move left/right/up/down" (±0.1) and "Reset camera"; keyboard arrows (±5°) and `+`/`=`/`-`.
- The canvas `accessibilityValue` is `"Yaw N degrees, tilt N degrees, zoom N percent, pan X N percent, pan Y N percent"`. UI tests parse this string, so it is the testable camera state.

---

## (d) Metal phosphor renderer

Files: `Rendering/OrbitMetalView.swift`, `Rendering/Phosphor.metal`, `Rendering/SceneGeometry.swift`.

### Architecture

```
OrbitModel (@Observable @MainActor, conforms to OrbitalSceneSource)
   │ renderSnapshot() → RenderSnapshot (value struct)
   │ advanceFrame(timestamp:)  (clock driven by the display tick)
   ▼
OrbitMetalView: UIViewRepresentable  (source, redrawKey, running, onError)
   └─ OrbitMTKView: MTKView  (didMoveToWindow → setNeedsDisplay)
        delegate = OrbitRenderer (@MainActor NSObject, MTKViewDelegate)
             ├─ SceneGeometry (CPU: snapshot → [PhosphorSegment])
             ├─ 3 × MTLBuffer (2 MiB each, .storageModeShared), round-robin
             ├─ DispatchSemaphore(value: 3), non-blocking wait
             ├─ backgroundPipeline (instrumentVertex/instrumentFragment, fullscreen tri)
             └─ tracePipeline (phosphorVertex/phosphorFragment, instanced quads)
```

```swift
@MainActor protocol OrbitalSceneSource: AnyObject {
  func renderSnapshot() -> RenderSnapshot
  func advanceFrame(timestamp: Double)
  var isAnimating: Bool { get }
}
```

### Vertex format (one instance = one analytic capsule)

```swift
// Layout exactly matches Phosphor.metal. One instance is an analytic capsule;
// a degenerate segment is a particle disc, optionally with a hollow center.
struct PhosphorSegment {            // stride 64 bytes
  var start: SIMD2<Float>           // points (not pixels), top-left origin
  var end: SIMD2<Float>
  var color: SIMD4<Float>           // start RGBA (A = opacity)
  var style: SIMD4<Float>           // radius (= width/2), glow 0…1, dash period, cumulative dash offset
  var detail: SIMD4<Float>          // hollow radius, end R, end G, end B  (gradient endpoint)
}
private struct PhosphorUniforms {   // stride 32 bytes
  var viewport: SIMD4<Float>        // width pt, height pt, contentScale, elapsed sim time
  var appearance: SIMD4<Float>      // retcon tint (0/1), reduced motion (0/1), reserved, reserved
}
```
- `capacity = 32_768` segments × 64 B = 2,097,152 B (**2 MiB**) per buffer, three buffers.
- Draw call: `drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: segmentCount)`. The segments are memcpy'd into the current buffer with `withUnsafeBytes` + `copyMemory`.
- Uniforms go through `setVertexBytes`/`setFragmentBytes` at index 1; segments are bound with `setVertexBuffer` at index 0.
- Pipelines: color attachment = `view.colorPixelFormat` (`.bgra8Unorm`). Trace blending uses **premultiplied alpha**: `source = .one`, `destination = .oneMinusSourceAlpha` for both RGB and alpha, operation `.add`. The background pipeline is opaque.
- MTKView config: `isOpaque = true`, `framebufferOnly = true`, `colorPixelFormat = .bgra8Unorm`, `sampleCount = 1` (no MSAA, because antialiasing is analytic), `autoResizeDrawable = true`, `isAccessibilityElement = false`, `isUserInteractionEnabled = false`.

### Shader techniques (`Phosphor.metal`)

- **Vertex** (`phosphorVertex`): a unit quad of 6 corners is expanded along the segment tangent and normal by `padding = radius + glowRadius + 1.5`, where `glowRadius = glow > 0 ? 3 + 7*glow : 0`. Positions are converted from points to NDC with `x/w*2-1, 1-y/h*2`. `start`, `end`, `color`, `style` and `detail` are passed `[[flat]]`, and the interpolated `point` is passed too.
- **Fragment**: the analytic capsule distance is `t = clamp(dot(p-a, d)/|d|², 0, 1)` and `distance = |p - (a + t d)|`.
  - AA edge: `edge = max(0.5 / contentScale, fwidth(distance) * 0.6)`; `core = 1 - smoothstep(r - edge, r + edge, distance)`.
  - Hollow ring (`detail.x > 0`): `core *= smoothstep(hollow - edge, hollow + edge, distance)`, with the glow suppressed inside.
  - Glow: `outside = max(0, distance - r)`, `spread = 1.4 + glow*3.1`, `glow = exp(-outside²/spread²) * glow * 0.34`.
  - `alpha = (core + glow*(1-core)) * color.a`.
  - Dashes: when `style.z > 0`, `along = t*|d| + style.w`, `dash = fmod(along, period)`, and alpha is multiplied by `1 - smoothstep(0.56P - edge, 0.56P + edge, dash)`, a 56% duty cycle. The cumulative `style.w` offset keeps dashes continuous across segments.
  - Gradient: `color = mix(color.rgb, detail.yzw, t)`. This blends along the whole capsule, glow included, so CMY gradient lines need no extra stride.
  - Particle "hot core": for a degenerate, non-hollow segment, `color = mix(color, white, 0.52*(1 - smoothstep(0, r, distance)))`.
  - Output is premultiplied: `half4(color * alpha, alpha)`.
- **Background** (`instrumentVertex`/`instrumentFragment`): one oversized full-screen triangle. It draws a radial vignette `clamp(1 - |c|²*1.7, 0.35, 1)`, a **32 pt grid** (line width about 0.2–0.75 pt via smoothstep), a brighter center cross ("major"), and a scanline `0.96 + 0.04*cos(y*π)`. Grid weights are `grid*0.22 + major*0.15`, and the colors switch to a blue cast when `appearance.x == 1` (retcon). The background is skipped in AR so the camera shows through.

### Frame pacing and power

- `static var preferredFrameRate`: **30** if `ProcessInfo.isLowPowerModeEnabled` or `thermalState` is `.serious`/`.critical`, else **60**. It is re-checked every `draw` and applied in `updateUIView`. The Info.plist allows high refresh (`CADisableMinimumFrameDurationOnPhone`), but the app caps itself at 60.
- **Paused mode**: `view.enableSetNeedsDisplay = !running; view.isPaused = !running`. While paused, `updateUIView` calls `setNeedsDisplay()` when `redrawKey` changes. `model.invalidate()` does `redrawKey &+= 1`, and every control, camera or selection change calls it. `drawableSizeWillChange` and `didMoveToWindow` also request a draw.
- **Offscreen skipping**: `draw(in:)` returns early if there is no window, the view is hidden, bounds are ≤ 1 pt, or the app is in the background. It **always calls `source.advanceFrame(timestamp: CACurrentMediaTime())` first**, so the clock and readouts continue. It then computes `view.convert(view.bounds, to: window).intersection(window.bounds)` and returns if that is empty. A scrolled-away plot therefore skips the drawable, the snapshot copy and the geometry.
- **Never block**: `guard inFlight.wait(timeout: .now()) == .success else { return }`. With all three buffers in flight it drops the tick, and the simulation clock stays accurate. The completion handler signals a locally captured `semaphore`, not `self`.
- **Errors**: `RendererError` (`.unavailable`, `.shader`, `.buffer`, each with a user-facing `errorDescription`) is surfaced through `onError` → `model.renderError` → `ContentUnavailableView("Renderer unavailable", systemImage: "exclamationmark.triangle")`.
- **Teardown** (`dismantleUIView`): `isPaused = true`, `delegate = nil`, renderer released, `releaseDrawables()`.
- Debug labels on pipelines, buffers and encoders ("Orbitals · analytic phosphor capsules", "Orbitals · frame N", "Orbitals · <view title>").

### SceneGeometry approach

`final class SceneGeometry` (not an actor, not Sendable; owned by the @MainActor renderer):
- `update(_ snapshot: RenderSnapshot, size: CGSize, capacity: Int, arProjection: ARSceneProjection? = nil)` clears `segments` with `removeAll(keepingCapacity: true)`, which was reserved at 32,768. It then dispatches on `snapshot.kind` and emits segments. `defer { self.snapshot = nil }` releases the archive array at frame end; the comment explains that retaining it would force the recorder's copy-on-write array to copy on the next append.
- **Fit-to-view scale**: spatial uses `max(1, min(w-36, h-54) / (2*bound)) * zoom`, where `bound = R*(fourD ? 1.5 : 1.1)`. Cylinder uses `CameraMath.cylinderScale` (corner-box fit, insets 44/88). Torus, tracks and retcon use a rotation-invariant bound `min(w-32, h-54) / (2*(2.6+0.88))`, so the apparent size doesn't pump while dragging.
- **Projection closure**: `screen(Vec3)` applies `CameraMath.rotate(yaw:pitch:)` followed by `viewportPoint`, or `arProjection.project` in AR. `viewportPoint` is `(w*(0.5+panX) + x*scale, h*(0.48+panY) - y*scale)`. Only the geometry scales; stroke widths and particle sizes stay in points, which keeps them crisp at any zoom.
- **Primitives**: `add(a, b, color:, endColor:, width: 1.5, glow:, dash:, offset:, hollow:)` guards nil, non-finite values and the capacity limit; `dot(p, color:, diameter: 7, hollow:)` is a degenerate segment; `path([Vec3])` is a polyline with a cumulative dash offset; `gradientPath` is a CMY-cycling polyline; `faded(color, alpha)`; `nextDashOffset`.
- **Caching keyed by Equatable signatures**: `meshKey: MeshShape` (radius, morph, xw, yw, zw, fourD), `trajectoryKey`/`trackKey: TrackShapeSignature` (shape only, excluding speed and frequency, so rate changes never rebuild), and a `lazy var torusCage`. Tests assert that caches invalidate correctly across all five views.
- **CMY cyclic gradient**: `static func cyclicTrackColor(phase:channel:)` wraps the phase first, so the closing seam matches exactly.
- **Stroke vocabulary** (width in pt / glow factor):

  | Element | Width | Glow | Other |
  |---|---|---|---|
  | mesh | 0.85 | `glow*0.15` | green, alpha 0.24 |
  | axes | 0.9 | — | green 0.4; 4th axis ghost, dashed 5 |
  | motion guides | 1.4 | `glow*0.65` | gradient, alpha 0.8, dashed 6 |
  | recorded trails | 1.6 | `glow*0.5` | alpha `0.76*(1-age/persistence)` |
  | connections | 1.8 | full `glow` | gradient between the two endpoint CMY colors |
  | particles | diameter 8 (spatial), 7 (time views), 9 (track nodes) | full | — |
  | archive traces | 1.65 | `glow*0.65` | alpha 0.9 |
  | forecasts | 1.8 | `glow*0.65` | dashed 9, alpha 0.75 |
  | ghosts | 1.05 | none | dashed 7 |
  | inspection markers | diameter 10 | — | hollow ring |

- **Honesty in geometry**: archive segments connect only samples that share a `segment` id, so discontinuities stay visible. Display-only joins (torus closure bridge, window snap) are commented as such and never written back to data.

---

## (e) Haptics service: `Services/OrbitalHaptics.swift`

```swift
@MainActor final class OrbitalHaptics {
  static let shared: OrbitalHaptics
  var enabled: Bool = true      // didSet: false → stop()
  var strength: Double = 0.85   // 0…1, applied as the hapticIntensityControl dynamic parameter
  func tap()                    // generic button
  func selection()              // UISelectionFeedbackGenerator.selectionChanged()
  func beginAdjustment()        // grab: prepares generators, plays .touch
  func detent(normalized: Double) // 0…1 → 72 detents, boundary pulse at 0 and 72
  func endAdjustment()          // release pulse
  func boundary()               // end-stop / failure
  func success()                // UINotificationFeedbackGenerator .success
  func stop()                   // stop players + engine, reset rate-limit state
}
```

| Pulse | Intensity | Sharpness | Min interval (s) |
|---|---|---|---|
| `.touch` (`tap`, `beginAdjustment`) | 0.64 | 0.5 | 0.028 (tap), 0.035 (begin) |
| `.detent` | 0.43 | 0.86 | 0.045 |
| `.release` (`endAdjustment`) | 0.34 | 0.38 | 0.035 |
| `.boundary` | 0.95 | 0.64 | 0.09 |
| `selection()` (system) | — | — | 0.035 |
| `success()` (system) | — | — | 0.06 |

Implementation details:
- Rate limiting: one shared `lastFeedbackTime` (`ProcessInfo.systemUptime`), checked by `admit(interval:)`. Detents are additionally deduplicated by `lastDetent` index, so dragging coalesces instead of queuing one vibration per frame.
- `canPlay` requires `enabled`, a finite `strength > 0`, and `UIApplication.shared.applicationState == .active`.
- Core Haptics path: when `CHHapticEngine.capabilitiesForHardware().supportsHaptics`, one lazy `CHHapticEngine` is used with `playsHapticsOnly = true` and `isAutoShutdownEnabled = true`. Its `stoppedHandler` and `resetHandler` hop to the main actor with `Task { @MainActor [weak self] in ... }`, and the reset handler drops the cached players. Players are cached per `Pulse` (`[Pulse: any CHHapticPatternPlayer]`) from a single `.hapticTransient` event. Each play sends `CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength)` and then `start(atTime: CHHapticTimeImmediate)`.
- Fallback, used on any error or without Core Haptics: `UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: strength * pulse.intensity)`.
- Lifecycle: one `UIApplication.didEnterBackgroundNotification` observer calls `stop()`. The App also calls `stop()` on any non-active `scenePhase`. There is no idle polling, and per the class doc, **"Nothing runs continuously with the simulation clock."**
- Settings: `OrbitModel.hapticsEnabled` and `.hapticStrength` push into the singleton in `didSet` and are persisted.

Usage patterns:
- Every button: `tap()`.
- Pickers, toggles, tabs, chips, VoiceOver adjustments: `selection()`.
- Continuous controls: `beginAdjustment` → `detent(normalized:)` → `endAdjustment`.
- Hitting a limit or a failed AR placement: `boundary()`.
- Loading a preset, Reset experiment, or a successful AR anchor: `success()`.
- Menus get `tap()` through `.simultaneousGesture(TapGesture().onEnded { ... })`.

---

## (f) AR controller approach

Files: `AR/OrbitARController.swift`, `AR/OrbitalARView.swift`, `UI/OrbitARScreen.swift`, `Core/ARPlacementMath.swift`, `Core/ARSceneProjection.swift`.

**Layering** (`OrbitalARView: UIViewRepresentable`): a container `UIView` holds three full-bleed subviews pinned with Auto Layout:
1. `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)` with `renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR]`. RealityKit is used **only as the camera feed**.
2. A transparent `MTKView` (`isOpaque = false`, clear color 0,0,0,0, `enableSetNeedsDisplay = false`, starts paused) driven by the **same `OrbitRenderer`**, with `renderer.arProjectionProvider = { [weak controller] in controller?.projection() }`.
3. `ARCoachingOverlayView` (`goal = .anyPlane`, `activatesAutomatically = true`).

Gestures on the container: tap to place, pinch to scale, rotation to yaw. Their targets and delegate are the controller. `tap.cancelsTouchesInView = false`. `gestureRecognizerShouldBegin` refuses all gestures while coaching, so the native coaching controls get their touches. Taps are accepted only in placement mode, and pinch/rotation only after placement. Pinch and rotation recognize simultaneously.

**Controller**: `@Observable @MainActor final class OrbitARController: NSObject`.
- `enum Phase: Equatable { requestingPermission, scanning, ready, placed, interrupted, relocalizing, paused, denied, unsupported, failed(String) }`. Each phase maps to a `title` and an `instruction` string; the UI renders these directly.
- Observable state: `isPlaced`, `isPlacementMode`, `canPlace`, `isCoaching`, `sizeMeters` (default **0.65 m**, range **0.15–2 m**). Computed: `isSupported = ARWorldTrackingConfiguration.isSupported` and `scalePercent`.
- Session configuration: `ARWorldTrackingConfiguration` with `planeDetection = [.horizontal, .vertical]`, `worldAlignment = .gravity`, `environmentTexturing = .none`, `isLightEstimationEnabled = false`. Depth, people occlusion and scene mesh are deliberately off because the geometry is emissive.
- Permission: `AVCaptureDevice.authorizationStatus(for: .video)` / `await AVCaptureDevice.requestAccess(for: .video)`. Denial shows `ContentUnavailableView` with an "Open Settings" `.glassProminent` button (`UIApplication.openSettingsURLString`). The check re-runs whenever the scene becomes active.
- Delegates: `extension OrbitARController: @preconcurrency ARSessionDelegate` and `@preconcurrency ARCoachingOverlayViewDelegate`, with `arView.session.delegateQueue = .main`. A comment explains that ARSession delivers every callback on main, so the preconcurrency conformance is safe.
- Surface readiness: in `session(_:didUpdate:)`, a center-screen `arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .any)` runs, **throttled to every 0.12 s**, and toggles `canPlace` and `.ready`/`.scanning`. Tracking state maps to phases (`.limited(.relocalizing)` → `.relocalizing`).
- Placement: raycast at the tap point or the center. The old anchor is removed, then `ARAnchor(name: "Orbitals placement", transform: result.worldTransform)` is added, then `success()` haptic and coaching is deactivated. A failure plays `boundary()`.
- `replace()` re-enters placement while the old placement stays visible ("Move anchor"). `resetPlacement()` reruns the session with `[.resetTracking, .removeExistingAnchors]` ("Scan a new space").
- Interruptions: `sessionWasInterrupted` sets `.interrupted` and deliberately does not call pause; `sessionInterruptionEnded` moves to `.relocalizing` or `.scanning`; `sessionShouldAttemptRelocalization` returns `true`.
- Lifecycle: `setActive(_:)` pauses or resumes on scene phase. `detach()` is used for SwiftUI teardown and can re-attach. `shutdown()` is the permanent disposal on `onDisappear`. Anchors are session-only and nothing is persisted.
- **Projection per tick** (`projection() -> ARSceneProjection?`): reads `session.currentFrame` and refreshes `anchorTransform` from `frame.anchors`, which picks up the corrected pose rather than a frozen raycast. It takes the orientation from `view.window?.windowScene?.effectiveGeometry.interfaceOrientation` and builds `viewProjection = camera.projectionMatrix(for: orientation, viewportSize: bounds.size, zNear: 0.01, zFar: 100) * camera.viewMatrix(for: orientation)`. It returns `nil` (and the renderer clears the overlay) while interrupted or relocalizing, or when there is no frame or anchor.
- `ARPlacementMath.transform(anchor:kind:settings:sizeMeters:yaw:) = anchor * lift * rotationY * uniformScale`. The scale is `size / referenceSpan(kind)` (spatial 6, cylinder 5.6, torus/tracks/retcon 6.96). The lift is `halfExtents.y * scale + 0.015 m` (`surfaceClearance`), so the shape sits just above a table or in front of a wall. The live radius affects only the clearance, so the radius dial still changes world size.
- `ARSceneProjection.project(_:viewport:)` multiplies by the cached `viewProjection * modelTransform`. It culls before dividing (`w > 1e-6`, `0 ≤ z ≤ w`, all finite) and maps to top-left pixel coordinates.
- `SceneGeometry` in AR ignores the instrument camera (yaw and pitch are set to 0 for spatial), so leaving AR restores the instrument framing. Pause freezes the simulation, but the AR canvas keeps rendering camera poses.
- `OrbitARScreen` UI:
  - Header (glass): Dials, AR view Menu (`arkit`), Close (`xmark`).
  - Center reticle: `Image(systemName: "scope")` 34 pt light, phosphor when placeable.
  - Instruction card: `.glassEffect(.regular, in: .rect(cornerRadius: 22))`, `maxWidth 540`, with a status dot.
  - Actions use `ViewThatFits` HStack/VStack (VStack at accessibility sizes): "Place here" / "Move anchor" (`.glassProminent`, tint white, disabled until `canPlace`), Play, Smaller ×0.8, Larger ×1.25, and a `⋯` menu ("Reset size and rotation", "Scan a new space").

---

## (g) Model and state architecture

- **Observation, not Combine.** `OrbitModel` and `OrbitARController` are `@Observable @MainActor final class`. There are no `ObservableObject`, `@Published`, `@AppStorage` or `@StateObject`. The App owns `@State private var model = OrbitModel()`; views take `@Bindable var model: OrbitModel` (read-only views take `let model`). `OrbitARScreen` owns `@State private var controller = OrbitARController()`.
- Non-UI-driving internals are marked `@ObservationIgnored`: the recorder, `time`, `lastTimestamp`, `cameras`, `saveTask` and loop origins. **The simulation `time` is ignored; the UI observes `displayTime`**, which is copied only in `refreshReadouts()` at 10 Hz. This avoids 60 Hz SwiftUI invalidation.
- **Single source of truth with `didSet` side effects**: `settings` is an `OrbitalSettings` value (`Codable, Equatable, Hashable, Sendable`), and its `didSet` calls `controlsChanged()` (record a new segment, revise retcon, invalidate, schedule a save). Other properties invalidate or save from their own `didSet`. A `ready` flag suppresses side effects during `init`.
- **Custom bindings for scoped edits**: `channel(\.speed)` → `Binding(get: settings.channels[selected][keyPath:], set: model.setChannel(key, $0))`. `setChannel` writes to the selected channel, or all channels when `linked`. `setting(\.radius)` is a generic keypath binding into `settings`.
- **Redraw signalling**: `redrawKey: Int` (`invalidate()` does `&+= 1`) is passed into the `UIViewRepresentable`. This is the only bridge from model edits to a paused Metal view.
- **Persistence**: one `UserDefaults` key, **`"Orbitals.experiment.v1"`**. It stores a JSON-encoded `private struct SavedExperiment: Codable { settings, dimension, view, loop, haptics, strength }`. Saves are debounced: `scheduleSave()` cancels the previous `Task` and sleeps **400 ms**. The App also calls `save()` immediately on a non-active scene phase. The clock, archive, cameras and AR anchors are **not** persisted, so a new launch starts a fresh clock and recording.
- **Test hook**: the launch argument `-ui-testing` resets settings to defaults, `dimension = 2`, `.spatial`, and `running = false`.
- **Clock and time semantics**:
  - The clock is driven by the display tick through `advanceFrame(timestamp: CACurrentMediaTime())`.
  - `time += min(max(Δ, 0), 0.1)`: negative deltas are dropped and long frames are bounded to 100 ms.
  - `lastTimestamp = nil` whenever `running`, `active` or `isAnimating` changes. The first frame after resuming only re-bases, so there is **no wall-clock catch-up** after pause or background.
  - `isAnimating = running && active`; `setActive` is driven by `scenePhase`.
  - `step()` sets `running = false` and adds exactly `1/60` s.
  - Readouts refresh when `time - lastReport >= 0.1`.
  - The clock string is `"%02d:%02d.%02d"`.
- **Recording**: `TimelineRecorder` (a value type, `Sendable`) samples on an exact **60 Hz simulation-time grid** (`sampleInterval = 1/60`) and keeps **30 s** (`historySeconds`, reserved capacity 1,804). A change in the physical `MotionSignature` (channels, radius, morph, fourD, xw/yw/zw) starts a new segment; optical changes (glow, yaw, mesh) do not. Archived samples are never mutated. Edits while paused affect only the next segment. Time going backwards clears the recorder.
- **Scoped resets**: `resetCamera()` (this view), `alignAllViews()` (all cameras, preserving preset label and physics), `resetMotionControls()` (selected or linked dials), `alignPhases()`, `clearTrails()` (sets a `trailCutoff` timestamp), `clearHistory()`, and `reset()` (everything, restarts running). Each one documents what it preserves.
- **Swift 6 strict-concurrency choices**:
  - Core math types are `enum`s with static functions, or value `struct`s marked `Sendable`.
  - The model, renderer, haptics, AR controller and gesture coordinator are explicitly `@MainActor`.
  - Objective-C delegates use `@preconcurrency` conformances when callbacks are main-queue.
  - Callbacks from non-isolated contexts (haptic engine handlers, NotificationCenter, Metal errors) hop with `Task { @MainActor [weak self] in … }`.
  - The Metal completion handler captures only the `DispatchSemaphore`.
  - `OrbitMetalView.Coordinator` and `SceneGeometry` are plain non-Sendable classes confined to main.
  - The app has no `async` work except AR permission and the debounced save.
- **Domain separation**: `Core/` has no UI imports (Foundation, simd and CoreGraphics only) and uses `Double` throughout (`typealias Vec4 = SIMD4<Double>`, `Vec3 = SIMD3<Double>`). Conversion to `Float` happens only at the GPU boundary.

---

## (h) Testing approach

XCTest is used throughout; there is no Swift Testing. Model and UI tests are annotated `@MainActor`. Tests use `@testable import Orbitals`.

**Unit tests (`OrbitalsTests`, 67 tests across 7 files)**:

| File | Count | Focus |
|---|---|---|
| `CoreTests` | 19 | Codable round trip, morph radius invariance (301 cases), 4D rotation isometry (500 cases), bounded and finite motions (5 modes × 400 randomized settings), recorder ticks and 30 s retention, paused-edit immutability, segments, torus closure stays inside the tube, closed tracks (position and tangent), loop presets, retcon |
| `ModelTests` | 13 | Exact 1/60 step, edits keep clock and archive, linking, retcon evidence, loop isolation, clear/reset, five views, per-view cameras, **background suspension with no catch-up**, **long frame bounded to 0.1 s** |
| `CameraViewportTests` | 9 | Clamps, non-finite rejection, **anchored zoom keeps the touched scene point stationary** (1e-12), clamped-ratio zoom at the limits, per-view independence, reset preserves archive, paused invalidation |
| `HarmonicPresetTests` | 9 | Exact recurrence, three-phase balance after 4D rotation, Laplace 4:2:1 lock, beat period, apply-harmonic semantics, scoped resets |
| `MotionRenderingTests` | 4 | Builds `SceneGeometry` directly from a synthetic `RenderSnapshot` and inspects `segments`: guide counts (`3 × 320`), cache invalidation across all five views, guides unchanged by rate |
| `ARPlacementMathTests` | 5 | Every shape clears horizontal and vertical surfaces by exactly 0.015 m; yaw preserves support height; malformed radius falls back finitely |
| `ARSceneProjectionTests` | 8 | Matrix order, top-left mapping, near/far/behind culling, invalid inputs never reach the GPU, AR ignores the instrument camera, only the cylinder ring is white (`count == 64`) |

Pattern: `makeModel()` removes the `"Orbitals.experiment.v1"` default, then creates the model, calls `reset()` and sets `running = false`. Time is driven deterministically through `advanceFrame(timestamp:)` and `step()`, never through real time. Assertion helpers `assertNear(Vec4/Vec3, accuracy: 1e-9)` pass `file:`/`line:` through. Large deterministic loops (`for index in 0..<500`) replace random fuzzing.

**UI tests (`OrbitalsUITests`, 13 tests across 3 files)**: `OrbitalsUITests` (7), `MotionControlUITests` (4) and `ARPresentationUITests` (2).
- Every app launch uses `-ui-testing` (paused, defaults). Dynamic Type stress launches add `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`.
- Elements are located **only by `accessibilityIdentifier`** or by exact labels. Stable IDs: `transport-play`, `transport-step`, `dimension-picker`, `view-selector`, `view-<kind>`, `visualization-expand`, `visualization-close`, `visualization-ar`, `orbital-canvas`, `orbital-canvas-fullscreen`, `fullscreen-play`, `camera-pan-mode`, `camera-zoom-in/out`, `fullscreen-reset-camera`, `motion-controls-open`, `fullscreen-motion-controls-open`, `motion-reset-dials`, `motion-reset-alignment`, `harmonic-picker`, `channel-picker`, `motion-choice-<Name>`, `motion-mode-description`, `dashboard-scroll`, `motion-controls-scroll`, `controls-scroll`, `field-notes-scroll`, and `ar-unavailable`, `ar-open-settings`, `ar-motion-controls`, `ar-view-picker`, `ar-close`, `ar-status`, `ar-place`, `ar-play`, `ar-smaller`, `ar-larger`, `ar-actions`.
- **State is asserted through accessibility values**. The canvas camera string is parsed into 5 numbers, and the clock is found with the label predicate `"Simulation paused, 00:00.01"`.
- Real gestures are exercised: `press(forDuration:thenDragTo:)`, `pinch(withScale:velocity:)`, `doubleTap()`, `adjust(toNormalizedSliderPosition:)` and `XCUIDevice.shared.orientation = .landscapeLeft`.
- Fit checks verify that every control's frame lies inside `app.frame` at XXXL and in landscape.
- Helpers to copy: `requireHittable`, `wait(predicate, on:, message:)`, `reveal(_:in:direction:)` (scrolls from the 0.97-x gutter so dials never steal the drag; short adaptive horizontal drags), `waitForFullVisibility`.
- Screenshots are attached with `XCTAttachment(screenshot:)`, `lifetime = .keepAlways`.
- AR UI tests call `throw XCTSkip` on a device (`#if !targetEnvironment(simulator)`) and exercise the Simulator's "unsupported" path.

**Parity tests**: per `VERIFICATION.md`, the initial Swift core was checked against the original TypeScript dashboard with **500 direct parity samples, max absolute error `7.771561172376096e-16`**. The harness is **not** in the Orbitals repo; it was run ad hoc during the port. Spectra should keep its parity harness in-repo, for example comparing the spectra-lab JavaScript output to the Swift core, so it can be re-run.

**Verification log discipline** (`VERIFICATION.md`): every build iteration records:
- what changed
- test counts, with the `.xcresult` bundle name
- failures and their root cause, including test-harness issues
- the signed Release build, plus device install and launch evidence paths (`/private/tmp/orbitals-*.log/json`)
- screenshots
- explicit "not verified" items, such as physical haptic feel and AR tracking

---

## Cross-cutting UX principles (the "Orbitals logic")

1. **Instrument aesthetic**: a dark phosphor CRT content layer (grid, vignette, scanlines, glow), numbered monospaced panels, and amber readouts. Liquid Glass is reserved for controls and navigation.
2. **Two color languages**: data identity (CMY channels) never changes, and parameter identity (dial accents) never changes. Do not mix them.
3. **Every control is tactile and causal**: tap, selection, grab, detent, release, boundary, success. Haptics are rate-limited, never continuous, and off in the background. The user can adjust their strength.
4. **Every gesture has three alternatives**: buttons, VoiceOver actions or the adjustable trait, and keyboard keys. Dials always have a linear slider underneath.
5. **Dynamic Type**: `isAccessibilitySize` collapses grids to one column, stacks the transport and reset bars, and switches to icon-only labels. `ViewThatFits` handles row/column fallback, and `@ScaledMetric` sets descriptor heights.
6. **Reduce Motion**: every animation becomes nil, and symbol effects are removed.
7. **Editing while paused never starts playback**; edits never rewrite recorded evidence. Actions that do restart (presets) say so in the copy.
8. **Persistent access**: the Dials button sits top-left on every surface. The sheet's reset actions are pinned and always visible.
9. **One renderer at a time**: offscreen, paused or background states cost nothing. The frame rate drops to 30 fps on Low Power Mode or thermal pressure.
10. **Honest copy**: muted captions explain limiting cases (zero speed or amplitude), projection semantics and simplifications. Field notes cite sources.
11. **Testability by design**: stable identifiers on every control, state exposed through `accessibilityValue`, and a `-ui-testing` launch argument.

---

## Directly reusable files

These copy into Spectra **nearly verbatim**, apart from renames: `OrbitTheme` → `SpectraTheme`, `OrbitalHaptics` → `SpectraHaptics`, `OrbitModel` → the Spectra model or a protocol, and `Orbitals ·` labels → `Spectra ·`.

| Orbitals file | Spectra target | Changes needed |
|---|---|---|
| `Services/OrbitalHaptics.swift` | `Services/SpectraHaptics.swift` | Rename only. The API, pulses, intervals and lifecycle are generic. |
| `UI/GlassControls.swift` | `UI/GlassControls.swift` | Rename the haptics and theme references. `GlassKnob`, `GlassSlider`, `GlassToggle`, `ActionButton` and the three helpers are domain-free. Consider making `quantized` support log-scale ranges, which frequency and wavelength dials over many decades will need; the Orbitals versions are linear. |
| `UI/OrbitTheme.swift` (`InstrumentPanel`, `Readout`) | `UI/SpectraTheme.swift` | Keep both components verbatim. Keep `background`, `panel`, `phosphor`, `amber`, `muted` and the four dial accents if Spectra adopts the same κ/α/ν/φ-style parameter colors. Replace `channels`/`channelNames` with Spectra's data-identity palette, e.g. spectrum bands. |
| `Rendering/Phosphor.metal` | `Rendering/Phosphor.metal` | Verbatim. The `appearance.zw` lanes are free for a Spectra mode tint; `appearance.y` (reduce motion) is unused. |
| `Rendering/OrbitMetalView.swift` | `Rendering/PhosphorMetalView.swift` | Copy `PhosphorSegment`, `PhosphorUniforms`, `RendererError`, `OrbitMetalView`, `OrbitMTKView` and `OrbitRenderer`. Move `OrbitalViewKind`, `ViewCamera` and `RenderSnapshot` out. Make the renderer take a generic geometry builder (a protocol with `segments` and `update(snapshot,size,capacity,arProjection)`) and a generic snapshot, instead of the concrete `SceneGeometry`/`RenderSnapshot`. The uniform `appearance.x` retcon flag becomes a generic tint selector. |
| `UI/OrbitCanvasGestures.swift` | `UI/CanvasGestures.swift` | Verbatim logic. Replace `OrbitModel` with a small `@MainActor` protocol: `camera`, `setCamera(yaw:pitch:)`, `panCamera(dx:dy:)`, `zoomCamera(by:anchor:)`, `resetCamera()`, and a view identity used to trigger `cancel()`. 2D-only plots such as a Fourier spectrum can map one-finger drag to pan and disable rotation through `panWithOneFinger = true`. |
| `UI/InstrumentControlSheet.swift` | `UI/InstrumentControlSheet.swift` | The structure is verbatim: NavigationStack, inline title, Done in `.confirmationAction`, detents `[.medium, .large]` defaulting to `.large`, and the pinned `safeAreaInset` reset bar. Change the `DashboardSheet` cases, titles and reset actions. |
| `Core/ARSceneProjection.swift` | `Core/ARSceneProjection.swift` | Verbatim. Needs only the `Vec3` typealias. |
| Camera API in `Services/OrbitModel.swift` (`setCamera`, `setViewport`, `panCamera`, `zoomCamera(by:anchor:)`, `resetCamera`, `alignAllViews`, the `cameras` dictionary, `defaultCamera(for:)`) plus `ViewCamera` | `Core/CameraState.swift` | Extract into a reusable value type or mixin. Keep the limits (zoom 0.25–6, pan ±1.5, pitch ±85, center 0.5/0.48) and the anchored-zoom math. `CameraViewportTests` ports almost unchanged. |
| Clock, persistence and lifecycle pattern in `OrbitModel` (`advanceFrame` with 0.1 s clamp, `lastTimestamp = nil` rebase, `step()` = 1/60 + pause, `setActive`, `invalidate()`/`redrawKey`, `scheduleSave()` 400 ms debounce, `save()` to a versioned UserDefaults key, `-ui-testing` reset) | Spectra model | Copy the pattern. Rename the key to e.g. `"Spectra.session.v1"`. |
| `OrbitalsApp.swift` | `SpectraApp.swift` | Verbatim shape: `@State` model, `.preferredColorScheme(.dark)`, `.tint(phosphor)`, scenePhase → `setActive`, `haptics.stop()`, `save()`. |
| `OrbitalsUITests` helpers (`launchPausedApp`, `requireHittable`, `wait`, `reveal`, `waitForFullVisibility`, `clockLabel`, `cameraState`) | `SpectraUITests/UITestSupport.swift` | Verbatim; move them into a shared helper file, since Orbitals duplicates them in each test class. |
| `project.yml` | `project.yml` | Adapt: name, bundle id `com.utkarsh.spectra`, usage descriptions for the new sensors, scheme. Keep iOS 27.0, Swift 6.0, strict concurrency complete, `MTL_FAST_MATH`, `CADisableMinimumFrameDurationOnPhone`, `UIUserInterfaceStyle: Dark`, `LaunchBackground` and `AccentColor`. |
| `Resources/Assets.xcassets` `AccentColor`, `LaunchBackground` | same | Verbatim if Spectra keeps the phosphor palette. |

**Needs adaptation (use as a structural template; the domain content changes):**

| Orbitals file | What to keep |
|---|---|
| `UI/DashboardView.swift` | NavigationStack with large title; top-left Dials and top-right info/sliders toolbar; scroll layout with the 16/26 gutters, 22/18 spacing and the 850 pt wide breakpoint (60% + 400 pt side column); segmented mode picker; glass horizontal tab selector with `scrollTo(.center)`; `safeAreaInset` transport with the scrim and accessibility-size variant; `fullScreenCover(item:)` + `sheet(item:)`; Space key. |
| `UI/VisualizationView.swift` | `VisualizationPanel` (header with Align + Expand, canvas height formula, radius 20/28, legend footer, contextual caption), `OrbitalCanvas` (Metal + annotation overlay + gestures + error overlay + full accessibility/keyboard surface), and `FullScreenVisualization` (header and footer layout, Move mode, zoom buttons, AR entry). Rename and rewire to Spectra's instruments. |
| `UI/MotionControls.swift` | The panel recipe: preset Menu → channel segmented + Link → editing indicator → explicit chips + live explanation → `GlassKnob` grid → footer hint. |
| `UI/ControlsView.swift`, `UI/TelemetryView.swift` | Numbered `InstrumentPanel` stacks; `CoordinatesTable` grid pattern (em-dash for gaps, per-cell accessibility labels); `FieldNotesView` with its `note()` helper and `Link` citations. |
| `Rendering/SceneGeometry.swift` | Keep the primitives (`add`, `dot`, `path`, `gradientPath`, `faded`, `nextDashOffset`, `viewportPoint`, `cyclicTrackColor`), the finite and capacity guards, signature-keyed caches, and `defer { snapshot = nil }`. Replace the five view builders with Spectra's: wave scope, spectrum, Fourier bins, antenna pattern, node graph. |
| `Core/HarmonicPreset.swift` | The enum shape (`title`, `ratioLabel`, `summary`, values, `sourceTitle`, `sourceURL`) and the derived "current preset" by value equality. A natural fit for Spectra's radio-generation and antenna-style presets. |
| `Core/TimelineMath.swift` (`TimelineRecorder`) | Fixed-grid recording, signature-based segments and bounded retention. Make it generic over the sample payload if Spectra records live sensor or RF history. |
| `AR/OrbitARController.swift`, `AR/OrbitalARView.swift`, `UI/OrbitARScreen.swift`, `Core/ARPlacementMath.swift` | The whole AR stack ports if Spectra places, for example, antenna radiation patterns in the room. Change strings, the anchor name, `referenceSpan` and `halfExtents` per view kind, and the source protocol. |
| `make-icon.swift`, `Documentation/Icon/README.md` | Icon generation and prompt-record pattern. |

**Not reusable (Orbitals domain math):** `Core/OrbitalMath.swift`, `Core/TorusMath.swift` (except `CameraMath.rotate`, which is generic), `Core/TrackMath.swift`, `Core/RetconMath.swift`, and the retcon, loop and timeline UI panels.
