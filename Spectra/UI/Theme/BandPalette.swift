import SwiftUI

/// Hue means EM frequency and nothing else (coherence rule R2). This is spectra-lab's
/// `displayColor(λ)` (`src/core/spectrum.js`): the band colour outside the visible, and the
/// lifted spectral hue (Bruton's piecewise fit, lift 0.16 + 0.84·c^0.8) inside it.
///
/// The band table mirrors spectra-lab `BANDS`; `Core/` carries the parity-tested port.
nonisolated enum BandPalette {
  nonisolated struct Band: Hashable, Sendable, Identifiable {
    let key: String
    let name: String
    let short: String
    /// Lower and upper vacuum wavelength edges, metres.
    let lo: Double
    let hi: Double
    let rgb: RGB
    var id: String { key }
    var color: Color { rgb.color }
  }

  /// Gamma … radio, short to long wavelength. Gamma and X-ray are split at 10 pm.
  static let bands: [Band] = [
    Band(key: "gamma", name: "Gamma", short: "γ", lo: 0, hi: 1e-11, rgb: RGB(hex: 0xE2D4FF)),
    Band(key: "xray", name: "X-ray", short: "X", lo: 1e-11, hi: 1e-8, rgb: RGB(hex: 0x8FD3FF)),
    Band(key: "uv", name: "Ultraviolet", short: "UV", lo: 1e-8, hi: 400e-9, rgb: RGB(hex: 0xB583FF)),
    Band(key: "visible", name: "Visible", short: "Vis", lo: 400e-9, hi: 700e-9, rgb: RGB(hex: 0xA8FF3E)),
    Band(key: "ir", name: "Infrared", short: "IR", lo: 700e-9, hi: 1e-3, rgb: RGB(hex: 0xFF7A6B)),
    Band(key: "microwave", name: "Microwave", short: "µW", lo: 1e-3, hi: 1, rgb: RGB(hex: 0x5FD3BC)),
    Band(key: "radio", name: "Radio", short: "Radio", lo: 1, hi: .infinity, rgb: RGB(hex: 0x9DB0CC)),
  ]

  /// The band containing `lambda` (metres); radio for anything longer than 1 m.
  static func band(forWavelength lambda: Double) -> Band {
    bands.first { lambda >= $0.lo && lambda < $0.hi } ?? bands[bands.count - 1]
  }

  /// Approximate perceived colour of monochromatic light at `nm`, linear 0…1 per channel
  /// (spectra-lab `spectralRGB`, after Bruton). Zero outside 380–780 nm.
  static func spectralRGB(nanometres nm: Double) -> (r: Double, g: Double, b: Double) {
    var r = 0.0
    var g = 0.0
    var b = 0.0
    if nm >= 380, nm < 440 {
      r = (440 - nm) / 60
      b = 1
    } else if nm >= 440, nm < 490 {
      g = (nm - 440) / 50
      b = 1
    } else if nm >= 490, nm < 510 {
      g = 1
      b = (510 - nm) / 20
    } else if nm >= 510, nm < 580 {
      r = (nm - 510) / 70
      g = 1
    } else if nm >= 580, nm < 645 {
      r = 1
      g = (645 - nm) / 65
    } else if nm >= 645, nm <= 780 {
      r = 1
    }
    var k = 1.0
    if nm < 420 {
      k = 0.3 + 0.7 * (nm - 380) / 40
    } else if nm > 700 {
      k = 0.3 + 0.7 * (780 - nm) / 80
    }
    if nm < 380 || nm > 780 { k = 0 }
    return (r * k, g * k, b * k)
  }

  /// The display colour for a wavelength in metres, as an sRGB token.
  static func rgb(forWavelength lambda: Double) -> RGB {
    guard lambda.isFinite, lambda > 0 else { return bands[bands.count - 1].rgb }
    let band = band(forWavelength: lambda)
    guard band.key == "visible" else { return band.rgb }
    let c = spectralRGB(nanometres: lambda * 1e9)
    func lift(_ x: Double) -> Double {
      // spectra-lab writes the lifted value as 8-bit hex; round the same way so the
      // native and web colours are identical.
      (min(1, max(0, 0.16 + 0.84 * pow(x, 0.8))) * 255).rounded() / 255
    }
    return RGB(lift(c.r), lift(c.g), lift(c.b))
  }

  /// The display colour for a wavelength in metres.
  static func color(forWavelength lambda: Double) -> Color {
    rgb(forWavelength: lambda).color
  }

  /// The display colour for a frequency in hertz.
  static func color(forFrequency hertz: Double) -> Color {
    color(forWavelength: SpectrumMarker.lambda(forFrequency: hertz))
  }

  /// The colour a marker or stream is drawn in: band colour for EM, phosphor for analogy.
  static func color(for marker: SpectrumMarker) -> Color {
    marker.isEM ? color(forWavelength: marker.lambda) : Theme.analogy
  }
}
