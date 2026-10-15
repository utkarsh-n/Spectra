import Foundation

// Dispersion relations ω(k) for the phase-space views (wigner-spacetime.md rule 6: a free field's
// (k, ν) marginal lives on ν = ω(k)/2π). Media come from Core (`Matter.Medium.index`, the same
// Sellmeier/Cauchy/Debye fits as the Matter bench); absorption (the imaginary index) is ignored.

nonisolated extension Phase {
  enum Dispersion: Sendable, Hashable, Codable {
    /// ω = c|k| (the light line).
    case vacuum
    /// k = n(λ)·ω/c with Core's index of refraction (glass, water, silica, diamond, air).
    case medium(Matter.Medium)
    /// Cold plasma ω² = ω_p² + c²k² (the ionosphere: f_p ≈ 1–15 MHz), plasma frequency in Hz.
    case plasma(plasmaFrequency: Double)
    /// Hollow waveguide ω² = ω_c² + c²k², cut-off frequency in Hz.
    case waveguide(cutoffFrequency: Double)
    /// ω = ω₀ + v_g(k − k₀) + ½·D·(k − k₀)²: the linear (D = 0) or quadratic model around a
    /// carrier (closed-form oracles, Fresnel/Schrödinger analogues).
    case taylor(Taylor)

    struct Taylor: Sendable, Hashable, Codable {
      var k0: Double
      var omega0: Double
      var groupVelocity: Double
      /// d²ω/dk² (group-velocity dispersion of ω(k)).
      var gvd: Double

      init(k0: Double, omega0: Double, groupVelocity: Double, gvd: Double = 0) {
        self.k0 = k0
        self.omega0 = omega0
        self.groupVelocity = groupVelocity
        self.gvd = gvd
      }

      func omega(_ k: Double) -> Double {
        let d = k - k0
        return omega0 + groupVelocity * d + 0.5 * gvd * d * d
      }
    }

    var title: String {
      switch self {
      case .vacuum: "Vacuum"
      case .medium(let m): m.name
      case .plasma: "Plasma (ionosphere)"
      case .waveguide: "Waveguide"
      case .taylor(let t): t.gvd == 0 ? "Linear dispersion" : "Quadratic dispersion"
      }
    }

    /// The relation as shown next to the overlay.
    var formula: String {
      switch self {
      case .vacuum: "ω = c|k|"
      case .medium: "k = n(λ) ω / c"
      case .plasma: "ω² = ω_p² + c²k²"
      case .waveguide: "ω² = ω_c² + c²k²"
      case .taylor: "ω = ω₀ + v_g (k − k₀) + ½ D (k − k₀)²"
      }
    }

    /// True when ω(−k) = ω(k).
    var isIsotropic: Bool {
      if case .taylor = self { return false }
      return true
    }

    /// ω(k) ≥ 0 in rad/s for a real k (nil when the model has no propagating solution).
    func angularFrequency(wavenumber k: Double) -> Double? {
      guard k.isFinite else { return nil }
      let c = SI.c
      switch self {
      case .vacuum:
        return c * abs(k)
      case .plasma(let fp):
        let wp = 2 * Double.pi * fp
        return (wp * wp + c * c * k * k).squareRoot()
      case .waveguide(let fc):
        let wc = 2 * Double.pi * fc
        return (wc * wc + c * c * k * k).squareRoot()
      case .taylor(let t):
        let w = t.omega(k)
        return w >= 0 ? w : nil
      case .medium(let m):
        return Self.mediumOmega(m, k: abs(k))
      }
    }

    /// ν(k) = ω/2π in Hz.
    func frequency(wavenumber k: Double) -> Double? { angularFrequency(wavenumber: k).map { $0 / (2 * Double.pi) } }

    /// k(ν) ≥ 0 in rad/m on the forward branch (nil: below cut-off or no solution).
    func wavenumber(frequency nu: Double) -> Double? {
      guard nu.isFinite, nu >= 0 else { return nil }
      let c = SI.c
      let w = 2 * Double.pi * nu
      switch self {
      case .vacuum:
        return w / c
      case .plasma(let fp):
        guard nu >= fp else { return nil }
        let wp = 2 * Double.pi * fp
        return (w * w - wp * wp).squareRoot() / c
      case .waveguide(let fc):
        guard nu >= fc else { return nil }
        let wc = 2 * Double.pi * fc
        return (w * w - wc * wc).squareRoot() / c
      case .medium(let m):
        guard nu > 0 else { return 0 }
        return w * m.index(c / nu).n / c
      case .taylor(let t):
        let d0 = w - t.omega0
        if t.gvd == 0 {
          guard t.groupVelocity != 0 else { return nil }
          return t.k0 + d0 / t.groupVelocity
        }
        let disc = t.groupVelocity * t.groupVelocity + 2 * t.gvd * d0
        guard disc >= 0 else { return nil }
        let root = (disc.squareRoot() - abs(t.groupVelocity)) / t.gvd
        return t.k0 + (t.groupVelocity >= 0 ? root : -root)
      }
    }

    /// Effective index c·k/ω at ν, and whether the model is valid there (Core's table ranges;
    /// below cut-off returns n = 0, invalid).
    func refractiveIndex(frequency nu: Double) -> (n: Double, valid: Bool) {
      switch self {
      case .medium(let m):
        let ix = m.index(SI.c / nu)
        return (ix.n, ix.valid)
      default:
        guard let k = wavenumber(frequency: nu), nu > 0 else { return (0, false) }
        return (SI.c * k / (2 * Double.pi * nu), true)
      }
    }

    /// True when the model is valid at ν (Core's fitted ranges for media; above cut-off).
    func isValid(frequency nu: Double) -> Bool {
      switch self {
      case .medium(let m): m.index(SI.c / nu).valid
      default: wavenumber(frequency: nu) != nil
      }
    }

    /// Group velocity dω/dk at ν (m/s).
    func groupVelocity(frequency nu: Double) -> Double? {
      let c = SI.c
      switch self {
      case .vacuum:
        return c
      case .plasma, .waveguide:
        guard let k = wavenumber(frequency: nu), nu > 0 else { return nil }
        return c * c * k / (2 * Double.pi * nu)
      case .taylor(let t):
        guard let k = wavenumber(frequency: nu) else { return nil }
        return t.groupVelocity + t.gvd * (k - t.k0)
      case .medium:
        let h = nu * 1e-5
        guard let k1 = wavenumber(frequency: nu + h), let k0 = wavenumber(frequency: nu - h), k1 != k0 else { return nil }
        return 2 * Double.pi * 2 * h / (k1 - k0)
      }
    }

    /// Phase velocity ω/k at ν (m/s).
    func phaseVelocity(frequency nu: Double) -> Double? {
      guard let k = wavenumber(frequency: nu), k != 0 else { return nil }
      return 2 * Double.pi * nu / k
    }

    /// The Taylor model of this relation around the carrier ν₀ on the ±k branch (vacuum, plasma
    /// and waveguide in closed form; media by finite differences).
    func taylor(atFrequency nu0: Double, direction: Int = 1) -> Taylor? {
      guard let kk = wavenumber(frequency: nu0) else { return nil }
      let s: Double = direction >= 0 ? 1 : -1
      let k0 = s * kk
      let w0 = 2 * Double.pi * nu0
      let c = SI.c
      switch self {
      case .vacuum:
        return Taylor(k0: k0, omega0: w0, groupVelocity: s * c, gvd: 0)
      case .plasma(let f), .waveguide(let f):
        let wp = 2 * Double.pi * f
        return Taylor(k0: k0, omega0: w0, groupVelocity: c * c * k0 / w0, gvd: c * c * wp * wp / (w0 * w0 * w0))
      case .taylor(let t):
        return t
      case .medium:
        guard let vg = groupVelocity(frequency: nu0) else { return nil }
        let dk = max(abs(k0) * 1e-4, 1e-12)
        guard let wp = angularFrequency(wavenumber: k0 + dk), let wm = angularFrequency(wavenumber: k0 - dk) else {
          return Taylor(k0: k0, omega0: w0, groupVelocity: s * vg, gvd: 0)
        }
        return Taylor(k0: k0, omega0: w0, groupVelocity: s * vg, gvd: (wp - 2 * w0 + wm) / (dk * dk))
      }
    }

    /// Points (k, ν) of the shell for the overlay, k in rad/m over `kRange`. Points where the
    /// model has no solution are left out; `valid` marks Core's fitted range.
    func shell(kRange: ClosedRange<Double>, count: Int) -> [ShellPoint] {
      let n = max(2, count)
      var out: [ShellPoint] = []
      out.reserveCapacity(n)
      for i in 0..<n {
        let k = kRange.lowerBound + (kRange.upperBound - kRange.lowerBound) * Double(i) / Double(n - 1)
        guard let nu = frequency(wavenumber: k) else { continue }
        out.append(ShellPoint(k: k, nu: nu, valid: isValid(frequency: nu)))
      }
      return out
    }

    /// Solves 2πν·n(c/ν)/c = k for ν (fixed point on ν = ck/(2πn), then bisection if it stalls).
    static func mediumOmega(_ m: Matter.Medium, k: Double) -> Double? {
      let c = SI.c
      if k == 0 { return 0 }
      let nuVac = c * k / (2 * Double.pi)
      func residual(_ nu: Double) -> Double { 2 * Double.pi * nu * m.index(c / nu).n / c - k }
      var nu = nuVac / max(m.index(c / nuVac).n, 1e-6)
      for _ in 0..<60 {
        let next = nuVac / max(m.index(c / nu).n, 1e-6)
        if abs(next - nu) <= 1e-15 * nu {
          nu = next
          return 2 * Double.pi * nu
        }
        nu = next
      }
      if abs(residual(nu)) <= 1e-12 * k { return 2 * Double.pi * nu }
      var lo = nuVac / 50
      var hi = nuVac * 2
      guard residual(lo) < 0, residual(hi) > 0 else { return nil }
      for _ in 0..<200 {
        let mid = 0.5 * (lo + hi)
        if residual(mid) < 0 { lo = mid } else { hi = mid }
        if hi - lo <= 1e-15 * hi { break }
      }
      return 2 * Double.pi * 0.5 * (lo + hi)
    }
  }

  struct ShellPoint: Sendable, Hashable, Codable {
    var k: Double
    var nu: Double
    var valid: Bool
  }

  /// Display units: lengths in the reference vacuum wavelength λ_ref = c/ν_ref, times in the
  /// reference period T_ref = 1/ν_ref, so x̂ = x/λ_ref, t̂ = t/T_ref, k̂ = k·λ_ref (rad per λ_ref),
  /// ν̂ = ν/ν_ref. Speeds come out in units of c. The same packet picture then works for any band
  /// (radio to gamma) — only the axis labels change.
  struct DisplayUnits: Sendable, Hashable, Codable {
    var referenceFrequency: Double

    init(referenceFrequency: Double) { self.referenceFrequency = referenceFrequency }
    init(referenceWavelength lambda: Double) { referenceFrequency = SI.c / lambda }

    var wavelength: Double { SI.c / referenceFrequency }
    var period: Double { 1 / referenceFrequency }

    func length(_ metres: Double) -> Double { metres / wavelength }
    func time(_ seconds: Double) -> Double { seconds * referenceFrequency }
    func wavenumber(_ radPerMetre: Double) -> Double { radPerMetre * wavelength }
    func frequency(_ hertz: Double) -> Double { hertz / referenceFrequency }

    func metres(_ x: Double) -> Double { x * wavelength }
    func seconds(_ t: Double) -> Double { t / referenceFrequency }
    func radPerMetre(_ k: Double) -> Double { k / wavelength }
    func hertz(_ nu: Double) -> Double { nu * referenceFrequency }
  }

  /// A dispersion relation expressed in the units of a field: SI (`units == nil`) or display units.
  struct ShellModel: Sendable, Hashable, Codable {
    var dispersion: Dispersion
    var units: DisplayUnits?

    init(_ dispersion: Dispersion, units: DisplayUnits? = nil) {
      self.dispersion = dispersion
      self.units = units
    }

    /// ω(k) in rad per time unit.
    func omega(_ k: Double) -> Double? {
      guard let u = units else { return dispersion.angularFrequency(wavenumber: k) }
      return dispersion.frequency(wavenumber: u.radPerMetre(k)).map { 2 * Double.pi * u.frequency($0) }
    }

    /// ν(k) in the frequency unit.
    func frequency(_ k: Double) -> Double? { omega(k).map { $0 / (2 * Double.pi) } }

    /// k(ν) ≥ 0 in the wavenumber unit.
    func wavenumber(_ nu: Double) -> Double? {
      guard let u = units else { return dispersion.wavenumber(frequency: nu) }
      return dispersion.wavenumber(frequency: u.hertz(nu)).map { u.wavenumber($0) }
    }

    /// Group velocity in length units per time unit (units of c in display units).
    func groupVelocity(_ nu: Double) -> Double? {
      guard let u = units else { return dispersion.groupVelocity(frequency: nu) }
      return dispersion.groupVelocity(frequency: u.hertz(nu)).map { $0 / SI.c }
    }

    /// The Taylor model around ν₀ in these units.
    func taylor(atFrequency nu0: Double, direction: Int = 1) -> Dispersion.Taylor? {
      guard let u = units else { return dispersion.taylor(atFrequency: nu0, direction: direction) }
      guard let t = dispersion.taylor(atFrequency: u.hertz(nu0), direction: direction) else { return nil }
      // ω̂ = ω·T_ref, k̂ = k·λ_ref, v̂ = v/c, D̂ = D·T_ref/λ_ref².
      return Dispersion.Taylor(
        k0: u.wavenumber(t.k0), omega0: t.omega0 * u.period, groupVelocity: t.groupVelocity / SI.c,
        gvd: t.gvd * u.period / (u.wavelength * u.wavelength))
    }

    /// The shell in these units over a k range.
    func shell(kRange: ClosedRange<Double>, count: Int) -> [ShellPoint] {
      let n = max(2, count)
      var out: [ShellPoint] = []
      for i in 0..<n {
        let k = kRange.lowerBound + (kRange.upperBound - kRange.lowerBound) * Double(i) / Double(n - 1)
        guard let nu = frequency(k) else { continue }
        let valid = dispersion.isValid(frequency: units.map { $0.hertz(nu) } ?? nu)
        out.append(ShellPoint(k: k, nu: nu, valid: valid))
      }
      return out
    }
  }
}
