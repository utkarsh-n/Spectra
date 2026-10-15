import Foundation

/// Plain, readable number formatting for readouts and labels ("2.44 GHz", "12.3 cm",
/// "1.8 × 10¹⁵"). Not the JS-exact formatters that `Core/` uses for parity tests.
nonisolated enum SpectraFormat {
  /// `x` to `digits` significant figures, trailing zeros removed ("2.44", "60", "0.000123").
  static func significant(_ x: Double, _ digits: Int = 3) -> String {
    guard x.isFinite else { return x.isNaN ? "—" : (x > 0 ? "∞" : "−∞") }
    guard x != 0 else { return "0" }
    let d = max(1, digits)
    let exponent = Int(floor(log10(abs(x))))
    let decimals = max(0, d - 1 - exponent)
    var text = String(format: "%.\(min(decimals, 15))f", x)
    if text.contains(".") {
      while text.hasSuffix("0") { text.removeLast() }
      if text.hasSuffix(".") { text.removeLast() }
    }
    if text.hasPrefix("-") { text = "−" + text.dropFirst() }
    return text
  }

  /// Unicode superscript digits for an integer exponent ("¹⁵", "⁻³").
  static func superscript(_ n: Int) -> String {
    let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
    let body = String(abs(n)).compactMap { c in c.wholeNumberValue.map { digits[$0] } }
    return (n < 0 ? "⁻" : "") + String(body)
  }

  /// Scientific notation with a real times sign: "1.8 × 10¹⁵". Numbers between 0.01 and
  /// 10,000 are written plainly.
  static func scientific(_ x: Double, digits: Int = 3) -> String {
    guard x.isFinite, x != 0 else { return significant(x, digits) }
    let exponent = Int(floor(log10(abs(x))))
    if (-2...3).contains(exponent) { return significant(x, digits) }
    var mantissa = x / pow(10, Double(exponent))
    var e = exponent
    if abs(Double(significant(mantissa, digits)) ?? mantissa) >= 10 {
      mantissa /= 10
      e += 1
    }
    let m = significant(mantissa, digits)
    return m == "1" ? "10\(superscript(e))" : "\(m) × 10\(superscript(e))"
  }

  private static let prefixes: [(Int, String)] = [
    (-24, "y"), (-21, "z"), (-18, "a"), (-15, "f"), (-12, "p"), (-9, "n"), (-6, "µ"), (-3, "m"),
    (0, ""), (3, "k"), (6, "M"), (9, "G"), (12, "T"), (15, "P"), (18, "E"), (21, "Z"), (24, "Y"),
  ]

  /// A value with an SI prefix: `si(2.44e9, unit: "Hz")` → "2.44 GHz".
  static func si(_ value: Double, unit: String, digits: Int = 3) -> String {
    guard value.isFinite else { return significant(value) + " " + unit }
    guard value != 0 else { return "0 " + unit }
    let exponent = Int(floor(log10(abs(value))))
    var power = Int((Double(exponent) / 3).rounded(.down)) * 3
    power = min(24, max(-24, power))
    var mantissa = value / pow(10, Double(power))
    if abs(Double(significant(mantissa, digits)) ?? mantissa) >= 1000, power < 24 {
      power += 3
      mantissa = value / pow(10, Double(power))
    }
    let prefix = prefixes.first { $0.0 == power }?.1 ?? ""
    return "\(significant(mantissa, digits)) \(prefix)\(unit)"
  }

  /// Frequency with an SI prefix ("60 Hz", "2.44 GHz", "545 THz").
  static func frequency(_ hertz: Double, digits: Int = 3) -> String {
    si(hertz, unit: "Hz", digits: digits)
  }

  /// Wavelength in the friendliest unit ("550 nm", "12.3 cm", "140.8 km", "0.1 pm").
  static func wavelength(_ metres: Double, digits: Int = 3) -> String {
    guard metres.isFinite, metres > 0 else { return significant(metres) + " m" }
    let units: [(Double, String)] = [
      (1e3, "km"), (1, "m"), (1e-2, "cm"), (1e-3, "mm"), (1e-6, "µm"), (1e-9, "nm"), (1e-12, "pm"), (1e-15, "fm"),
    ]
    for (scale, name) in units where metres >= scale * 0.999_5 {
      return "\(significant(metres / scale, digits)) \(name)"
    }
    return "\(significant(metres / 1e-15, digits)) fm"
  }

  /// Decibels with a unit ("−67 dBm", "+3.0 dB").
  static func decibels(_ value: Double, unit: String = "dB", decimals: Int = 1, signed: Bool = false) -> String {
    guard value.isFinite else { return "— \(unit)" }
    var text = String(format: "%.\(max(0, decimals))f", value)
    if signed, value > 0 { text = "+" + text }
    if text.hasPrefix("-") { text = "−" + text.dropFirst() }
    return "\(text) \(unit)"
  }

  /// Clock text "MM:SS.hh" (Orbitals' transport clock).
  static func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--.--" }
    let t = max(0, seconds)
    let minutes = Int(t / 60)
    let secs = Int(t) % 60
    let hundredths = Int((t - floor(t)) * 100)
    return String(format: "%02d:%02d.%02d", minutes, secs, hundredths)
  }

  /// A measured sample rate ("99.8 Hz", "48 kHz", "irregular").
  static func rate(_ hertz: Double?) -> String {
    guard let hertz, hertz.isFinite, hertz > 0 else { return "irregular" }
    return frequency(hertz, digits: 3)
  }
}
