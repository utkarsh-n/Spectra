import Foundation

/// Wavelength, frequency and photon-energy bookkeeping for the whole spectrum (port of
/// spectra-lab `core/spectrum.js`; the string formatters live in `JSFormat`).
///
/// Wavelengths are vacuum wavelengths in metres throughout.
nonisolated enum Spectrum {
  // MARK: Ranges

  /// Lower end of the source dial: 0.1 pm (12.4 MeV). Parity value of `LOG_MIN`.
  static let logMin: Double = -13
  /// Upper end of the source dial: 1 km (300 kHz). Parity value of `LOG_MAX`; `sanitize`
  /// clamps to it by default.
  static let logMax: Double = 3
  /// `logMin...logMax`, the web prototype's range and the default everywhere.
  static let logRange: ClosedRange<Double> = logMin...logMax

  /// Lower end of the native Spectrum ruler (same as `logMin`).
  static let rulerLogMin: Double = -13
  /// Upper end of the native Spectrum ruler: 100,000 km (3 Hz), far enough for Earth-field
  /// NMR (~141 km), mains hum (5,000–6,000 km) and the Schumann resonance (~38,000 km).
  static let rulerLogMax: Double = 8
  /// `rulerLogMin...rulerLogMax`. Opt in with `SpectraState.extendedRange` or by passing it
  /// to `WaveSource.sanitize(logRange:)`; nothing uses it by default.
  static let rulerLogRange: ClosedRange<Double> = rulerLogMin...rulerLogMax

  // MARK: Conversions

  /// f = c/λ, Hz.
  static func frequency(_ lambda: Double) -> Double { SI.c / lambda }
  /// λ = c/f, m.
  static func wavelength(frequency f: Double) -> Double { SI.c / f }
  /// Photon energy hc/λ, eV.
  static func photonEV(_ lambda: Double) -> Double { SI.hcEVm / lambda }
  /// λ = hc/E for a photon energy in eV.
  static func wavelength(eV: Double) -> Double { SI.hcEVm / eV }
  /// eV per particle → kcal/mol.
  static func kcalPerMol(eV: Double) -> Double { eV * SI.eVToKcalPerMol }
  /// eV per particle → kJ/mol.
  static func kjPerMol(eV: Double) -> Double { eV * SI.eVToKJPerMol }
  /// Wavenumber 1/λ in cm⁻¹.
  static func wavenumber(_ lambda: Double) -> Double { 1 / (lambda * 100) }
  /// λ in m from a wavenumber in cm⁻¹.
  static func wavelength(wavenumber nu: Double) -> Double { 1 / (nu * 100) }
  /// Clamps log₁₀ λ to the dial range (JS `clampLog`; a NaN input returns `logMin`, where JS
  /// keeps NaN).
  static func clampLog(_ lg: Double) -> Double { min(logMax, max(logMin, lg)) }
  /// Clamps log₁₀ λ to the extended ruler range.
  static func clampRulerLog(_ lg: Double) -> Double { min(rulerLogMax, max(rulerLogMin, lg)) }

  // MARK: Bands

  /// The seven conventional bands. Gamma and X-ray overlap in nature (they are named by
  /// origin); the toy splits them at 10 pm, as the poster does.
  enum BandKey: String, CaseIterable, Codable, Sendable, Identifiable {
    case gamma, xray, uv, visible, ir, microwave, radio
    var id: String { rawValue }
  }

  /// One band: `lo ≤ λ < hi`, with its palette colour (uppercase hex, as in the JS).
  struct Band: Hashable, Sendable, Identifiable {
    let key: BandKey
    let name: String
    let short: String
    let lo: Double
    let hi: Double
    let colorHex: String
    var id: BandKey { key }
  }

  static let bands: [Band] = [
    Band(key: .gamma, name: "Gamma", short: "\u{03B3}", lo: 0, hi: 1e-11, colorHex: "#E2D4FF"),
    Band(key: .xray, name: "X-ray", short: "X", lo: 1e-11, hi: 1e-8, colorHex: "#8FD3FF"),
    Band(key: .uv, name: "Ultraviolet", short: "UV", lo: 1e-8, hi: 400e-9, colorHex: "#B583FF"),
    Band(key: .visible, name: "Visible", short: "Vis", lo: 400e-9, hi: 700e-9, colorHex: "#A8FF3E"),
    Band(key: .ir, name: "Infrared", short: "IR", lo: 700e-9, hi: 1e-3, colorHex: "#FF7A6B"),
    Band(key: .microwave, name: "Microwave", short: "\u{00B5}W", lo: 1e-3, hi: 1, colorHex: "#5FD3BC"),
    Band(key: .radio, name: "Radio", short: "Radio", lo: 1, hi: .infinity, colorHex: "#9DB0CC"),
  ]

  /// The band record for a key.
  static func band(_ key: BandKey) -> Band { bands.first { $0.key == key } ?? bands[bands.count - 1] }

  /// The first band with `lo ≤ λ < hi`, else radio (so NaN and ∞ are radio, and 0 is gamma).
  static func band(at lambda: Double) -> Band {
    bands.first { lambda >= $0.lo && lambda < $0.hi } ?? bands[bands.count - 1]
  }

  /// Representative wavelength each band button jumps to (spectra-lab `app.js`).
  static let bandJump: [BandKey: Double] = [
    .gamma: 1.24e-12, .xray: 20.7e-12, .uv: 254e-9, .visible: 550e-9, .ir: 9.3e-6, .microwave: 0.1224, .radio: 3,
  ]

  private static let subBands: [(lo: Double, hi: Double, name: String)] = [
    (1e-11, 1e-8, "Hard \u{2192} soft X-ray"),
    (1e-8, 100e-9, "Extreme UV"),
    (100e-9, 280e-9, "UV-C"),
    (280e-9, 315e-9, "UV-B"),
    (315e-9, 400e-9, "UV-A"),
    (700e-9, 1.4e-6, "Near IR"),
    (1.4e-6, 3e-6, "Short-wave IR"),
    (3e-6, 8e-6, "Mid-wave IR"),
    (8e-6, 15e-6, "Long-wave IR (thermal)"),
    (15e-6, 1e-3, "Far IR"),
    (1e-3, 1e-2, "Millimeter wave (EHF)"),
    (1e-2, 1e-1, "SHF \u{00B7} centimeter"),
    (1e-1, 1, "UHF"),
    (1, 10, "VHF"),
    (10, 100, "HF \u{00B7} shortwave"),
    (100, 1000, "MF \u{00B7} AM broadcast"),
  ]

  /// Finer name for a wavelength ("UV-B", "Visible · green", "Gamma above 1 MeV"); above
  /// 1 km it falls back to the band name.
  static func subBand(at lambda: Double) -> String {
    if lambda < 1e-11 { return lambda < 1.2398e-12 ? "Gamma above 1 MeV" : "Gamma" }
    if lambda >= 400e-9 && lambda < 700e-9 { return "Visible \u{00B7} " + hueName(nm: lambda * 1e9) }
    if let s = subBands.first(where: { lambda >= $0.lo && lambda < $0.hi }) { return s.name }
    return band(at: lambda).name
  }

  /// Colour word for a visible wavelength in nm.
  static func hueName(nm: Double) -> String {
    if nm < 450 { return "violet" }
    if nm < 495 { return "blue" }
    if nm < 520 { return "cyan" }
    if nm < 570 { return "green" }
    if nm < 590 { return "yellow" }
    if nm < 620 { return "orange" }
    return "red"
  }

  /// What a photon of this energy can do to matter, coarsely.
  enum IonizationClass: String, CaseIterable, Codable, Sendable {
    case ionizing, bond, none
    var label: String {
      switch self {
      case .ionizing: "Ionizing"
      case .bond: "Can break bonds"
      case .none: "Non-ionizing"
      }
    }
  }

  /// ≥ 10 eV ionizing; above the violet edge (3.0996 eV) bond-breaking; else non-ionizing.
  static func ionizationClass(_ lambda: Double) -> IonizationClass {
    let ev = photonEV(lambda)
    if ev >= SI.ionizingEV { return .ionizing }
    if ev > SI.visibleEdgeEV { return .bond }
    return .none
  }

  // MARK: Colour

  /// Approximate perceived colour of monochromatic light (Bruton's piecewise fit), linear 0…1.
  /// Zero outside 380–780 nm.
  static func spectralRGB(nm: Double) -> SIMD3<Double> {
    var r = 0.0, g = 0.0, b = 0.0
    if nm >= 380 && nm < 440 {
      r = (440 - nm) / 60
      b = 1
    } else if nm < 490 {
      g = (nm - 440) / 50
      b = 1
    } else if nm < 510 {
      g = 1
      b = (510 - nm) / 20
    } else if nm < 580 {
      r = (nm - 510) / 70
      g = 1
    } else if nm < 645 {
      r = 1
      g = (645 - nm) / 65
    } else if nm <= 780 {
      r = 1
    }
    var k = 1.0
    if nm < 420 {
      k = 0.3 + (0.7 * (nm - 380)) / 40
    } else if nm > 700 {
      k = 0.3 + (0.7 * (780 - nm)) / 80
    }
    if nm < 380 || nm > 780 { k = 0 }
    return SIMD3(r * k, g * k, b * k)
  }

  /// Display colour for a wavelength: the true hue in the visible band, lifted for a dark
  /// screen (lowercase hex, `0.16 + 0.84·c^0.8`), and the band palette elsewhere (uppercase).
  static func displayColorHex(_ lambda: Double) -> String {
    let b = band(at: lambda)
    if b.key != .visible { return b.colorHex }
    let rgb = spectralRGB(nm: lambda * 1e9)
    func lift(_ c: Double) -> Double { 0.16 + 0.84 * pow(c, 0.8) }
    return hex(lift(rgb.x), lift(rgb.y), lift(rgb.z))
  }

  /// `displayColorHex` as linear 0…1 components (each channel is the hex byte / 255).
  static func displayRGB(_ lambda: Double) -> SIMD3<Double> { rgb(hex: displayColorHex(lambda)) }

  /// Parses `#RRGGBB` (either case) into 0…1 components; black for malformed input.
  static func rgb(hex: String) -> SIMD3<Double> {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return .zero }
    return SIMD3(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF)) / 255
  }

  /// JS `"#" + [r,g,b].map(v => Math.round(clamp01(v)·255).toString(16).padStart(2, "0"))`.
  private static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
    "#" + [r, g, b].map { v -> String in
      let byte = Int(JSMath.round(JSMath.clamp(v, 0, 1) * 255))
      let s = String(byte, radix: 16)
      return s.count < 2 ? "0" + s : s
    }.joined()
  }

  // MARK: Detents

  /// A haptic/audible detent on the λ dial: a band edge or the ionizing threshold (and, on the
  /// native extended ruler only, a long-wave landmark).
  struct Detent: Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
      case band, ionizing
      /// A `longWaveLandmarks` mark beyond 1 km (`rulerDetents` only; never in `detents`).
      case landmark
    }
    /// log₁₀ λ of the detent.
    let log: Double
    let kind: Kind
    let label: String
  }

  /// Band lower edges (X-ray … Radio) then the ionizing threshold hc/10 eV.
  static let detents: [Detent] =
    bands.dropFirst().map { Detent(log: log10($0.lo), kind: .band, label: $0.name) }
    + [Detent(log: log10(SI.hcEVm / SI.ionizingEV), kind: .ionizing, label: "Ionizing")]

  /// Detents strictly above the lower and at or below the upper of two log₁₀ λ values
  /// (half-open (lo, hi]), in table order. Fire one haptic per result on a λ edit.
  static func crossedDetents(fromLog: Double, toLog: Double) -> [Detent] {
    let lo = JSMath.min(fromLog, toLog), hi = JSMath.max(fromLog, toLog)
    return detents.filter { $0.log > lo && $0.log <= hi }
  }

  // MARK: Size comparisons

  /// An everyday object whose size is one wavelength somewhere on the ruler.
  struct SizeComparison: Hashable, Sendable {
    let size: Double
    let label: String
  }

  static let sizeComparisons: [SizeComparison] = [
    SizeComparison(size: 1e-14, label: "an atomic nucleus"),
    SizeComparison(size: 1e-10, label: "an atom"),
    SizeComparison(size: 1e-9, label: "a sugar molecule"),
    SizeComparison(size: 1e-7, label: "a virus"),
    SizeComparison(size: 5e-7, label: "the width of E. coli"),
    SizeComparison(size: 1e-5, label: "a cell"),
    SizeComparison(size: 1e-3, label: "a pinhead"),
    SizeComparison(size: 1.2e-2, label: "a bee"),
    SizeComparison(size: 1.7, label: "a person"),
    SizeComparison(size: 100, label: "a football field"),
  ]

  /// The nearest size comparison on a log scale, with λ/size and the distance in decades.
  struct Comparison: Hashable, Sendable {
    let size: Double
    let label: String
    let ratio: Double
    let decades: Double
  }

  static func nearestComparison(_ lambda: Double) -> Comparison {
    var best = sizeComparisons[0]
    var d = Double.infinity
    for c in sizeComparisons {
      let dd = abs(log10(c.size) - log10(lambda))
      if dd < d {
        d = dd
        best = c
      }
    }
    return Comparison(size: best.size, label: best.label, ratio: lambda / best.size, decades: d)
  }

  // MARK: Long-wave bands (native ruler only)

  /// ITU-R V.431 names for the decades beyond the web range (λ ≥ 1 km): LF 30–300 kHz,
  /// VLF 3–30 kHz, ULF 300–3,000 Hz, SLF 30–300 Hz, ELF 3–30 Hz.
  private static let rulerSubBands: [(lo: Double, hi: Double, name: String)] = [
    (1e3, 1e4, "LF \u{00B7} longwave"),
    (1e4, 1e5, "VLF"),
    (1e5, 1e6, "ULF"),
    (1e6, 1e7, "SLF"),
    (1e7, 1e8, "ELF"),
  ]

  /// `subBand(at:)` extended over the native ruler: identical below 1 km (so parity is
  /// untouched), the ITU band name from 1 km to 100,000 km, and "Radio" beyond.
  static func rulerSubBand(at lambda: Double) -> String {
    if let s = rulerSubBands.first(where: { lambda >= $0.lo && lambda < $0.hi }) { return s.name }
    return subBand(at: lambda)
  }

  // MARK: Long-wave landmarks (native ruler only)

  /// A fixed mark on the extended ruler beyond the web range (above 1 km).
  struct Landmark: Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    /// Frequency, Hz.
    let frequency: Double
    /// Vacuum wavelength c/f, m.
    var lambda: Double { SI.c / frequency }
  }

  /// Earth-field NMR of water protons at 50 µT (γ′ₚ·B = 2,128.82 Hz, λ = 140.83 km; the
  /// shielded γ′ₚ, as in gyre-integration.md §4.1 and the Spin engine), mains hum at 60 and
  /// 50 Hz (≈ 4,997 and 5,996 km) and the Schumann resonance fundamental 7.83 Hz (≈ 38,000 km).
  static let longWaveLandmarks: [Landmark] = [
    Landmark(
      id: "earthNMR", label: "Earth-field NMR (50 \u{00B5}T)", frequency: SI.gammaProtonShieldedHzPerT * 50e-6),
    Landmark(id: "mains60", label: "Mains hum 60 Hz", frequency: 60),
    Landmark(id: "mains50", label: "Mains hum 50 Hz", frequency: 50),
    Landmark(id: "schumann", label: "Schumann resonance", frequency: 7.83),
  ]

  /// The extended ruler's detents: the web `detents` (band edges and the ionizing line) plus
  /// one `.landmark` detent per `longWaveLandmarks` mark (Earth-field NMR, mains 60/50 Hz,
  /// Schumann), as gyre-integration.md §5.6 asks for. Label = the landmark's label.
  static let rulerDetents: [Detent] =
    detents + longWaveLandmarks.map { Detent(log: log10($0.lambda), kind: .landmark, label: $0.label) }

  /// `crossedDetents` over `rulerDetents`: identical below 1 km, plus the long-wave landmarks
  /// crossed, half-open (lo, hi] and in table order. Use it when `SpectraState.extendedRange`
  /// is on.
  static func crossedRulerDetents(fromLog: Double, toLog: Double) -> [Detent] {
    let lo = JSMath.min(fromLog, toLog), hi = JSMath.max(fromLog, toLog)
    return rulerDetents.filter { $0.log > lo && $0.log <= hi }
  }

  // MARK: Describe

  /// Everything a readout needs for one wavelength (JS `describe`).
  static func describe(_ lambda: Double) -> WaveDescription {
    let ev = photonEV(lambda)
    let f = frequency(lambda)
    return WaveDescription(
      lambda: lambda, f: f, ev: ev, band: band(at: lambda), sub: subBand(at: lambda), ion: ionizationClass(lambda),
      colorHex: displayColorHex(lambda),
      text: WaveDescription.Text(
        lambda: JSFormat.length(lambda), f: JSFormat.frequency(f), ev: JSFormat.energy(ev),
        kcal: JSFormat.kcal(eV: ev), wavenumber: JSFormat.sig3(wavenumber(lambda)) + " cm\u{207B}\u{00B9}"))
  }
}

/// Readout bundle for one wavelength (JS `describe(λ)`): numbers, band, sub-band, ionization
/// class, display colour and the formatted strings.
nonisolated struct WaveDescription: Hashable, Sendable {
  /// The formatted readout strings, JS-exact.
  struct Text: Hashable, Sendable {
    var lambda: String
    var f: String
    var ev: String
    var kcal: String
    var wavenumber: String
  }

  var lambda: Double
  var f: Double
  var ev: Double
  var band: Spectrum.Band
  var sub: String
  var ion: Spectrum.IonizationClass
  var colorHex: String
  var text: Text
}
