import Foundation
import simd

/// A timed list of hard RF pulses: FID, Hahn echo, inversion recovery.
nonisolated struct PulseProgram: Sendable, Hashable, Codable {
  struct Event: Sendable, Hashable, Codable {
    /// Seconds after the program starts.
    var time: Double
    var pulse: RFPulse
  }

  /// Events in time order.
  private(set) var events: [Event]

  init(_ events: [Event]) { self.events = events.sorted { $0.time < $1.time } }

  /// A π/2 at t = 0: the free induction decay.
  static let fid = PulseProgram([Event(time: 0, pulse: .ninety)])

  /// π/2 – τ – π(y): the gradient's dephasing refocuses at 2τ with amplitude e^(−2τ/T₂)
  /// [Hahn 1950].
  static func hahnEcho(tau: Double) -> PulseProgram {
    PulseProgram([Event(time: 0, pulse: .ninety), Event(time: tau, pulse: .refocusing)])
  }

  /// π – Tᵢ – π/2: reads M_z(Tᵢ) = M₀(1 − 2e^(−Tᵢ/T₁)) as the FID amplitude.
  static func inversionRecovery(inversionTime ti: Double) -> PulseProgram {
    PulseProgram([Event(time: 0, pulse: .oneEighty), Event(time: ti, pulse: .ninety)])
  }
}

/// Many isochromats spread in frequency, so T₂* and the spin echo emerge from the physics
/// instead of being imposed (`gyre-integration.md` §4.1, "SpinEnsemble"). All live in the
/// frame rotating at the carrier; isochromat k sees the offset Δf + δfₖ, where Δf =
/// `drive.offsetHz` is f_L − f_rf of the sample's centre.
///
/// RF comes three ways: hard pulses (instant; `apply`, or timed by a `PulseProgram`), finite
/// pulses at the drive's B₁ (`startPulse`, so off-resonance isochromats tip by less), and CW
/// (`drive.continuous`). Every interval between events is solved exactly per isochromat
/// (`Bloch.propagate`), so one ensemble of count 1 behaves exactly like `BlochSimulator`.
nonisolated struct SpinEnsemble: Sendable {
  /// How the isochromats' offsets are spread.
  enum Spread: Sendable, Hashable, Codable {
    /// All on the carrier (no inhomogeneity).
    case none
    /// A linear field gradient (tesla per metre) across a sample of `length` metres:
    /// uniform offsets over Δf = |γ|GΔx/2π. 1 µT/m over 10 cm, water: 4.258 Hz.
    case gradient(teslaPerMetre: Double, length: Double)
    /// A Lorentzian line whose FID decays as e^(−t/T₂*) (approximately, for a finite count:
    /// the isochromats sit at the line's quantiles).
    case lorentzian(t2Star: Double)
  }

  let species: SpinSpecies
  var relaxation: BlochRelaxation
  /// The RF drive in the rotating frame: B₁ amplitude and phase for CW and finite pulses,
  /// `offsetHz` = f_L − f_rf of the sample's centre. `carrierHz` is not used here (the
  /// ensemble has no B₀; the caller locks or detunes the carrier through `offsetHz`).
  var drive = BlochDrive()
  /// Common offset Δf of the whole ensemble from the carrier (Hz): `drive.offsetHz`.
  var offsetHz: Double {
    get { drive.offsetHz }
    set { drive.offsetHz = newValue }
  }
  /// The current spread.
  private(set) var spread: Spread
  /// Per-isochromat offsets δfₖ (Hz).
  private(set) var isochromatOffsets: [Double]
  /// Per-isochromat magnetization (rotating frame).
  private(set) var magnetizations: [SIMD3<Double>]
  /// Simulated time since the last reset (s).
  private(set) var time = 0.0
  /// Hard pulses still to play from `schedule`, in absolute ensemble time.
  private(set) var pending: [PulseProgram.Event] = []
  private var activePulse: ActivePulse?

  private struct ActivePulse: Sendable, Hashable {
    var remaining: Double
    var b1: Double
    var phase: Double
  }

  init(
    species: SpinSpecies = .protonWater, count: Int = 64, spread: Spread = .none,
    relaxation: BlochRelaxation = BlochRelaxation()
  ) {
    self.species = species
    self.relaxation = relaxation
    self.spread = spread
    isochromatOffsets = Self.offsets(count: count, spread: spread, species: species)
    magnetizations = Array(repeating: SIMD3(0, 0, relaxation.m0), count: isochromatOffsets.count)
  }

  // MARK: Spread maths

  /// Offsets for `count` isochromats (Hz), deterministic and symmetric about zero.
  static func offsets(count: Int, spread: Spread, species: SpinSpecies) -> [Double] {
    let n = max(count, 1)
    return (0..<n).map { k in
      let u = (Double(k) + 0.5) / Double(n) - 0.5  // −½ … ½
      switch spread {
      case .none:
        return 0
      case .gradient(let g, let length):
        return abs(species.gammaHzPerT) * g * length * u
      case .lorentzian(let t2Star):
        guard t2Star.isFinite, t2Star > 0 else { return 0 }
        return tan(.pi * u) / (2 * .pi * t2Star)
      }
    }
  }

  /// Spread Δf = |γ|GΔx/2π (Hz) of a linear gradient across a uniform sample.
  /// Water, 1 µT/m over 10 cm: 4.258 Hz.
  static func gradientSpreadHz(species: SpinSpecies, gradient: Double, length: Double) -> Double {
    abs(species.gammaHzPerT * gradient * length)
  }

  /// x where sin x / x = 1/e (2.1995…), solved once by Newton's method.
  static let sincOneOverE: Double = {
    var x = 2.2
    for _ in 0..<40 {
      let f = sin(x) / x - exp(-1.0)
      let df = (x * cos(x) - sin(x)) / (x * x)
      x -= f / df
    }
    return x
  }()

  /// Dephasing time of a gradient line: a linear gradient over a uniform sample gives a
  /// *rectangular* line, so the FID envelope is |sinc(πΔf t)| and falls to 1/e at
  /// 2.1995/(πΔf), not at T₂* = 1/(πΔf) (that formula is for a Lorentzian; corrected in
  /// review). Water, 1 µT/m over 10 cm: 164 ms; 10 µT/m: 16.4 ms. Label it "dephasing time".
  static func dephasingTime(species: SpinSpecies, gradient: Double, length: Double) -> Double {
    let df = gradientSpreadHz(species: species, gradient: gradient, length: length)
    return df > 0 ? sincOneOverE / (.pi * df) : .infinity
  }

  /// First null of the gradient FID, 1/Δf. Water, 1 µT/m over 10 cm: 235 ms.
  static func firstNull(species: SpinSpecies, gradient: Double, length: Double) -> Double {
    let df = gradientSpreadHz(species: species, gradient: gradient, length: length)
    return df > 0 ? 1 / df : .infinity
  }

  /// The ideal gradient-FID envelope |sinc(πΔf t)| (continuous limit of the isochromats).
  static func gradientEnvelope(spreadHz df: Double, at t: Double) -> Double {
    let x = Double.pi * df * t
    return abs(x) < 1e-12 ? 1 : abs(sin(x) / x)
  }

  // MARK: Readouts

  /// Number of isochromats.
  var count: Int { magnetizations.count }

  /// The ensemble average of M (rotating frame).
  var meanMagnetization: SIMD3<Double> {
    magnetizations.reduce(.zero, +) / Double(max(magnetizations.count, 1))
  }

  /// The detected signal: mean Mₓ + iM_y in the rotating frame.
  var signal: SIMD2<Double> {
    let m = meanMagnetization
    return SIMD2(m.x, m.y)
  }

  /// |mean M⊥|, the detected FID envelope.
  var signalMagnitude: Double { simd_length(signal) }

  /// Whether B₁ is on right now (CW or a finite pulse in progress).
  var isRFOn: Bool { activePulse != nil || drive.continuous }
  /// Whether a finite pulse is still being played.
  var isPulsing: Bool { activePulse != nil }

  /// The effective field (tesla, rotating frame) acting on isochromat `index` right now.
  func effectiveField(isochromat index: Int) -> SIMD3<Double> {
    let (b1, phase) = currentRF
    let df = drive.offsetHz + isochromatOffsets[index]
    return SIMD3(b1 * cos(phase), b1 * sin(phase), 2 * .pi * df / abs(species.gamma))
  }

  // MARK: Control

  /// Back to equilibrium at t = 0, with nothing scheduled or playing.
  mutating func reset() {
    for i in magnetizations.indices { magnetizations[i] = SIMD3(0, 0, relaxation.m0) }
    time = 0
    pending = []
    activePulse = nil
  }

  /// Re-spreads the isochromats (a new gradient or count) and returns to equilibrium.
  mutating func respread(count: Int, spread: Spread) {
    self.spread = spread
    isochromatOffsets = Self.offsets(count: count, spread: spread, species: species)
    magnetizations = Array(repeating: SIMD3(0, 0, relaxation.m0), count: isochromatOffsets.count)
    time = 0
    pending = []
    activePulse = nil
  }

  /// Queues `program` to start now; `advance` plays its pulses as their times pass.
  mutating func schedule(_ program: PulseProgram) {
    let start = time
    pending = (pending + program.events.map { PulseProgram.Event(time: start + $0.time, pulse: $0.pulse) })
      .sorted { $0.time < $1.time }
  }

  /// Applies a hard pulse to every isochromat.
  mutating func apply(_ pulse: RFPulse) {
    for i in magnetizations.indices { magnetizations[i] = pulse.rotate(magnetizations[i], gamma: species.gamma) }
  }

  /// Starts `pulse` as a finite pulse at the drive's B₁: on for |θ|/(|γ|B₁), during which every
  /// isochromat turns about its own tilted B_eff. A negative θ turns the other way (phase + π).
  /// With B₁ = 0 (or non-finite) it falls back to a hard pulse.
  mutating func startPulse(_ pulse: RFPulse) {
    let b1 = abs(drive.b1)
    let p = pulse.normalized
    let duration = p.duration(species: species, b1: b1)
    guard b1 > 0, b1.isFinite, duration.isFinite else {
      apply(pulse)
      return
    }
    activePulse = ActivePulse(remaining: duration, b1: b1, phase: p.phase)
  }

  // MARK: Time

  /// Real-time stepping for the Spin tab: advances `dt` seconds, applying scheduled hard
  /// pulses exactly at their times and ending finite pulses exactly on time.
  mutating func advance(_ dt: Double) {
    guard dt > 0, dt.isFinite else { return }
    let end = time + dt
    while let next = pending.first, next.time <= end {
      if next.time > time {
        evolve(next.time - time)
        time = next.time
      }
      apply(next.pulse)
      pending.removeFirst()
    }
    if end > time { evolve(end - time) }
    time = end
  }

  /// Free evolution (plus CW or a finite pulse in progress) and relaxation for `dt`
  /// seconds: exact for every isochromat.
  mutating func freePrecess(_ dt: Double) { evolve(dt) }

  /// Most samples one `acquire` returns (2²², 64 MB): a runaway duration × rate is cut here
  /// instead of exhausting memory.
  static let maxAcquireSamples = 1 << 22

  /// Runs `program` from the current state and records the signal at `sampleRate` for
  /// `duration` seconds (samples at t = 0, 1/fs, …, duration, at most `maxAcquireSamples`).
  /// A pulse scheduled at a sample time is applied before that sample is read. Pulses queued
  /// with `schedule` are not played here; `advance` plays them.
  mutating func acquire(_ program: PulseProgram, duration: Double, sampleRate: Double) -> [SIMD2<Double>] {
    guard sampleRate > 0, sampleRate.isFinite, duration >= 0, duration.isFinite else { return [] }
    let count = Int(min((duration * sampleRate).rounded(.down) + 1, Double(Self.maxAcquireSamples)))
    let start = time
    var events = program.events[...]
    var out = [SIMD2<Double>]()
    out.reserveCapacity(count)
    for k in 0..<count {
      let target = Double(k) / sampleRate
      while let next = events.first, next.time <= target {
        evolve(start + next.time - time)
        apply(next.pulse)
        events = events.dropFirst()
      }
      evolve(start + target - time)
      out.append(signal)
    }
    return out
  }

  // MARK: Internals

  private var currentRF: (b1: Double, phase: Double) {
    if let p = activePulse { return (p.b1, p.phase) }
    return drive.continuous ? (drive.b1, drive.phase) : (0, 0)
  }

  /// Evolves every isochromat for `dt`, splitting at the end of a finite pulse.
  private mutating func evolve(_ dt: Double) {
    guard dt > 0 else { return }
    var remaining = dt
    while remaining > 0 {
      var h = remaining
      if let p = activePulse { h = min(h, p.remaining) }
      let (b1, phase) = currentRF
      let r = relaxation
      let gamma = species.gamma
      let scale = 2 * .pi / abs(gamma)
      for i in magnetizations.indices {
        let bEff = SIMD3(b1 * cos(phase), b1 * sin(phase), scale * (drive.offsetHz + isochromatOffsets[i]))
        magnetizations[i] = Bloch.propagate(
          magnetizations[i], h: h, gamma: gamma, bEff: bEff, t1: r.t1, t2: r.effectiveT2, m0: r.m0)
      }
      if var p = activePulse {
        p.remaining -= h  // exactly 0 when the pulse limited h
        activePulse = p.remaining > 0 ? p : nil
      }
      time += h
      remaining -= h
    }
  }
}
