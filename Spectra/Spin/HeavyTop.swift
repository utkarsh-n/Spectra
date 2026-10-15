import Foundation
import simd

/// Everything the gyroscope knobs control (Gyre's `GyroParams`). Values are in the units the
/// knobs show. `magnet` is signed: + puts the moment along the spin (proton-like), − against
/// it (electron-like), so the rotor can precess either way about B.
nonisolated struct HeavyTopParams: Sendable, Hashable, Codable {
  /// Target spin (rpm); 0 = motor off, rotor coasts.
  var motorRPM = 3000.0
  /// × moment of inertia of a 6 cm brass disc.
  var inertia = 1.0
  /// Local gravity in g (negative = inverted).
  var gravity = 1.0
  /// Rotor position on the axle, −1…1 of 3.5 cm.
  var balance = 0.5
  /// Pivot and bearing friction, 0…1.
  var friction = 0.25
  /// Air density × sea level (the effective density also scales with the barometer).
  var air = 1.0
  /// Rotor magnetization, −1…1 of `HeavyTop.maxDipole`.
  var magnet = 0.0
  /// Simulation speed D (simulated seconds per wall second).
  var timeScale = 1.0

  /// "Real NdFeB" detent: a solid NdFeB rotor of the same 60 g, μ = 8.276 A·m², i.e. 0.138 of
  /// Gyre's 60 A·m² fantasy magnet (`gyre-integration.md` §1).
  static let realNdFeBMagnet = HeavyTop.ndfebDipole() / HeavyTop.maxDipole
  /// "Electron-like" detent: moment against the spin.
  static let electronLikeMagnet = -1.0

  /// Fastest simulation speed D the integrator accepts (5× the Time knob's 2×). Each wall frame
  /// (≤ 0.05 s) then covers at most 0.5 simulated seconds: ≤ 480 tip samples and a bounded RK4
  /// substep size. An unbounded D (a mis-wired κ) used to append 960·D·0.05 tip samples per
  /// frame: 2.5 GB and 2 s of work at D = 10⁷.
  static let maxTimeScale = 10.0

  /// The knobs as the integrator uses them: every non-finite value replaced by its default,
  /// the inertia kept in 0.01…100 × and the time scale at most `maxTimeScale`, so a NaN, a zero
  /// or a runaway value from a modulation source can never reach (and trap or stall) the
  /// integrator. Finite in-range knobs pass through unchanged.
  var sanitized: HeavyTopParams {
    let d = HeavyTopParams()
    var p = self
    p.motorRPM = motorRPM.isFinite ? motorRPM : d.motorRPM
    p.inertia = inertia.isFinite ? SpinMath.clamp(inertia, 0.01, 100) : d.inertia
    p.gravity = gravity.isFinite ? gravity : d.gravity
    p.balance = balance.isFinite ? balance : d.balance
    p.friction = friction.isFinite ? friction : d.friction
    p.air = air.isFinite ? air : d.air
    p.magnet = magnet.isFinite ? magnet : d.magnet
    p.timeScale = timeScale.isFinite ? min(timeScale, Self.maxTimeScale) : d.timeScale
    return p
  }
}

/// Sensor-derived surroundings for one step, in the world frame (Z up).
nonisolated struct HeavyTopEnvironment: Sendable, Hashable {
  /// Phone's angular velocity, rad/s (real time).
  var deviceRate = SIMD3<Double>.zero
  /// Phone's acceleration minus gravity, m/s².
  var linearAccel = SIMD3<Double>.zero
  /// Magnetic field, tesla (live magnetometer, a knob, or B₀ + B₁(t) for resonance).
  var magneticField = SIMD3<Double>.zero
  /// Ambient pressure / 101.325 kPa (barometer). Multiplies `HeavyTopParams.air`.
  var pressureFactor = 1.0
  /// Extra torque, N·m (e.g. sound pushing the rotor, the modulation matrix).
  var extraTorque = SIMD3<Double>.zero

  /// The surroundings with any non-finite vector zeroed and a non-finite pressure factor set
  /// to 1 (one bad sensor sample must not poison the rotor).
  var sanitized: HeavyTopEnvironment {
    func clean(_ v: SIMD3<Double>) -> SIMD3<Double> { v.x.isFinite && v.y.isFinite && v.z.isFinite ? v : .zero }
    return HeavyTopEnvironment(
      deviceRate: clean(deviceRate), linearAccel: clean(linearAccel), magneticField: clean(magneticField),
      pressureFactor: pressureFactor.isFinite ? pressureFactor : 1, extraTorque: clean(extraTorque))
  }
}

/// A 10 Hz snapshot of the rotor for readouts, haptics and Patch control outputs
/// (`gyre-integration.md` §4.8: spin, precession, nod, strain, L, τ). Rates are in simulated
/// time; multiply by the time scale D for what a viewer sees.
nonisolated struct HeavyTopTelemetry: Sendable, Hashable {
  var rpm: Double
  /// Azimuthal precession rate about world vertical, rad/s (smoothed, simulated time).
  var precessionRate: Double
  /// Inertial nod rate at the current tilt, including gravity and the field
  /// (`HeavyTop.nodRate`), rad/s. "Inertial nod", never "Rabi nutation".
  var nutationRate: Double
  /// The torque-free nod rate L₃/I₁, rad/s.
  var freeNutationRate: Double
  /// |L|, J·s.
  var angularMomentum: Double
  /// L in world axes, J·s.
  var momentum: SIMD3<Double>
  /// |τ| of gravity + magnet, N·m.
  var torque: Double
  /// τ of gravity + magnet in world axes, N·m.
  var torqueVector: SIMD3<Double>
  /// |ω_phone × L|, N·m: the gyroscopic reaction you feel.
  var strain: Double
  /// Axis angle from world up, rad.
  var tilt: Double
  /// The rotor's mechanical gyromagnetic ratio μ/L₃, rad s⁻¹ T⁻¹ (0 without a magnet).
  var rotorGamma: Double

  var precessionHz: Double { precessionRate / (2 * .pi) }
  var nutationHz: Double { nutationRate / (2 * .pi) }
}

/// A symmetric heavy top on a frictional ball pivot fixed to the phone: Gyre's `GyroSim`,
/// ported to a value type with a signed magnet and a 960 Hz axle-tip output.
///
/// The spin axis `axis` and angular momentum `momentum` live in the world frame, so the
/// rotor keeps its orientation in space while the phone turns around it. Torques: gravity and
/// the phone's own acceleration on the offset centre of mass, the magnetic dipole μ × B, the
/// spin motor, pivot friction relative to the phone, and air drag relative to the air in the
/// bubble. RK4 with substeps that resolve the fastest motion present (nutation, swing,
/// magnetic oscillation, friction relaxation).
nonisolated struct HeavyTop: Sendable {
  static let mass = 0.06  // kg
  static let rotorRadius = 0.03  // m
  static let maxOffset = 0.035  // m, balance = ±1
  static let cageInertia = 2.5e-6  // kg·m², cage and axle about a transverse axis
  static let g0 = SpinConstants.standardGravity
  static let maxDipole = 60.0  // A·m² at magnet = 1 (a fantasy magnet; Earth's field then matters)
  static let motorGain = 2e-4  // N·m·s
  static let motorTorque = 2.5e-3  // N·m
  static let swivelFriction = 6e-5  // N·m·s at friction = 1
  static let spinFriction = 1.2e-6  // N·m·s at friction = 1
  static let airLinear = 1.5e-7  // N·m·s, spin drag
  static let airQuadratic = 6e-9  // N·m·s², spin drag
  static let airTransverse = 2e-6  // N·m·s, drag on swinging and precession
  /// Axle-tip IQ output rate, samples per *simulated* second: Nyquist 480 Hz covers the
  /// 376.7 Hz worst-case nod in simulated time at any Time knob setting (sampling on the
  /// wall clock would alias above D = 1.27; corrected in review).
  static let tipSampleRate = 960.0
  /// Tip samples kept when nobody drains them (4 s).
  static let tipCapacity = 3840

  /// Dipole of a solid NdFeB rotor, μ = (Bᵣ/μ₀)·(m/ρ). 1.3 T, 60 g, 7500 kg/m³: 8.276 A·m².
  static func ndfebDipole(remanence: Double = 1.3, mass: Double = HeavyTop.mass, density: Double = 7500) -> Double {
    remanence / SpinConstants.mu0 * (mass / density)
  }

  static func transverseInertia(scale: Double, offset: Double) -> Double {
    scale * 0.25 * mass * rotorRadius * rotorRadius + cageInertia + mass * offset * offset
  }

  // MARK: State

  private(set) var axis = SIMD3<Double>(0, 0, 1)
  private(set) var momentum = SIMD3<Double>.zero
  /// A cage direction perpendicular to the axis, parallel-transported (it never twists
  /// about the axis), so the cage doesn't spin and the rotor spins inside it.
  private(set) var cageX = SIMD3<Double>(1, 0, 0)
  private(set) var spinAngle = 0.0
  /// Rotor angle swept during the last step; drives the motion blur.
  private(set) var spinSweep = 0.0
  private(set) var offset = 0.5 * maxOffset
  private(set) var inertiaScale = 1.0
  /// Angular velocity of the air inside the bubble (it lags the phone).
  private(set) var airRate = SIMD3<Double>.zero
  private(set) var externalTorque = SIMD3<Double>.zero
  private(set) var effectiveGravity = SIMD3<Double>(0, 0, -g0)
  /// Azimuthal rate of the axis about world vertical, rad/s of simulated time, smoothed.
  private(set) var precessionRate = 0.0
  /// How fast the axis direction itself is moving, rad/s of simulated time.
  private(set) var axisSpeed = 0.0
  /// The rotor's dipole moment along the axis (A·m², signed) at the last step.
  private(set) var dipole = 0.0
  /// Simulated time (s).
  private(set) var time = 0.0
  /// Substeps used by the last step.
  private(set) var lastSubsteps = 0
  private var lastAzimuth: Double?
  private var lastDeviceRate = SIMD3<Double>.zero
  private var lastField = SIMD3<Double>.zero
  var paused = false

  /// Axle-tip samples eₓ + ie_y (world axes) at 960 per simulated second, waiting to be
  /// drained (at most `tipCapacity` are kept; the oldest go first). Sample number n (0-based,
  /// counted since `launch`) sits at simulated time (n + 1)/960 s.
  private(set) var tipSamples: [SIMD2<Double>] = []
  /// Total tip samples produced since `launch`, including any dropped.
  private(set) var tipSampleCount = 0
  /// Whether `step` produces tip samples.
  var tipOutputEnabled = true
  /// Simulated seconds since the last tip sample.
  private var tipPhase = 0.0

  init() {}

  // MARK: Derived

  var I3: Double { inertiaScale * 0.5 * Self.mass * Self.rotorRadius * Self.rotorRadius }
  var I1: Double { Self.transverseInertia(scale: inertiaScale, offset: offset) }
  /// Spin about the axis, rad/s.
  var spinRate: Double { simd_dot(momentum, axis) / I3 }
  var rpm: Double { spinRate * 60 / (2 * .pi) }
  /// Angle between the spin axis and world up.
  var tilt: Double { acos(SpinMath.clamp(axis.z, -1, 1)) }
  var angularVelocity: SIMD3<Double> {
    let l3 = simd_dot(momentum, axis)
    return (momentum - l3 * axis) / I1 + (l3 / I3) * axis
  }
  /// L₃ = L·ê, J·s.
  var spinMomentum: Double { simd_dot(momentum, axis) }
  /// Torque-free inertial nod rate ω_n = L₃/I₁ (rad/s): 3000 rpm with ℓ = 1.75 cm gives
  /// 246.76 rad/s. A quantum spin has no transverse inertia and no such nod; NMR's
  /// "nutation" is Rabi.
  var nutationRate: Double { abs(spinMomentum) / I1 }

  /// The nod rate at the current tilt with the restoring or overturning torques:
  /// ω_n = cos θ·(Ω₊ − Ω₋) = √((L₃/I₁)² − 4(mgℓ cos θ_g − μB cos θ_B)/I₁), θ_g from "up"
  /// (against effective gravity) and θ_B from B. Exact with one field; with both it adds
  /// the two stiffnesses. 3000 rpm, ℓ 1.75 cm, 1 g, tilt 0.3: 244.43 rad/s; 1500 rpm,
  /// balanced, magnet 1 in 50 µT: ≈ 42.4 Hz (corrected in review).
  func nodRate(field: SIMD3<Double> = .zero, magnet: Double = 0) -> Double {
    let l3 = abs(spinMomentum)
    let g = simd_length(effectiveGravity)
    let cosG = g > 0 ? simd_dot(axis, -effectiveGravity / g) : 0
    let mu = SpinMath.clamp(magnet, -1, 1) * Self.maxDipole
    let muB = mu * simd_dot(axis, field)  // μB cos θ_B
    let w2 = (l3 / I1) * (l3 / I1) - 4 * (Self.mass * g * offset * cosG - muB) / I1
    return w2 > 0 ? w2.squareRoot() : 0
  }

  /// Fast-top precession m g ℓ / L₃ (rad/s) under `gravity` g.
  /// 3000 rpm, ℓ = 1.75 cm, 1 g: 1.2139 rad/s.
  func fastTopPrecession(gravity: Double = 1) -> Double {
    let l3 = spinMomentum
    return abs(l3) > 0 ? Self.mass * Self.g0 * gravity * offset / l3 : 0
  }

  /// Steady precession Ω_p, the slow root of I₁ cos θ Ω² − L₃ Ω + mgℓ = 0 at `tilt`
  /// (falls back to the fast-top value near θ = 90° or past the sleeping limit).
  /// 3000 rpm, ℓ = 1.75 cm, tilt 0.3: 1.2197 rad/s.
  static func steadyPrecession(spinMomentum l3: Double, transverseInertia i1: Double, offset: Double, gravity: Double, tilt: Double) -> Double {
    let mgl = mass * g0 * gravity * offset
    var omega = mgl / max(abs(l3), 1e-9)
    let cosT = cos(tilt)
    if abs(cosT) > 1e-3 {
      let disc = l3 * l3 - 4 * i1 * cosT * mgl
      if disc > 0 { omega = (l3 - disc.squareRoot()) / (2 * i1 * cosT) }
    }
    return omega
  }
  /// The rotor's gyromagnetic ratio γ_rotor = μ/L₃ (rad s⁻¹ T⁻¹) for magnet setting `magnet`.
  /// 1500 rpm, magnet 1: 14 147 rad s⁻¹ T⁻¹.
  func rotorGamma(magnet: Double) -> Double {
    let l3 = spinMomentum
    return abs(l3) > 0 ? magnet * Self.maxDipole / l3 : 0
  }
  /// Larmor precession angular velocity about B (rad/s, signed along B: −γ_rotor|B|).
  /// 1500 rpm, magnet 1, 50 µT: −0.7074 rad/s (period 8.88 s).
  func larmorRate(magnet: Double, field: Double) -> Double { -rotorGamma(magnet: magnet) * field }

  /// Kinetic + gravitational potential energy, for checking the integrator (Gyre's
  /// definition; add `magneticEnergy` when a field acts).
  var energy: Double {
    let l3 = simd_dot(momentum, axis)
    let lp = momentum - l3 * axis
    return simd_length_squared(lp) / (2 * I1) + l3 * l3 / (2 * I3)
      - Self.mass * simd_dot(offset * axis, effectiveGravity)
  }

  /// Magnetic potential energy −μ·B of the rotor's dipole in `field` (J).
  func magneticEnergy(field: SIMD3<Double>) -> Double { -dipole * simd_dot(axis, field) }

  /// The axle tip eₓ + ie_y right now.
  var tip: SIMD2<Double> { SIMD2(axis.x, axis.y) }

  /// A snapshot for readouts and control outputs.
  var telemetry: HeavyTopTelemetry {
    HeavyTopTelemetry(
      rpm: rpm, precessionRate: precessionRate,
      nutationRate: nodRate(field: lastField, magnet: dipole / Self.maxDipole),
      freeNutationRate: nutationRate,
      angularMomentum: simd_length(momentum), momentum: momentum,
      torque: simd_length(externalTorque), torqueVector: externalTorque,
      strain: simd_length(simd_cross(lastDeviceRate, momentum)), tilt: tilt,
      rotorGamma: abs(spinMomentum) > 0 ? dipole / spinMomentum : 0)
  }

  /// Takes the pending axle-tip samples (960 Hz), oldest first.
  mutating func drainTip() -> [SIMD2<Double>] {
    let out = tipSamples
    tipSamples.removeAll(keepingCapacity: true)
    return out
  }

  // MARK: Stepping

  private struct Context {
    var I1: Double
    var I3: Double
    var offset: Double
    var gravity: SIMD3<Double>
    var dipole: Double
    var field: SIMD3<Double>
    var motorOn: Bool
    var motorTarget: Double
    var swivel: Double
    var spin: Double
    var deviceRate: SIMD3<Double>
    var airRate: SIMD3<Double>
    var rho: Double
    var extra: SIMD3<Double>
  }

  /// Advances by `rawDt` wall seconds (clamped to 0.05 s); simulated time advances by
  /// rawDt × timeScale. Non-finite knobs or sensor values are replaced (`sanitized`), and a
  /// step that would leave the state non-finite is discarded, so the rotor can never trap
  /// or freeze as NaN.
  mutating func step(dtReal rawDt: Double, env rawEnv: HeavyTopEnvironment, params rawParams: HeavyTopParams) {
    let p = rawParams.sanitized
    let env = rawEnv.sanitized
    recoverIfNonFinite()
    let dtReal = SpinMath.clamp(rawDt.isFinite ? rawDt : 0, 0, 0.05)
    // Knob changes ease in so the rotor never teleports. Changing inertia keeps angular
    // momentum: spin slows as inertia grows, like a skater's arms.
    offset += (SpinMath.clamp(p.balance, -1, 1) * Self.maxOffset - offset) * (1 - exp(-dtReal / 0.25))
    inertiaScale += (p.inertia - inertiaScale) * (1 - exp(-dtReal / 0.3))
    airRate += (env.deviceRate - airRate) * (1 - exp(-dtReal / 0.9))
    effectiveGravity = SIMD3(0, 0, -Self.g0 * p.gravity) - env.linearAccel
    lastDeviceRate = env.deviceRate
    lastField = env.magneticField
    spinSweep = 0

    let scale = max(p.timeScale, 0.02)
    let w3 = spinRate
    let fric = p.friction * p.friction
    dipole = SpinMath.clamp(p.magnet, -1, 1) * Self.maxDipole
    let c = Context(
      I1: I1, I3: I3, offset: offset, gravity: effectiveGravity,
      dipole: dipole, field: env.magneticField,
      motorOn: p.motorRPM > 1, motorTarget: (w3 < -5 ? -1 : 1) * p.motorRPM * 2 * .pi / 60,
      swivel: Self.swivelFriction * fric, spin: Self.spinFriction * fric,
      // In slow motion the phone turns faster relative to the rotor's clock.
      deviceRate: env.deviceRate / scale, airRate: airRate / scale,
      rho: max(p.air, 0) * max(env.pressureFactor, 0), extra: env.extraTorque)
    externalTorque = torque(axis: axis, c)

    guard !paused, dtReal > 0 else {
      // Simulated time stands still, so the tip stream (sampled in simulated time) does too.
      axisSpeed = 0
      lastSubsteps = 0
      return
    }
    let dt = dtReal * scale

    // Substeps resolve the fastest motion present: nutation (≈ L₃/I₁ for a fast top),
    // pendulum swing, magnetic oscillation, or friction relaxation.
    let l3 = abs(simd_dot(momentum, axis))
    var fastest = l3 / c.I1
    fastest = max(fastest, sqrt(Self.mass * simd_length(c.gravity) * abs(c.offset) / c.I1))
    fastest = max(fastest, sqrt(abs(c.dipole) * simd_length(c.field) / c.I1))
    fastest = max(fastest, (c.swivel + c.rho * Self.airTransverse) / c.I1)
    fastest = max(fastest, simd_length(angularVelocity - simd_dot(angularVelocity, axis) * axis))
    // The spin motor relaxes ω₃ at motorGain/I₃ (7.4 s⁻¹ at 1×, but 740 s⁻¹ at 0.01×): resolve
    // it too, or RK4 goes unstable on a very light rotor (not in Gyre, where Inertia ≥ 0.25).
    if c.motorOn { fastest = max(fastest, Self.motorGain / c.I3) }
    let wanted = (dt * fastest / 0.1).rounded(.up)
    let n = wanted.isFinite ? Int(SpinMath.clamp(wanted, 1, 2000)) : 2000
    let h = dt / Double(n)
    let saved = (axis, momentum, cageX, spinAngle, tipPhase, tipSamples.count, tipSampleCount)

    for _ in 0..<n {
      let before = axis
      rk4(h, c)
      let t = cageX - simd_dot(cageX, axis) * axis
      cageX = simd_length(t) > 1e-6 ? simd_normalize(t) : SpinMath.perpendicular(to: axis)
      let spin = simd_dot(momentum, axis) / c.I3
      spinAngle += spin * h
      spinSweep += spin * h
      if tipOutputEnabled { emitTip(from: before, to: axis, over: h) }
    }
    lastSubsteps = n
    if !Self.isFinite(axis) || !Self.isFinite(momentum) || !spinAngle.isFinite {
      // Diverged (e.g. an absurd finite knob): drop this step instead of keeping NaN.
      (axis, momentum, cageX, spinAngle, tipPhase) = (saved.0, saved.1, saved.2, saved.3, saved.4)
      tipSamples.removeLast(tipSamples.count - saved.5)
      tipSampleCount = saved.6
      spinSweep = 0
      axisSpeed = 0
      lastSubsteps = 0
      return
    }
    if tipSamples.count > Self.tipCapacity { tipSamples.removeFirst(tipSamples.count - Self.tipCapacity) }
    time += dt
    spinAngle = spinAngle.truncatingRemainder(dividingBy: 2 * .pi)
    externalTorque = torque(axis: axis, c)
    axisSpeed = simd_length(simd_cross(angularVelocity, axis))

    let horizontal = hypot(axis.x, axis.y)
    let azimuth = atan2(axis.y, axis.x)
    if let last = lastAzimuth, horizontal > 0.03 {
      let rate = SpinMath.wrapAngle(azimuth - last) / dt
      precessionRate += (rate - precessionRate) * (1 - exp(-dtReal / 0.6))
    } else if horizontal <= 0.03 {
      precessionRate *= exp(-dtReal / 0.6)
    }
    lastAzimuth = azimuth
  }

  private static func isFinite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

  /// Puts a non-finite axis or momentum (from a NaN impulse, say) back to a sane state: axis
  /// up, at rest.
  private mutating func recoverIfNonFinite() {
    if !Self.isFinite(axis) || simd_length_squared(axis) < 0.5 {
      axis = SIMD3(0, 0, 1)
      cageX = SIMD3(1, 0, 0)
    }
    if !Self.isFinite(momentum) { momentum = .zero }
    if !Self.isFinite(cageX) { cageX = SpinMath.perpendicular(to: axis) }
    if !spinAngle.isFinite { spinAngle = 0 }
    if !precessionRate.isFinite { precessionRate = 0 }
  }

  /// Gravity (plus the phone's acceleration) on the offset centre of mass, and the magnetic
  /// dipole in the field. Excludes motor and friction.
  private func torque(axis e: SIMD3<Double>, _ c: Context) -> SIMD3<Double> {
    simd_cross(c.offset * e, Self.mass * c.gravity) + c.dipole * simd_cross(e, c.field)
  }

  private func derivative(_ e: SIMD3<Double>, _ L: SIMD3<Double>, _ c: Context) -> (SIMD3<Double>, SIMD3<Double>) {
    let l3 = simd_dot(L, e)
    let lPerp = L - l3 * e
    let w = lPerp / c.I1 + (l3 / c.I3) * e
    let de = simd_cross(w, e)

    var tau = torque(axis: e, c) + c.extra
    if c.motorOn {
      let w3 = l3 / c.I3
      tau += SpinMath.clamp(Self.motorGain * (c.motorTarget - w3), -Self.motorTorque, Self.motorTorque) * e
    }
    // The pivot is held by the phone, so its friction acts on motion relative to the phone.
    let rel = w - c.deviceRate
    let rel3 = simd_dot(rel, e)
    tau -= c.swivel * (rel - rel3 * e) + c.spin * rel3 * e
    // Air drag acts relative to the air, which itself is dragged around by the bubble.
    let ra = w - c.airRate
    let ra3 = simd_dot(ra, e)
    tau -=
      c.rho
      * ((Self.airLinear + Self.airQuadratic * abs(ra3)) * ra3 * e
        + Self.airTransverse * (ra - ra3 * e))
    return (de, tau)
  }

  private mutating func rk4(_ h: Double, _ c: Context) {
    let e0 = axis
    let l0 = momentum
    let (k1e, k1l) = derivative(e0, l0, c)
    let (k2e, k2l) = derivative(simd_normalize(e0 + 0.5 * h * k1e), l0 + 0.5 * h * k1l, c)
    let (k3e, k3l) = derivative(simd_normalize(e0 + 0.5 * h * k2e), l0 + 0.5 * h * k2l, c)
    let (k4e, k4l) = derivative(simd_normalize(e0 + h * k3e), l0 + h * k3l, c)
    axis = simd_normalize(e0 + h / 6 * (k1e + 2 * k2e + 2 * k3e + k4e))
    momentum = l0 + h / 6 * (k1l + 2 * k2l + 2 * k3l + k4l)
  }

  /// Resamples the axis between two substeps onto the 960 Hz simulated-time grid (linear
  /// interpolation; substeps are ≤ 0.1 rad of the fastest motion, so the error is tiny).
  private mutating func emitTip(from a: SIMD3<Double>, to b: SIMD3<Double>, over h: Double) {
    guard h > 0 else { return }
    let interval = 1 / Self.tipSampleRate
    var t = interval - tipPhase  // from the substep's start to the next sample
    while t <= h {
      let e = a + (b - a) * (t / h)
      tipSamples.append(SIMD2(e.x, e.y))
      tipSampleCount += 1
      t += interval
    }
    tipPhase = h - (t - interval)
  }

  // MARK: Interaction

  /// Places the rotor at `tilt` from vertical, spinning, already in steady precession so it
  /// starts smoothly instead of lurching.
  mutating func launch(params rawParams: HeavyTopParams, tilt rawTilt: Double = 0.32, azimuth rawAzimuth: Double = 0.6, rpm rawRPM: Double? = nil) {
    let p = rawParams.sanitized
    let tilt = rawTilt.isFinite ? rawTilt : 0.32
    let azimuth = rawAzimuth.isFinite ? rawAzimuth : 0.6
    let rpm = rawRPM.flatMap { $0.isFinite ? $0 : nil }
    offset = SpinMath.clamp(p.balance, -1, 1) * Self.maxOffset
    inertiaScale = p.inertia
    let e = SIMD3<Double>(sin(tilt) * cos(azimuth), sin(tilt) * sin(azimuth), cos(tilt))
    axis = e
    let spinRPM = rpm ?? (p.motorRPM > 1 ? p.motorRPM : 3000)
    let l3 = I3 * spinRPM * 2 * .pi / 60
    let cosT = e.z
    let omegaP = Self.steadyPrecession(spinMomentum: l3, transverseInertia: I1, offset: offset, gravity: p.gravity, tilt: tilt)
    momentum = l3 * e + I1 * omegaP * (SIMD3(0, 0, 1) - cosT * e)
    cageX = SpinMath.perpendicular(to: e)
    spinAngle = 0
    precessionRate = omegaP
    lastAzimuth = nil
    dipole = SpinMath.clamp(p.magnet, -1, 1) * Self.maxDipole
    time = 0
    tipPhase = 0
    tipSamples.removeAll(keepingCapacity: true)
    tipSampleCount = 0
  }

  /// Adds angular momentum `dL` (J·s, world axes). Non-finite impulses are ignored.
  mutating func applyImpulse(_ dL: SIMD3<Double>) {
    guard Self.isFinite(dL) else { return }
    momentum += dL
  }

  /// Adds angular momentum along the spin axis (a string pull or a finger on the rim).
  mutating func addSpin(_ dL3: Double) {
    guard dL3.isFinite else { return }
    momentum += dL3 * axis
  }

  /// Knocks the axis sideways (Gyre's `kick`): an impulse perpendicular to the axis at
  /// `angle` around it, sized by |L| (clamp(0.4|L|, 0.0008, 0.0065) J·s) × `strength`.
  mutating func kick(strength: Double, angle: Double) {
    let dir = SpinMath.rotate(SpinMath.perpendicular(to: axis), about: axis, by: angle)
    applyImpulse(dir * strength * SpinMath.clamp(0.4 * simd_length(momentum), 0.0008, 0.0065))
  }
}

/// A rotating field B₀ẑ + B₁(cos(Ωt + φ), sin(Ωt + φ), 0) for classical magnetic resonance
/// with the rotor ("Magnetic resonance with a gyroscope", the Purcell/Feynman demonstration).
nonisolated struct RotorResonanceDrive: Sendable, Hashable, Codable {
  /// Static field along +z (tesla).
  var b0 = 50e-6
  /// Rotating field amplitude (tesla).
  var b1 = 10e-6
  /// Angular velocity of B₁ about +z (rad/s, signed). Resonance: Ω = −γ_rotor B₀.
  var omega: Double
  /// Phase of B₁ at t = 0 (radians).
  var phase = 0.0

  /// The field at simulated time `t`.
  func field(at t: Double) -> SIMD3<Double> {
    let a = omega * t + phase
    return SIMD3(b1 * cos(a), b1 * sin(a), b0)
  }

  /// A drive on resonance with `top` at magnet setting `magnet`: B₁ co-rotates with the
  /// rotor's Larmor precession. 1500 rpm, magnet 1, 50 µT: |Ω| = 0.7074 rad/s.
  static func resonant(with top: HeavyTop, magnet: Double, b0: Double = 50e-6, b1: Double = 10e-6, phase: Double = 0) -> RotorResonanceDrive {
    RotorResonanceDrive(b0: b0, b1: b1, omega: top.larmorRate(magnet: magnet, field: b0), phase: phase)
  }

  /// Time for B₁ to tip the axis by 90°, π/(2γ_rotor B₁). 1500 rpm, 10 µT: 11.10 s.
  static func quarterTurnTime(rotorGamma: Double, b1: Double) -> Double { .pi / (2 * abs(rotorGamma * b1)) }
}

/// A preset tuning of the gyroscope knobs that shows off one behaviour (Gyre's nine
/// experiments plus the Spin field trips that use the rotor).
nonisolated struct HeavyTopPreset: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let subtitle: String
  var params: HeavyTopParams
  var tilt = 0.3
  /// For the resonance trip: a synthetic B₀ + rotating B₁ replaces the live field.
  var resonance: Bool = false

  static let all: [HeavyTopPreset] = {
    let top = HeavyTopParams()

    var free = HeavyTopParams()
    free.balance = 0
    free.motorRPM = 6000
    free.friction = 0.05
    free.air = 0.5

    var moon = HeavyTopParams()
    moon.gravity = 0.166
    moon.balance = 0.8
    moon.motorRPM = 2500

    var jupiter = HeavyTopParams()
    jupiter.gravity = 2.53
    jupiter.balance = 0.6
    jupiter.motorRPM = 3500

    var hanging = HeavyTopParams()
    hanging.balance = -0.7
    hanging.motorRPM = 3000

    var larmor = HeavyTopParams()
    larmor.balance = 0
    larmor.magnet = 1
    larmor.friction = 0.03
    larmor.air = 0
    larmor.motorRPM = 1500

    var slow = HeavyTopParams()
    slow.timeScale = 0.15
    slow.motorRPM = 1800
    slow.friction = 0.05
    slow.air = 0.3
    slow.balance = 0.7

    var windDown = HeavyTopParams()
    windDown.motorRPM = 0
    windDown.air = 2
    windDown.friction = 0.4

    var zeroG = HeavyTopParams()
    zeroG.gravity = 0
    zeroG.motorRPM = 3000

    var ndfeb = larmor
    ndfeb.magnet = HeavyTopParams.realNdFeBMagnet

    var electronLike = larmor
    electronLike.magnet = HeavyTopParams.electronLikeMagnet

    var resonance = HeavyTopParams()
    resonance.balance = 0
    resonance.gravity = 0
    resonance.friction = 0
    resonance.air = 0
    resonance.magnet = 1
    resonance.motorRPM = 1500

    return [
      HeavyTopPreset(id: "top", title: "Spinning top", subtitle: "Precesses around real gravity", params: top),
      HeavyTopPreset(id: "free", title: "Free gyroscope", subtitle: "Turn the phone; the axis stays put in space", params: free, tilt: 0.8),
      HeavyTopPreset(id: "moon", title: "On the Moon", subtitle: "One-sixth gravity, lazy precession", params: moon),
      HeavyTopPreset(id: "jupiter", title: "On Jupiter", subtitle: "2.5 g: fast precession, deep nods", params: jupiter, tilt: 0.6),
      HeavyTopPreset(id: "hanging", title: "Hanging gyro", subtitle: "Below the pivot it precesses backward", params: hanging, tilt: 2.4),
      HeavyTopPreset(id: "larmor", title: "Magnetic compass", subtitle: "Precesses around Earth's field. Try a magnet", params: larmor, tilt: 1.0),
      HeavyTopPreset(id: "slow", title: "Slow motion", subtitle: "Tap the bubble and watch it nod", params: slow, tilt: 0.5),
      HeavyTopPreset(id: "wind", title: "Wind-down", subtitle: "No motor: it slows, wobbles and falls", params: windDown),
      HeavyTopPreset(id: "zero", title: "Zero-g", subtitle: "Only inertia remains", params: zeroG, tilt: 0.7),
      HeavyTopPreset(id: "ndfeb", title: "Real NdFeB rotor", subtitle: "An honest magnet: one turn about B in about a minute", params: ndfeb, tilt: 1.0),
      HeavyTopPreset(id: "electronLike", title: "Electron-like rotor", subtitle: "Moment against the spin: it precesses the other way", params: electronLike, tilt: 1.0),
      HeavyTopPreset(
        id: "resonance", title: "Magnetic resonance with a gyroscope",
        subtitle: "A slowly rotating field tips the axis, as RF tips a proton", params: resonance, tilt: 0.1, resonance: true),
    ]
  }()
}
