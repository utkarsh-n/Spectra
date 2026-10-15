import Foundation

// MARK: - Free space and Friis (rf-physics A.14, B.1)

nonisolated extension RF.Propagation {
  /// Free-space path loss 20·log10(4πd/λ) = 20·log10 d + 20·log10 f − 147.552 2168 dB
  /// (ITU-R P.525-5 eq. 5; d in m, f in Hz). 1 km at 1 GHz → 92.4478 dB.
  static func fsplDB(distance d: Double, frequency f: Double) -> Double {
    20 * log10(d) + 20 * log10(f) + RF.Const.fsplConstantDB
  }

  /// P.525 eq. (6) with its rounded constant: 32.4 + 20·log10 f_MHz + 20·log10 d_km.
  static func fsplP525RoundedDB(distanceKm d: Double, frequencyMHz f: Double) -> Double {
    32.4 + 20 * log10(f) + 20 * log10(d)
  }

  /// Distance (m) at which the free-space loss equals `lossDB`.
  static func freeSpaceDistance(lossDB: Double, frequency f: Double) -> Double {
    pow(10, (lossDB - 20 * log10(f) - RF.Const.fsplConstantDB) / 20)
  }

  /// Friis received power P_r = P_t + G_t + G_r − FSPL (dBm; 20 dBm, 0/0 dBi, 2.45 GHz, 10 m
  /// → −40.2311 dBm).
  static func friisReceivedPowerDBm(
    txPowerDBm pt: Double, txGainDBi gt: Double, rxGainDBi gr: Double, distance d: Double, frequency f: Double
  ) -> Double {
    pt + gt + gr - fsplDB(distance: d, frequency: f)
  }
}

// MARK: - Log-distance (rf-physics B.2)

nonisolated extension RF.Propagation {
  /// PL(d) = PL(d₀) + 10·n·log10(d/d₀) (+ X_σ drawn separately). With PL(d₀) = FSPL at
  /// d₀ = 1 m, 2.4 GHz, n = 3, 20 m → 79.0829 dB.
  static func logDistanceDB(distance d: Double, referenceDistance d0: Double, referenceLossDB pl0: Double, exponent n: Double) -> Double {
    pl0 + 10 * n * log10(d / d0)
  }

  /// Log-distance loss with PL(d₀) taken as the free-space loss at d₀.
  static func logDistanceDB(distance d: Double, frequency f: Double, exponent n: Double, referenceDistance d0: Double = 1) -> Double {
    logDistanceDB(distance: d, referenceDistance: d0, referenceLossDB: fsplDB(distance: d0, frequency: f), exponent: n)
  }

  /// Inverts the log-distance model: the distance at which the loss equals `lossDB`.
  /// Used by the Link page's "Live check" to turn a BLE RSSI into a distance.
  static func logDistanceRange(lossDB: Double, referenceDistance d0: Double, referenceLossDB pl0: Double, exponent n: Double) -> Double {
    d0 * pow(10, (lossDB - pl0) / (10 * n))
  }

  /// Distance from an RSSI with a known 1 m reference RSSI (the BLE "measured power"
  /// convention): d = 10^((RSSI₁ₘ − RSSI)/(10n)).
  static func distanceFromRSSI(rssiDBm: Double, rssiAt1mDBm: Double, exponent n: Double) -> Double {
    pow(10, (rssiAt1mDBm - rssiDBm) / (10 * n))
  }

  /// One zero-mean Gaussian shadowing draw X_σ (dB).
  static func shadowingDB(sigma: Double, rng: inout RF.SeededRandom) -> Double { sigma * rng.gaussian() }

  /// Measured or textbook path-loss exponents and shadowing spreads (rf-physics B.2).
  struct LogDistanceEnvironment: Hashable, Codable, Sendable, Identifiable {
    var id: String
    var name: String
    /// Exponent range n.
    var exponent: ClosedRange<Double>
    /// Shadowing standard deviation range σ (dB), when the source gives one.
    var sigma: ClosedRange<Double>?
    /// Frequency of the measurement, Hz, when the source gives one.
    var frequency: Double?
    /// Short citation.
    var source: String

    /// Mid-range exponent.
    var typicalExponent: Double { (exponent.lowerBound + exponent.upperBound) / 2 }

    /// Andersen/Rappaport/Yoshida 1995 Table 2 rows and Rappaport Table 4.2 ranges.
    static let all: [LogDistanceEnvironment] = [
      .init(id: "free", name: "Free space", exponent: 2...2, sigma: nil, frequency: nil, source: "Friis"),
      .init(id: "officeHard", name: "Office, hard partitions", exponent: 3...3, sigma: 7...7, frequency: 1.5e9, source: "Andersen 1995 Table 2"),
      .init(id: "factoryLOS", name: "Factory, line of sight", exponent: 1.6...2.0, sigma: 3...6, frequency: 1.3e9, source: "Andersen 1995 Table 2"),
      .init(id: "urbanCellular", name: "Urban cellular", exponent: 2.7...3.5, sigma: nil, frequency: nil, source: "Rappaport Table 4.2 [S]"),
      .init(id: "shadowedUrban", name: "Shadowed urban", exponent: 3...5, sigma: nil, frequency: nil, source: "Rappaport Table 4.2 [S]"),
      .init(id: "inBuildingLOS", name: "In building, line of sight", exponent: 1.6...1.8, sigma: nil, frequency: nil, source: "Rappaport Table 4.2 [S]"),
      .init(id: "obstructedBuilding", name: "Obstructed in building", exponent: 4...6, sigma: nil, frequency: nil, source: "Rappaport Table 4.2 [S]"),
      .init(id: "obstructedFactory", name: "Obstructed in factory", exponent: 2...3, sigma: nil, frequency: nil, source: "Rappaport Table 4.2 [S]"),
    ]
  }
}

// MARK: - 3GPP TR 38.901 V19.5.0 (rf-physics B.3)

nonisolated extension RF.Propagation {
  /// The TR 38.901 path-loss formulas the verified reference carries (f_c in GHz, d₃D in m).
  enum TR38901: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// InH-Office LOS: 32.4 + 17.3·log d + 20·log f, σ 3 dB, 1–150 m.
    case indoorOfficeLOS
    /// InH-Office NLOS: max(LOS, 38.3·log d + 17.30 + 24.9·log f), σ 8.03 dB.
    case indoorOfficeNLOS
    /// UMa NLOS (optional model): 32.4 + 20·log f + 30·log d, σ 7.8 dB.
    case urbanMacroNLOS
    /// UMi-Street Canyon NLOS (optional model): 32.4 + 20·log f + 31.9·log d, σ 8.2 dB.
    case urbanMicroNLOS

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .indoorOfficeLOS: "Indoor office (LOS)"
      case .indoorOfficeNLOS: "Indoor office (NLOS)"
      case .urbanMacroNLOS: "Urban macro (NLOS)"
      case .urbanMicroNLOS: "Urban micro street canyon (NLOS)"
      }
    }

    /// Shadow-fading standard deviation σ_SF, dB.
    var shadowSigmaDB: Double {
      switch self {
      case .indoorOfficeLOS: 3
      case .indoorOfficeNLOS: 8.03
      case .urbanMacroNLOS: 7.8
      case .urbanMicroNLOS: 8.2
      }
    }

    /// Median path loss in dB (InH 5.5 GHz 10 m: LOS 64.5073, NLOS 74.0350; UMa NLOS 3.5 GHz
    /// 500 m: 124.2505; UMi NLOS 28 GHz 200 m: 134.7460).
    func pathLossDB(distance3D d: Double, frequencyGHz f: Double) -> Double {
      let ld = log10(d)
      let lf = log10(f)
      switch self {
      case .indoorOfficeLOS:
        return 32.4 + 17.3 * ld + 20 * lf
      case .indoorOfficeNLOS:
        return max(32.4 + 17.3 * ld + 20 * lf, 38.3 * ld + 17.30 + 24.9 * lf)
      case .urbanMacroNLOS:
        return 32.4 + 20 * lf + 30 * ld
      case .urbanMicroNLOS:
        return 32.4 + 20 * lf + 31.9 * ld
      }
    }

    /// Distance range over which the reference states the model applies (InH 1–150 m).
    var validDistance: ClosedRange<Double>? {
      switch self {
      case .indoorOfficeLOS, .indoorOfficeNLOS: 1...150
      case .urbanMacroNLOS, .urbanMicroNLOS: nil
      }
    }
  }
}

// MARK: - Two-ray ground reflection (rf-physics B.4)

nonisolated extension RF.Propagation {
  /// Direct ray plus one ground reflection with coefficient Γ (−1 at grazing incidence).
  struct TwoRay: Hashable, Sendable {
    var txHeight: Double
    var rxHeight: Double
    var frequency: Double
    var reflection: RF.Complex = RF.Complex(-1)

    init(txHeight: Double, rxHeight: Double, frequency: Double, reflection: RF.Complex = RF.Complex(-1)) {
      self.txHeight = txHeight
      self.rxHeight = rxHeight
      self.frequency = frequency
      self.reflection = reflection
    }

    var wavelength: Double { RF.Const.c / frequency }

    /// Exact loss −20·log10[(λ/4π)·|e^{−jkd₁}/d₁ + Γe^{−jkd₂}/d₂|] for isotropic antennas
    /// (h 30/1.5 m, 900 MHz: 88.0119 dB at 1 km, 126.9463 dB at 10 km).
    func exactLossDB(distance d: Double) -> Double {
      let ht = txHeight
      let hr = rxHeight
      let d1 = (d * d + (ht - hr) * (ht - hr)).squareRoot()
      let d2 = (d * d + (ht + hr) * (ht + hr)).squareRoot()
      let k = 2 * Double.pi / wavelength
      let direct = RF.Complex.expj(-k * d1) / d1
      let reflected = reflection * RF.Complex.expj(-k * d2) / d2
      let field = (direct + reflected).magnitude * wavelength / (4 * Double.pi)
      return -20 * log10(max(field, 1e-300))
    }

    /// Far asymptote 40·log10 d − 20·log10(h_t·h_r) (∝ d⁻⁴, frequency independent; 86.9357 dB at 1 km).
    func asymptoticLossDB(distance d: Double) -> Double {
      40 * log10(d) - 20 * log10(txHeight * rxHeight)
    }

    /// Crossover of the d⁻² and d⁻⁴ asymptotes, d_x = 4π·h_t·h_r/λ (1697.63 m).
    var crossoverDistance: Double { 4 * Double.pi * txHeight * rxHeight / wavelength }

    /// Goldsmith's critical distance d_c = 4·h_t·h_r/λ: the **last interference maximum**
    /// (540.37 m). Beyond it the d⁻⁴ regime begins.
    var criticalDistance: Double { 4 * txHeight * rxHeight / wavelength }

    /// Small-angle estimate of the last null, 2·h_t·h_r/λ (270.2 m).
    var lastNullEstimate: Double { 2 * txHeight * rxHeight / wavelength }

    /// The last null from the exact geometry: the largest d at which the reflected ray arrives in
    /// antiphase, k(d₂ − d₁) = arg Γ − π + 2π, i.e. d₂ − d₁ = λ for Γ = −1 (268.5 m for the
    /// reference case). Nil when the geometry never reaches that path difference.
    var lastNull: Double? {
      let lambda = wavelength
      let ht = txHeight
      let hr = rxHeight
      // Smallest positive path difference (in λ) that puts the two rays in antiphase.
      var cycles = (reflection.phase - Double.pi) / (2 * Double.pi)
      cycles -= cycles.rounded(.down)
      if cycles < 1e-12 { cycles = 1 }
      let target = cycles * lambda
      // d₂ − d₁ decreases monotonically with d.
      let g: (Double) -> Double = { d in
        (d * d + (ht + hr) * (ht + hr)).squareRoot() - (d * d + (ht - hr) * (ht - hr)).squareRoot() - target
      }
      guard g(1e-6) > 0 else { return nil }
      return RF.Numerics.bisect(1e-6, 1e9, tolerance: 1e-9, g)
    }
  }
}

// MARK: - Okumura–Hata and COST-231 (rf-physics B.5)

nonisolated extension RF.Propagation {
  /// Hata environments (Hata 1980 naming: the −2[log(f/28)]² − 5.4 correction is suburban).
  enum HataEnvironment: String, CaseIterable, Codable, Hashable, Sendable {
    case smallMediumCity, largeCity, suburban, open
  }

  /// Mobile-antenna correction a(h_m), dB. Large city uses the f ≤ 200 MHz form below 300 MHz
  /// and the f ≥ 400 MHz form above (the reference gives no rule in between).
  static func hataMobileCorrection(frequencyMHz f: Double, mobileHeight hm: Double, largeCity: Bool) -> Double {
    if largeCity {
      return f < 300 ? 8.29 * pow(log10(1.54 * hm), 2) - 1.1 : 3.2 * pow(log10(11.75 * hm), 2) - 4.97
    }
    return (1.1 * log10(f) - 0.7) * hm - (1.56 * log10(f) - 0.8)
  }

  /// Okumura–Hata median loss (f 150–1500 MHz, h_b 30–200 m, h_m 1–10 m, d 1–20 km).
  /// 900 MHz, 30 m, 1.5 m, 5 km: 151.0244 (small/medium), 151.0412 (large), 141.0818 (suburban),
  /// 122.5180 dB (open).
  static func hataDB(frequencyMHz f: Double, baseHeight hb: Double, mobileHeight hm: Double, distanceKm d: Double, environment: HataEnvironment) -> Double {
    let a = hataMobileCorrection(frequencyMHz: f, mobileHeight: hm, largeCity: environment == .largeCity)
    let urban = 69.55 + 26.16 * log10(f) - 13.82 * log10(hb) - a + (44.9 - 6.55 * log10(hb)) * log10(d)
    switch environment {
    case .smallMediumCity, .largeCity: return urban
    case .suburban: return urban - 2 * pow(log10(f / 28), 2) - 5.4
    case .open: return urban - 4.78 * pow(log10(f), 2) + 18.33 * log10(f) - 40.94
    }
  }

  /// COST-231 Hata (1500–2000 MHz), C_m = 0 dB (medium city/suburban) or 3 dB (metropolitan).
  /// 1800 MHz, 30 m, 1.5 m, 2 km → 146.8007 / 149.8007 dB.
  static func cost231DB(frequencyMHz f: Double, baseHeight hb: Double, mobileHeight hm: Double, distanceKm d: Double, metropolitan: Bool) -> Double {
    let a = hataMobileCorrection(frequencyMHz: f, mobileHeight: hm, largeCity: false)
    return 46.3 + 33.9 * log10(f) - 13.82 * log10(hb) - a + (44.9 - 6.55 * log10(hb)) * log10(d) + (metropolitan ? 3 : 0)
  }
}

// MARK: - Knife-edge diffraction (ITU-R P.526-16 §4.1, rf-physics B.6)

nonisolated extension RF.Propagation {
  /// Fresnel–Kirchhoff parameter ν = h·√[(2/λ)(1/d₁ + 1/d₂)] (eq. 26). h is the height of the
  /// edge above the direct ray (negative when the ray clears it). h 10 m, 1 km/1 km, 900 MHz →
  /// ν = 1.095 824.
  static func knifeEdgeNu(height h: Double, d1: Double, d2: Double, wavelength lambda: Double) -> Double {
    h * ((2 / lambda) * (1 / d1 + 1 / d2)).squareRoot()
  }

  /// Approximate loss 6.9 + 20·log10(√((ν−0.1)² + 1) + ν − 0.1) dB for ν > −0.78, else 0
  /// (eq. 31). J(0) = 6.0329 dB.
  static func knifeEdgeLossApproxDB(nu: Double) -> Double {
    guard nu > -0.78 else { return 0 }
    return 6.9 + 20 * log10(((nu - 0.1) * (nu - 0.1) + 1).squareRoot() + nu - 0.1)
  }

  /// Exact loss from the Fresnel integrals (eq. 30):
  /// J(ν) = −20·log10(√([1 − C − S]² + [C − S]²)/2). J(0) = 6.0206 dB.
  static func knifeEdgeLossExactDB(nu: Double) -> Double {
    let (c, s) = RF.Special.fresnel(nu)
    let a = 1 - c - s
    let b = c - s
    return -20 * log10((a * a + b * b).squareRoot() / 2)
  }
}
