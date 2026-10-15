import Foundation

/// Small-scale fading statistics, dispersion and Doppler (rf-physics B.10–B.12).
nonisolated extension RF.Fading {
  /// Rayleigh outage: probability that the received power falls below γ₀ when the mean is γ̄,
  /// 1 − e^{−γ₀/γ̄}. `fadeDB` is how far below the mean (10 dB → 0.095 1626).
  static func rayleighOutage(belowMeanDB fadeDB: Double) -> Double {
    -expm1(-pow(10, -fadeDB / 10))
  }

  /// Standard deviation of Rayleigh-faded power in dB, (10/ln 10)·π/√6 = 5.57 dB: the
  /// turntable experiment's yardstick for "the pattern is buried in fading".
  static let rayleighDBStandardDeviation = 10 / log(10.0) * Double.pi / 6.0.squareRoot()

  /// Rayleigh envelope pdf p(r) = (r/σ²)·e^{−r²/(2σ²)}.
  static func rayleighPDF(_ r: Double, sigma: Double) -> Double {
    guard r >= 0 else { return 0 }
    let s2 = sigma * sigma
    return r / s2 * exp(-r * r / (2 * s2))
  }

  /// Rician envelope pdf p(z) = (z/σ²)·exp[−(z² + s²)/(2σ²)]·I₀(zs/σ²), evaluated with the
  /// scaled Bessel function so large K does not overflow.
  static func ricianPDF(_ z: Double, s: Double, sigma: Double) -> Double {
    guard z >= 0 else { return 0 }
    let s2 = sigma * sigma
    let x = z * s / s2
    return z / s2 * exp(-(z - s) * (z - s) / (2 * s2)) * RF.Special.besselI0Scaled(x)
  }

  /// Rician K = s²/(2σ²) → (s, σ) for unit mean power P_r = s² + 2σ² = 1.
  static func ricianParameters(k: Double) -> (s: Double, sigma: Double) {
    (s: (k / (k + 1)).squareRoot(), sigma: (1 / (2 * (k + 1))).squareRoot())
  }

  /// RMS delay spread σ_τ = √(⟨τ²⟩ − ⟨τ⟩²) of a power-delay profile (delays in s, powers linear).
  static func rmsDelaySpread(delays: [Double], powers: [Double]) -> Double {
    let total = powers.reduce(0, +)
    guard total > 0 else { return 0 }
    var m1 = 0.0
    var m2 = 0.0
    for (t, p) in zip(delays, powers) {
      m1 += p * t
      m2 += p * t * t
    }
    m1 /= total
    m2 /= total
    return max(0, m2 - m1 * m1).squareRoot()
  }

  /// Coherence bandwidth for 50 % correlation, B_c ≈ 1/(5σ_τ) (1 µs → 200 kHz).
  static func coherenceBandwidth50(delaySpread s: Double) -> Double { 1 / (5 * s) }

  /// Coherence bandwidth for 90 % correlation, B_c ≈ 1/(50σ_τ) (1 µs → 20 kHz).
  static func coherenceBandwidth90(delaySpread s: Double) -> Double { 1 / (50 * s) }

  /// True when the signal bandwidth exceeds B_c,50 (frequency-selective channel).
  static func isFrequencySelective(bandwidth b: Double, delaySpread s: Double) -> Bool {
    s > 0 && b > coherenceBandwidth50(delaySpread: s)
  }

  /// Maximum Doppler shift f_m = v·f/c (30 m/s at 3.5 GHz → 350.2423 Hz).
  static func maxDoppler(speed v: Double, frequency f: Double) -> Double { v * f / RF.Const.c }

  /// Doppler shift f_D = (v/λ)·cosθ for arrival angle θ from the direction of motion.
  static func dopplerShift(speed v: Double, frequency f: Double, angle theta: Double) -> Double {
    maxDoppler(speed: v, frequency: f) * cos(theta)
  }

  /// Coherence time, geometric-mean rule T_c ≈ 0.423/f_m (1.2077 ms at 350 Hz) [S, Rappaport].
  static func coherenceTime(maxDoppler fm: Double) -> Double { 0.423 / fm }

  /// Coherence time for 0.5 correlation, T_c ≈ 9/(16π·f_m) (0.5112 ms at 350 Hz) [S, Rappaport].
  static func coherenceTimeHalfCorrelation(maxDoppler fm: Double) -> Double { 9 / (16 * Double.pi * fm) }

  /// Clarke/Jakes Doppler spectrum S(f) = 1/(π·f_m·√(1 − (f/f_m)²)) for |f| < f_m, else 0.
  static func clarkeSpectrum(_ f: Double, maxDoppler fm: Double) -> Double {
    let x = f / fm
    guard abs(x) < 1 else { return 0 }
    return 1 / (Double.pi * fm * (1 - x * x).squareRoot())
  }

  /// TR 38.901 Table 7.7.3-1 scaling delay spreads (ns): very short … very long.
  static let tr38901ScalingDelaySpreadsNs: [Double] = [10, 30, 100, 300, 1000]

  /// TR 38.901 Table 7.7.3-2 example delay spreads (ns) for UI detents.
  static let tr38901ExampleDelaySpreads: [(name: String, frequencyGHz: Double, nanoseconds: Double)] = [
    ("Indoor office", 2, 39), ("Indoor office", 28, 20),
    ("Urban macro", 2, 363), ("Urban macro", 28, 266), ("Urban macro (long)", 2, 1148),
  ]
}
