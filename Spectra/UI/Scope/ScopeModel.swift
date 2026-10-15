import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// What the trigger is doing (the status word in the display's corner).
nonisolated enum ScopeStatus: Equatable, Sendable {
  case triggered, auto, waiting, stopped, single, roll, xy, analysis, noSignal

  var text: String {
    switch self {
    case .triggered: "TRIG'D"
    case .auto: "AUTO"
    case .waiting: "WAIT"
    case .stopped: "STOP"
    case .single: "SINGLE"
    case .roll: "ROLL"
    case .xy: "XY"
    case .analysis: "RUN"
    case .noSignal: "NO SIGNAL"
    }
  }

  var meaning: String {
    switch self {
    case .triggered: "Triggered: each sweep starts on the trigger edge."
    case .auto: "Auto: no trigger edge, so the scope free-runs."
    case .waiting: "Waiting for a trigger edge; only triggered sweeps are drawn, the last one stays."
    case .stopped: "Stopped: the display is frozen."
    case .single: "Armed for a single sweep."
    case .roll: "Rolling: newest samples at the right edge."
    case .xy: "XY: channel X against channel Y."
    case .analysis: "Analyzing the newest window."
    case .noSignal: "No samples yet on the shown channels."
    }
  }
}

/// The readouts the views show, refreshed at about 5 Hz (never per frame).
struct ScopeReadout: Equatable {
  var status: ScopeStatus = .noSignal
  /// Index 0…3 = CH1…CH4, 4 = math.
  var measurements: [Int: ScopeEngine.Measurements] = [:]
  var rates: [Int: Double] = [:]
  var aliasNotes: [ScopeEngine.AliasNote] = []
  /// The same notes per channel (0…3), so the FFT marks only what its own channel aliases.
  var channelAliasNotes: [Int: [ScopeEngine.AliasNote]] = [:]
  var sampleCounts: [Int: Int] = [:]
  /// Seconds since the newest sample on the shown channels (stale data shows as "waiting").
  var dataAge: Double?
}

/// A finished time–frequency picture for the Spectrogram / Wigner–Ville / Pseudo-Wigner modes.
struct ScopeTFDisplay {
  var mode: ScopeMode
  var image: CGImage?
  /// |x(t)|² as measured by the image (M1) and the reference |z(t)|², normalised to the max.
  var timeMarginal: [Float]
  var intensity: [Float]
  /// Σ_t W Δt (M2) and |Z(ν)|², normalised to the max.
  var frequencyMarginal: [Float]
  var spectrum: [Float]
  var sampleRate: Double
  var duration: Double
  var samples: Int
  var decimation: Int
  /// Max |M1 − |z|²| / max |z|² and max |M2 − |Z|²| / max |Z|².
  var m1Error: Double
  var m2Error: Double
  var resampled: Bool
}

/// The pixel data a background task produces (Sendable; the `CGImage` is made on the main actor).
nonisolated struct ScopeTFResult: Sendable {
  var width: Int
  var height: Int
  var pixels: [UInt8]
  var timeMarginal: [Float]
  var intensity: [Float]
  var frequencyMarginal: [Float]
  var spectrum: [Float]
  var m1Error: Double
  var m2Error: Double
}

/// The visible window as CSV (share sheet), built only when the user exports.
nonisolated struct ScopeExport: Transferable, Sendable {
  var columns: [ScopeEngine.CSVColumn]
  var origin: Double

  var isEmpty: Bool { columns.allSatisfy { $0.times.isEmpty } }

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .commaSeparatedText) { item in
      Data(ScopeEngine.csv(item.columns, origin: item.origin).utf8)
    }
    .suggestedFileName("Spectra scope.csv")
  }
}

/// The universal oscilloscope's model (SPEC-features §3b, §3c): settings, acquisition (trigger,
/// sweeps, roll, XY), the phosphor frame for `ScopeCanvas`, measurements, FFT and the
/// time–frequency modes, sensor acquisition with owner "scope", presets and CSV export.
///
/// Per-frame work runs in `buildScopeFrame` (called by the Metal display) or `tick()` (the
/// analysis modes' timeline) and touches only `@ObservationIgnored` state; the observed
/// readouts change at about 5 Hz, so SwiftUI does not re-render every frame.
@Observable @MainActor
final class ScopeModel: ScopeFrameSource {
  /// Owner name for `SensorHub.acquire` (the Live tab's Scope page).
  static let mainOwner = "scope"
  /// The Live tab's scope: one instance for the app's lifetime, so its state survives page and
  /// tab switches.
  static let main = ScopeModel(owner: mainOwner, persistent: true)
  /// Sensors the user started with a tap this session (later visits may start them again).
  private static var tappedSensors: Set<SensorID> = []

  let owner: String
  let persistent: Bool
  /// Fixed streams of an embedded scope (Patch sink, previews); nil for the Live page.
  let fixedStreams: [StreamID]?

  private(set) var settings: ScopeSettings
  private(set) var running = true
  private(set) var readout = ScopeReadout()
  private(set) var spectrum: ScopeEngine.Spectrum?
  private(set) var spectrumResampledRate: Double?
  private(set) var timeFrequency: ScopeTFDisplay?
  /// Sensors a channel needs that wait for a tap (they would show a permission prompt).
  private(set) var blockedSensors: [SensorID] = []
  /// Bumped when the display must redraw while stopped.
  private(set) var revision = 0
  private(set) var export = ScopeExport(columns: [], origin: 0)

  @ObservationIgnored weak var app: AppModel?
  @ObservationIgnored private var store: JSONStore<ScopeSettings>?
  /// One track per channel (CH1…CH4); replaced when the channel's stream changes, so a
  /// stream that is no longer shown does not keep its samples (or its ring) alive.
  @ObservationIgnored private var channelTracks: [ScopeTrack?] = [nil, nil, nil, nil]
  /// Plain tracks for math inputs that read a stream directly, pruned with the math settings.
  @ObservationIgnored private var auxTracks: [StreamID: ScopeTrack] = [:]
  /// FFT setups reused by the 5 Hz measurements.
  @ObservationIgnored private var peakAnalyzers = ScopeEngine.PeakAnalyzers()
  @ObservationIgnored private var mathTrack: ScopeMathTrack?
  @ObservationIgnored private var mathKey: MathKey?
  @ObservationIgnored private var heldSensors: Set<SensorID> = []
  /// Sensors started from a channel sheet's source list, held while that sheet is open.
  @ObservationIgnored private var browsingSensors: Set<SensorID> = []
  private(set) var visible = false
  @ObservationIgnored private(set) var probes = ScopeProbeStreams()
  @ObservationIgnored private var lastTick = -Double.infinity
  @ObservationIgnored private var lastReadout = -Double.infinity
  @ObservationIgnored private var lastResolve = -Double.infinity
  /// When each channel's resolved stream was first seen missing while its sensor ran.
  @ObservationIgnored private var missingSince: [Int: Double] = [:]
  @ObservationIgnored private var lastSpectrum = -Double.infinity
  @ObservationIgnored private var lastTF = -Double.infinity
  @ObservationIgnored private var tfTask: Task<Void, Never>?
  /// Bumped whenever a pending time–frequency result must be dropped (mode or channel change,
  /// disappear), so a late result neither lands on the wrong picture nor clears a newer task.
  @ObservationIgnored private var tfGeneration = 0
  @ObservationIgnored private var spectrumCache = ScopeEngine.SpectrumCache()
  @ObservationIgnored private var appliedRequest: UUID?
  /// The last "Open in Scope" request the view scrolled the display into view for.
  @ObservationIgnored var revealedRequest: UUID?
  // Acquisition state (YT).
  @ObservationIgnored private var currentSweep: ClosedRange<Double>?
  @ObservationIgnored private var lastTrigger: Double?
  @ObservationIgnored private var lastTriggerWall = -Double.infinity
  @ObservationIgnored private var searched = -Double.infinity
  @ObservationIgnored private var newSweeps: [ClosedRange<Double>] = []
  @ObservationIgnored private var lastFreeRunAccumulated = -Double.infinity
  @ObservationIgnored private var status: ScopeStatus = .noSignal
  @ObservationIgnored private var frozenEnd: Double?
  @ObservationIgnored private var lastXYEnd: Double?
  @ObservationIgnored private var clearPersistence = true
  @ObservationIgnored private var rollWasAuto = false
  @ObservationIgnored private var sweepRate = 0.0
  @ObservationIgnored private var analysisWindowChecked = false
  /// The timebase in use before FFT or a time–frequency mode lengthened it; restored when the
  /// scope goes back to YT, Roll or XY (unless the user turned the timebase meanwhile).
  @ObservationIgnored private var timebaseBeforeAnalysis: Double?
  @ObservationIgnored private var lastHaptic = -Double.infinity

  init(owner: String, persistent: Bool, fixedStreams: [StreamID]? = nil) {
    self.owner = owner
    self.persistent = persistent
    self.fixedStreams = fixedStreams
    var s = ScopeSettings()
    if persistent, !LaunchOptions.current.uiTesting {
      let store = JSONStore<ScopeSettings>(key: ScopeSettings.storageKey)
      self.store = store
      if let saved = store.load() { s = saved }
    }
    if let fixedStreams {
      for i in 0..<4 {
        s.channels[i] = ScopeChannel()
        s.channels[i].enabled = i < fixedStreams.count
        s.channels[i].stream = i < fixedStreams.count ? fixedStreams[i] : nil
      }
      s.preset = nil
    } else if s.preset == nil, s.channels.allSatisfy({ $0.stream == nil && $0.query == nil }) {
      ScopePreset.magnetic.configure(&s)
    }
    settings = s
  }

  // MARK: - Lifecycle

  /// The scope became visible: bind to the app, apply a pending "Open in Scope" request, start
  /// the sensors its channels need.
  func appear(app: AppModel) {
    self.app = app
    visible = true
    if fixedStreams == nil { applyPendingRequest() }
    resolveChannels(force: true)
    updateAcquisition()
    clearPersistence = true
  }

  /// The scope left the screen: release every sensor and simulated stream.
  func disappear() {
    visible = false
    cancelTimeFrequency()
    if let app {
      app.live.releaseAll(by: owner)
      probes.stopAll(registry: app.streams)
    }
    heldSensors = []
    browsingSensors = []
    blockedSensors = []
    // A running scope rebuilds its tracks from the rings on the next visit; a stopped one keeps
    // its frozen samples.
    if running {
      channelTracks = [nil, nil, nil, nil]
      auxTracks = [:]
      mathTrack = nil
      mathKey = nil
    }
    store?.flush()
  }

  /// Writes pending settings now (the app is leaving the foreground).
  func flushSettings() { store?.flush() }

  private func cancelTimeFrequency() {
    tfTask?.cancel()
    tfTask = nil
    tfGeneration &+= 1
  }

  /// Back to acquiring: clears a frozen window (after Stop or a Single capture).
  private func resume() {
    running = true
    frozenEnd = nil
  }

  /// Applies `app.scopeRequest` if it is new (the Live page follows it; embedded scopes don't).
  func applyPendingRequest() {
    guard fixedStreams == nil, let request = app?.scopeRequest, request.id != appliedRequest else { return }
    appliedRequest = request.id
    let preset = request.preset.flatMap(ScopePreset.init(name:))
    if let preset { applyPreset(preset, tapped: true) }
    if !request.streams.isEmpty {
      let streams = Array(request.streams.prefix(4))
      mutate { s in
        if preset != nil {
          // A stream the probe already asks for by meaning goes to that channel and keeps its
          // coupling, scale and position ("|B| in Scope" with the Magnetic probe lands on the
          // |B| trace, not on CH1's AC-coupled X band; two Bluetooth radios and |B| fill CH1,
          // CH2 and CH4, not CH3's dBm band).
          var free = Array(0..<4)
          var unplaced: [StreamID] = []
          for id in streams {
            if let i = free.first(where: { s.channels[$0].enabled && s.channels[$0].query.map { self.query($0, matches: id) } == true }) {
              s.channels[i].stream = id
              free.removeAll { $0 == i }
            } else {
              unplaced.append(id)
            }
          }
          // A probe channel that already resolved to one of these streams looks again, so no
          // stream is drawn twice (CH2's "second strongest radio" may be the radio just pinned
          // to CH1).
          let pinned = Set(streams)
          for i in free where s.channels[i].query != nil {
            if let id = s.channels[i].stream, pinned.contains(id) { s.channels[i].stream = nil }
          }
          // The rest take the channels the probe leaves empty first, so an extra stream does
          // not replace one of the probe's own traces.
          free.sort { a, b in
            let ea = s.channels[a].enabled && s.channels[a].query != nil
            let eb = s.channels[b].enabled && s.channels[b].query != nil
            return ea != eb ? !ea : a < b
          }
          for (id, i) in zip(unplaced, free) {
            let position = s.channels[i].enabled && s.channels[i].query != nil ? s.channels[i].position : 0
            s.channels[i] = ScopeChannel(stream: id)
            s.channels[i].position = position
          }
        } else {
          // Just these streams, DC-coupled and auto-scaled, stacked in their own bands like a
          // probe (a coupling or position left over from the last probe would hide them: an
          // AC-coupled battery level is a flat line).
          let layout: [[Double]] = [[0], [2, -2], [3, 1, -1], [3, 1, -1, -3]]
          for i in 0..<4 {
            if i < streams.count {
              s.channels[i] = ScopeChannel(stream: streams[i])
              s.channels[i].position = layout[streams.count - 1][i]
            } else {
              s.channels[i].enabled = false
            }
          }
          s.preset = nil
          s.math.enabled = false
          if s.trigger.source >= streams.count {
            s.trigger.source = 0
            s.trigger.level = 0
          }
          if s.measureChannel >= streams.count { s.measureChannel = 0 }
          if s.analysisChannel >= streams.count { s.analysisChannel = 0 }
          if s.xChannel >= streams.count || s.yChannel >= streams.count {
            s.xChannel = 0
            s.yChannel = min(1, streams.count - 1)
          }
          if s.mode == .xy, streams.count < 2 { s.mode = .yt }
        }
      }
      // An "Open in Scope" tap is the user's tap: sensors behind those streams may prompt.
      for id in request.streams {
        if let sensor = ScopeEngine.sensor(for: id, group: app?.streams.stream(id)?.group) {
          Self.tappedSensors.insert(sensor)
        }
      }
    }
    resume()
    resetAcquisition()
    updateAcquisition()
  }

  // MARK: - Settings

  /// Changes settings, persists them and keeps acquisition consistent.
  func mutate(_ change: (inout ScopeSettings) -> Void) {
    var next = settings
    change(&next)
    guard next != settings else { return }
    let old = settings
    settings = next
    cachedRange = nil
    store?.schedule(next)
    if old.channels.map(\.stream) != next.channels.map(\.stream) || old.channels.map(\.enabled) != next.channels.map(\.enabled)
      || old.channels.map(\.query) != next.channels.map(\.query) || old.math != next.math || old.preset != next.preset
    {
      resolveChannels(force: true)
      updateAcquisition()
    }
    if old.mode != next.mode || old.timebase != next.timebase || old.channels != next.channels
      || old.math != next.math || old.xChannel != next.xChannel || old.yChannel != next.yChannel
    {
      clearPersistence = true
    }
    if old.mode != next.mode || old.timebase != next.timebase || old.trigger != next.trigger {
      // Turning the level, slope or holdoff keeps the last sweep on screen until the next
      // edge, as on a bench scope (Normal would otherwise blank while the knob turns).
      let sameSweep =
        old.mode == next.mode && old.timebase == next.timebase && old.trigger.mode == next.trigger.mode
        && old.trigger.source == next.trigger.source
      resetAcquisition(keepingSweep: sameSweep)
    }
    // A newly analyzed channel (another channel, or another stream on it) may be slower: check
    // again that the window holds enough of its samples (a 10 Hz illuminance after the 2.4 kHz
    // flicker would otherwise read "Collecting samples…" for good).
    let a = next.analysisChannel
    if old.analysisChannel != a || (a < 4 && old.channels[a].stream != next.channels[a].stream) || (a == 4 && old.math != next.math) {
      analysisWindowChecked = false
    }
    if old.mode != next.mode || old.analysisChannel != next.analysisChannel {
      spectrum = nil
      spectrumResampledRate = nil
      timeFrequency = nil
      lastSpectrum = -.infinity
      lastTF = -.infinity
      cancelTimeFrequency()
    }
    if old.math != next.math { pruneAuxTracks() }
    revision &+= 1
  }

  /// Drops direct-stream tracks the math channel no longer reads.
  private func pruneAuxTracks() {
    let m = settings.math
    var keep = Set<StreamID>()
    if m.enabled {
      for source in [m.a, m.b, m.c].prefix(m.operation.inputs) { if case .stream(let id) = source { keep.insert(id) } }
    }
    auxTracks = auxTracks.filter { keep.contains($0.key) }
  }

  func applyPreset(_ preset: ScopePreset, tapped: Bool) {
    if tapped { for sensor in preset.sensors { Self.tappedSensors.insert(sensor) } }
    mutate { preset.configure(&$0) }
    rollWasAuto = false
    analysisWindowChecked = false
    timebaseBeforeAnalysis = nil
    resume()
    resetAcquisition()
    resolveChannels(force: true)
    updateAcquisition()
  }

  func setMode(_ mode: ScopeMode) {
    rollWasAuto = false
    analysisWindowChecked = false
    let restore = mode == .fft || mode.isTimeFrequency ? nil : timebaseBeforeAnalysis
    if restore != nil { timebaseBeforeAnalysis = nil }
    mutate { s in
      s.mode = mode
      if let restore { s.timebase = restore }
    }
  }

  /// On entering FFT or a time–frequency mode, lengthens the window (never shortens it) so the
  /// analysed record holds enough samples: FFT ≥ 1024 samples and ≥ 0.1 s; time–frequency
  /// ≥ 1024 samples and ≥ 0.5 s (at most 20 s).
  private func ensureAnalysisWindow() {
    guard !analysisWindowChecked, settings.mode == .fft || settings.mode.isTimeFrequency else { return }
    let i = settings.analysisChannel
    guard isShown(i), let r = rate(i), r > 0 else { return }
    analysisWindowChecked = true
    let need = settings.mode == .fft ? max(0.1, 1024 / r) : min(20, max(0.5, 1024 / r))
    let options = timebaseOptions
    guard timebase * Double(ScopeEngine.divisionsX) < need * (1 - 1e-9),
      let tb = options.first(where: { $0 * Double(ScopeEngine.divisionsX) >= need * (1 - 1e-9) }) ?? options.last
    else { return }
    if timebaseBeforeAnalysis == nil { timebaseBeforeAnalysis = settings.timebase }
    mutate { $0.timebase = tb }
  }

  /// The allowed timebases for the shown channels (one sample per division at the fastest
  /// stream … the longest history).
  var timebaseOptions: [Double] {
    let range = timebaseRange
    return ScopeEngine.timebases.filter { $0 >= range.lowerBound * (1 - 1e-9) && $0 <= range.upperBound * (1 + 1e-9) }
  }

  /// Read several times per frame (window, trigger, auto-scale, readouts), so it is cached for
  /// a quarter second and dropped whenever settings or a channel's stream change.
  var timebaseRange: ClosedRange<Double> {
    let now = SignalClock.now()
    if let r = cachedRange, now - cachedRangeAt < 0.25 { return r }
    let r = computeTimebaseRange()
    cachedRange = r
    cachedRangeAt = now
    return r
  }

  @ObservationIgnored private var cachedRange: ClosedRange<Double>?
  @ObservationIgnored private var cachedRangeAt = -Double.infinity
  @ObservationIgnored private var cachedTimebase: (setting: Double, range: ClosedRange<Double>, value: Double)?

  private func computeTimebaseRange() -> ClosedRange<Double> {
    let shown = shownTracks
    guard !shown.isEmpty else { return ScopeEngine.timebases[0]...ScopeEngine.timebases[ScopeEngine.timebases.count - 1] }
    let rates = shown.map { $0.isIrregular ? nil : ($0.stream.nominalRate > 0 ? $0.stream.nominalRate : nil) }
    let histories = shown.map { ScopeEngine.history(ringCapacity: $0.stream.ring.capacity, rate: $0.isIrregular ? nil : $0.stream.nominalRate) }
    // The fastest stream sets the floor.
    let floors = rates.map { ScopeEngine.minimumTimebase(sampleRate: $0) }
    let lo = floors.min() ?? ScopeEngine.timebases[0]
    let hi = max(lo, ScopeEngine.maximumTimebase(history: histories.max() ?? 30))
    return lo...hi
  }

  /// The timebase in use: the setting snapped onto what the streams can show.
  var timebase: Double {
    let range = timebaseRange
    if let c = cachedTimebase, c.setting == settings.timebase, c.range == range { return c.value }
    let value = ScopeEngine.clampTimebase(settings.timebase, to: range)
    cachedTimebase = (settings.timebase, range, value)
    return value
  }

  func setTimebase(_ value: Double) {
    timebaseBeforeAnalysis = nil
    let snapped = ScopeEngine.clampTimebase(value, to: timebaseRange)
    mutate { s in
      s.timebase = snapped
      if snapped >= ScopeEngine.rollThreshold, s.mode == .yt {
        s.mode = .roll
        rollWasAuto = true
      } else if snapped < ScopeEngine.rollThreshold, s.mode == .roll, rollWasAuto {
        s.mode = .yt
        rollWasAuto = false
      }
    }
  }

  // MARK: - Run / Stop

  func toggleRun() {
    if running {
      stop()
    } else {
      running = true
      frozenEnd = nil
      if settings.trigger.mode == .single { mutate { $0.trigger.mode = .auto } }
      resetAcquisition()
    }
    revision &+= 1
  }

  private func stop() {
    running = false
    frozenEnd = latestShownTime
    status = .stopped
    refreshReadout(force: true)
  }

  /// Arms one triggered sweep (switches to Single, YT).
  func armSingle() {
    mutate { s in
      s.trigger.mode = .single
      if s.mode != .yt { s.mode = .yt }
    }
    running = true
    frozenEnd = nil
    resetAcquisition()
    status = .single
    refreshReadout(force: true)
    revision &+= 1
  }

  /// Fits every shown channel's scale to its data and centres the trigger level.
  func autoset() {
    tick()
    mutate { s in
      let window = displayWindow
      for i in 0..<4 where s.channels[i].enabled {
        guard let track = track(for: i) else { continue }
        let w = track.fitSamples(window)
        guard let lo = w.values.filter(\.isFinite).min(), let hi = w.values.filter(\.isFinite).max() else { continue }
        // Keeps each trace where it is (stacked traces stay stacked) and fits it to its band.
        let target = abs(s.channels[i].position) < 0.05 ? 6.0 : 1.6
        let fit = ScopeEngine.autoScale(minimum: Double(lo), maximum: Double(hi), unit: track.stream.unit, divisions: target)
        s.channels[i].unitsPerDiv = fit.unitsPerDiv
        s.channels[i].reference = fit.reference
        s.channels[i].autoScale = true
        if s.trigger.source == i { s.trigger.level = fit.reference }
      }
      // The math trace too ("every channel"), in its own band like the inputs.
      if s.math.enabled, let m = mathSamples() {
        let w = m.window(window, margin: true)
        if let lo = w.values.filter(\.isFinite).min(), let hi = w.values.filter(\.isFinite).max() {
          let target = abs(s.math.position) < 0.05 ? 6.0 : 1.6
          let fit = ScopeEngine.autoScale(minimum: Double(lo), maximum: Double(hi), unit: unit(4), divisions: target)
          s.math.unitsPerDiv = fit.unitsPerDiv
          s.math.reference = fit.reference
          s.math.autoScale = true
          if s.trigger.source == 4 { s.trigger.level = fit.reference }
        }
      }
    }
  }

  private func resetAcquisition(keepingSweep: Bool = false) {
    if !keepingSweep { currentSweep = nil }
    lastTrigger = nil
    lastTriggerWall = SignalClock.now()
    searched = -.infinity
    newSweeps = []
    lastFreeRunAccumulated = -.infinity
    lastXYEnd = nil
    clearPersistence = true
  }

  // MARK: - Sensors

  /// The sensor behind channel `i`'s stream or query.
  func sensor(forChannel i: Int) -> SensorID? {
    guard i < 4 else { return nil }
    let ch = settings.channels[i]
    if let id = ch.stream { return ScopeEngine.sensor(for: id, group: app?.streams.stream(id)?.group) }
    if let q = ch.query { return Self.sensor(forGroup: q.group) }
    return nil
  }

  static func sensor(forGroup group: String) -> SensorID? {
    switch group {
    case StreamGroup.magnetometer: .magnetometer
    case StreamGroup.motion: .motion
    case StreamGroup.air: .barometer
    case StreamGroup.audio: .microphone
    case StreamGroup.bluetooth: .bluetooth
    case StreamGroup.network: .network
    case StreamGroup.location: .location
    case StreamGroup.light: .light
    case StreamGroup.device: .charging
    default: nil
    }
  }

  /// Every sensor the shown channels, the math inputs and the preset need.
  var neededSensors: Set<SensorID> {
    var out = Set<SensorID>()
    for i in 0..<4 where settings.channels[i].enabled {
      if let s = sensor(forChannel: i) { out.insert(s) }
    }
    if settings.math.enabled {
      // Only the inputs the operation reads (d/dt of A does not start B's sensor).
      let inputs = settings.math.operation.inputs
      for source in [settings.math.a, settings.math.b, settings.math.c].prefix(inputs) {
        if case .stream(let id) = source, let s = ScopeEngine.sensor(for: id, group: app?.streams.stream(id)?.group) {
          out.insert(s)
        }
      }
      for q in settings.math.queries.prefix(inputs) { if let q, let s = Self.sensor(forGroup: q.group) { out.insert(s) } }
    }
    if let preset = settings.preset { out.formUnion(preset.sensors) }
    return out
  }

  /// Starts what may start without a prompt (or was tapped), releases what is no longer needed,
  /// publishes the probes' simulated streams.
  func updateAcquisition() {
    guard visible, let app else { return }
    let needed = neededSensors.union(browsingSensors)
    var blocked: [SensorID] = []
    for id in SensorID.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
      if needed.contains(id) {
        let channel = app.live.channel(id)
        let allowed =
          !id.needsPermission || app.launch.isFaked(id) || channel.state.isRunning || Self.tappedSensors.contains(id)
        if allowed {
          if !heldSensors.contains(id) {
            app.live.acquire(id, by: owner)
            heldSensors.insert(id)
          }
        } else if !heldSensors.contains(id) {
          blocked.append(id)
        }
      } else if heldSensors.contains(id) {
        app.live.release(id, by: owner)
        heldSensors.remove(id)
      }
    }
    if blocked != blockedSensors { blockedSensors = blocked }
    var kinds = Set(settings.preset?.modelStreams ?? [])
    let ids = Set(settings.channels.compactMap { $0.enabled ? $0.stream : nil })
    if ids.contains(ScopeProbeStreams.fidID) { kinds.insert(.spinFID) }
    if ids.contains(ScopeProbeStreams.iID) || ids.contains(ScopeProbeStreams.qID) { kinds.insert(.radioIQ) }
    probes.ensure(kinds, registry: app.streams)
  }

  /// A tap on "Start <sensor>": the permission prompt (if any) belongs to this tap.
  func startSensor(_ id: SensorID) {
    Self.tappedSensors.insert(id)
    updateAcquisition()
    resolveChannels(force: true)
  }

  /// "Start" in a channel sheet's source list: the sensor runs while the sheet is open, so its
  /// streams appear to pick from, and is let go when the sheet closes unless a channel then
  /// shows it (`endBrowsing`). The permission prompt, if any, belongs to this tap.
  func startSensorForPicking(_ id: SensorID) {
    browsingSensors.insert(id)
    startSensor(id)
  }

  /// The channel sheet closed: sensors started only to browse their streams stop again.
  func endBrowsing() {
    guard !browsingSensors.isEmpty else { return }
    browsingSensors = []
    updateAcquisition()
  }

  // MARK: - Streams

  /// Resolves preset queries against the registry (by group and meaning, not fixed ids).
  func resolveChannels(force: Bool = false) {
    guard let app else { return }
    let now = SignalClock.now()
    guard force || now - lastResolve > 1 else { return }
    lastResolve = now
    let candidates = app.streams.streams.map { ScopeEngine.StreamCandidate($0) }
    var next = settings
    var changed = false
    for i in 0..<4 {
      guard let q = next.channels[i].query else { continue }
      if let current = next.channels[i].stream {
        // A probe's stream that has gone (a Bluetooth radio rotated its address, a saved id
        // from an earlier session) is found again by meaning, among streams no other channel
        // shows; until then the channel keeps waiting on the old id. Only once its sensor has
        // been running without it for 2 s, so a sensor that is still starting keeps its ids.
        guard app.streams.stream(current) == nil else {
          missingSince[i] = nil
          continue
        }
        if let sensor = Self.sensor(forGroup: q.group) {
          guard app.live.channel(sensor).state.isRunning else {
            missingSince[i] = nil
            continue
          }
          let since = missingSince[i] ?? now
          missingSince[i] = since
          guard now - since >= 2 else { continue }
        }
        let used = Set(next.channels.indices.compactMap { $0 == i ? nil : next.channels[$0].stream })
        var again = q
        if case .strongest = q.rank { again.rank = .strongest(0) }
        if let id = ScopeEngine.resolve(again, in: candidates.filter { !used.contains($0.id) }), id != current {
          next.channels[i].stream = id
          changed = true
        }
      } else {
        // Two channels never show the same stream by accident (the Network probe's cellular
        // RTT waits instead of repeating the only RTT stream). A ranked query takes the
        // strongest radio no other channel shows: in channel order that is the 1st, 2nd and 3rd
        // strongest, and a radio pinned by "Open in Scope" is not repeated.
        let used = Set(next.channels.indices.compactMap { $0 == i ? nil : next.channels[$0].stream })
        var query = q
        if case .strongest = q.rank { query.rank = .strongest(0) }
        if let id = ScopeEngine.resolve(query, in: candidates.filter { !used.contains($0.id) }) {
          next.channels[i].stream = id
          changed = true
        }
      }
    }
    for k in 0..<3 {
      guard let q = next.math.queries[k] else { continue }
      if let id = ScopeEngine.resolve(q, in: candidates) {
        let source = ScopeSource.stream(id)
        switch k {
        case 0: if next.math.a != source { next.math.a = source; changed = true }
        case 1: if next.math.b != source { next.math.b = source; changed = true }
        default: if next.math.c != source { next.math.c = source; changed = true }
        }
      }
    }
    if changed {
      settings = next
      cachedRange = nil
      store?.schedule(next)
      clearPersistence = true
      pruneAuxTracks()
      revision &+= 1
    }
  }

  /// Whether a probe's query asks for stream `id` (ignoring rank). An id that is not registered
  /// yet (its sensor is still starting) is judged by its id alone, within the query's group.
  func query(_ q: ScopeEngine.StreamQuery, matches id: StreamID) -> Bool {
    let candidate: ScopeEngine.StreamCandidate
    if let s = app?.streams.stream(id) {
      candidate = ScopeEngine.StreamCandidate(s)
    } else {
      // Same group: the same sensor ("mag.norm" → Magnetometer), or the id's first part names
      // it ("radio.i" → Radio, "spin.fid" → Spin).
      let prefix = id.rawValue.split(separator: ".").first.map { $0.lowercased() } ?? ""
      let sensor = ScopeEngine.sensor(for: id)
      guard (sensor != nil && Self.sensor(forGroup: q.group) == sensor) || prefix == q.group.lowercased() else { return false }
      candidate = ScopeEngine.StreamCandidate(id: id, label: id.rawValue, group: q.group, unit: "", rate: 0)
    }
    var any = q
    any.rank = .best
    return ScopeEngine.resolve(any, in: [candidate]) == id
  }

  /// The registered stream shown on channel `i` (nil while it waits for its sensor).
  func stream(forChannel i: Int) -> SignalStream? {
    guard i < 4, let id = settings.channels[i].stream else { return nil }
    return app?.streams.stream(id)
  }

  /// The track of channel `i`, rebuilt when the stream instance or coupling changes.
  func track(for i: Int) -> ScopeTrack? {
    guard i >= 0, i < 4, settings.channels[i].enabled, let stream = stream(forChannel: i) else { return nil }
    let ch = settings.channels[i]
    // A stopped scope keeps its frozen samples when it comes back on screen, although the
    // sensor behind them has restarted with a new stream instance under the same id (Live
    // sources and the probe streams make a fresh one per run); Run then takes the new one.
    if let t = channelTracks[i], t.stream === stream || (!running && t.stream.id == stream.id) {
      if t.coupling == ch.coupling, t.invert == ch.invert, ch.coupling != .removeGravity || now(t.gravityChecked) {
        return t
      }
      let gravity = ch.coupling == .removeGravity ? gravityStream(for: stream) : nil
      t.configure(coupling: ch.coupling, invert: ch.invert, gravity: gravity)
      t.gravityChecked = SignalClock.now()
      return t
    }
    let gravity = ch.coupling == .removeGravity ? gravityStream(for: stream) : nil
    let t = ScopeTrack(stream: stream, coupling: ch.coupling, invert: ch.invert, gravity: gravity)
    t.gravityChecked = SignalClock.now()
    t.ingest()
    channelTracks[i] = t
    cachedRange = nil
    return t
  }

  /// True while a gravity-stream lookup made at `time` is still fresh (2 s): a gravity stream
  /// that appears later (the live builder's device motion) is picked up without a lookup per call.
  private func now(_ time: Double) -> Bool { SignalClock.now() - time < 2 }

  /// A plain (DC) track for a math input that reads a stream directly.
  private func auxTrack(_ id: StreamID) -> ScopeTrack? {
    guard let stream = app?.streams.stream(id) else { return nil }
    // Stopped: the frozen samples stay, as for the channels (`track(for:)`).
    if let t = auxTracks[id], t.stream === stream || !running { return t }
    let t = ScopeTrack(stream: stream, coupling: .dc, invert: false, gravity: nil)
    t.ingest()
    auxTracks[id] = t
    return t
  }

  /// The gravity stream on the same axis as a raw accelerometer stream (none for user
  /// acceleration, which has gravity removed already).
  func gravityStream(for stream: SignalStream) -> SignalStream? {
    guard let app, stream.group == StreamGroup.motion else { return nil }
    let text = (stream.id.rawValue + " " + stream.label).lowercased()
    guard !text.contains("user"), !text.contains("gravity") else { return nil }
    let axis = stream.id.rawValue.split(separator: ".").last.map(String.init) ?? ""
    guard ["x", "y", "z"].contains(axis) else { return nil }
    let candidates = app.streams.streams(in: StreamGroup.motion).map { ScopeEngine.StreamCandidate($0) }
    guard let id = ScopeEngine.resolve(ScopeEngine.StreamQuery(group: StreamGroup.motion, axis: axis, any: ["gravity"]), in: candidates)
    else { return nil }
    return app.streams.stream(id)
  }

  /// Whether channel `i` uses a 0.25 Hz high-pass for "No gravity" (no gravity stream to
  /// subtract, which includes user acceleration).
  func gravityIsFiltered(_ i: Int) -> Bool {
    guard let s = stream(forChannel: i) else { return true }
    return gravityStream(for: s) == nil
  }

  private var shownTracks: [ScopeTrack] {
    (0..<4).compactMap { i in settings.channels[i].enabled ? track(for: i) : nil }
  }

  /// The math channel's track (nil when off or its inputs are missing).
  func mathSamples() -> ScopeMathTrack? {
    let m = settings.math
    guard m.enabled else { return nil }
    func input(_ source: ScopeSource) -> ScopeTrack? {
      switch source {
      case .channel(let i): track(for: i)
      case .stream(let id): auxTrack(id)
      }
    }
    guard let a = input(m.a) else { return nil }
    let b = m.operation.inputs >= 2 ? input(m.b) : nil
    let c = m.operation.inputs >= 3 ? input(m.c) : nil
    if m.operation.inputs >= 2, m.operation != .magnitude, b == nil { return nil }
    let key = MathKey(
      operation: m.operation, cornerHz: m.cornerHz, a: ObjectIdentifier(a), b: b.map(ObjectIdentifier.init),
      c: c.map(ObjectIdentifier.init))
    if mathTrack == nil || key != mathKey {
      mathKey = key
      mathTrack = ScopeMathTrack(operation: m.operation, cornerHz: m.cornerHz, capacity: a.capacity)
    }
    mathTrack?.update(
      a: (a.values, a.times), b: b.map { ($0.values, $0.times) }, c: c.map { ($0.values, $0.times) },
      holdB: b?.isIrregular ?? false, holdC: c?.isIrregular ?? false)
    return mathTrack
  }

  /// Every displayed sample of channel 0…3 or math (4), without copying: the per-frame drawing
  /// passes these whole arrays with a window to `ScopeEngine.trace`, which searches them.
  private func series(_ i: Int) -> (values: [Float], times: [Double])? {
    if i == 4 {
      guard let m = mathSamples() else { return nil }
      return (m.values, m.times)
    }
    guard let t = track(for: i) else { return nil }
    return (t.values, t.times)
  }

  /// Whether more than two samples per pixel column fall in `window` (drawn as an envelope).
  private func isDense(_ times: [Double], in window: ClosedRange<Double>, columns: Int) -> Bool {
    ScopeEngine.upperBound(times, window.upperBound) - ScopeEngine.lowerBound(times, window.lowerBound) > columns * 2
  }

  /// Displayed samples of channel 0…3 or math (4) in `window`.
  func samples(_ i: Int, in window: ClosedRange<Double>, margin: Bool = false) -> (values: [Float], times: [Double])? {
    if i == 4 { return mathSamples()?.window(window, margin: margin) }
    return track(for: i)?.window(window, margin: margin)
  }

  /// Unit of channel 0…3 or math (4).
  func unit(_ i: Int) -> String {
    if i == 4 {
      let m = settings.math
      let ua = unit(of: m.a)
      let ub = unit(of: m.b)
      return m.operation.unit(ua, ub)
    }
    return stream(forChannel: i)?.unit ?? ""
  }

  private func unit(of source: ScopeSource) -> String {
    switch source {
    case .channel(let i): stream(forChannel: i)?.unit ?? ""
    case .stream(let id): app?.streams.stream(id)?.unit ?? ""
    }
  }

  /// Label of channel 0…3 or math (4).
  func label(_ i: Int) -> String {
    if i == 4 {
      let m = settings.math
      return m.label ?? m.operation.formula
    }
    return stream(forChannel: i)?.label ?? settings.channels[i].query.map { "Waiting for \($0.group.lowercased())" } ?? "Off"
  }

  /// Provenance of channel 0…3 or math (4) (math: the union of its inputs).
  func provenance(_ i: Int) -> [Provenance] {
    if i == 4 {
      let m = settings.math
      var list: [Provenance] = [.model]
      for source in [m.a, m.b, m.c].prefix(m.operation.inputs) {
        switch source {
        case .channel(let c): list += provenance(c)
        case .stream(let id): if let p = app?.streams.stream(id)?.provenance { list.append(p) }
        }
      }
      return Provenance.union(list)
    }
    guard let s = stream(forChannel: i) else { return [] }
    var list = [s.provenance]
    if s.id == ScopeProbeStreams.fidID, probes.owns(s.id) {
      list.append(app?.streams.stream("mag.norm")?.provenance ?? .model)
    }
    if s.group == StreamGroup.audio { list.append(.analogy) }
    if s.group == StreamGroup.light, s.id.rawValue.contains("flicker") { list.append(.model) }
    return Provenance.union(list)
  }

  /// Every shown channel's provenance (the panel's badges).
  var provenanceUnion: [Provenance] {
    var list: [Provenance] = []
    for i in 0..<4 where settings.channels[i].enabled { list += provenance(i) }
    if settings.math.enabled { list += provenance(4) }
    return Provenance.union(list)
  }

  /// The display panel's badges: the shown channels' union, plus MODEL for the
  /// time–frequency pictures (a computed quasi-distribution of the stream).
  var displayProvenance: [Provenance] {
    settings.mode.isTimeFrequency ? Provenance.union(provenanceUnion + [.model]) : provenanceUnion
  }

  /// Display colour (linear token) of channel 0…3 or math (4): CH1–CH4 identity colours.
  func colorRGB(_ i: Int) -> RGB {
    if i == 4 { return Theme.violetRGB }
    return Theme.channelRGB[i]
  }

  func color(_ i: Int) -> Color { colorRGB(i).color }

  /// Units per division and reference (centre value) of channel 0…3 or math (4).
  func scale(_ i: Int) -> (unitsPerDiv: Double, reference: Double, position: Double) {
    if i == 4 { return (settings.math.unitsPerDiv, settings.math.reference, settings.math.position) }
    let c = settings.channels[i]
    return (c.unitsPerDiv, c.reference, c.position)
  }

  /// Measured sample rate of channel 0…3, or of math input A (4).
  func rate(_ i: Int) -> Double? {
    if i == 4 {
      switch settings.math.a {
      case .channel(let c): return track(for: c)?.rate
      case .stream(let id): return auxTrack(id)?.rate
      }
    }
    return track(for: i)?.rate
  }

  func isIrregular(_ i: Int) -> Bool {
    if i == 4 { return false }
    return stream(forChannel: i)?.isIrregular ?? false
  }

  /// Drawn sample-and-hold: irregular streams (dashed) and step streams such as link quality
  /// or battery state (solid), whose value stands until the next sample.
  func isHeld(_ i: Int) -> Bool {
    guard i >= 0, i < 4, let s = stream(forChannel: i) else { return false }
    return s.isIrregular || ScopeEngine.isStepUnit(s.unit)
  }

  /// Whether this channel or math is drawn.
  func isShown(_ i: Int) -> Bool {
    if i == 4 { return settings.math.enabled }
    return settings.channels[i].enabled && settings.channels[i].stream != nil
  }

  /// The time mapping of what is shown (rule R3): κ-slowed by a known factor for the scope's own
  /// I/Q probe; what a stream's label declares for another slice's stream ("Radio I (κ-slowed)",
  /// "Spectrum Ex at z = 0 (κ-slowed)", the electron FID "slowed ×714"); otherwise real time.
  var timeNote: ScopeTimeNote {
    for i in 0..<4 where isShown(i) {
      guard let id = settings.channels[i].stream else { continue }
      if id == ScopeProbeStreams.iID || id == ScopeProbeStreams.qID, probes.owns(id) {
        return .known(probes.radioTimeMapping)
      }
      guard let s = stream(forChannel: i) else { continue }
      let label = s.label.lowercased()
      if label.contains("slowed") {
        if let factor = Self.slowFactor(in: s.label) { return .known(.slowed(factor: factor)) }
        return .declared(badge: TimeMapping.slowed(factor: 1).badge, detail: "CH\(i + 1), at its source")
      }
      if label.contains("heterodyn") || label.contains("rotating frame") {
        return .declared(badge: TimeMapping.heterodyned(fRef: 0).badge, detail: "CH\(i + 1), at its source")
      }
    }
    return .known(.realTime)
  }

  /// "×714" in a stream label → 714 (a plain factor > 1). Scientific notation ("×1.1 × 10⁴")
  /// is not parsed: the chip then says the channel is slowed at its source, without a number.
  nonisolated static func slowFactor(in label: String) -> Double? {
    let superscripts: Set<Character> = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹", "⁻"]
    guard !label.contains(where: { superscripts.contains($0) }),
      let r = label.range(of: #"×\s*[0-9]+(\.[0-9]+)?"#, options: .regularExpression)
    else { return nil }
    let after = label[r.upperBound...].drop { $0 == " " }
    guard after.first != "×", after.first?.isNumber != true else { return nil }
    let digits = label[r].drop { !$0.isNumber }
    guard let v = Double(digits), v > 1, v.isFinite else { return nil }
    return v
  }

  // MARK: - Frame

  var scopeAnimating: Bool { running && visible }

  /// Ingests new samples and runs the trigger; idempotent within one display frame.
  func tick() {
    let now = SignalClock.now()
    guard now - lastTick > 0.004 else { return }
    lastTick = now
    guard let app else { return }
    resolveChannels()
    if running {
      let field = app.streams.stream("mag.norm")?.ring.latest.map { Double($0.value) * 1e-6 }
      probes.pump(now: now, fieldTesla: field, registry: app.streams)
      for i in 0..<4 where settings.channels[i].enabled { track(for: i)?.ingest() }
      if settings.math.enabled {
        for source in [settings.math.a, settings.math.b, settings.math.c] {
          if case .stream(let id) = source { auxTrack(id)?.ingest() }
        }
      }
      _ = mathSamples()
      acquire(now: now)
    }
    autoScaleIfNeeded(now: now)
    refreshReadout(force: false)
    if settings.mode == .fft || settings.mode.isTimeFrequency { ensureAnalysisWindow() }
    if settings.mode == .fft { updateSpectrum(now: now) }
    if settings.mode.isTimeFrequency { updateTimeFrequency(now: now) }
  }

  /// The newest sample time over the shown channels.
  private var latestShownTime: Double? {
    var latest: Double?
    for i in 0..<4 where settings.channels[i].enabled {
      if let t = track(for: i)?.latestTime { latest = max(latest ?? t, t) }
    }
    return latest
  }

  /// The newest instant every regular shown channel has reached (irregular ones are held).
  private var commonLatestTime: Double? {
    var common: Double?
    var any: Double?
    for i in 0..<4 where settings.channels[i].enabled {
      guard let t = track(for: i) else { continue }
      guard let last = t.latestTime else { continue }
      any = max(any ?? last, last)
      if !t.isIrregular { common = min(common ?? last, last) }
    }
    return common ?? any
  }

  /// The time window currently displayed (YT sweep, roll or XY window, analysis window).
  var displayWindow: ClosedRange<Double> {
    let w = timebase * Double(ScopeEngine.divisionsX)
    switch settings.mode {
    case .yt:
      if let sweep = currentSweep { return sweep }
      let end = frozenEnd ?? commonLatestTime ?? SignalClock.now()
      return (end - w)...end
    case .roll:
      let end = frozenEnd ?? rollEnd
      return (end - w)...end
    default:
      let end = frozenEnd ?? commonLatestTime ?? SignalClock.now()
      return (end - w)...end
    }
  }

  /// Roll mode's right edge: now, less the data latency of the regular channels (≤ 0.5 s).
  private var rollEnd: Double {
    let now = SignalClock.now()
    var latency = 0.0
    for i in 0..<4 where settings.channels[i].enabled {
      guard let t = track(for: i), !t.isIrregular, let last = t.latestTime else { continue }
      latency = max(latency, now - last)
    }
    return now - min(0.5, latency)
  }

  /// The trigger: finds new edges on the source and turns them into sweeps.
  private func acquire(now: Double) {
    let w = timebase * Double(ScopeEngine.divisionsX)
    let half = w / 2
    switch settings.mode {
    case .yt:
      break
    case .roll:
      status = .roll
      return
    case .xy:
      status = isShown(settings.xChannel) && isShown(settings.yChannel) ? .xy : .noSignal
      return
    default:
      status = .analysis
      return
    }
    let trig = settings.trigger
    guard let source = triggerSource(), let latest = source.times.last else {
      // The trigger source has no samples (switched off, or still waiting for its stream):
      // Auto free-runs on the channels that do have data; Normal and Single wait.
      if trig.mode == .auto, let end = commonLatestTime {
        let sweep = (end - w)...end
        currentSweep = sweep
        if end - lastFreeRunAccumulated >= w {
          newSweeps.append(sweep)
          lastFreeRunAccumulated = end
        }
        status = .auto
      } else if latestShownTime == nil {
        status = .noSignal
      } else {
        status = trig.mode == .single ? .single : .waiting
      }
      return
    }
    let hysteresis = 0.1 * scale(trig.source).unitsPerDiv
    let holdoff = trig.holdoff
    let searchEnd = latest - half
    let notBefore = max(searched, lastTrigger.map { $0 + half + holdoff } ?? -.infinity)
    var triggers: [Double] = []
    if searchEnd > notBefore {
      // Some context before the search window, so the hysteresis can arm.
      let from = notBefore.isFinite ? notBefore - max(half, 0.05) : searchEnd - w
      let lo = ScopeEngine.lowerBound(source.times, from)
      let hi = ScopeEngine.upperBound(source.times, searchEnd)
      if hi - lo > 1 {
        // The whole arrays with the stretch to search (no per-frame copy).
        triggers = ScopeEngine.triggerTimes(
          values: source.values, times: source.times, level: trig.level, slope: trig.slope,
          hysteresis: hysteresis, holdoff: half + holdoff, notBefore: notBefore, range: lo..<hi)
      }
      searched = searchEnd
    }
    if !triggers.isEmpty {
      if trig.mode == .single, let first = triggers.first {
        currentSweep = (first - half)...(first + half)
        newSweeps = [currentSweep!]
        lastTrigger = first
        running = false
        frozenEnd = first + half
        status = .stopped
        Haptics.shared.success()
        refreshReadout(force: true)
        revision &+= 1
        return
      }
      let recent = triggers.suffix(8)
      newSweeps.append(contentsOf: recent.map { ($0 - half)...($0 + half) })
      if newSweeps.count > 8 { newSweeps.removeFirst(newSweeps.count - 8) }
      if let last = recent.last {
        currentSweep = (last - half)...(last + half)
        lastTrigger = last
      }
      lastTriggerWall = now
      status = .triggered
      return
    }
    switch trig.mode {
    case .auto:
      let timeout = min(3, max(0.15, 1.5 * w))
      if now - lastTriggerWall > timeout {
        let end = commonLatestTime ?? latest
        currentSweep = (end - w)...end
        if end - lastFreeRunAccumulated >= w {
          newSweeps.append((end - w)...end)
          lastFreeRunAccumulated = end
        }
        status = .auto
      }
    case .normal:
      status = .waiting
    case .single:
      status = .single
    }
  }

  /// The trigger source as displayed samples.
  private func triggerSource() -> (values: [Float], times: [Double])? {
    let i = settings.trigger.source
    if i == 4 {
      guard let m = mathSamples() else { return nil }
      return (m.values, m.times)
    }
    guard let t = track(for: i) else { return nil }
    return (t.values, t.times)
  }

  func buildScopeFrame(_ frame: inout ScopeFrame, size: CGSize, dt: Double) {
    tick()
    let rect = CGRect(origin: .zero, size: size)
    frame.inset = 0
    frame.graticule = SIMD3(Float(ScopeEngine.divisionsX), Float(ScopeEngine.divisionsY), 1)
    let tau = settings.persistence
    if !running {
      frame.decay = 1
    } else if tau <= 0 || settings.mode == .roll {
      frame.decay = 0
    } else if tau >= ScopeSettings.infinitePersistence {
      frame.decay = 1
    } else {
      frame.decay = Float(exp(-max(0, dt) / tau))
    }
    if clearPersistence {
      frame.clearAccumulation = true
      clearPersistence = false
    }
    let columns = max(32, Int(size.width.rounded()))
    switch settings.mode {
    case .yt: drawYT(&frame, rect: rect, columns: columns, dt: dt)
    case .roll: drawRoll(&frame, rect: rect, columns: columns)
    case .xy: drawXY(&frame, rect: rect, dt: dt)
    default: break
    }
    drawCursors(&frame, rect: rect)
  }

  /// Brightness of one sweep written into the persistence buffer. Sweeps arriving at rate R
  /// with time constant τ pile up to about a·R·τ, so a = 0.5 / max(1, R·τ): a steady repetitive
  /// signal glows like one sweep, while a rare event still shows at full strength.
  private func sweepIntensity(sweeps: Int, dt: Double) -> Float {
    let instant = Double(sweeps) / max(dt, 1e-3)
    sweepRate = 0.9 * sweepRate + 0.1 * instant
    let tau = min(10, settings.persistence)
    return Float(0.5 / max(1, sweepRate * tau))
  }

  /// Normal and Single before their first edge: nothing has triggered, so the screen shows no
  /// trace (only what the persistence still holds), never a free-running one.
  private var awaitingTrigger: Bool {
    running && settings.mode == .yt && settings.trigger.mode != .auto && currentSweep == nil
  }

  private func drawYT(_ frame: inout ScopeFrame, rect: CGRect, columns: Int, dt: Double) {
    let window = displayWindow
    // The new sweeps are read in place and the list is emptied at the end, keeping its storage.
    defer { newSweeps.removeAll(keepingCapacity: true) }
    // At most the newest six go into the persistence buffer (none while stopped).
    let sweeps = running ? max(0, newSweeps.count - 6)..<newSweeps.count : 0..<0
    let persistence = settings.persistence > 0
    let a = persistence ? sweepIntensity(sweeps: running ? newSweeps.count : 0, dt: dt) : 0
    let awaiting = awaitingTrigger
    for i in 0...4 where isShown(i) {
      if awaiting {
        drawGround(&frame, channel: i, rect: rect)
        continue
      }
      let rgb = colorRGB(i)
      let dashed = isIrregular(i)
      guard let s = series(i) else { continue }
      // A slow stream beside a fast one (the 10 Hz illuminance under 5 ms/div of flicker) has
      // at most one sample in the sweep: hold its last value across instead of drawing nothing.
      // Only while the stream is alive (its newest sample within two periods of the sweep's
      // end): a stream that stopped is not drawn as if its last value went on.
      let period = i < 4 ? 1 / max(stream(forChannel: i)?.nominalRate ?? 0, 1e-9) : .infinity
      let sparse =
        ScopeEngine.upperBound(s.times, window.upperBound) - ScopeEngine.lowerBound(s.times, window.lowerBound) < 2
        && (s.times.last ?? -.infinity) >= window.upperBound - 2 * period
      let hold = isHeld(i) || sparse
      if persistence {
        for k in sweeps {
          let sweep = newSweeps[k]
          let dense = isDense(s.times, in: sweep, columns: columns)
          ScopeEngine.trace(
            values: s.values, times: s.times, window: sweep, columns: columns, hold: hold, into: &traceScratch,
            columnScratch: &columnScratch)
          fillPoints(channel: i, rect: rect)
          frame.accumulate.trace(pointScratch, color: GlowColor(rgb, intensity: dense ? a * 0.5 : a), width: 1.2, glow: 0.3)
        }
      }
      let dense = isDense(s.times, in: window, columns: columns)
      ScopeEngine.trace(
        values: s.values, times: s.times, window: window, columns: columns, hold: hold, holdUntil: hold ? window.upperBound : nil,
        into: &traceScratch, columnScratch: &columnScratch)
      fillPoints(channel: i, rect: rect)
      frame.overlay.trace(
        pointScratch, color: GlowColor(rgb, intensity: dense ? 0.45 : 1.0), width: dense ? 1.1 : 1.4, glow: dense ? 0.25 : 0.6,
        dash: dashed ? 5 : 0)
      drawGround(&frame, channel: i, rect: rect)
    }
    // Trigger point (top, centre) and level (right edge).
    if settings.mode == .yt, isShown(settings.trigger.source) {
      let rgb = colorRGB(settings.trigger.source)
      let x = rect.midX
      frame.overlay.segment2D(CGPoint(x: x - 5, y: rect.minY + 1), CGPoint(x: x, y: rect.minY + 7), color: GlowColor(rgb, intensity: 0.9), width: 1.4, glow: 0.3)
      frame.overlay.segment2D(CGPoint(x: x + 5, y: rect.minY + 1), CGPoint(x: x, y: rect.minY + 7), color: GlowColor(rgb, intensity: 0.9), width: 1.4, glow: 0.3)
      let y = yPosition(settings.trigger.level, channel: settings.trigger.source, rect: rect)
      if y >= rect.minY, y <= rect.maxY {
        frame.overlay.segment2D(CGPoint(x: rect.maxX - 1, y: y - 5), CGPoint(x: rect.maxX - 8, y: y), color: GlowColor(rgb, intensity: 0.9), width: 1.4, glow: 0.3)
        frame.overlay.segment2D(CGPoint(x: rect.maxX - 1, y: y + 5), CGPoint(x: rect.maxX - 8, y: y), color: GlowColor(rgb, intensity: 0.9), width: 1.4, glow: 0.3)
        frame.overlay.segment2D(CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX - 8, y: y), color: GlowColor(rgb, intensity: 0.25, alpha: 0.6), width: 0.8, glow: 0, dash: 4)
      }
    }
  }

  private func drawRoll(_ frame: inout ScopeFrame, rect: CGRect, columns: Int) {
    let window = displayWindow
    newSweeps.removeAll(keepingCapacity: true)
    for i in 0...4 where isShown(i) {
      let hold = isHeld(i)
      guard let s = series(i) else { continue }
      ScopeEngine.rollTrace(
        values: s.values, times: s.times, end: window.upperBound, span: window.upperBound - window.lowerBound, columns: columns,
        hold: hold, into: &traceScratch, columnScratch: &columnScratch)
      fillPoints(channel: i, rect: rect)
      let dense = isDense(s.times, in: window, columns: columns)
      frame.overlay.trace(
        pointScratch, color: GlowColor(colorRGB(i), intensity: dense ? 0.45 : 1.0), width: dense ? 1.1 : 1.4, glow: dense ? 0.25 : 0.6,
        dash: isIrregular(i) ? 5 : 0)
      if let last = pointScratch.last { frame.overlay.dot2D(last, color: GlowColor(colorRGB(i), intensity: 1.4), diameter: 4.5, glow: 0.8) }
      drawGround(&frame, channel: i, rect: rect)
    }
  }

  private func drawXY(_ frame: inout ScopeFrame, rect: CGRect, dt: Double) {
    let xi = settings.xChannel
    let yi = settings.yChannel
    guard isShown(xi), isShown(yi), let xt = track(for: xi), let yt = track(for: yi) else { return }
    let w = timebase * Double(ScopeEngine.divisionsX)
    let end = frozenEnd ?? min(xt.latestTime ?? 0, yt.isIrregular ? (xt.latestTime ?? 0) : (yt.latestTime ?? 0))
    let window = (end - w)...end
    let tolerance = max(0.002, 1.5 / max(1, yt.rate ?? 10))
    // The whole arrays (copy-on-write, nothing is copied): pairXY searches them for the window.
    let xs = (values: xt.values, times: xt.times)
    let ys = (values: yt.values, times: yt.times)
    ScopeEngine.pairXY(x: xs, y: ys, window: window, tolerance: tolerance, holdY: yt.isIrregular, into: &traceScratch)
    fillXYPoints(rect: rect)
    let rgb = Theme.channelRGB[xi].mix(Theme.channelRGB[yi], 0.5)
    // The beam adds up where the figure overlaps itself: thousands of points (the Radio tab's
    // 2.4 kHz I/Q over 2 s) would burn a white blob. Like a bench scope's intensity, the beam
    // is dimmed so about 500 points draw at full strength.
    let density = Float(max(0.12, min(1, 500 / Double(max(1, traceScratch.count)))))
    frame.overlay.trace(pointScratch, color: GlowColor(rgb, intensity: 0.4 * density, alpha: 0.85), width: 1.1, glow: 0.3)
    if let last = pointScratch.last { frame.overlay.dot2D(last, color: GlowColor(rgb, intensity: 1.5), diameter: 6, glow: 1) }
    // The beam writes only what is new into the persistence buffer.
    if running, settings.persistence > 0 {
      let from = max(window.lowerBound, lastXYEnd ?? window.lowerBound)
      // From the last X sample already written, so the new stretch joins the old one.
      let k = max(0, ScopeEngine.lowerBound(xt.times, from) - 1)
      let start = k < xt.times.count ? min(from, xt.times[k]) : from
      if end > from {
        ScopeEngine.pairXY(x: xs, y: ys, window: start...end, tolerance: tolerance, holdY: yt.isIrregular, into: &traceScratch)
        // Points arriving at R per second pile up to about R·τ on the screen.
        let piled = Double(traceScratch.count) / max(dt, 1e-3) * min(10, settings.persistence)
        let gain = Float(max(0.05, min(1, 500 / max(1, piled))))
        fillXYPoints(rect: rect)
        frame.accumulate.trace(pointScratch, color: GlowColor(rgb, intensity: 0.35 * gain), width: 1.2, glow: 0.3)
      }
      lastXYEnd = end
    }
  }

  private func drawGround(_ frame: inout ScopeFrame, channel i: Int, rect: CGRect) {
    let y = yPosition(scale(i).reference, channel: i, rect: rect)
    guard y >= rect.minY, y <= rect.maxY else { return }
    let c = GlowColor(colorRGB(i), intensity: 0.9)
    frame.overlay.segment2D(CGPoint(x: rect.minX + 1, y: y - 4), CGPoint(x: rect.minX + 7, y: y), color: c, width: 1.4, glow: 0.3)
    frame.overlay.segment2D(CGPoint(x: rect.minX + 1, y: y + 4), CGPoint(x: rect.minX + 7, y: y), color: c, width: 1.4, glow: 0.3)
  }

  private func drawCursors(_ frame: inout ScopeFrame, rect: CGRect) {
    let c = settings.cursors
    guard c.mode != .off, settings.mode == .yt || settings.mode == .roll else { return }
    let divW = rect.width / CGFloat(ScopeEngine.divisionsX)
    let divH = rect.height / CGFloat(ScopeEngine.divisionsY)
    let color = GlowColor(RGB(0.92, 0.95, 0.93), intensity: 0.7, alpha: 0.9)
    if c.mode.showsTime {
      for k in 0..<2 {
        let x = rect.minX + CGFloat(k == 0 ? c.t1 : c.t2) * divW
        frame.overlay.segment2D(CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY), color: color, width: 1, glow: 0.2, dash: 6)
      }
    }
    if c.mode.showsAmplitude {
      for k in 0..<2 {
        let y = rect.midY - CGFloat(k == 0 ? c.y1 : c.y2) * divH
        frame.overlay.segment2D(CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y), color: color, width: 1, glow: 0.2, dash: 6)
      }
    }
  }

  /// Screen y of value `v` on channel `i`.
  func yPosition(_ v: Double, channel i: Int, rect: CGRect) -> CGFloat {
    let s = scale(i)
    let divH = rect.height / CGFloat(ScopeEngine.divisionsY)
    let d = (v - s.reference) / max(s.unitsPerDiv, 1e-30) + s.position
    return rect.midY - CGFloat(d) * divH
  }

  // Per-frame scratch: a trace (x 0…1 across, value) and its screen points. The drawing reuses
  // them, so a steady frame allocates nothing (SceneBuilder's rule).
  @ObservationIgnored private var traceScratch: [SIMD2<Float>] = []
  @ObservationIgnored private var columnScratch: [ScopeEngine.Column?] = []
  @ObservationIgnored private var pointScratch: [CGPoint] = []

  /// `traceScratch` on channel `i` as screen points, into `pointScratch`.
  private func fillPoints(channel i: Int, rect: CGRect) {
    let s = scale(i)
    let divH = Double(rect.height) / Double(ScopeEngine.divisionsY)
    let k = 1 / max(s.unitsPerDiv, 1e-30)
    // Off-screen samples are pinned just outside the well (clipped there), so a trace that
    // leaves the screen does not pile up along the edge.
    let lo = Double(rect.minY) - 14
    let hi = Double(rect.maxY) + 14
    pointScratch.removeAll(keepingCapacity: true)
    pointScratch.reserveCapacity(traceScratch.count)
    for p in traceScratch {
      let d = (Double(p.y) - s.reference) * k + s.position
      let y = min(hi, max(lo, Double(rect.midY) - d * divH))
      pointScratch.append(CGPoint(x: Double(rect.minX) + Double(p.x) * Double(rect.width), y: y))
    }
  }

  /// `traceScratch` as XY pairs (X channel across, Y channel up), into `pointScratch`.
  private func fillXYPoints(rect: CGRect) {
    let sx = scale(settings.xChannel)
    let sy = scale(settings.yChannel)
    let divW = Double(rect.width) / Double(ScopeEngine.divisionsX)
    let divH = Double(rect.height) / Double(ScopeEngine.divisionsY)
    pointScratch.removeAll(keepingCapacity: true)
    pointScratch.reserveCapacity(traceScratch.count)
    for p in traceScratch {
      let dx = (Double(p.x) - sx.reference) / max(sx.unitsPerDiv, 1e-30) + sx.position
      let dy = (Double(p.y) - sy.reference) / max(sy.unitsPerDiv, 1e-30) + sy.position
      let x = min(Double(rect.maxX) + 14, max(Double(rect.minX) - 14, Double(rect.midX) + dx * divW))
      let y = min(Double(rect.maxY) + 14, max(Double(rect.minY) - 14, Double(rect.midY) - dy * divH))
      pointScratch.append(CGPoint(x: x, y: y))
    }
  }

  // MARK: - Auto-scale

  @ObservationIgnored private var lastAutoScale = -Double.infinity

  private func autoScaleIfNeeded(now: Double) {
    guard running, now - lastAutoScale > 0.5 else { return }
    lastAutoScale = now
    let window = displayWindow
    var next = settings
    var changed = false
    func fit(_ values: [Float], unit: String, current: (Double, Double, Double)) -> (Double, Double)? {
      let finite = values.filter(\.isFinite)
      guard finite.count > 1, let lo = finite.min(), let hi = finite.max() else { return nil }
      let (upd, ref, pos) = current
      let top = (Double(hi) - ref) / upd + pos
      let bottom = (Double(lo) - ref) / upd + pos
      let span = Double(hi - lo) / upd
      // A centred trace may fill 6 of the 8 divisions; a trace moved off centre (stacked
      // channels) keeps to a 1.6-division band around its position. Refit when it leaves the
      // screen or its band, or shrinks to a quarter of it.
      let target = abs(pos) < 0.05 ? 6.0 : 1.6
      guard top > 3.95 || bottom < -3.95 || span < target / 4 || span > target * 1.3 else { return nil }
      let f = ScopeEngine.autoScale(minimum: Double(lo), maximum: Double(hi), unit: unit, divisions: target)
      return (f.unitsPerDiv, f.reference)
    }
    /// The data span of a refitted channel (the trigger level is checked against it).
    func span(_ values: [Float]) -> ClosedRange<Double>? {
      let finite = values.filter(\.isFinite)
      guard let lo = finite.min(), let hi = finite.max() else { return nil }
      return Double(lo)...Double(hi)
    }
    var sourceSpan: ClosedRange<Double>?
    let src = next.trigger.source
    for i in 0..<4 where next.channels[i].enabled && next.channels[i].autoScale {
      guard let t = track(for: i) else { continue }
      let w = t.fitSamples(window)
      let c = next.channels[i]
      if let (upd, ref) = fit(w.values, unit: t.stream.unit, current: (c.unitsPerDiv, c.reference, c.position)) {
        if upd != c.unitsPerDiv || abs(ref - c.reference) > upd * 0.25 {
          next.channels[i].unitsPerDiv = upd
          next.channels[i].reference = ref
          changed = true
          if i == src { sourceSpan = span(w.values) }
        }
      }
    }
    if next.math.enabled, next.math.autoScale, let m = mathSamples() {
      let w = m.window(window, margin: true)
      let c = next.math
      if let (upd, ref) = fit(w.values, unit: unit(4), current: (c.unitsPerDiv, c.reference, c.position)) {
        if upd != c.unitsPerDiv || abs(ref - c.reference) > upd * 0.25 {
          next.math.unitsPerDiv = upd
          next.math.reference = ref
          changed = true
          if src == 4 { sourceSpan = span(w.values) }
        }
      }
    }
    if changed {
      // When the trigger source is refitted, a level its trace never reaches (the default 0
      // on a 48 µT field, or a DC level left behind by a switch to AC) moves to the trace's
      // middle, so the scope triggers instead of free-running; a level on the trace stays.
      if let s = sourceSpan, !s.contains(next.trigger.level) {
        next.trigger.level = src == 4 ? next.math.reference : next.channels[src].reference
      }
      settings = next
      store?.schedule(next)
      clearPersistence = true
    }
  }

  // MARK: - Readouts, FFT, time–frequency

  private func refreshReadout(force: Bool) {
    let now = SignalClock.now()
    guard force || now - lastReadout > 0.2 else { return }
    lastReadout = now
    var r = ScopeReadout()
    r.status = running ? status : .stopped
    let window = displayWindow
    var latest: Double?
    var columns: [ScopeEngine.CSVColumn] = []
    // Waiting for a first edge (Normal, Single): nothing is on screen, so nothing is measured
    // or exported.
    let awaiting = awaitingTrigger
    for i in 0...4 where isShown(i) && !awaiting {
      guard let s = samples(i, in: window) else { continue }
      let rate = self.rate(i)
      if let rate { r.rates[i] = rate }
      r.sampleCounts[i] = s.values.count
      var m = ScopeEngine.measure(
        values: s.values, times: s.times, sampleRate: isIrregular(i) ? nil : rate, analyzers: &peakAnalyzers)
      // Decibel levels (RSSI, mic level): "RMS" is their mean power (the panel says so).
      if ScopeEngine.isLogarithmic(unit(i)) { m.rms = ScopeEngine.powerMean(s.values) }
      r.measurements[i] = m
      if let t = s.times.last { latest = max(latest ?? t, t) }
      columns.append(ScopeEngine.CSVColumn(header: i == 4 ? "MATH \(label(4))" : "CH\(i + 1) \(label(i))", unit: unit(i), times: s.times, values: s.values))
    }
    if let t = (0..<4).compactMap({ settings.channels[$0].enabled ? track(for: $0)?.latestTime : nil }).max() {
      r.dataAge = max(0, now - t)
    }
    if r.status != .stopped, !awaiting, r.measurements.values.allSatisfy({ $0.count == 0 }) { r.status = .noSignal }
    for i in 0..<4 where isShown(i) {
      let notes = aliasNotes(channel: i)
      guard !notes.isEmpty else { continue }
      r.channelAliasNotes[i] = notes
      for note in notes where !r.aliasNotes.contains(where: { $0.source == note.source }) { r.aliasNotes.append(note) }
    }
    if r != readout { readout = r }
    export = ScopeExport(columns: columns, origin: window.lowerBound)
  }

  /// Known sources that the shown streams cannot sample truthfully (mains hum on the
  /// magnetometer at ~100 Hz, LED flicker at twice mains on the light meter).
  func aliasNotes() -> [ScopeEngine.AliasNote] {
    var notes: [ScopeEngine.AliasNote] = []
    for i in 0..<4 where isShown(i) {
      for note in aliasNotes(channel: i) where !notes.contains(where: { $0.source == note.source }) { notes.append(note) }
    }
    return notes
  }

  /// The known sources channel `i` (0…3) cannot sample truthfully, at its measured rate.
  func aliasNotes(channel i: Int) -> [ScopeEngine.AliasNote] {
    guard i >= 0, i < 4, isShown(i), let s = stream(forChannel: i), !s.isIrregular else { return [] }
    let mains = ScopeEngine.mainsFrequency(region: Locale.current.region?.identifier)
    let rate = track(for: i)?.rate ?? s.nominalRate
    var sources: [(label: String, frequency: Double)] = []
    switch s.group {
    case StreamGroup.magnetometer:
      sources = [("\(Int(mains)) Hz mains", mains), ("\(Int(2 * mains)) Hz mains harmonic", 2 * mains)]
    case StreamGroup.light:
      // Only the row-signal is a point sample of the light; lux, color temperature and EV
      // come from whole exposures, which average flicker away rather than alias it.
      let text = (s.id.rawValue + " " + s.label).lowercased()
      if text.contains("flicker") || text.contains("row") { sources = [("\(Int(2 * mains)) Hz lamp flicker", 2 * mains)] }
    case StreamGroup.motion:
      sources = [("\(Int(mains)) Hz motor hum", mains)]
    default:
      break
    }
    return ScopeEngine.aliasNotes(sources: sources, sampleRate: rate)
  }

  /// The analysis channel's newest window as uniform samples (irregular streams are held and
  /// resampled).
  private func analysisRecord(maxCount: Int) -> (values: [Float], rate: Double, start: Double, resampled: Bool, decimation: Int)? {
    let i = settings.analysisChannel
    guard isShown(i) else { return nil }
    let window = displayWindow
    guard let s = samples(i, in: window, margin: true), s.values.count > 8 else { return nil }
    if isIrregular(i) {
      let span = window.upperBound - window.lowerBound
      let rate = min(50, max(1, Double(s.values.count) / max(span, 1e-6)))
      let r = ScopeEngine.resample(values: s.values, times: s.times, rate: rate, window: window, hold: true, maxCount: maxCount)
      guard r.values.count > 8 else { return nil }
      return (r.values, rate, r.start, true, 1)
    }
    let rate = self.rate(i) ?? 1
    var values = s.values
    var times = s.times
    let lo = ScopeEngine.lowerBound(times, window.lowerBound)
    values = Array(values[lo...])
    times = Array(times[lo...])
    var factor = 1
    if values.count > maxCount {
      factor = Int((Double(values.count) / Double(maxCount)).rounded(.up))
      values = ScopeEngine.boxcarDecimate(values, factor: factor)
    }
    return (values, rate / Double(factor), times.first ?? window.lowerBound, false, factor)
  }

  private func updateSpectrum(now: Double) {
    guard running || spectrum == nil, now - lastSpectrum > 0.12 else { return }
    lastSpectrum = now
    guard let record = analysisRecord(maxCount: 16_384) else {
      spectrum = nil
      return
    }
    // The mean (DC) line is dropped so the window's offset never hides the lines above it.
    spectrum = spectrumCache.spectrum(values: record.values, sampleRate: record.rate, removeMean: true)
    spectrumResampledRate = record.resampled ? record.rate : nil
  }

  private func updateTimeFrequency(now: Double) {
    guard tfTask == nil, running || timeFrequency == nil, now - lastTF > 0.35, let phase = settings.mode.phaseMode,
      let record = analysisRecord(maxCount: 65_536)
    else { return }
    lastTF = now
    let mode = settings.mode
    let channel = settings.analysisChannel
    let input = record.values
    let inputRate = record.rate
    let resampled = record.resampled
    let recordDecimation = record.decimation
    tfGeneration &+= 1
    let generation = tfGeneration
    // Band focusing, the transform and the colouring all run off the main actor.
    tfTask = Task { [weak self] in
      let focused = await Task.detached(priority: .userInitiated) {
        ScopeModel.focusedTimeFrequency(values: input, sampleRate: inputRate, mode: phase)
      }.value
      guard let self, self.tfGeneration == generation else { return }
      self.tfTask = nil
      guard !Task.isCancelled, self.settings.mode == mode, self.settings.analysisChannel == channel else { return }
      let result = focused.result
      self.timeFrequency = ScopeTFDisplay(
        mode: mode, image: Self.makeImage(result), timeMarginal: result.timeMarginal, intensity: result.intensity,
        frequencyMarginal: result.frequencyMarginal, spectrum: result.spectrum, sampleRate: focused.sampleRate,
        duration: Double(focused.samples) / focused.sampleRate, samples: focused.samples,
        decimation: recordDecimation * focused.factor, m1Error: result.m1Error, m2Error: result.m2Error, resampled: resampled)
    }
  }

  /// Focuses the band, then computes the picture: decimates (FIR anti-alias, `RF.DSP.decimate`)
  /// so 0 … f_s/2 spans about 1.25× the highest frequency within 30 dB of the strongest line,
  /// keeps the newest 4096 samples and runs `computeTF`. Pure; called off the main actor.
  nonisolated static func focusedTimeFrequency(values input: [Float], sampleRate: Double, mode: Phase.TimeFrequencyMode)
    -> (result: ScopeTFResult, sampleRate: Double, samples: Int, factor: Int)
  {
    var values = input
    var rate = sampleRate
    var factor = 1
    var cache = ScopeEngine.SpectrumCache()
    if let top = contentFrequency(values: values, sampleRate: rate, spectrum: &cache) {
      factor = min(64, max(1, Int((rate / (2.5 * max(top, rate / 2000))).rounded(.down))))
    }
    if factor > 1 {
      let decimated = RF.DSP.decimate(values, factor: factor, taps: max(63, 8 * factor + 1))
      if decimated.count >= 64 {
        values = decimated
        rate /= Double(factor)
      } else {
        factor = 1
      }
    }
    if values.count > 4096 { values = Array(values.suffix(4096)) }
    return (computeTF(values: values, sampleRate: rate, mode: mode), rate, values.count, factor)
  }

  /// The highest frequency whose line is within `range` dB of the strongest one (newest
  /// ≤ 16,384 samples, mean removed); nil when there is no signal.
  nonisolated static func contentFrequency(
    values: [Float], sampleRate: Double, spectrum cache: inout ScopeEngine.SpectrumCache, range: Float = 30
  ) -> Double? {
    guard let s = cache.spectrum(values: Array(values.suffix(16_384)), sampleRate: sampleRate, removeMean: true),
      s.db.count > 2, let peak = s.db.dropFirst().max(), peak.isFinite, peak > -150
    else { return nil }
    guard let k = s.db.indices.dropFirst().last(where: { s.db[$0] >= peak - range }) else { return nil }
    return Double(k) * s.binWidth
  }

  /// The Phase engine's time–frequency image of a real record, coloured: Wigner values are
  /// signed (warm orange positive, cool blue negative, as in Utkarsh's poster); the spectrogram
  /// is ≥ 0 (dB, phosphor ramp). Time runs across, frequency up (0 … f_s/2).
  nonisolated static func computeTF(values: [Float], sampleRate: Double, mode: Phase.TimeFrequencyMode) -> ScopeTFResult {
    let mean = values.reduce(0, +) / Float(max(1, values.count))
    let centred = values.map { $0 - mean }
    let rows = min(256, max(8, centred.count))
    let request = Phase.TimeFrequencyRequest(mode: mode, rows: rows, columns: 256)
    let image = Phase.timeFrequency(real: centred, sampleRate: sampleRate, request: request)
    let plane = image.plane
    let w = plane.rows
    let h = plane.columns
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let well = SIMD3<Double>(0.016, 0.031, 0.027)
    if mode == .spectrogram {
      let maxV = max(plane.maxValue, 1e-300)
      let ramp: [(Double, SIMD3<Double>)] = [
        (0, well), (0.35, SIMD3(0.05, 0.32, 0.17)), (0.65, SIMD3(0.4, 0.96, 0.56)), (0.88, SIMD3(1, 0.75, 0.37)),
        (1, SIMD3(1, 1, 1)),
      ]
      for r in 0..<w {
        for c in 0..<h {
          let v = plane.value(row: r, column: c)
          let db = 10 * log10(max(v, 1e-300) / maxV)
          let t = min(1, max(0, (db + 60) / 60))
          var k = 0
          while k < ramp.count - 2, t > ramp[k + 1].0 { k += 1 }
          let (t0, c0) = ramp[k]
          let (t1, c1) = ramp[k + 1]
          let f = (t - t0) / max(1e-9, t1 - t0)
          let rgb = c0 + (c1 - c0) * f
          let o = ((h - 1 - c) * w + r) * 4
          pixels[o] = UInt8(min(255, max(0, rgb.x * 255)))
          pixels[o + 1] = UInt8(min(255, max(0, rgb.y * 255)))
          pixels[o + 2] = UInt8(min(255, max(0, rgb.z * 255)))
          pixels[o + 3] = 255
        }
      }
    } else {
      let unit = plane.signedUnit()
      let warm = SIMD3<Double>(1.0, 0.56, 0.18)
      let hot = SIMD3<Double>(1.0, 0.93, 0.78)
      let cool = SIMD3<Double>(0.25, 0.56, 1.0)
      let icy = SIMD3<Double>(0.78, 0.9, 1.0)
      for r in 0..<w {
        for c in 0..<h {
          let u = Double(unit[r * h + c])
          let m = pow(min(1, abs(u)), 0.6)
          let rgb: SIMD3<Double>
          if u >= 0 {
            rgb = m < 0.8 ? well + (warm - well) * (m / 0.8) : warm + (hot - warm) * ((m - 0.8) / 0.2)
          } else {
            rgb = m < 0.8 ? well + (cool - well) * (m / 0.8) : cool + (icy - cool) * ((m - 0.8) / 0.2)
          }
          let o = ((h - 1 - c) * w + r) * 4
          pixels[o] = UInt8(min(255, max(0, rgb.x * 255)))
          pixels[o + 1] = UInt8(min(255, max(0, rgb.y * 255)))
          pixels[o + 2] = UInt8(min(255, max(0, rgb.z * 255)))
          pixels[o + 3] = 255
        }
      }
    }
    func normalized(_ a: [Double], by m: Double) -> [Float] { a.map { Float($0 / max(m, 1e-300)) } }
    let iMax = image.intensity.max() ?? 1
    let sMax = image.spectrum.max() ?? 1
    let m1 = zip(image.timeMarginal, image.intensity).map { abs($0 - $1) }.max() ?? 0
    let m2 = zip(image.frequencyMarginal, image.spectrum).map { abs($0 - $1) }.max() ?? 0
    return ScopeTFResult(
      width: w, height: h, pixels: pixels,
      timeMarginal: normalized(image.timeMarginal, by: iMax), intensity: normalized(image.intensity, by: iMax),
      frequencyMarginal: normalized(image.frequencyMarginal, by: sMax), spectrum: normalized(image.spectrum, by: sMax),
      m1Error: m1 / max(iMax, 1e-300), m2Error: m2 / max(sMax, 1e-300))
  }

  private static func makeImage(_ r: ScopeTFResult) -> CGImage? {
    guard r.width > 0, r.height > 0, let provider = CGDataProvider(data: Data(r.pixels) as CFData) else { return nil }
    return CGImage(
      width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }

  // MARK: - Cursors

  /// What the cursors measure: Δt and 1/Δt for the time cursors, ΔY (in the cursor channel's
  /// unit) for the amplitude cursors. Nil when the cursors are off or the mode has none (they
  /// measure YT and Roll traces only).
  var cursorReadout: ScopeCursorReadout? {
    let c = settings.cursors
    guard c.mode != .off, settings.mode == .yt || settings.mode == .roll else { return nil }
    // ΔY is a difference: dB on a dBm channel.
    var r = ScopeCursorReadout(channel: c.channel, unit: ScopeEngine.differenceUnit(unit(c.channel)))
    if c.mode.showsTime {
      let dt = abs(c.t2 - c.t1) * timebase
      r.dt = dt
      r.frequency = dt > 0 ? 1 / dt : nil
    }
    if c.mode.showsAmplitude { r.dy = (c.y1 - c.y2) * scale(c.channel).unitsPerDiv }
    return r
  }

  // MARK: - Patch

  /// "Add to Patch" for channel `i`'s stream.
  func addToPatch(_ i: Int) {
    guard let app, let s = stream(forChannel: i) else {
      Haptics.shared.boundary()
      return
    }
    app.patch.addStreamSource(s.id, label: s.label)
    app.showToast("\(s.label) added to Patch", symbol: "point.3.connected.trianglepath.dotted")
    Haptics.shared.success()
  }
}

/// The time mapping chip under the display (`ScopeModel.timeNote`).
enum ScopeTimeNote: Equatable {
  /// A mapping the scope knows exactly (real time, or its own κ-slowed I/Q).
  case known(TimeMapping)
  /// A mapping a stream declares in its label without a factor the scope can read.
  case declared(badge: String, detail: String)
}

/// The cursor measurements (`ScopeModel.cursorReadout`).
struct ScopeCursorReadout: Equatable {
  /// The channel whose units ΔY reads (0…3, 4 = math).
  var channel: Int
  var unit: String
  var dt: Double?
  var frequency: Double?
  var dy: Double?
}

/// What the math channel's running state depends on: a new key restarts it (the operation, its
/// corner, or a rebuilt input track).
private struct MathKey: Equatable {
  var operation: ScopeEngine.MathOperation
  var cornerHz: Double
  var a: ObjectIdentifier
  var b: ObjectIdentifier?
  var c: ObjectIdentifier?
}

extension ScopeSource {
  /// The channel index, when this source is a channel.
  nonisolated var channelIndex: Int? {
    if case .channel(let i) = self { return i }
    return nil
  }
}
