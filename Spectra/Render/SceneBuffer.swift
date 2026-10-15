import CoreGraphics
import simd

/// One glowing line instance, shared by both line materials. The layout mirrors
/// `GlowSegment` in `Shaders.metal` (5 × float4 = 80 bytes).
///
/// - Holo (3D): `a.xyz`/`b.xyz` are world positions, `a.w`/`b.w` widths in points.
/// - Phosphor (2D): `a.xy`/`b.xy` are view positions in points (top-left origin), `a.w` is
///   the capsule radius in points.
///
/// `ca`/`cb` are linear-light RGB × intensity and alpha at each end; `style` is glow (0…1),
/// dash period (pt, 0 = solid), cumulative dash offset (pt) and hollow radius (pt, dots).
nonisolated struct GlowSegment: Sendable, Equatable {
  var a: SIMD4<Float>
  var b: SIMD4<Float>
  var ca: SIMD4<Float>
  var cb: SIMD4<Float>
  var style: SIMD4<Float>
}

/// A linear-light colour with intensity for the HDR scene. Intensity above 1 blooms and,
/// on XDR panels, glows brighter than white.
nonisolated struct GlowColor: Sendable, Equatable {
  var rgb: SIMD3<Float>
  var alpha: Float = 1

  init(_ rgb: SIMD3<Float>, intensity: Float = 1, alpha: Float = 1) {
    self.rgb = rgb * intensity
    self.alpha = alpha
  }

  /// From an sRGB token (`Theme.fieldERGB`, `BandPalette.rgb(forWavelength:)`).
  init(_ token: RGB, intensity: Float = 1, alpha: Float = 1) {
    self.init(token.linear, intensity: intensity, alpha: alpha)
  }

  var vector: SIMD4<Float> { SIMD4(rgb, alpha) }

  /// The same colour with a different alpha.
  func alpha(_ a: Float) -> GlowColor {
    var c = self
    c.alpha = a
    return c
  }

  /// The same colour scaled in intensity.
  func scaled(_ k: Float) -> GlowColor {
    var c = self
    c.rgb *= k
    return c
  }
}

/// What the renderer draws under the lines.
nonisolated enum SceneBackground: Sendable, Equatable {
  /// The plot-well colour with Orbitals' 32 pt phosphor grid, centre cross and vignette.
  case grid(pitch: Float = 32)
  /// The plot-well colour only (vignetted).
  case plain
}

/// The camera for one frame: world → clip and the eye position (for depth cues).
nonisolated struct SceneCamera: Sendable, Equatable {
  var viewProj: simd_float4x4 = matrix_identity_float4x4
  var eye: SIMD3<Float> = SIMD3(0, 0, 4)
}

/// Everything a `SceneBuilder` produces for one frame: holo (3D) and phosphor (2D) line
/// instances, the camera and the look. The renderer reuses one buffer, so arrays keep their
/// capacity between frames.
///
/// World convention: right-handed, +Y up, the default camera looks down −Z (from +Z).
nonisolated struct SceneBuffer: Sendable {
  /// Maximum instances per material per frame; extra lines are dropped.
  static let capacity = 65_536

  private(set) var holo: [GlowSegment] = []
  private(set) var phosphor: [GlowSegment] = []
  var camera = SceneCamera()
  var background: SceneBackground = .grid()
  /// Bloom strength (Gyre 0.6).
  var bloom: Float = 0.6
  /// Scanline depth in the composite (0 = none; Gyre 0.04). Forced to 0 under Reduce Motion.
  var scanlines: Float = 0.03
  /// View size in points.
  private(set) var size: CGSize = .zero
  /// Reduce Motion is on: builders should drop flicker, scan bands and autonomous spin.
  private(set) var reduceMotion = false

  init() {
    holo.reserveCapacity(4096)
    phosphor.reserveCapacity(4096)
  }

  /// Clears the lines for a new frame of `size` points; keeps camera and look.
  mutating func reset(size: CGSize, reduceMotion: Bool) {
    holo.removeAll(keepingCapacity: true)
    phosphor.removeAll(keepingCapacity: true)
    self.size = size
    self.reduceMotion = reduceMotion
  }

  /// Aspect ratio width / height (1 for an empty view).
  var aspect: Float {
    size.height > 0 ? Float(size.width / size.height) : 1
  }

  /// Uses an orbit camera for this frame.
  mutating func use(_ orbit: OrbitCamera) {
    camera = orbit.sceneCamera(aspect: Double(aspect))
  }

  // MARK: Holo (3D)

  /// A 3D segment from `a` to `b`, width in points, colour fading from `color` to `end`.
  mutating func line(
    _ a: SIMD3<Float>, _ b: SIMD3<Float>, color: GlowColor, end: GlowColor? = nil, width: Float = 1.5,
    glow: Float = 1, dash: Float = 0, dashOffset: Float = 0
  ) {
    guard holo.count < Self.capacity, Self.finite(a), Self.finite(b) else { return }
    holo.append(
      GlowSegment(
        a: SIMD4(a, width), b: SIMD4(b, width), ca: color.vector, cb: (end ?? color).vector,
        style: SIMD4(glow, dash, dashOffset, 0)))
  }

  /// A polyline (butt-capped joints, so additive blending never beads).
  mutating func polyline(
    _ points: [SIMD3<Float>], color: GlowColor, end: GlowColor? = nil, width: Float = 1.5, glow: Float = 1,
    closed: Bool = false
  ) {
    guard points.count > 1 else { return }
    let n = points.count - 1 + (closed ? 1 : 0)
    for i in 0..<n {
      let j = (i + 1) % points.count
      let c0 = Self.mix(color, end ?? color, Float(i) / Float(max(1, n)))
      let c1 = Self.mix(color, end ?? color, Float(i + 1) / Float(max(1, n)))
      line(points[i], points[j], color: c0, end: c1, width: width, glow: glow)
    }
  }

  /// A round dot at `p` (a zero-length holo segment), diameter in points.
  mutating func point(_ p: SIMD3<Float>, color: GlowColor, size: Float = 5) {
    line(p, p, color: color, width: size)
  }

  /// A circle (or arc) of `radius` about `center` in the plane normal to `normal`.
  mutating func ring(
    center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float, color: GlowColor, width: Float = 1.2,
    segments: Int = 64, from: Float = 0, to: Float = 2 * .pi, dash: Float = 0
  ) {
    let n = simd_normalize(normal)
    guard n.x.isFinite, segments > 1 else { return }
    let u = Self.perpendicular(n)
    let v = simd_cross(n, u)
    var previous = center + radius * (cos(from) * u + sin(from) * v)
    var travelled: Float = 0
    for i in 1...segments {
      let angle = from + (to - from) * Float(i) / Float(segments)
      let p = center + radius * (cos(angle) * u + sin(angle) * v)
      line(previous, p, color: color, width: width, dash: dash, dashOffset: travelled)
      if dash > 0 { travelled += screenDistance(previous, p) }
      previous = p
    }
  }

  /// On-screen length in points between two world points (0 if either is behind the camera).
  func screenDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    guard let pa = project(a), let pb = project(b) else { return 0 }
    return Float(hypot(pb.x - pa.x, pb.y - pa.y))
  }

  /// An arrow from `from` to `to` with a two-stroke head facing the camera.
  mutating func arrow(
    from: SIMD3<Float>, to: SIMD3<Float>, color: GlowColor, width: Float = 1.8, head: Float = 0.12
  ) {
    let d = to - from
    let length = simd_length(d)
    guard length > 1e-5 else { return }
    line(from, to, color: color, width: width)
    let dir = d / length
    let toEye = simd_normalize(camera.eye - to)
    var side = simd_cross(dir, toEye)
    if simd_length(side) < 1e-4 { side = Self.perpendicular(dir) }
    side = simd_normalize(side)
    let h = min(head, length * 0.4)
    line(to, to - dir * h + side * h * 0.55, color: color, width: width)
    line(to, to - dir * h - side * h * 0.55, color: color, width: width)
  }

  // MARK: Phosphor (2D, points, top-left origin)

  /// A 2D capsule from `a` to `b` (points); `width` is the stroke width.
  mutating func segment2D(
    _ a: CGPoint, _ b: CGPoint, color: GlowColor, end: GlowColor? = nil, width: Float = 1.5, glow: Float = 0.8,
    dash: Float = 0, dashOffset: Float = 0, hollow: Float = 0
  ) {
    guard phosphor.count < Self.capacity, a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return }
    phosphor.append(
      GlowSegment(
        a: SIMD4(Float(a.x), Float(a.y), 0, width / 2), b: SIMD4(Float(b.x), Float(b.y), 0, width / 2),
        ca: color.vector, cb: (end ?? color).vector, style: SIMD4(glow, dash, dashOffset, hollow)))
  }

  /// A 2D polyline trace (scope, spectrum, cable) with a continuous dash pattern.
  mutating func trace(
    _ points: [CGPoint], color: GlowColor, width: Float = 1.5, glow: Float = 0.8, dash: Float = 0,
    dashOffset: Float = 0
  ) {
    guard points.count > 1 else { return }
    var offset = dashOffset
    for i in 0..<(points.count - 1) {
      segment2D(points[i], points[i + 1], color: color, width: width, glow: glow, dash: dash, dashOffset: offset)
      offset += Float(hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y))
    }
  }

  /// A 2D dot (hot core), or a ring when `hollow` > 0.
  mutating func dot2D(_ p: CGPoint, color: GlowColor, diameter: Float = 7, glow: Float = 1, hollow: Float = 0) {
    segment2D(p, p, color: color, width: diameter, glow: glow, hollow: hollow)
  }

  /// Projects a world point to view points (nil when behind the camera).
  func project(_ p: SIMD3<Float>) -> CGPoint? {
    let c = camera.viewProj * SIMD4(p, 1)
    guard c.w > 1e-4 else { return nil }
    return CGPoint(
      x: CGFloat((c.x / c.w * 0.5 + 0.5)) * size.width, y: CGFloat((0.5 - c.y / c.w * 0.5)) * size.height)
  }

  // MARK: Helpers

  private static func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

  private static func mix(_ a: GlowColor, _ b: GlowColor, _ t: Float) -> GlowColor {
    var c = a
    c.rgb = a.rgb + (b.rgb - a.rgb) * t
    c.alpha = a.alpha + (b.alpha - a.alpha) * t
    return c
  }

  /// A unit vector perpendicular to `n`.
  static func perpendicular(_ n: SIMD3<Float>) -> SIMD3<Float> {
    let axis: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
    return simd_normalize(simd_cross(n, axis))
  }
}

/// A 3D or 2D scene drawn by `MetalCanvas`. Called once per displayed frame on the main
/// actor; keep it allocation-free in steady state (the buffer keeps its capacity).
///
/// ```swift
/// @Observable final class WaveScene: SceneBuilder {
///   var camera = OrbitCamera(yaw: 30, pitch: 15)
///   func build(into buffer: inout SceneBuffer, time: Double, size: CGSize) {
///     buffer.use(camera)
///     buffer.line(.zero, SIMD3(1, 0, 0), color: GlowColor(Theme.fieldERGB))
///   }
/// }
/// ```
@MainActor
protocol SceneBuilder: AnyObject {
  /// Fills `buffer` (already reset to `size` points) with this frame's lines and camera.
  /// `time` is `AppClock.time`: it stops while the transport is paused.
  func build(into buffer: inout SceneBuffer, time: Double, size: CGSize)
  /// True when the scene changes even while the clock is paused (live sensor data).
  var needsContinuousRedraw: Bool { get }
}

extension SceneBuilder {
  var needsContinuousRedraw: Bool { false }
}
