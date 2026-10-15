# Design house rules: Tether, Subtext, Cipher, Blockdown

Research date: 3 October 2026. Sources are the files on disk under `/path/to/developer/Documents/AI Stuff/`. Nothing in those projects was modified. Orbitals and Gyre are covered in their own research notes. They are cited here only when they confirm or contradict a convention. SDK claims were checked against `Xcode-beta.app/.../iPhoneOS27.0.sdk`.

---

## 1. project.yml at a glance

| | Tether | Subtext | Cipher | Blockdown | (Orbitals / Gyre, for contrast) |
|---|---|---|---|---|---|
| Deployment target | `iOS: "27.0"`, `xcodeVersion: "27.0"` | `"26.0"` | `"26.0"` | `"26.0"` | 27.0 / 27.0 |
| `SWIFT_VERSION` | `"6.0"` | `"5.0"` | `"5.0"` | `"5.0"` | 6.0 / 5.0 |
| `SWIFT_STRICT_CONCURRENCY` | `complete` | not set | not set | not set | `complete` (target level) / not set |
| `ENABLE_USER_SCRIPT_SANDBOXING` | `YES` | not set | not set | not set | — |
| `DEVELOPMENT_TEAM` | `YOUR_TEAM_ID` | `YOUR_TEAM_ID` | `YOUR_TEAM_ID` | **absent** (passed on the command line) | `YOUR_TEAM_ID` |
| `bundleIdPrefix` | `com.utkarsh` | same | same | same | same |
| App bundle id | `com.utkarsh.tether` | `com.utkarsh.subtext` | `com.utkarsh.cipher` | `com.utkarsh.blockdown` | `com.utkarsh.orbitals` / `com.utkarsh.gyre` |
| Extension id | `com.utkarsh.tether.widgets` | `com.utkarsh.subtext.widget` | — | `com.utkarsh.blockdown.widget` | — |
| App Group | `group.com.utkarsh.tether` | none | none | none | — |
| Device family | `"1,2"` | `"1"` | `"1"` | `"1"` | `"1,2"` / `"1"` |
| Orientations | iPhone: portrait + both landscape; iPad: all four | portrait | portrait | portrait | — |
| `UIUserInterfaceStyle` | `Dark` | (system) | (system, but `.preferredColorScheme(.dark)` in code) | (system) | Dark / Dark |
| Info.plist style | `info: path + properties` | `info:` | `info:` | `INFOPLIST_FILE` + `INFOPLIST_KEY_CFBundleDisplayName` | `info:` |
| Global accent | — (`.tint(TetherTheme.violet)` in code) | `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor` | same | same | — |
| iCloud xattr strip | no (builds with `-derivedDataPath /private/tmp/...`) | `postCompileScripts: /usr/bin/xattr -cr "$TARGET_BUILD_DIR/$WRAPPER_NAME" \|\| true` on app and widget | same, app only | no | — |
| Test targets | `TetherTests` (`bundle.unit-test`) + `TetherUITests` (`bundle.ui-testing`), both `GENERATE_INFOPLIST_FILE: YES`, in an explicit `schemes:` block | none | none | none | Orbitals: unit + UI tests |
| Versions | `MARKETING_VERSION "1.0"`, build `"1"` | `"0.1"`, `"1"` | `"0.1"`, `"1"` | `"1.4"`, `"5"` | — |

Common keys in every `info:` block: `CFBundleDisplayName`, `UILaunchScreen: {}`, and `ITSAppUsesNonExemptEncryption: false` (Blockdown's plist omits it). Every widget extension uses `NSExtensionPointIdentifier: com.apple.widgetkit-extension` and `SKIP_INSTALL`. Tether also sets `APPLICATION_EXTENSION_API_ONLY: YES`.

---

## 2. Per-app findings

### Tether (`/path/to/developer/Documents/AI Stuff/Tether`)

The newest app and the closest match to Orbitals, which its README says it follows.

- **Root**: `TetherApp` has `@State private var model = TetherModel()` (`@MainActor @Observable final class`). It applies `.preferredColorScheme(.dark)`, `.tint(TetherTheme.violet)`, `.task { await model.load() }` and `.onOpenURL { model.handle($0) }`.
- **Tab bar**: `TabView(selection: $model.tab)` with the iOS 18+ `Tab("Reading", systemImage: "sparkles", value: 0)` API. The four tabs are Reading, Explore, Us and Cycles. Each tab is wrapped by a helper `navigation(title)` that builds a `NavigationStack` with an inline title. The same two toolbar buttons appear on every tab: `info.circle` "Model & sources" (`.topBarLeading`) and `slider.horizontal.3` "Birth times & settings" (`.topBarTrailing`), both `.labelStyle(.iconOnly)`. Tab titles are nouns, and the navigation titles are evocative phrases ("Space & time", "A shared orbit", "Time within time").
- **Sheets**: a single enum drives all of them: `enum TetherSheet: String, Identifiable { case time, settings, methodology }`, presented with `.sheet(item: $sheet)` and a `switch`. No detents are set, so every sheet is full height. Each sheet owns a `NavigationStack`.
- **Settings** (`UI/SettingsView.swift`): a `Form`, titled "Your sky", inline. It uses the **draft pattern**: values are copied into `@State` in `init`, and the toolbar has `.cancellationAction` "Cancel" and `.confirmationAction` "Save", which writes back and calls `model.persist()`. Sections: "Zodiac reference" (picker plus a footnote explanation), one section per person, **"Feel"** (`Toggle("Tactile feedback")`, persisted to `UserDefaults` key `"haptics"`), "Home Screen widgets" (how to add one), and **"Private by design"**. A UI test asserts that Cancel preserves the saved values.
- **Methodology sheet** (`UI/MethodologyView.swift`, "How Tether works"): an `Eyebrow` and a serif hero headline, then a stack of `Surface` cards, each with an SF Symbol, a title and an honest explanation, then a "Read the sources" card of `Link` rows. It ends with a licence and endorsement disclaimer. This is the in-app "what is real and what is metaphor" page.
- **Components** (`UI/TetherTheme.swift`):
  - `Surface`: padding 20, `TetherTheme.panel.gradient`, corner radius 26, a 1 pt stroke of `accent.opacity(0.16)`.
  - `Eyebrow`: uppercased `.caption2.weight(.bold)` with `.tracking(2)`.
  - `PillAction`: `.glass` or `.glassProminent` with `.buttonBorderShape(.capsule)`; it fires a haptic before its action.
  - Grouped pills sit inside a `GlassEffectContainer`.
  - Palette: background `rgb(0.025, 0.031, 0.065)`, panel `(0.065, 0.073, 0.13)`, mint, rose and violet accents.
- **Loading**: a full-screen overlay while `model.engine == nil`, with `ProgressView("Opening your sky…")`. On error it shows the message and a `.glassProminent` "Try again" button.
- **Motion and lifecycle**:
  - `@Environment(\.accessibilityReduceMotion)` with `.transaction { if reduceMotion { $0.animation = nil } }`.
  - Playback runs in `.task(id: model.playing && phase == .active)` on a 100 ms `Task.sleep` loop, with the delta clamped to `min(0.25, seconds)`.
  - Leaving `.active` stops playback and haptics.
- **Haptics**: `Services/OrbitalHaptics.swift` (the name is borrowed from Orbitals) is a CoreHaptics singleton. It checks `CHHapticEngine.capabilitiesForHardware().supportsHaptics`, rate-limits pulses, only plays while the app is `.active`, and exposes `tap() / selection() / beginAdjustment() / detent(normalized:) / endAdjustment() / boundary() / success() / stop()`.
- **Accessibility** (the strongest of the four apps):
  - The Metal canvas uses `.accessibilityElement(children: .ignore)` with a descriptive label.
  - Its `accessibilityValue` reads the camera state ("Azimuth … degrees, tilt …, zoom … percent").
  - `.accessibilityAdjustableAction` rotates the camera.
  - Named actions are "Zoom in", "Zoom out" and "Reset camera".
  - Decorative symbols are hidden.
  - Every control a test touches has an `accessibilityIdentifier` (`"cosmicCanvas"`, `"playTimeline"`, `"mode_<id>"`, `"selectedEpoch"`…).
- **Widget** (`TetherWidgets/TetherDailyWidget.swift`):
  - `AppIntentConfiguration` with `WidgetConfigurationIntent`.
  - The person parameter is a **`String` with a `DynamicOptionsProvider`**. A code comment explains why: it avoids "an iOS 27 AppEnum resolver failure".
  - `.containerBackground(for: .widget)` and `.widgetURL(entry.url)` with the `tether://reading?person=…&date=…` scheme, declared via `CFBundleURLTypes`.
  - `.supportedFamilies([.systemSmall, .systemMedium])`, timeline `policy: .atEnd` with eight daily entries.
  - Shared state lives in `UserDefaults(suiteName: "group.com.utkarsh.tether")`. The app calls `WidgetCenter.shared.reloadAllTimelines()` after saving.
- **Tests**: XCTest only. 22 hosted unit tests (`@MainActor final class …: XCTestCase`, `@testable import Tether`, `Bundle(for: TetherModel.self)`) and four XCUITest flows.
  - UI-test helpers: `launchLoadedApp()`, `requireHittable`, `wait(predicate, on:, message:, timeout: 8)`, `revealVertically` (scrolls until the control is inside a `safeViewport` clear of the navigation and tab bars), `revealHorizontally`, and `attach(app, name)` (screenshots kept with `.keepAlways`).
  - There are no launch arguments; tests wait up to 30 s for real data to load.
- **Docs**:
  - `README.md` is a pitch naming the frameworks ("SwiftUI presents iOS 27 Liquid Glass controls, Metal draws…, Core Haptics…, WidgetKit…; there is no web view"), then `## Run`, `## Four spaces` (one bullet per tab), `## What is calculated—and what is interpreted`, `## Privacy and efficiency` and `## Verification and sources`. Its last line states that the source apps are unchanged.
  - `VERIFICATION.md` is titled "Tether verification — 2 October 2026", with sections `## Native builds` (Xcode build id `27A5194q`, exact `xcodebuild` command, log paths), `## Numerical, projection and model tests` (count passed, bullet per area, `.xcresult` path), `## Native interaction tests` (numbered flows, plus the sentence "No app state assertion was weakened to hide a failure"), `## Widget and visual checks` and `## Remaining practical limits`.
  - `Documentation/RESEARCH.md` ("Research checked on October 2, 2026") holds sources and limits. `Documentation/Screenshots/*.jpg` and `Documentation/make-icon.swift` sit alongside it.
- **Permissions**: none. Tether is offline, and its plist has no usage strings.

### Subtext (`/path/to/developer/Documents/AI Stuff/Subtext`)

- **No tab bar.** There is one `NavigationStack(path:)`, a `List` of tracks, `.navigationDestination(for: SubtitleTrack.self)`, and a **mini-player**: `.safeAreaInset(edge: .bottom)` holds a "now showing" bar styled `.glassEffect(.regular, in: .rect(cornerRadius: 18))` that pushes the session back on tap.
- **Toolbar**: `gearshape` Settings at `.topBarLeading`, and search plus `doc.badge.plus` import in a `ToolbarItemGroup(.topBarTrailing)`.
- **Empty state**: `ContentUnavailableView { Label("No subtitles yet", systemImage: "captions.bubble") } description: {…} actions: { Button("Search OpenSubtitles").buttonStyle(.borderedProminent); Button("Import a file") }`. This replaces onboarding.
- **Settings**: a `Form` titled "Settings", inline, with a single `.confirmationAction` "Done". Values apply live (`onChange` writes to the Keychain). Sections use `header:` and `footer:` (footer copy explains why a key is needed). The last section is **"Privacy"**: *"Subtext listens through the microphone … No audio or text ever leaves the device. The orange microphone dot stays on while a session runs."* Session options (auto-sync, speech, Live Activity, speed-watching, audio language) are `Toggle`s on the Now Playing screen, not in Settings.
- **Microphone permission** is requested just in time:
  - The trigger is opening a track. `NowPlayingView.onAppear` calls `session.start` → `SyncEngine.start` → `await AVAudioApplication.requestRecordPermission()`.
  - If denied, nothing is shown modally. The status card's detail line reads "Microphone access is needed to follow what is playing." There is no Settings deep link.
  - Speech-model assets download through `AssetInventory.assetInstallationRequest(supporting:)`.
- **Usage strings** (`project.yml`):
  - `NSMicrophoneUsageDescription`: "Subtext listens to the room so it can keep subtitles in step with what is playing. Audio is analysed on this phone and never leaves it."
  - `NSSpeechRecognitionUsageDescription`: "Subtext recognises a few spoken words on this phone to find where you are in the subtitles. Nothing is sent anywhere."
- **Live state UI**:
  - `SyncPhase` (`listening/searching/locked/drifting/manual/paused`) carries `.label` and `.symbol` (`ear`, `waveform.badge.magnifyingglass`, `checkmark.circle.fill`, …).
  - The status card shows the phase symbol, label, a human detail line and a 5-bar `MicMeter` (`accessibilityLabel("Microphone level")`).
  - Detail copy: "In step with the room.", "Lost the thread for a moment, widening the search.", "Timing is yours."
  - Cards use `.glassEffect(.regular, in: .rect(cornerRadius: 18))`. `TimelineView(.periodic(from: .now, by: 0.1))` drives the readout.
- **Manual override**: "Manual controls always win" (README). There is a `ScrubWheel` that clicks `UISelectionFeedbackGenerator` every 0.1 s tick, with `accessibilityAdjustableAction` and `accessibilityValue(value.trimLabel)`. Capsule `.bordered` steppers offer −1s, −½, −.1, +.1, +½ and +1s.
- **Sheets**: `SeekSheet` uses `.presentationDetents([.medium])`. Settings and Search are full height.
- **Live Activity** (`Playback/LiveActivityController.swift`, `SubtextWidget/SubtextLiveActivity.swift`): see house rule 9. It adds `.supplementalActivityFamilies([.small])` for Apple Watch (verified in the iOS 27 WidgetKit swiftinterface) and `LiveActivityIntent` buttons (`NudgeSyncIntent`, `ResyncIntent`, `TogglePauseIntent`, all with `isDiscoverable = false`). The buttons route through `SyncCommandRelay.handler`, which is registered in `SubtextApp.init`, with a 120 ms double-fire guard. The plist sets `NSSupportsLiveActivities` and `NSSupportsLiveActivitiesFrequentUpdates` to true, and `UIBackgroundModes: [audio]`.
- **Theme**: `Color.subtextTheme = Color("SubtextTheme")` (a warm amber) lives in `Shared/SharedAssets.xcassets`. A comment explains it: "so WidgetKit's archived views keep it". The app follows the system appearance.
- **Logging**: a file-private `Logger(subsystem: "com.utkarsh.subtext", category: "Audio" | "Sync" | "Session" | "LiveActivity" | "Speech" | "Library")`.
- **Testing**: no Xcode test targets.
  - `Tools/synctest.sh` (zsh) compiles the app's own `Sync/*.swift` and `Models/SubtitleTrack.swift` with `swiftc -O` into a macOS CLI. It synthesises a film with `say` and runs scenarios.
  - DEBUG launch arguments: `-importSubtitles /path/file.srt` and `-recordMic` (writes 40 s to `Documents/mic.caf`). Both are inside `#if DEBUG`.
- **README**: pitch, `## How sync works` (a numbered pipeline, each step naming its file), `## Build` (an exact `xcodegen generate` and `xcodebuild … -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` block, plus the device command `-allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID` and `xcrun devicectl device install app`), debug launch arguments, `## Sync test harness`, `## OpenSubtitles` (licensing), and `## Real-room test` (a manual protocol).

### Cipher (`/path/to/developer/Documents/AI Stuff/Cipher`)

**No README exists**, at the root or under `Views/`. The only Markdown is `Tools/culture/TAGGING.md`, and the architecture is recorded in the user's memory notes.

- **Root**: `CipherApp` uses `.environment(model)` (`AppModel` is `@Observable`), `.preferredColorScheme(.dark)`, `.tint(Theme.accent)` and `.modelContainer(for: [Song.self, MeaningNote.self, ChainRecord.self])` (SwiftData). `RootView` switches on `model.phase`:
  - `.loading` shows a `ProgressView` with "Loading the dictionary".
  - `.failed` shows `ContentUnavailableView("Couldn't start", systemImage: "exclamationmark.triangle", …)`.
  - `.ready` shows the `TabView`.
- **Tabs**: `Tab("Write", systemImage: "pencil.line", value: AppTab.write)`, then Sphere (`circle.hexagonpath`), Lab (`waveform`) and Bridge (`arrow.triangle.merge`). The selected tab is **persisted**: `var tab … { didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") } }`.
- **Settings** (`Views/SettingsView.swift`): a `Form` titled "Settings", inline, with "Done" only and live-applied values. Every section has a `header:` and a **long, plain-language `footer:`**. The sections are:
  - Languages: toggles plus up/down reorder buttons with `.labelStyle(.iconOnly)`.
  - Culture: custom weight rows (title, a monospaced value, a caption, then a `Slider`).
  - Claude: a `SecureField("sk-ant-...")` that saves to the Keychain; footer: "…Everything else in Cipher runs on this phone."
  - Rhymes.
  - About: a dense credits paragraph with every dataset licence.
- **Settings is reachable from several screens**: `.sheet(isPresented: $showSettings) { SettingsView() }` is attached in SongsView, LabView, BridgeView and AssistSheet. A feature that needs a key links straight to it.
- **Sheets and detents**:
  - Tool sheets: `.presentationDetents([.medium, .large])` (AssistSheet, the delivery bar card, `WorkSheet` in CultureViews).
  - The "sticky" sphere (`Views/OrbitView.swift`): `.presentationDetents([.medium, .large], selection: $detent)`, `.presentationBackgroundInteraction(.enabled(upThrough: .medium))` and `.presentationDragIndicator(.visible)`. A toolbar button toggles "Full screen"/"Smaller" by setting `detent`. "Done" is `.fontWeight(.semibold)`. An `ellipsis.circle` `Menu` at `.topBarLeading` holds secondary actions, including a `role: .destructive` "Start over".
  - From the user's memory notes: the first modal felt "janky", and the fix was this NavigationStack sheet with normal swipe-to-dismiss and sideways-only drag gestures on the canvas.
- **Permissions**: each is requested just in time, on the tap that needs it. Nothing is requested at launch.
  - Music library: `MPMediaLibrary.requestAuthorization` runs when the user taps "From your music library" or "Playing now in Music".
  - Microphone: `AVAudioApplication.requestRecordPermission()` runs when the user taps "Record a take".
  - Speech: `SFSpeechRecognizer.requestAuthorization` runs only on the legacy fallback path when `SpeechTranscriber` is unavailable.
  - On denial, an alert appears: `.alert("Couldn't use that", isPresented: Binding(get: { problem != nil }, …))` with the message "Cipher was not allowed to use the microphone. You can change that in Settings." There is no deep-link button.
- **Usage strings**:
  - "Cipher reads songs from your music library so it can write out their lyrics as bars."
  - "Cipher listens to a recording on this device to write out its lyrics."
  - "Cipher records a take so it can write out the words and read how they were delivered."
- **Components** (`Views/Theme.swift`):
  - `Theme.ink` `rgb(0.047, 0.047, 0.063)`, `Theme.panel` `white 6%`, `panelStroke` `white 9%`, accent lime `rgb(0.78, 0.96, 0.20)`, and an 8-colour highlighter palette.
  - `SectionCard` (radius 20, `.continuous`), `WordChip` (capsule; opacity scales with strength), `FlowLayout` (a custom `Layout`).
  - Glass surfaces: `.glassEffect(.regular, in: .rect(cornerRadius: 20|22))` and `.regular.tint(accent)` for the selected state.
- **Responsiveness**: `.task(id:)` with `Task.sleep` debounce (160 ms for analysis, 250 ms for the culture lookup, 180 ms for typing in the sphere).
- **Simulator fake**: `#if targetEnvironment(simulator)` loads a sidecar `<name>.words.json` from Documents in place of speech recognition, because the simulator has none.
- **Engine purity**: `Cipher/Engine/` uses only Foundation and NaturalLanguage, so `Tools/build_lexicon.sh` compiles Engine sources together with `Tools/lexgen/*.swift` via `swiftc -O`. `Tools/build_lexicon.sh eval` scores the readers. There are no Xcode test targets.
- **Accessibility**: minimal. There are about two modifiers in `Views/`.
- **Repo hygiene**:
  - `.gitignore` excludes `Cipher.xcodeproj/` (generated), `Tools/data/`, and **`* 2.*` / `* 2/`** (iCloud conflict copies). `Cipher 2.xcodeproj` is still present on disk.
  - The git database lives outside iCloud: `--separate-git-dir=/path/to/developer/Developer/git/Cipher.git` (per the user's memory notes).
  - The app icon comes from `Tools/make_icon.swift`, which draws an exact 1024 px `CGContext` with `noneSkipLast` ("actool rejects anything else").

### Blockdown (`/path/to/developer/Documents/AI Stuff/Blockdown`)

- **Tabs**: `TabView { Tab("Timer", systemImage: "timer") {…}; Tab("History", systemImage: "clock.arrow.circlepath") {…} }`, with no selection binding. Each tab has its own `NavigationStack` and a large title ("Blockdown", "History").
- **No Settings screen.** Settings live where they act:
  - A `PhysicalToggleRow("Live Activity")` on the setup screen.
  - An `ellipsis.circle` `Menu` in the toolbar while running, holding Edit Timer, Restart Timer, `Divider()`, and a `Toggle` labelled `Label("Live Activity", systemImage: "bolt.badge.clock")`.
- **Physical controls**:
  - `CircleControlButton` is 88×88 pt with `.glassEffect(.regular.tint(tint.opacity(0.28)).interactive(), in: .circle)`. It follows the system Clock app: Cancel/Pause, Cancel/Resume, Done/Restart.
  - `AdjustChip` and `PresetChip` are capsules with `.regular.tint(theme.opacity(0.15)).interactive()`.
  - `PhysicalToggleRow` replaces `Toggle`. The comment says the stock control's "small hit target proved unreliable". The whole row is the button, with a spring knob, `.sensoryFeedback(.impact(weight: .medium), trigger: isOn)`, `.accessibilityAddTraits(.isToggle)` and `.accessibilityValue(isOn ? "On" : "Off")`.
- **Sensor-driven visuals** (`Support/FluidMotion.swift`), directly relevant to Spectra:
  - A `@MainActor @Observable` class runs `CMMotionManager` device motion at `1.0/60.0`. Gravity sets the pool angle, `userAcceleration` adds slosh, and an under-damped spring (stiffness 22, damping 3.6/s) settles it.
  - `start()` runs in `.onAppear` and `stop()` in `.onDisappear`.
  - When `!manager.isDeviceMotionAvailable` (the simulator), it drives itself with a **synthetic signal**: `π/2 + 1.1·sin(1.1t) + 0.3·sin(2.7t)`. No flag is needed.
  - Blockdown declares **no** `NSMotionUsageDescription`. That matches the SDK: `CMMotionManager.h` has no authorization API, while `CMAltimeter.h:57` declares `+authorizationStatus`. That is why Gyre, which reads the barometer, declares one.
- **Notifications**: `requestAuthorization(options: [.alert, .sound])` is called inside `TimerEngine.start()`, so the prompt appears on the first Start tap, not at launch. The result is ignored. A foreground banner is shown via `willPresent` returning `[.banner, .sound]`. `interruptionLevel = .timeSensitive`.
- **Sheets**: `EditTimerSheet` uses `.presentationDetents([.medium, .large])`, with "Cancel" (`.cancellationAction`) and "Done" (`.confirmationAction`, which commits the rename).
- **Destructive actions**: the History toolbar has `Button("Clear", role: .destructive)`, which opens `.confirmationDialog("Clear all history?", titleVisibility: .visible)`. Swipe `.onDelete` is also available.
- **Empty state**: `ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath", description: Text("Finished and stopped timers will show up here."))`.
- **Numbers**: `.font(.system(size: 56, weight: .thin)).monospacedDigit().contentTransition(.numericText(countsDown: true))`, driven by `TimelineView(.periodic(from: .now, by: 1.0))`.
- **Theme**: `Color.blockdownTheme = Color("BlockdownTheme")` in `Shared/SharedAssets.xcassets`, red in light mode and aqua in dark. The comment says asset colours "are the only dynamic colors that survive" WidgetKit archiving. The app adapts to light and dark.
- **Persistence**: a JSON snapshot in `UserDefaults` for the engine, and a JSON file in Documents for history.
- **Testing**: none in Xcode. A DEBUG launch argument, `xcrun simctl launch booted com.utkarsh.blockdown -autostart 60`, is parsed from `ProcessInfo.processInfo.arguments` in `App.init` inside `#if DEBUG`.
- **README**: pitch, `## Features` bullets, `## Project layout`, `## Building`, `### Simulator test hook (DEBUG only)`.

---

## 3. House rules (hold across his apps)

1. **XcodeGen is the source of truth.** Every app has `project.yml` with `bundleIdPrefix: com.utkarsh` and `createIntermediateGroups: true`, regenerated with `xcodegen generate`. Bundle ids are `com.utkarsh.<lowercased name>`; extensions are `<app>.widget` and App Groups are `group.com.utkarsh.<app>`. Team `YOUR_TEAM_ID`, `CODE_SIGN_STYLE: Automatic`. `UILaunchScreen: {}` and `ITSAppUsesNonExemptEncryption: false`.
2. **Native SwiftUI on the latest OS. No web views, no onboarding.** First launch opens straight into the instrument or list. An empty or first-run state is a `ContentUnavailableView` with a label, a one-sentence description of what to do, and one or two action buttons (Subtext, Cipher, Blockdown, Orbitals). No app uses TipKit or a welcome carousel.
3. **Permissions are just in time, on the tap that needs them, never at launch.** No app shows a priming screen first. The tapped control *is* the explanation: "Record a take", "From your music library", opening a track to start listening, Start on a timer.
4. **Usage-description voice**: `"<App> <verb>s … so it can <benefit>."` followed by a privacy sentence when data is sensitive: "Audio is analysed on this phone and never leaves it." / "Nothing is sent anywhere." / "Nothing is recorded or kept." (Gyre). Plain words, the app's name as the subject, no "we", no "in order to".
5. **Settings is a `Form` in a sheet with its own `NavigationStack` and an inline title.**
   - Apply-live settings get a single `.confirmationAction` "Done" (Subtext, Cipher). Draft edits get "Cancel" + "Save"/"Done" (Tether Settings, Blockdown Edit).
   - Every non-obvious control has a plain-language `footer:`.
   - There is always an explicit **privacy** section or footer stating what stays on the phone: Tether "Private by design", Subtext "Privacy", Cipher's Claude footer.
   - Credits and licences go in an About section or the methodology sheet.
   - The settings entry point is a toolbar icon button (`gearshape` or `slider.horizontal.3`).
6. **Live, frequently used controls stay on the main surface, not in Settings.** Examples: Subtext's session toggles on Now Playing, Blockdown's Live Activity toggle on the setup screen and in the ⋯ menu, Tether's playback controls.
7. **Tool sheets use `[.medium, .large]` detents. Settings and import flows are full height.** A sheet the user works *alongside* keeps the content beneath interactive: `.presentationBackgroundInteraction(.enabled(upThrough: .medium))` + `.presentationDragIndicator(.visible)` + a `selection:` binding with a "Full screen"/"Smaller" toolbar toggle (Cipher Orbit).
8. **Tab bars use the `Tab(_:systemImage:value:)` API with 2–4 tabs, one `NavigationStack` per tab.** Tab labels are one word. Secondary actions live in an `ellipsis.circle` `Menu`. Subtext, a single-purpose app, has no tabs and uses a bottom `.safeAreaInset` glass mini-bar instead.
9. **Live Activity controller pattern** (Blockdown and Subtext are near-identical):
   - A `@MainActor final class LiveActivityController` with a `hasActivity` flag that is true only when `activityState == .active`.
   - `reattach()` on relaunch.
   - `start` guards `ActivityAuthorizationInfo().areActivitiesEnabled`, logs a warning and skips silently when disabled, and ends stray activities first ("Never stack activities").
   - `update` re-requests the activity if the user swiped it away.
   - `end` uses `.immediate` for cancel and `.default` for completion.
   - Attributes live in `Shared/` and compile into both targets.
   - The activity is user-toggleable.
   - Styling: `.activityBackgroundTint(Color.black.opacity(0.72–0.78))`, `.activitySystemActionForegroundColor(theme)`, `.keylineTint(theme)`. The compact-leading slot shows an SF Symbol in the theme colour and the compact-trailing slot shows a `.monospacedDigit()` value capped with `.frame(maxWidth:)`.
10. **Theme colours that a widget or Live Activity renders must come from an asset catalog** (`Shared/SharedAssets.xcassets`, `Color("<App>Theme")`), because WidgetKit's view archiving drops programmatic dynamic colours. Each app has **one** signature accent, applied with `.tint(...)` at the root.
11. **Liquid Glass is the control material.**
    - Cards: `.glassEffect(.regular, in: .rect(cornerRadius: 16–22))`.
    - Primary buttons: `.buttonStyle(.glassProminent)`; secondary: `.buttonStyle(.glass)`.
    - Toggled or selected state: `.regular.tint(accent.opacity(0.12–0.28))`.
    - Physical buttons and chips: `.interactive()`.
    - Grouped pills: `GlassEffectContainer`.
    - Numeric readouts are always `.monospacedDigit()` or `.monospaced()`.
12. **Hit targets and feel matter more than stock controls.** Blockdown replaced `Toggle` with a full-row `PhysicalToggleRow`, and Tether's UI tests had to work around the stock switch-thumb hit area. Every physical-feeling control gives haptic feedback:
    - Blockdown: `.sensoryFeedback`.
    - Subtext: `UISelectionFeedbackGenerator` on each tick.
    - Tether and Orbitals: a rate-limited CoreHaptics singleton.
    - Haptics have a user toggle where they are rich (Tether "Feel" section, `UserDefaults` key `"haptics"`).
13. **The human always wins over automation.** "Manual controls always win" (Subtext README). Auto-sync, auto-detected language and sensor-driven state all have a manual override in the UI, and the phase/status is shown as a symbol plus a one-line human sentence.
14. **Sensors start on appear, stop on disappear, and degrade to a synthetic signal in the simulator.**
    - Automatic fallback: Blockdown `FluidMotion` when `!isDeviceMotionAvailable`.
    - Compile-time fallback: Cipher `#if targetEnvironment(simulator)` sidecar.
    - Launch-argument fallbacks: Gyre `-fakeMic`, `-fakeAR`, `-simSway`; Orbitals `-ui-testing`.
    - Tether stops work when `scenePhase != .active`.
15. **The algorithmic core is UI-free so it can run headless**: Cipher `Engine/` (Foundation + NaturalLanguage), Subtext `Sync/` (compiled to a macOS CLI by `Tools/*.sh`), Tether `Shared/Core` (shared with the widget, unit-tested).
16. **Simulator and test hooks are launch arguments with a leading single dash, parsed from `ProcessInfo.processInfo.arguments`/`CommandLine.arguments`, documented in the README** (`-autostart 60`, `-importSubtitles <path>`, `-recordMic`).
17. **State architecture**:
    - Models are `@MainActor @Observable final class`.
    - They are held in `@State` at the App root and injected with `.environment(model)` (Cipher, Blockdown) or passed as `@Bindable` (Tether).
    - Small preferences persist through `didSet { UserDefaults.standard.set(...) }`.
    - Secrets go in the Keychain.
    - Logging uses a file-private `Logger(subsystem: "com.utkarsh.<app>", category: "<Area>")`.
18. **Errors are surfaced, never swallowed silently in the UI.**
    - `.alert("<Couldn't …>", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }))` with the message as `Text`.
    - Inline status text for continuous processes (Subtext).
    - Full-screen `ContentUnavailableView` with "Try again" for load failures (Tether, Cipher).
19. **Honesty is a design feature.** Each app separates what is measured from what is approximated or metaphorical:
    - Tether's README section "What is calculated—and what is interpreted" and its in-app "How Tether works" sheet (`info.circle`, with sources).
    - Subtext's "Real-room test" and its notes on what is not verified.
    - VERIFICATION.md's "Remaining practical limits".
    - Licences are credited in-app.
20. **Docs**:
    - README: pitch (frameworks named) → Run/Build with exact commands → one section per feature or tab → how it works with file paths → simulator hooks → privacy → verification pointer.
    - `VERIFICATION.md` (Tether, Orbitals): dated title, build command and log paths, test counts and `.xcresult` paths, numbered UI flows, honest failure history, device-only limits.
    - Research goes in `Documentation/RESEARCH.md` with a "checked on" date. App icons are drawn by a `make-icon.swift`/`make_icon.swift` script at exactly 1024 px with no alpha.
21. **Device builds** run headless: `xcodebuild -destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=""; it must be unlocked). Because the projects live in iCloud-synced `~/Documents`, builds use a `-derivedDataPath` outside iCloud (scratchpad or `/private/tmp`).
22. **Tests are XCTest only.** No app imports `Testing`. Where UI tests exist they use `accessibilityIdentifier`s, predicate waits, scroll-into-safe-viewport helpers, and `XCTAttachment(screenshot:)` with `.keepAlways`.

---

## 4. Contradictions between apps (pick deliberately for Spectra)

| Topic | Variants | Recommendation for Spectra |
|---|---|---|
| Deployment target / Swift | iOS 27 + Swift 6 + `SWIFT_STRICT_CONCURRENCY: complete` (Tether, Orbitals) vs iOS 26 + Swift 5 (Subtext, Cipher, Blockdown); Gyre is iOS 27 + Swift 5 | Follow Orbitals/Tether: `iOS: "27.0"`, `xcodeVersion: "27.0"`, Swift 6, strict concurrency complete. Budget for audio-tap and CoreMotion callbacks off the main actor. Subtext's `nonisolated(unsafe)` relay would not pass review under Swift 6. |
| Appearance | Forced dark (`UIUserInterfaceStyle: Dark` + `.preferredColorScheme(.dark)`: Tether, Orbitals, Gyre, Cipher) vs system light/dark (Subtext, Blockdown) | The instrument apps (Orbitals, Gyre, Tether) are dark only. Spectra is an instrument, so use forced dark. |
| Theme colour definition | Swift constants in an `enum Theme` (Tether, Cipher) vs asset-catalog `Color("XTheme")` (Subtext, Blockdown) | Use Swift constants for in-app palette tokens, but any colour used in a widget or Live Activity must be an asset colour. |
| Settings commit model | Live-apply + "Done" (Subtext, Cipher) vs draft + Cancel/Save (Tether, Blockdown Edit) | Live-apply for instrument toggles; draft only for multi-field records. |
| Settings entry point | `gearshape` at `.topBarLeading` (Subtext, Cipher) vs `slider.horizontal.3` at `.topBarTrailing` plus `info.circle` methodology at leading (Tether) vs no settings screen (Blockdown) | Follow Tether: `info.circle` "How Spectra works" on the left, settings on the right. Spectra needs a methodology sheet to separate measured, simulated and metaphor. |
| Permission denial UX | Inline status sentence, no link (Subtext); alert telling the user to "change that in Settings", no link (Cipher); `ContentUnavailableView` + "Open Settings" `.glassProminent` button using `UIApplication.openSettingsURLString` (Orbitals); silent ignore (Blockdown notifications, Live Activities) | Use the Orbitals version in place, for each sensor panel: explain, then offer Open Settings, and keep the simulated mode working. |
| Device family / orientation | iPhone-only portrait (Subtext, Cipher, Blockdown, Gyre) vs universal with landscape (Tether, Orbitals) | His device is an iPhone. Choose iPhone-only portrait unless the Fourier scope needs landscape. |
| Test strategy | Full unit + UI test targets and VERIFICATION.md (Tether, Orbitals) vs no test targets but a CLI harness (Subtext, Cipher) vs nothing (Blockdown) | Combine: unit tests for the DSP/RF math, UI tests with identifiers, plus launch-argument fakes for every sensor. |
| Launch-argument gating | Inside `#if DEBUG` (Subtext, Blockdown) vs always on (Gyre `-fakeMic`, Orbitals `-ui-testing`) | Gate fakes behind `#if DEBUG`, except a `-ui-testing` reset if UI tests run against Release. |
| Info.plist authoring | `info: properties:` (most) vs hand-written plist + `INFOPLIST_KEY_*` (Blockdown) | Use `info: properties:`, so usage strings live in `project.yml`. |
| iCloud xattr workaround | `postCompileScripts xattr -cr` (Subtext, Cipher, Stupid App) vs `-derivedDataPath` outside iCloud (Tether, per the user's memory notes) | Prefer `-derivedDataPath` outside iCloud. Tether also sets `ENABLE_USER_SCRIPT_SANDBOXING: YES`; whether an undeclared-output script works under that setting was not checked, so do not combine the two blindly. |
| Generated `.xcodeproj` | Gitignored (Blockdown, Cipher, Subtext) vs "the generated project is included" (Tether README) | Gitignore it, and also add `* 2.*` / `* 2/` for iCloud conflict copies (Cipher, Orbitals both have `… 2.xcodeproj` on disk). |
| Extension naming | `.widget` (Subtext, Blockdown, Stupid App) vs `.widgets` (Tether) | `.widget` (majority). |
| Haptics API | CoreHaptics singleton (Tether, Orbitals) vs `UISelectionFeedbackGenerator` (Subtext) vs `.sensoryFeedback` (Blockdown) | Use a CoreHaptics singleton for continuous or tuning detents (tuner, frequency dials), with a user toggle under "Feel"; `.sensoryFeedback` for simple toggles. |
| Spelling | British in Subtext and Cipher copy ("analysed", "recognises", "favour") vs American in Tether ("personalized", "color") | Pick one and stay consistent. His newest copy (Subtext and Cipher, Oct 2026) leans British. |
| Accessibility depth | Thorough (Tether: canvas labels, values, adjustable and named actions, reduce-motion transaction; Orbitals tests XXXL Dynamic Type via `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`) vs minimal (Cipher, Blockdown) | Follow Tether and Orbitals: every Canvas/Metal view gets a label, a live value, adjustable and named actions, and reduce-motion handling. |
| README presence | Every app except Cipher | Ship README.md + VERIFICATION.md + Documentation/RESEARCH.md. |

---

## 5. Direct implications for Spectra's sensor work

- Request each sensor's permission when its panel's live mode is first switched on. The panel opens in simulation, and a "Go live" control triggers the prompt (rule 3). Write each usage string in the rule 4 voice. For example, microphone: "Spectra listens to draw the sound around you as a live spectrum. Audio is analysed on this phone and never leaves it."
- Device motion via `CMMotionManager` needs no usage string. `CMAltimeter`, pedometer and activity APIs do need `NSMotionUsageDescription`, because they have `authorizationStatus` (verified in `CoreMotion.framework/Headers/CMAltimeter.h:57`).
- Follow the `FluidMotion` pattern for each live source: `start()`/`stop()` tied to view appear/disappear and `scenePhase`, and an automatic synthetic signal when the hardware is unavailable. Also add DEBUG launch arguments (`-fakeMic`, `-fakeMotion`, …) so UI tests and simulator screenshots are deterministic.
- Show a status pill for each live source (Subtext's `SyncPhase` pattern: `.label` and `.symbol`, plus a one-line human detail), and a manual override for every automatic reading.
- If Spectra gets a Live Activity or widget, copy the `LiveActivityController` pattern and use asset-catalog theme colours.
