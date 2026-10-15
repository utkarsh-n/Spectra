import Foundation

/// JS-exact number formatting (port of the formatting half of spectra-lab `core/spectrum.js`).
///
/// `toFixed` and `toPrecision` follow ECMAScript exactly: they round the *exact binary value*
/// and break exact ties away from zero. `String(format:)` breaks ties to even and Swift's
/// `FormatStyle` rounds the shortest decimal instead, so neither is used for parity strings.
/// Unicode is copied code point for code point: µ is U+00B5 MICRO SIGN, × is U+00D7, and the
/// superscripts are ⁻ U+207B, ⁰ U+2070, ¹ U+00B9, ² U+00B2, ³ U+00B3, ⁴…⁹ U+2074…2079.
nonisolated enum JSFormat {
  /// U+00B5 MICRO SIGN (not U+03BC GREEK SMALL LETTER MU).
  static let micro = "\u{00B5}"
  /// U+00D7 MULTIPLICATION SIGN.
  static let times = "\u{00D7}"

  // MARK: ECMAScript Number formatting

  /// `x.toFixed(digits)`. Values with |x| ≥ 1e21 and non-finite values print like `String(x)`.
  static func toFixed(_ x: Double, _ digits: Int) -> String {
    guard x.isFinite, abs(x) < 1e21 else { return jsString(x) }
    let f = max(0, digits)
    let negative = x < 0  // −0 prints without a sign, as in JS
    var (d, intCount) = exactDecimal(abs(x))
    while d.count < intCount + f + 1 { d.append(0) }
    var kept = Array(d[0..<(intCount + f)])
    if d[intCount + f] >= 5 && increment(&kept) {
      kept.insert(1, at: 0)
      intCount += 1
    }
    var intPart = kept[0..<intCount].drop { $0 == 0 }
    if intPart.isEmpty { intPart = [0] }
    var out = negative ? "-" : ""
    out += digitString(intPart)
    if f > 0 { out += "." + digitString(kept[intCount...]) }
    return out
  }

  /// `x.toPrecision(precision)`: fixed notation for decimal exponents −6…precision−1,
  /// exponential (`1.23e-7`, `1e+21`) otherwise.
  static func toPrecision(_ x: Double, _ precision: Int) -> String {
    guard x.isFinite else { return jsString(x) }
    let p = max(1, precision)
    if x == 0 { return p > 1 ? "0." + String(repeating: "0", count: p - 1) : "0" }
    let sign = x < 0 ? "-" : ""
    let (d, intCount) = exactDecimal(abs(x))
    let first = d.firstIndex { $0 != 0 } ?? 0
    var e = intCount - 1 - first
    var sig = (0..<p).map { first + $0 < d.count ? d[first + $0] : 0 }
    let next = first + p < d.count ? d[first + p] : 0
    if next >= 5 && increment(&sig) {
      sig = [1] + Array(repeating: 0, count: p - 1)
      e += 1
    }
    let s = digitString(sig)
    if e < -6 || e >= p {
      let mantissa = p > 1 ? String(s.prefix(1)) + "." + String(s.dropFirst()) : s
      return sign + mantissa + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
    }
    if e == p - 1 { return sign + s }
    if e >= 0 { return sign + String(s.prefix(e + 1)) + "." + String(s.dropFirst(e + 1)) }
    return sign + "0." + String(repeating: "0", count: -(e + 1)) + s
  }

  /// JS `String(x)` / `Number.prototype.toString()`: shortest round-trip digits, plain notation
  /// for decimal exponents −7 < n ≤ 21, exponential (`1e-7`, `1.5e+21`) otherwise.
  static func jsString(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    if x == 0 { return "0" }
    // Swift's description is also the shortest round-trip digit string; only the layout differs.
    var text = abs(x).description
    var exponent = 0
    if let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
      exponent = Int(text[text.index(after: eIndex)...]) ?? 0
      text = String(text[..<eIndex])
    }
    let point = text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
    var digits = Array(text.filter { $0 != "." })
    var n = point + exponent
    while digits.first == "0" { digits.removeFirst(); n -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count
    let s = String(digits)
    let sign = x < 0 ? "-" : ""
    if k <= n && n <= 21 { return sign + s + String(repeating: "0", count: n - k) }
    if 0 < n && n <= 21 { return sign + String(s.prefix(n)) + "." + String(s.dropFirst(n)) }
    if -6 < n && n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + s }
    let e = n - 1
    let mantissa = k == 1 ? s : String(s.prefix(1)) + "." + String(s.dropFirst())
    return sign + mantissa + "e" + (e < 0 ? "-" : "+") + String(abs(e))
  }

  // MARK: spectra-lab readout formatters

  /// Three significant figures the way the readouts print them (`sig3`).
  static func sig3(_ x: Double) -> String {
    let a = abs(x)
    if a >= 100 { return toFixed(x, 0) }
    if a >= 10 { return toFixed(x, 1) }
    if a >= 1 { return toFixed(x, 2) }
    return toPrecision(x, 3)
  }

  /// Scientific notation `"1.23×10⁻⁷ unit"` (`sci`). The mantissa can print as `10.00`
  /// (e.g. 9.996e5), a JS quirk kept for parity.
  static func sci(_ v: Double, unit: String = "") -> String {
    let suffix = unit.isEmpty ? "" : " " + unit
    if v == 0 { return "0" + suffix }
    let e = floor(log10(abs(v)))
    let m = v / pow(10, e)
    return toFixed(m, 2) + times + "10" + superscript(jsString(e)) + suffix
  }

  /// Length with an SI prefix from km to fm (`formatLength`): "550 nm", "12.2 cm".
  static func length(_ metres: Double) -> String { engineering(metres, unit: "m", prefixes: lengthPrefixes) }

  /// Frequency with an SI prefix up to EHz, scientific from 1e19 Hz (`formatFrequency`).
  static func frequency(_ hertz: Double) -> String {
    hertz >= 1e19 ? sci(hertz, unit: "Hz") : engineering(hertz, unit: "Hz", prefixes: frequencyPrefixes)
  }

  /// Photon energy with an SI prefix from MeV to peV (`formatEnergy`): "60.0 keV".
  static func energy(_ eV: Double) -> String { engineering(eV, unit: "eV", prefixes: energyPrefixes) }

  /// Molar energy (`formatKcal`): `sig3` for 0.01 ≤ k < 1e5 kcal/mol, scientific otherwise.
  static func kcal(eV: Double) -> String {
    let k = Spectrum.kcalPerMol(eV: eV)
    return (k >= 0.01 && k < 1e5 ? sig3(k) : sci(k)) + " kcal/mol"
  }

  /// Maps `-0123456789` to `⁻⁰¹²³⁴⁵⁶⁷⁸⁹`; other characters pass through.
  static func superscript(_ s: String) -> String {
    String(s.map { superscriptMap[$0] ?? $0 })
  }

  // MARK: Private helpers

  private static let lengthPrefixes: [(String, Double)] = [
    ("k", 1e3), ("", 1), ("c", 1e-2), ("m", 1e-3), (micro, 1e-6), ("n", 1e-9), ("p", 1e-12), ("f", 1e-15),
  ]
  private static let frequencyPrefixes: [(String, Double)] = [
    ("E", 1e18), ("P", 1e15), ("T", 1e12), ("G", 1e9), ("M", 1e6), ("k", 1e3), ("", 1),
  ]
  private static let energyPrefixes: [(String, Double)] = [
    ("M", 1e6), ("k", 1e3), ("", 1), ("m", 1e-3), (micro, 1e-6), ("n", 1e-9), ("p", 1e-12),
  ]
  private static let superscriptMap: [Character: Character] = [
    "-": "\u{207B}", "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}", "4": "\u{2074}",
    "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}", "8": "\u{2078}", "9": "\u{2079}",
  ]

  /// spectra-lab `engineering()`: the first prefix whose scale (×0.9995) fits, else the last.
  private static func engineering(_ v: Double, unit: String, prefixes: [(String, Double)]) -> String {
    if !v.isFinite || v == 0 { return "0 " + unit }
    for (p, s) in prefixes where abs(v) >= s * 0.9995 { return sig3(v / s) + " " + p + unit }
    let (p, s) = prefixes[prefixes.count - 1]
    return sig3(v / s) + " " + p + unit
  }

  /// Exact decimal expansion of a finite double a ≥ 0: every digit (most significant first) and
  /// the number of integer digits. A double m·2ᵏ has at most −k fraction digits, so this is the
  /// complete expansion, with no rounding.
  private static func exactDecimal(_ a: Double) -> (digits: [UInt8], intCount: Int) {
    if a == 0 { return ([0], 1) }
    let normal = a.exponentBitPattern != 0
    let m = a.significandBitPattern | (normal ? UInt64(1) << 52 : 0)
    let e2 = normal ? Int(a.exponentBitPattern) - 1075 : -1074
    var big = BigDecimal(m)
    if e2 >= 0 {
      big.multiply(byPowerOf: 2, exponent: e2)
      let digits = big.digits()
      return (digits, digits.count)
    }
    big.multiply(byPowerOf: 5, exponent: -e2)  // m·2^e2 = m·5^(−e2) / 10^(−e2)
    var digits = big.digits()
    let fraction = -e2
    if digits.count <= fraction {
      digits.insert(contentsOf: [UInt8](repeating: 0, count: fraction - digits.count + 1), at: 0)
    }
    return (digits, digits.count - fraction)
  }

  /// Adds one unit in the last place of a decimal digit array; returns true on overflow
  /// (every digit was 9 and is now 0).
  private static func increment(_ digits: inout [UInt8]) -> Bool {
    var i = digits.count - 1
    while i >= 0 {
      if digits[i] < 9 { digits[i] += 1; return false }
      digits[i] = 0
      i -= 1
    }
    return true
  }

  private static func digitString<C: Collection>(_ digits: C) -> String where C.Element == UInt8 {
    String(String.UnicodeScalarView(digits.map { Unicode.Scalar(48 + $0) }))
  }
}

/// A non-negative integer in base 10⁹ limbs (least significant first), just enough to expand
/// a double into exact decimal digits.
nonisolated private struct BigDecimal {
  private static let base: UInt64 = 1_000_000_000
  private var limbs: [UInt64]

  init(_ value: UInt64) {
    var v = value
    limbs = []
    repeat {
      limbs.append(v % Self.base)
      v /= Self.base
    } while v > 0
  }

  /// Multiplies by `factor`^`exponent` (factor 2 or 5), in chunks that keep every limb product
  /// below 2⁶⁴.
  mutating func multiply(byPowerOf factor: UInt64, exponent: Int) {
    let chunk = factor == 2 ? 30 : 13  // 2³⁰ ≈ 1.07e9, 5¹³ ≈ 1.22e9
    var remaining = exponent
    while remaining > 0 {
      let n = min(chunk, remaining)
      var multiplier: UInt64 = 1
      for _ in 0..<n { multiplier *= factor }
      multiply(by: multiplier)
      remaining -= n
    }
  }

  private mutating func multiply(by k: UInt64) {
    var carry: UInt64 = 0
    for i in limbs.indices {
      let product = limbs[i] * k + carry
      limbs[i] = product % Self.base
      carry = product / Self.base
    }
    while carry > 0 {
      limbs.append(carry % Self.base)
      carry /= Self.base
    }
  }

  /// Decimal digits, most significant first, no leading zeros (a single 0 for zero).
  func digits() -> [UInt8] {
    var out: [UInt8] = []
    for (i, limb) in limbs.reversed().enumerated() {
      var chunk = [UInt8](repeating: 0, count: 9)
      var v = limb
      for j in stride(from: 8, through: 0, by: -1) {
        chunk[j] = UInt8(v % 10)
        v /= 10
      }
      if i == 0 {
        out.append(contentsOf: chunk.drop { $0 == 0 })
      } else {
        out.append(contentsOf: chunk)
      }
    }
    return out.isEmpty ? [0] : out
  }
}

/// JavaScript `Math` semantics where they differ from Swift's defaults: NaN-propagating
/// `min`/`max` with +0 > −0, `Math.round` (ties toward +∞), `Math.sign`, and V8's exact
/// `Math.hypot` algorithm (scaled, Kahan-compensated), which reproduces Node bit for bit.
nonisolated enum JSMath {
  /// `Math.max(a, b)`: NaN if either is NaN; +0 beats −0.
  static func max(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == b { return a.sign == .minus ? b : a }
    return a > b ? a : b
  }

  /// `Math.min(a, b)`: NaN if either is NaN; −0 beats +0.
  static func min(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == b { return a.sign == .minus ? a : b }
    return a < b ? a : b
  }

  /// `Math.min(hi, Math.max(lo, v))`, the spectra-lab `clamp`.
  static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

  /// `Math.round(x)`: nearest integer, ties toward +∞. (JS returns −0 for −0.5 ≤ x < 0; this
  /// returns +0 there, which prints the same.)
  static func round(_ x: Double) -> Double {
    guard x.isFinite, x != 0 else { return x }
    let r = x.rounded(.down)
    return x - r >= 0.5 ? r + 1 : r
  }

  /// `Math.sign(x)`: 1, −1, ±0 or NaN.
  static func sign(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x > 0 { return 1 }
    if x < 0 { return -1 }
    return x
  }

  /// `Math.hypot(a, b)` exactly as V8 computes it (src/builtins/math.tq): ∞ wins over NaN,
  /// then each |value| is divided by the largest and the squares are Kahan-summed. Only
  /// + − × ÷ √ are used, so the result is bit-identical to Node's.
  static func hypot(_ a: Double, _ b: Double) -> Double {
    let x = abs(a), y = abs(b)
    let anyNaN = x.isNaN || y.isNaN
    var largest = 0.0
    if !x.isNaN && x > largest { largest = x }
    if !y.isNaN && y > largest { largest = y }
    if largest == .infinity { return .infinity }
    if anyNaN { return .nan }
    if largest == 0 { return 0 }
    var sum = 0.0
    var compensation = 0.0
    for v in [x, y] {
      let n = v / largest
      let summand = n * n - compensation
      let preliminary = sum + summand
      compensation = (preliminary - sum) - summand
      sum = preliminary
    }
    return sum.squareRoot() * largest
  }
}
