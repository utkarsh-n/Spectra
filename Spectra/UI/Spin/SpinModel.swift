import Foundation
import Observation
import simd

/// "Open in Lab" hook: the Spectrum tab opens its Spectroscopy lab in the NMR sample's
/// "Earth field (live |B|)" mode. The spectrum owner (or integration) adds the conformance,
/// e.g. `extension SpectrumModel: SpinEarthFieldLab { func openEarthFieldLab() { … } }`.
/// Without it, Spin falls back to `AppModel.focus` and a toast.
@MainActor
protocol SpinEarthFieldLab: AnyObject {
  func openEarthFieldLab()
}

/// A panel the Spin content scrolls to (`spin-anchor-<anchor>`); `serial` makes a repeat
/// request for the same panel a new value.
struct SpinScrollRequest: Equatable {
  let anchor: String
  let serial: Int
}

/// The numbers one spin bench shows, refreshed at 10 Hz.
struct SpinBenchReading: Equatable {
  var species: SpinSpecies
  var larmorHz = 0.0
  var omega = 0.0
  var carrierHz = 0.0
  var offsetHz = 0.0
  var drive = SpinDriveReadout(species: .protonWater, b1: 1e-6, offsetHz: 0)
  var dephasing = Double.infinity
  var mPerp = 0.0
  var mz = 1.0
  var isRFOn = false
  var isPulsing = false
  var wavelength = 0.0
}

/// What SwiftUI reads from the Spin model, refreshed at 10 Hz (the engines themselves are
/// stepped every frame and are not observed).
struct SpinReadings: Equatable {
  /// B₀ in use (tesla).
  var field = EarthField.typicalField
  /// .live (real magnetometer), .sim (fake) or .model (the dial).
  var fieldProvenance: Provenance = .model
  /// The magnetometer's state while the field source is Live.
  var liveFieldState: SensorState = .idle
  var liveFieldAvailable = false
  /// |B| scatter over the last second (tesla).
  var fieldNoise: Double?
  /// The magnetometer's calibration accuracy (−1…2) while it supplies B₀, when reported.
  var calibration: Int?
  /// Dip angle and dipole magnetic latitude (rad), from gravity and B in the phone frame.
  var dip: Double?
  var latitude: Double?
  /// .live or .sim while device motion drives the rotor; nil without motion.
  var motionProvenance: Provenance?
  var fieldChips = SpinFieldReadout(field: EarthField.typicalField)
  var proton = SpinBenchReading(species: .protonWater)
  var electron = SpinBenchReading(species: .electron)
  var gyro: HeavyTopTelemetry?
  /// The rotor's Larmor rate −γ_rotor·|B| (rad/s), 0 without a magnet.
  var rotorLarmor = 0.0
  /// |B| the rotor feels (tesla).
  var rotorField = 0.0
  /// The resonance trip's synthetic field drives the rotor (not the live or dial field).
  var rotorResonance = false
  /// What Hear it plays for the proton line.
  var protonVoice = LarmorSonification.voice(species: .protonWater, field: EarthField.typicalField)
  var pressure: Double?
}

/// The Spin tab (SPEC-features §4): Gyre's heavy top driven by the phone's real motion, and
/// protons and electrons precessing in the live Earth field, on one Metal scene, with FID,
/// spectrum, Wigner view, true-pitch sound, streams and strip markers.
///
/// Keeps the stage-1 contract: the type name, `init()`, `markers`, `TabModel`, plus
/// `fieldTesla` and `larmorFrequency` that `AppTests` read.
@Observable @MainActor
final class SpinModel: TabModel {
  /// Everything persisted under `Spectra.spin.v1`.
  var saved: SpinSaved {
    didSet {
      guard saved != oldValue else { return }
      savedChanged(from: oldValue)
    }
  }
  private(set) var readings = SpinReadings()
  /// Hear it: the proton line plays at true pitch under the simulated |M⊥|.
  private(set) var isHearing = false
  /// The Spin tab is on screen.
  private(set) var isVisible = false
  /// The engines are stepping and the streams are published.
  private(set) var running = false
  /// The latest FID spectrum (centred baseband, species hertz) and its sample rate.
  private(set) var spectrum: FIDSpectrum?
  /// The latest Wigner image of the FID record and the species it shows.
  private(set) var wigner: Phase.TimeFrequencyImage?
  private(set) var wignerSpecies: SpinSpecies = .protonWater
  private(set) var wignerBusy = false
  /// Live sensors are moving the scene (the canvas redraws even while paused).
  private(set) var liveDriven = false
  /// Bumped about 30 times a second while the tab is on screen: the rolling plots redraw on it.
  private(set) var plotTick = 0
  /// Axle-tip spectrum (960 Hz simulated time), dB re its peak.
  private(set) var tipSpectrum: FIDSpectrum?
  /// A panel the content should scroll to (a deep link, or a hand-off from another tab).
  private(set) var scrollRequest: SpinScrollRequest?

  /// The Metal scene (camera, drawing).
  let scene: SpinScene

  // MARK: Engines (stepped every frame, not observed)

  @ObservationIgnored private(set) var gyro: GyroscopeEngine
  @ObservationIgnored private(set) var proton: SpinBenchRunner
  @ObservationIgnored private(set) var electron: SpinBenchRunner
  @ObservationIgnored private(set) var live = SpinLiveSample()
  @ObservationIgnored private var liveReader = SpinLiveReader()
  /// Recent axle-tip samples (960 Hz simulated), for the IQ plot and its spectrum.
  @ObservationIgnored private(set) var tipHistory: [SIMD2<Double>] = []
  /// Reused per-frame buffers (no allocation in the stepping hot path once warmed up).
  @ObservationIgnored private var fidScratch: [SIMD2<Double>] = []
  @ObservationIgnored private var scratchI: [Float] = []
  @ObservationIgnored private var scratchQ: [Float] = []
  @ObservationIgnored private var scratchT: [Double] = []
  /// Something the rolling plots show changed while the clock was held (reset, pulse, view).
  @ObservationIgnored private var plotsDirty = true
  @ObservationIgnored private var fidVoice = SpinFIDSource()
  @ObservationIgnored private var smoother = FieldSmoother()
  @ObservationIgnored private var lastClock: Double?
  @ObservationIgnored private var lastLive: Double?
  @ObservationIgnored private var lastReadout = -Double.infinity
  @ObservationIgnored private var lastTipSpectrum = -Double.infinity
  @ObservationIgnored private var lastPlotTick = -Double.infinity
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var wignerTask: Task<Void, Never>?
  @ObservationIgnored private var analysedRevision = -1
  @ObservationIgnored private var analysedKey = ""
  @ObservationIgnored private weak var app: AppModel?
  private let store = JSONStore<SpinSaved>(key: "Spectra.spin.v1")
  private let persists: Bool
  @ObservationIgnored private var published: [StreamID: SignalStream] = [:]
  @ObservationIgnored private var publishedKey = ""
  @ObservationIgnored private var lastFIDStamp = 0.0
  @ObservationIgnored private var lastTipStamp = 0.0
  @ObservationIgnored private var voice: SynthVoice?
  @ObservationIgnored private var heldSensors: Set<SensorID> = []
  /// The last strip / hand-off marker this tab acted on (`handleFocus`).
  @ObservationIgnored private var handledFocus: SpectrumMarker?

  /// Stream ids this tab publishes (`Docs/API-spin-ui.md`).
  static let fidStream: StreamID = "spin.fid"
  static let fidQStream: StreamID = "spin.fid.q"
  static let tipIStream: StreamID = "gyro.tip.i"
  static let tipQStream: StreamID = "gyro.tip.q"
  /// The 10 cm sample's length, for the dephasing-time readout.
  static let sampleLength = SpinBenchRunner.sampleLength
  /// The default field direction without a magnetometer: Gyre's simulated (0, 22, −40) µT
  /// (north and dipping down), world axes.
  static let defaultFieldDirection = simd_normalize(SIMD3<Double>(0, 22, -40))
  /// The rotor feels at most this field from the dial (tesla); above it the magnetic swing of a
  /// fantasy-magnet rotor outruns the integrator's substep budget.
  static let rotorFieldLimit = 0.01

  /// Species seconds per proton second, u = γ′ₚ/|γ|: 1 for water protons, 1/658 for the
  /// electron, so the electron bench shows the proton's picture at its own pace.
  nonisolated static func timeUnit(_ species: SpinSpecies) -> Double {
    abs(SpinSpecies.protonWater.gammaHzPerT / species.gammaHzPerT)
  }

  init() {
    persists = !LaunchOptions.current.uiTesting
    var initial = SpinSaved()
    if persists, let stored = store.load() { initial = stored }
    var anchor: String?
    if let path = LaunchOptions.current.openTab == .spin ? LaunchOptions.current.openPath : nil {
      if let view = SpinView(path: path) { initial.view = view }
      let parts = path.split(separator: "/")
      if parts.count > 1 { anchor = String(parts[1]).lowercased() }
    }
    saved = initial
    scrollRequest = anchor.map { SpinScrollRequest(anchor: $0, serial: 1) }
    gyro = GyroscopeEngine(params: initial.gyro)
    if let preset = HeavyTopPreset.all.first(where: { $0.id == initial.presetID }), preset.resonance {
      gyro.apply(preset)
      gyro.params = initial.gyro
    }
    proton = SpinBenchRunner(species: .protonWater, timeUnit: 1, bench: initial.proton)
    electron = SpinBenchRunner(species: .electron, timeUnit: Self.timeUnit(.electron), bench: initial.electron)
    scene = SpinScene()
    scene.model = self
    scene.resetCamera(for: initial.view)
    refreshReadings()
  }

  func attach(to app: AppModel) {
    self.app = app
    // *Publish while hidden* was left on: the Scope or a Patch node may read the Spin streams
    // before this tab is opened, so they start now (motion and the magnetometer show no
    // permission prompt; the hub starts them once the app is active).
    if saved.publishHidden { updateRunning() }
    #if DEBUG
      if SpinSnapshots.requested { SpinSnapshots.run(app: app) }
    #endif
  }

  /// Asks the content to scroll to `spin-anchor-<anchor>`.
  func scroll(to anchor: String) {
    scrollRequest = SpinScrollRequest(anchor: anchor, serial: (scrollRequest?.serial ?? 0) + 1)
  }

  /// Acts once on a marker another tab focused on Spin (`AppModel.focus`): the Live tab's
  /// "Hear Earth-field NMR" (`live.nmr`) opens the proton bench on the live field and starts
  /// Hear it when Sound is on; a tap on a Spin marker of the strip opens the view that owns it.
  /// Called by SpinTab on appear and whenever `app.focusedMarker` changes, after `setVisible`.
  func handleFocus(_ marker: SpectrumMarker?) {
    guard let marker, marker.tab == .spin, marker != handledFocus else { return }
    handledFocus = marker
    switch marker.id {
    case "live.nmr":
      saved.fieldSource = .live
      select(.proton)
      if let app, app.settings.soundOn, !isHearing { toggleHearing() }
      scroll(to: "hear")
    case "spin.larmor":
      if saved.view != .proton, saved.view != .compare { select(.proton) }
      scroll(to: "readouts")
    case "spin.electron":
      if saved.view != .electron, saved.view != .compare { select(.electron) }
      scroll(to: "readouts")
    case "spin.nod":
      if saved.view != .gyroscope, saved.view != .compare { select(.gyroscope) }
      scroll(to: "readouts")
    default:
      break
    }
  }

  // MARK: Stage-1 contract

  /// The B₀ dial (tesla).
  var fieldTesla: Double {
    get { saved.fieldTesla }
    set { saved.fieldTesla = newValue }
  }

  /// Water-proton precession frequency in the field in use (Hz).
  var larmorFrequency: Double { SpinSpecies.protonWater.larmorHz(field: fieldInUse) }

  /// B₀ in use: the smoothed live |B| while the source is Live and the magnetometer runs,
  /// otherwise the dial.
  var fieldInUse: Double {
    if saved.fieldSource == .live, live.hasField, let b = smoother.value, b > 0 { return b }
    return saved.fieldTesla
  }

  var markers: [SpectrumMarker] {
    let r = readings
    let fieldNote = r.fieldProvenance == .model ? "" : " (live |B|)"
    var list = [
      SpectrumMarker(
        id: "spin.larmor", label: "¹H precession \(SpectraFormat.frequency(r.fieldChips.protonHz, digits: 5))\(fieldNote)",
        frequency: r.fieldChips.protonHz, provenance: .model, tab: .spin)
    ]
    if saved.view == .electron || saved.view == .compare {
      list.append(
        SpectrumMarker(
          id: "spin.electron", label: "e⁻ spin \(SpectraFormat.frequency(r.fieldChips.electronHz, digits: 4))\(fieldNote)",
          frequency: r.fieldChips.electronHz, provenance: .model, tab: .spin))
    }
    if saved.view == .gyroscope || saved.view == .compare, let g = r.gyro, g.nutationHz > 0.5 {
      list.append(
        SpectrumMarker(
          id: "spin.nod", label: "Rotor inertial nod \(SpectraFormat.frequency(g.nutationHz))",
          frequency: g.nutationHz, provenance: .analogy, tab: .spin, isEM: false))
    }
    return list
  }

  // MARK: Visibility and running

  /// SpinTab's onAppear / onDisappear.
  func setVisible(_ visible: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
    if !visible {
      stopHearing()
      app?.haptics.stopHum()
      flush()
      releaseFocus()
    }
    updateRunning()
  }

  /// Leaving the tab hands back a marker that was focused on Spin. `@Observable` skips the
  /// notification when an equal value is set, so a second "Hear Earth-field NMR" with the same
  /// label would otherwise neither change `app.focusedMarker` nor pass `handledFocus`, and Spin
  /// would ignore it. Clearing it here makes the next hand-off a change again; markers focused
  /// on other tabs are left alone.
  private func releaseFocus() {
    handledFocus = nil
    if let app, app.focusedMarker?.tab == .spin { app.focusedMarker = nil }
  }

  private func updateRunning() {
    let should = isVisible || saved.publishHidden
    guard should != running else {
      if running { updateSensors() }
      return
    }
    running = should
    if should {
      lastClock = nil
      updateSensors()
      ensureStreams()
      loop = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(16))
          guard let self, let app = self.app else { return }
          // The render loop steps while the canvas draws; this loop covers the rest
          // (canvas paused or off screen, tab hidden while publishing).
          if app.isActive, SignalClock.now() - self.scene.lastBuild > 0.05 { self.advance(to: app.clock.time) }
        }
      }
    } else {
      loop?.cancel()
      loop = nil
      releaseSensors()
      unregisterStreams()
      stopHearing()
    }
  }

  private func updateSensors() {
    guard let app else { return }
    var wanted: Set<SensorID> = [.motion]
    if saved.fieldSource == .live { wanted.insert(.magnetometer) }
    for id in wanted.subtracting(heldSensors) { app.live.acquire(id, by: "spin") }
    for id in heldSensors.subtracting(wanted) { app.live.release(id, by: "spin") }
    heldSensors = wanted
  }

  private func releaseSensors() {
    app?.live.releaseAll(by: "spin")
    heldSensors = []
  }

  // MARK: Stepping

  /// Steps every engine to clock time `t` (idempotent: the render loop and the background
  /// loop both call it). Paused clock → dt = 0: live inputs and readouts still refresh.
  ///
  /// Only what is on screen steps: the rotor in the gyroscope and Compare views, the proton
  /// bench in the proton and Compare views, the electron bench in its own and Compare views.
  /// With *Publish while hidden* on, the engines behind the published streams keep stepping
  /// whatever the view (the Scope or Patch is reading them).
  func advance(to t: Double) {
    guard let app else { return }
    let dt = lastClock.map { min(max(t - $0, 0), AppClock.maxStep) } ?? 0
    lastClock = t
    readLive(app)
    let field = fieldInUse
    fidVoice.setField(field)

    let view = saved.view
    let publishing = saved.publishHidden
    if view == .gyroscope || view == .compare || publishing { stepGyro(dt, app: app) }
    var events = SpinBenchEvents()
    if view == .proton || view == .compare || (view == .gyroscope && publishing) {
      fidScratch.removeAll(keepingCapacity: true)
      let protonHz = SpinSpecies.protonWater.larmorHz(field: field)
      let e = proton.advance(
        dt * saved.proton.slowMotion, bench: saved.proton, larmorHz: protonHz, lockCarrier: saved.lockCarrier,
        repeating: saved.repeatPulses
      ) { s, _ in fidScratch.append(s) }
      if view != .gyroscope { events.sequenceStarted = events.sequenceStarted || e.sequenceStarted }
      if fidSpecies == .protonWater { publishFID(rate: fidWallRate) }
    }
    if view == .electron || view == .compare {
      fidScratch.removeAll(keepingCapacity: true)
      let electronHz = SpinSpecies.electron.larmorHz(field: field)
      let e = electron.advance(
        dt * electron.timeUnit * saved.electron.slowMotion, bench: saved.electron, larmorHz: electronHz,
        lockCarrier: saved.lockCarrier, repeating: saved.repeatPulses
      ) { s, _ in fidScratch.append(s) }
      if view == .electron { events.sequenceStarted = events.sequenceStarted || e.sequenceStarted }
      if fidSpecies == .electron { publishFID(rate: fidWallRate) }
    }
    if events.sequenceStarted, isVisible { app.haptics.transient(intensity: 0.45, sharpness: 0.85) }

    feedback(app)
    let now = SignalClock.now()
    // The rolling plots redraw at 30 Hz while something moves (or once after an edit while
    // the clock is held), and only while the tab is on screen.
    if isVisible, dt > 0 || plotsDirty, now - lastPlotTick >= 1.0 / 30 {
      lastPlotTick = now
      plotsDirty = false
      plotTick &+= 1
    }
    // Readouts at 10 Hz on screen; while hidden (publishing for the Scope or Patch) only the
    // strip markers and stream registration read them, so 2 Hz is enough.
    if now - lastReadout >= (isVisible ? 0.1 : 0.5) {
      lastReadout = now
      refreshReadings()
      refreshAnalysis()
    }
  }

  private func readLive(_ app: AppModel) {
    let now = SignalClock.now()
    let wdt = lastLive.map { now - $0 } ?? 0
    lastLive = now
    live = liveReader.read(app.streams, now: now)
    if let b = live.fieldMagnitude, b.isFinite, b > 0 { smoother.update(b, dt: wdt) }
  }

  /// The field the rotor feels (tesla, world axes): the live vector, or the dial along the live
  /// direction (Gyre's simulated direction without a magnetometer).
  var rotorField: SIMD3<Double> {
    if saved.fieldSource == .live, let b = live.fieldWorld { return b }
    let direction = live.fieldWorld.map { simd_length($0) > 0 ? simd_normalize($0) : Self.defaultFieldDirection }
    return (direction ?? Self.defaultFieldDirection) * min(saved.fieldTesla, Self.rotorFieldLimit)
  }

  private func stepGyro(_ dt: Double, app: AppModel) {
    var env = HeavyTopEnvironment()
    if let w = live.rateWorld { env.deviceRate = w }
    if let a = live.linearWorld {
      // A dropped or flung phone reads tens of m/s²; keep the jolt to 3 g.
      let n = simd_length(a)
      env.linearAccel = n > 3 * SpinLiveReader.g0 ? a * (3 * SpinLiveReader.g0 / n) : a
    }
    env.magneticField = rotorField
    if let p = live.pressure { env.pressureFactor = AirHere.pressureFactor(kilopascals: p / 1000) }
    gyro.advance(dtReal: dt, environment: env)
    let tips = gyro.drainTip()
    guard !tips.isEmpty else { return }
    tipHistory.append(contentsOf: tips)
    // Trim in batches (the plots and the spectrum read at most the newest 2048).
    if tipHistory.count > 4096 { tipHistory.removeFirst(tipHistory.count - 2048) }
    publishTips(tips)
  }

  /// The field the rotor actually feels (tesla, world axes): the resonance trip's synthetic
  /// B₀ + rotating B₁ while that trip runs, otherwise `rotorField`.
  var rotorFieldApplied: SIMD3<Double> { isResonanceTrip ? gyro.appliedField : rotorField }

  /// The "Magnetic resonance with a gyroscope" trip is driving the rotor with its own field.
  var isResonanceTrip: Bool { gyro.resonance != nil }

  /// Haptic hum (Settings → Continuous hum) and the Hear it voice, once per frame.
  private func feedback(_ app: AppModel) {
    if isVisible {
      switch saved.view {
      case .gyroscope, .compare:
        let strain = gyro.telemetry.strain
        app.haptics.updateHum(intensity: Float(min(strain / 0.03, 1)), sharpness: 0.3)
      case .proton:
        app.haptics.updateHum(intensity: Float(0.6 * proton.sample.signalMagnitude), sharpness: 0.6)
      case .electron:
        app.haptics.updateHum(intensity: Float(0.6 * electron.sample.signalMagnitude), sharpness: 0.8)
      }
    }
    if isHearing {
      // Hear it lives on the proton page: leaving it (or turning Sound off) stops the voice,
      // so nothing keeps playing without a Stop button on screen.
      guard app.settings.soundOn, saved.view == .proton, isVisible else {
        stopHearing()
        return
      }
      if voice == nil { voice = app.synth.voice(for: "spin.fid") }
      // The envelope is the simulated |M⊥|; a held clock holds the simulation, so the voice
      // falls silent rather than droning on a frozen envelope.
      let level = app.clock.playing ? 0.7 * min(1, proton.sample.signalMagnitude) : 0
      voice?.tone(fidVoice.voice.audibleHz, level: level)
    }
  }

  // MARK: Actions

  /// The spin species of the selected view (the proton unless the electron is shown).
  var fidSpecies: SpinSpecies { saved.view == .electron ? .electron : .protonWater }

  func bench(_ species: SpinSpecies) -> SpinBench { species == .electron ? saved.electron : saved.proton }

  func setBench(_ species: SpinSpecies, _ edit: (inout SpinBench) -> Void) {
    if species == .electron { edit(&saved.electron) } else { edit(&saved.proton) }
  }

  func runner(_ species: SpinSpecies) -> SpinBenchRunner { species == .electron ? electron : proton }

  /// Run: plays the selected sequence now.
  func runSequence(_ species: SpinSpecies) {
    if species == .electron { electron.startSequence(saved.electron) } else { proton.startSequence(saved.proton) }
    plotsDirty = true
    app?.haptics.transient(intensity: 0.55, sharpness: 0.9)
  }

  /// A finite π/2 or π pulse at B₁ about the phase knob.
  func pulse(_ species: SpinSpecies, flip: Double) {
    if species == .electron {
      electron.startPulse(flip: flip, bench: saved.electron)
    } else {
      proton.startPulse(flip: flip, bench: saved.proton)
    }
    plotsDirty = true
    app?.haptics.transient(intensity: 0.5, sharpness: 0.7)
  }

  func resetMagnetization(_ species: SpinSpecies) {
    if species == .electron { electron.resetMagnetization() } else { proton.resetMagnetization() }
    plotsDirty = true
  }

  /// Hear it: claims the synth voice and follows the proton bench's |M⊥| at the true Larmor
  /// pitch (MAPPED above 20 kHz). Pulses first when nothing is ringing.
  func toggleHearing() {
    if isHearing {
      stopHearing()
      return
    }
    guard let app, app.settings.soundOn, saved.view == .proton else {
      app?.haptics.boundary()
      return
    }
    voice = app.synth.voice(for: "spin.fid")
    guard voice != nil else {
      app.haptics.boundary()
      app.showToast("Every synth voice is busy", symbol: "speaker.slash.fill")
      return
    }
    isHearing = true
    if proton.sample.signalMagnitude < 0.05 { runSequence(.protonWater) }
  }

  func stopHearing() {
    guard isHearing || voice != nil else { return }
    isHearing = false
    voice = nil
    app?.synth.releaseVoice(for: "spin.fid")
  }

  /// Loads a field trip on the rotor.
  func apply(preset: HeavyTopPreset) {
    gyro.apply(preset)
    tipHistory.removeAll(keepingCapacity: true)
    saved.gyro = preset.params
    saved.presetID = preset.id
    app?.haptics.spinUp()
  }

  /// Relaunches the rotor in steady precession at the current knobs.
  func relaunchRotor() {
    gyro.params = saved.gyro
    gyro.launch(tilt: max(0.2, gyro.top.tilt.isFinite ? gyro.top.tilt : 0.32))
    tipHistory.removeAll(keepingCapacity: true)
    plotsDirty = true
    app?.haptics.spinUp()
  }

  /// Knocks the axle sideways (Gyre's tap).
  func kickRotor() {
    gyro.kick(strength: 0.6, angle: Double.random(in: 0..<(2 * .pi)))
    plotsDirty = true
    app?.haptics.transient(intensity: 0.8, sharpness: 0.5)
  }

  func select(_ view: SpinView) {
    guard view != saved.view else { return }
    saved.view = view
  }

  /// Reset dials: every knob in the visible view's Dials sheet (and the B₀ dial) back to its
  /// default. Compare's sheet holds the rotor's dials only, so the spin benches keep theirs.
  func resetDials() {
    switch saved.view {
    case .gyroscope, .compare:
      gyro.resonance = nil
      saved.gyro = HeavyTopParams()
      saved.presetID = ""
      gyro.params = saved.gyro
    case .proton:
      saved.proton = SpinBench.defaults(timeUnit: 1)
    case .electron:
      saved.electron = SpinBench.defaults(timeUnit: Self.timeUnit(.electron))
    }
    saved.fieldTesla = EarthField.typicalField
  }

  func resetAlignment() { scene.resetCamera(for: saved.view) }

  // MARK: Links

  /// The line "Show on spectrum" sends: the electron's in the electron view, else water protons'.
  var linkSpecies: SpinSpecies { saved.view == .electron ? .electron : .protonWater }

  func showOnSpectrum() {
    guard let app else { return }
    let s = linkSpecies
    let f = s.larmorHz(field: fieldInUse)
    app.sendToSpectrum(
      lambda: s.larmorWavelength(field: fieldInUse),
      label: s == .electron ? "e⁻ spin \(SpectraFormat.frequency(f, digits: 4))" : "¹H \(SpectraFormat.frequency(f, digits: 5))")
  }

  func openInLab() {
    guard let app else { return }
    if let lab = (app.spectrum as AnyObject) as? SpinEarthFieldLab {
      lab.openEarthFieldLab()
      if app.selectedTab != .spectrum { app.selectedTab = .spectrum }
      return
    }
    let f = SpinSpecies.protonWater.larmorHz(field: fieldInUse)
    app.focus(
      SpectrumMarker(
        id: "spin.larmor", label: "¹H precession \(SpectraFormat.frequency(f, digits: 5))", frequency: f,
        provenance: .model, tab: .spectrum))
    app.showToast("Spectroscopy lab → ethanol ¹H NMR → Earth field shows this line", symbol: "flask")
  }

  /// The streams "Open in Scope" and "Add to Patch" use for the visible view.
  var linkStreams: [StreamID] {
    saved.view == .gyroscope ? [Self.tipIStream, Self.tipQStream] : [Self.fidStream, Self.fidQStream]
  }

  func openInScope() {
    guard let app else { return }
    saved.publishHidden = true
    ensureStreams()
    app.openScope(linkStreams, preset: saved.view == .gyroscope ? nil : "Spin FID")
  }

  func addToPatch() {
    guard let app else { return }
    saved.publishHidden = true
    ensureStreams()
    let id = linkStreams[0]
    let label = saved.view == .gyroscope ? "Gyroscope tip I" : "Spin FID (\(fidSpecies == .electron ? "electron" : "proton"))"
    let before = app.selectedTab
    app.patch.addStreamSource(id, label: label)
    if app.selectedTab == before { app.showToast("\(label) added to Patch", symbol: "point.3.connected.trianglepath.dotted") }
  }

  // MARK: Streams

  /// spin.fid's wall-clock rate: 400 bench samples per displayed second × the bench's pace.
  var fidWallRate: Double { SpinBenchRunner.baseSampleRate * bench(fidSpecies).slowMotion }

  private func ensureStreams() {
    guard let app, running else { return }
    let fidRate = fidWallRate
    let tipRate = gyro.wallClockTipRate
    let key = "\(fidSpecies.rawValue)|\(fidRate)|\(tipRate)|\(saved.fieldSource.rawValue)"
    guard key != publishedKey else { return }
    publishedKey = key
    let who = fidSpecies == .electron ? "electron" : "proton"
    let fieldNote = saved.fieldSource == .live ? "live |B|" : "dial B₀"
    let slowed = fidSpecies == .electron ? ", slowed ×\(Int((1 / Self.timeUnit(.electron)).rounded()))" : ""
    // The FID describes the Larmor line, so it carries that line's wavelength (the Scope
    // colours it by band); the value is the field at registration.
    let lambda = fidSpecies.larmorWavelength(field: fieldInUse)
    let made = [
      SignalStream(
        id: Self.fidStream, label: "Spin FID I · \(who) (\(fieldNote)\(slowed))", unit: "M₀", nominalRate: fidRate,
        provenance: .model, isEM: true, lambda: lambda, group: StreamGroup.spin),
      SignalStream(
        id: Self.fidQStream, label: "Spin FID Q · \(who) (\(fieldNote)\(slowed))", unit: "M₀", nominalRate: fidRate,
        provenance: .model, isEM: true, lambda: lambda, group: StreamGroup.spin),
      SignalStream(
        id: Self.tipIStream, label: "Gyroscope tip I (live motion)", unit: "eₓ", nominalRate: tipRate,
        provenance: .model, group: StreamGroup.spin),
      SignalStream(
        id: Self.tipQStream, label: "Gyroscope tip Q (live motion)", unit: "e_y", nominalRate: tipRate,
        provenance: .model, group: StreamGroup.spin),
    ]
    app.streams.register(made)
    published = Dictionary(uniqueKeysWithValues: made.map { ($0.id, $0) })
    lastFIDStamp = 0
    lastTipStamp = 0
  }

  private func unregisterStreams() {
    guard let app else { return }
    for s in published.values { app.streams.unregister(s) }
    published = [:]
    publishedKey = ""
  }

  /// Publishes this frame's bench samples (`fidScratch`) on spin.fid / spin.fid.q.
  private func publishFID(rate: Double) {
    guard !fidScratch.isEmpty, let i = published[Self.fidStream], let q = published[Self.fidQStream] else { return }
    publish(fidScratch, i: i, q: q, rate: rate, last: &lastFIDStamp)
  }

  private func publishTips(_ samples: [SIMD2<Double>]) {
    guard !samples.isEmpty, let i = published[Self.tipIStream], let q = published[Self.tipQStream] else { return }
    publish(samples, i: i, q: q, rate: gyro.wallClockTipRate, last: &lastTipStamp)
  }

  /// Appends complex samples to an I/Q stream pair with wall-clock times at `rate` ending now,
  /// never earlier than the last; the conversion buffers are reused.
  private func publish(_ samples: [SIMD2<Double>], i: SignalStream, q: SignalStream, rate: Double, last: inout Double) {
    let dt = 1 / max(rate, 1e-6)
    var start = SignalClock.now() - Double(samples.count - 1) * dt
    if start <= last { start = last + dt }
    scratchI.removeAll(keepingCapacity: true)
    scratchQ.removeAll(keepingCapacity: true)
    scratchT.removeAll(keepingCapacity: true)
    for (k, s) in samples.enumerated() {
      scratchI.append(Float(s.x))
      scratchQ.append(Float(s.y))
      scratchT.append(start + Double(k) * dt)
    }
    last = scratchT.last ?? last
    i.ring.append(contentsOf: scratchI, times: scratchT)
    q.ring.append(contentsOf: scratchQ, times: scratchT)
  }

  // MARK: Readouts and analysis

  private func refreshReadings() {
    var r = SpinReadings()
    let field = fieldInUse
    r.field = field
    let mag = app?.live.channel(.magnetometer)
    r.liveFieldState = mag?.state ?? .idle
    r.liveFieldAvailable = live.hasField && smoother.value != nil
    r.fieldProvenance =
      saved.fieldSource == .live && r.liveFieldAvailable ? (mag?.provenance == .live ? .live : .sim) : .model
    r.fieldNoise = app.flatMap { SpinLiveReader.fieldNoise($0.streams) }
    if r.fieldProvenance != .model, let mag { r.calibration = SpinMagnetometerCalibration.accuracy(of: mag) }
    if let b = live.fieldDevice, let g = live.gravityDevice {
      let earth = EarthField(microtesla: b, gravity: g)
      r.dip = earth.dipAngle
      r.latitude = earth.magneticLatitude
    }
    if live.hasMotion, let motion = app?.live.channel(.motion) {
      r.motionProvenance = motion.provenance == .live ? .live : .sim
    }
    r.fieldChips = SpinFieldReadout(field: field)
    r.proton = reading(proton, bench: saved.proton, field: field)
    r.electron = reading(electron, bench: saved.electron, field: field)
    r.gyro = gyro.telemetry
    r.rotorResonance = isResonanceTrip
    r.rotorField = simd_length(rotorFieldApplied)
    r.rotorLarmor = gyro.top.larmorRate(magnet: saved.gyro.magnet, field: r.rotorField)
    r.protonVoice = fidVoice.voice
    r.pressure = live.pressure
    if r != readings { readings = r }
    // The canvas redraws while paused only when live sensors move what it shows: the phone
    // outline, horizon and field on the rotor, or a Bloch sphere aligned with your field.
    let rotorShown = saved.view == .gyroscope || saved.view == .compare
    let aligned = saved.alignToField && (saved.view == .proton || saved.view == .electron) && r.liveFieldAvailable
    let driven = running && ((rotorShown && (r.motionProvenance != nil || r.fieldProvenance != .model)) || aligned)
    if driven != liveDriven { liveDriven = driven }
    ensureStreams()
  }

  private func reading(_ runner: SpinBenchRunner, bench: SpinBench, field: Double) -> SpinBenchReading {
    let s = runner.species
    var b = SpinBenchReading(species: s)
    b.larmorHz = s.larmorHz(field: field)
    b.omega = s.larmorAngular(field: field)
    b.carrierHz = runner.carrierHz > 0 ? runner.carrierHz : b.larmorHz - bench.offsetHz
    b.offsetHz = runner.effectiveOffset
    b.drive = SpinDriveReadout(species: s, b1: bench.b1, offsetHz: runner.effectiveOffset)
    b.dephasing = SpinEnsemble.dephasingTime(species: s, gradient: bench.gradient, length: Self.sampleLength)
    let m = runner.sample.meanMagnetization
    b.mPerp = runner.sample.signalMagnitude
    b.mz = m.z
    b.isRFOn = runner.sample.isRFOn
    b.isPulsing = runner.sample.isPulsing
    b.wavelength = s.larmorWavelength(field: field)
    return b
  }

  /// Recomputes the FID spectrum (main actor, small DFT) and the Wigner image (detached) when a
  /// new record completes or the view settings change; the tip spectrum at 2 Hz.
  private func refreshAnalysis() {
    let now = SignalClock.now()
    // Only for the panels on screen: the tip spectrum in the gyroscope view, the FID spectrum
    // and Wigner image in the proton and electron views (Compare shows neither).
    if saved.view == .gyroscope, isVisible, now - lastTipSpectrum > 0.5, tipHistory.count >= 256 {
      lastTipSpectrum = now
      let n = tipHistory.count >= 2048 ? 2048 : (tipHistory.count >= 1024 ? 1024 : 512)
      let block = Array(tipHistory.suffix(n))
      let w = SpinAnalysis.hann(count: n)
      let windowed = block.enumerated().map { $0.element * w[$0.offset] }
      tipSpectrum = FIDSpectrum.transform(windowed, sampleRate: HeavyTop.tipSampleRate)
    }
    guard isVisible, saved.view == .proton || saved.view == .electron else { return }
    let species = fidSpecies
    let r = runner(species)
    let key = "\(species.rawValue)|\(saved.wignerMode.rawValue)"
    guard r.recorder.revision != analysedRevision || key != analysedKey else { return }
    let record = r.recorder.record
    guard record.count >= 32 else {
      // Reset M empties the record: drop the old spectrum and Wigner image instead of showing
      // the previous FID under "last record".
      analysedRevision = r.recorder.revision
      analysedKey = key
      wignerTask?.cancel()
      wignerBusy = false
      wignerSpecies = species
      if spectrum != nil { spectrum = nil }
      if wigner != nil { wigner = nil }
      return
    }
    analysedRevision = r.recorder.revision
    analysedKey = key
    let rate = r.sampleRate
    if species != wignerSpecies { wigner = nil }
    wignerSpecies = species
    spectrum = FIDSpectrum.transform(record, sampleRate: rate)
    wignerTask?.cancel()
    wignerBusy = true
    let mode = saved.wignerMode
    wignerTask = Task { [weak self] in
      let image = await Task.detached(priority: .userInitiated) {
        Phase.timeFrequency(
          complex: Phase.Signal.fromIQ(record, sampleRate: rate),
          request: Phase.TimeFrequencyRequest(mode: mode, rows: min(128, record.count), columns: 128))
      }.value
      guard !Task.isCancelled, let self, self.wignerSpecies == species else { return }
      self.wigner = image
      self.wignerBusy = false
    }
  }

  // MARK: Persistence and reactions

  private func savedChanged(from old: SpinSaved) {
    if persists { store.schedule(saved) }
    plotsDirty = true
    if saved.gyro != old.gyro {
      var p = saved.gyro
      p.motorRPM = (p.motorRPM / SpinKnobs.motor.step).rounded() * SpinKnobs.motor.step
      gyro.params = p
      if gyro.resonance != nil, p.magnet != old.gyro.magnet || p.motorRPM != old.gyro.motorRPM {
        gyro.retuneResonance()
      }
      if saved.presetID == old.presetID, !saved.presetID.isEmpty, saved.gyro != presetParams(saved.presetID) {
        saved.presetID = ""
      }
    }
    if saved.view != old.view {
      scene.resetCamera(for: saved.view)
      if saved.view != .proton { stopHearing() }
      plotsDirty = true
      analysedRevision = -1
      spectrum = nil
      wigner = nil
    }
    if saved.fieldSource != old.fieldSource || saved.publishHidden != old.publishHidden { updateRunning() }
    if running { ensureStreams() }
    if saved.wignerMode != old.wignerMode { analysedKey = "" }
    refreshReadings()
  }

  private func presetParams(_ id: String) -> HeavyTopParams? { HeavyTopPreset.all.first { $0.id == id }?.params }

  /// Writes pending state now.
  func flush() { if persists { store.flush() } }
}
