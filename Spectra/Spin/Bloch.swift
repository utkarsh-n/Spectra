import Foundation
import simd

/// The Bloch equations [Bloch 1946] in the frame rotating with the RF carrier:
///
///   dM/dt = γ M × B_eff − (Mₓ x̂ + M_y ŷ)/T₂ − (M_z − M₀) ẑ/T₁
///
/// The frame turns about z with angular velocity Ω_f, so B_eff = B + (Ω_f/γ) ẑ. Locked to the
/// carrier (`BlochSimulator`), B_eff = (B₁ cos φ, B₁ sin φ, 2πΔf/|γ|) with Δf = f_L − f_rf.
///
/// Two integrators, both unconditionally stable at any κ:
/// - `step`: Strang splitting (`gyre-integration.md` §4.1): an exact Rodrigues rotation for
///   h/2, exact exponential relaxation for h, the rotation for h/2 again. Exact when B_eff ∥ z
///   or without relaxation; otherwise second order in h.
/// - `propagate`: the exact solution for a field held constant over the step,
///   M(h) = e^(Gh)·(M, 1) with G the affine Bloch generator. What the simulators use, so a CW
///   drive with relaxation reaches the true steady state at any step size.
nonisolated enum Bloch {
  /// Free precession: M turns about `field` with angular velocity −γB for `duration` seconds.
  static func precess(_ m: SIMD3<Double>, gamma: Double, field: SIMD3<Double>, duration: Double) -> SIMD3<Double> {
    SpinMath.rotate(m, angularVelocity: -gamma * field, duration: duration)
  }

  /// Fastest relaxation rate (s⁻¹): a time constant of 0 (or below 1 ps) relaxes at this rate,
  /// which is "instant" for any step longer than a few tens of picoseconds.
  static let maxRelaxationRate = 1e12

  /// Relaxation rate 1/T (s⁻¹) for a time constant `t` (s). Infinite or NaN means no
  /// relaxation (0); T ≤ 0 means instant relaxation (`maxRelaxationRate`), never a division
  /// by zero or "no relaxation" by accident.
  static func relaxationRate(_ t: Double) -> Double {
    guard t.isFinite else { return 0 }
    return t > 0 ? min(1 / t, maxRelaxationRate) : maxRelaxationRate
  }

  /// Exact relaxation over `duration`: Mₓ, M_y decay with T₂; M_z recovers toward M₀ with T₁.
  /// Infinite times mean no relaxation; zero means instant (`relaxationRate`).
  static func relax(_ m: SIMD3<Double>, duration h: Double, t1: Double, t2: Double, m0: Double) -> SIMD3<Double> {
    let e2 = exp(-h * relaxationRate(t2))
    let e1 = exp(-h * relaxationRate(t1))
    return SIMD3(m.x * e2, m.y * e2, m0 + (m.z - m0) * e1)
  }

  /// One Strang-split step of length `h` with a constant effective field `bEff` (tesla).
  static func step(
    _ m: inout SIMD3<Double>, h: Double, gamma: Double, bEff: SIMD3<Double>,
    t1: Double, t2: Double, m0: Double
  ) {
    m = precess(m, gamma: gamma, field: bEff, duration: 0.5 * h)
    m = relax(m, duration: h, t1: t1, t2: t2, m0: m0)
    m = precess(m, gamma: gamma, field: bEff, duration: 0.5 * h)
  }

  /// The exact Bloch evolution over `h` seconds in a constant field `bEff` (tesla):
  /// - no relaxation: one Rodrigues rotation (|M| is kept exactly);
  /// - B_eff ∥ z: rotation about z and relaxation commute, so rotate then relax;
  /// - otherwise: M(h) = M_ss + e^(Ah)(M − M_ss) with A = [w]× − diag(1/T₂, 1/T₂, 1/T₁),
  ///   w = −γB_eff, and M_ss the CW steady state (`steadyState`); e^(Ah) by scaling and
  ///   squaring (error ~1e-13 for any h). Evolving the deviation from M_ss keeps the fixed
  ///   point exact: with stiff relaxation (T ≪ h, e.g. T = 0 → 10¹² s⁻¹) the ~2ˢ rounding
  ///   growth of s squarings only touches a decaying deviation, so |M| cannot creep past M₀.
  ///   Without a steady state (T₁ = ∞) it is e^(Gh) of the 4 × 4 affine generator
  ///   G = [[A, M₀ẑ/T₁], [0, 0]].
  ///
  /// A non-finite step, γ, field or M₀ leaves M unchanged (a NaN from a live sensor or a
  /// modulation source must not poison the state for good), and so does a step whose result
  /// would overflow.
  static func propagate(
    _ m: SIMD3<Double>, h: Double, gamma: Double, bEff: SIMD3<Double>, t1: Double, t2: Double, m0: Double
  ) -> SIMD3<Double> {
    guard h > 0, h.isFinite, gamma.isFinite, m0.isFinite,
      bEff.x.isFinite, bEff.y.isFinite, bEff.z.isFinite
    else { return m }
    let r2 = relaxationRate(t2)
    let r1 = relaxationRate(t1)
    let out: SIMD3<Double>
    if r1 == 0, r2 == 0 {
      out = precess(m, gamma: gamma, field: bEff, duration: h)
    } else if bEff.x == 0, bEff.y == 0 {
      out = relax(precess(m, gamma: gamma, field: bEff, duration: h), duration: h, t1: t1, t2: t2, m0: m0)
    } else {
      let w = -gamma * bEff
      // Columns of A (simd matrices are column-major); the fourth column carries M₀ẑ/T₁.
      let a = simd_double4x4(
        SIMD4(-r2, w.z, -w.y, 0),
        SIMD4(-w.z, -r2, w.x, 0),
        SIMD4(w.y, -w.x, -r1, 0),
        SIMD4(0, 0, 0, 0))
      if r1 > 0, let ss = steadyState(gamma: gamma, bEff: bEff, t1: t1, t2: t2, m0: m0),
        ss.x.isFinite, ss.y.isFinite, ss.z.isFinite
      {
        let d = m - ss
        let e = exponential(a * h) * SIMD4(d.x, d.y, d.z, 0)
        out = ss + SIMD3(e.x, e.y, e.z)
      } else {
        var g = a
        g[3] = SIMD4(0, 0, r1 * m0, 0)
        let e = exponential(g * h) * SIMD4(m.x, m.y, m.z, 1)
        out = SIMD3(e.x, e.y, e.z)
      }
    }
    return out.x.isFinite && out.y.isFinite && out.z.isFinite ? out : m
  }

  /// e^X for a 4 × 4 matrix: scale X by 2⁻ˢ until its ∞-norm is ≤ 1/8, sum the degree-10
  /// Taylor series by Horner's rule (truncation ≤ 1e-18), then square s times.
  static func exponential(_ x: simd_double4x4) -> simd_double4x4 {
    var norm = 0.0
    for row in 0..<4 {
      var sum = 0.0
      for col in 0..<4 { sum += abs(x[col][row]) }
      norm = max(norm, sum)
    }
    guard norm.isFinite else { return simd_double4x4(diagonal: SIMD4(repeating: .nan)) }
    let squarings = norm > 0.125 ? Int((log2(norm / 0.125)).rounded(.up)) : 0
    let a = x * (1 / pow(2.0, Double(squarings)))
    let identity = simd_double4x4(diagonal: SIMD4(repeating: 1))
    var p = identity
    for k in stride(from: 10, through: 1, by: -1) { p = identity + (a * p) * (1 / Double(k)) }
    for _ in 0..<squarings { p = p * p }
    return p
  }

  /// The steady state under a constant `bEff` (CW drive), solved exactly from the linear
  /// system (W − R)M + (M₀/T₁)ẑ = 0. Nil when nothing relaxes (no steady state).
  static func steadyState(gamma: Double, bEff: SIMD3<Double>, t1: Double, t2: Double, m0: Double) -> SIMD3<Double>? {
    let r2 = relaxationRate(t2)
    let r1 = relaxationRate(t1)
    guard r1 > 0 else { return nil }
    let w = -gamma * bEff
    // Rows of A = [w]× − diag(r2, r2, r1).
    let a0 = SIMD3<Double>(-r2, -w.z, w.y)
    let a1 = SIMD3<Double>(w.z, -r2, -w.x)
    let a2 = SIMD3<Double>(-w.y, w.x, -r1)
    let rhs = SIMD3<Double>(0, 0, -m0 * r1)
    let det = simd_dot(a0, simd_cross(a1, a2))
    guard abs(det) > 0 else { return nil }
    // Cramer's rule with the rows as a matrix: solution = (rhs · (a1×a2), …)/det on columns.
    let c0 = simd_cross(a1, a2)
    let c1 = simd_cross(a2, a0)
    let c2 = simd_cross(a0, a1)
    // The inverse of the row matrix has columns c0, c1, c2 divided by det.
    return (c0 * rhs.x + c1 * rhs.y + c2 * rhs.z) / det
  }

  /// Rabi frequency off resonance, f_eff = √(f₁² + Δf²) (Hz).
  static func effectiveHz(rabiHz: Double, offsetHz: Double) -> Double { hypot(rabiHz, offsetHz) }

  /// Maximum inversion probability of a CW drive from equilibrium, (1 − M_z,min/M₀)/2 =
  /// f₁²/(f₁² + Δf²) (Rabi). f₁ 42.576 Hz, Δf 10 Hz: 0.94772. This is *not* the largest
  /// |M_xy|: B_eff tilts θ from z, M sweeps a cone up to 2θ, and |M_xy| reaches 1 whenever
  /// 2θ ≥ 90° (`gyre-integration.md` §4.1, corrected in review).
  static func maxInversionProbability(rabiHz: Double, offsetHz: Double) -> Double {
    let f1 = rabiHz * rabiHz
    let total = f1 + offsetHz * offsetHz
    return total > 0 ? f1 / total : 0
  }

  /// Tilt θ of B_eff from +z, atan2(f₁, Δf) (radians). f₁ 42.576 Hz, Δf 10 Hz: 76.8°.
  static func effectiveFieldTilt(rabiHz: Double, offsetHz: Double) -> Double { atan2(abs(rabiHz), offsetHz) }

  /// The lowest M_z/M₀ a CW drive reaches from equilibrium without relaxation, cos 2θ.
  static func minimumLongitudinal(rabiHz: Double, offsetHz: Double) -> Double {
    1 - 2 * maxInversionProbability(rabiHz: rabiHz, offsetHz: offsetHz)
  }
}

/// T₁, T₂ and the equilibrium magnetization. T₂ is kept ≤ 2T₁ (physical bound). An infinite
/// time means no relaxation; a time of 0 means instant relaxation (`Bloch.relaxationRate`).
nonisolated struct BlochRelaxation: Sendable, Hashable, Codable {
  /// Longitudinal relaxation (s). Tap water: ~2–3 s.
  var t1 = 2.5
  /// Transverse relaxation (s).
  var t2 = 2.0
  /// Equilibrium magnetization along +B₀ (normalised units by default).
  var m0 = 1.0

  /// No relaxation at all: a lossless spin.
  static let none = BlochRelaxation(t1: .infinity, t2: .infinity, m0: 1)

  /// T₂ clamped to the physical bound 2T₁.
  var effectiveT2: Double { min(t2, 2 * t1) }
}

/// An RF pulse: a rotation of M about an axis in the transverse plane of the rotating frame.
nonisolated struct RFPulse: Sendable, Hashable, Codable {
  /// Flip angle θ in radians.
  var flipAngle: Double
  /// Phase φ of B₁ in the rotating frame, radians (0 = +x).
  var phase = 0.0

  /// π/2 about x: tips M₀ into the transverse plane (starts an FID).
  static let ninety = RFPulse(flipAngle: .pi / 2)
  /// π about x: inverts M_z.
  static let oneEighty = RFPulse(flipAngle: .pi)
  /// π about y: the refocusing pulse of a Hahn/CPMG echo.
  static let refocusing = RFPulse(flipAngle: .pi, phase: .pi / 2)

  init(flipAngle: Double, phase: Double = 0) {
    self.flipAngle = flipAngle
    self.phase = phase
  }

  /// An arbitrary flip angle and phase in degrees (the Drive page's "θ" pulse).
  init(degrees: Double, phaseDegrees: Double = 0) {
    self.init(flipAngle: degrees * .pi / 180, phase: phaseDegrees * .pi / 180)
  }

  /// Duration of the pulse at RF amplitude `b1` (tesla): |θ|/(|γ|B₁).
  func duration(species: SpinSpecies, b1: Double) -> Double { abs(flipAngle) / abs(species.gamma * b1) }

  /// The same rotation with a non-negative flip angle: −θ about φ is +θ about φ + π. Finite
  /// pulses play this form (a negative duration would otherwise drop the pulse).
  var normalized: RFPulse {
    flipAngle < 0 ? RFPulse(flipAngle: -flipAngle, phase: phase + .pi) : self
  }

  /// Applies the pulse instantly ("hard" pulse): the same rotation a resonant B₁ along
  /// (cos φ, sin φ, 0) produces, angular velocity −γB₁. For γ > 0 a π/2 about x takes +z to +y.
  func rotate(_ m: SIMD3<Double>, gamma: Double) -> SIMD3<Double> {
    let axis = SIMD3<Double>(cos(phase), sin(phase), 0)
    let sense: Double = gamma >= 0 ? -1 : 1
    return SpinMath.rotate(m, about: axis, by: sense * flipAngle)
  }
}

/// The RF drive: carrier, B₁ amplitude and phase, CW on or off.
nonisolated struct BlochDrive: Sendable, Hashable, Codable {
  /// RF amplitude B₁ (tesla) used for CW and finite pulses. 0.1–10 µT on the Drive page.
  var b1 = 1e-6
  /// Phase φ of B₁ in the rotating frame (radians, 0 = +x).
  var phase = 0.0
  /// Offset Δf = f_L − f_rf (Hz) while the carrier is locked to the Larmor line.
  var offsetHz = 0.0
  /// A fixed carrier (Hz). Nil locks the carrier to the line (minus `offsetHz`), so a
  /// drifting live |B| stays on resonance; a fixed carrier lets the drift detune it.
  var carrierHz: Double? = nil
  /// CW: B₁ stays on between pulses.
  var continuous = false
}

/// One driven spin isochromat: magnetization M in the rotating frame, B₀ along +z (the
/// live |B| or a knob), an RF field rotating with the carrier, and T₁/T₂ relaxation.
///
/// The lab-frame vector is M_lab = R_z(frameAngle)·M, which is exact for a circularly
/// polarized B₁ (the rotating-wave picture; the Bloch–Siegert shift of a linear coil is
/// not modelled). The field is constant between control changes, so every step is the exact
/// solution (`Bloch.propagate`): long runs stay on the sphere without relaxation and reach the
/// true CW steady state with it, at any step size.
nonisolated struct BlochSimulator: Sendable {
  var species: SpinSpecies
  /// B₀ magnitude along +z, tesla.
  var b0: Double { didSet { b0 = abs(b0) } }
  var drive: BlochDrive
  var relaxation: BlochRelaxation

  /// M in the rotating frame (units of M₀).
  private(set) var magnetization: SIMD3<Double>
  /// Simulated time, seconds.
  private(set) var time = 0.0
  /// Angle of the rotating frame about +z (wrapped to (−π, π]).
  private(set) var frameAngle = 0.0
  private var activePulse: ActivePulse?

  private struct ActivePulse: Sendable, Hashable {
    var remaining: Double
    var b1: Double
    var phase: Double
  }

  init(
    species: SpinSpecies = .protonWater, b0: Double = 50e-6,
    drive: BlochDrive = BlochDrive(), relaxation: BlochRelaxation = BlochRelaxation()
  ) {
    self.species = species
    self.b0 = abs(b0)
    self.drive = drive
    self.relaxation = relaxation
    magnetization = SIMD3(0, 0, relaxation.m0)
  }

  // MARK: Readouts

  var gamma: Double { species.gamma }
  /// Larmor frequency |γ|B₀/2π (Hz).
  var larmorHz: Double { species.larmorHz(field: b0) }
  /// The RF carrier (Hz).
  var carrierHz: Double { drive.carrierHz ?? (larmorHz - drive.offsetHz) }
  /// Δf = f_L − f_rf (Hz): what is left to see in the rotating frame.
  var detuningHz: Double { larmorHz - carrierHz }
  /// Rabi frequency f₁ = |γ|B₁/2π of the drive amplitude (Hz).
  var rabiHz: Double { species.rabiHz(b1: drive.b1) }
  /// √(f₁² + Δf²) (Hz).
  var effectiveHz: Double { Bloch.effectiveHz(rabiHz: rabiHz, offsetHz: detuningHz) }
  /// Whether B₁ is on right now (CW or a finite pulse in progress).
  var isRFOn: Bool { activePulse != nil || drive.continuous }
  /// Whether a finite pulse is still being played.
  var isPulsing: Bool { activePulse != nil }
  /// Angular velocity of the rotating frame about +z (rad/s), in the species' own sense.
  var frameAngularVelocity: Double { species.precessionSense.sign * 2 * .pi * carrierHz }

  /// The effective field in the rotating frame right now (tesla).
  var effectiveField: SIMD3<Double> {
    let (b1, phase) = currentRF
    return SIMD3(b1 * cos(phase), b1 * sin(phase), 2 * .pi * detuningHz / abs(gamma))
  }

  /// M in the lab frame (B₀ along +z).
  var labMagnetization: SIMD3<Double> { SpinMath.rotateZ(magnetization, by: frameAngle) }

  /// The lab-frame field this rotating-frame state stands for, at the current time:
  /// B₀ẑ + B₁(cos(Ω_f t + φ), sin(Ω_f t + φ), 0) with Ω_f = −sign(γ)·2πf_rf. For γ > 0 that is
  /// B₁(cos(ω_rf t − φ), −sin(ω_rf t − φ), 0): the drive co-rotates with the clockwise
  /// precession (`gyre-integration.md` §4.1, rotation sense corrected in review).
  var labField: SIMD3<Double> {
    let (b1, phase) = currentRF
    let a = frameAngle + phase
    return SIMD3(b1 * cos(a), b1 * sin(a), b0)
  }

  /// The CW steady state for the current drive (rotating frame), or nil without T₁.
  var steadyState: SIMD3<Double>? {
    let r = relaxation
    return Bloch.steadyState(gamma: gamma, bEff: effectiveField, t1: r.t1, t2: r.effectiveT2, m0: r.m0)
  }
  /// Mₓ + iM_y in the rotating frame: the heterodyned signal at the carrier.
  var transverse: SIMD2<Double> { SIMD2(magnetization.x, magnetization.y) }
  /// Mₓ + iM_y in the lab frame: what a pickup coil sees at the true Larmor frequency.
  var labTransverse: SIMD2<Double> {
    let m = labMagnetization
    return SIMD2(m.x, m.y)
  }
  /// |M⊥|, the FID envelope.
  var transverseMagnitude: Double { hypot(magnetization.x, magnetization.y) }

  // MARK: Control

  /// Back to equilibrium M = M₀ẑ at t = 0, with no pulse playing.
  mutating func reset() {
    magnetization = SIMD3(0, 0, relaxation.m0)
    time = 0
    frameAngle = 0
    activePulse = nil
  }

  /// Sets M directly (rotating frame), e.g. to start from a tipped state.
  mutating func setMagnetization(_ m: SIMD3<Double>) { magnetization = m }

  /// Applies `pulse` instantly (a hard pulse).
  mutating func applyHardPulse(_ pulse: RFPulse) {
    magnetization = pulse.rotate(magnetization, gamma: gamma)
  }

  /// Starts `pulse` as a finite pulse at the drive amplitude: B₁ stays on for |θ|/(|γ|B₁)
  /// and `step` plays it out, ending it exactly on time. Off resonance it tips by less. A
  /// negative θ turns the other way (phase + π); with B₁ = 0 (or non-finite) it is a hard pulse.
  mutating func startPulse(_ pulse: RFPulse) {
    let b1 = abs(drive.b1)
    let p = pulse.normalized
    let duration = p.duration(species: species, b1: b1)
    guard b1 > 0, b1.isFinite, duration.isFinite else {
      applyHardPulse(pulse)
      return
    }
    activePulse = ActivePulse(remaining: duration, b1: b1, phase: p.phase)
  }

  /// Advances by `dt` seconds. Finite pulses end exactly within the step.
  mutating func step(_ dt: Double) {
    guard dt > 0, dt.isFinite else { return }
    var remaining = dt
    while remaining > 0 {
      var h = remaining
      if let p = activePulse { h = min(h, p.remaining) }
      let (b1, phase) = currentRF
      advance(h, b1: b1, phase: phase)
      if var p = activePulse {
        p.remaining -= h
        activePulse = p.remaining > 0 ? p : nil
      }
      remaining -= h
    }
  }

  private var currentRF: (b1: Double, phase: Double) {
    if let p = activePulse { return (p.b1, p.phase) }
    return drive.continuous ? (drive.b1, drive.phase) : (0, 0)
  }

  private mutating func advance(_ h: Double, b1: Double, phase: Double) {
    let bEff = SIMD3(b1 * cos(phase), b1 * sin(phase), 2 * .pi * detuningHz / abs(gamma))
    let r = relaxation
    magnetization = Bloch.propagate(magnetization, h: h, gamma: gamma, bEff: bEff, t1: r.t1, t2: r.effectiveT2, m0: r.m0)
    time += h
    let turned = frameAngle + frameAngularVelocity * h
    if turned.isFinite { frameAngle = SpinMath.wrapAngle(turned) }
  }
}

/// The Bloch equations in the lab frame, dM/dt = γ M × B(t) with relaxation about the static
/// field (taken along +z): what the rotating frame stands for, integrated directly. Each step
/// solves the equations exactly with the field held at the step's midpoint
/// (`Bloch.propagate`), so |M| never grows; accuracy needs steps short against 1/f_L (for a
/// rotating B₁ the error per Larmor cycle falls as the square of the step).
///
/// Use it to check rotation senses (a counter-rotating B₁ barely tips M) and for any drive
/// the rotating frame cannot express, such as a linearly polarized coil field.
nonisolated struct LabFrameBloch: Sendable {
  var species: SpinSpecies
  var relaxation: BlochRelaxation
  /// M in the lab frame (units of M₀).
  private(set) var magnetization: SIMD3<Double>
  /// Simulated time, seconds.
  private(set) var time = 0.0

  init(species: SpinSpecies = .protonWater, relaxation: BlochRelaxation = .none, magnetization: SIMD3<Double>? = nil) {
    self.species = species
    self.relaxation = relaxation
    self.magnetization = magnetization ?? SIMD3(0, 0, relaxation.m0)
  }

  /// One step of `h` seconds in the field `field` (tesla), held constant over the step.
  mutating func step(_ h: Double, field: SIMD3<Double>) {
    guard h > 0, h.isFinite else { return }
    let r = relaxation
    magnetization = Bloch.propagate(
      magnetization, h: h, gamma: species.gamma, bEff: field, t1: r.t1, t2: r.effectiveT2, m0: r.m0)
    time += h
  }

  /// Runs for `duration` seconds in `steps` equal steps, sampling `field(t)` at each step's
  /// midpoint.
  mutating func run(duration: Double, steps: Int, field: (Double) -> SIMD3<Double>) {
    guard duration > 0, steps > 0 else { return }
    let h = duration / Double(steps)
    for _ in 0..<steps { step(h, field: field(time + 0.5 * h)) }
  }

  /// A circularly polarized drive in the lab frame: B₀ẑ + B₁(cos(s·ωt + φ), sin(s·ωt + φ), 0),
  /// with `sense` the way B₁ turns about +z. Resonant when it turns with the spin's own
  /// precession (`species.precessionSense`).
  static func circularField(
    b0: Double, b1: Double, frequencyHz: Double, phase: Double = 0, sense: PrecessionSense, at t: Double
  ) -> SIMD3<Double> {
    let a = sense.sign * 2 * .pi * frequencyHz * t + phase
    return SIMD3(b1 * cos(a), b1 * sin(a), b0)
  }
}
