import CoreGraphics
import Foundation
import simd

/// Decompose → Phase space: Utkarsh's spacetime Wigner distribution Φ(ν, k; x, t) as a Metal
/// volume. The cube shows Φ integrated over k (the temporal Wigner at every x) or one k column,
/// as glowing point sprites on a diverging map: positive warm orange, negative cool blue, as
/// on his poster. Time runs along world X, frequency up (Y) and space in depth (−Z).
///
/// The points come from `SpectrumPhaseModel` (computed off the main actor by `Phase`); this
/// scene only places them. The fixed-t and fixed-x slices are outlined as planes.
@MainActor
final class WignerScene: SceneBuilder {
  var camera = OrbitCamera.wignerCubeHome
  /// Cube cells: (x, t, ν) in −1…1 and the signed value w in −1…1.
  var points: [SIMD4<Float>] = []
  /// Fixed-t slice position along the time axis (−1…1), or nil.
  var tSlice: Float? = 0
  /// Fixed-x slice position along the space axis (−1…1), or nil.
  var xSlice: Float? = 0

  /// Warm orange for Φ > 0 and cool blue for Φ < 0.
  static let positive = RGB(1.0, 0.56, 0.18)
  static let negative = RGB(0.27, 0.58, 1.0)

  init() {}

  @inline(__always) private func world(x: Float, t: Float, nu: Float) -> SIMD3<Float> {
    SIMD3(t, nu * 0.9, -x)
  }

  func build(into buffer: inout SceneBuffer, time: Double, size: CGSize) {
    buffer.use(camera)
    buffer.background = .grid(pitch: 32)
    buffer.bloom = 0.5

    // The box and its three axes from the (x, t, ν) = (−1, −1, −1) corner.
    let box = GlowColor(Theme.mutedRGB, intensity: 0.32, alpha: 0.6)
    for a in stride(from: Float(-1), through: 1, by: 2) {
      for b in stride(from: Float(-1), through: 1, by: 2) {
        buffer.line(world(x: a, t: -1, nu: b), world(x: a, t: 1, nu: b), color: box, width: 0.8, glow: 0)
        buffer.line(world(x: -1, t: a, nu: b), world(x: 1, t: a, nu: b), color: box, width: 0.8, glow: 0)
        buffer.line(world(x: a, t: b, nu: -1), world(x: a, t: b, nu: 1), color: box, width: 0.8, glow: 0)
      }
    }
    let origin = world(x: -1, t: -1, nu: -1)
    buffer.arrow(
      from: origin, to: world(x: -1, t: 1.25, nu: -1), color: GlowColor(Theme.phosphorRGB, intensity: 0.9), width: 1.4,
      head: 0.1)
    buffer.arrow(
      from: origin, to: world(x: -1, t: -1, nu: 1.25), color: GlowColor(Theme.amberRGB, intensity: 0.9), width: 1.4,
      head: 0.1)
    buffer.arrow(
      from: origin, to: world(x: 1.25, t: -1, nu: -1), color: GlowColor(Theme.iceRGB, intensity: 0.9), width: 1.4,
      head: 0.1)

    // Slices.
    if let t = tSlice {
      let col = GlowColor(Theme.phosphorRGB, intensity: 0.7, alpha: 0.8)
      rect(
        &buffer, world(x: -1, t: t, nu: -1), world(x: 1, t: t, nu: -1), world(x: 1, t: t, nu: 1), world(x: -1, t: t, nu: 1),
        color: col)
    }
    if let x = xSlice {
      let col = GlowColor(Theme.iceRGB, intensity: 0.7, alpha: 0.8)
      rect(
        &buffer, world(x: x, t: -1, nu: -1), world(x: x, t: 1, nu: -1), world(x: x, t: 1, nu: 1), world(x: x, t: -1, nu: 1),
        color: col)
    }

    // The volume. Points add up along the line of sight, so each one is dimmed by the cloud's
    // density (about 1,500 points read at full strength) to keep warm and cool apart instead
    // of burning to white where many cells stack.
    let density = max(1, (Float(points.count) / 1500).squareRoot())
    for p in points {
      let w = p.w
      let a = abs(w)
      let rgb = w >= 0 ? Self.positive : Self.negative
      buffer.point(
        world(x: p.x, t: p.y, nu: p.z),
        color: GlowColor(rgb, intensity: (0.14 + 0.7 * a) / density, alpha: min(1, (0.25 + 0.6 * a) / density.squareRoot())),
        size: 1.8 + 3.8 * a)
    }
  }

  /// A slice outline through four corners (no array, so a frame allocates nothing).
  private func rect(
    _ buffer: inout SceneBuffer, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, color: GlowColor
  ) {
    buffer.line(a, b, color: color, width: 1.1, glow: 0.4)
    buffer.line(b, c, color: color, width: 1.1, glow: 0.4)
    buffer.line(c, d, color: color, width: 1.1, glow: 0.4)
    buffer.line(d, a, color: color, width: 1.1, glow: 0.4)
  }
}
