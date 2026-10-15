import Foundation

/// Time-mapping arithmetic for spin displays (coherence rule R3). The same formulas as the
/// app's `TimeMapping`, kept here so the pure engine and its harness need nothing outside
/// `Spin/`.
nonisolated enum SpinTiming {
  /// Where a frequency lands after sampling at `sampleRate`: |f − fs·round(f/fs)|.
  /// 60 Hz at 99.8 Hz → 39.8 Hz; a 337.5 Hz nod at 120 fps → 22.5 Hz.
  static func aliasedFrequency(_ frequency: Double, sampleRate: Double) -> Double {
    guard sampleRate > 0 else { return frequency }
    return abs(frequency - sampleRate * (frequency / sampleRate).rounded())
  }

  /// True when a displayed frequency exceeds half the frame rate (show ALIASED and blur).
  static func isAliased(_ displayedFrequency: Double, frameRate: Double) -> Bool {
    frameRate > 0 && abs(displayedFrequency) > 0.5 * frameRate
  }

  /// κ-slowed display rate D = κ/f_ref (simulated seconds per wall second).
  /// 545 THz at κ = 1: 1.83 × 10⁻¹⁵; electrons gyrating at 1.40 MHz: 7.1 × 10⁻⁷.
  static func kappaRate(kappa: Double, referenceHz: Double) -> Double {
    referenceHz > 0 ? kappa / referenceHz : 0
  }

  /// How many times slower than reality a κ-slowed display runs, 1/D = f_ref/κ. Print this
  /// ("slowed 5.5 × 10¹⁴×" for 545 THz at κ = 1), not "1 : 1/D" with D's mantissa, which
  /// overstates the slowdown (corrected in review).
  static func slowdownFactor(kappa: Double, referenceHz: Double) -> Double {
    kappa > 0 ? referenceHz / kappa : .infinity
  }

  /// The nod frequency a viewer sees: the true nod × time scale, folded by the frame rate.
  /// 12 000 rpm balanced (337.5 Hz) at 120 fps: 22.5 Hz.
  static func apparentFrequency(_ frequency: Double, timeScale: Double = 1, frameRate: Double) -> Double {
    aliasedFrequency(abs(frequency * timeScale), sampleRate: frameRate)
  }
}
