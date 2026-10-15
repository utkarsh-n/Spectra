import Foundation
import simd

/// Earth's field as the phone sees it: the magnetometer vector and the gravity vector in the
/// same frame (`gyre-integration.md` §5.3). Gives |B|, the dip angle I and, through the dipole
/// relation tan I = 2 tan λₘ, your magnetic latitude (INFERRED).
nonisolated struct EarthField: Sendable, Hashable {
  /// IGRF dipole equatorial field B₀ ≈ 30 µT [S], for the dipole |B| estimate.
  static let dipoleEquatorialField = 30e-6
  /// "Earth field" detent and the default B₀ when no live field exists (tesla).
  static let typicalField = 50e-6

  /// The magnetic field vector, tesla.
  var field: SIMD3<Double>
  /// Gravity in the same frame, pointing down (CoreMotion's `gravity`); any units.
  var gravity: SIMD3<Double>

  init(field: SIMD3<Double>, gravity: SIMD3<Double>) {
    self.field = field
    self.gravity = gravity
  }

  /// From CoreMotion units: field in µT, gravity in g.
  init(microtesla: SIMD3<Double>, gravity: SIMD3<Double>) {
    self.init(field: microtesla * 1e-6, gravity: gravity)
  }

  /// |B| in tesla.
  var magnitude: Double { simd_length(field) }

  /// Unit vector pointing down.
  var down: SIMD3<Double> { SpinMath.unit(gravity) }

  /// Downward component of B (tesla); positive in the northern magnetic hemisphere.
  var vertical: Double { simd_dot(field, down) }

  /// Horizontal component of B (tesla).
  var horizontal: Double { simd_length(field - vertical * down) }

  /// Inclination (dip) I = atan2(B·down, |B_h|), radians: + when the field dips downward.
  var dipAngle: Double { atan2(vertical, horizontal) }

  /// Magnetic latitude λₘ from tan I = 2 tan λₘ, radians.
  var magneticLatitude: Double { Self.magneticLatitude(dipAngle: dipAngle) }

  /// What a centred dipole predicts for |B| at this magnetic latitude (tesla).
  var dipoleMagnitude: Double { Self.dipoleMagnitude(magneticLatitude: magneticLatitude) }

  /// Larmor frequency of `species` in this field (Hz).
  func larmorHz(_ species: SpinSpecies) -> Double { species.larmorHz(field: magnitude) }

  /// λₘ = atan(tan I / 2). I = 66° gives 48.316°.
  static func magneticLatitude(dipAngle: Double) -> Double { atan(tan(dipAngle) / 2) }

  /// I = atan(2 tan λₘ).
  static func dipAngle(magneticLatitude: Double) -> Double { atan(2 * tan(magneticLatitude)) }

  /// |B| = B₀√(1 + 3 sin²λₘ). λₘ = 48.3° with B₀ = 30 µT: 49.0 µT.
  static func dipoleMagnitude(magneticLatitude: Double, equatorialField b0: Double = dipoleEquatorialField) -> Double {
    let s = sin(magneticLatitude)
    return b0 * (1 + 3 * s * s).squareRoot()
  }
}

/// One-pole smoothing for a noisy, irregularly sampled field magnitude (or any scalar):
/// y += (x − y)(1 − e^(−dt/τ)). τ = 0.25 s for the FID pitch.
nonisolated struct FieldSmoother: Sendable, Hashable {
  var timeConstant: Double
  private(set) var value: Double?

  init(timeConstant: Double = LarmorSonification.fieldSmoothingTime) { self.timeConstant = timeConstant }

  /// Feeds a sample taken `dt` seconds after the previous one; returns the smoothed value.
  /// A non-finite sample is skipped (the value holds; 0 before the first good sample).
  @discardableResult
  mutating func update(_ x: Double, dt: Double) -> Double {
    guard x.isFinite else { return value ?? 0 }
    guard let y = value, timeConstant > 0 else {
      value = x
      return x
    }
    let next = y + (x - y) * (1 - exp(-(dt.isFinite ? max(dt, 0) : 0) / timeConstant))
    value = next
    return next
  }

  mutating func reset() { value = nil }
}

/// Chemical shifts against field strength (`gyre-integration.md` §4.1, "Ethanol at Earth's
/// field"): shifts scale with B₀, J couplings do not, so at Earth's field ethanol's CH₂ and
/// CH₃ lines are strongly coupled and collapse into one line.
nonisolated enum ChemicalShift {
  /// Ethanol CH₂ − CH₃ shift difference, 3.69 − 1.22 = 2.47 ppm.
  static let ethanolShiftPPM = 2.47
  /// Ethanol ³J(CH₂–CH₃), Hz.
  static let ethanolCouplingHz = 7.1

  /// Δν = Δδ·f₀ (Hz) for a shift difference `ppm` at proton frequency `protonHz`.
  /// Ethanol: 988.6 Hz at 9.4 T, 148.3 Hz at 1.41 T, 5.26 mHz at 50 µT.
  static func separationHz(ppm: Double, protonHz: Double) -> Double { ppm * 1e-6 * protonHz }

  /// Δν/J: ≫ 1 is first order (multiplets), ≪ 1 strongly coupled (one line).
  /// Ethanol: 139 at 9.4 T, 20.9 at 1.41 T, 7.4 × 10⁻⁴ at 50 µT.
  static func couplingRatio(ppm: Double, couplingHz: Double, protonHz: Double) -> Double {
    couplingHz > 0 ? separationHz(ppm: ppm, protonHz: protonHz) / couplingHz : .infinity
  }
}
