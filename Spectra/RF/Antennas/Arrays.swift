import Foundation

/// Uniform linear arrays (rf-physics A.11–A.12, Nikolova L13–L14). θ is measured **from the
/// array axis** (Nikolova's convention); `fromBroadside` helpers convert. Spacing d in
/// wavelengths, progressive phase β in radians.
nonisolated extension RF.Arrays {
  /// Array phase ψ = k·d·cosθ + β (d in λ, so k·d = 2π·d).
  @inline(__always) static func psi(theta: Double, spacing d: Double, beta: Double) -> Double {
    2 * Double.pi * d * cos(theta) + beta
  }

  /// Normalized array factor AF_n(ψ) = sin(Nψ/2)/(N·sin(ψ/2)), signed, 1 at ψ = 0 (mod 2π).
  static func normalizedAF(psi: Double, elements n: Int) -> Double {
    let half = psi / 2
    let den = Double(n) * sin(half)
    if abs(den) < 1e-12 {
      // ψ = 2πm: the limit is (−1)^{m(N−1)} (parity in Double, so a huge ψ cannot trap).
      let m = (psi / (2 * Double.pi)).rounded()
      return (n - 1) % 2 == 0 || m.truncatingRemainder(dividingBy: 2) == 0 ? 1 : -1
    }
    return sin(Double(n) * half) / den
  }

  /// Normalized ULA array factor at angle θ (radians from the axis).
  static func normalizedAF(theta: Double, elements n: Int, spacing d: Double, beta: Double) -> Double {
    normalizedAF(psi: psi(theta: theta, spacing: d, beta: beta), elements: n)
  }

  /// Progressive phase that steers the main beam to θ₀ (from the axis): β = −k·d·cosθ₀.
  /// N = 8, d = λ/2, θ₀ = 60° → −90°.
  static func steeringPhase(spacing d: Double, steerTheta theta0: Double) -> Double {
    -2 * Double.pi * d * cos(theta0)
  }

  /// Largest grating-free spacing for a beam steered to θ₀ (from the axis):
  /// d/λ < 1/(1 + |cosθ₀|) (0.6667λ at θ₀ = 60°; 1λ at broadside).
  static func gratingFreeSpacing(steerTheta theta0: Double) -> Double { 1 / (1 + abs(cos(theta0))) }

  /// Same limit with the steering angle measured from broadside: d/λ < 1/(1 + |sinθ_s|).
  static func gratingFreeSpacing(steerFromBroadside thetaS: Double) -> Double { 1 / (1 + abs(sin(thetaS))) }

  /// Directions (radians from the axis, ascending) of every full-height lobe of the array
  /// factor in visible space: ψ = 2πm for integer m with |cosθ| ≤ 1. The main beam is the one
  /// with m = 0; the others are grating lobes.
  /// Spacings above 10⁴λ (or non-finite inputs) return no lobes rather than enumerate millions.
  static func lobeDirections(spacing d: Double, beta: Double) -> [(order: Int, theta: Double)] {
    guard d > 0, d <= 1e4, beta.isFinite, abs(beta) <= 1e6 else { return [] }
    var out: [(Int, Double)] = []
    let kd = 2 * Double.pi * d
    let mMin = Int(((-kd + beta) / (2 * Double.pi)).rounded(.down)) - 1
    let mMax = Int(((kd + beta) / (2 * Double.pi)).rounded(.up)) + 1
    for m in mMin...mMax {
      let c = (2 * Double.pi * Double(m) - beta) / kd
      if c >= -1 - 1e-12, c <= 1 + 1e-12 { out.append((m, acos(min(1, max(-1, c))))) }
    }
    return out.sorted { $0.1 < $1.1 }
  }

  /// Grating lobes only (every full-height lobe other than the steered main beam).
  static func gratingLobes(spacing d: Double, beta: Double) -> [Double] {
    lobeDirections(spacing: d, beta: beta).filter { $0.order != 0 }.map(\.theta)
  }

  /// Power pattern |AF_n|² sampled in degrees from the axis.
  static func powerPattern(elements n: Int, spacing d: Double, beta: Double) -> (Double) -> Double {
    { deg in
      let a = normalizedAF(theta: deg * Double.pi / 180, elements: n, spacing: d, beta: beta)
      return a * a
    }
  }

  /// Direction of the main beam (degrees from the axis): where ψ = 0, refined on the sampled
  /// pattern so endfire beams are handled too.
  static func beamPeakDeg(elements n: Int, spacing d: Double, beta: Double) -> Double {
    let p = powerPattern(elements: n, spacing: d, beta: beta)
    let guess = acos(min(1, max(-1, -beta / (2 * Double.pi * d)))) * 180 / Double.pi
    // Stay inside the main lobe: its first nulls are about 57.3°/(N·d) away.
    let half = min(1, 0.5 * 57.3 / (Double(n) * max(d, 1e-6)))
    let lo = max(0, guess - half)
    let hi = min(180, guess + half)
    return RF.Numerics.maximize(lo, hi, tolerance: 1e-10, p)
  }

  /// Exact half-power beamwidth of the main beam in degrees (N = 8, λ/2: 12.80° broadside,
  /// 14.84° steered to 60°). Nil for an endfire beam whose half-power point falls outside 0…180°.
  static func hpbwDeg(elements n: Int, spacing d: Double, beta: Double) -> Double? {
    let peak = beamPeakDeg(elements: n, spacing: d, beta: beta)
    return RF.Antennas.halfPowerBeamwidth(
      peakDeg: peak, rangeDeg: 0...180, step: 0.01, powerPattern(elements: n, spacing: d, beta: beta))
  }

  /// Broadside HPBW approximation 2[π/2 − arccos(1.391λ/(πNd))] in degrees (L14 p. 11; 12.71°).
  static func broadsideHPBWApproxDeg(elements n: Int, spacing d: Double) -> Double {
    let x = 1.391 / (Double.pi * Double(n) * d)
    guard x <= 1 else { return 180 }
    return 2 * (90 - acos(x) * 180 / Double.pi)
  }

  /// Broadside directivity approximation D ≈ 2N·d/λ (L14).
  static func broadsideDirectivityApprox(elements n: Int, spacing d: Double) -> Double { 2 * Double(n) * d }

  /// Directivity of an N-element ULA of isotropic elements by numerical integration:
  /// D = 2·max|AF|² / ∫₀^π |AF|² sinθ dθ (N = 8, λ/2 broadside → 8.000).
  static func directivity(elements requested: Int, spacing d: Double, beta: Double) -> Double {
    let n = max(1, requested)
    guard d.isFinite, beta.isFinite else { return .nan }
    // In μ = cosθ, |AF|² is periodic in ψ = 2πdμ + β; use enough panels to resolve every lobe.
    let panels = Int(min(max(32, (Double(n) * abs(d) * 8).rounded(.up)), 1_000_000))
    let power: (Double) -> Double = { mu in
      let a = normalizedAF(psi: 2 * Double.pi * d * mu + beta, elements: n)
      return a * a
    }
    let integral = RF.Numerics.integrate(-1, 1, panels: panels, rule: .order32, power)
    // The visible-space maximum is 1 whenever ψ = 0 is visible. Otherwise (|β| > kd, the main
    // beam is out of visible space) it is an end point or an interior sidelobe peak: scan and
    // refine.
    var peak = 1.0
    if lobeDirections(spacing: d, beta: beta).isEmpty {
      let steps = min(1_000_000, max(2000, panels * 64))
      var best = -1.0
      peak = 0
      for k in 0...steps {
        let mu = -1 + 2 * Double(k) / Double(steps)
        let v = power(mu)
        if v > peak {
          peak = v
          best = mu
        }
      }
      let h = 2 / Double(steps)
      let refined = RF.Numerics.maximize(max(-1, best - h), min(1, best + h), tolerance: 1e-13, power)
      peak = max(peak, power(refined))
    }
    return 2 * peak / integral
  }

  /// Level (dB, relative to the main beam) of the highest sidelobe — the largest local maximum
  /// that is not a full-height lobe (N = 8, λ/2 → −12.80 dB).
  static func highestSidelobeDB(elements n: Int, spacing d: Double, beta: Double) -> Double? {
    let p = powerPattern(elements: n, spacing: d, beta: beta)
    let step = 0.02
    var best: Double?
    var prev2 = p(0)
    var prev1 = p(step)
    var x = 2 * step
    while x <= 180 + 1e-9 {
      let cur = p(x)
      if prev1 > prev2, prev1 >= cur, prev1 < 0.999 {
        let refined = RF.Numerics.maximize(x - 2 * step, x, tolerance: 1e-10, p)
        let v = p(refined)
        if v < 0.999, v > (best ?? 0) { best = v }
      }
      prev2 = prev1
      prev1 = cur
      x += step
    }
    return best.map { 10 * log10($0) }
  }
}
