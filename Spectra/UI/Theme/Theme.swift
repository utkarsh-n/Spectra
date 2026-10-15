import SwiftUI
import simd

/// An sRGB colour token usable from SwiftUI (`color`) and Metal (`linear`, `srgb`).
nonisolated struct RGB: Hashable, Sendable {
  let r: Double
  let g: Double
  let b: Double

  init(_ r: Double, _ g: Double, _ b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }

  /// From a hex literal such as `0x61B3FF`.
  init(hex: UInt32) {
    self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
  }

  var color: Color { Color(red: r, green: g, blue: b) }

  func color(_ opacity: Double) -> Color { Color(red: r, green: g, blue: b).opacity(opacity) }

  /// sRGB-encoded components for shaders that encode themselves.
  var srgb: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }

  /// Linear-light components (sRGB transfer removed), for the HDR Metal pipeline.
  var linear: SIMD3<Float> { SIMD3(Self.toLinear(r), Self.toLinear(g), Self.toLinear(b)) }

  /// Mixes toward `other` by `t` in sRGB.
  func mix(_ other: RGB, _ t: Double) -> RGB {
    RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
  }

  static func toLinear(_ c: Double) -> Float {
    let x = min(1, max(0, c))
    return Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
  }
}

/// Design tokens: "glass over phosphor" (SPEC.md §2). Content is a dark phosphor
/// instrument; Liquid Glass is reserved for controls and navigation.
nonisolated enum Theme {
  // MARK: Content layer
  static let backgroundRGB = RGB(0.025, 0.045, 0.04)
  static let panelRGB = RGB(0.065, 0.095, 0.083)
  static let plotWellRGB = RGB(hex: 0x040807)
  static let phosphorRGB = RGB(0.4, 0.96, 0.56)
  static let amberRGB = RGB(1, 0.75, 0.37)
  static let mutedRGB = RGB(0.61, 0.71, 0.65)

  static let background = backgroundRGB.color
  static let panel = panelRGB.color
  /// Plot wells (`#040807`), radius 16–20, faint phosphor grid.
  static let plotWell = plotWellRGB.color
  static let hairline = Color.white.opacity(0.07)
  static let phosphor = phosphorRGB.color
  static let amber = amberRGB.color
  static let muted = mutedRGB.color
  /// Primary text on panels (spectra-lab `#e8f1ec`).
  static let text = RGB(hex: 0xE8F1EC).color
  /// Tertiary text and axis labels (spectra-lab `#7e978a`).
  static let dim = RGB(hex: 0x7E978A).color
  /// Ionizing threshold and warnings.
  static let ionizing = RGB(hex: 0xFF8F6B).color
  /// Plot grid: phosphor at 6 % (spectra-lab).
  static let grid = phosphor.opacity(0.06)
  /// Plot axes (spectra-lab `rgba(156,181,166,0.35)`).
  static let axis = RGB(hex: 0x9CB5A6).color(0.35)

  // MARK: Field colours (fixed)
  static let fieldERGB = RGB(hex: 0x61B3FF)
  static let fieldBRGB = RGB(hex: 0xFF5C7A)
  static let fieldExRGB = RGB(hex: 0x1AEDFF)
  static let fieldEyRGB = RGB(hex: 0xFFE82E)
  static let fieldE = fieldERGB.color
  static let fieldB = fieldBRGB.color
  /// Poynting vector S.
  static let poynting = amber
  static let fieldEx = fieldExRGB.color
  static let fieldEy = fieldEyRGB.color

  // MARK: Dial accents (parameter identity; never reused for data)
  /// E₀ blue.
  static let dialE0 = fieldE
  /// θ mint.
  static let dialTheta = RGB(hex: 0x59F0B0).color
  /// δ rose.
  static let dialDelta = RGB(hex: 0xFF8FB8).color
  /// φ violet.
  static let dialPhi = RGB(hex: 0xC799FF).color
  /// n, T, κ amber.
  static let dialAmber = amber
  /// λ follows the band colour of the value.
  static func dialLambda(_ metres: Double) -> Color { BandPalette.color(forWavelength: metres) }

  // MARK: Data identity
  static let iceRGB = RGB(hex: 0x8FD3FF)
  static let roseRGB = RGB(hex: 0xFF8FB8)
  static let mintRGB = RGB(hex: 0x59F0B0)
  static let violetRGB = RGB(hex: 0xC799FF)
  /// Spectra sources A, B, C.
  static let sourceRGB = [phosphorRGB, roseRGB, iceRGB]
  static let sources = sourceRGB.map(\.color)
  static let sourceNames = ["A", "B", "C"]
  /// Scope channels CH1–CH4.
  static let channelRGB = [phosphorRGB, amberRGB, iceRGB, roseRGB]
  static let channels = channelRGB.map(\.color)

  /// Non-EM signals (sound, motion, the rotor): phosphor or amber with an ANALOGY badge.
  static let analogy = phosphor
  static let analogyAlt = amber

  // MARK: Shape and spacing
  static let panelRadius: CGFloat = 26
  static let wellRadius: CGFloat = 18
  static let cardRadius: CGFloat = 20
  static let chipRadius: CGFloat = 14
  static let glassCardRadius: CGFloat = 22
  /// Screen side gutter (16 compact).
  static let gutter: CGFloat = 16
  /// Spacing between stacked panels.
  static let stackSpacing: CGFloat = 22
  static let panelPadding: CGFloat = 20
  /// Minimum touch target.
  static let minTouch: CGFloat = 44

  // MARK: Type
  /// Numbered monospaced uppercase panel titles ("01 WAVE SCOPE").
  static let panelTitleFont = Font.system(.caption, design: .monospaced).weight(.medium)
  static let readoutTitleFont = Font.system(.caption2, design: .monospaced)
  static let readoutValueFont = Font.system(.callout, design: .monospaced).weight(.medium)
  static let eyebrowFont = Font.system(.caption2, design: .monospaced)
  static let captionFont = Font.caption
  /// 9 pt canvas annotations (fixed size, as in Orbitals).
  static let annotationFont = Font.system(size: 9, weight: .medium, design: .monospaced)
  /// Serif symbols for physical quantities (λ, E₀, θ, B).
  static let symbolFont = Font.system(.title3, design: .serif).weight(.semibold)

  // MARK: Motion
  /// `nil` under Reduce Motion, otherwise `animation`.
  static func animation(_ reduceMotion: Bool, _ animation: Animation = .smooth(duration: 0.25)) -> Animation? {
    reduceMotion ? nil : animation
  }
}

extension String {
  /// Uppercase for instrument labels ("λ/2 LENGTH", "FIELD |B| IN µT"): Latin letters are
  /// capitalized, Greek letters and the micro sign stay as written (uppercasing µ would turn
  /// microwatts into megawatts).
  nonisolated var instrumentCaps: String {
    String(
      map { ch -> Character in
        let keep = ch.unicodeScalars.contains { s in
          (0x0370...0x03FF).contains(s.value) || (0x1F00...0x1FFF).contains(s.value) || s.value == 0xB5
        }
        guard !keep else { return ch }
        let upper = ch.uppercased()
        return upper.count == 1 ? Character(upper) : ch
      })
  }
}

extension Color {
  /// `Color(hex: 0x61B3FF)`.
  init(hex: UInt32, opacity: Double = 1) {
    let rgb = RGB(hex: hex)
    self.init(red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
  }
}

extension View {
  /// The app's dark ground behind a screen.
  func spectraBackground() -> some View {
    background(Theme.background.ignoresSafeArea())
  }
}
