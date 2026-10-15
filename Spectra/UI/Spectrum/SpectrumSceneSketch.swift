import SwiftUI
import simd

extension EnvironmentValues {
  /// Draw the Metal scenes as CPU sketches (offscreen snapshots, where a `MetalCanvas` cannot
  /// render). Off in the app.
  @Entry var spectrumSketchScenes = false
}

/// A CPU sketch of a `SceneBuilder`: builds one frame into a `SceneBuffer` and strokes its
/// holo segments in a `Canvas` with additive blending (no bloom, no depth test). Used by the
/// DEBUG snapshot run so the scene geometry can be checked without a window server.
struct SceneSketch: View {
  let scene: any SceneBuilder
  var time: Double = 0

  var body: some View {
    Canvas { ctx, size in
      var buffer = SceneBuffer()
      buffer.reset(size: size, reduceMotion: false)
      scene.build(into: &buffer, time: time, size: size)
      var c = ctx
      c.blendMode = .plusLighter
      for s in buffer.holo {
        let a = SIMD3(s.a.x, s.a.y, s.a.z), b = SIMD3(s.b.x, s.b.y, s.b.z)
        guard let p = buffer.project(a), let q = buffer.project(b) else { continue }
        let color = Self.color(s.ca)
        let width = CGFloat(max(0.5, s.a.w))
        if a == b {
          c.fill(Path(ellipseIn: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width)), with: .color(color))
        } else {
          var path = Path()
          path.move(to: p)
          path.addLine(to: q)
          c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
        }
      }
    }
    .background(Theme.plotWell)
  }

  /// Linear HDR colour → display sRGB (clamped), alpha kept.
  private static func color(_ v: SIMD4<Float>) -> Color {
    func enc(_ x: Float) -> Double { Double(pow(min(1, max(0, x)), 1 / 2.2)) }
    return Color(red: enc(v.x), green: enc(v.y), blue: enc(v.z)).opacity(Double(min(1, max(0, v.w))))
  }
}
