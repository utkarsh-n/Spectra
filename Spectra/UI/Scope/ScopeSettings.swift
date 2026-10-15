import Foundation

/// Display modes (SPEC-features §3b, §3c).
nonisolated enum ScopeMode: String, Codable, Sendable, CaseIterable, Identifiable {
  case yt, roll, xy, fft, spectrogram, wignerVille, pseudoWigner

  var id: String { rawValue }

  var title: String {
    switch self {
    case .yt: "YT"
    case .roll: "Roll"
    case .xy: "XY"
    case .fft: "FFT"
    case .spectrogram: "Spectrogram"
    case .wignerVille: "Wigner–Ville"
    case .pseudoWigner: "Pseudo-Wigner"
    }
  }

  var symbol: String {
    switch self {
    case .yt: "waveform.path"
    case .roll: "arrow.left.to.line"
    case .xy: "circle.dashed"
    case .fft: "chart.bar"
    case .spectrogram: "square.stack.3d.down.right"
    case .wignerVille: "square.grid.3x3.fill"
    case .pseudoWigner: "square.grid.3x3"
    }
  }

  /// A time–frequency image (Phase engine) rather than a trace.
  var isTimeFrequency: Bool { self == .spectrogram || self == .wignerVille || self == .pseudoWigner }

  /// The Phase engine's mode for the time–frequency views.
  var phaseMode: Phase.TimeFrequencyMode? {
    switch self {
    case .spectrogram: .spectrogram
    case .wignerVille: .wignerVille
    case .pseudoWigner: .pseudoWigner
    default: nil
    }
  }

  /// One plain sentence for the panel caption.
  var caption: String {
    switch self {
    case .yt: "Sweeps start on the trigger; the trigger point sits at the center line."
    case .roll: "The newest samples enter at the right edge and scroll left, like a seismograph."
    case .xy: "Channel X against channel Y, paired sample by sample by their timestamps."
    case .fft: "Hann-windowed spectrum of the visible window, in dB of the stream's own unit."
    case .spectrogram: "Short-time Fourier power over the window: time across, frequency up, dB brightness."
    case .wignerVille:
      "Wigner–Ville distribution of the analytic signal: sharp lines and chirps, with signed cross terms between components. Its edges are the exact marginals |x(t)|² and |X(ν)|²."
    case .pseudoWigner:
      "Pseudo-Wigner: a Hann lag window trades some sharpness for weaker cross terms. The time marginal stays exact; the frequency marginal is smoothed."
    }
  }
}

/// Input coupling (a one-pole high-pass for AC, plus two physical presets).
nonisolated enum ScopeCoupling: String, Codable, Sendable, CaseIterable, Identifiable {
  case dc, ac, removeGravity, removeEarthField

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dc: "DC"
    case .ac: "AC"
    case .removeGravity: "No gravity"
    case .removeEarthField: "No Earth field"
    }
  }
}

nonisolated enum ScopeTriggerMode: String, Codable, Sendable, CaseIterable, Identifiable {
  case auto, normal, single

  var id: String { rawValue }

  var title: String {
    switch self {
    case .auto: "Auto"
    case .normal: "Normal"
    case .single: "Single"
    }
  }
}

/// Where a math input comes from: a channel as displayed (after coupling and invert), or any
/// registered stream as recorded.
nonisolated enum ScopeSource: Codable, Sendable, Hashable {
  case channel(Int)
  case stream(StreamID)
}

/// One input channel.
nonisolated struct ScopeChannel: Codable, Sendable, Hashable {
  /// The stream shown, once resolved.
  var stream: StreamID?
  /// A preset's description of the stream it wants, until a matching stream appears.
  var query: ScopeEngine.StreamQuery?
  var enabled = true
  var unitsPerDiv = 1.0
  /// Vertical position of the trace in divisions (the knob labelled Offset).
  var position = 0.0
  /// The value drawn at the centre line before `position` (set by Auto and Centre).
  var reference = 0.0
  var coupling: ScopeCoupling = .dc
  var invert = false
  /// Keep re-fitting units/div and reference to the data.
  var autoScale = true

  init(
    stream: StreamID? = nil, query: ScopeEngine.StreamQuery? = nil, enabled: Bool = true, unitsPerDiv: Double = 1,
    coupling: ScopeCoupling = .dc, autoScale: Bool = true
  ) {
    self.stream = stream
    self.query = query
    self.enabled = enabled
    self.unitsPerDiv = unitsPerDiv
    self.coupling = coupling
    self.autoScale = autoScale
  }
}

/// The math channel.
nonisolated struct ScopeMath: Codable, Sendable, Hashable {
  var enabled = false
  var operation: ScopeEngine.MathOperation = .sum
  var a: ScopeSource = .channel(0)
  var b: ScopeSource = .channel(1)
  var c: ScopeSource = .channel(2)
  /// Preset queries for stream sources (|ω| from the gyroscope axes), resolved like channels.
  var queries: [ScopeEngine.StreamQuery?] = [nil, nil, nil]
  /// High-pass corner (Hz).
  var cornerHz = 1.0
  var unitsPerDiv = 1.0
  var position = 0.0
  var reference = 0.0
  var autoScale = true
  /// Name shown instead of the formula ("|ω|").
  var label: String?
}

nonisolated struct ScopeTrigger: Codable, Sendable, Hashable {
  var mode: ScopeTriggerMode = .auto
  /// 0…3 = CH1…CH4, 4 = math.
  var source = 0
  /// In the source's displayed units.
  var level = 0.0
  var slope: ScopeEngine.Slope = .rising
  /// Seconds after a sweep before the next trigger is accepted.
  var holdoff = 0.0
}

nonisolated enum ScopeCursorMode: String, Codable, Sendable, CaseIterable, Identifiable {
  case off, time, amplitude, both

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: "Off"
    case .time: "Time"
    case .amplitude: "Amplitude"
    case .both: "Both"
    }
  }

  var showsTime: Bool { self == .time || self == .both }
  var showsAmplitude: Bool { self == .amplitude || self == .both }
}

nonisolated struct ScopeCursors: Codable, Sendable, Hashable {
  var mode: ScopeCursorMode = .off
  /// Divisions from the left edge, 0…10.
  var t1 = 3.0
  var t2 = 7.0
  /// Divisions from the center line, −4…4.
  var y1 = 2.0
  var y2 = -2.0
  /// The channel whose units the amplitude cursors read (0…3, 4 = math).
  var channel = 0
}

/// Everything the scope remembers (persisted as `Spectra.scope.v1`).
nonisolated struct ScopeSettings: Codable, Sendable, Hashable {
  var channels: [ScopeChannel]
  var math = ScopeMath()
  var mode: ScopeMode = .yt
  /// s/div as chosen; the model clamps it to what the streams can show.
  var timebase = 0.05
  var trigger = ScopeTrigger()
  /// Phosphor decay time constant (s): 0 = off, `.infinity` = infinite persistence.
  var persistence = 0.25
  var logFrequency = true
  /// XY: channel indices for X and Y.
  var xChannel = 0
  var yChannel = 1
  /// Channel shown by the FFT and time–frequency modes (0…3, 4 = math).
  var analysisChannel = 0
  var cursors = ScopeCursors()
  var preset: ScopePreset?
  /// The channel the measurement panel shows (0…3, 4 = math).
  var measureChannel = 0

  init() {
    channels = [ScopeChannel(), ScopeChannel(), ScopeChannel(), ScopeChannel()]
  }

  /// Persistence values at or above this read as infinite.
  static let infinitePersistence = 30.0

  static let storageKey = "Spectra.scope.v1"

  enum CodingKeys: String, CodingKey {
    case channels, math, mode, timebase, trigger, persistence, logFrequency, xChannel, yChannel, analysisChannel,
      cursors, preset, measureChannel
  }

  /// Tolerant decoding: a missing or older key falls back to its default.
  init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let v = try? c.decode([ScopeChannel].self, forKey: .channels), v.count == 4 { channels = v }
    if let v = try? c.decode(ScopeMath.self, forKey: .math) { math = v }
    if let v = try? c.decode(ScopeMode.self, forKey: .mode) { mode = v }
    if let v = try? c.decode(Double.self, forKey: .timebase), v.isFinite, v > 0 { timebase = v }
    if let v = try? c.decode(ScopeTrigger.self, forKey: .trigger) { trigger = v }
    if let v = try? c.decode(Double.self, forKey: .persistence), v >= 0 { persistence = min(v, Self.infinitePersistence) }
    if let v = try? c.decode(Bool.self, forKey: .logFrequency) { logFrequency = v }
    if let v = try? c.decode(Int.self, forKey: .xChannel) { xChannel = min(3, max(0, v)) }
    if let v = try? c.decode(Int.self, forKey: .yChannel) { yChannel = min(3, max(0, v)) }
    if let v = try? c.decode(Int.self, forKey: .analysisChannel) { analysisChannel = min(4, max(0, v)) }
    if let v = try? c.decode(ScopeCursors.self, forKey: .cursors) { cursors = v }
    preset = try? c.decode(ScopePreset.self, forKey: .preset)
    if let v = try? c.decode(Int.self, forKey: .measureChannel) { measureChannel = min(4, max(0, v)) }
    sanitize()
  }

  /// Pulls every index and number back into range, so a damaged or older saved state can never
  /// index past CH1…CH4/math or divide by a zero scale.
  mutating func sanitize() {
    func index(_ i: Int, upTo hi: Int) -> Int { min(hi, max(0, i)) }
    func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
    func scale(_ v: Double) -> Double { v.isFinite && v > 0 ? v : 1 }
    func source(_ s: ScopeSource) -> ScopeSource {
      if case .channel(let i) = s { return .channel(index(i, upTo: 3)) }
      return s
    }
    for i in channels.indices {
      channels[i].unitsPerDiv = scale(channels[i].unitsPerDiv)
      channels[i].position = min(4, max(-4, finite(channels[i].position, 0)))
      channels[i].reference = finite(channels[i].reference, 0)
    }
    math.unitsPerDiv = scale(math.unitsPerDiv)
    math.position = min(4, max(-4, finite(math.position, 0)))
    math.reference = finite(math.reference, 0)
    math.cornerHz = min(100, max(0.01, finite(math.cornerHz, 1)))
    math.a = source(math.a)
    math.b = source(math.b)
    math.c = source(math.c)
    if math.queries.count != 3 { math.queries = [nil, nil, nil] }
    trigger.source = index(trigger.source, upTo: 4)
    trigger.level = finite(trigger.level, 0)
    trigger.holdoff = min(5, max(0, finite(trigger.holdoff, 0)))
    cursors.channel = index(cursors.channel, upTo: 4)
    cursors.t1 = min(10, max(0, finite(cursors.t1, 3)))
    cursors.t2 = min(10, max(0, finite(cursors.t2, 7)))
    cursors.y1 = min(4, max(-4, finite(cursors.y1, 2)))
    cursors.y2 = min(4, max(-4, finite(cursors.y2, -2)))
  }
}
