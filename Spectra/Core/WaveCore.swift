import Foundation

/// One Spectra source: a monochromatic plane wave, a pulse or a thermal spectrum travelling
/// along +z (JS `defaultSource`).
///
/// - `lambda`: vacuum wavelength, m.
/// - `e0`: peak electric field, V/m (JSON key `E0`).
/// - `theta`: Jones amplitude-split angle ψ, degrees: Ex₀ = E₀ cos ψ, Ey₀ = E₀ sin ψ (the tilt
///   of linear light; 90 = vertical, the default).
/// - `delta`: phase of Ey relative to Ex, degrees (0 linear, ±90 circular when ψ = 45).
/// - `phi`: overall phase, degrees.
/// - `cycles`: pulse length in carrier cycles (FWHM of intensity).
/// - `temperature`: thermal source temperature, K.
nonisolated struct WaveSource: Codable, Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
    case plane, pulse, thermal
    var id: String { rawValue }

    /// Display name (spectra-lab `SOURCE_KINDS`).
    var name: String {
      switch self {
      case .plane: "Plane wave"
      case .pulse: "Pulse"
      case .thermal: "Thermal"
      }
    }

    /// One-sentence explanation (spectra-lab `SOURCE_KINDS`).
    var note: String {
      switch self {
      case .plane: "One frequency with flat wave fronts, the simplest case."
      case .pulse: "A short burst. Making it shorter needs a wider spread of frequencies."
      case .thermal: "A hot object's glow: many frequencies with random phases, following Planck's law."
      }
    }
  }

  var enabled: Bool
  var kind: Kind
  var lambda: Double
  var e0: Double
  var theta: Double
  var delta: Double
  var phi: Double
  var cycles: Double
  var temperature: Double

  init(
    enabled: Bool = true, kind: Kind = .plane, lambda: Double = 550e-9, e0: Double = 1000, theta: Double = 90,
    delta: Double = 0, phi: Double = 0, cycles: Double = 3, temperature: Double = 5772
  ) {
    self.enabled = enabled
    self.kind = kind
    self.lambda = lambda
    self.e0 = e0
    self.theta = theta
    self.delta = delta
    self.phi = phi
    self.cycles = cycles
    self.temperature = temperature
  }

  enum CodingKeys: String, CodingKey {
    case enabled, kind, lambda, e0 = "E0", theta, delta, phi, cycles, temperature
  }

  /// Decodes a full or partial source; missing or mistyped fields keep the defaults.
  init(from decoder: any Decoder) throws {
    self.init()
    try merge(from: decoder)
  }

  /// Overwrites the fields present in `decoder` (JS `{ ...base, ...partial }`).
  mutating func merge(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? { try? c.decodeIfPresent(type, forKey: key) }
    if let v = value(.enabled, Bool.self) { enabled = v }
    if let v = value(.kind, Kind.self) { kind = v }
    if let v = value(.lambda, Double.self) { lambda = v }
    if let v = value(.e0, Double.self) { e0 = v }
    if let v = value(.theta, Double.self) { theta = v }
    if let v = value(.delta, Double.self) { delta = v }
    if let v = value(.phi, Double.self) { phi = v }
    if let v = value(.cycles, Double.self) { cycles = v }
    if let v = value(.temperature, Double.self) { temperature = v }
  }

  /// Clamps and wraps every field into its legal range (JS `sanitize`):
  /// λ → 10^clamp(log₁₀ λ, range) (so λ drifts by a few ulp, as in JS), E₀ to [1e-6, 1e16],
  /// θ to [−90, 90], δ wrapped to [−180, 180) (+180 maps to −180), φ wrapped to [0, 360),
  /// cycles to [1, 12], T to [1, 1e8]; a thermal source's λ becomes its Wien peak.
  ///
  /// `logRange` defaults to the web prototype's `Spectrum.logRange`; pass
  /// `Spectrum.rulerLogRange` to allow wavelengths up to 100,000 km.
  ///
  /// Intentional divergence from JS (port-plan §7 Q8): a NaN field (only reachable through
  /// corrupted storage) resets to its default instead of staying NaN.
  mutating func sanitize(logRange: ClosedRange<Double> = Spectrum.logRange) {
    let d = WaveSource()
    var lg = log10(lambda)
    if lg.isNaN { lg = log10(d.lambda) }
    lambda = pow(10, JSMath.clamp(lg, logRange.lowerBound, logRange.upperBound))
    e0 = JSMath.clamp(e0.isNaN ? d.e0 : e0, 1e-6, 1e16)
    theta = JSMath.clamp(theta.isNaN ? d.theta : theta, -90, 90)
    let wrappedDelta = (((delta + 180).truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) - 180
    delta = wrappedDelta.isNaN ? d.delta : wrappedDelta
    let wrappedPhi = ((phi.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
    phi = wrappedPhi.isNaN ? d.phi : wrappedPhi
    cycles = JSMath.clamp(cycles.isNaN ? d.cycles : cycles, 1, 12)
    temperature = JSMath.clamp(temperature.isNaN ? d.temperature : temperature, 1, 1e8)
    if kind == .thermal { lambda = Wave.wienPeak(temperature) }
  }

  /// A sanitized copy.
  func sanitized(logRange: ClosedRange<Double> = Spectrum.logRange) -> WaveSource {
    var s = self
    s.sanitize(logRange: logRange)
    return s
  }
}

/// Plane electromagnetic waves: fields, polarization, superposition, blackbody sources and a
/// test charge (port of spectra-lab `core/wave.js`). Angles in the public API are degrees
/// unless a name says otherwise.
nonisolated enum Wave {
  /// 2π, written as the JS `2 * Math.PI` (bit-identical).
  static let tau: Double = 2 * Double.pi

  /// Degrees to radians, `(deg * π) / 180` (keep this operand order for parity).
  static func rad(_ deg: Double) -> Double { (deg * Double.pi) / 180 }

  // MARK: Polarization

  /// Unit Jones amplitudes and the relative phase δ (radians).
  struct Jones: Hashable, Sendable {
    var ax: Double
    var ay: Double
    var delta: Double
  }

  static func jones(_ s: WaveSource) -> Jones {
    let psi = rad(s.theta), d = rad(s.delta)
    return Jones(ax: cos(psi), ay: sin(psi), delta: d)
  }

  /// Unit-amplitude fields at one phase. B is returned divided by c/n ("E units"):
  /// B_SI = (n/c)·B.
  struct FieldSample: Hashable, Sendable {
    var ex: Double
    var ey: Double
    var bx: Double
    var by: Double
  }

  /// Real fields at phase q = kz − ωt + φ (JS `fieldsAtPhase`).
  static func fields(_ s: WaveSource, phase q: Double) -> FieldSample {
    let j = jones(s)
    let ex = j.ax * cos(q), ey = j.ay * cos(q + j.delta)
    return FieldSample(ex: ex, ey: ey, bx: -ey, by: ex)
  }

  /// q = kz − ωt + φ with k = 2πn/λ and ω = 2πc/λ (JS `phaseAt`).
  static func phase(_ s: WaveSource, z: Double, t: Double, n: Double = 1) -> Double {
    let k = (tau * n) / s.lambda, w = (tau * SI.c) / s.lambda
    return k * z - w * t + rad(s.phi)
  }

  // MARK: Intensity

  /// Time-averaged intensity ½·n·c·ε₀·E₀² in a medium of real index n, W/m².
  static func intensity(e0: Double, n: Double = 1) -> Double { 0.5 * n * SI.c * SI.eps0 * e0 * e0 }
  /// Peak magnetic field n·E₀/c, T.
  static func peakB(e0: Double, n: Double = 1) -> Double { (n * e0) / SI.c }
  /// Radiation pressure I/c (absorbing) or 2I/c (reflecting), Pa.
  static func radiationPressure(e0: Double, n: Double = 1, reflect: Bool = false) -> Double {
    ((reflect ? 2 : 1) * intensity(e0: e0, n: n)) / SI.c
  }
  /// Photon flux I/(hc/λ), photons/m²/s.
  static func photonFlux(e0: Double, lambda: Double, n: Double = 1) -> Double {
    intensity(e0: e0, n: n) / ((SI.h * SI.c) / lambda)
  }

  /// Polarization ellipse of a Jones vector (Born & Wolf §1.4).
  struct Ellipse: Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case linear, circular, elliptical }
    enum Sense: String, Codable, Sendable {
      case counterClockwise = "counter-clockwise"
      case clockwise
    }
    /// Orientation of the major axis, degrees. Numerical noise for circular light: show "—".
    var orientation: Double
    /// Ellipticity angle χ, degrees: 0 linear, ±45 circular.
    var chi: Double
    var kind: Kind
    /// nil for linear light.
    var sense: Sense?
  }

  static func ellipse(_ s: WaveSource) -> Ellipse {
    let j = jones(s)
    let orientation = 0.5 * atan2(2 * j.ax * j.ay * cos(j.delta), j.ax * j.ax - j.ay * j.ay)
    let sin2chi = JSMath.max(-1, JSMath.min(1, 2 * j.ax * j.ay * sin(j.delta)))
    let chi = 0.5 * asin(sin2chi)
    let kind: Ellipse.Kind =
      abs(sin2chi) < 1e-9 ? .linear : abs(abs(sin2chi) - 1) < 1e-6 ? .circular : .elliptical
    // With Ey = cos(q + δ) and q = kz − ωt, sin δ > 0 rotates x → y at a fixed point in time order.
    let sense: Ellipse.Sense? = kind == .linear ? nil : sin2chi > 0 ? .counterClockwise : .clockwise
    return Ellipse(orientation: (orientation * 180) / Double.pi, chi: (chi * 180) / Double.pi, kind: kind, sense: sense)
  }

  /// Fraction of intensity an ideal linear polarizer at `alphaDeg` passes.
  static func polarizerTransmission(_ s: WaveSource, alphaDeg: Double) -> Double {
    let j = jones(s)
    let a = rad(alphaDeg), c = cos(a), sn = sin(a)
    return j.ax * j.ax * c * c + j.ay * j.ay * sn * sn + 2 * j.ax * j.ay * c * sn * cos(j.delta)
  }

  // MARK: Pulses and thermal light

  /// Gaussian field envelope with `cycles` carrier periods at intensity FWHM (the intensity
  /// envelope is its square).
  static func pulseEnvelope(_ s: WaveSource, phase q: Double) -> Double {
    let fwhmPhase = tau * s.cycles
    let sigma = fwhmPhase / (2 * (2 * log(2.0)).squareRoot())
    return exp(-(q * q) / (4 * sigma * sigma))
  }

  /// Δf/f of a transform-limited Gaussian pulse, 2 ln 2 / (π·cycles).
  static func pulseBandwidth(_ s: WaveSource) -> Double { (2 * log(2.0)) / (Double.pi * s.cycles) }

  /// Planck spectral radiance per unit wavelength, W/(m²·sr·m); exactly 0 when hc/λkT > 700.
  static func planckLambda(_ lambda: Double, temperature t: Double) -> Double {
    let a = (2 * SI.h * SI.c * SI.c) / pow(lambda, 5)
    let x = (SI.h * SI.c) / (lambda * SI.kB * t)
    return x > 700 ? 0 : a / expm1(x)
  }

  /// Wien peak b/T, m.
  static func wienPeak(_ t: Double) -> Double { SI.wienB / t }

  /// One discrete frequency component; `amp` is relative to the source's E₀, `phase` radians.
  struct Component: Hashable, Sendable {
    var lambda: Double
    var amp: Double
    var phase: Double
  }

  /// Discrete components for superposition and the Fourier view (JS `components`).
  /// Plane: one line. Pulse: `count` lines across ±2.2σ_f, L1-normalized. Thermal: `count`
  /// lines on a log grid around the Wien peak (src.lambda ignored), amplitude ∝ √(B_λ·λ)
  /// L2-normalized, phases from a fresh LCG seeded 12345 on every call. `count` < 3 → 3.
  static func components(_ s: WaveSource, count requested: Int = 15) -> [Component] {
    let count = max(3, requested)
    switch s.kind {
    case .plane:
      return [Component(lambda: s.lambda, amp: 1, phase: rad(s.phi))]
    case .pulse:
      let f0 = SI.c / s.lambda, df = pulseBandwidth(s) * f0
      let sigmaF = df / (2 * (2 * log(2.0)).squareRoot())
      var out: [Component] = []
      out.reserveCapacity(count)
      for i in 0..<count {
        let u = (Double(i) / Double(count - 1)) * 2 - 1
        let f = f0 + 2.2 * sigmaF * u
        let d = f - f0
        out.append(Component(lambda: SI.c / f, amp: exp(-(d * d) / (4 * sigmaF * sigmaF)), phase: rad(s.phi)))
      }
      var sum = 0.0
      for c in out { sum = sum + c.amp }
      for i in out.indices { out[i].amp /= sum }
      return out
    case .thermal:
      let peak = wienPeak(s.temperature)
      var rng: UInt32 = 12345
      var out: [Component] = []
      out.reserveCapacity(count)
      for i in 0..<count {
        let lambda = peak * pow(10, -0.6 + (1.6 * Double(i)) / Double(count - 1))
        let p = planckLambda(lambda, temperature: s.temperature) * lambda  // power per log-λ bin
        rng = rng &* 1_664_525 &+ 1_013_904_223
        out.append(Component(lambda: lambda, amp: p.squareRoot(), phase: tau * (Double(rng) / 4_294_967_296)))
      }
      var sum = 0.0
      for c in out { sum = sum + c.amp * c.amp }
      let norm = sum.squareRoot()
      for i in out.indices { out[i].amp /= norm }
      return out
    }
  }

  // MARK: Strong fields and a free electron

  /// Normalized laser strength a₀ = eE₀/(m_e·ω·c); above ~1 the v×B push rivals the E shake.
  static func a0(e0: Double, lambda: Double) -> Double { (SI.e * e0) / (SI.me * ((tau * SI.c) / lambda) * SI.c) }
  /// E₀ for a given a₀, V/m.
  static func fieldForA0(_ a: Double, lambda: Double) -> Double { (a * SI.me * ((tau * SI.c) / lambda) * SI.c) / SI.e }
  /// Peak quiver amplitude of a free electron (non-relativistic), m.
  static func quiverAmplitude(e0: Double, lambda: Double) -> Double {
    let w = (tau * SI.c) / lambda
    return (SI.e * e0) / (SI.me * (w * w))
  }
  /// Average forward drift speed (fraction of c) in a linearly polarized wave, a²/(4 + a²).
  static func driftSpeed(_ a: Double) -> Double { (a * a) / (4 + a * a) }

  /// Which forces act on the probe charge.
  enum ProbeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// E and v×B.
    case both
    /// E only (drop v×B).
    case electric
    /// v×B only: nothing moves from rest.
    case magnetic
    var id: String { rawValue }
  }

  /// One sample of the exact trajectory. Coordinates in units of c/ω, time in 1/ω.
  struct TrajectoryPoint: Hashable, Sendable {
    var eta: Double
    var t: Double
    var x: Double
    var y: Double
    var z: Double
    var ux: Double
    var uy: Double
    var uz: Double
    var gamma: Double
  }

  /// Exact trajectory of an electron, initially at rest, in a vacuum plane wave of strength a.
  /// Light-front phase η = ωt − kz; canonical momentum gives u⊥ = A(η) − A(0) and, with the
  /// magnetic force, γ − u_z = 1 so u_z = |u⊥|²/2. Midpoint rule in η; returns steps + 1 points
  /// (none for a negative `steps`, as in JS, where the loop never runs).
  static func electronTrajectory(
    _ s: WaveSource, a: Double, mode: ProbeMode = .both, cycles: Double = 2, steps: Int = 720
  ) -> [TrajectoryPoint] {
    guard steps >= 0 else { return [] }  // `0...steps` would trap
    let j = jones(s)
    func vectorPotential(_ eta: Double) -> (Double, Double) { (a * j.ax * sin(eta), a * j.ay * sin(eta + j.delta)) }
    let a0v = vectorPotential(0)
    var pts: [TrajectoryPoint] = []
    pts.reserveCapacity(steps + 1)
    var x = 0.0, y = 0.0, z = 0.0, t = 0.0
    let dEta = (tau * cycles) / Double(steps)
    for i in 0...steps {
      let eta = Double(i) * dEta
      var ux = 0.0, uy = 0.0, uz = 0.0
      if mode != .magnetic {
        let ae = vectorPotential(eta)
        ux = ae.0 - a0v.0
        uy = ae.1 - a0v.1
        if mode == .both { uz = (ux * ux + uy * uy) / 2 }
      }
      let gamma = mode == .both ? 1 + uz : (1 + ux * ux + uy * uy).squareRoot()
      pts.append(TrajectoryPoint(eta: eta, t: t, x: x, y: y, z: z, ux: ux, uy: uy, uz: uz, gamma: gamma))
      // dη/dt = ω(γ − u_z)/γ; integrate dx/dη = u/(γ − u_z) with the midpoint rule.
      let etaM = eta + dEta / 2
      var mx = 0.0, my = 0.0, mz = 0.0, mg = 1.0
      if mode != .magnetic {
        let am = vectorPotential(etaM)
        mx = am.0 - a0v.0
        my = am.1 - a0v.1
        if mode == .both { mz = (mx * mx + my * my) / 2 }
        mg = mode == .both ? 1 + mz : (1 + mx * mx + my * my).squareRoot()
      }
      let md = mg - mz
      x += (mx / md) * dEta
      y += (my / md) * dEta
      z += (mz / md) * dEta
      t += (mg / md) * dEta
    }
    return pts
  }
}
