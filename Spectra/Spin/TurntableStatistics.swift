import Foundation

/// Fading statistics for the BLE turntable experiment (`gyre-integration.md` §4.2): why a
/// single RSSI stream cannot show an antenna pattern on its own.
nonisolated enum TurntableStatistics {
  /// Standard deviation of 10 log₁₀ X for exponentially distributed power X (pure Rayleigh
  /// fading): (10/ln 10)·π/√6 = 5.570 dB. If the per-bin σ is about this, the pattern is
  /// buried in fading.
  static let rayleighDecibelSpread = 10 / log(10.0) * .pi / 6.0.squareRoot()

  /// Mean and standard deviation of a sample.
  static func meanAndDeviation(_ values: [Double]) -> (mean: Double, deviation: Double) {
    guard !values.isEmpty else { return (0, 0) }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return (mean, variance.squareRoot())
  }

  /// σ in dB of `count` simulated Rayleigh-faded power samples (seeded, deterministic).
  static func simulatedDecibelSpread(count: Int, seed: UInt64) -> Double {
    var rng = SpinRandom(seed: seed)
    let db = (0..<max(count, 1)).map { _ in 10 * log10(rng.exponential()) }
    return meanAndDeviation(db).deviation
  }
}

/// The closed-form models the turntable experiment and the attitude-locked antenna compare
/// against (`gyre-integration.md` §4.2), kept here so the §10 oracles run in the spin harness.
/// The RF engine (`RF/Antennas`) owns the general antenna models; these are the textbook
/// special cases only.
nonisolated enum TurntableModel {
  /// Polarization loss factor cos²ψ in dB for linear antennas misaligned by `angle` (rad).
  /// 80°: −15.2066 dB.
  static func polarizationLossDB(misalignment angle: Double) -> Double {
    let c = cos(angle)
    return 10 * log10(max(c * c, 1e-300))
  }

  /// Half-wave dipole power pattern F²(θ) = [cos(π/2·cos θ)/sin θ]² in dB, θ from the dipole
  /// axis. 30°: −7.5808 dB.
  static func halfWaveDipolePatternDB(theta: Double) -> Double {
    let s = sin(theta)
    guard abs(s) > 1e-12 else { return -.infinity }
    let f = cos(.pi / 2 * cos(theta)) / s
    return 10 * log10(max(f * f, 1e-300))
  }

  /// Normalized array factor of an N-element uniform linear array,
  /// AF = sin(Nψ/2)/(N sin(ψ/2)), ψ = 2π(d/λ) cos θ + β, θ from the array axis.
  /// N 8, d λ/2, β 0: nulls at cos θ = k/4 (75.52°, then 60°).
  static func uniformArrayFactor(elements n: Int, spacingWavelengths d: Double, phaseStep beta: Double, theta: Double) -> Double {
    let psi = 2 * .pi * d * cos(theta) + beta
    let den = Double(n) * sin(psi / 2)
    guard abs(den) > 1e-15 else { return 1 }
    return sin(Double(n) * psi / 2) / den
  }
}
