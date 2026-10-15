import Foundation

// MARK: - Gas absorption, ITU-R P.676-13 Annex 1 (rf-physics B.7)

nonisolated extension RF.Atmosphere {
  /// How the pressure argument is read. P.676 eq. (3) defines p as **dry** air pressure; the
  /// reference's worked values take 1013.25 hPa as **total** pressure (dry = total − e). The two
  /// differ by 0.12 dB/km at 60 GHz, so every caller states which one it means.
  enum PressureConvention: String, Codable, Hashable, Sendable {
    /// `pressure` is total pressure; dry pressure p = total − e (reference tables: 60 GHz → 14.656 dB/km).
    case total
    /// `pressure` is dry-air pressure p (60 GHz → 14.778 dB/km at 1013.25 hPa).
    case dry
  }

  /// Atmospheric state for gas absorption.
  struct AirState: Hashable, Codable, Sendable {
    /// Pressure in hPa (see `convention`).
    var pressure: Double
    /// Temperature in °C.
    var temperatureC: Double
    /// Water-vapour density ρ in g/m³.
    var waterVapourDensity: Double
    var convention: PressureConvention

    init(pressure: Double = 1013.25, temperatureC: Double = 15, waterVapourDensity: Double = 7.5, convention: PressureConvention = .total) {
      self.pressure = pressure
      self.temperatureC = temperatureC
      self.waterVapourDensity = waterVapourDensity
      self.convention = convention
    }

    /// The standard atmosphere of the reference: 1013.25 hPa total, 15 °C, 7.5 g/m³.
    static let standard = AirState()

    /// Water-vapour partial pressure e = ρT/216.7 hPa (T in kelvin).
    var vapourPressure: Double { waterVapourDensity * (temperatureC + 273.15) / 216.7 }
    /// Dry-air pressure p, hPa.
    var dryPressure: Double { convention == .total ? pressure - vapourPressure : pressure }
  }

  /// Specific attenuation (dB/km) split into oxygen (dry air incl. the Debye continuum) and
  /// water vapour, γ = 0.1820·f·N″(f) (eq. 1), line-by-line over P.676-13 Tables 1–2.
  /// Valid 1–1000 GHz. Reference (total-pressure convention, standard atmosphere):
  /// 60 GHz → 14.502 + 0.154 = 14.656 dB/km; 22.235 GHz → 0.1933 dB/km.
  static func gasSpecificAttenuation(frequencyGHz f: Double, air: AirState = .standard) -> (oxygen: Double, waterVapour: Double) {
    let tk = air.temperatureC + 273.15
    let th = 300 / tk
    let e = air.vapourPressure
    let p = air.dryPressure
    var no = 0.0
    for line in oxygenLines {
      let f0 = line[0]
      let s = line[1] * 1e-7 * p * th * th * th * exp(line[2] * (1 - th))
      var df = line[3] * 1e-4 * (p * pow(th, 0.8 - line[4]) + 1.1 * e * th)
      df = (df * df + 2.25e-6).squareRoot()
      let delta = (line[5] + line[6] * th) * 1e-4 * (p + e) * pow(th, 0.8)
      let shape = f / f0 * ((df - delta * (f0 - f)) / ((f0 - f) * (f0 - f) + df * df)
        + (df - delta * (f0 + f)) / ((f0 + f) * (f0 + f) + df * df))
      no += s * shape
    }
    // Dry continuum (eq. 8): Debye spectrum of oxygen plus pressure-induced nitrogen absorption.
    let d = 5.6e-4 * (p + e) * pow(th, 0.8)
    no += f * p * th * th * (6.14e-5 / (d * (1 + (f / d) * (f / d))) + 1.4e-12 * p * pow(th, 1.5) / (1 + 1.9e-5 * pow(f, 1.5)))
    var nw = 0.0
    for line in waterVapourLines {
      let f0 = line[0]
      let s = line[1] * 1e-1 * e * pow(th, 3.5) * exp(line[2] * (1 - th))
      var df = line[3] * 1e-4 * (p * pow(th, line[4]) + line[5] * e * pow(th, line[6]))
      df = 0.535 * df + (0.217 * df * df + 2.1316e-12 * f0 * f0 / th).squareRoot()
      let shape = f / f0 * (df / ((f0 - f) * (f0 - f) + df * df) + df / ((f0 + f) * (f0 + f) + df * df))
      nw += s * shape
    }
    return (0.1820 * f * no, 0.1820 * f * nw)
  }

  /// Total gas specific attenuation γ_o + γ_w in dB/km.
  static func gasAttenuationDBPerKm(frequencyGHz f: Double, air: AirState = .standard) -> Double {
    let g = gasSpecificAttenuation(frequencyGHz: f, air: air)
    return g.oxygen + g.waterVapour
  }

  /// Frequency range of P.676-13 Annex 1, GHz (below it the line-by-line sum still gives the
  /// small, physically sensible dry-air continuum).
  static let gasValidGHz: ClosedRange<Double> = 1...1000

  /// Gas loss over a horizontal (constant-air) path of `distance` metres, dB.
  static func gasLossDB(frequency: Double, distance: Double, air: AirState = .standard) -> Double {
    gasAttenuationDBPerKm(frequencyGHz: frequency / 1e9, air: air) * distance / 1000
  }
}

// MARK: - Rain, ITU-R P.838-3 (rf-physics B.8)

nonisolated extension RF.Atmosphere {
  /// P.838-3 coefficients k and α for horizontal and vertical polarization.
  struct RainCoefficients: Hashable, Sendable {
    var kH: Double
    var alphaH: Double
    var kV: Double
    var alphaV: Double

    /// k and α for a path at elevation θ with polarization tilt τ (eqs. 4–5; τ = 0 horizontal,
    /// 90° vertical, 45° circular):
    /// k = [k_H + k_V + (k_H − k_V)cos²θ·cos2τ]/2,
    /// α = [k_Hα_H + k_Vα_V + (k_Hα_H − k_Vα_V)cos²θ·cos2τ]/(2k).
    func combined(elevationDeg: Double, tiltDeg: Double) -> (k: Double, alpha: Double) {
      let c = pow(cos(elevationDeg * Double.pi / 180), 2) * cos(2 * tiltDeg * Double.pi / 180)
      let k = (kH + kV + (kH - kV) * c) / 2
      let alpha = (kH * alphaH + kV * alphaV + (kH * alphaH - kV * alphaV) * c) / (2 * k)
      return (k, alpha)
    }
  }

  /// Regression coefficients of P.838-3 Tables 1–4 (log10 k and α as sums of Gaussians in
  /// log10 f plus a linear term, eqs. 2–3). They reproduce every Table 5 row carried by the
  /// reference (28, 39, 60 GHz) to the printed digit — that is the test.
  private struct RainFit {
    let a: [Double]
    let b: [Double]
    let c: [Double]
    let m: Double
    let offset: Double

    func callAsFunction(_ logF: Double) -> Double {
      var s = m * logF + offset
      for j in a.indices { s += a[j] * exp(-pow((logF - b[j]) / c[j], 2)) }
      return s
    }
  }

  private static let rainKH = RainFit(
    a: [-5.33980, -0.35351, -0.23789, -0.94158], b: [-0.10008, 1.26970, 0.86036, 0.64552],
    c: [1.13098, 0.45400, 0.15354, 0.16817], m: -0.18961, offset: 0.71147)
  private static let rainKV = RainFit(
    a: [-3.80595, -3.44965, -0.39902, 0.50167], b: [0.56934, -0.22911, 0.73042, 1.07319],
    c: [0.81061, 0.51059, 0.11899, 0.27195], m: -0.16398, offset: 0.63297)
  private static let rainAlphaH = RainFit(
    a: [-0.14318, 0.29591, 0.32177, -5.37610, 16.1721], b: [1.82442, 0.77564, 0.63773, -0.96230, -3.29980],
    c: [-0.55187, 0.19822, 0.13164, 1.47828, 3.43990], m: 0.67849, offset: -1.95537)
  private static let rainAlphaV = RainFit(
    a: [-0.07771, 0.56727, -0.20238, -48.2991, 48.5833], b: [2.33840, 0.95545, 1.14520, 0.791669, 0.791459],
    c: [-0.76284, 0.54039, 0.26809, 0.116226, 0.116479], m: -0.053739, offset: 0.83433)

  /// Frequency range of the P.838-3 regressions, GHz.
  static let rainValidGHz: ClosedRange<Double> = 1...1000

  /// k_H, α_H, k_V, α_V at f GHz. 28 GHz → 0.2051, 0.9679, 0.1964, 0.9277. The regressions are
  /// defined for 1–1000 GHz only and blow up outside it (at 100 MHz they would give 21 dB/km at
  /// 25 mm/h, at 13.56 MHz 10⁹ dB/km), so f is clamped to that range. Below 1 GHz the 1 GHz
  /// coefficients are used: an upper bound (rain loss keeps falling with frequency) of
  /// 0.0023 dB/km at 100 mm/h.
  static func rainCoefficients(frequencyGHz f: Double) -> RainCoefficients {
    let lf = log10(min(max(f, rainValidGHz.lowerBound), rainValidGHz.upperBound))
    return RainCoefficients(kH: pow(10, rainKH(lf)), alphaH: rainAlphaH(lf), kV: pow(10, rainKV(lf)), alphaV: rainAlphaV(lf))
  }

  /// Rain specific attenuation γ_R = k·R^α dB/km (R in mm/h). Horizontal at 25 mm/h:
  /// 4.6241 / 7.0310 / 10.1173 dB/km at 28 / 39 / 60 GHz.
  static func rainAttenuationDBPerKm(frequencyGHz f: Double, rainRate r: Double, elevationDeg: Double = 0, tiltDeg: Double = 0) -> Double {
    guard r > 0 else { return 0 }
    let (k, alpha) = rainCoefficients(frequencyGHz: f).combined(elevationDeg: elevationDeg, tiltDeg: tiltDeg)
    return k * pow(r, alpha)
  }

  /// Rain loss over a path fully inside uniform rain (no path-reduction factor), dB.
  static func rainLossDB(frequency: Double, rainRate r: Double, distance: Double, tiltDeg: Double = 0) -> Double {
    rainAttenuationDBPerKm(frequencyGHz: frequency / 1e9, rainRate: r, tiltDeg: tiltDeg) * distance / 1000
  }

  /// Named rain rates for UI detents (mm/h).
  static let rainPresets: [(name: String, rate: Double)] = [
    ("Drizzle", 1), ("Moderate", 5), ("Heavy", 25), ("Downpour", 50), ("Tropical", 100),
  ]
}
