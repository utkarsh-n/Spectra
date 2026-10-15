import Foundation

nonisolated extension Matter {
  /// A complex number with exactly the spectra-lab `matter.js` arithmetic: naive division
  /// (no Smith scaling) and the JS `csqrt` sign rule. Nested in `Matter` so it cannot clash
  /// with any other module's `Complex`.
  struct Complex: Hashable, Sendable, Codable {
    var re: Double
    var im: Double

    init(_ re: Double, _ im: Double = 0) {
      self.re = re
      self.im = im
    }

    static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }

    /// JS `cdiv`: d = b.re² + b.im², then ((a.re·b.re + a.im·b.im)/d, (a.im·b.re − a.re·b.im)/d).
    /// Safe in range: ω ≤ 1.9e22 rad/s keeps d ≈ 1e89, far from overflow.
    static func / (a: Complex, b: Complex) -> Complex {
      let d = b.re * b.re + b.im * b.im
      return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }

    /// Principal square root, JS `csqrt`: r = |z| (V8's hypot), re = √max(0, (r + re)/2),
    /// im = sign(im || 1)·√max(0, (r − re)/2). A ±0 or NaN imaginary part counts as +1.
    static func sqrt(_ z: Complex) -> Complex {
      let r = JSMath.hypot(z.re, z.im)
      let re = JSMath.max(0, (r + z.re) / 2).squareRoot()
      let s = z.im == 0 || z.im.isNaN ? 1 : JSMath.sign(z.im)
      let im = s * JSMath.max(0, (r - z.re) / 2).squareRoot()
      return Complex(re, im)
    }
  }
}
