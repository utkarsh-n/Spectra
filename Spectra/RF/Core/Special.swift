import Foundation

// MARK: - Special functions

nonisolated extension RF.Special {
  /// Euler–Mascheroni constant γ.
  static let eulerGamma = 0.577_215_664_901_532_860_6

  /// Gaussian tail probability Q(x) = ½·erfc(x/√2) (rf-physics C.6).
  static func Q(_ x: Double) -> Double { 0.5 * erfc(x / 2.0.squareRoot()) }

  /// Standard normal CDF Φ(x).
  static func normalCDF(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }

  /// Inverse standard normal CDF Φ⁻¹(p) for 0 < p < 1 (Acklam's rational approximation plus one
  /// Halley step against `erfc`, accurate to ~1e-15). Used by ITU-R P.2109 (F⁻¹).
  static func inverseNormalCDF(_ p: Double) -> Double {
    guard p > 0 else { return -.infinity }
    guard p < 1 else { return .infinity }
    let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
             1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
    let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
             6.680131188771972e+01, -1.328068155288572e+01]
    let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
             -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
    let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
    let pLow = 0.02425
    var x: Double
    if p < pLow {
      let q = (-2 * log(p)).squareRoot()
      x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
        / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    } else if p <= 1 - pLow {
      let q = p - 0.5
      let r = q * q
      x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
        / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    } else {
      let q = (-2 * log(1 - p)).squareRoot()
      x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
        / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    }
    // One Halley refinement step.
    let e = normalCDF(x) - p
    let u = e * (2 * Double.pi).squareRoot() * exp(x * x / 2)
    x -= u / (1 + x * u / 2)
    return x
  }

  /// Inverse of Q: the x for which Q(x) = p.
  static func inverseQ(_ p: Double) -> Double { -inverseNormalCDF(p) }

  /// Bessel function of the first kind Jₙ(x) (libm `jn`, rf-physics §0.4).
  static func besselJ(_ n: Int, _ x: Double) -> Double { jn(Int32(n), x) }

  /// Modified Bessel function I₀(x).
  static func besselI0(_ x: Double) -> Double {
    let ax = abs(x)
    if ax <= 15 { return i0Series(ax) }
    return exp(ax) * i0AsymptoticScaled(ax)
  }

  /// e^{−|x|}·I₀(x), safe for large arguments (Rician pdf).
  static func besselI0Scaled(_ x: Double) -> Double {
    let ax = abs(x)
    if ax <= 15 { return exp(-ax) * i0Series(ax) }
    return i0AsymptoticScaled(ax)
  }

  private static func i0Series(_ x: Double) -> Double {
    let y = x * x / 4
    var term = 1.0
    var sum = 1.0
    var k = 1.0
    while k < 500 {
      term *= y / (k * k)
      sum += term
      if term < sum * 1e-17 { break }
      k += 1
    }
    return sum
  }

  private static func i0AsymptoticScaled(_ x: Double) -> Double {
    var term = 1.0
    var sum = 1.0
    for k in 1..<60 {
      let next = term * Double((2 * k - 1) * (2 * k - 1)) / (8 * Double(k) * x)
      if next >= term { break }
      term = next
      sum += term
      if term < 1e-17 { break }
    }
    return sum / (2 * Double.pi * x).squareRoot()
  }

  /// Sine and cosine integrals Si(x) and Ci(x) for x > 0 (power series for x ≤ 6, the
  /// continued fraction for E₁(ix) beyond, Numerical Recipes §6.9).
  static func sici(_ x: Double) -> (si: Double, ci: Double) {
    let t = abs(x)
    guard t > 0 else { return (0, -.infinity) }
    var si: Double
    var ci: Double
    if t <= 6 {
      si = 0
      var term = t  // x^{2k+1}/(2k+1)!
      var k = 0
      while k < 200 {
        let contribution = term / Double(2 * k + 1)
        si += (k % 2 == 0 ? 1 : -1) * contribution
        if abs(contribution) < 1e-18 * max(1, abs(si)) { break }
        let denominator = Double((2 * k + 2) * (2 * k + 3))
        term *= t * t / denominator
        k += 1
      }
      ci = eulerGamma + log(t) - cinSeries(t)
    } else {
      // Lentz evaluation of E₁(it): b₀ = 1 + it, aₙ = −(n−1)², bₙ = bₙ₋₁ + 2.
      let tiny = 1e-300
      var b = RF.Complex(1, t)
      var c = RF.Complex(1 / tiny, 0)
      var d = RF.Complex.one / b
      var h = d
      for i in 2...1000 {
        let a = -Double((i - 1) * (i - 1))
        b = b + RF.Complex(2, 0)
        d = RF.Complex.one / (d * a + b)
        c = b + RF.Complex(a, 0) / c
        let del = c * d
        h = h * del
        if abs(del.re - 1) + abs(del.im) < 1e-16 { break }
      }
      h = RF.Complex(cos(t), -sin(t)) * h
      ci = -h.re
      si = Double.pi / 2 + h.im
    }
    if x < 0 { si = -si }
    return (si, ci)
  }

  /// Entire cosine integral Cin(x) = ∫₀ˣ (1 − cos t)/t dt = γ + ln x − Ci(x).
  static func cin(_ x: Double) -> Double {
    let t = abs(x)
    if t <= 6 { return cinSeries(t) }
    return eulerGamma + log(t) - sici(t).ci
  }

  private static func cinSeries(_ t: Double) -> Double {
    var sum = 0.0
    var term = 1.0  // x^{2k}/(2k)!
    var k = 1
    while k < 200 {
      term *= t * t / Double((2 * k - 1) * (2 * k))
      let contribution = term / Double(2 * k)
      sum += (k % 2 == 1 ? 1 : -1) * contribution
      if contribution < 1e-18 * max(1, abs(sum)) { break }
      k += 1
    }
    return sum
  }

  /// Fresnel integrals C(x) = ∫₀ˣ cos(πt²/2) dt and S(x) = ∫₀ˣ sin(πt²/2) dt
  /// (series for |x| ≤ 2, complex continued fraction beyond; Numerical Recipes §6.9).
  static func fresnel(_ x: Double) -> (c: Double, s: Double) {
    let ax = abs(x)
    var c: Double
    var s: Double
    if ax < 1e-150 {
      return (x, 0)
    } else if ax <= 2 {
      // C = Σ (−1)^k (π/2)^{2k} x^{4k+1} / ((2k)!(4k+1)),  S = Σ (−1)^k (π/2)^{2k+1} x^{4k+3} / ((2k+1)!(4k+3)).
      let u = Double.pi / 2 * ax * ax
      c = 0
      s = 0
      var term = ax  // (π/2)^n x^{2n+1} / n!
      var n = 0
      while n < 200 {
        let contribution = term / Double(2 * n + 1)
        let sign: Double = (n / 2) % 2 == 0 ? 1 : -1
        if n % 2 == 0 { c += sign * contribution } else { s += sign * contribution }
        if contribution < 1e-18 { break }
        n += 1
        term *= u / Double(n)
      }
    } else {
      let pix2 = Double.pi * ax * ax
      let tiny = 1e-300
      var b = RF.Complex(1, -pix2)
      var cc = RF.Complex(1 / tiny, 0)
      var d = RF.Complex.one / b
      var h = d
      var n = -1
      for _ in 2...1000 {
        n += 2
        let a = -Double(n * (n + 1))
        b = b + RF.Complex(4, 0)
        d = RF.Complex.one / (d * a + b)
        cc = b + RF.Complex(a, 0) / cc
        let del = cc * d
        h = h * del
        if abs(del.re - 1) + abs(del.im) < 1e-16 { break }
      }
      h = RF.Complex(ax, -ax) * h
      let cs = RF.Complex(0.5, 0.5) * (RF.Complex.one - RF.Complex(cos(0.5 * pix2), sin(0.5 * pix2)) * h)
      c = cs.re
      s = cs.im
    }
    if x < 0 {
      c = -c
      s = -s
    }
    return (c, s)
  }

  /// sin(x)/x with the removable singularity handled.
  static func sinc(_ x: Double) -> Double {
    abs(x) < 1e-8 ? 1 - x * x / 6 : sin(x) / x
  }
}

// MARK: - Numerics

nonisolated extension RF.Numerics {
  /// Gauss–Legendre nodes and weights on [−1, 1].
  struct GaussLegendre: Sendable {
    let nodes: [Double]
    let weights: [Double]

    init(order n: Int) {
      var x = [Double](repeating: 0, count: n)
      var w = [Double](repeating: 0, count: n)
      let m = (n + 1) / 2
      for i in 0..<m {
        var z = cos(Double.pi * (Double(i) + 0.75) / (Double(n) + 0.5))
        var pp = 0.0
        for _ in 0..<100 {
          var p1 = 1.0
          var p2 = 0.0
          for j in 1...n {
            let p3 = p2
            p2 = p1
            p1 = ((2 * Double(j) - 1) * z * p2 - (Double(j) - 1) * p3) / Double(j)
          }
          pp = Double(n) * (z * p1 - p2) / (z * z - 1)
          let z1 = z
          z = z1 - p1 / pp
          if abs(z - z1) < 1e-15 { break }
        }
        x[i] = -z
        x[n - 1 - i] = z
        w[i] = 2 / ((1 - z * z) * pp * pp)
        w[n - 1 - i] = w[i]
      }
      nodes = x
      weights = w
    }

    static let order8 = GaussLegendre(order: 8)
    static let order16 = GaussLegendre(order: 16)
    static let order32 = GaussLegendre(order: 32)
  }

  /// Composite Gauss–Legendre integral of `f` over [a, b] with `panels` equal panels.
  static func integrate(
    _ a: Double, _ b: Double, panels: Int = 16, rule: GaussLegendre = .order16,
    _ f: (Double) -> Double
  ) -> Double {
    let h = (b - a) / Double(panels)
    var total = 0.0
    for p in 0..<panels {
      let lo = a + Double(p) * h
      let mid = lo + h / 2
      var s = 0.0
      for i in rule.nodes.indices {
        s += rule.weights[i] * f(mid + h / 2 * rule.nodes[i])
      }
      total += s * h / 2
    }
    return total
  }

  /// Bisection root of `f` on [a, b] (requires a sign change).
  static func bisect(_ a: Double, _ b: Double, tolerance: Double = 1e-13, _ f: (Double) -> Double) -> Double? {
    var lo = a
    var hi = b
    var flo = f(lo)
    let fhi = f(hi)
    if flo == 0 { return lo }
    if fhi == 0 { return hi }
    guard flo * fhi < 0 else { return nil }
    for _ in 0..<200 {
      let mid = 0.5 * (lo + hi)
      let fm = f(mid)
      if fm == 0 { return mid }
      if flo * fm < 0 {
        hi = mid
      } else {
        lo = mid
        flo = fm
      }
      if hi - lo < tolerance { break }
    }
    return 0.5 * (lo + hi)
  }

  /// Golden-section search for the maximum of a unimodal `f` on [a, b].
  static func maximize(_ a: Double, _ b: Double, tolerance: Double = 1e-12, _ f: (Double) -> Double) -> Double {
    let g = (5.0.squareRoot() - 1) / 2
    var lo = a
    var hi = b
    var x1 = hi - g * (hi - lo)
    var x2 = lo + g * (hi - lo)
    var f1 = f(x1)
    var f2 = f(x2)
    for _ in 0..<200 where hi - lo > tolerance {
      if f1 < f2 {
        lo = x1
        x1 = x2
        f1 = f2
        x2 = lo + g * (hi - lo)
        f2 = f(x2)
      } else {
        hi = x2
        x2 = x1
        f2 = f1
        x1 = hi - g * (hi - lo)
        f1 = f(x1)
      }
    }
    return 0.5 * (lo + hi)
  }
}
