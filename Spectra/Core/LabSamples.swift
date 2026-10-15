import Foundation

/// The five Spectroscopy-lab samples (spectra-lab `SAMPLES`, in display order).
nonisolated enum SampleKey: String, CaseIterable, Codable, Sendable, Identifiable {
  case hydrogen, co2, water, chlorophyll, nmr
  var id: String { rawValue }
}

/// Measurement modes. Raw values are the JS strings ("400" and "60" for NMR).
nonisolated enum SampleMode: String, CaseIterable, Codable, Sendable, Identifiable {
  case emission, absorption, ir, raman, a, b
  case nmr400 = "400"
  case nmr60 = "60"
  var id: String { rawValue }
}

/// The x axis of a sample's spectrum; `from` is drawn on the left.
nonisolated struct SampleAxis: Hashable, Sendable {
  enum Kind: String, Codable, Sendable {
    /// Wavelength in m on a log scale.
    case lambdaLog = "lambda-log"
    /// Wavelength in m on a linear scale.
    case lambda
    /// Wavenumber, cm⁻¹.
    case wavenumber
    /// Chemical shift, ppm.
    case ppm
  }

  var kind: Kind
  var from: Double
  var to: Double
  var label: String

  /// x at fraction u ∈ [0, 1] of the axis: geometric for `lambdaLog`, linear otherwise.
  func x(at u: Double) -> Double {
    kind == .lambdaLog ? from * pow(to / from, u) : from + (to - from) * u
  }
}

nonisolated extension SampleKey {
  var name: String {
    switch self {
    case .hydrogen: "Hydrogen"
    case .co2: "CO\u{2082}"
    case .water: "Liquid water"
    case .chlorophyll: "Chlorophyll"
    case .nmr: "Proton NMR"
    }
  }

  var modes: [SampleMode] {
    switch self {
    case .hydrogen: [.emission, .absorption]
    case .co2: [.ir, .raman]
    case .water: [.ir]
    case .chlorophyll: [.a, .b]
    case .nmr: [.nmr400, .nmr60]
    }
  }

  /// Liquid water is measured (Segelstein); the rest are models with literature line positions.
  var source: CoreProvenance { self == .water ? .table : .model }

  var axis: SampleAxis {
    switch self {
    case .hydrogen: SampleAxis(kind: .lambdaLog, from: 90e-9, to: 2.7e-6, label: "wavelength")
    case .co2, .water: SampleAxis(kind: .wavenumber, from: 4000, to: 400, label: "wavenumber")
    case .chlorophyll: SampleAxis(kind: .lambda, from: 350e-9, to: 750e-9, label: "wavelength")
    case .nmr: SampleAxis(kind: .ppm, from: 4.5, to: -0.3, label: "chemical shift")
    }
  }

  /// Spectrum value at axis position x (absorbance or relative intensity).
  func value(_ x: Double, mode: SampleMode) -> Double {
    switch self {
    case .hydrogen:
      let lx = log10(x)
      var y = 0.0
      for l in Samples.hydrogenLines(mode: mode) {
        y = y + l.strength * Samples.lorentz(lx, log10(l.lambda), 0.0012)
      }
      return y
    case .co2:
      var y = 0.0
      for b in mode == .ir ? Samples.co2IR : Samples.co2Raman { y = y + b.strength * Samples.bandShape(x, b) }
      return y
    case .water:
      guard let a = Matter.waterAbsorption(1 / (x * 100)) else { return 0 }
      return (a * 1e-4) / 2.302585092994046  // absorbance of a 1 µm film (÷ Math.LN10)
    case .chlorophyll:
      let nm = x * 1e9
      var y = 0.0
      for p in mode == .b ? Samples.chlorophyllB : Samples.chlorophyllA {
        y = y + p.strength * Samples.gauss(nm, p.center, p.width)
      }
      return y
    case .nmr:
      let b0 = Samples.nmrField(mode)
      return Samples.nmrSpectrum(ppm: x, b0: b0) / Samples.nmrSpectrum(ppm: 1.22, b0: b0)
    }
  }

  /// The source wavelength that probes axis position x (the lab's sweep retunes to it).
  func toLambda(_ x: Double, mode: SampleMode) -> Double {
    switch self {
    case .hydrogen, .chlorophyll: x
    case .co2, .water: 1 / (x * 100)
    case .nmr: SI.c / Samples.larmor(b0: Samples.nmrField(mode), ppm: x)
    }
  }

  /// The sample's one-paragraph note.
  func note(mode: SampleMode) -> String {
    switch self {
    case .hydrogen:
      mode == .emission
        ? "Every line is an electron dropping between two levels. Positions come straight from the Rydberg formula; only Balmer lines are visible to the eye."
        : "Cold hydrogen absorbs only from the ground state, so only the Lyman series appears, all in the ultraviolet."
    case .co2:
      mode == .ir
        ? "The symmetric stretch near 1388 cm\u{207B}\u{00B9} leaves CO\u{2082}'s dipole unchanged, so infrared can't drive it. The 667 cm\u{207B}\u{00B9} bend falls in Earth's thermal glow."
        : "Raman sees the symmetric stretch that IR misses: the field distorts the electron cloud instead of tugging on a dipole."
    case .water:
      "Measured (Segelstein 1981), 1 \u{00B5}m film. The O\u{2013}H stretch near 3400 cm\u{207B}\u{00B9} is broad because hydrogen bonds keep tugging at every molecule."
    case .chlorophyll:
      "Chlorophyll \(mode.rawValue) absorbs blue and red light and reflects the green in between, which is why leaves look green."
    case .nmr:
      "Ethanol in a \(mode == .nmr60 ? "1.41 T (60 MHz)" : "9.4 T (400 MHz)") magnet. Radio waves flip proton spins. Neighbouring protons split each peak by J = 7.1 Hz, a fixed amount in hertz, so a stronger magnet spreads the peaks apart."
    }
  }
}

/// Spectroscopy-lab line data and shapes (port of spectra-lab `core/samples.js`). Line
/// positions come from physics or the literature; band shapes and relative strengths are
/// drawn to look like real spectra (MODEL) unless marked TABLE.
nonisolated enum Samples {
  /// 1/(1 + ((x − x0)/hw)²).
  static func lorentz(_ x: Double, _ x0: Double, _ hw: Double) -> Double {
    let q = (x - x0) / hw
    return 1 / (1 + q * q)
  }

  /// exp(−(x − x0)²/(2s²)).
  static func gauss(_ x: Double, _ x0: Double, _ s: Double) -> Double {
    let d = x - x0
    return exp(-(d * d) / (2 * s * s))
  }

  // MARK: Hydrogen

  /// A hydrogen series: lines ending on level n1.
  struct Series: Hashable, Sendable {
    let n1: Int
    let name: String
  }

  static let series: [Series] = [
    Series(n1: 1, name: "Lyman"), Series(n1: 2, name: "Balmer"), Series(n1: 3, name: "Paschen"),
    Series(n1: 4, name: "Brackett"),
  ]

  /// One hydrogen line with its strength normalized to the strongest line in the set.
  struct HydrogenLine: Hashable, Sendable {
    let lambda: Double
    let series: String
    let n1: Int
    let n2: Int
    let strength: Double
  }

  /// Vacuum wavelength of the n2 → n1 transition, Rydberg formula with the reduced-mass R_H.
  static func hydrogenLine(n1: Int, n2: Int) -> Double {
    let a = Double(n1 * n1), b = Double(n2 * n2)
    return 1 / (SI.rHydrogen * (1 / a - 1 / b))
  }

  /// Emission: 48 lines (four series × 12) with strength (n1/n2)³/n1. Absorption: the 12
  /// Lyman lines only (cold atoms sit in n = 1) with strength (n1/n2)³. Cached per mode.
  static func hydrogenLines(mode: SampleMode) -> [HydrogenLine] {
    mode == .absorption ? hydrogenAbsorption : hydrogenEmission
  }

  private static let hydrogenEmission = makeHydrogenLines(absorption: false)
  private static let hydrogenAbsorption = makeHydrogenLines(absorption: true)

  private static func makeHydrogenLines(absorption: Bool) -> [HydrogenLine] {
    var raw: [(lambda: Double, series: Series, n2: Int, strength: Double)] = []
    for s in series {
      if absorption && s.n1 != 1 { continue }
      for n2 in (s.n1 + 1)...(s.n1 + 12) {
        let strength = pow(Double(s.n1) / Double(n2), 3) * (absorption ? 1 : 1 / Double(s.n1))
        raw.append((hydrogenLine(n1: s.n1, n2: n2), s, n2, strength))
      }
    }
    let maxStrength = raw.map(\.strength).reduce(-Double.infinity) { JSMath.max($0, $1) }
    return raw.map { HydrogenLine(lambda: $0.lambda, series: $0.series.name, n1: $0.series.n1, n2: $0.n2, strength: $0.strength / maxStrength) }
  }

  // MARK: CO₂

  /// A CO₂ band: centre (cm⁻¹), relative strength, rotational shape, label.
  struct CO2Band: Hashable, Sendable {
    enum Shape: String, Sendable {
      /// P and R lobes only.
      case parallel
      /// P and R lobes plus a sharp Q branch.
      case perpendicular
      /// A single Lorentzian (Raman Q branch).
      case q
    }
    let nu: Double
    let strength: Double
    let shape: Shape
    let label: String
  }

  /// IR bands (Herzberg; NIST Chemistry WebBook): ν₃ 2349.1, ν₂ 667.4, combinations 3716 and 3609.
  static let co2IR: [CO2Band] = [
    CO2Band(nu: 2349.1, strength: 1.0, shape: .parallel, label: "\u{03BD}\u{2083} asymmetric stretch"),
    CO2Band(nu: 667.4, strength: 0.55, shape: .perpendicular, label: "\u{03BD}\u{2082} bend"),
    CO2Band(nu: 3716, strength: 0.07, shape: .parallel, label: "\u{03BD}\u{2081}+\u{03BD}\u{2083} combination"),
    CO2Band(nu: 3609, strength: 0.05, shape: .parallel, label: "2\u{03BD}\u{2082}+\u{03BD}\u{2083} combination"),
  ]

  /// Raman bands: the ν₁ / 2ν₂ Fermi dyad at 1388.2 and 1285.4 cm⁻¹.
  static let co2Raman: [CO2Band] = [
    CO2Band(nu: 1388.2, strength: 1.0, shape: .q, label: "\u{03BD}\u{2081} symmetric stretch"),
    CO2Band(nu: 1285.4, strength: 0.62, shape: .q, label: "2\u{03BD}\u{2082} (Fermi resonance)"),
  ]

  /// Room-temperature gas-phase band envelope: P and R lobes ~12 cm⁻¹ either side,
  /// (|d|/12)·exp(0.5 − d²/288), plus a Q branch for perpendicular bands.
  static func bandShape(_ x: Double, _ b: CO2Band) -> Double {
    let d = x - b.nu, sLobe = 12.0
    let lobe = (abs(d) / sLobe) * exp(0.5 - (d * d) / (2 * sLobe * sLobe))
    switch b.shape {
    case .q: return lorentz(x, b.nu, 2.5)
    case .perpendicular: return 0.75 * lobe + 1.0 * lorentz(x, b.nu, 1.2)
    case .parallel: return lobe
    }
  }

  // MARK: Chlorophyll

  /// One Gaussian absorption peak: centre nm, relative strength, σ nm.
  struct Peak: Hashable, Sendable {
    let center: Double
    let strength: Double
    let width: Double
  }

  /// Chlorophyll a in diethyl ether (Lichtenthaler 1987): 428 / 660 nm main peaks.
  static let chlorophyllA: [Peak] = [
    Peak(center: 428, strength: 1.0, width: 14), Peak(center: 410, strength: 0.55, width: 12),
    Peak(center: 660, strength: 0.78, width: 9), Peak(center: 615, strength: 0.12, width: 12),
    Peak(center: 578, strength: 0.08, width: 12), Peak(center: 530, strength: 0.03, width: 20),
  ]
  /// Chlorophyll b: 452 / 642 nm main peaks.
  static let chlorophyllB: [Peak] = [
    Peak(center: 452, strength: 1.0, width: 14), Peak(center: 430, strength: 0.4, width: 14),
    Peak(center: 642, strength: 0.36, width: 9), Peak(center: 595, strength: 0.07, width: 12),
  ]

  // MARK: Proton NMR of ethanol

  /// An ethanol proton group: shift (ppm), proton count, multiplet weights, label.
  struct NMRGroup: Hashable, Sendable {
    let ppm: Double
    let protons: Double
    let multiplet: [Double]
    let label: String
  }

  /// CH₃ 1.22 ppm triplet, CH₂ 3.69 ppm quartet (J = 7.1 Hz), OH singlet ~2.61 ppm, TMS at 0.
  static let ethanol: [NMRGroup] = [
    NMRGroup(ppm: 3.69, protons: 2, multiplet: [1, 3, 3, 1], label: "CH\u{2082} quartet"),
    NMRGroup(ppm: 2.61, protons: 1, multiplet: [1], label: "OH"),
    NMRGroup(ppm: 1.22, protons: 3, multiplet: [1, 2, 1], label: "CH\u{2083} triplet"),
    NMRGroup(ppm: 0, protons: 0.4, multiplet: [1], label: "TMS reference"),
  ]

  /// J coupling, Hz.
  static let couplingJ: Double = 7.1
  /// Display half-width, Hz (shimmed spectrometers reach < 0.5 Hz).
  static let nmrHalfWidthHz: Double = 1.2

  /// B₀ for an NMR mode: 1.41 T for "60", 9.4 T otherwise.
  static func nmrField(_ mode: SampleMode) -> Double { mode == .nmr60 ? 1.41 : 9.4 }

  /// Proton precession frequency γₚ·B₀·(1 + ppm·10⁻⁶), Hz.
  static func larmor(b0: Double, ppm: Double = 0) -> Double { SI.gammaProtonHzPerT * b0 * (1 + ppm * 1e-6) }

  /// Ethanol spectrum at any field B₀ (T), normalized like the lab's NMR modes (CH₃ centre = 1).
  /// First-order multiplets: valid while the shift differences (in Hz) are much larger than
  /// J, i.e. at spectrometer fields. Near the Earth's field (50 µT, f ≈ 2.1 kHz) the shifts are
  /// millihertz, the multiplets collapse and a real spectrum shows a single proton line, so an
  /// Earth-field view should draw one line at `earthFieldLarmor(b0:)` instead of this curve.
  static func ethanolValue(ppm: Double, b0: Double) -> Double {
    nmrSpectrum(ppm: ppm, b0: b0) / nmrSpectrum(ppm: 1.22, b0: b0)
  }

  /// Vacuum wavelength c/f_L of the proton line at shift `ppm` in field B₀ (T).
  static func nmrLambda(ppm: Double, b0: Double) -> Double { SI.c / larmor(b0: b0, ppm: ppm) }

  /// Earth-field NMR line of water protons, γ′ₚ·|B| Hz (shielded γ′ₚ, CODATA 2022): the single
  /// line the lab's "Earth field (live |B|)" mode draws, identical to the Spin engine's
  /// water-proton Larmor frequency. Worked values (gyre-integration.md §4.1): 25 µT → 1064.41 Hz,
  /// 50 µT → 2128.82 Hz, 65 µT → 2767.47 Hz. (`larmor(b0:)` keeps the web lab's bare γₚ.)
  static func earthFieldLarmor(b0: Double) -> Double { SI.gammaProtonShieldedHzPerT * b0 }

  /// Vacuum wavelength of the Earth-field water-proton line, c/(γ′ₚ·|B|): 140.83 km at 50 µT.
  static func earthFieldLambda(b0: Double) -> Double { SI.c / earthFieldLarmor(b0: b0) }

  /// Un-normalized ethanol spectrum at a chemical shift, for field B₀.
  static func nmrSpectrum(ppm: Double, b0: Double) -> Double {
    let f0 = SI.gammaProtonHzPerT * b0
    var y = 0.0
    for g in ethanol {
      var sum = 0.0
      for m in g.multiplet { sum = sum + m }
      let k = Double(g.multiplet.count)
      for (i, m) in g.multiplet.enumerated() {
        let lineHz = g.ppm * 1e-6 * f0 + (Double(i) - (k - 1) / 2) * couplingJ
        y += ((g.protons * m) / sum) * lorentz(ppm * 1e-6 * f0, lineHz, nmrHalfWidthHz)
      }
    }
    return y
  }
}
