import Foundation
import Observation
import SwiftUI

/// Decompose's four tabs: the three web tabs and Utkarsh's Phase space.
enum DecomposePage: String, CaseIterable, Identifiable {
  case polarization, probe, fourier, phase
  var id: String { rawValue }

  var title: String {
    switch self {
    case .polarization: "Polarization"
    case .probe: "Probe charge"
    case .fourier: "Fourier"
    case .phase: "Phase space"
    }
  }

  /// Segment label (the full title is the accessibility label).
  var short: String {
    switch self {
    case .polarization: "Polarization"
    case .probe: "Probe"
    case .fourier: "Fourier"
    case .phase: "Phase space"
    }
  }
}

/// The Spectrum tab's model (SPEC.md §3.4): wraps the ported `SpectraState`, owns the Wave
/// scope and Φ-cube scenes, the phase-space computation, the streams it publishes and the
/// native extras, and persists everything under `Spectra.spectrum.v1`.
///
/// Physics comes from `Core/` (and `Phase/` for the spacetime Wigner); this class only routes
/// edits, plays the detents and remembers settings.
@Observable @MainActor
final class SpectrumModel: TabModel {
  /// The web prototype's state: sources A/B/C, medium, κ and per-instrument settings. The
  /// native app always runs with the extended ruler (λ up to 100,000 km).
  var state: SpectraState {
    didSet {
      guard state != oldValue else { return }
      revision &+= 1
      waveScene.state = state
      if state.lab.sweeping, sweepTask == nil { runSweep() }
      changed()
    }
  }

  /// Native settings: cameras, tuner window, Phase space, Earth-field lab mode.
  var extras: SpectrumExtras {
    didSet {
      guard extras != oldValue else { return }
      waveScene.camera = extras.camera
      syncWignerScene()
      changed()
    }
  }

  /// Bumped on every state change; the Wave scope's paused canvas redraws on it.
  private(set) var revision = 0

  /// Shows the full-screen pop-out of the current instrument.
  var fullscreen = false

  let waveScene = WaveScene()
  let wignerScene = WignerScene()
  let phase = SpectrumPhaseModel()
  let streams = SpectrumStreams()

  @ObservationIgnored weak var app: AppModel?
  @ObservationIgnored private let store = JSONStore<SpectrumSaved>(key: "Spectra.spectrum.v1")
  @ObservationIgnored private let persists: Bool
  @ObservationIgnored private var probeCache: (key: [Double], geometry: ProbeGeometry)?
  @ObservationIgnored private var stemCache: (sources: [WaveSource], medium: Matter.Medium, stems: FourierStems)?
  @ObservationIgnored private var labCurves: [String: [Double]] = [:]
  @ObservationIgnored private var labMaxima: [String: Double] = [:]
  @ObservationIgnored private var lastResonant: Set<SpecimenKey> = []
  @ObservationIgnored private var labOnPeak = false
  @ObservationIgnored private var humming: Set<String> = []
  @ObservationIgnored private var sweepTask: Task<Void, Never>?

  init() {
    persists = !LaunchOptions.current.uiTesting
    var s = SpectraState()
    var x = SpectrumExtras()
    if persists, let saved = store.load() {
      s = saved.state
      x = saved.extras
    }
    s.extendedRange = true
    s.sanitizeSources()
    state = s
    extras = x
    waveScene.state = s
    waveScene.camera = x.camera
    syncWignerScene()
    // Only a Spectrum path: `-open radio/fourier` must not switch this tab to Decompose.
    if LaunchOptions.current.openTab == .spectrum { applyOpenPath(LaunchOptions.current.openPath) }
  }

  /// The Φ cube's camera and slice planes follow the Phase space settings.
  private func syncWignerScene() {
    wignerScene.camera = extras.phase.camera
    wignerScene.tSlice = Float(2 * extras.phase.tFraction - 1)
    wignerScene.xSlice = Float(2 * extras.phase.xFraction - 1)
  }

  func attach(to app: AppModel) {
    self.app = app
    streams.attach(model: self, app: app)
    // A sweep saved while running resumes (it holds until someone watches it).
    if state.lab.sweeping { runSweep() }
    #if DEBUG
      if SpectrumSnapshots.requested { SpectrumSnapshots.run(app: app) }
      SpectrumSnapshots.runChecksIfRequested()
    #endif
  }

  // MARK: Loop

  /// Sources A, B and C while they are on (MODEL).
  var markers: [SpectrumMarker] {
    state.sources.indices.compactMap { i -> SpectrumMarker? in
      let s = state.sources[i]
      guard s.enabled else { return nil }
      let letter = SpectraState.sourceNames[i]
      let label = s.kind == .thermal ? "Source \(letter) · \(SpectraFormat.significant(s.temperature, 4)) K glow" : "Source \(letter)"
      return SpectrumMarker(id: "spectrum.\(letter)", label: label, lambda: s.lambda, provenance: .model, tab: .spectrum)
    }
  }

  /// Source A's vacuum wavelength, m (the stage-1 API; setting it tunes source A).
  var sourceALambda: Double {
    get { state.sources[0].lambda }
    set { tune(lambda: newValue) }
  }

  /// Tunes source A to `lambda` (metres) from anywhere in the app ("Tune Spectrum here").
  /// A thermal source A becomes a plane wave, since a glow has no single wavelength.
  func tune(lambda: Double) {
    guard lambda.isFinite, lambda > 0 else { return }
    var s = state
    s.extendedRange = true
    s.active = 0
    s.sources[0].enabled = true
    if s.sources[0].kind == .thermal { s.sources[0].kind = .plane }
    let before = s.sources[0].lambda
    s.edit(.lambda(lambda))
    s.preset = nil
    state = s
    playDetents(from: before, to: state.sources[0].lambda)
    follow()
  }

  // MARK: Editing

  /// The active source.
  var active: WaveSource { state.activeSource }

  /// Edits the active source (Link applies a relative change to every enabled source) and
  /// plays one detent per band edge, ionizing line or long-wave landmark crossed.
  func edit(_ e: SpectraState.SourceEdit, quiet: Bool = false) {
    let before = state.activeSource.lambda
    var s = state
    s.edit(e)
    s.preset = nil
    state = s
    let after = state.activeSource.lambda
    if !quiet, after != before { playDetents(from: before, to: after) }
  }

  /// Sets the active source's wavelength; a thermal source takes the temperature whose Wien
  /// peak sits there instead.
  func setLambda(_ lambda: Double) {
    guard lambda.isFinite, lambda > 0 else { return }
    if active.kind == .thermal {
      edit(.temperature(SpectrumDisplay.thermalTemperature(atLog: log10(lambda))))
    } else {
      edit(.lambda(lambda))
    }
    follow()
  }

  /// One detent per crossed band edge (detent), ionizing line (firm stop) or landmark.
  func playDetents(from before: Double, to after: Double) {
    let crossed = Spectrum.crossedRulerDetents(fromLog: log10(before), toLog: log10(after))
    guard !crossed.isEmpty else { return }
    if crossed.contains(where: { $0.kind == .ionizing }) {
      Haptics.shared.boundary()
    } else {
      Haptics.shared.detent()
    }
  }

  /// Band segmented control: jump the active source to the band's representative λ.
  func jump(to band: Spectrum.BandKey) {
    guard let lambda = Spectrum.bandJump[band] else { return }
    setLambda(lambda)
    follow()
  }

  /// Applies one of the 14 field trips: sources, medium, instrument and its settings, and
  /// restarts the clock.
  func apply(preset p: SpectraPreset) {
    var s = state
    s.apply(p)
    s.extendedRange = true
    state = s
    if p.decompose != nil { extras.phasePage = false }
    if p.lab != nil { extras.labEarth = false }
    app?.clock.reset()
    follow()
    Haptics.shared.success()
    app?.showToast("\(p.name): \(p.note)", symbol: "map")
  }

  func select(_ instrument: SpectraState.Instrument) {
    guard state.instrument != instrument else { return }
    state.instrument = instrument
    if instrument == .lab { ensureLabMode() }
    // The tuner opens with the active cursor in its window.
    if instrument == .tuner { follow() }
  }

  /// Selects source A, B or C for editing.
  func selectSource(_ index: Int) {
    guard state.sources.indices.contains(index) else { return }
    state.active = index
  }

  /// Turns the active source on or off (one source always stays on, as in the web lab).
  func setActiveEnabled(_ on: Bool) {
    var s = state
    s.edit(.enabled(on))
    if !s.sources.contains(where: \.enabled) { s.sources[0].enabled = true }
    s.preset = nil
    state = s
  }

  /// Plane wave, pulse or thermal for the active source.
  func setKind(_ kind: WaveSource.Kind) {
    edit(.kind(kind))
    if kind == .thermal { edit(.temperature(active.temperature)) }
  }

  /// Web "Reset dials": the active source (every source with Link on) back to its default,
  /// keeping whether it is on.
  func resetDials() {
    let base = SpectraState().sources
    var s = state
    let targets = s.link ? Array(s.sources.indices) : [s.active]
    for i in targets where s.sources.indices.contains(i) {
      let enabled = s.sources[i].enabled
      s.sources[i] = base[i]
      s.sources[i].enabled = enabled
    }
    s.extendedRange = true
    s.sanitizeSources()
    s.preset = nil
    state = s
    follow()
  }

  /// Every view back to its framing: scope camera, tuner window, Φ cube camera.
  func resetAlignment() {
    extras.camera = .waveScopeHome
    extras.tunerLow = TunerWindow.web.lowerBound
    extras.tunerHigh = TunerWindow.web.upperBound
    extras.phase.camera = .wignerCubeHome
    follow()
  }

  /// The instrument's own Align (web `align`).
  func align() {
    switch state.instrument {
    case .scope:
      extras.camera = .waveScopeHome
    case .tuner:
      setTunerWindow(TunerWindow.web)
      follow()
    case .bench:
      break
    case .decompose:
      if decomposePage == .phase {
        extras.phase.camera = .wignerCubeHome
        extras.phase.tFraction = 0.5
        extras.phase.xFraction = 0.5
      } else {
        state.decompose.polarizer = 30
        state.decompose.a0 = 1.5
      }
    case .lab:
      if extras.labEarth { extras.earthSweep = 0 } else { state.lab.sweep = 0 }
      state.lab.sweeping = false
      tuneLab()
    }
  }

  /// Whether the current instrument has something to align.
  var canAlign: Bool { state.instrument != .bench }

  // MARK: Tuner window

  var tunerWindow: ClosedRange<Double> { extras.tunerLow...extras.tunerHigh }

  func setTunerWindow(_ w: ClosedRange<Double>) {
    let c = TunerWindow.clamp(low: w.lowerBound, high: w.upperBound)
    extras.tunerLow = c.lowerBound
    extras.tunerHigh = c.upperBound
  }

  /// Keeps the active cursor inside the tuner window after a programmatic tune.
  func follow() {
    let lg = log10(active.lambda)
    let w = TunerWindow.following(tunerWindow, lg: lg)
    if w != tunerWindow { setTunerWindow(w) }
  }

  // MARK: Decompose

  var decomposePage: DecomposePage {
    get {
      extras.phasePage ? .phase : (DecomposePage(rawValue: state.decompose.tab.rawValue) ?? .polarization)
    }
    set {
      if newValue == .phase {
        extras.phasePage = true
      } else {
        extras.phasePage = false
        if let tab = SpectraState.DecomposeSettings.Tab(rawValue: newValue.rawValue) { state.decompose.tab = tab }
      }
    }
  }

  /// The probe charge's exact trajectory and its drawing geometry (extents, drift-frame
  /// inset), cached by (a₀, mode, θ, δ) so the 60 fps canvas does no per-frame work on it.
  func probeGeometry() -> ProbeGeometry {
    let src = active
    let d = state.decompose
    let modeIndex = Double(Wave.ProbeMode.allCases.firstIndex(of: d.probeMode) ?? 0)
    let key = [d.a0, modeIndex, src.theta, src.delta]
    if let cache = probeCache, cache.key == key { return cache.geometry }
    let points = SpectrumDisplay.probeTrajectory(src, a0: d.a0, mode: d.probeMode)
    let geometry = ProbeGeometry(points, thetaDeg: src.theta, mode: d.probeMode)
    probeCache = (key, geometry)
    return geometry
  }

  /// The Fourier page's stems (every component of every source on screen) and their
  /// log-frequency axis, cached per sources and medium: they do not change from frame to frame.
  func fourierStems() -> FourierStems {
    let ds = waveScene.displaySources
    if let cache = stemCache, cache.sources == state.sources, cache.medium == state.medium { return cache.stems }
    var list: [FourierStems.Stem] = []
    for d in ds.list {
      for c in Wave.components(d.source, count: SpectrumDisplay.fourierStemCount) {
        list.append(FourierStems.Stem(lambda: c.lambda, logF: log10(SI.c / c.lambda), a: c.amp * d.scale))
      }
    }
    let stems = FourierStems(
      stems: list, maxA: max(1e-30, list.map(\.a).max() ?? 1),
      axis: list.isEmpty ? nil : SpectrumDisplay.stemAxis(logFrequencies: list.map(\.logF)))
    stemCache = (state.sources, state.medium, stems)
    return stems
  }

  // MARK: Matter bench

  /// Every specimen's answer for the active source.
  func benchResults() -> [SpecimenKey: SpecimenResult] {
    let src = active
    let options = SpecimenOptions(lambda0: state.bench.lambda0)
    var out: [SpecimenKey: SpecimenResult] = [:]
    for key in SpecimenKey.allCases { out[key] = key.evaluate(src.lambda, source: src, options: options) }
    return out
  }

  /// Specimens on resonance (DNA band, oscillator on resonance, antenna above half current).
  static func resonant(_ key: SpecimenKey, _ r: SpecimenResult) -> Bool {
    if r.response.resonance == true { return true }
    if key == .oscillator, r.response.regime == .on { return true }
    if key == .antenna, (r.response.value ?? 0) > 0.5 { return true }
    return false
  }

  /// Plays a resonance thump when a specimen newly comes into resonance.
  func noteResonances(_ keys: Set<SpecimenKey>) {
    if !keys.subtracting(lastResonant).isEmpty { Haptics.shared.resonance(0.8) }
    lastResonant = keys
  }

  // MARK: Spectroscopy lab

  var labSample: SampleKey { state.lab.sample }

  /// Keeps the lab mode legal for its sample (web `build`).
  func ensureLabMode() {
    let s = state.lab.sample
    if !s.modes.contains(state.lab.mode) { state.lab.mode = s.modes[0] }
    if s != .nmr, extras.labEarth { extras.labEarth = false }
  }

  func selectSample(_ sample: SampleKey) {
    var s = state
    s.lab.sample = sample
    s.lab.sweep = 0
    s.lab.sweeping = false
    if !sample.modes.contains(s.lab.mode) { s.lab.mode = sample.modes[0] }
    state = s
    extras.labEarth = false
    labOnPeak = false
    tuneLab()
  }

  func selectMode(_ mode: SampleMode) {
    state.lab.mode = mode
    state.lab.sweeping = false
    extras.labEarth = false
    labOnPeak = false
    tuneLab()
  }

  /// Spin's "Open in Lab": the Spectroscopy lab in the NMR sample's Earth-field mode. The
  /// integrator adds `extension SpectrumModel: SpinEarthFieldLab {}` (the protocol lives in
  /// `UI/Spin/SpinModel.swift`, which the stage-2 baseline does not have).
  func openEarthFieldLab() {
    fullscreen = false
    select(.lab)
    selectEarthMode()
    follow()
  }

  /// The NMR sample's third mode: the live magnetometer magnitude sets B₀.
  func selectEarthMode() {
    var s = state
    s.lab.sample = .nmr
    s.lab.sweeping = false
    if !SampleKey.nmr.modes.contains(s.lab.mode) { s.lab.mode = .nmr400 }
    state = s
    extras.labEarth = true
    labOnPeak = false
    tuneLab()
  }

  /// The cursor position 0…1 of whichever axis is showing.
  var labSweep: Double { extras.labEarth ? extras.earthSweep : state.lab.sweep }

  func setLabSweep(_ u: Double) {
    let v = min(1, max(0, u.isFinite ? u : 0))
    if extras.labEarth { extras.earthSweep = v } else { state.lab.sweep = v }
    tuneLab()
  }

  /// Sweep retunes the active source to the wavelength the cursor probes, and thumps when the
  /// cursor reaches a strong feature (web `lab.draw`).
  func tuneLab() {
    if extras.labEarth {
      setLambda(EarthFieldAxis.lambda(at: extras.earthSweep))
    } else {
      let s = state.lab.sample
      setLambda(s.toLambda(s.axis.x(at: state.lab.sweep), mode: state.lab.mode))
    }
    noteLabPeak(labReading() > 0.35)
  }

  // MARK: Earth-field NMR (live |B|)

  /// The magnetometer magnitude |B| in µT, averaged over the last half second, while the
  /// Earth-field mode is on screen (nil before the first sample).
  var earthField: Double?
  /// LIVE on a phone, SIM with fakes or in the Simulator.
  var earthProvenance: Provenance = .live

  /// The water-proton line γ′ₚ·|B| (Hz), from Core (shielded γ′ₚ, the Spin tab's value).
  var earthLine: Double? {
    guard let b = earthField, b.isFinite, b > 0 else { return nil }
    return Samples.earthFieldLarmor(b0: b * 1e-6)
  }

  /// Moves the Earth-field cursor onto the live line and tunes source A to it.
  func tuneToEarthLine() {
    guard let f = earthLine else {
      Haptics.shared.boundary()
      return
    }
    state.lab.sweeping = false
    setLabSweep(EarthFieldAxis.fraction(of: f))
    Haptics.shared.success()
  }

  func toggleSweep() {
    if state.lab.sweeping {
      state.lab.sweeping = false
      return
    }
    if labSweep >= 0.999 { setLabSweep(0) }
    app?.clock.playing = true
    state.lab.sweeping = true
  }

  /// Advances the automatic sweep (axis fraction per second, `SpectrumDisplay.labSweepRate`).
  func advanceSweep(dt: Double) {
    guard state.lab.sweeping, dt > 0 else { return }
    let next = min(1, labSweep + dt * SpectrumDisplay.labSweepRate)
    setLabSweep(next)
    if next >= 1 { state.lab.sweeping = false }
  }

  /// Whether a running sweep is being watched: the lab on the Spectrum tab, or the detector
  /// (`spectrum.lab`) drawing the spectrum like a chart recorder in the Scope on the Live tab
  /// or in Patch.
  private var sweepWatched: Bool {
    guard let app, state.instrument == .lab else { return false }
    switch app.selectedTab {
    case .spectrum: return true
    case .live, .patch: return streams.labOnBus
    case .radio, .spin: return false
    }
  }

  /// Runs the sweep by the app clock's own time (so Step, pause and background behave as
  /// everywhere else), waking about 30 times a second while `state.lab.sweeping`. The model
  /// owns it rather than a view: a tab that is not showing cancels its views' tasks, which
  /// froze the detector in the Scope. It holds (no catch-up) while nobody watches.
  private func runSweep() {
    guard sweepTask == nil, app != nil else { return }
    sweepTask = Task { [weak self] in
      var last: Double?
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(33))
        guard let self, let app = self.app, self.state.lab.sweeping else { break }
        let now = app.clock.time
        let live = app.clock.isAnimating && self.sweepWatched
        if live, let last { self.advanceSweep(dt: min(AppClock.maxStep, max(0, now - last))) }
        last = live ? now : nil
      }
      self?.sweepTask = nil
    }
  }

  /// The sample's curve on `count + 1` points, normalized to its maximum (cached).
  func labCurve(_ sample: SampleKey, _ mode: SampleMode, count: Int = 720) -> [Double] {
    let key = "\(sample.rawValue)|\(mode.rawValue)|\(count)"
    if let c = labCurves[key] { return c }
    let max = labMaximum(sample, mode)
    let curve = (0...count).map { sample.value(sample.axis.x(at: Double($0) / Double(count)), mode: mode) / max }
    labCurves[key] = curve
    return curve
  }

  /// The detector reading at the cursor (normalized). In the Earth-field mode it is the
  /// water-proton line drawn at the screen's resolution (`EarthFieldAxis.displayHalfWidth`).
  func labReading() -> Double {
    if extras.labEarth {
      guard let f0 = earthLine else { return 0 }
      return Samples.lorentz(EarthFieldAxis.frequency(at: extras.earthSweep), f0, EarthFieldAxis.displayHalfWidth)
    }
    let s = state.lab.sample
    let max = labMaximum(s, state.lab.mode)
    return s.value(s.axis.x(at: state.lab.sweep), mode: state.lab.mode) / max
  }

  /// `SpectrumDisplay.labMaximum` (2,401 evaluations), cached per sample and mode.
  func labMaximum(_ sample: SampleKey, _ mode: SampleMode) -> Double {
    let key = "\(sample.rawValue)|\(mode.rawValue)"
    if let m = labMaxima[key] { return m }
    let m = SpectrumDisplay.labMaximum(sample, mode: mode)
    labMaxima[key] = m
    return m
  }

  /// Resonance thump when the cursor crosses a strong feature (> 35 % of the maximum).
  func noteLabPeak(_ onPeak: Bool) {
    if onPeak, !labOnPeak { Haptics.shared.resonance(0.6) }
    labOnPeak = onPeak
  }

  // MARK: Phase space

  /// Rebuilds the phase-space request from the sources and settings and hands it to the
  /// background computation (debounced there).
  func refreshPhase() {
    let built = PhaseSpaceRequestBuilder.build(state: state, settings: extras.phase)
    phase.request(built, cube: extras.phase, scene: wignerScene)
  }

  // MARK: Sound

  /// With Sound on, each enabled source hums at a pitch mapped from its real frequency while
  /// the Spectrum tab is visible and the clock runs (spectra-lab `setTones`).
  func updateHums(visible: Bool) {
    guard let app else { return }
    let on = visible && app.settings.soundOn && app.clock.playing && app.selectedTab == .spectrum
    let enabled = on ? state.enabledIndices : []
    let owners = Set(enabled.map { "spectrum.hum.\(SpectraState.sourceNames[$0])" })
    for owner in humming.subtracting(owners) { app.synth.releaseVoice(for: owner) }
    humming = owners
    guard on else { return }
    let level = 0.12 / Double(max(1, enabled.count))
    for i in enabled {
      let owner = "spectrum.hum.\(SpectraState.sourceNames[i])"
      let f = Spectrum.frequency(state.sources[i].lambda)
      app.synth.voice(for: owner)?.tone(SpectrumDisplay.soundPitch(frequency: f), level: level, pan: Double(i - 1) * 0.4)
    }
  }

  // MARK: Transport

  /// κ-slowed time mapping for the reference source, plus the scope/patch actions for the
  /// field (and the lab detector when the lab is showing).
  func transport() -> TransportConfig {
    let f = Spectrum.frequency(state.referenceSource.lambda)
    var actions = [
      TransportAction(id: "spectrum-transport-scope", title: "Open field in Scope", symbol: "waveform.path.ecg") {
        [weak self] in self?.openFieldInScope()
      },
      TransportAction(id: "spectrum-transport-patch", title: "Add field to Patch", symbol: "point.3.connected.trianglepath.dotted") {
        [weak self] in self?.addFieldToPatch()
      },
    ]
    if state.instrument == .lab {
      actions.append(
        TransportAction(id: "spectrum-transport-lab-scope", title: "Open detector in Scope", symbol: "chart.xyaxis.line") {
          [weak self] in self?.openLabInScope()
        })
    }
    return TransportConfig(timeMapping: .slowed(factor: state.slowMotion), frequency: f, actions: actions)
  }

  // MARK: Scope and Patch

  func openFieldInScope() {
    guard let app else { return }
    app.openScope(streams.ensureField())
  }

  func addFieldToPatch() {
    guard let app else { return }
    for id in streams.ensureField() {
      app.patch.addStreamSource(id, label: id == SpectrumStreams.ex ? "Spectrum Ex" : "Spectrum Ey")
    }
  }

  func openLabInScope() {
    guard let app else { return }
    if extras.labEarth {
      app.openScope(["mag.norm"], preset: "Magnetic scope")
    } else {
      app.openScope(streams.ensureLab())
    }
  }

  func addLabToPatch() {
    guard let app else { return }
    if extras.labEarth {
      app.patch.addStreamSource("mag.norm", label: "|B| (Earth-field NMR)")
    } else {
      for id in streams.ensureLab() { app.patch.addStreamSource(id, label: "Spectroscopy detector") }
    }
  }

  // MARK: Knob compatibility

  /// Source A's wavelength knob (stage-1 API, kept for tests and other tabs): log from
  /// 0.1 pm to 100,000 km with band-edge and long-wave detents.
  static let lambdaKnob = KnobSpec(
    id: "spectrum-lambda", title: "Wavelength", glyph: "λ", tint: Theme.phosphor, range: 1e-13...1e8,
    defaultValue: 550e-9, logarithmic: true, detents: SpectrumKnobs.lambdaDetents,
    hint: "Vacuum wavelength. Hue follows the band; inside the visible it is the spectral color.",
    format: { SpectrumKnobs.lambdaText($0) })

  // MARK: Persistence

  private func changed() {
    guard persists else { return }
    store.schedule(SpectrumSaved(state: state, extras: extras))
  }

  /// Writes a pending save now (the tab calls it when the app leaves the foreground, so an
  /// edit made just before the app is closed is not lost to the 400 ms debounce).
  func flush() {
    guard persists else { return }
    store.flush()
  }

  /// `-open spectrum/<instrument>[/<page>]`: tuner, bench, lab, lab/earth, decompose/phase, …
  private func applyOpenPath(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    let parts = path.lowercased().split(separator: "/").map(String.init)
    let aliases: [String: SpectraState.Instrument] = [
      "scope": .scope, "wave": .scope, "tuner": .tuner, "bench": .bench, "matter": .bench, "decompose": .decompose,
      "lab": .lab, "spectroscopy": .lab, "polarization": .decompose, "probe": .decompose, "fourier": .decompose,
      "phase": .decompose, "earth": .lab,
    ]
    guard let first = parts.first, let instrument = aliases[first] else { return }
    state.instrument = instrument
    let page = first == "decompose" || first == "lab" ? parts.dropFirst().first : first
    switch page {
    case "polarization", "probe", "fourier", "phase":
      decomposePage = DecomposePage(rawValue: page!) ?? .polarization
    case "earth":
      state.lab.sample = .nmr
      if !SampleKey.nmr.modes.contains(state.lab.mode) { state.lab.mode = .nmr400 }
      extras.labEarth = true
    default:
      if let key = page, let sample = SampleKey(rawValue: key) {
        state.lab.sample = sample
        state.lab.mode = sample.modes[0]
        extras.labEarth = false
      }
    }
    if parts.contains("fullscreen") { fullscreen = true }
  }
}
