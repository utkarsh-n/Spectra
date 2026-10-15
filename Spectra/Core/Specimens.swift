import Foundation

/// Where a Core number comes from: interpolated measured data (TABLE) or a model (MODEL).
/// The raw values match the app-wide `Provenance` cases `.table` / `.model`, so
/// `Provenance(rawValue: x.rawValue)` converts.
nonisolated enum CoreProvenance: String, Codable, CaseIterable, Sendable {
  case table, model
}

/// The seven Matter-bench specimens (spectra-lab `SPECIMENS`, in display order).
nonisolated enum SpecimenKey: String, CaseIterable, Codable, Sendable, Identifiable {
  case oscillator, antenna, water, glass, zinc, dna, hand
  var id: String { rawValue }
}

/// Options for `SpecimenKey.evaluate`; only the oscillator reads them.
nonisolated struct SpecimenOptions: Hashable, Sendable {
  /// Resonance wavelength of the charge on a spring, m.
  var lambda0: Double = 120e-9
  /// Quality factor of the oscillator.
  var q: Double = 8
}

/// How a specimen responds, for the animated stage and the text line.
nonisolated struct SpecimenResponse: Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    case spring, current, twist, stretch, pass, absorb, eject, reflect, dimer, shadow, glow
  }
  /// Oscillator drive relative to resonance (JS `where`).
  enum Regime: String, Codable, Sendable { case below, on, above }

  var kind: Kind
  var text: String
  /// Oscillator: displacement relative to the static response.
  var amplitude: Double? = nil
  /// Oscillator: phase lag behind the field, degrees.
  var lag: Double? = nil
  /// Oscillator: absorbed power relative to on-resonance.
  var power: Double? = nil
  var regime: Regime? = nil
  /// Antenna: relative current.
  var value: Double? = nil
  /// Water: heating at the front face, K/min.
  var heating: Double? = nil
  /// Zinc: maximum photoelectron energy, eV (nil when nothing is ejected).
  var ejectKeMax: Double? = nil
  /// DNA: on the 260 nm band (A > 0.3).
  var resonance: Bool? = nil
}

/// One specimen's answer at one wavelength. Transmission/reflection/absorption are fractions
/// (JS `T`, `R`, `A`; absent for the oscillator and the antenna, which do not block the beam).
nonisolated struct SpecimenResult: Hashable, Sendable {
  var transmission: Double? = nil
  var reflection: Double? = nil
  var absorption: Double? = nil
  /// Attenuation coefficient, 1/cm (water, glass).
  var alpha: Double? = nil
  /// DNA absorbance (base-10).
  var absorbance: Double? = nil
  /// Finger: transmission through the bone path.
  var boneT: Double? = nil
  /// Finger: 1 − boneT/softT.
  var contrast: Double? = nil
  var source: CoreProvenance
  var response: SpecimenResponse
}

nonisolated extension SpecimenKey {
  var name: String {
    switch self {
    case .oscillator: "Charge on a spring"
    case .antenna: "FM dipole antenna"
    case .water: "Water"
    case .glass: "Window glass"
    case .zinc: "Zinc plate"
    case .dna: "DNA"
    case .hand: "Finger"
    }
  }

  var sub: String {
    switch self {
    case .oscillator: "The model behind every material"
    case .antenna: "1.5 m, tuned to 100 MHz"
    case .water: "1 cm deep"
    case .glass: "Borosilicate, 3 mm"
    case .zinc: "1 mm"
    case .dna: "50 \u{00B5}g/mL in 1 cm of water"
    case .hand: "3 cm, with 1 cm of bone"
    }
  }

  /// "What happens to this beam?" at `lambda`. `source` supplies E₀ for water heating
  /// (nil → no heating); `options` tune the oscillator.
  func evaluate(_ lambda: Double, source: WaveSource? = nil, options: SpecimenOptions = SpecimenOptions()) -> SpecimenResult {
    switch self {
    case .oscillator: Specimens.oscillator(lambda, options)
    case .antenna: Specimens.antenna(lambda)
    case .water: Specimens.water(lambda, source)
    case .glass: Specimens.glass(lambda)
    case .zinc: Specimens.zinc(lambda)
    case .dna: Specimens.dna(lambda, source)
    case .hand: Specimens.hand(lambda)
    }
  }
}

/// The Matter bench (port of spectra-lab `core/specimens.js`): six specimens and one
/// idealized oscillator. Every result carries its provenance.
nonisolated enum Specimens {
  /// First Segelstein point, 10 nm.
  static let segMin: Double = 10e-9

  /// True where the XCOM tables apply: λ ≤ 1.24 nm and E ≤ 20 MeV.
  static func isXray(_ lambda: Double) -> Bool {
    lambda <= Matter.xcomLambdaMax && Spectrum.photonEV(lambda) <= Matter.xcomMaxEV
  }

  /// Attenuation of water at any wavelength, 1/cm, stitched across XCOM, Segelstein and a
  /// log-log bridge. Beyond 10 m it is 0 (MODEL), as in the JS.
  static func waterAlpha(_ lambda: Double) -> (alpha: Double, source: CoreProvenance) {
    if isXray(lambda) { return (Matter.linearAttenuation(.water, eV: Spectrum.photonEV(lambda)) ?? 0, .table) }
    if let a = Matter.waterAbsorption(lambda) { return (a, .table) }
    if lambda < segMin && lambda > Matter.xcomLambdaMax {
      let alpha = Matter.bridge(
        lambda, segMin, Matter.waterAbsorption(segMin) ?? 0, Matter.xcomLambdaMax,
        Matter.linearAttenuation(.water, eV: 1e3) ?? 0)
      return (alpha, .model)
    }
    let ev = JSMath.min(Spectrum.photonEV(lambda), Matter.xcomMaxEV)
    return (Matter.linearAttenuation(.water, eV: ev) ?? 0, .model)
  }

  /// dsDNA at 50 µg/mL in 1 cm of water: A260 = 1.00, A260/A280 ≈ 1.9, A260/A230 ≈ 2.2
  /// (two Gaussian bands; no in-band gate here).
  static func dnaAbsorbance(_ lambda: Double) -> Double {
    let nm = lambda * 1e9
    let d1 = nm - 259, d2 = nm - 195
    return exp(-(d1 * d1) / (2 * (18.6 * 18.6))) + 2.3 * exp(-(d2 * d2) / (2 * (15.0 * 15.0)))
  }

  /// Beam remaining after each specimen in turn (the oscillator and antenna pass it through).
  struct SeriesStep: Hashable, Sendable {
    let key: SpecimenKey
    let before: Double
    let after: Double
  }

  static func inSeries(_ lambda: Double, source: WaveSource?, list: [SpecimenKey] = SpecimenKey.allCases) -> [SeriesStep] {
    var remaining = 1.0
    return list.map { key in
      let r = key.evaluate(lambda, source: source)
      let before = remaining
      if let t = r.transmission { remaining *= t }
      return SeriesStep(key: key, before: before, after: remaining)
    }
  }

  // MARK: Specimens

  private static func highEnergyNote(_ lambda: Double) -> String {
    let ev = Spectrum.photonEV(lambda)
    if ev >= SI.pairThresholdEV {
      return "Above 1.022 MeV a photon near a nucleus can become an electron\u{2013}positron pair."
    }
    if ev >= 1e5 { return "Mostly Compton scattering: photons bounce off electrons and lose energy." }
    return "Photoabsorption: the photon is swallowed and an inner electron is knocked out."
  }

  fileprivate static func oscillator(_ lambda: Double, _ opts: SpecimenOptions) -> SpecimenResult {
    let lambda0 = opts.lambda0, q = opts.q
    let w = (Wave.tau * SI.c) / lambda, w0 = (Wave.tau * SI.c) / lambda0
    let r = Matter.oscillatorResponse(omega: w, omega0: w0, gamma: w0 / q)
    let regime: SpecimenResponse.Regime = lambda > lambda0 * 1.15 ? .below : lambda < lambda0 / 1.15 ? .above : .on
    let text: String =
      switch regime {
      case .below:
        "Driven below its resonance, the charge follows the field in step. That only slows the wave, which is the origin of the refractive index."
      case .on: "On resonance it swings hardest, a quarter cycle behind the field, and absorbs energy."
      case .above:
        "Driven far above resonance, it can't keep up: tiny motion, half a cycle behind. The wave passes almost untouched."
      }
    return SpecimenResult(
      source: .model,
      response: SpecimenResponse(kind: .spring, text: text, amplitude: r.amplitude, lag: r.lag, power: r.power, regime: regime))
  }

  /// Half-wave dipole tuned to 100 MHz; odd harmonics also resonate. Q ≈ 8 (illustrative).
  fileprivate static func antenna(_ lambda: Double) -> SpecimenResult {
    let f = SI.c / lambda, f0 = 100e6, q = 8.0
    var current = 0.0
    for (n, weight) in [(1.0, 1.0), (3.0, 0.55), (5.0, 0.4)] {
      let fn = n * f0, x = q * (f / fn - fn / f)
      current = JSMath.max(current, weight / (1 + x * x).squareRoot())
    }
    let band = Spectrum.band(at: lambda).key
    let text =
      current > 0.5
      ? "Resonant: half a wavelength fits the rods, so electrons slosh end to end and drive a current."
      : band == .radio || band == .microwave
        ? "Off resonance: the field pushes electrons, but the rods are the wrong length to build a current."
        : "Far too short a wave: the rods are just a metal surface that reflects it."
    return SpecimenResult(source: .model, response: SpecimenResponse(kind: .current, text: text, value: current))
  }

  fileprivate static func water(_ lambda: Double, _ src: WaveSource?) -> SpecimenResult {
    let (alpha, source) = waterAlpha(lambda)
    let d = 1.0
    let t = exp(-alpha * d)
    // Heating at the front face: absorbed power density α·I over ρ·c_p (4.18 J/cm³/K).
    let intensity = src.map { Wave.intensity(e0: $0.e0) } ?? 0  // W/m²
    let heating = ((alpha * 100 * intensity) / 4.18e6) * 60  // K per minute
    let band = Spectrum.band(at: lambda).key
    let text: String =
      switch band {
      case .radio: "Molecules turn to follow the field but lag behind it, so a little energy turns to heat."
      case .microwave:
        "Water molecules twist after the field and lag behind it (Debye relaxation), so the water heats."
      case .ir: "Bonds stretch and bend in resonance, and water absorbs most infrared in a fraction of a millimeter."
      case .visible:
        "Nearly transparent. Red is absorbed slightly more than blue, which is why deep water looks blue."
      case .uv:
        lambda < 180e-9 ? "Electrons in the molecule absorb it within micrometers." : "Mostly transparent until the deep UV."
      case .xray, .gamma: highEnergyNote(lambda)
      }
    let kind: SpecimenResponse.Kind = band == .microwave || band == .radio ? .twist : band == .ir ? .stretch : .pass
    return SpecimenResult(
      transmission: t, reflection: 0, absorption: 1 - t, alpha: alpha, source: source,
      response: SpecimenResponse(kind: kind, text: text, heating: heating))
  }

  /// Borosilicate optical absorption: typical 3 mm transmission curves (MODEL anchors), [λ m, α 1/cm].
  private static let glassAlpha = LogLogTable(rows: [
    (100e-9, 4e5), (200e-9, 100), (260e-9, 30), (280e-9, 5), (300e-9, 1.5), (320e-9, 0.4), (350e-9, 0.05),
    (400e-9, 0.004), (2.0e-6, 0.004), (2.7e-6, 0.5), (3.0e-6, 0.3), (3.5e-6, 0.6), (4.0e-6, 2), (4.5e-6, 8),
    (5e-6, 30), (6e-6, 300), (9e-6, 5000), (20e-6, 2000), (100e-6, 100), (1e-3, 3), (1e-2, 0.1), (0.1, 0.01),
    (1, 0.001), (1e3, 1e-6),
  ])

  /// Borosilicate sheet, 3 mm: X-ray/gamma from NIST Pyrex (TABLE), optical anchors and BK7
  /// reflection elsewhere (MODEL).
  fileprivate static func glass(_ lambda: Double) -> SpecimenResult {
    if isXray(lambda) {
      let t = exp(-(Matter.linearAttenuation(.pyrex, eV: Spectrum.photonEV(lambda)) ?? 0) * 0.3)
      return SpecimenResult(
        transmission: t, reflection: 0, absorption: 1 - t, source: .table,
        response: SpecimenResponse(kind: .pass, text: highEnergyNote(lambda)))
    }
    let alpha =
      lambda < 100e-9
      ? Matter.bridge(lambda, 100e-9, 4e5, Matter.xcomLambdaMax, Matter.linearAttenuation(.pyrex, eV: 1e3) ?? 0)
      : Matter.anchors(glassAlpha, lambda)
    let n = Matter.Medium.glass.index(lambda).n
    let r = Matter.slab(r: Matter.normalReflectance(n: n), alphaPerCm: alpha, thicknessCm: 0.3)
    let band = Spectrum.band(at: lambda).key
    let text: String =
      switch band {
      case .visible:
        "Clear: its electrons resonate in the UV and its atoms in the IR, leaving a window for visible light."
      case .uv: "Blocked: the wave is close to the glass's electronic resonance, so it is absorbed."
      case .ir:
        lambda > 5e-6
          ? "Opaque: the silicon\u{2013}oxygen lattice vibrates in resonance and soaks it up." : "Mostly clear in the near infrared."
      default: "Passes: glass has no free electrons to stop it; a little reflects at each face."
      }
    return SpecimenResult(
      transmission: r.t, reflection: r.r, absorption: r.a, alpha: alpha, source: .model,
      response: SpecimenResponse(kind: r.t > 0.5 ? .pass : .absorb, text: text))
  }

  /// Zinc plate, 1 mm: free-electron reflection, the photoelectric threshold, NIST attenuation
  /// for X-rays.
  fileprivate static func zinc(_ lambda: Double) -> SpecimenResult {
    let ev = Spectrum.photonEV(lambda), phi = Matter.zincWorkFunction
    let keMax: Double? = ev > phi ? ev - phi : nil
    let phiText = JSFormat.jsString(phi)
    let ejectText: String
    if let ke = keMax {
      let amount = ke < 1e3 ? JSFormat.toFixed(ke, 2) + " eV" : JSFormat.toFixed(ke / 1e3, 1) + " keV"
      ejectText = "Photons above the \(phiText) eV work function knock electrons out, at up to \(amount)."
    } else {
      ejectText = "Below the \(phiText) eV work function: no electrons come out, however bright the beam."
    }
    if isXray(lambda) {
      let t = exp(-(Matter.linearAttenuation(.zinc, eV: ev) ?? 0) * 0.1)
      return SpecimenResult(
        transmission: t, reflection: 0, absorption: 1 - t, source: .table,
        response: SpecimenResponse(kind: .eject, text: ejectText + " " + highEnergyNote(lambda), ejectKeMax: keMax))
    }
    let w = (Wave.tau * SI.c) / lambda
    let ix = Matter.index(fromEpsilon: Matter.drudeEpsilon(omega: w, wp: Matter.zinc.wp, gamma: Matter.zinc.gamma))
    let r = Matter.slab(
      r: Matter.normalReflectance(n: ix.n, k: ix.k), alphaPerCm: Matter.absorptionFromK(ix.k, lambda: lambda),
      thicknessCm: 0.1)
    let mirror = r.r > 0.5 ? "Free electrons shake and re-radiate, so the metal reflects like a mirror. " : ""
    return SpecimenResult(
      transmission: r.t, reflection: r.r, absorption: r.a, source: .model,
      response: SpecimenResponse(kind: keMax != nil ? .eject : .reflect, text: mirror + ejectText, ejectKeMax: keMax))
  }

  /// DNA in water: the water result times 10^−A inside 150–400 nm.
  fileprivate static func dna(_ lambda: Double, _ src: WaveSource?) -> SpecimenResult {
    let w = water(lambda, src)
    let inBand = lambda > 150e-9 && lambda < 400e-9
    let a = inBand ? dnaAbsorbance(lambda) : 0
    let t = (w.transmission ?? 0) * pow(10, -a)
    let resonance = a > 0.3
    let text =
      resonance
      ? "The bases absorb strongly near 260 nm. Neighbouring thymines can fuse into dimers, which is the damage behind sunburn."
      : inBand ? "DNA barely absorbs here." : "DNA is transparent here; the surrounding water decides what happens."
    return SpecimenResult(
      transmission: t, reflection: 0, absorption: 1 - t, absorbance: a, source: inBand ? .model : w.source,
      response: SpecimenResponse(kind: resonance ? .dimer : .pass, text: text, resonance: resonance))
  }

  /// Soft tissue effective attenuation, optical anchors after Jacques 2013, [λ m, α 1/cm].
  private static let tissueOptical = LogLogTable(rows: [
    (200e-9, 500), (300e-9, 150), (400e-9, 60), (450e-9, 40), (500e-9, 25), (550e-9, 20), (600e-9, 8), (650e-9, 4),
    (700e-9, 3), (800e-9, 2.5), (900e-9, 2.6), (1000e-9, 3), (1200e-9, 4), (1450e-9, 25), (1700e-9, 8), (1940e-9, 60),
  ])
  /// Muscle at microwave/RF, after Gabriel 1996, [λ m, α 1/cm].
  private static let tissueRF = LogLogTable(rows: [(3e-2, 6), (0.1224, 0.9), (3, 0.26), (300, 0.025)])

  private static func tissueAlpha(_ lambda: Double) -> (alpha: Double, source: CoreProvenance) {
    if isXray(lambda) { return (Matter.linearAttenuation(.tissue, eV: Spectrum.photonEV(lambda)) ?? 0, .table) }
    if lambda < 200e-9 {
      return (Matter.bridge(lambda, 200e-9, 500, Matter.xcomLambdaMax, Matter.linearAttenuation(.tissue, eV: 1e3) ?? 0), .model)
    }
    if lambda <= 1940e-9 { return (Matter.anchors(tissueOptical, lambda), .model) }
    if lambda <= 3e-3 { return (0.7 * waterAlpha(lambda).alpha, .model) }
    if lambda < 3e-2 { return (Matter.bridge(lambda, 3e-3, 0.7 * waterAlpha(3e-3).alpha, 3e-2, 6), .model) }
    return (Matter.anchors(tissueRF, lambda), .model)
  }

  /// A finger: two paths through 3 cm, one all soft tissue, one with 1 cm of cortical bone.
  fileprivate static func hand(_ lambda: Double) -> SpecimenResult {
    let tissue = tissueAlpha(lambda)
    let softT = exp(-tissue.alpha * 3)
    var source = tissue.source
    let boneT: Double
    if isXray(lambda) {
      boneT = exp(-(Matter.linearAttenuation(.bone, eV: Spectrum.photonEV(lambda)) ?? 0) * 1 - tissue.alpha * 2)
    } else {
      boneT = exp(-tissue.alpha * 1.2 * 1 - tissue.alpha * 2)
      source = .model
    }
    let contrast = softT > 1e-12 ? 1 - boneT / softT : 0
    let band = Spectrum.band(at: lambda).key
    let text: String =
      switch band {
      case .xray:
        softT > 0.05
          ? "Bone stops more than soft tissue, so its shadow shows \(JSFormat.jsString(JSMath.round(contrast * 100)))% darker."
          : "Too soft: almost nothing gets through, so the film would be blank."
      case .gamma: "Passes through bone and tissue almost alike, so there's little contrast."
      case .visible:
        lambda > 600e-9
          ? "Red light scatters through and the fingertip glows; blood absorbs the rest of the colors."
          : "Blood and skin absorb it within millimeters."
      case .ir:
        lambda < 1.4e-6
          ? "Near infrared goes deepest of all; pulse oximeters use this window."
          : "Water in the tissue absorbs it at the surface; you feel it as warmth."
      case .uv: "Absorbed in the outer skin; this is what tans and burns."
      default: "Penetrates centimeters and deposits heat; how deep depends on frequency."
      }
    let kind: SpecimenResponse.Kind = band == .xray ? .shadow : softT > 0.05 ? .glow : .absorb
    return SpecimenResult(
      transmission: softT, reflection: 0, absorption: 1 - softT, boneT: boneT, contrast: contrast, source: source,
      response: SpecimenResponse(kind: kind, text: text))
  }
}
