import Foundation
import simd

/// A charged species for the Spin bubble's "Charges" layer.
nonisolated enum ChargedSpecies: String, CaseIterable, Codable, Sendable, Hashable {
  case electron
  case proton

  /// Signed charge, C.
  var charge: Double { self == .electron ? -SpinConstants.e : SpinConstants.e }
  /// Mass, kg (CODATA 2022).
  var mass: Double { self == .electron ? SpinConstants.electronMass : SpinConstants.protonMass }
  /// q/m, C/kg.
  var chargeToMass: Double { charge / mass }
  var symbol: String { self == .electron ? "e⁻" : "p⁺" }
  var title: String { self == .electron ? "Electrons" : "Protons" }
}

/// How often a charge collides with the neutral air around it.
nonisolated enum CollisionModel: Sendable, Hashable, Codable {
  /// Electrons in air from the measured momentum-transfer rates for N₂ and O₂ (Schunk &
  /// Nagy, *Ionospheres*, Table 4.6), the review's cross-check. Sea level, Tₑ 300 K:
  /// ν ≈ 1.6 × 10¹¹ s⁻¹, and ω_c = ν near 5.5 Pa in 50 µT (the D layer, ~70 km). For
  /// protons it falls back to a hard sphere of 10⁻¹⁹ m².
  case measuredAir
  /// ν = nσv̄ with an assumed cross-section σ (m²). σ = 10⁻¹⁹ m² is the original
  /// order-of-magnitude estimate [!]: 2.7 × 10¹¹ s⁻¹ at sea level, gyration near 3 Pa.
  case hardSphere(crossSection: Double)
}

/// Gyration of free charges in a magnetic field (`gyre-integration.md` §4.10, §5.4b).
nonisolated enum Gyration {
  /// Mole fractions of N₂ and O₂ in dry air.
  static let nitrogenFraction = 0.7808
  static let oxygenFraction = 0.2095

  /// Cyclotron angular frequency ω_c = |q|B/m (rad/s). Electron, 50 µT: 8.79 × 10⁶ s⁻¹.
  static func cyclotronAngular(_ s: ChargedSpecies, field: Double) -> Double { abs(s.charge) * abs(field) / s.mass }

  /// Cyclotron frequency f_c = |q|B/2πm (Hz). Electron, 50 µT: 1.3996244917 MHz; proton: 762.2 Hz.
  static func cyclotronHz(_ s: ChargedSpecies, field: Double) -> Double { cyclotronAngular(s, field: field) / (2 * .pi) }

  /// Gyration period 2πm/(|q|B) (s). Electron, 50 µT: 0.714477 µs.
  static func period(_ s: ChargedSpecies, field: Double) -> Double { 1 / cyclotronHz(s, field: field) }

  /// Larmor (gyro) radius r = m v⊥/(|q|B) (m). Electron with v⊥ = 9.536 × 10⁴ m/s in 50 µT:
  /// 1.08438 cm.
  static func gyroradius(_ s: ChargedSpecies, perpendicularSpeed v: Double, field: Double) -> Double {
    s.mass * abs(v) / (abs(s.charge) * abs(field))
  }

  /// √(2kT/m) (m/s): the 3D most-probable speed, which as v⊥ is the *RMS* perpendicular
  /// speed (the plasma physicist's v_th). Electron at 300 K: 9.536 × 10⁴ m/s → r 1.08 cm.
  /// Readouts using it say "RMS v⊥" (corrected in review).
  static func perpendicularRMSSpeed(_ s: ChargedSpecies, temperature: Double) -> Double {
    (2 * SpinConstants.kB * temperature / s.mass).squareRoot()
  }

  /// √(kT/m) (m/s): the most probable perpendicular speed of a 2D Maxwellian. Electron at
  /// 300 K: 6.74 × 10⁴ m/s → r 0.77 cm.
  static func perpendicularMostProbableSpeed(_ s: ChargedSpecies, temperature: Double) -> Double {
    (SpinConstants.kB * temperature / s.mass).squareRoot()
  }

  /// Mean thermal speed √(8kT/πm) (m/s). Electron at 300 K: 1.08 × 10⁵ m/s.
  static func meanSpeed(_ s: ChargedSpecies, temperature: Double) -> Double {
    (8 * SpinConstants.kB * temperature / (.pi * s.mass)).squareRoot()
  }

  /// E × B drift velocity E×B/B² (m/s). E = 1 V/m ⊥ 50 µT: 2 × 10⁴ m/s.
  static func driftVelocity(electric e: SIMD3<Double>, magnetic b: SIMD3<Double>) -> SIMD3<Double> {
    let b2 = simd_length_squared(b)
    return b2 > 0 ? simd_cross(e, b) / b2 : .zero
  }

  /// Charge–neutral collision frequency ν (1/s) at `pressure` Pa, neutral number density
  /// n = P/(kT_gas).
  static func collisionFrequency(
    _ s: ChargedSpecies, pressure: Double, model: CollisionModel = .measuredAir,
    gasTemperature: Double = 288.15, particleTemperature: Double = 300
  ) -> Double {
    let n = max(pressure, 0) / (SpinConstants.kB * gasTemperature)
    switch model {
    case .measuredAir where s == .electron:
      // Schunk & Nagy Table 4.6, n in cm⁻³, Tₑ in K:
      //   ν(e,N₂) = 2.33e-11 n(N₂)(1 − 1.21e-4 Tₑ)Tₑ,  ν(e,O₂) = 1.82e-10 n(O₂)(1 + 3.6e-2 √Tₑ)√Tₑ
      let te = particleTemperature
      let perCC = n * 1e-6
      let n2 = 2.33e-11 * (1 - 1.21e-4 * te) * te
      let o2 = 1.82e-10 * (1 + 3.6e-2 * te.squareRoot()) * te.squareRoot()
      return perCC * (nitrogenFraction * n2 + oxygenFraction * o2)
    case .measuredAir:
      return n * 1e-19 * meanSpeed(s, temperature: particleTemperature)
    case .hardSphere(let sigma):
      return n * sigma * meanSpeed(s, temperature: particleTemperature)
    }
  }

  /// The pressure (Pa) at which ω_c/ν = 1, where charges just manage to gyrate. Electrons in
  /// 50 µT: ≈ 5.5 Pa with measured rates ("D layer ~5 Pa"), ≈ 3 Pa with σ = 10⁻¹⁹ m².
  static func gyrationPressure(
    _ s: ChargedSpecies, field: Double, model: CollisionModel = .measuredAir,
    gasTemperature: Double = 288.15, particleTemperature: Double = 300
  ) -> Double {
    let perPascal = collisionFrequency(
      s, pressure: 1, model: model, gasTemperature: gasTemperature, particleTemperature: particleTemperature)
    return perPascal > 0 ? cyclotronAngular(s, field: field) / perPascal : .infinity
  }

  /// ω_c/ν, the number of radians a charge turns between collisions (≫ 1: it gyrates).
  static func magnetizationParameter(
    _ s: ChargedSpecies, field: Double, pressure: Double, model: CollisionModel = .measuredAir,
    gasTemperature: Double = 288.15, particleTemperature: Double = 300
  ) -> Double {
    let nu = collisionFrequency(
      s, pressure: pressure, model: model, gasTemperature: gasTemperature, particleTemperature: particleTemperature)
    return nu > 0 ? cyclotronAngular(s, field: field) / nu : .infinity
  }

  /// Electron spin precession |γₑ|B/2π (Hz). 50 µT: 1.401247569305 MHz.
  static func electronSpinHz(field: Double) -> Double { SpinSpecies.electron.larmorHz(field: field) }

  /// The g − 2 beat f_s − f_c = aₑ f_c (Hz): the spin outruns the orbit. 50 µT: 1623.1 Hz.
  static func gMinusTwoBeatHz(field: Double) -> Double {
    electronSpinHz(field: field) - cyclotronHz(.electron, field: field)
  }

  /// f_s/f_c for the electron, 1 + aₑ = 1.00115965218 (field independent).
  static var electronSpinToCyclotronRatio: Double {
    abs(SpinConstants.gammaElectronHzPerT) / (SpinConstants.e / (2 * .pi * SpinConstants.electronMass))
  }

  /// Proton orbit/spin comparison: f_L/f_c = μₚ/μ_N for a free proton (2.7928): 762 Hz
  /// cyclotron vs 2129 Hz Larmor in 50 µT.
  static func protonSpinToCyclotronRatio() -> Double {
    SpinConstants.gammaProtonHzPerT / (SpinConstants.e / (2 * .pi * SpinConstants.protonMass))
  }
}

/// One charged particle pushed with the Boris scheme [Boris 1970; Birdsall & Langdon]:
/// second order, time-reversible, |v| exactly conserved in a pure magnetic field.
nonisolated struct ChargedParticle: Sendable, Hashable {
  var species: ChargedSpecies
  var position: SIMD3<Double>
  var velocity: SIMD3<Double>

  init(species: ChargedSpecies, position: SIMD3<Double> = .zero, velocity: SIMD3<Double>) {
    self.species = species
    self.position = position
    self.velocity = velocity
  }

  var kineticEnergy: Double { 0.5 * species.mass * simd_length_squared(velocity) }

  /// One Boris step of `h` seconds in fields E (V/m) and B (tesla):
  /// v⁻ = v + (q/m)E h/2; t = (q/m)B h/2, s = 2t/(1 + t²); v′ = v⁻ + v⁻×t; v⁺ = v⁻ + v′×s;
  /// v = v⁺ + (q/m)E h/2; x += v h.
  ///
  /// Plain Boris turns v by 2 atan(ω_c h/2) per step instead of ω_c h, so its gyrofrequency
  /// is low by ≈ (ω_c h)²/12 and its radius high by ≈ (ω_c h)²/8 (3.3e-4 and 4.9e-4 at 100
  /// steps per orbit). `exactPhase` uses t = tan(ω_c h/2)·B̂ instead, which makes the gyration
  /// phase exact at any step (corrected in review); the drift x += v h still walks a chord, so
  /// the radius stays high by ≈ (ω_c h)²/24 (1.6e-4 at 100 steps per orbit).
  mutating func borisStep(h: Double, electric e: SIMD3<Double> = .zero, magnetic b: SIMD3<Double>, exactPhase: Bool = false) {
    borisKick(h: h, electric: e, magnetic: b, exactPhase: exactPhase)
    position += velocity * h
  }

  /// The velocity half of `borisStep` (E half-kick, B rotation, E half-kick); the position is
  /// left for the caller to advance (`x += v h`, or `flight` with collisions).
  mutating func borisKick(h: Double, electric e: SIMD3<Double> = .zero, magnetic b: SIMD3<Double>, exactPhase: Bool = false) {
    let qm = species.chargeToMass
    let vMinus = velocity + qm * e * (0.5 * h)
    var t = qm * b * (0.5 * h)
    if exactPhase {
      let half = simd_length(t)
      if half > 0 { t *= tan(half) / half }
    }
    let s = 2 * t / (1 + simd_length_squared(t))
    let vPrime = vMinus + simd_cross(vMinus, t)
    let vPlus = vMinus + simd_cross(vPrime, s)
    velocity = vPlus + qm * e * (0.5 * h)
  }

  /// Free flight with collisions over `h` seconds, solved exactly: the Ornstein–Uhlenbeck
  /// velocity and its integral, the position, drawn jointly [Chandrasekhar 1943, Rev. Mod.
  /// Phys. 15, 1; Gillespie 1996, Phys. Rev. E 54, 2084]. Per axis, with a = νh, E = e^(−a)
  /// and σ² = kT/m:
  ///
  ///   v ← vE + ξ_v,  x ← x + v·h(1 − E)/a + ξ_x,
  ///   ⟨ξ_v²⟩ = σ²(1 − E²), ⟨ξ_x²⟩ = σ²h²(2a − 3 + 4E − E²)/a², ⟨ξ_xξ_v⟩ = σ²h(1 − E)²/a.
  ///
  /// Exact for any νh, so sea-level air (ν ≈ 1.6 × 10¹¹ s⁻¹) needs no collision substeps:
  /// charges diffuse with D = kT/(mν) and drift at the mobility velocity qE/(mν) (put the E
  /// kick in `borisKick` first). ν = 0 is free flight, x += vh.
  mutating func flight(h: Double, collisionFrequency nu: Double, temperature: Double, rng: inout SpinRandom) {
    guard h > 0, h.isFinite else { return }
    guard nu > 0, nu.isFinite else {
      position += velocity * h
      return
    }
    let a = nu * h
    let decay = exp(-a)
    let oneMinus = -expm1(-a)  // 1 − E without cancellation
    let kT = temperature.isFinite ? max(temperature, 0) : 0
    let s2 = SpinConstants.kB * kT / species.mass
    let varV = s2 * -expm1(-2 * a)
    // g(a) = (2a − 3 + 4E − E²)/a²; its series below a = 0.01 avoids the cancellation
    // (both forms agree to 4e-10 there).
    let g = a < 1e-2 ? a * (2.0 / 3 + a * (-0.5 + a * (7.0 / 30 - a / 12))) : (2 * a - 3 + 4 * decay - decay * decay) / (a * a)
    let varX = s2 * h * h * g
    let cov = s2 * h * oneMinus * oneMinus / a
    let slope = varV > 0 ? cov / varV : 0
    let residual = max(varX - cov * slope, 0).squareRoot()
    let sv = varV.squareRoot()
    let mean = h * oneMinus / a
    let (n1x, n2x) = rng.gaussianPair()
    let (n1y, n2y) = rng.gaussianPair()
    let (n1z, n2z) = rng.gaussianPair()
    let xiV = sv * SIMD3(n1x, n1y, n1z)
    let xiX = slope * xiV + residual * SIMD3(n2x, n2y, n2z)
    position += velocity * mean + xiX
    velocity = velocity * decay + xiV
  }

  /// Collisions with neutral gas over `h` seconds, velocity only: an exact Ornstein–Uhlenbeck
  /// update, v ← v e^(−νh) + √(kT/m (1 − e^(−2νh)))·N(0, 1) per axis. For small νh the kick
  /// variance is the fluctuation–dissipation 2νkT/m·h, so Air and Temperature stay consistent.
  /// `flight` does this jointly with the position (what `ChargeCloud` uses).
  mutating func collide(frequency nu: Double, temperature: Double, h: Double, rng: inout SpinRandom) {
    guard nu > 0, h > 0 else { return }
    let decay = exp(-nu * h)
    let sigma = (SpinConstants.kB * temperature / species.mass * (1 - decay * decay)).squareRoot()
    velocity = velocity * decay + sigma * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())
  }
}

/// The bubble's "Charges" layer: thermal charges at true scale in the live field, gyrating
/// with exact phase, colliding with the bubble's air (Air → ν), reflecting elastically off
/// the film. The bubble is 17 cm across (Gyre's `sceneScale` 12/m), so a 300 K electron's
/// 1.08 cm gyroradius fits; time runs κ-slowed at D = κ/f_c (`SpinTiming.kappaRate`).
nonisolated struct ChargeCloud: Sendable {
  /// Bubble radius (m): Gyre's bubble is about 17 cm across.
  static let bubbleRadius = 0.085
  /// Substep cap per `advance` call; beyond it accuracy degrades gracefully, never stability.
  static let maxSubsteps = 4000

  /// The charges' species. Changing it respawns the cloud (same count, Maxwellian at
  /// `temperature`): the particles carry their own q/m, so a cloud must never mix species.
  var species: ChargedSpecies {
    didSet { if species != oldValue { respawn(count: particles.count) } }
  }
  /// Wall radius (m).
  var radius: Double
  /// Particle (and gas) temperature (K): shared with the RF Lab noise temperature.
  var temperature: Double
  /// Air pressure in the bubble (Pa); 0 is vacuum. Detents: Vacuum, D layer ~5 Pa, sea level.
  var pressure: Double
  var collisionModel: CollisionModel
  private(set) var particles: [ChargedParticle]
  /// Simulated time (s).
  private(set) var time = 0.0
  /// Substeps used by the last `advance` (1 per frame at sea level; ≥ 16 per orbit in vacuum).
  private(set) var lastSubsteps = 0
  private var rng: SpinRandom

  init(
    species: ChargedSpecies = .electron, count: Int = 48, radius: Double = ChargeCloud.bubbleRadius,
    temperature: Double = 300, pressure: Double = 0, collisionModel: CollisionModel = .measuredAir, seed: UInt64 = 1
  ) {
    self.species = species
    self.radius = radius
    self.temperature = temperature
    self.pressure = pressure
    self.collisionModel = collisionModel
    rng = SpinRandom(seed: seed)
    particles = []
    respawn(count: count)
  }

  /// Fresh particles: uniform in 0.8 of the bubble, Maxwellian velocities at `temperature`
  /// (a non-finite or negative temperature spawns them at rest rather than with NaN speeds).
  mutating func respawn(count: Int) {
    var out = [ChargedParticle]()
    out.reserveCapacity(max(count, 0))
    let kT = temperature.isFinite ? max(temperature, 0) : 0
    let sigma = (SpinConstants.kB * kT / species.mass).squareRoot()
    while out.count < max(count, 0) {
      let p = SIMD3(rng.uniform() * 2 - 1, rng.uniform() * 2 - 1, rng.uniform() * 2 - 1)
      guard simd_length(p) <= 1 else { continue }
      let v = sigma * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())
      out.append(ChargedParticle(species: species, position: p * 0.8 * radius, velocity: v))
    }
    particles = out
    time = 0
  }

  /// Collision frequency at the current pressure (1/s).
  var collisionFrequency: Double {
    Gyration.collisionFrequency(species, pressure: pressure, model: collisionModel, particleTemperature: temperature)
  }

  /// Readouts for `field` (tesla): RMS-v⊥ gyroradius, f_c and ω_c/ν.
  func readouts(field: Double) -> (gyroradius: Double, cyclotronHz: Double, magnetization: Double) {
    let v = Gyration.perpendicularRMSSpeed(species, temperature: temperature)
    let nu = collisionFrequency
    let wc = Gyration.cyclotronAngular(species, field: field)
    return (Gyration.gyroradius(species, perpendicularSpeed: v, field: field), wc / (2 * .pi), nu > 0 ? wc / nu : .infinity)
  }

  /// Advances `dt` *simulated* seconds (the caller multiplies wall time by D) in a uniform
  /// field B (tesla) and E (V/m). Substeps keep each step under 1/16 orbit and under a quarter
  /// radius of flight at the thermal speed or the fastest particle's, whichever is larger (in
  /// vacuum nothing re-thermalizes, so charges spawned hot stay hot after the Temperature knob
  /// drops; sized by the knob alone they crossed the bubble in one substep and the wall
  /// reflection parked them at the centre). Collisions need no substeps, because `flight` is
  /// exact for any νh (sea-level air costs one substep per frame, not thousands). Non-finite
  /// fields are ignored for this call.
  mutating func advance(_ dt: Double, magnetic b: SIMD3<Double>, electric e: SIMD3<Double> = .zero) {
    guard dt > 0, dt.isFinite, !particles.isEmpty,
      b.x.isFinite, b.y.isFinite, b.z.isFinite, e.x.isFinite, e.y.isFinite, e.z.isFinite
    else { return }
    let wc = Gyration.cyclotronAngular(species, field: simd_length(b))
    let nu = collisionFrequency
    let kT = temperature.isFinite ? max(temperature, 0) : 0
    let thermal = (3 * SpinConstants.kB * kT / species.mass).squareRoot()
    let fastest = particles.reduce(thermal) { max($0, simd_length($1.velocity)) }
    let limit = max(wc / (2 * .pi / 16), radius > 0 ? fastest / (0.25 * radius) : 0)
    let wanted = (dt * limit).rounded(.up)
    let n = wanted.isFinite ? Int(SpinMath.clamp(wanted, 1, Double(Self.maxSubsteps))) : Self.maxSubsteps
    let h = dt / Double(n)
    let collides = nu > 0 && nu.isFinite
    for _ in 0..<n {
      for i in particles.indices {
        var p = particles[i]
        p.borisKick(h: h, electric: e, magnetic: b, exactPhase: true)
        if collides {
          p.flight(h: h, collisionFrequency: nu, temperature: kT, rng: &rng)
        } else {
          p.position += p.velocity * h
        }
        let d = simd_length(p.position)
        if d > radius {
          let nrm = p.position / d
          p.position = nrm * max(2 * radius - d, 0)
          let vn = simd_dot(p.velocity, nrm)
          if vn > 0 { p.velocity -= 2 * vn * nrm }
        }
        particles[i] = p
      }
    }
    lastSubsteps = n
    time += dt
  }

  /// Positions in units of the bubble radius (−1…1), for the renderer.
  var normalizedPositions: [SIMD3<Float>] {
    particles.map { SIMD3<Float>($0.position / radius) }
  }
}
