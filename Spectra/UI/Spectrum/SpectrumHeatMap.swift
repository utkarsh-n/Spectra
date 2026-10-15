import CoreGraphics
import SwiftUI

/// Small heat-map images for the Phase space panels: a phosphor ramp for |ψ|² and |ψ̃|², and
/// the poster's diverging map for the signed Wigner slices (positive warm orange, negative
/// cool blue, zero the plot-well colour).
enum SpectrumHeatMap {
  enum Map {
    /// 0…1 → well → deep green → phosphor → near white.
    case phosphor
    /// −1…1 → blue … well … orange.
    case diverging
  }

  /// A `rows × columns` RGBA image; `value(row, column)` gives the mapped value, row 0 on top.
  static func image(rows: Int, columns: Int, map: Map, value: (Int, Int) -> Float) -> CGImage? {
    guard rows > 0, columns > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: rows * columns * 4)
    let well = Theme.plotWellRGB
    let w = SIMD3<Float>(Float(well.r), Float(well.g), Float(well.b))
    let green = SIMD3<Float>(0.05, 0.36, 0.17)
    let phosphor = SIMD3<Float>(Float(Theme.phosphorRGB.r), Float(Theme.phosphorRGB.g), Float(Theme.phosphorRGB.b))
    let white = SIMD3<Float>(0.9, 1.0, 0.92)
    let pos = SIMD3<Float>(Float(WignerScene.positive.r), Float(WignerScene.positive.g), Float(WignerScene.positive.b))
    let neg = SIMD3<Float>(Float(WignerScene.negative.r), Float(WignerScene.negative.g), Float(WignerScene.negative.b))
    for r in 0..<rows {
      for c in 0..<columns {
        var v = value(r, c)
        if !v.isFinite { v = 0 }
        let rgb: SIMD3<Float>
        switch map {
        case .phosphor:
          let u = pow(min(1, max(0, v)), 0.6)
          if u < 0.45 {
            rgb = mix(w, green, u / 0.45)
          } else if u < 0.85 {
            rgb = mix(green, phosphor, (u - 0.45) / 0.4)
          } else {
            rgb = mix(phosphor, white, (u - 0.85) / 0.15)
          }
        case .diverging:
          let a = pow(min(1, abs(v)), 0.65)
          rgb = mix(w, v >= 0 ? pos : neg, a)
        }
        let i = (r * columns + c) * 4
        bytes[i] = UInt8(min(255, max(0, rgb.x * 255)))
        bytes[i + 1] = UInt8(min(255, max(0, rgb.y * 255)))
        bytes[i + 2] = UInt8(min(255, max(0, rgb.z * 255)))
        bytes[i + 3] = 255
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }

  private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    let u = min(1, max(0, t))
    return a + (b - a) * u
  }
}

/// A heat-map image filling its frame with smooth interpolation.
struct HeatMapImage: View {
  let image: CGImage?

  var body: some View {
    if let image {
      Image(decorative: image, scale: 1)
        .resizable()
        .interpolation(.medium)
    } else {
      Theme.plotWell
    }
  }
}
