import Foundation
import simd

/// An orbiting camera with Orbitals' limits and anchored-zoom maths: yaw wraps to
/// [−180, 180), pitch is clamped to ±85°, zoom to 0.25…6 (25–600 %), pan to ±1.5 viewports.
/// Zoom and pan act on the image (after projection), so the touched point stays under the
/// fingers while pinching.
///
/// World convention (shared with `SceneBuffer`): +Y up; at yaw 0, pitch 0 the camera sits on
/// +Z looking at `target`.
nonisolated struct OrbitCamera: Hashable, Sendable, Codable {
  /// Degrees about +Y, [−180, 180).
  var yaw: Double = 0
  /// Degrees above the horizon, −85…85.
  var pitch: Double = 0
  /// Image magnification, 0.25…6.
  var zoom: Double = 1
  /// Image offset as a fraction of the view width (+ right).
  var panX: Double = 0
  /// Image offset as a fraction of the view height (+ down).
  var panY: Double = 0
  /// Eye distance from `target` in world units.
  var distance: Double = 4
  /// Vertical field of view in degrees.
  var fieldOfView: Double = 38
  /// What the camera orbits.
  var target: SIMD3<Double> = .zero

  static let zoomRange: ClosedRange<Double> = 0.25...6
  static let panLimit = 1.5
  static let pitchLimit = 85.0
  /// Degrees of rotation per point of one-finger drag (Orbitals).
  static let degreesPerPoint = 0.45

  init(
    yaw: Double = 0, pitch: Double = 0, zoom: Double = 1, distance: Double = 4, fieldOfView: Double = 38,
    target: SIMD3<Double> = .zero
  ) {
    self.distance = distance
    self.fieldOfView = fieldOfView
    self.target = target
    setAngles(yaw: yaw, pitch: pitch)
    self.zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
  }

  // MARK: Edits (non-finite input is ignored)

  /// Sets yaw (wrapped) and pitch (clamped).
  mutating func setAngles(yaw: Double, pitch: Double) {
    guard yaw.isFinite, pitch.isFinite else { return }
    let wrapped = yaw.truncatingRemainder(dividingBy: 360)
    self.yaw = wrapped >= 180 ? wrapped - 360 : (wrapped < -180 ? wrapped + 360 : wrapped)
    self.pitch = min(Self.pitchLimit, max(-Self.pitchLimit, pitch))
  }

  /// One-finger drag by (dx, dy) points: right turns the scene, down tilts it.
  mutating func rotate(dx: Double, dy: Double) {
    setAngles(yaw: yaw + dx * Self.degreesPerPoint, pitch: pitch - dy * Self.degreesPerPoint)
  }

  /// Pans by a fraction of the view (each delta bounded to ±3 before adding).
  mutating func pan(dx: Double, dy: Double) {
    guard dx.isFinite, dy.isFinite else { return }
    panX = min(Self.panLimit, max(-Self.panLimit, panX + min(3, max(-3, dx))))
    panY = min(Self.panLimit, max(-Self.panLimit, panY + min(3, max(-3, dy))))
  }

  /// Zooms by `factor` about `anchor`, measured from the view centre as a fraction of the
  /// view (−0.5…0.5). The actual clamped ratio is applied, so the anchored point stays put.
  mutating func zoom(by factor: Double, anchor: SIMD2<Double> = .zero) {
    guard factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
    let next = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
    let ratio = next / zoom
    guard ratio != 1 else { return }
    zoom = next
    panX = min(Self.panLimit, max(-Self.panLimit, anchor.x - (anchor.x - panX) * ratio))
    panY = min(Self.panLimit, max(-Self.panLimit, anchor.y - (anchor.y - panY) * ratio))
  }

  /// Back to `home`'s framing.
  mutating func reset(to home: OrbitCamera) { self = home }

  // MARK: Matrices

  /// The eye position in world units.
  var eye: SIMD3<Double> {
    let y = yaw * .pi / 180
    let p = pitch * .pi / 180
    return target + distance * SIMD3(cos(p) * sin(y), sin(p), cos(p) * cos(y))
  }

  /// World → view (look-at, +Y up).
  var viewMatrix: simd_double4x4 {
    let e = eye
    let f = simd_normalize(target - e)
    var s = simd_cross(f, SIMD3(0, 1, 0))
    if simd_length(s) < 1e-9 { s = SIMD3(1, 0, 0) }
    s = simd_normalize(s)
    let u = simd_cross(s, f)
    return simd_double4x4(
      SIMD4(s.x, u.x, -f.x, 0),
      SIMD4(s.y, u.y, -f.y, 0),
      SIMD4(s.z, u.z, -f.z, 0),
      SIMD4(-simd_dot(s, e), -simd_dot(u, e), simd_dot(f, e), 1))
  }

  /// Perspective (Metal clip depth 0…1) followed by the image zoom and pan.
  func projectionMatrix(aspect: Double, near: Double = 0.05, far: Double = 200) -> simd_double4x4 {
    let a = aspect > 0 && aspect.isFinite ? aspect : 1
    let ys = 1 / tan(fieldOfView * .pi / 360)
    let xs = ys / a
    let zs = far / (near - far)
    let perspective = simd_double4x4(
      SIMD4(xs, 0, 0, 0),
      SIMD4(0, ys, 0, 0),
      SIMD4(0, 0, zs, -1),
      SIMD4(0, 0, zs * near, 0))
    let image = simd_double4x4(
      SIMD4(zoom, 0, 0, 0),
      SIMD4(0, zoom, 0, 0),
      SIMD4(0, 0, 1, 0),
      SIMD4(2 * panX, -2 * panY, 0, 1))
    return image * perspective
  }

  /// The camera for one frame of a view with this aspect (width / height).
  func sceneCamera(aspect: Double) -> SceneCamera {
    let m = projectionMatrix(aspect: aspect) * viewMatrix
    let e = eye
    return SceneCamera(
      viewProj: simd_float4x4(
        SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)),
      eye: SIMD3<Float>(e))
  }

  /// Orbitals' testable camera string, also the canvas's accessibility value.
  var accessibilityDescription: String {
    "Yaw \(Int(yaw.rounded())) degrees, tilt \(Int(pitch.rounded())) degrees, zoom \(Int((zoom * 100).rounded())) percent, pan X \(Int((panX * 100).rounded())) percent, pan Y \(Int((panY * 100).rounded())) percent"
  }
}
