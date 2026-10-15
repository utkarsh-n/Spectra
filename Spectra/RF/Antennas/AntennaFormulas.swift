import Foundation

/// Closed-form antenna results from rf-physics.md §A (verified reference in rf-physics-review.md).
/// Lengths in wavelengths unless the parameter name says metres. η defaults to η₀; pass
/// `RF.Const.eta120pi` to reproduce textbook "73 Ω / 80π² / 31 171" numbers.
nonisolated extension RF.Antennas {
  // MARK: Dipoles and monopoles

  /// Hertzian (infinitesimal) dipole R_r = (2π/3)·η·(Δl/λ)² (A.1). 0.01λ → 0.078 902 Ω (η₀).
  static func hertzianRadiationResistance(lengthWavelengths dl: Double, eta: Double = RF.Const.eta0) -> Double {
    2 * Double.pi / 3 * eta * dl * dl
  }

  /// Short dipole with triangular current, R_r = 20π²(l/λ)² (A.2). 0.1λ → 1.973 92 Ω.
  static func shortDipoleRadiationResistance(lengthWavelengths l: Double) -> Double {
    20 * Double.pi * Double.pi * l * l
  }

  /// Thin centre-fed dipole of total length L (in λ), sinusoidal current (A.3).
  struct ThinDipole: Sendable, Hashable {
    /// Total length L/λ.
    let length: Double
    /// Radiation integral 𝓘 = ∫₀^π [cos(πL cosθ) − cos(πL)]²/sinθ dθ.
    let radiationIntegral: Double
    /// Maximum of the power pattern F(θ) = ([cos(πL cosθ) − cos(πL)]/sinθ)².
    let patternMax: Double
    /// Angle of the pattern maximum in degrees, 0…90 (the pattern is symmetric about 90°).
    let thetaMaxDeg: Double

    /// `L` is clamped to 10⁻⁴…10³ (as L → 0 the pattern tends to the Hertzian sin²θ, D → 1.5);
    /// a non-finite length gives the half-wave dipole.
    init(lengthWavelengths requested: Double) {
      let L = requested.isFinite ? min(max(requested, 1e-4), 1e3) : 0.5
      length = L
      let piL = Double.pi * L
      let cosPiL = cos(piL)
      // In μ = cosθ the integrand is [cos(πLμ) − cos(πL)]²/(1 − μ²), smooth on [−1, 1].
      let panels = max(16, Int(ceil(L * 12)))
      radiationIntegral = RF.Numerics.integrate(-1, 1, panels: panels) { mu in
        let den = 1 - mu * mu
        guard den > 1e-300 else { return 0 }
        let n = cos(piL * mu) - cosPiL
        return n * n / den
      }
      // Global maximum: dense scan over θ ∈ (0, 90°], then golden-section refinement.
      let f: (Double) -> Double = { theta in ThinDipole.power(theta: theta, piL: piL, cosPiL: cosPiL) }
      var best = Double.pi / 2
      var bestValue = f(best)
      // Lobes are about 1/L apart in cosθ: keep several scan points per lobe for long wires.
      let steps = max(1800, Int(L * 400))
      for i in 1..<steps {
        let theta = Double(i) / Double(steps) * Double.pi / 2
        let v = f(theta)
        if v > bestValue * (1 + 1e-12) {
          bestValue = v
          best = theta
        }
      }
      let step = Double.pi / 2 / Double(steps)
      if best < Double.pi / 2 - step / 2 {
        best = RF.Numerics.maximize(max(1e-9, best - step), min(Double.pi / 2, best + step), f)
        bestValue = f(best)
      }
      patternMax = bestValue
      thetaMaxDeg = best * 180 / Double.pi
    }

    /// Unnormalized power pattern F(θ).
    static func power(theta: Double, piL: Double, cosPiL: Double) -> Double {
      let s = sin(theta)
      guard abs(s) > 1e-12 else { return 0 }
      let n = cos(piL * cos(theta)) - cosPiL
      return n * n / (s * s)
    }

    /// Normalized power pattern F(θ)/F_max.
    func normalizedPower(theta: Double) -> Double {
      ThinDipole.power(theta: theta, piL: Double.pi * length, cosPiL: cos(Double.pi * length)) / patternMax
    }

    /// Radiation resistance referred to the current maximum, R_r = η𝓘/(2π).
    func radiationResistance(eta: Double = RF.Const.eta0) -> Double { eta * radiationIntegral / (2 * Double.pi) }

    /// Input resistance at the centre feed, R_in = R_r/sin²(πL); infinite for L = nλ (thin wire).
    func inputResistance(eta: Double = RF.Const.eta0) -> Double {
      let s = sin(Double.pi * length)
      guard abs(s) > 1e-9 else { return .infinity }
      return radiationResistance(eta: eta) / (s * s)
    }

    /// Directivity D = 2·F_max/𝓘.
    var directivity: Double { 2 * patternMax / radiationIntegral }

    /// Half-power beamwidth of the main lobe in degrees (nil if it never falls to half power).
    var hpbwDeg: Double? {
      RF.Antennas.halfPowerBeamwidth(peakDeg: thetaMaxDeg, rangeDeg: 0...180) { normalizedPower(theta: $0 * Double.pi / 180) }
    }
  }

  /// Reactance of the thin half-wave dipole at the feed, X_in ≈ +42.5 Ω (A.3, L09 p. 13).
  static let halfWaveDipoleReactance = 42.5
  /// Quarter-wave monopole over infinite ground, Z_in ≈ 36.5 + j21.25 Ω (A.4).
  static let quarterWaveMonopoleImpedance = RF.Complex(36.5, 21.25)

  // MARK: Loops

  /// Small loop R_r = (8/3)·η·π³·(A/λ²)²·N²·μ_eff² (A.5). `areaOverLambdaSquared` = A/λ².
  static func smallLoopRadiationResistance(
    areaOverLambdaSquared a: Double, turns: Double = 1, muEffective: Double = 1, eta: Double = RF.Const.eta0
  ) -> Double {
    8.0 / 3.0 * eta * pow(Double.pi, 3) * a * a * turns * turns * muEffective * muEffective
  }

  /// Small loop R_r from physical area (m²) and frequency.
  static func smallLoopRadiationResistance(
    area: Double, frequency: Double, turns: Double = 1, muEffective: Double = 1, eta: Double = RF.Const.eta0
  ) -> Double {
    let lambda = RF.Const.c / frequency
    return smallLoopRadiationResistance(areaOverLambdaSquared: area / (lambda * lambda), turns: turns, muEffective: muEffective, eta: eta)
  }

  // MARK: Microstrip patch (transmission-line model, A.6)

  /// Rectangular patch dimensions (metres) from the Balanis transmission-line design equations.
  struct PatchDesign: Sendable, Hashable {
    /// Width W = c/(2f)·√(2/(ε_r+1)).
    let width: Double
    /// ε_eff = (ε_r+1)/2 + (ε_r−1)/2·(1+12h/W)^(−½).
    let epsilonEffective: Double
    /// Fringing extension ΔL.
    let deltaL: Double
    /// Physical length L = c/(2f√ε_eff) − 2ΔL.
    let length: Double
    /// Effective length L_e = L + 2ΔL used by the two-slot pattern.
    var effectiveLength: Double { length + 2 * deltaL }

    init(epsilonR er: Double, height h: Double, frequency f: Double) {
      let c = RF.Const.c
      let w = c / (2 * f) * (2 / (er + 1)).squareRoot()
      let ee = (er + 1) / 2 + (er - 1) / 2 * pow(1 + 12 * h / w, -0.5)
      let dl = 0.412 * h * (ee + 0.3) * (w / h + 0.264) / ((ee - 0.258) * (w / h + 0.8))
      width = w
      epsilonEffective = ee
      deltaL = dl
      length = c / (2 * f * ee.squareRoot()) - 2 * dl
    }
  }

  // MARK: Yagi-Uda (NBS TN 688, A.7)

  /// NBS Technical Note 688 optimized designs: boom length (λ), element count, gain (dBd).
  static let yagiNBSTable: [(boom: Double, elements: Int, gainDBd: Double)] = [
    (0.4, 3, 7.1), (0.8, 5, 9.2), (1.2, 6, 10.2), (2.2, 12, 12.25), (3.2, 17, 13.4), (4.2, 15, 14.2),
  ]

  /// Yagi gain in dBd interpolated linearly in boom length from the NBS table; clamped to the
  /// table ends (the flag says when the boom is outside 0.4…4.2λ).
  static func yagiGainDBd(boomWavelengths boom: Double) -> (gainDBd: Double, insideTable: Bool) {
    let t = yagiNBSTable
    if boom <= t[0].boom { return (t[0].gainDBd, boom >= t[0].boom - 1e-12) }
    if boom >= t[t.count - 1].boom { return (t[t.count - 1].gainDBd, boom <= t[t.count - 1].boom + 1e-12) }
    for i in 1..<t.count where boom <= t[i].boom {
      let f = (boom - t[i - 1].boom) / (t[i].boom - t[i - 1].boom)
      return (t[i - 1].gainDBd + f * (t[i].gainDBd - t[i - 1].gainDBd), true)
    }
    return (t[t.count - 1].gainDBd, false)
  }

  // MARK: Axial-mode helix (A.8)

  /// Axial-mode helix estimates; C and S in wavelengths, N turns.
  struct HelixEstimates: Sendable, Hashable {
    let circumference: Double
    let turns: Double
    let spacing: Double
    /// Kraus (2nd ed.) D = 12·C²·N·S.
    var krausDirectivity: Double { 12 * circumference * circumference * turns * spacing }
    /// Kraus HPBW = 52°/(C·√(N·S)).
    var krausHPBWDeg: Double { 52 / (circumference * (turns * spacing).squareRoot()) }
    /// Stutzman–Thiele D = 6.2·C²·N·S.
    var stutzmanThieleDirectivity: Double { 6.2 * circumference * circumference * turns * spacing }
    /// Stutzman–Thiele HPBW = 65°/(C·√(N·S)).
    var stutzmanThieleHPBWDeg: Double { 65 / (circumference * (turns * spacing).squareRoot()) }
    /// Input resistance R_in ≈ 140·C Ω (axial mode, nearly resistive).
    var inputResistance: Double { 140 * circumference }
    /// Axial ratio (2N+1)/(2N).
    var axialRatio: Double { (2 * turns + 1) / (2 * turns) }
    /// Axial length L = N·S (λ).
    var axialLength: Double { turns * spacing }
    /// Emerson (NRAO) realistic maximum gain, 10.25 + 1.22L − 0.0726L² dBi, valid 2 ≤ L ≤ 7.
    var emersonGainDBi: Double? {
      let L = axialLength
      guard L >= 2 - 1e-9, L <= 7 + 1e-9 else { return nil }
      return 10.25 + 1.22 * L - 0.0726 * L * L
    }
    /// Axial mode requires 3/4 < C < 4/3.
    var isAxialMode: Bool { circumference > 0.75 && circumference < 4.0 / 3.0 }
  }

  // MARK: Apertures (A.9, A.10)

  /// Optimum pyramidal-horn aperture efficiency ε_t·ε_ph^E·ε_ph^H ≈ 0.51.
  static let hornOptimumApertureEfficiency = 0.51

  /// Horn gain G = ε_ap·4πAB/λ² with A, B in wavelengths.
  static func hornGain(apertureA a: Double, apertureB b: Double, efficiency: Double = hornOptimumApertureEfficiency) -> Double {
    efficiency * 4 * Double.pi * a * b
  }

  /// Dish gain G = η·(πD/λ)² with D in wavelengths.
  static func dishGain(diameter d: Double, efficiency: Double = 0.65) -> Double {
    efficiency * pow(Double.pi * d, 2)
  }

  /// The root of (2J₁(u)/u)² = ½, u = 1.616 34.
  static let airyHalfPowerArgument: Double = {
    RF.Numerics.bisect(1.4, 1.8) { u in pow(2 * RF.Special.besselJ(1, u) / u, 2) - 0.5 } ?? 1.616_34
  }()

  /// Uniform circular aperture HPBW = 2·asin(u·λ/(πD)) in degrees (58.96°·λ/D for large D).
  static func uniformApertureHPBWDeg(diameter d: Double) -> Double {
    let s = airyHalfPowerArgument / (Double.pi * d)
    guard s < 1 else { return 180 }
    return 2 * asin(s) * 180 / Double.pi
  }

  /// Typical tapered-feed dish HPBW ≈ 70°·λ/D (rule of thumb, NASA NTRS 20070032925).
  static func taperedDishHPBWDeg(diameter d: Double) -> Double { 70 / d }

  // MARK: Arrays (A.12)

  /// Ideal planar-array gain G ≈ G_element + 10·log10(N_x·N_y) dBi.
  static func planarArrayGainDBi(elementGainDBi: Double, nx: Int, ny: Int) -> Double {
    elementGainDBi + 10 * log10(Double(nx * ny))
  }

  /// Coherent beamforming array gain 10·log10(N) dB (D.10).
  static func arrayGainDB(elements n: Int) -> Double { 10 * log10(Double(n)) }

  // MARK: PIFA (A.13, qualitative)

  /// PIFA resonance estimate: the top-plate current path L₁ + L₂ ≈ λ/4 (rough guide only, [S]).
  static func pifaResonantFrequency(currentPath: Double) -> Double { RF.Const.c / (4 * currentPath) }
  /// Published smartphone total-efficiency range (40–70 %, rf-physics A.13 [S]).
  static let phoneEfficiencyRange: ClosedRange<Double> = 0.4...0.7

  // MARK: Friis, aperture, EIRP (A.14)

  /// Effective aperture A_e = G·λ²/(4π) in m².
  static func effectiveAperture(gain: Double, wavelength lambda: Double) -> Double {
    gain * lambda * lambda / (4 * Double.pi)
  }

  /// EIRP in dBm = P_t + G_t + e_TL (feed loss entered as a positive loss in dB).
  static func eirpDBm(txPowerDBm: Double, gainDBi: Double, feedLossDB: Double = 0) -> Double {
    txPowerDBm + gainDBi - feedLossDB
  }

  // MARK: Polarization (A.15)

  /// Polarization loss factor for two linear polarizations at angle ψ: PLF = cos²ψ.
  static func linearPLF(mismatchDeg psi: Double) -> Double { pow(cos(psi * Double.pi / 180), 2) }

  /// PLF in dB, clamped for display (RHCP→LHCP is −∞).
  static func plfDB(_ plf: Double, floorDB: Double = -40) -> Double { max(floorDB, 10 * log10(max(plf, 1e-300))) }

  // MARK: Field regions (A.17)

  /// Reactive near-field boundary 0.62√(D³/λ) (D, λ in metres).
  static func reactiveNearFieldBoundary(size d: Double, wavelength lambda: Double) -> Double {
    0.62 * (d * d * d / lambda).squareRoot()
  }

  /// Fraunhofer far-field boundary 2D²/λ.
  static func farFieldBoundary(size d: Double, wavelength lambda: Double) -> Double { 2 * d * d / lambda }

  /// Electrically small antenna boundary λ/2π.
  static func smallAntennaBoundary(wavelength lambda: Double) -> Double { lambda / (2 * Double.pi) }

  // MARK: Beamwidth helper

  /// Half-power beamwidth around a peak at `peakDeg` of a normalized power pattern sampled in
  /// degrees. Walks outward on a 0.05° grid until the pattern falls below ½, then bisects.
  /// Returns nil if either side never reaches half power within `rangeDeg`.
  static func halfPowerBeamwidth(
    peakDeg: Double, rangeDeg: ClosedRange<Double>, step: Double = 0.05, _ p: (Double) -> Double
  ) -> Double? {
    let peak = p(peakDeg)
    guard peak > 0 else { return nil }
    let half = peak / 2
    func edge(_ direction: Double) -> Double? {
      var a = peakDeg
      var x = peakDeg + direction * step
      while rangeDeg.contains(x) {
        if p(x) < half {
          return RF.Numerics.bisect(min(a, x), max(a, x), tolerance: 1e-10) { p($0) - half }
        }
        a = x
        x += direction * step
      }
      return nil
    }
    guard let lo = edge(-1), let hi = edge(1) else { return nil }
    return hi - lo
  }
}
