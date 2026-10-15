import Foundation

/// The settings model shared by every Spectrum instrument (port of spectra-lab `core/state.js`):
/// three superposable sources, the medium, per-instrument settings, display and feedback.
///
/// JSON keys are the JS keys (`E0`, `lambda`, …), so a spectra-lab `localStorage` blob decodes
/// directly. Decoding follows JS `deserialize`: every field is optional and merges over the
/// defaults, sources are sanitized, `lab.sweeping` is forced off and `active` is truncated and
/// clamped. Use `SpectraState.deserialize(_:)` for the JS "garbage → defaults" behaviour.
nonisolated struct SpectraState: Codable, Equatable, Sendable {
  // MARK: Nested settings

  /// The five instruments of the Spectrum tab.
  enum Instrument: String, CaseIterable, Codable, Sendable, Identifiable {
    case scope, tuner, bench, decompose, lab
    var id: String { rawValue }

    var name: String {
      switch self {
      case .scope: "Wave scope"
      case .tuner: "Spectrum tuner"
      case .bench: "Matter bench"
      case .decompose: "Decompose"
      case .lab: "Spectroscopy lab"
      }
    }

    var detail: String {
      switch self {
      case .scope: "E \u{22A5} B \u{22A5} propagation"
      case .tuner: "One dial, fifteen decades"
      case .bench: "Same beam, different matter"
      case .decompose: "Take the wave apart"
      case .lab: "Sweep and read"
      }
    }
  }

  /// Wave scope display toggles and camera.
  struct ScopeSettings: Codable, Equatable, Sendable {
    var showE = true
    var showB = true
    var showS = true
    /// Camera yaw, degrees.
    var yaw: Double = 64
    /// Camera pitch, degrees (the UI clamps to [−60, 80]).
    var pitch: Double = 18
    var zoom: Double = 1

    init() {}
    init(from decoder: any Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      showE = c.lenient(.showE) ?? showE
      showB = c.lenient(.showB) ?? showB
      showS = c.lenient(.showS) ?? showS
      yaw = c.lenient(.yaw) ?? yaw
      pitch = c.lenient(.pitch) ?? pitch
      zoom = c.lenient(.zoom) ?? zoom
    }
  }

  /// Decompose instrument settings.
  struct DecomposeSettings: Codable, Equatable, Sendable {
    enum Tab: String, CaseIterable, Codable, Sendable, Identifiable {
      case polarization, probe, fourier
      var id: String { rawValue }
    }
    var tab: Tab = .polarization
    /// Polarizer angle, degrees.
    var polarizer: Double = 30
    var probeMode: Wave.ProbeMode = .both
    /// Probe-charge laser strength.
    var a0: Double = 1.5

    init() {}
    init(from decoder: any Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      tab = c.lenient(.tab) ?? tab
      polarizer = c.lenient(.polarizer) ?? polarizer
      probeMode = c.lenient(.probeMode) ?? probeMode
      a0 = c.lenient(.a0) ?? a0
    }
  }

  /// Matter bench settings.
  struct BenchSettings: Codable, Equatable, Sendable {
    enum Arrangement: String, CaseIterable, Codable, Sendable, Identifiable {
      case side, series
      var id: String { rawValue }
    }
    var arrangement: Arrangement = .side
    /// Oscillator resonance wavelength, m.
    var lambda0: Double = 120e-9
    var focus: SpecimenKey = .water

    init() {}
    init(from decoder: any Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      arrangement = c.lenient(.arrangement) ?? arrangement
      lambda0 = c.lenient(.lambda0) ?? lambda0
      focus = c.lenient(.focus) ?? focus
    }
  }

  /// Spectroscopy lab settings. `sweep` is the axis fraction 0…1.
  struct LabSettings: Codable, Equatable, Sendable {
    var sample: SampleKey = .co2
    var mode: SampleMode = .ir
    var sweep: Double = 0.46
    var sweeping = false

    init() {}
    init(from decoder: any Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      sample = c.lenient(.sample) ?? sample
      mode = c.lenient(.mode) ?? mode
      sweep = c.lenient(.sweep) ?? sweep
      sweeping = c.lenient(.sweeping) ?? sweeping
    }
  }

  /// The web prototype's feedback settings (the native app keeps its own in AppSettings).
  struct FeedbackSettings: Codable, Equatable, Sendable {
    var sound = false
    var haptics = true
    var strength: Double = 0.7

    init() {}
    init(from decoder: any Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      sound = c.lenient(.sound) ?? sound
      haptics = c.lenient(.haptics) ?? haptics
      strength = c.lenient(.strength) ?? strength
    }
  }

  /// One edit to the active source (JS `editSource(state, key, value)`).
  enum SourceEdit: Hashable, Sendable {
    case lambda(Double), e0(Double), temperature(Double)
    case theta(Double), delta(Double), phi(Double)
    case cycles(Double), kind(WaveSource.Kind), enabled(Bool)
  }

  // MARK: Stored state

  /// Always three sources: A, B, C.
  var sources: [WaveSource]
  /// Index of the source the dials edit (0…2).
  var active = 0
  /// With Link on, an edit applies the same relative change to every enabled source.
  var link = false
  var medium: Matter.Medium = .vacuum
  /// κ: display cycles per second for the reference source at 1×.
  var speed: Double = 1
  var instrument: Instrument = .scope
  var scope = ScopeSettings()
  var decompose = DecomposeSettings()
  var bench = BenchSettings()
  var lab = LabSettings()
  var feedback = FeedbackSettings()
  var playing = true
  /// Key of the last field trip applied, if any.
  var preset: String? = nil
  /// Native extension: when true, sanitizing allows λ up to `Spectrum.rulerLogMax`
  /// (100,000 km) instead of the web range. Off by default, so default behaviour and parity
  /// are unchanged. Persisted only when true. Switching it off re-sanitizes the sources, so a
  /// source left beyond 1 km clamps back onto the web range (and its dial).
  var extendedRange = false {
    didSet { if oldValue && !extendedRange { sanitizeSources() } }
  }

  /// Source names in order.
  static let sourceNames = ["A", "B", "C"]

  /// spectra-lab `defaults()`: A 550 nm on, B 450 nm off, C 650 nm off. The defaults are not
  /// sanitized, so λ stays exactly 5.5e-7.
  static var defaults: SpectraState { SpectraState() }

  init() {
    sources = [
      WaveSource(lambda: 550e-9),
      WaveSource(enabled: false, lambda: 450e-9),
      WaveSource(enabled: false, lambda: 650e-9),
    ]
  }

  // MARK: Derived

  /// The log₁₀ λ range sanitizing uses: the web range, or the ruler range when
  /// `extendedRange` is on.
  var logRange: ClosedRange<Double> { extendedRange ? Spectrum.rulerLogRange : Spectrum.logRange }

  /// Reference source for the display: the first enabled source, else A.
  var referenceSource: WaveSource { sources.first(where: \.enabled) ?? sources[0] }

  /// Real seconds per displayed second: κ / f_ref (JS `timeScale`).
  var timeScale: Double { speed / Spectrum.frequency(referenceSource.lambda) }

  /// How many times slower than reality the display runs (JS `slowMotion`).
  var slowMotion: Double { 1 / timeScale }

  /// The enabled sources in order.
  var enabledSources: [WaveSource] { sources.filter(\.enabled) }

  /// Indices of the enabled sources.
  var enabledIndices: [Int] { sources.indices.filter { sources[$0].enabled } }

  /// The active source (`active` clamped into `sources`, so a stray index cannot trap).
  var activeSource: WaveSource {
    get { sources[activeIndex] }
    set { sources[activeIndex] = newValue }
  }

  /// `active` clamped to a valid index of `sources`.
  private var activeIndex: Int { Swift.max(0, Swift.min(active, sources.count - 1)) }

  /// λ = c/f (JS `lambdaFromFrequency`).
  static func lambda(frequency f: Double) -> Double { SI.c / f }

  // MARK: Editing

  /// Applies an edit to the active source (JS `editSource`). With Link on, the targets are the
  /// enabled sources plus the active one: λ, E₀ and T scale by the active source's ratio, θ, δ
  /// and φ shift by its difference, and every other field copies the value. Each target is
  /// then sanitized (with `logRange`).
  mutating func edit(_ e: SourceEdit) {
    let active = activeIndex
    let src = sources[active]
    let targets = link ? sources.indices.filter { sources[$0].enabled || $0 == active } : [active]
    let range = logRange
    for i in targets {
      var s = sources[i]
      let isActive = i == active
      switch e {
      case .lambda(let v): s.lambda = isActive ? v : s.lambda * (v / src.lambda)
      case .e0(let v): s.e0 = isActive ? v : s.e0 * (v / src.e0)
      case .temperature(let v): s.temperature = isActive ? v : s.temperature * (v / src.temperature)
      case .theta(let v): s.theta = isActive ? v : s.theta + (v - src.theta)
      case .delta(let v): s.delta = isActive ? v : s.delta + (v - src.delta)
      case .phi(let v): s.phi = isActive ? v : s.phi + (v - src.phi)
      case .cycles(let v): s.cycles = v
      case .kind(let v): s.kind = v
      case .enabled(let v): s.enabled = v
      }
      s.sanitize(logRange: range)
      sources[i] = s
    }
  }

  /// Sanitizes every source with `logRange`.
  mutating func sanitizeSources() {
    let range = logRange
    for i in sources.indices { sources[i].sanitize(logRange: range) }
  }

  // MARK: Serialization

  enum CodingKeys: String, CodingKey {
    case sources, active, link, medium, speed, instrument, scope, decompose, bench, lab, feedback, playing, preset
    case extendedRange
  }

  /// JS `deserialize` semantics: requires exactly three sources (else the defaults), merges
  /// each source over its default (A/B/C), sanitizes them, forces `lab.sweeping` off and sets
  /// `active = clamp(active | 0, 0, 2)` ("2" and 2.7 → 2, −1 → 0). Mistyped fields keep their
  /// defaults; an unknown medium decodes as vacuum.
  init(from decoder: any Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    var list = try c.nestedUnkeyedContainer(forKey: .sources)
    var decoded: [WaveSource] = []
    let base = SpectraState().sources
    while !list.isAtEnd, decoded.count <= base.count {
      // Each entry merges over its own default (A/B/C); a non-object entry keeps the default.
      guard let entry = try? list.superDecoder() else { break }
      var s = decoded.count < base.count ? base[decoded.count] : WaveSource()
      try? s.merge(from: entry)
      decoded.append(s)
    }
    guard decoded.count == 3 else { return }  // stays at the defaults
    link = c.lenient(.link) ?? link
    if let raw: String = c.lenient(.medium) { medium = Matter.Medium(rawValue: raw) ?? .vacuum }
    speed = c.lenient(.speed) ?? speed
    instrument = c.lenient(.instrument) ?? instrument
    scope = c.lenient(.scope) ?? scope
    decompose = c.lenient(.decompose) ?? decompose
    bench = c.lenient(.bench) ?? bench
    lab = c.lenient(.lab) ?? lab
    lab.sweeping = false
    feedback = c.lenient(.feedback) ?? feedback
    playing = c.lenient(.playing) ?? playing
    preset = c.lenient(.preset)
    extendedRange = c.lenient(.extendedRange) ?? false
    sources = decoded
    sanitizeSources()
    active = Self.jsActive(c)
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(sources, forKey: .sources)
    try c.encode(active, forKey: .active)
    try c.encode(link, forKey: .link)
    try c.encode(medium, forKey: .medium)
    try c.encode(speed, forKey: .speed)
    try c.encode(instrument, forKey: .instrument)
    try c.encode(scope, forKey: .scope)
    try c.encode(decompose, forKey: .decompose)
    try c.encode(bench, forKey: .bench)
    try c.encode(lab, forKey: .lab)
    try c.encode(feedback, forKey: .feedback)
    try c.encode(playing, forKey: .playing)
    try c.encodeIfPresent(preset, forKey: .preset)
    if extendedRange { try c.encode(true, forKey: .extendedRange) }
  }

  /// JS `deserialize(text)`: anything that is not a JSON object with three sources yields the
  /// defaults.
  static func deserialize(_ data: Data) -> SpectraState {
    (try? JSONDecoder().decode(SpectraState.self, from: data)) ?? SpectraState()
  }

  /// JS `deserialize(text)` for a string.
  static func deserialize(_ text: String) -> SpectraState { deserialize(Data(text.utf8)) }

  /// JS `serialize(state)`: compact JSON with the JS keys. A non-finite number (say a κ of ∞
  /// set by a bad caller) is written as the string "Infinity"/"-Infinity"/"NaN" instead of
  /// failing the whole encode (a plain `JSONEncoder` throws, which used to return empty data
  /// and lose every setting); `deserialize` then restores that one field's default.
  func serialized() -> Data {
    let encoder = JSONEncoder()
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    return (try? encoder.encode(self)) ?? Data()
  }

  /// `s.active | 0` (ToInt32: numbers truncate toward zero, numeric strings parse, anything
  /// else is 0), clamped to 0…2.
  private static func jsActive(_ c: KeyedDecodingContainer<CodingKeys>) -> Int {
    var v = 0.0
    if let d: Double = c.lenient(.active) {
      v = d
    } else if let s: String = c.lenient(.active) {
      v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    } else if let b: Bool = c.lenient(.active) {
      v = b ? 1 : 0
    }
    guard v.isFinite else { return 0 }
    let t = v.rounded(.towardZero)
    let int32 = Int32(truncatingIfNeeded: Int64(t.truncatingRemainder(dividingBy: 4_294_967_296)))
    return min(2, max(0, Int(int32)))
  }

}

nonisolated extension KeyedDecodingContainer {
  /// The value for `key` when present and of the right type, else nil (never throws).
  fileprivate func lenient<T: Decodable>(_ key: Key) -> T? {
    (try? decodeIfPresent(T.self, forKey: key)) ?? nil
  }
}

nonisolated extension SpectraState {
  /// Dial ranges of the field-controls sheet (spectra-lab `ui/controls.js`).
  enum Dial: String, CaseIterable, Sendable {
    case lambda, temperature, e0, theta, delta, phi, cycles

    /// The dial's range: log₁₀ of the value for log dials, the value itself for linear ones.
    var range: ClosedRange<Double> {
      switch self {
      case .lambda: Spectrum.logMin...Spectrum.logMax
      case .temperature: 0...7
      case .e0: -3...13
      case .theta: -90...90
      case .delta: -180...180
      case .phi: 0...360
      case .cycles: 1...12
      }
    }

    /// The dial's range with the native ruler extension: λ reaches `Spectrum.rulerLogMax`
    /// (100,000 km) when `extended` is true; every other dial is unchanged.
    func range(extended: Bool) -> ClosedRange<Double> {
      self == .lambda && extended ? Spectrum.rulerLogRange : range
    }

    /// True when the dial position is log₁₀ of the value.
    var isLog: Bool { self == .lambda || self == .temperature || self == .e0 }

    /// Quantization step of the value (nil = continuous): 1° for angles, 0.5 for cycles.
    var step: Double? {
      switch self {
      case .theta, .delta, .phi: 1
      case .cycles: 0.5
      default: nil
      }
    }
  }
}
