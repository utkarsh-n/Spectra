import Foundation
import Observation
import simd

/// The Radio tab's shared model (SPEC-features §2): the selected system (carrier, bandwidth,
/// modulation), the antenna (style and knobs), the Fourier channel and message, and the link
/// budget. Every number it shows comes from the RF and Phase engines; this class only wires
/// knobs to them, runs the expensive builds off the main actor, follows the phone's attitude,
/// publishes the `radio.*` streams and persists everything under `Spectra.radio.v1`.
@Observable @MainActor
final class RadioModel: TabModel {
  // MARK: Defaults

  static let defaultCarrier = 2.44e9
  static let defaultSystemID = "ble"
  static let carrierRange: ClosedRange<Double> = 100e3...300e9

  // MARK: Persisted state

  var page: RadioPage = .antenna {
    didSet {
      guard page != oldValue else { return }
      changed()
      refreshDemand()
    }
  }
  /// The catalog system the Fourier and Link pages simulate (`select(system:)`).
  private(set) var systemID = RadioModel.defaultSystemID {
    didSet { if systemID != oldValue { changed() } }
  }
  /// Carrier frequency, Hz: the antenna is designed for it, the link budget uses it, and the
  /// strip shows it.
  var carrier: Double = RadioModel.defaultCarrier {
    didSet {
      guard carrier != oldValue else { return }
      if antenna.frequency != carrier { antenna.frequency = carrier }
      changed()
      if app != nil { republishIQWhenSettled() }
    }
  }
  var antenna = RF.AntennaParameters(style: .dipole, frequency: RadioModel.defaultCarrier) {
    didSet {
      guard antenna != oldValue else { return }
      rebuildAntenna()
      changed()
    }
  }
  /// Turn the pattern with the phone (live attitude).
  var followPhone = false {
    didSet {
      guard followPhone != oldValue else { return }
      if followPhone {
        // Aim at where the beam points once the phone's attitude is known (the motion sensor
        // starts below); aiming now would use the upright stand-in.
        aimPending = true
        aimWhenAttitudeArrives()
      } else {
        aimPending = false
        beamLock = false
      }
      updateFollow()
      changed()
    }
  }
  /// Phased array: re-steer to keep the target direction while the phone turns.
  var beamLock = false {
    didSet {
      guard beamLock != oldValue else { return }
      updateFollow()
      changed()
    }
  }
  var lobeScale: RadioLobeScale = .decibel {
    didSet {
      guard lobeScale != oldValue else { return }
      if let b = antennaBuild { loadScene(b) }
      changed()
    }
  }
  /// The receiver's polarization for the PLF readout.
  var reference: RF.ReferencePolarization = .vertical { didSet { if reference != oldValue { changed() } } }
  var aperturePlane: RF.PatternPlane = .e {
    didSet {
      guard aperturePlane != oldValue else { return }
      rebuildAperture()
      changed()
    }
  }
  /// Fresnel distance of the aperture view as a fraction of the far-field distance 2D²/λ.
  var fresnelRatio = 0.0 {
    didSet {
      guard fresnelRatio != oldValue else { return }
      rebuildAperture()
      changed()
    }
  }
  var filter: RadioSystemFilter = .all { didSet { if filter != oldValue { changed() } } }
  var iPhoneOnly = false { didSet { if iPhoneOnly != oldValue { changed() } } }
  var fourier = RadioFourierSettings() {
    didSet {
      guard fourier != oldValue else { return }
      if fourier.message != oldValue.message { messageChanged(from: oldValue.message) }
      changed()
      restartProducer()
    }
  }
  var tfView: RadioTFView = .both { didSet { if tfView != oldValue { changed() } } }
  var traceSource: RadioTraceSource = .received { didSet { if traceSource != oldValue { changed() } } }
  var link = RadioLinkSettings() { didSet { if link != oldValue { changed() } } }

  // MARK: Derived state

  /// The latest antenna build (model, lobe mesh, cuts); nil until the first build lands.
  private(set) var antennaBuild: RadioAntennaBuild?
  /// The aperture phase-space view of the latest build (nil when the style has no line source).
  private(set) var apertureBuild: RadioApertureBuild?
  private(set) var apertureComputing = false
  /// Bumped when a new build lands (views key animations on it).
  private(set) var buildRevision = 0
  /// The world direction (CoreMotion frame: x east, y north, z up) the link readouts and Beam
  /// lock aim at. Set by "Aim here" and when Follow phone turns on.
  private(set) var target: SIMD3<Double>? {
    didSet { scene.target = target }
  }
  /// The Live check's running state (the user tapped Start once this session).
  var liveCheckWanted = false

  /// The 3D lobe scene.
  let scene = AntennaScene()
  /// The Fourier page's frame-rate simulator.
  let fourierEngine = RadioFourierEngine()

  @ObservationIgnored weak var app: AppModel?
  @ObservationIgnored private let store = JSONStore<RadioSaved>(key: "Spectra.radio.v1")
  @ObservationIgnored private var loading = false
  @ObservationIgnored private var antennaTask: Task<Void, Never>?
  @ObservationIgnored private var apertureTask: Task<Void, Never>?
  @ObservationIgnored private var lockTask: Task<Void, Never>?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private var producerTask: Task<Void, Never>?
  @ObservationIgnored private var producerKey: Int?
  /// Which Radio pages are on screen (set by the views).
  @ObservationIgnored private var visiblePages: Set<RadioPage> = []
  @ObservationIgnored private var motionHeld = false
  /// Follow phone just turned on: aim the target at the beam when the first attitude lands.
  @ObservationIgnored private var aimPending = false
  /// Whether the app was active at the last `refreshDemand` (flush the store on the way out).
  @ObservationIgnored private var wasActive = true
  /// Published simulated streams (MODEL). `radio.i` / `radio.q` carry the carrier's λ (band colour in the Scope, the λ a Patch
  /// ruler sends on), so they are re-published when the carrier settles on a new value.
  @ObservationIgnored private(set) var streamI: SignalStream
  @ObservationIgnored private(set) var streamQ: SignalStream
  let streamAudio: SignalStream
  @ObservationIgnored private var republishTask: Task<Void, Never>?

  // MARK: Init

  init() {
    (streamI, streamQ) = Self.makeIQStreams(lambda: SpectrumMarker.lambda(forFrequency: Self.defaultCarrier))
    streamAudio = SignalStream(
      id: "radio.audio", label: "Radio demodulated audio", unit: "FS", nominalRate: RF.BasebandLink.audioRate,
      provenance: .model, isEM: false, lambda: nil, group: StreamGroup.radio)
    if !LaunchOptions.current.uiTesting, let saved = store.load() { restore(saved) }
    if abs((streamI.lambda ?? 0) - lambda) > 1e-9 * lambda { (streamI, streamQ) = Self.makeIQStreams(lambda: lambda) }
    rebuildAntenna()
  }

  /// The κ-slowed I/Q pair for a carrier of wavelength `lambda` (m), optionally carrying over
  /// the samples of the pair it replaces so a scope trace does not restart empty.
  private static func makeIQStreams(lambda: Double, replacing old: (SignalStream, SignalStream)? = nil) -> (SignalStream, SignalStream) {
    func make(_ id: StreamID, _ label: String, _ previous: SignalStream?) -> SignalStream {
      let s = SignalStream(
        id: id, label: label, unit: "V (norm.)", nominalRate: RadioStreamProducer.iqRate,
        provenance: .model, isEM: true, lambda: lambda, group: StreamGroup.radio)
      if let previous {
        let snap = previous.ring.snapshot()
        s.ring.append(contentsOf: snap.values, times: snap.times)
      }
      return s
    }
    return (make("radio.i", "Radio I (κ-slowed)", old?.0), make("radio.q", "Radio Q (κ-slowed)", old?.1))
  }

  /// Re-publishes `radio.i` / `radio.q` with the current carrier's λ once the carrier has
  /// settled (a knob drag would otherwise swap streams every frame).
  private func republishIQWhenSettled() {
    republishTask?.cancel()
    republishTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let self, let app = self.app else { return }
      let lambda = self.lambda
      guard abs((self.streamI.lambda ?? 0) - lambda) > 1e-9 * lambda else { return }
      (self.streamI, self.streamQ) = Self.makeIQStreams(lambda: lambda, replacing: (self.streamI, self.streamQ))
      app.streams.register([self.streamI, self.streamQ])
      // The producer writes the stream objects it was started with.
      if self.producerTask != nil {
        self.stopProducer()
        self.refreshDemand()
      }
    }
  }

  /// Wires the scene to the live attitude, applies `-open radio/<page>[/<style or system>]`,
  /// publishes the streams and starts watching which tab is visible.
  func attach(to app: AppModel) {
    self.app = app
    scene.attitude = { [weak self] in self?.phoneAttitude() }
    if app.launch.openTab == .radio, let path = app.launch.openPath { applyLaunchPath(path) }
    app.streams.register([streamI, streamQ, streamAudio])
    fourierEngine.attach(model: self, app: app)
    handleFocusedMarker()
    watchFocus()
    monitorTask?.cancel()
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard let self else { return }
        self.refreshDemand()
      }
    }
  }

  // MARK: Markers and loop actions

  var markers: [SpectrumMarker] {
    let inBand = system.bands.contains { $0.contains(carrier) } || abs(carrier - system.carrier) < 1
    let label = inBand ? "Radio carrier · \(system.name)" : "Radio carrier"
    return [SpectrumMarker(id: "radio.carrier", label: label, frequency: carrier, provenance: .model, tab: .radio)]
  }

  /// Vacuum wavelength of the carrier, m.
  var lambda: Double { SpectrumMarker.lambda(forFrequency: carrier) }

  var system: RF.RadioSystem { RF.SystemsCatalog.system(id: systemID) ?? RF.SystemsCatalog.all[0] }

  /// Systems → Fourier: selects a catalog system, tunes the carrier to it and jumps to Fourier.
  func select(system s: RF.RadioSystem, jump: Bool = true) {
    apply(system: s)
    if jump { page = .fourier }
    app?.haptics.success()
    app?.showToast("Simulating \(s.name) at \(SpectraFormat.frequency(s.carrier))", symbol: "waveform.path.ecg")
  }

  /// Makes `s` the shared system: carrier, and a fresh modulation override and link bandwidth.
  private func apply(system s: RF.RadioSystem) {
    let changedSystem = s.id != systemID
    systemID = s.id
    carrier = s.carrier
    if changedSystem {
      var f = fourier
      f.modulation = nil
      if f.message == .voice, !Self.supportsVoice(s.waveform) { f.message = .auto }
      if f.message == .text, !Self.supportsText(s.waveform) { f.message = .auto }
      fourier = f
      link.bandwidth = nil
    }
    restartProducer()
  }

  /// The Systems card the page should scroll to (set when another tab opens a card).
  private(set) var systemsScrollTarget: String?

  /// Prefix of the markers other tabs focus to open a Systems card (Live's "You are on 5G NR
  /// NSA → open card"): `live.system.<RF.SystemsCatalog id>`.
  static let systemMarkerPrefix = "live.system."

  /// Opens the Systems page on a catalog card: selects the system, clears filters that would
  /// hide it and scrolls to it. Returns false for an unknown id.
  @discardableResult
  func openSystemCard(id: String) -> Bool {
    guard let s = RF.SystemsCatalog.system(id: id) else { return false }
    apply(system: s)
    reveal(s)
    page = .systems
    systemsScrollTarget = s.id
    app?.showToast("\(s.generation) · \(s.name)", symbol: "antenna.radiowaves.left.and.right")
    return true
  }

  /// Clears a filter chip or "only in this iPhone" that would hide `s`'s card.
  private func reveal(_ s: RF.RadioSystem) {
    if let c = filter.category, c != s.category { filter = .all }
    if iPhoneOnly, s.iPhone == .no { iPhoneOnly = false }
  }

  /// Fourier → "Change system": the Systems page, scrolled to the selected system's card.
  func showSelectedSystemCard() {
    reveal(system)
    page = .systems
    systemsScrollTarget = systemID
  }

  /// Called once the Systems page has scrolled to `systemsScrollTarget`.
  func clearSystemsScrollTarget() { systemsScrollTarget = nil }

  /// Reacts to every `app.focus(_:)` (re-focusing the same marker counts again).
  private func watchFocus() {
    guard let app else { return }
    withObservationTracking {
      _ = app.focusedMarker
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.handleFocusedMarker()
        self.watchFocus()
      }
    }
  }

  private func handleFocusedMarker() {
    guard let app, let id = app.focusedMarker?.id, id.hasPrefix(Self.systemMarkerPrefix) else { return }
    openSystemCard(id: String(id.dropFirst(Self.systemMarkerPrefix.count)))
    // `@Observable` skips the notification when an equal value is set, so a second "open card"
    // for the same system would only switch tabs. The hand-off marker is not on the strip, so
    // consuming it here makes the next focus a change again.
    app.focusedMarker = nil
  }

  /// "Tune Spectrum here": sends the carrier to the Spectrum tab (the loop).
  func tuneSpectrum() {
    app?.sendToSpectrum(lambda: lambda, label: "the radio carrier \(SpectraFormat.frequency(carrier))")
  }

  /// "Open in Scope": the radio I/Q streams (and the demodulated audio for analog systems).
  func openInScope() {
    guard let app else { return }
    restartProducer()
    app.openScope(["radio.i", "radio.q"], preset: "radio-iq")
  }

  /// "Add to Patch": a source node bound to the radio I stream.
  func addToPatch(_ id: StreamID = "radio.i", label: String = "Radio I/Q") {
    guard let app else { return }
    let before = app.selectedTab
    app.patch.addStreamSource(id, label: label)
    if app.selectedTab == before, app.toast == nil {
      app.haptics.success()
      app.showToast("Added \(label) to Patch", symbol: "point.3.connected.trianglepath.dotted")
    }
  }

  // MARK: Reset

  /// Restores the visible page's dials (Dials sheet → Reset dials).
  func resetDials() {
    switch page {
    case .antenna:
      // The carrier knob sits in this sheet too; its default is the selected system's carrier.
      carrier = system.carrier
      let style = antenna.style
      var p = RF.AntennaParameters(style: style, frequency: carrier)
      p.referenceImpedance = 50
      antenna = p
      lobeScale = .decibel
      reference = .vertical
      aperturePlane = .e
      fresnelRatio = 0
      beamLock = false
    case .systems:
      filter = .all
      iPhoneOnly = false
    case .fourier:
      var f = RadioFourierSettings()
      f.message = fourier.message
      f.text = fourier.text
      fourier = f
      tfView = .both
      traceSource = .received
    case .link:
      link = RadioLinkSettings()
    }
  }

  /// Recentres the 3D view (Dials sheet → Reset alignment).
  func resetAlignment() {
    scene.camera = AntennaScene.home
  }

  // MARK: Visibility

  /// Called by the page views on appear/disappear.
  func setVisible(_ page: RadioPage, _ visible: Bool) {
    if visible { visiblePages.insert(page) } else { visiblePages.remove(page) }
    refreshDemand()
  }

  private var radioTabVisible: Bool { app?.selectedTab == .radio }

  /// Starts and stops what depends on visibility: the motion sensor for Follow phone, the
  /// Beam lock loop and the stream producer.
  func refreshDemand() {
    guard let app else { return }
    let active = app.isActive
    if active != wasActive {
      wasActive = active
      // Leaving the foreground: write the debounced save now (the app may not come back).
      if !active { store.flush() }
    }
    let antennaOnScreen = active && radioTabVisible && page == .antenna && visiblePages.contains(.antenna)
    let wantMotion = followPhone && antennaOnScreen
    if wantMotion != motionHeld {
      motionHeld = wantMotion
      if wantMotion { app.live.acquire(.motion, by: "radio.follow") } else { app.live.release(.motion, by: "radio.follow") }
    }
    let follow = followPhone && antennaOnScreen
    if scene.follow != follow { scene.follow = follow }
    aimWhenAttitudeArrives()
    let locked = wantMotion && beamLock && antenna.style == .phasedArray
    if scene.beamLocked != locked { scene.beamLocked = locked }
    updateLockLoop(running: locked)
    let fourierOnScreen = radioTabVisible && page == .fourier && visiblePages.contains(.fourier)
    let wantStreams = active && (fourierOnScreen || app.selectedTab == .live || app.selectedTab == .patch)
    if wantStreams { startProducerIfNeeded() } else { stopProducer() }
    fourierEngine.setRunning(active && fourierOnScreen)
  }

  // MARK: Antenna builds

  private func rebuildAntenna() {
    antennaTask?.cancel()
    let p = antenna
    antennaTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(12))
      guard !Task.isCancelled else { return }
      let build = await Task.detached(priority: .userInitiated) { RadioAntennaBuild(p) }.value
      guard !Task.isCancelled, let self else { return }
      self.antennaBuild = build
      self.buildRevision &+= 1
      self.loadScene(build)
      self.rebuildAperture()
    }
  }

  private func loadScene(_ build: RadioAntennaBuild) {
    let band = BandPalette.rgb(forWavelength: build.model.wavelength)
    let glyph = AntennaGlyph(build.model.parameters, phaseX: build.phaseX, phaseY: build.phaseY)
    scene.update(build, scale: lobeScale.scale, band: band, glyph: glyph)
  }

  private func rebuildAperture() {
    apertureTask?.cancel()
    guard let build = antennaBuild else { return }
    let model = build.model
    let plane = aperturePlane
    let ratio = fresnelRatio
    apertureComputing = true
    apertureTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(40))
      guard !Task.isCancelled else { return }
      let result = await Task.detached(priority: .utility) { () -> RadioApertureBuild? in
        let spacing = RadioApertureBuild.requestedSpacing(for: model)
        let d = model.apertureDistribution(plane: plane, spacing: spacing)
        let ff = model.fieldRegions.farField / model.wavelength
        return RadioApertureBuild.make(d, ratio: ratio, farFieldWavelengths: ff)
      }.value
      guard !Task.isCancelled, let self else { return }
      self.apertureBuild = result
      self.apertureComputing = false
    }
  }

  // MARK: Attitude, Follow phone, Beam lock

  /// Antenna local frame → device: local z along the phone's long axis (device y), local y
  /// out of the back (−device z): a −90° turn about x.
  nonisolated static let mount = simd_quatd(angle: -Double.pi / 2, axis: SIMD3(1, 0, 0))
  /// The phone standing upright facing you (device y up, screen toward the viewer, who looks
  /// north): device → world is +90° about x, so the antenna's local frame equals the world's.
  nonisolated static let upright = simd_quatd(angle: Double.pi / 2, axis: SIMD3(1, 0, 0))

  /// The phone's attitude (device → CoreMotion world) from the motion channel's
  /// `attitude.pitch/yaw/roll` streams (degrees): R = Rz(yaw)·Rx(pitch)·Ry(roll).
  func phoneAttitude() -> simd_quatd? {
    guard let app,
      let p = app.streams.stream("attitude.pitch")?.ring.latest,
      let y = app.streams.stream("attitude.yaw")?.ring.latest,
      let r = app.streams.stream("attitude.roll")?.ring.latest
    else { return nil }
    return Self.attitude(pitchDeg: Double(p.value), yawDeg: Double(y.value), rollDeg: Double(r.value))
  }

  nonisolated static func attitude(pitchDeg: Double, yawDeg: Double, rollDeg: Double) -> simd_quatd {
    let k = Double.pi / 180
    let qz = simd_quatd(angle: yawDeg * k, axis: SIMD3(0, 0, 1))
    let qx = simd_quatd(angle: pitchDeg * k, axis: SIMD3(1, 0, 0))
    let qy = simd_quatd(angle: rollDeg * k, axis: SIMD3(0, 1, 0))
    return simd_normalize(qz * qx * qy)
  }

  /// Antenna local → world: the live phone attitude while following (and available), else the
  /// phone upright.
  var antennaAttitude: simd_quatd {
    let phone = (followPhone ? phoneAttitude() : nil) ?? Self.upright
    return simd_normalize(phone * Self.mount)
  }

  /// True when Follow phone is on but no attitude has arrived yet.
  var waitingForAttitude: Bool { followPhone && phoneAttitude() == nil }

  /// Points the target at the beam's current world direction ("Aim here").
  func aimAtBeam() {
    aimPending = false
    let peak = antennaBuild?.model.peakDirection ?? SIMD3(0, 0, 1)
    target = simd_normalize(antennaAttitude.act(peak))
    app?.haptics.detent()
  }

  /// Follow phone just turned on: sets the target to the beam's direction as soon as the live
  /// attitude is there (before that the antenna stands in upright).
  private func aimWhenAttitudeArrives() {
    guard aimPending, followPhone, antennaBuild != nil, phoneAttitude() != nil else { return }
    aimAtBeam()
  }

  /// The pattern, polarization and gain toward the target (or the beam peak), from
  /// `RF.AntennaModel.linkFactor`.
  func linkFactor() -> (patternDB: Double, polarizationDB: Double, gainDB: Double)? {
    guard let model = antennaBuild?.model else { return nil }
    let att = antennaAttitude
    let toward = target ?? simd_normalize(att.act(model.peakDirection))
    return model.linkFactor(attitude: att, toward: toward, reference: reference)
  }

  /// Polarization loss toward the target as a positive dB (for the link budget).
  var plfLossDB: Double {
    guard let f = linkFactor() else { return 0 }
    return max(0, -f.polarizationDB) + 0  // + 0 turns −0 into 0 for display
  }

  private func updateFollow() {
    if !followPhone { target = nil }
    refreshDemand()
  }

  private func updateLockLoop(running: Bool) {
    if running {
      guard lockTask == nil else { return }
      lockTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(100))
          guard let self else { return }
          self.aimWhenAttitudeArrives()
          self.steerToTarget()
        }
      }
    } else {
      lockTask?.cancel()
      lockTask = nil
    }
  }

  /// Beam lock: re-steers the array toward the target in its local frame
  /// (`RF.AntennaModel.localDirection` + `steering(toward:)`).
  private func steerToTarget() {
    guard antenna.style == .phasedArray, let target, let phone = phoneAttitude() else { return }
    let att = simd_normalize(phone * Self.mount)
    let local = RF.AntennaModel.localDirection(world: target, attitude: att)
    let s = RF.AntennaModel.steering(toward: local)
    let theta = min(max(s.theta, -90), 90)
    let phi = s.phi
    if abs(theta - antenna.steerTheta) > 0.5 || abs(Self.wrap(phi - antenna.steerPhi)) > (theta < 1 ? 360 : 1) {
      // One assignment, so one rebuild.
      var p = antenna
      p.steerTheta = theta
      p.steerPhi = phi
      antenna = p
    }
    let behind = local.z < 0
    if targetBehind != behind { targetBehind = behind }
  }

  /// True when the Beam-lock target sits behind the array (the steering folds it to the front).
  private(set) var targetBehind = false

  nonisolated static func wrap(_ deg: Double) -> Double {
    var d = deg.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
  }

  // MARK: Link budget

  /// The receiver noise bandwidth the Link page uses: the knob, else the system's own.
  var linkBandwidth: Double { link.bandwidth ?? systemNoiseBandwidth }

  /// The system's widest channel; for a catalog entry that lists none (6G is not standardized,
  /// Qi is an unmodulated power carrier) the bandwidth its simulated waveform occupies, which is
  /// 0 (CW) for a tone.
  var systemNoiseBandwidth: Double {
    system.maxChannelWidth ?? RF.WaveformSettings(waveform: system.waveform).occupiedBandwidth
  }

  /// True when the Link page uses the simulated waveform's width because the catalog lists no
  /// channel width for the system (6G).
  var linkBandwidthIsPlaceholder: Bool {
    link.bandwidth == nil && system.maxChannelWidth == nil && systemNoiseBandwidth > 0
  }

  /// Transmit antenna gain on the Link page.
  var linkTxGainDBi: Double {
    link.useAntennaGain ? (antennaBuild?.model.gainDBi ?? 0) : link.txGainDBi
  }

  var linkInput: RF.LinkBudgetInput {
    var x = RF.LinkBudgetInput(frequency: carrier, bandwidth: linkBandwidth)
    x.txPowerDBm = link.txPowerDBm
    x.txGainDBi = linkTxGainDBi
    x.rxGainDBi = link.rxGainDBi
    x.distance = link.distance
    x.model = link.environment.model(exponent: link.exponent)
    x.walls = RF.Building.Material.allCases.compactMap { m in
      let n = link.walls[m.rawValue] ?? 0
      return n > 0 ? RF.WallLayer(m, count: n) : nil
    }
    x.rainRate = link.rainRate
    x.includeGas = link.gas
    // A path longer than 100 km leaves the atmosphere: rain and gas act over its lowest 10 km.
    if link.distance > 100_000, link.rainRate > 0 || link.gas { x.atmosphericPathLength = Self.atmosphereThickness }
    x.noiseFigureDB = link.noiseFigureDB
    x.polarizationLossDB = link.includePLF ? plfLossDB : 0
    x.systemPeakRate = system.peakRate?.value
    return x
  }

  static let atmosphereThickness = 10_000.0

  var linkResult: RF.LinkBudgetResult { RF.LinkBudget.evaluate(linkInput) }

  /// The Live check's model: log-distance at 2.44 GHz with the BLE transmit power and exponent.
  var bleInput: RF.LinkBudgetInput {
    var x = RF.LinkBudgetInput(frequency: 2.44e9, bandwidth: 1e6)
    x.txPowerDBm = link.bleTxPowerDBm
    x.txGainDBi = 0
    x.rxGainDBi = 0
    x.model = .logDistance(exponent: link.bleExponent, referenceDistance: 1)
    return x
  }

  // MARK: Fourier configuration

  /// The end-to-end baseband configuration for the selected system and the Fourier knobs.
  var basebandConfig: RF.BasebandLinkConfig {
    var c = RF.BasebandLinkConfig(system: system)
    let f = fourier
    c.snrDB = f.snrDB
    c.delaySpread = f.delaySpread
    c.dopplerHz = f.fading == .none ? 0 : f.dopplerHz
    c.fading = Self.fadingKind(f)
    if let m = f.modulation, system.waveform.dataModulation != nil { c.modulation = m }
    if f.message == .text, Self.supportsText(system.waveform), !f.text.isEmpty { c.message = .text(f.text) }
    return c
  }

  nonisolated static func fadingKind(_ f: RadioFourierSettings) -> RF.FadingKind {
    switch f.fading {
    case .none: .none
    case .rayleigh: .rayleigh
    case .rician: .rician(k: pow(10, f.ricianKdB / 10))
    }
  }

  nonisolated static func isAnalog(_ w: RF.Waveform) -> Bool {
    switch w {
    case .analogAM, .analogFM: true
    default: false
    }
  }

  /// Text messages need a digital data path.
  nonisolated static func supportsText(_ w: RF.Waveform) -> Bool {
    switch w {
    case .tone, .chirp, .analogAM, .analogFM: false
    default: true
    }
  }

  /// Voice: AM/FM carry it directly; every digital system carries it over the QPSK voice link.
  nonisolated static func supportsVoice(_ w: RF.Waveform) -> Bool {
    switch w {
    case .tone, .chirp: false
    default: true
    }
  }

  private func messageChanged(from old: RadioMessage) {
    fourierEngine.messageChanged()
  }

  // MARK: Stream producer (radio.i / radio.q / radio.audio)

  private var producerConfigKey: Int {
    var h = Hasher()
    h.combine(basebandConfig)
    return h.finalize()
  }

  private func startProducerIfNeeded() {
    let key = producerConfigKey
    if producerTask != nil, producerKey == key { return }
    producerTask?.cancel()
    producerKey = key
    let config = basebandConfig
    let streams = RadioStreamProducer.Streams(i: streamI, q: streamQ, audio: streamAudio)
    let engine = fourierEngine
    producerTask = Task.detached(priority: .utility) {
      var producer = RadioStreamProducer(config: config, streams: streams)
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(20))
        let voiceOwnsAudio = await MainActor.run { engine.voiceOwnsAudio }
        producer.produce(until: SignalClock.now(), writeAudio: !voiceOwnsAudio)
      }
    }
  }

  private func stopProducer() {
    producerTask?.cancel()
    producerTask = nil
    producerKey = nil
  }

  /// Applies a new configuration to a running producer.
  private func restartProducer() {
    guard producerTask != nil else { return }
    if producerKey != producerConfigKey {
      stopProducer()
      refreshDemand()
    }
  }

  // MARK: Persistence

  private func changed() {
    guard !loading else { return }
    store.schedule(saved)
  }

  private var saved: RadioSaved {
    RadioSaved(
      carrier: carrier, page: page, systemID: systemID, antenna: antenna, followPhone: followPhone, beamLock: beamLock,
      lobeScale: lobeScale, reference: reference, aperturePlane: aperturePlane, fresnelRatio: fresnelRatio, filter: filter,
      iPhoneOnly: iPhoneOnly, fourier: fourier, tfView: tfView, traceSource: traceSource, link: link)
  }

  private func restore(_ s: RadioSaved) {
    loading = true
    defer { loading = false }
    if let id = s.systemID, RF.SystemsCatalog.system(id: id) != nil { systemID = id }
    if let c = s.carrier, c.isFinite { carrier = min(max(c, Self.carrierRange.lowerBound), Self.carrierRange.upperBound) }
    if let a = s.antenna {
      var p = a.sanitized()
      p.frequency = carrier
      antenna = p
    }
    if let p = s.page { page = p }
    if let v = s.lobeScale { lobeScale = v }
    if let v = s.reference { reference = v }
    if let v = s.aperturePlane { aperturePlane = v }
    if let v = s.fresnelRatio, v.isFinite { fresnelRatio = min(max(v, 0), Self.fresnelRange.upperBound) }
    if let v = s.filter { filter = v }
    if let v = s.iPhoneOnly { iPhoneOnly = v }
    if var v = s.fourier {
      // Voice needs a tap on push-to-talk each session; it restarts as random bits.
      if v.message == .voice { v.message = .auto }
      fourier = v
    }
    if let v = s.tfView { tfView = v }
    if let v = s.traceSource { traceSource = v }
    if var v = s.link {
      v.bleDevice = nil
      link = v
    }
    // Follow phone and Beam lock need the motion sensor: they start off each launch.
  }

  static let fresnelRange: ClosedRange<Double> = 0...2

  /// `-open radio/<page>[/<style | system id>]`.
  private func applyLaunchPath(_ path: String) {
    let parts = path.split(separator: "/").map(String.init)
    guard let first = parts.first, let p = RadioPage(rawValue: first.lowercased()) else { return }
    page = p
    guard parts.count > 1 else { return }
    let extra = parts[1]
    switch p {
    case .antenna:
      if let style = RF.AntennaStyle.allCases.first(where: { $0.rawValue.lowercased() == extra.lowercased() }) {
        antenna.style = style
      } else if extra.lowercased() == "follow" {
        followPhone = true
      }
    case .systems, .fourier, .link:
      if let s = RF.SystemsCatalog.system(id: extra) {
        // Like a card tap: a fresh modulation override, link bandwidth and a message the
        // system can carry; a saved filter that would hide the card is cleared.
        apply(system: s)
        if p == .systems {
          reveal(s)
          systemsScrollTarget = s.id
        }
      }
      if parts.count > 2, p == .fourier, let m = RadioMessage(rawValue: parts[2].lowercased()) {
        let w = system.waveform
        let carries = m == .auto || (m == .text && Self.supportsText(w)) || (m == .voice && Self.supportsVoice(w))
        if carries { fourier.message = m }
      }
    }
  }

  // MARK: Stub physics kept for AppTests

  /// Far-field power pattern of a half-wave dipole in its E-plane, dB relative to the
  /// maximum, at `count` angles from the dipole axis (0°) round the circle:
  /// F(θ) = cos(π/2 · cos θ) / sin θ (`rf-physics.md` verified reference; F² at 30° is
  /// −7.5808 dB).
  nonisolated static func halfWaveDipolePattern(count: Int = 180) -> [Double] {
    (0..<max(3, count)).map { i in
      let theta = 2 * Double.pi * Double(i) / Double(max(3, count))
      return halfWaveDipoleGainDB(theta: theta)
    }
  }

  /// 10·log₁₀ F²(θ) for the half-wave dipole, floored at −60 dB on the axis.
  nonisolated static func halfWaveDipoleGainDB(theta: Double) -> Double {
    let s = sin(theta)
    guard abs(s) > 1e-9 else { return -60 }
    let f = cos(Double.pi / 2 * cos(theta)) / s
    return max(-60, 10 * log10(max(f * f, 1e-12)))
  }
}
