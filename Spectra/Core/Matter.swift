import Foundation

/// A log-log interpolation table: knots `xs` (ascending; a repeated x marks a step such as an
/// absorption edge) and values `ys`.
nonisolated struct LogLogTable: Hashable, Sendable {
  let xs: [Double]
  let ys: [Double]

  init(xs: [Double], ys: [Double]) {
    precondition(xs.count == ys.count && !xs.isEmpty, "LogLogTable needs matching, non-empty columns")
    self.xs = xs
    self.ys = ys
  }

  /// From flattened pairs `[x0, y0, x1, y1, …]` (the generated table format).
  init(flat: [Double]) {
    precondition(flat.count >= 2 && flat.count % 2 == 0, "LogLogTable(flat:) needs x, y pairs")
    self.init(xs: stride(from: 0, to: flat.count, by: 2).map { flat[$0] },
              ys: stride(from: 1, to: flat.count, by: 2).map { flat[$0] })
  }

  /// From `(x, y)` rows.
  init(rows: [(Double, Double)]) {
    self.init(xs: rows.map(\.0), ys: rows.map(\.1))
  }

  var count: Int { xs.count }
}

/// How matter answers a wave (port of spectra-lab `core/matter.js`): table lookups (NIST XCOM,
/// Segelstein water), the Lorentz/Drude oscillator, refractive indices of the medium dial,
/// slab transmission and smooth anchor curves.
///
/// Two kinds of numbers come out: TABLE (interpolated measured data) and MODEL (oscillator
/// physics or a smooth curve through published anchor values); see `CoreProvenance`.
nonisolated enum Matter {
  // MARK: Interpolation

  /// Log-log interpolation, JS `logLog` exactly (port-plan §7 Q1): nil outside
  /// [first x, last x] or for NaN; at an edge (repeated x) the upper value applies;
  /// u = ln(x/x0)/ln(x1/x0), y = exp(ln y0 + u·(ln y1 − ln y0)).
  static func logLog(_ t: LogLogTable, _ x: Double) -> Double? {
    let xs = t.xs, n = xs.count
    if !(x >= xs[0]) || x > xs[n - 1] { return nil }
    var i = 1
    while i < n - 1 && xs[i] < x { i += 1 }
    // At an edge (xs[i] == xs[i+1] == x) take the upper value.
    while i < n - 1 && xs[i + 1] == x { i += 1 }
    if n == 1 { return t.ys[0] }
    let x0 = xs[i - 1], y0 = t.ys[i - 1], x1 = xs[i], y1 = t.ys[i]
    if x1 == x0 { return y1 }
    let u = log(x / x0) / log(x1 / x0)
    return exp(log(y0) + u * (log(y1) - log(y0)))
  }

  // MARK: Reference tables

  /// Lowest XCOM energy, eV.
  static let xcomMinEV: Double = 1e3
  /// Highest XCOM energy, eV.
  static let xcomMaxEV: Double = 2e7
  /// 1.24 nm. Uses the literal 1.239841984e-6, not `SI.hcEVm` (port-plan §7 Q4).
  static let xcomLambdaMax: Double = 1.239841984e-6 / xcomMinEV

  /// NIST mass attenuation μ/ρ, cm²/g, or nil outside 1 keV…20 MeV. Computed as
  /// `logLog(table, eV / 1e6)` (divide, do not multiply by 1e-6: edge hits depend on it).
  static func massAttenuation(_ m: XCOMMaterial, eV: Double) -> Double? { logLog(m.table, eV / 1e6) }

  /// Linear attenuation μ, 1/cm, at the material's default density unless given.
  static func linearAttenuation(_ m: XCOMMaterial, eV: Double, density: Double? = nil) -> Double? {
    guard let mu = massAttenuation(m, eV: eV) else { return nil }
    return mu * (density ?? m.density)
  }

  /// Liquid water absorption coefficient α, 1/cm (Segelstein 1981), or nil outside 10 nm…10 m.
  /// Computed as `logLog(table, lambda * 1e9)`.
  static func waterAbsorption(_ lambda: Double) -> Double? { logLog(SegelsteinWater.table, lambda * 1e9) }

  // MARK: Complex index

  /// Complex refractive index n + iκ.
  struct ComplexIndex: Hashable, Sendable {
    var n: Double
    var k: Double
  }

  /// n + iκ from relative permittivity (e^{−iωt} convention, absorbing: κ ≥ 0).
  static func index(fromEpsilon eps: Complex) -> ComplexIndex {
    let n = Complex.sqrt(eps)
    return ComplexIndex(n: n.re, k: abs(n.im))
  }

  /// Intensity absorption coefficient 4πκ/λ, 1/cm (λ in m).
  static func absorptionFromK(_ k: Double, lambda: Double) -> Double { (4 * Double.pi * k) / lambda / 100 }

  /// Normal-incidence reflectance ((n−1)² + κ²)/((n+1)² + κ²).
  static func normalReflectance(n: Double, k: Double = 0) -> Double {
    ((n - 1) * (n - 1) + k * k) / ((n + 1) * (n + 1) + k * k)
  }

  // MARK: The bound-charge (Lorentz) oscillator

  /// Response of a charge on a spring driven at ω: displacement relative to the static
  /// response, phase lag behind the field (degrees: 0 in step, 90 on resonance, 180 opposite),
  /// and absorbed power relative to the on-resonance power.
  struct OscillatorResponse: Hashable, Sendable {
    var amplitude: Double
    var lag: Double
    var power: Double
  }

  static func oscillatorResponse(omega: Double, omega0: Double, gamma: Double) -> OscillatorResponse {
    let re = omega0 * omega0 - omega * omega, im = gamma * omega
    let amplitude = (omega0 * omega0) / JSMath.hypot(re, im)
    let lag = (atan2(im, re) * 180) / Double.pi
    let power = (gamma * gamma * omega * omega) / (re * re + im * im)
    return OscillatorResponse(amplitude: amplitude, lag: lag, power: power)
  }

  /// One Lorentz term: resonance ω₀, plasma frequency ω_p, damping γ (rad/s).
  struct LorentzOscillator: Hashable, Sendable, Codable {
    var w0: Double
    var wp: Double
    var gamma: Double
  }

  /// ε = 1 + Σ ω_p²/(ω₀² − ω² − iγω).
  static func lorentzEpsilon(omega: Double, _ oscillators: [LorentzOscillator]) -> Complex {
    var eps = Complex(1, 0)
    for o in oscillators {
      let t = Complex(o.wp * o.wp, 0) / Complex(o.w0 * o.w0 - omega * omega, -o.gamma * omega)
      eps = Complex(eps.re + t.re, eps.im + t.im)
    }
    return eps
  }

  /// Free electrons (Drude): the oscillator with no spring.
  static func drudeEpsilon(omega: Double, wp: Double, gamma: Double) -> Complex {
    lorentzEpsilon(omega: omega, [LorentzOscillator(w0: 0, wp: wp, gamma: gamma)])
  }

  // MARK: Media (the medium dial)

  /// Refractive index of a medium at one wavelength; `valid` is false where the formula is a
  /// placeholder outside its fitted range.
  struct MediumIndex: Hashable, Sendable {
    var n: Double
    var k: Double
    var valid: Bool
  }

  /// The six media of the medium dial (JS `MEDIA`). Raw values are the JS keys.
  enum Medium: String, CaseIterable, Codable, Sendable, Identifiable {
    case vacuum, air, water, glass, silica, diamond
    var id: String { rawValue }

    var name: String {
      switch self {
      case .vacuum: "Vacuum"
      case .air: "Air"
      case .water: "Water"
      case .glass: "Glass (BK7)"
      case .silica: "Fused silica"
      case .diamond: "Diamond"
      }
    }

    /// Schott N-BK7 (0.3–2.5 µm, borosilicate εr ≈ 4.6 from 1 mm up); Malitson 1965 fused
    /// silica (0.21–3.7 µm); Peter 1923 diamond (0.225 µm+); water: Cauchy fit through
    /// n(400 nm) = 1.3435 and n(700 nm) = 1.3311 (0.2–1.1 µm), and single Debye relaxation at
    /// 25 °C below 1 THz (Kaatze 1989: εs 78.36, ε∞ 5.16, τ 8.27 ps).
    func index(_ l: Double) -> MediumIndex {
      switch self {
      case .vacuum:
        return MediumIndex(n: 1, k: 0, valid: true)
      case .air:
        return MediumIndex(n: 1.000293, k: 0, valid: l > 200e-9)
      case .water:
        if l >= 200e-9 && l <= 1.1e-6 {
          let nm = l * 1e9
          return MediumIndex(n: 1.3251 + 2946 / (nm * nm), k: 0, valid: true)
        }
        if l >= 0.3e-3 {
          let w = (Wave.tau * SI.c) / l, tau = 8.27e-12
          let eps = Complex(78.36 - 5.16, 0) / Complex(1, w * tau)
          let ix = Matter.index(fromEpsilon: Complex(5.16 + eps.re, -eps.im))
          return MediumIndex(n: ix.n, k: ix.k, valid: true)
        }
        return MediumIndex(n: 1.33, k: 0, valid: false)
      case .glass:
        let um = l * 1e6
        if um >= 0.3 && um <= 2.5 {
          return MediumIndex(
            n: Matter.sellmeier(um, [1.03961212, 0.231792344, 1.01046945], [0.00600069867, 0.0200179144, 103.560653]),
            k: 0, valid: true)
        }
        if l >= 1e-3 { return MediumIndex(n: (4.6 as Double).squareRoot(), k: 0, valid: true) }
        return MediumIndex(n: 1.5, k: 0, valid: false)
      case .silica:
        let um = l * 1e6
        if um >= 0.21 && um <= 3.7 {
          return MediumIndex(
            n: Matter.sellmeier(
              um, [0.6961663, 0.4079426, 0.8974794], [0.0684043 * 0.0684043, 0.1162414 * 0.1162414, 9.896161 * 9.896161]),
            k: 0, valid: true)
        }
        return MediumIndex(n: 1.46, k: 0, valid: false)
      case .diamond:
        let um = l * 1e6
        if um >= 0.225 {
          return MediumIndex(n: Matter.sellmeier(um, [4.3356, 0.3306], [0.106 * 0.106, 0.175 * 0.175]), k: 0, valid: um <= 1000)
        }
        return MediumIndex(n: 2.4, k: 0, valid: false)
      }
    }
  }

  /// n = √(1 + Σ Bᵢλ²/(λ² − Cᵢ)), λ in µm.
  static func sellmeier(_ lambdaUm: Double, _ b: [Double], _ c: [Double]) -> Double {
    let l2 = lambdaUm * lambdaUm
    var s = 0.0
    for i in b.indices { s = s + (b[i] * l2) / (l2 - c[i]) }
    return (1 + s).squareRoot()
  }

  // MARK: Metals

  /// Free-electron (Drude) parameters: electron density (1/m³), plasma frequency and damping
  /// (rad/s), and the plasma energy ħω_p/e (eV).
  struct FreeElectronMetal: Hashable, Sendable {
    var ne: Double
    var wp: Double
    var gamma: Double
    var plasmaEV: Double
  }

  /// From density (g/cm³), molar mass (g/mol), valence and DC conductivity (S/m).
  static func freeElectronMetal(density: Double, molarMass: Double, valence: Double, conductivity: Double) -> FreeElectronMetal {
    let ne = (valence * density * 1e3 * SI.nA) / (molarMass * 1e-3)
    let wp = ((ne * SI.e * SI.e) / (SI.eps0 * SI.me)).squareRoot()
    let tau = (conductivity * SI.me) / (ne * SI.e * SI.e)
    return FreeElectronMetal(ne: ne, wp: wp, gamma: 1 / tau, plasmaEV: (SI.hbar * wp) / SI.e)
  }

  /// Zinc: 7.134 g/cm³, 65.38 g/mol, valence 2, σ = 1.69e7 S/m.
  static let zinc = freeElectronMetal(density: 7.134, molarMass: 65.38, valence: 2, conductivity: 1.69e7)

  /// A photoelectric work function, eV (CRC Handbook, polycrystalline).
  struct WorkFunction: Hashable, Sendable {
    let metal: String
    let eV: Double
  }

  /// In the JS key order.
  static let workFunctions: [WorkFunction] = [
    WorkFunction(metal: "cesium", eV: 2.14), WorkFunction(metal: "potassium", eV: 2.3),
    WorkFunction(metal: "sodium", eV: 2.36), WorkFunction(metal: "zinc", eV: 4.33),
    WorkFunction(metal: "copper", eV: 4.65), WorkFunction(metal: "platinum", eV: 5.65),
  ]

  /// Zinc's work function, eV.
  static let zincWorkFunction: Double = 4.33

  // MARK: Slabs and smooth curves

  /// Transmitted, reflected and absorbed fractions (JS `{T, R, A}`).
  struct TRA: Hashable, Sendable {
    var t: Double
    var r: Double
    var a: Double
  }

  /// Incoherent slab with two identical faces of reflectance R, absorption α (1/cm) and
  /// thickness d (cm). A = max(0, 1 − T − R).
  static func slab(r: Double, alphaPerCm: Double, thicknessCm: Double) -> TRA {
    let a = exp(-alphaPerCm * thicknessCm)
    let q = (1 - r) * (1 - r)
    let t = (q * a) / (1 - r * r * a * a)
    let rt = r + (q * r * a * a) / (1 - r * r * a * a)
    return TRA(t: t, r: rt, a: JSMath.max(0, 1 - t - rt))
  }

  /// Smooth log-log curve through anchors [[λ m, value]], clamped to the end values outside
  /// (`λ ≤ first` → first value exactly, `λ ≥ last` → last value).
  static func anchors(_ t: LogLogTable, _ lambda: Double) -> Double {
    if lambda <= t.xs[0] { return t.ys[0] }
    if lambda >= t.xs[t.count - 1] { return t.ys[t.count - 1] }
    return logLog(t, lambda) ?? 0  // nil only for NaN; JS null coerces to 0 in arithmetic
  }

  /// Log-log line through (λa, va) and (λb, vb), extrapolating (no clamp). Bridges the end of
  /// an optical table to the start of NIST data (10 nm … 1.24 nm).
  static func bridge(_ lambda: Double, _ lambdaA: Double, _ valueA: Double, _ lambdaB: Double, _ valueB: Double) -> Double {
    let u = log(lambda / lambdaA) / log(lambdaB / lambdaA)
    return exp(log(valueA) + u * (log(valueB) - log(valueA)))
  }
}
