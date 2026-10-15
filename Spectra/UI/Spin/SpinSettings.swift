import Foundation

/// What the Spin tab shows: Gyre's heavy top, a proton or an electron on its Bloch sphere,
/// or all three side by side.
nonisolated enum SpinView: String, CaseIterable, Identifiable, Codable, Sendable {
  case gyroscope, proton, electron, compare

  var id: String { rawValue }

  var title: String {
    switch self {
    case .gyroscope: "Gyroscope"
    case .proton: "Proton"
    case .electron: "Electron"
    case .compare: "Compare"
    }
  }

  /// SF Symbol (each checked in CoreGlyphs' name_availability.plist).
  var symbol: String {
    switch self {
    case .gyroscope: "gyroscope"
    case .proton: "atom"
    case .electron: "smallcircle.filled.circle"
    case .compare: "rectangle.split.3x1"
    }
  }

  /// The spin species this view simulates with the Bloch ensemble (nil for the rotor and Compare).
  var species: SpinSpecies? {
    switch self {
    case .proton: .protonWater
    case .electron: .electron
    case .gyroscope, .compare: nil
    }
  }

  /// `-open spin/<path>`: "gyroscope", "proton", "electron", "compare" (also "rotor", "nmr", "esr").
  init?(path: String?) {
    guard let path = path?.lowercased().split(separator: "/").first.map(String.init) else { return nil }
    switch path {
    case "gyroscope", "gyro", "rotor", "top": self = .gyroscope
    case "proton", "nmr", "h": self = .proton
    case "electron", "esr", "e": self = .electron
    case "compare", "all": self = .compare
    default: return nil
    }
  }
}

/// Where B₀ comes from.
nonisolated enum SpinFieldSource: String, CaseIterable, Identifiable, Codable, Sendable {
  /// The magnetometer's |B| (and direction), smoothed with τ = 0.25 s.
  case live
  /// The B₀ dial (10 µT … 9.4 T).
  case dial

  var id: String { rawValue }
  var title: String { self == .live ? "Live |B|" : "Dial" }
}

/// The pulse sequence "Run" plays (and "Repeat" replays every TR), as hard pulses at exact
/// times (`PulseProgram`).
nonisolated enum SpinSequence: String, CaseIterable, Identifiable, Codable, Sendable {
  /// One π/2 pulse: the free induction decay.
  case fid
  /// π/2 – τ – π(y): the gradient's dephasing refocuses at 2τ.
  case echo
  /// π – τ – π/2: the FID amplitude reads M_z(τ) = M₀(1 − 2e^(−τ/T₁)).
  case inversion

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fid: "FID"
    case .echo: "Spin echo"
    case .inversion: "Inversion recovery"
    }
  }

  /// The engine program for echo/inversion time `tau` (species seconds).
  func program(tau: Double) -> PulseProgram {
    switch self {
    case .fid: .fid
    case .echo: .hahnEcho(tau: tau)
    case .inversion: .inversionRecovery(inversionTime: tau)
    }
  }
}

/// How much of the spectrum and Wigner frequency axis is shown, as a fraction of the
/// record's full band (±fs/2).
nonisolated enum SpinSpectrumZoom: String, CaseIterable, Identifiable, Codable, Sendable {
  case narrow, medium, full
  var id: String { rawValue }
  var title: String {
    switch self {
    case .narrow: "±⅛ band"
    case .medium: "±¼ band"
    case .full: "Full band"
    }
  }
  var fraction: Double {
    switch self {
    case .narrow: 1.0 / 8
    case .medium: 1.0 / 4
    case .full: 1
    }
  }
}

/// The NMR (or ESR) bench for one species: drive, relaxation, sequence and display speed.
/// Every time-like value is in the species' own seconds and every frequency in its own hertz:
/// the electron's defaults are the proton's scaled by u = γ′ₚ/|γₑ| (1/658), so both species
/// show the same picture at their own speed.
nonisolated struct SpinBench: Codable, Sendable, Equatable {
  /// B₁ (tesla), the co-rotating RF amplitude used by finite pulses and CW.
  var b1: Double
  /// Δf = f_L − f_rf (Hz) of the sample's centre.
  var offsetHz: Double
  /// Phase φ of B₁ (radians, 0 = +x′).
  var phase: Double
  var t1: Double
  var t2: Double
  /// Field gradient across the 10 cm sample (tesla per metre).
  var gradient: Double
  var isochromats: Double
  /// Echo half-time τ, or the inversion time Tᵢ (s).
  var echoTau: Double
  /// Repetition time TR (s) between automatic sequences.
  var repetition: Double
  /// Display slow-motion on top of the species scale: displayed seconds run this fraction
  /// of the species' natural pace (1 = the proton's real time).
  var slowMotion: Double
  /// A sweep-coil ramp dB₀/dt (tesla per second) that starts at each sequence: the FID chirps.
  var ramp: Double
  /// B₁ stays on (CW): Rabi nutation about B_eff.
  var continuous: Bool
  var sequence: SpinSequence

  /// Proton defaults (SpinKnobs' engine defaults) with every time scaled by `u`: B₁ 1 µT, on
  /// resonance, T₁ 2.5 s, T₂ 2 s, 1 µT/m, 64 isochromats, τ 0.1 s, TR 3 s.
  static func defaults(timeUnit u: Double) -> SpinBench {
    SpinBench(
      b1: SpinKnobs.b1.defaultValue, offsetHz: 0, phase: 0, t1: SpinKnobs.t1.defaultValue * u,
      t2: SpinKnobs.t2.defaultValue * u, gradient: SpinKnobs.gradient.defaultValue,
      isochromats: SpinKnobs.isochromats.defaultValue, echoTau: 0.1 * u, repetition: 3 * u, slowMotion: 1, ramp: 0,
      continuous: false, sequence: .fid)
  }

  init(
    b1: Double, offsetHz: Double, phase: Double, t1: Double, t2: Double, gradient: Double, isochromats: Double,
    echoTau: Double, repetition: Double, slowMotion: Double, ramp: Double, continuous: Bool, sequence: SpinSequence
  ) {
    self.b1 = b1
    self.offsetHz = offsetHz
    self.phase = phase
    self.t1 = t1
    self.t2 = t2
    self.gradient = gradient
    self.isochromats = isochromats
    self.echoTau = echoTau
    self.repetition = repetition
    self.slowMotion = slowMotion
    self.ramp = ramp
    self.continuous = continuous
    self.sequence = sequence
  }

  private enum CodingKeys: String, CodingKey {
    case b1, offsetHz, phase, t1, t2, gradient, isochromats, echoTau, repetition, slowMotion, ramp, continuous, sequence
  }

  /// Tolerant decoding: a missing or non-finite field keeps the proton default.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = SpinBench.defaults(timeUnit: 1)
    func value(_ key: CodingKeys, _ fallback: Double) -> Double {
      let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil
      return v.flatMap { $0.isFinite ? $0 : nil } ?? fallback
    }
    b1 = value(.b1, d.b1)
    offsetHz = value(.offsetHz, d.offsetHz)
    phase = value(.phase, d.phase)
    t1 = value(.t1, d.t1)
    t2 = value(.t2, d.t2)
    gradient = value(.gradient, d.gradient)
    isochromats = value(.isochromats, d.isochromats)
    echoTau = value(.echoTau, d.echoTau)
    repetition = value(.repetition, d.repetition)
    // The display pace stays inside its knob (0.05…1): 0 would stop the bench and give the
    // spin.fid stream a zero rate.
    slowMotion = min(1, max(0.05, value(.slowMotion, d.slowMotion)))
    ramp = value(.ramp, d.ramp)
    continuous = ((try? c.decodeIfPresent(Bool.self, forKey: .continuous)) ?? nil) ?? d.continuous
    sequence = ((try? c.decodeIfPresent(SpinSequence.self, forKey: .sequence)) ?? nil) ?? d.sequence
  }

  /// Every value inside its knob's range for a species with time unit `u` (`SpinKnobSpecs`):
  /// a stored value outside it (an older build's range, or a missing field that took the
  /// proton default on the electron bench) goes back to that species' default.
  func sanitized(timeUnit u: Double) -> SpinBench {
    let d = SpinBench.defaults(timeUnit: u)
    func keep(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
      v.isFinite && range.contains(v) ? v : fallback
    }
    var b = self
    b.b1 = keep(b1, SpinKnobs.b1.range, d.b1)
    b.offsetHz = keep(offsetHz, (SpinKnobs.offset.range.lowerBound / u)...(SpinKnobs.offset.range.upperBound / u), d.offsetHz)
    b.phase = keep(phase, SpinKnobs.phase.range, d.phase)
    b.t1 = keep(t1, (SpinKnobs.t1.range.lowerBound * u)...(SpinKnobs.t1.range.upperBound * u), d.t1)
    b.t2 = keep(t2, (SpinKnobs.t2.range.lowerBound * u)...(SpinKnobs.t2.range.upperBound * u), d.t2)
    b.gradient = keep(gradient, SpinKnobs.gradient.range, d.gradient)
    b.isochromats = keep(isochromats, SpinKnobs.isochromats.range, d.isochromats)
    b.echoTau = keep(echoTau, (0.005 * u)...(1 * u), d.echoTau)
    b.repetition = keep(repetition, (0.5 * u)...(10 * u), d.repetition)
    b.slowMotion = keep(slowMotion, 0.05...1, d.slowMotion)
    b.ramp = keep(ramp, (-2e-6 / u)...(2e-6 / u), d.ramp)
    return b
  }
}

/// Everything the Spin tab persists under `Spectra.spin.v1`.
nonisolated struct SpinSaved: Codable, Sendable, Equatable {
  var view: SpinView = .gyroscope
  var gyro = HeavyTopParams()
  /// The field trip last loaded on the rotor ("" = knobs edited by hand).
  var presetID = ""
  var fieldSource: SpinFieldSource = .live
  /// The B₀ dial (tesla).
  var fieldTesla: Double = EarthField.typicalField
  var proton = SpinBench.defaults(timeUnit: 1)
  var electron = SpinBench.defaults(timeUnit: SpinModel.timeUnit(.electron))
  /// Show spins in the frame rotating with the carrier (HETERODYNED) instead of the lab frame.
  var rotatingFrame = true
  /// The carrier follows the Larmor line (a drifting live |B| stays on resonance); off, the
  /// carrier holds where it was and field drift shows up as detuning.
  var lockCarrier = true
  /// Replay the sequence every TR.
  var repeatPulses = true
  /// Tilt the Bloch sphere so B₀ points along your measured field.
  var alignToField = false
  var showTrail = true
  var showVectors = true
  var wignerMode: Phase.TimeFrequencyMode = .smoothedPseudoWigner
  var zoom: SpinSpectrumZoom = .medium
  /// Keep stepping and publishing the Spin streams while the tab is hidden (Scope, Patch).
  var publishHidden = false

  init() {}

  private enum CodingKeys: String, CodingKey {
    case view, gyro, presetID, fieldSource, fieldTesla, proton, electron, rotatingFrame, lockCarrier, repeatPulses
    case alignToField, showTrail, showVectors, wignerMode, zoom, publishHidden
  }

  /// Tolerant decoding: a missing key keeps its default, so adding settings never discards the rest.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func get<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
    let d = SpinSaved()
    view = get(SpinView.self, .view) ?? d.view
    gyro = get(HeavyTopParams.self, .gyro).map { Self.insideKnobs($0.sanitized) } ?? d.gyro
    presetID = get(String.self, .presetID) ?? d.presetID
    fieldSource = get(SpinFieldSource.self, .fieldSource) ?? d.fieldSource
    // Inside the B₀ dial (10 µT … 9.4 T), like the bench values: the dial cannot show or reach
    // anything outside it.
    fieldTesla = get(Double.self, .fieldTesla).flatMap { SpinKnobs.b0.range.contains($0) ? $0 : nil } ?? d.fieldTesla
    proton = get(SpinBench.self, .proton)?.sanitized(timeUnit: 1) ?? d.proton
    electron = get(SpinBench.self, .electron)?.sanitized(timeUnit: SpinModel.timeUnit(.electron)) ?? d.electron
    rotatingFrame = get(Bool.self, .rotatingFrame) ?? d.rotatingFrame
    lockCarrier = get(Bool.self, .lockCarrier) ?? d.lockCarrier
    repeatPulses = get(Bool.self, .repeatPulses) ?? d.repeatPulses
    alignToField = get(Bool.self, .alignToField) ?? d.alignToField
    showTrail = get(Bool.self, .showTrail) ?? d.showTrail
    showVectors = get(Bool.self, .showVectors) ?? d.showVectors
    wignerMode = get(Phase.TimeFrequencyMode.self, .wignerMode) ?? d.wignerMode
    zoom = get(SpinSpectrumZoom.self, .zoom) ?? d.zoom
    publishHidden = get(Bool.self, .publishHidden) ?? d.publishHidden
  }

  /// Every rotor knob inside its dial (`SpinKnobs`), like the benches and B₀: the engine's
  /// `sanitized` allows more (Inertia 0.01…100×, Time up to 10×) than the dials can show, so a
  /// stored value outside a dial goes back to that knob's default.
  static func insideKnobs(_ p: HeavyTopParams) -> HeavyTopParams {
    func keep(_ v: Double, _ knob: SpinKnobRange) -> Double {
      v.isFinite && knob.range.contains(v) ? v : knob.defaultValue
    }
    var q = p
    q.motorRPM = keep(p.motorRPM, SpinKnobs.motor)
    q.inertia = keep(p.inertia, SpinKnobs.inertia)
    q.gravity = keep(p.gravity, SpinKnobs.gravity)
    q.balance = keep(p.balance, SpinKnobs.balance)
    q.friction = keep(p.friction, SpinKnobs.friction)
    q.air = keep(p.air, SpinKnobs.air)
    q.magnet = keep(p.magnet, SpinKnobs.magnet)
    q.timeScale = keep(p.timeScale, SpinKnobs.time)
    return q
  }
}
