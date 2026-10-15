import Foundation

// MARK: - 3GPP TR 38.901 V19.5.0 O2I penetration (rf-physics B.9)

nonisolated extension RF.Building {
  /// Materials of TR 38.901 Table 7.4.3-1 (Release 19 IRR glass), loss in dB with f in GHz.
  enum Material: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// Standard multi-pane glass: 2 + 0.2f.
    case glass
    /// Infrared-reflective (coated) glass: 25.4 + 0.11f (Rel-19; older releases 23 + 0.3f).
    case irrGlass
    /// Concrete: 5 + 4f.
    case concrete
    /// Plywood: 1.03 + 0.17f.
    case plywood
    /// Wood: 4.85 + 0.12f.
    case wood

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .glass: "Glass"
      case .irrGlass: "IRR glass"
      case .concrete: "Concrete"
      case .plywood: "Plywood"
      case .wood: "Wood"
      }
    }

    /// Penetration loss through one layer, dB.
    func lossDB(frequencyGHz f: Double) -> Double {
      switch self {
      case .glass: 2 + 0.2 * f
      case .irrGlass: 25.4 + 0.11 * f
      case .concrete: 5 + 4 * f
      case .plywood: 1.03 + 0.17 * f
      case .wood: 4.85 + 0.12 * f
      }
    }
  }

  /// Wall models of TR 38.901 Table 7.4.3-2.
  enum O2IModel: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// 30 % glass, 70 % concrete; σ_P 4.4 dB.
    case lowLoss
    /// 70 % IRR glass, 30 % concrete; σ_P 6.5 dB.
    case highLoss
    /// 30 % glass, 70 % plywood ("low-loss A"); σ_P 4.4 dB.
    case lowLossA

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .lowLoss: "Low-loss (glass + concrete)"
      case .highLoss: "High-loss (IRR glass + concrete)"
      case .lowLossA: "Low-loss A (glass + plywood)"
      }
    }

    /// Standard deviation σ_P of the penetration loss, dB.
    var sigmaDB: Double { self == .highLoss ? 6.5 : 4.4 }

    /// Through-wall loss PL_tw = 5 − 10·log10(Σ p_i·10^{−L_i/10}) (3.5 GHz: 12.6975 dB low,
    /// 27.4993 dB high; 28 GHz: 17.8288 / 35.0290 dB).
    func wallLossDB(frequencyGHz f: Double) -> Double {
      let mix: [(Double, Material)]
      switch self {
      case .lowLoss: mix = [(0.3, .glass), (0.7, .concrete)]
      case .highLoss: mix = [(0.7, .irrGlass), (0.3, .concrete)]
      case .lowLossA: mix = [(0.3, .glass), (0.7, .plywood)]
      }
      let s = mix.reduce(0.0) { $0 + $1.0 * pow(10, -$1.1.lossDB(frequencyGHz: f) / 10) }
      return 5 - 10 * log10(s)
    }
  }

  /// Indoor loss PL_in = 0.5·d_2D-in dB (d in m).
  static func indoorLossDB(indoorDistance d: Double) -> Double { 0.5 * d }

  /// Sum of per-layer material losses for a list of walls (the Link page's "walls" stack).
  static func wallsLossDB(_ walls: [(material: Material, count: Int)], frequencyGHz f: Double) -> Double {
    walls.reduce(0.0) { $0 + Double(max(0, $1.count)) * $1.material.lossDB(frequencyGHz: f) }
  }
}

// MARK: - ITU-R P.2109-2 building entry loss (rf-physics B.9)

nonisolated extension RF.Building {
  /// Frequency range of ITU-R P.2109-2, GHz.
  static let entryLossValidGHz: ClosedRange<Double> = 0.08...100

  /// Building classes of P.2109-2 Table 1.
  enum BuildingClass: String, CaseIterable, Codable, Hashable, Sendable {
    case traditional, thermallyEfficient

    var displayName: String { self == .traditional ? "Traditional" : "Thermally efficient" }

    /// (r, s, t, u, v, w, x, y, z).
    fileprivate var coefficients: [Double] {
      switch self {
      case .traditional: [12.64, 3.72, 0.96, 9.6, 2.0, 9.1, -3.0, 4.5, -2.0]
      case .thermallyEfficient: [28.19, -3.00, 8.48, 13.5, 3.8, 27.8, -2.9, 9.4, -2.1]
      }
    }
  }

  /// Building entry loss not exceeded with probability P (0.08–100 GHz):
  /// L = 10·log10(10^{0.1A} + 10^{0.1B} + 10^{0.1C}), A = F⁻¹(P)σ₁ + μ₁, B = F⁻¹(P)σ₂ + μ₂, C = −3.
  /// Medians (P = 0.5, θ = 0): traditional 14.102 / 15.721 / 20.182 / 22.363 dB at
  /// 0.7 / 3.5 / 28 / 60 GHz; thermally efficient 31.576 / 30.886 / 41.676 / 49.676 dB.
  /// P.2109 defines 0 < P < 1; P is clamped to 10⁻⁶…1 − 10⁻⁶ (P = 1 would be an infinite loss;
  /// NaN reads as the median). The recommendation covers 0.08–100 GHz (`entryLossValidGHz`); f is
  /// clamped to that range (at f → 0 the log-frequency fits diverge) and θ to ±90°.
  static func entryLossDB(frequencyGHz fRaw: Double, probability pRaw: Double = 0.5, elevationDeg thetaRaw: Double = 0, building: BuildingClass) -> Double {
    let p = pRaw.isNaN ? 0.5 : min(max(pRaw, 1e-6), 1 - 1e-6)
    let f = fRaw.isNaN ? 1 : min(max(fRaw, entryLossValidGHz.lowerBound), entryLossValidGHz.upperBound)
    let theta = thetaRaw.isFinite ? min(max(thetaRaw, -90), 90) : 0
    let k = building.coefficients
    let lf = log10(f)
    let lh = k[0] + k[1] * lf + k[2] * lf * lf
    let le = 0.212 * abs(theta)
    let mu1 = lh + le
    let mu2 = k[5] + k[6] * lf
    let s1 = k[3] + k[4] * lf
    let s2 = k[7] + k[8] * lf
    let finv = RF.Special.inverseNormalCDF(p)
    let a = finv * s1 + mu1
    let b = finv * s2 + mu2
    let c = -3.0
    return 10 * log10(pow(10, 0.1 * a) + pow(10, 0.1 * b) + pow(10, 0.1 * c))
  }
}
