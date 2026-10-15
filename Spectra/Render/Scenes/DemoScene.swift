import CoreGraphics
import Foundation
import Observation
import simd

/// A pipeline check for the renderer: a circularly polarized wave travelling along +x. The
/// E vector (blue) and B vector (red) trace two helices a quarter turn apart, with stems from
/// the beam axis (drawn in the wave's band colour) and the Poynting arrow S (amber) at the
/// end; a 2D phosphor trace of Eᵧ runs along the bottom. Time is κ-slowed: the pattern turns
/// `cyclesPerSecond` times a second whatever the wavelength.
@Observable @MainActor
final class DemoScene: SceneBuilder {
  /// The framing that Align and double-tap return to.
  static let home = OrbitCamera(yaw: 28, pitch: 14, distance: 5.6)

  var camera = DemoScene.home
  /// Vacuum wavelength (m); sets the beam colour only.
  var lambda: Double = 550e-9
  /// Displayed turns per second (spectra-lab's κ).
  var cyclesPerSecond: Double = 0.5
  /// Sway the view gently (±20° of yaw) while the clock runs.
  var autoRotate = true

  init() {}

  func build(into buffer: inout SceneBuffer, time: Double, size: CGSize) {
    var view = camera
    if autoRotate, !buffer.reduceMotion {
      view.setAngles(yaw: camera.yaw + 20 * sin(2 * .pi * time / 24), pitch: camera.pitch)
    }
    buffer.use(view)
    buffer.background = .grid(pitch: 32)

    let e = GlowColor(Theme.fieldERGB, intensity: 1.6)
    let b = GlowColor(Theme.fieldBRGB, intensity: 1.4)
    let beam = GlowColor(BandPalette.rgb(forWavelength: lambda), intensity: 1.2)
    let s = GlowColor(Theme.amberRGB, intensity: 1.5)

    let length: Float = 3.2
    let x0 = -length / 2
    let turns: Float = 2
    let amplitude: Float = 0.62
    let phase = Float((2 * Double.pi * cyclesPerSecond * time).truncatingRemainder(dividingBy: 2 * .pi))
    let n = 160
    var ePoints: [SIMD3<Float>] = []
    var bPoints: [SIMD3<Float>] = []
    ePoints.reserveCapacity(n + 1)
    bPoints.reserveCapacity(n + 1)
    for i in 0...n {
      let u = Float(i) / Float(n)
      let x = x0 + length * u
      let k = 2 * Float.pi * turns * u - phase
      ePoints.append(SIMD3(x, amplitude * cos(k), amplitude * sin(k)))
      // B is perpendicular to E and a quarter turn ahead (E × B along +x).
      bPoints.append(SIMD3(x, -amplitude * 0.82 * sin(k), amplitude * 0.82 * cos(k)))
    }
    // Beam axis and its arrowhead.
    buffer.line(SIMD3(x0 - 0.2, 0, 0), SIMD3(-x0 + 0.1, 0, 0), color: beam.scaled(0.7), width: 1.2)
    buffer.arrow(from: SIMD3(-x0 + 0.1, 0, 0), to: SIMD3(-x0 + 0.55, 0, 0), color: s, width: 2, head: 0.14)
    // Stems every 8 samples.
    for i in stride(from: 0, through: n, by: 8) {
      buffer.line(SIMD3(ePoints[i].x, 0, 0), ePoints[i], color: e.scaled(0.45), width: 0.9, glow: 0.5)
      buffer.line(SIMD3(bPoints[i].x, 0, 0), bPoints[i], color: b.scaled(0.35), width: 0.8, glow: 0.4)
    }
    buffer.polyline(ePoints, color: e, width: 2.2)
    buffer.polyline(bPoints, color: b, width: 1.8)
    buffer.point(ePoints[n], color: e, size: 7)
    buffer.point(bPoints[n], color: b, size: 6)
    // The transverse plane at the far end, dashed.
    buffer.ring(
      center: SIMD3(-x0, 0, 0), normal: SIMD3(1, 0, 0), radius: amplitude, color: beam.scaled(0.5), width: 0.9,
      segments: 72, dash: 6)

    // A phosphor 2D trace of Eᵧ along the bottom of the view.
    let w = size.width
    let h = size.height
    guard w > 40, h > 80 else { return }
    let baseline = h - 26
    var trace: [CGPoint] = []
    trace.reserveCapacity(121)
    for i in 0...120 {
      let u = Float(i) / 120
      let k = 2 * Float.pi * turns * u - phase
      trace.append(CGPoint(x: 16 + (w - 32) * CGFloat(u), y: baseline - 14 * CGFloat(cos(k))))
    }
    buffer.segment2D(
      CGPoint(x: 16, y: baseline), CGPoint(x: w - 16, y: baseline), color: GlowColor(Theme.mutedRGB, alpha: 0.35),
      width: 0.8, glow: 0, dash: 4)
    buffer.trace(trace, color: GlowColor(Theme.fieldERGB, intensity: 0.85), width: 1.2, glow: 0.6)
  }
}
